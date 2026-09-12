# Baseline — popup open, hover selection, preview animation

Measured on 2026-09-12 with the instrumentation from
[performance-profiling.md](performance-profiling.md), before any of the optimizations it suggests.
This is the reference point every later change should be compared against.

## How the data was taken

Real GUI session, not a synthetic harness: the popup was opened by clicking the status item
(and by `⌘⇧C`), and the cursor was moved across the rows with the physical pointer from Peekaboo,
so AppKit delivered genuine `mouseMoved`/`onHover` events.

```bash
# 1. a throwaway copy of a real 200-item store, so the user's history is never touched
sqlite3 "file:$HOME/Library/Containers/org.p0deje.Maccy/Data/Library/Application\
 Support/Maccy/Storage.sqlite?mode=ro" ".backup /tmp/maccy-baseline/Storage.sqlite"

# 2. Debug build with instrumentation and the temporary store
open -n -g -a .build/Build/Products/Debug/Maccy.app \
  --env MACCY_PERF=1 --env MACCY_PERF_VERBOSE=1 \
  --env MACCY_STORAGE_PATH=/tmp/maccy-baseline/Storage.sqlite --args enable-testing

# 3. click the status item, sweep the cursor over 20 rows, let the preview auto-open
# 4. read the result
log show --last 15m --predicate 'subsystem == "org.p0deje.Maccy"' --info --style compact
log show --last 15m --predicate 'subsystem == "org.p0deje.Maccy"' --signpost --style compact
```

Environment: Debug build, 200 items (text, image, HTML/RTF, hex-colour titles), popup 450×800,
~57 rows prepared by the list, 60 Hz display, single display 1536×960 logical.
Idle baseline is a flat `fps=60.0 ... hitches=0 dropped=0 worst=16.67ms`.

## Zone 1 — opening the popup

`popup.open.firstFrame`, from the user action to the first frame ticked by the display link.

| source | samples (ms) | median |
| --- | --- | --- |
| status item click | 101.9, 102.4, 163.2, 172.6, 184.5 | 163.2 |
| `⌘⇧C` shortcut | 95.1, 106.0, 106.1, 177.2 | 106.0 |
| **all (n=9)** | 95.1 … 184.5 | **106.1** |

The AppKit work inside `FloatingPanel.open()` is only 10–13 ms of that:

| step | ms |
| --- | --- |
| `setContentSize` | 1.8 – 2.3 |
| `setFrameOrigin` | 0.15 – 0.19 |
| `orderFrontRegardless` | 0.44 – 0.58 |
| `makeKey` | 3.2 – 3.7 |
| `becameKey` | 4.8 – 5.6 |

**88–93 % of the open latency is the wait for the first presented frame** — first layout and paint
of the list, not window plumbing. The second right after an open: `fps` 46–55, `hitches` 0–6,
`dropped` 0–13, worst frame 20–150 ms.

No `popup.verticalResize` fired in any of these runs: with 200 items `popup.height` is already at
the 800 pt maximum, so the popup opens at its final size on the first frame. The two-phase
"popup grows after it appears" path only applies when the history is shorter than `windowSize`.

### Cold start — the first open after launch

This was never measured separate from the table above, and the open path has **not** been optimized:
nothing in the hover or preview work touches it. Three fresh instances of the same build, each doing
one first open and one later open in the same process (store already loaded, `position=Menu icon`,
200 items, status-item click):

| open | samples (ms) | median |
| --- | --- | --- |
| first after launch | 299.3, 228.7, 209.4 | **228.7** |
| later in the same process | 82.7, 82.2, 82.3 | **82.3** |

The first appearance costs **+127…+217 ms** (2.5–3.6×) and the extra time is in both halves:

| step | cold (ms) | warm (ms) |
| --- | --- | --- |
| `setContentSize` | 3.6 – 3.8 | 1.6 – 1.7 |
| `setFrameOrigin` | 0.18 – 0.20 | 0.07 – 0.08 |
| `orderFrontRegardless` | 11.5 – 11.6 | 0.90 – 0.96 |
| `makeKey` | 21.4 – 33.8 | 13.0 – 14.1 |
| `becameKey` | 34.4 – 35.5 | 4.8 – 16.0 |
| **AppKit steps, total** | **71 – 85** | **20 – 33** |
| the rest = wait for the first presented frame | 138 – 144 | ~50 – 62 |

**Thumbnail rasterization was the first suspect here and measurement rejected it.** Every row that
comes on screen for the first time runs `HistoryItemView.onAppear` → `ensureThumbnailImage()` →
`image.resized(to:)`, and that returns a **lazily drawn** image whose handler runs on the first draw,
on the main thread. But the first open of the popup only ever asked for **3** thumbnails
(`decorator.ensureThumbnailImage[calls=3]` in the second of the open, against ~25 visible rows), and
they were assigned in a later frame anyway (the generator is a `Task`). Rasterizing them off the main
thread (see the next subsection) changed the cold open from 209.4 / 228.7 / 299.3 ms to
**206.9 / 214.4 ms** — i.e. not at all, with the AppKit step breakdown identical (71.3 ms).

What the 138–144 ms first-frame wait actually is: first-time SwiftUI work — building and laying out
the list's view tree — plus first-time window work. The popup-open stall of the Instruments trace
(172 ms, ~10 s after launch, `wasVisible=false`) is **41 % allocation**, 17 % SwiftUI internals,
13 % ARC, 4 % attribute graph and only 1.8 % our own code: creation, not rendering. The first-time
half of that is visible in the AppKit steps too: `orderFrontRegardless` 0.9 → 11.5 ms and `becameKey`
4.8 → 34.4 ms on the first open, i.e. the window's first ordering and its first responder chain.

On the other hand the same lazy-thumbnail mechanism **is** what stalls a sweep: in the trace of a
full sweep `NSImage.resized` accounted for **131 ms of main-thread CPU in a single 0.33 s window**
(14:33:57.71–58.04) — the cluster of four stalls (125 / 98 / 95 / 111 ms) in the second that reported
fps 27.4 with 14 hitches — with `resample_horizontal_avx2` as self time in the same stall. That part
is fixed, see below.

Two shorter runs that pressed `⌘⇧C` instead of clicking the icon, with `position=Cursor`, gave
182.4 / 186.3 / 213.6 ms cold, and 231.8 ms when the open was requested 0.8 s after launch while the
store was still loading. So the penalty is not specific to the click path, but `popupPosition` does
change the absolute number (rule 11 in `AGENTS.md`) — cold and warm must be compared within one
setting.

One correction to the breakdown above: **62–70 ms of that first-frame wait was the probe measuring
itself.** `PerfFrameMonitor.start(on:)` creates the process's first display link, and CoreAnimation
answers that by enumerating every display mode of the screen — 69 of the 191 ms of the first-open
stall in the cold-open trace sit under `-[CADisplay _initWithDisplay:] → CA::Display::Display::update()
→ SLSIsDisplayModeVRR`, building vectors of `CGSDisplayMode`/`SLSLinkDescription`. It is a one-time
cost per process, it only exists when instrumentation is on, and it landed exactly inside the first
open. `PerfFrameMonitor.warmUp(on:)` now creates and discards a display link during the warm-up, and
`popup.open.displayLinkMonitor` reports what is left of it per open (0.08–0.21 ms).

### Cold start — after the popup warm-up

`FloatingPanel.prewarm()` (called from `History.load()` once the items are in) builds, lays out and
presents the popup's view tree while the panel is still hidden, so that the first open does not pay
for it: the panel is sized as an open would size it, laid out, ordered front **outside every screen**
(the `constrainFrameRect(_:to:)` override keeps AppKit from pulling it back onto a screen) and made
key for as long as the warm-up slices keep finding work, before being ordered out. Nothing is ever
visible and the app is never activated. Skipped in an XCTest host and when VoiceOver is on (a focus
change is audible there).

Measured with the *same* scenario for every build — fresh instance, 200-item copy of the store, the
popup triggered by reopening the app (`open -a`, i.e. `applicationShouldHandleReopen` → `panel.toggle`),
which lands 4/4 where the coordinate click on the status item landed about half the time. Four runs
per build, `popup.open.firstFrame`:

| build | cold (ms) | warm (ms) | cold − warm |
| --- | --- | --- | --- |
| HEAD before this change (8 runs, two sets) | 252.4 (238.6 – 334.0) | 78 – 87 | **166 ms** |
| warm-up of layout + presentation only | 158.9 (111.5 – 168.0) | 74.5 | 84 ms |
| + display-link warm-up | 127.4 (116.3 – 138.1) | 80.7 | 47 ms |
| + making the panel key offscreen, final | **128.9 / 99.0** (124.8 – 136.0) | 70.2 | **59 ms** |

> **These absolutes are only valid inside the session they were taken in.** The same HEAD build
> measured 252.4 ms cold there and 70.1 ms in the session that produced the turn table below — same
> store, same scenario, same trigger, same build settings. Every comparison in this document is
> therefore re-measured against its own baseline *in one session*; a difference of tens of
> milliseconds between two sessions says nothing about the code. See the caveat at the end of this
> section.

The last two rows are the same code path measured twice, with the runloop turn held at 0.2 s. Where
the work goes, per run:

| phase | cost at launch | what it moves off the first open |
| --- | --- | --- |
| display-link warm-up | 62 – 71 ms | the first `CADisplay` of the process |
| layout (`setContentSize` + `layoutSubtreeIfNeeded`) | 94 – 106 ms | building and laying out ~30 rows (`colorImage.from[calls=30]`) |
| presentation + key + runloop turn | 293 – 350 ms (200 of it the turn) | first ordering, first appearance, search field's first focus |

First open: **238.6 – 334.0 ms → 124.8 – 136.0 ms** (median 252.4 → 128.9), the cold-vs-warm penalty
166 → 59 ms. `popup.open.orderFrontRegardless` drops from 9.6 – 15.7 ms to 0.7 – 4.1 ms and
`popup.open.setContentSize` from 2.7 – 6.7 ms to 0.1 – 0.4 ms; `makeKey` stays cold (13 – 25 ms) and
the remaining ~59 ms is the part that can only happen on a window that is really on screen.

Cost: the warm-up itself is of the order of 400 ms of main-thread work about a second after launch
(see the turn section below). That is a deliberate trade — nobody is waiting for the popup then, and
a click that does arrive during the turn is respected (the panel is left open instead of being
ordered out from under the user).

Covered by `MaccyTests/FloatingPanelPrewarmTests`: the panel is sized like an open would size it, the
content is laid out, the window is ordered front **outside every screen** and never left visible, the
warm-up happens once, and it is skipped once the panel has been shown. The offscreen assertion is
what caught `constrainFrameRect` pulling the offscreen window back onto a screen — i.e. a popup
flashing in a corner at launch.

### The warm-up turn: from a fixed 0.2 s to "until the slices stop working"

A duration is the wrong shape for this turn. What the tree does after `makeKey()` was sampled per
20 ms slice (main-thread CPU per slice, one launch):

```
37.3  75.6  9.6  9.8  6.5  3.5  3.7  2.2  2.3  2.3  2.2  2.1  2.0  2.1  2.3  2.3 … 0.1
```

Two heavy slices, two more of ~10 ms, and then the same window dribbles 2–5 ms per slice for another
~300 ms without anything the first open notices. `PrewarmQuiescence` (in `FloatingPanel.swift`) ends
the turn when a slice burns less than a fifth of the busiest one so far, with a 1 ms floor, at least
4 slices and a ceiling of 25 slices (0.5 s). Everything is measured with
`clock_gettime(CLOCK_THREAD_CPUTIME_ID)`, so "work" means the main thread actually ran, not that some
view flag happened to be set (see the caveat about `needsLayout` in `AGENTS.md`).

The whole trade-off, one session, 3 runs per configuration, cold/warm = `popup.open.firstFrame`
medians:

| turn | warm-up total (ms) | cold (ms) | warm (ms) | cold − warm |
| --- | --- | --- | --- | --- |
| ~40 ms (the turn is effectively off) | 289 – 313 | 82.8 | 67.6 | 15 ms |
| ~135 ms (3 slices) | 381 – 391 | 65.8 | 69.3 | ≈0 |
| 200 ms, fixed (the previous version) | 437 – 457 | 70.1 | 66.8 | 3 ms |
| adaptive, final (4–5 slices, 157–172 ms) | 410 – 421 | 64.7 | 65.4 | **≈0** |
| "until the window goes completely quiet" (25 slices, 855–870 ms) | 855 – 870 | 68.5 | 66.0 | ≈0 |

Readings:

* **The remaining first-open penalty is ~15 ms, and ~130 ms of turn removes it.** Waiting for the
  tree to go completely quiet costs twice the launch time and buys nothing: 855–870 ms of warm-up for
  the same 65–68 ms open.
* **The adaptive turn lands where the fixed 0.2 s was tuned to**, which is the point — the fixed value
  was a worst case, chosen in a session where 50 ms of turn left 47 ms of work behind, and it is paid
  on every launch whether the work needs it or not. On a slower machine the fraction-based ceiling
  keeps the turn alive instead of cutting it in the middle of the work.
* The warm-up's own cost is dominated by the slices: layout 94–99 ms, display-link warm-up 61–63 ms, the turn 157–172 ms, total 410–421 ms.

### Release (-O) vs Debug: the cold start and the warm-up

Same scenario, same session, 4 runs per cell, medians of `popup.open.firstFrame`:

| build | warm-up | cold (ms) | warm (ms) | cold − warm |
| --- | --- | --- | --- | --- |
| Debug `-Onone` | none | 171.4 (169.1 – 177.3) | 71.7 | ~100 ms |
| Release `-O` | none | 167.4 (163.5 – 181.0) | 63.3 | ~104 ms |
| Debug `-Onone` | adaptive | **64.7** (63.4 – 68.3) | 65.4 | ≈0 |
| Release `-O` | adaptive | **66.7** (61.0 – 72.3) | 62.7 | ~4 ms |

Readings:

* **The cold open is structural, not `-Onone`.** Optimized or not, the first open past a repeat costs
  ~100 ms, and the medians are 171 vs 167 ms: `-O` does not touch it.
* **The warm-up removes it in both configurations**: 171 → 65 ms in Debug, 167 → 67 ms in Release.
* **`-Onone` costs ~8 ms (11 %) on the steady path**: the repeat open is 71.7 ms in Debug against
  63.3 ms in Release with no warm-up at all.
* **The warm-up itself is configuration-independent**: 410–421 ms in Debug against 396–432 ms in
  Release, with the turn at 157–172 ms in both, the layout a little cheaper in Release (88–96 ms
  against 93–99 ms) and the display-link warm-up identical (61–63 ms).
* **The stopping rule sees the same picture in Release**: 4–5 slices, busiest slice 67–77 ms
  (Debug 70–103 ms).

A Release run needs its own isolation — `enable-testing` and `MACCY_STORAGE_PATH` are compiled out
with `#if DEBUG`, so the build reads the real home directory. `CFFIXED_USER_HOME` redirects the store
*and* the preferences; the recipe and the post-run checks are in
[performance-profiling.md](performance-profiling.md).

### After the thumbnail fix — rasterization off the main thread

`NSImage.rasterized(to:scale:)` draws the resized image into a bitmap right away (at the backing
scale, so thumbnails stay crisp), and `HistoryItemDecorator.generateThumbnailImage()` awaits it inside
a detached task, so a row's thumbnail is never rasterized on the main thread. `resized(to:)` itself
is unchanged and still lazy; the preview image still goes through it.

Measured on the same sweep scenario, with the same Instruments setup (Time Profiler + `os_signpost`):

| | before | after |
| --- | --- | --- |
| main-thread CPU inside `NSImage.resized` | **131 ms** in one 0.33 s window | **35 ms** in one 35 ms window |
| where that time is spent | row thumbnails | the **preview** image, drawn lazily on the main thread |
| stalls ≥30 ms in the trace | 42 | 34 |
| main-thread busy CPU in the trace | 4463 ms (68 s recording) | 2842 ms (46 s recording) |

The last two rows are not directly comparable — the recordings differ in length and the sweep is
only part of them — but the image cluster is: the remaining 35 ms carries
`closure #1 in NSImage.resized(to:)` on the stack with no row-specific app frame, i.e. it is the
preview panel's image, the one path this change deliberately left alone. The largest stalls of the
new trace are elsewhere: 198 / 183 ms under `LargeTextPreviewView.makeScrollView(text:)` (the preview
panel's `NSTextView` being built) and 192 ms under `FloatingPanel.toggle` (the popup open).

Covered by `MaccyTests/ThumbnailRasterizationTests`: the rasterization runs off the main thread, the
row receives an image backed by an `NSBitmapImageRep`, the aspect ratio and the requested scale
survive, `resized(to:)` stays lazy, and an item without an image never rasterizes.

Caveat on comparing numbers across sessions: the same code measured 238.6 – 334.0 ms cold in one
session and 63.4 – 77.3 ms in another, with the trigger, the store, the item count and the popup
position all held constant. Machine state (other apps, thermal, the user's own Maccy instance being
up or not) moves these medians by more than most of the changes in this document do. Rebuild the
baseline and measure it in the same session, or do not compare at all.

Side observation from the same runs: in every fresh instance the preview panel toggles itself open
~1.9 s after `history.load`, with the popup still closed
(`preview.toggle.begin trigger=autoOpen state=closed` → `preview.toggle.end state=open`), because
loading the history sets the lead item and `NavigationManager` schedules `startAutoOpen()`. Whether
that panel is actually visible on screen was not verified in this pass.

## Zone 2 — hover selection

| metric | value |
| --- | --- |
| `hover.applySelection` interval (n=105) | min 0.23 / **p50 0.29** / max 0.72 ms |
| `hover.cursorToCallback.ms` per 1 s window (n=18) | min 5.5 / **p50 52.7** / max 486 ms |
| worst single cursor→callback sample | **660.7 ms** |
| `fps` while sweeping | 5.7 – 55 (idle 60) |
| `hitches` / `dropped` while sweeping | up to 10 / 86 per second |
| worst frame gap while sweeping | 190 – 1025 ms |
| row bodies re-evaluated per hover event | **~57** |

The per-window counters scale exactly with `hovers × 57`:

| counter | per window |
| --- | --- |
| `colorImage.from` | 228 – 969 |
| `decorator.hasImage` | 236 – 1057 |
| `historyItem.imageData` | 234 – 1011 |
| `decorator.accessibilityLabel` | 236 – 1003 |

So the selection itself is free (0.29 ms) while the *reaction* to it costs ~57 row-body evaluations,
and the cursor-to-highlight latency (median ~53 ms, up to ~0.5 s under load) is the main thread
queueing behind that work. That queueing delay is exactly the "highlight lags slightly behind the
cursor" symptom.

## Zone 3 — preview animation

`preview.toggle` (window frame animation) and `preview.swiftuiAnimation.ms` (content animation),
against the declared `SlideoutController.animationDuration = 0.25 s`.

| metric | samples (ms) | median | vs 250 ms |
| --- | --- | --- | --- |
| `preview.toggle` interval (n=6) | 276.5, 310.7, 319.7, 328.0, 335.9, 345.5 | **323.8** | +29 % |
| `preview.swiftuiAnimation.ms` (n=5) | 287.0, 291.0, 294.2, 296.3, 328.3 | **294.2** | +18 % |

The second in which the preview animates: `fps` 45–52, `hitches` 4–6, `dropped` 8–15,
worst frame 68–114 ms — roughly a quarter of the frames are late, and the window animation and the
SwiftUI content animation finish ~30 ms apart (they are driven by two independent clocks).

## Main time sinks, ranked

1. **Whole-list re-render on every hover.** Each selection change re-evaluates ~57 row bodies, and
   each body re-runs the expensive getters: `HistoryItem.imageData` (a fresh scan of `contents`),
   `HistoryItemDecorator.hasImage`, `accessibilityLabel` (string building),
   `ColorImage.from(title)` (synchronous rasterization) and the application-image cache lookup.
   Instrumented totals for one second of sweeping: `accessibilityLabel` 153 ms,
   `hasImage` 51 ms, `colorImage.from` 42 ms, `application.lookup` 35 ms — plus SwiftUI's own
   layout and commit on top.
2. **Main-thread saturation → input latency.** Cursor-to-hover-callback is median ~53 ms and up to
   ~0.5 s, while the hover handler itself costs 0.29 ms. The lag is queueing, not computation.
3. **First frame of the popup, ~90–170 ms** (88–93 % of open latency), with only ~11 ms of AppKit
   calls: it is the first layout + paint of the list.
4. **Preview animation overruns its 250 ms budget** by 18–29 % and drops 8–15 frames per second
   while it runs.

## Release (-O) vs Debug (-Onone)

The same scenario was replayed on a Release build to see which parts of the numbers above are
`-Onone` overhead and which are structural. Release differs from Debug in three ways
(`SWIFT_OPTIMIZATION_LEVEL = -O`, `SWIFT_COMPILATION_MODE = wholemodule`, no `DEBUG` condition),
so the comparison is "optimized build vs not", not "optimization flag alone".

One setting had to be normalized first: the Debug run had `popupPosition = statusItem` (the
"Menu icon" note), while the Release run picked up the code default `.cursor` from the unsandboxed
build's own domain — a different popup placement, and therefore a different hover starting point.
The Release run was forced to `statusItem` to match.

| metric | Debug `-Onone` | Release `-O` |
| --- | --- | --- |
| popup first frame, status item click | 163.2 ms (n=5: 101.9–184.5) | 166.2 ms (n=3: 107.1–238.1) |
| AppKit steps inside `open()` | 10.4 – 12.6 ms | 5.3 – 58 ms (noisier) |
| `hover.applySelection` | p50 0.29 ms (n=105) | p50 0.20 ms (n=53) |
| cursor → hover callback, mean per second | p50 52.7 ms, max 486 ms | 2.3 – 6.0 ms |
| worst single cursor → callback | 660.7 ms | 38.7 ms |
| worst frame gap while hovering | 190 – 1025 ms | 57 – 548 ms |
| `fps` while hovering | 5.7 – 41 (idle 60) | 25 – 57 (idle 60) |
| dropped frames per second while hovering | up to 86 | up to 34 |
| row bodies rebuilt per hover event | ~57 | ~30 |
| `decorator.accessibilityLabel` per call | 0.152 ms | 0.116 ms |
| `decorator.hasImage` per call | 0.048 ms | 0.028 ms |
| `colorImage.from` per call | 0.043 ms | 0.023 ms |
| `decorator.application.lookup` per call | 0.035 ms | 0.037 ms |
| preview animation | 323.8 ms median (n=6: 276.5–345.5) | 413.7 ms median (n=6: 331.5–499.9) |
| frames during the preview animation | fps 45–52, 4–6 hitches, 8–15 dropped, worst 68–114 ms | fps 42.5–43.8, 3–6 hitches, 10–20 dropped, worst 89–213 ms |

What that splits into:

* **The popup-open latency is structural.** The median does not move (163 → 166 ms), and the
  AppKit calls inside `open()` stay in the same ballpark — the cost is the first presented frame
  either way. Optimizing the open means making the first layout/paint of the list cheaper, not
  making Swift code faster.
* **The hover lag is mostly `-Onone` overhead, but not entirely.** Input delivery stops queueing
  (53 ms → 2.5 ms mean, 660 ms → 39 ms worst), which is the "slight lag behind the cursor"
  disappearing. Yet `fps` still falls to 25–40 with 20–34 dropped frames per second, because each
  hover still rebuilds ~30 rows whose getters re-scan `contents`, rebuild an accessibility label
  and rasterize a colour swatch. A Release-profile verification therefore validates the Debug
  measurements as a *ranking*, not as absolute numbers.
* **The preview overrun is structural.** `-O` did not improve it; the Release samples are ~28 %
  *higher*. Treat the direction as unresolved (4 of the 6 Release samples came from the sidebar
  button rather than `autoOpen`, and the preview content depends on which row was selected), but
  the conclusion that this is not `-Onone` overhead holds.

## After the hover fix — rows no longer rebuild on every hover

Replayed on 2026-09-12 with the same store (200 items, fresh copy), the same Debug build settings and
the same scenario (status-item click, `move` sweep with `smooth: true` over 20 rows, dwell for the
preview), only the code changed: `NavigationManager.isMultiSelectActive` is now a stored flag that is
written only when it flips, and the values a row derives from its item (`imageData`, `hasImage`,
`accessibilityLabel`, `application`, `ColorImage`) are cached.

| metric | before (Debug) | after (Debug) |
| --- | --- | --- |
| row bodies rebuilt per hover event | **~57** | **3.98** (490 bodies / 123 hovers) |
| `hover.cursorToCallback.ms`, mean per second | p50 52.7, max 486 | **p50 4.6**, min 2.6, max 12.7 |
| worst single cursor → callback | **660.7 ms** | **41.6 ms** |
| `hover.applySelection` interval | p50 0.29 ms | 0.21 – 0.23 ms |
| `fps` while sweeping (idle 60) | 5.7 – 55 | **36.0 – 58.9** (p50 46.6) |
| `hitches` per second while sweeping | up to 10 | up to 12 |
| `dropped` frames per second | up to 86 | up to 25 |
| worst frame gap while sweeping | 190 – 1025 ms | 35.6 – 130.5 ms |
| popup first frame, status item click | 163.2 ms median (n=5) | 148.9 ms median (n=5) |
| preview animation | 323.8 ms median (n=6) | 319.5 ms median (n=3) |

The per-second counters confirm the mechanism rather than just the number: inside every window that
has hover activity, `decorator.accessibilityLabel`, `decorator.hasImage`, `historyItem.imageData`,
`decorator.application.lookup` and `nav.isMultiSelectActive.changes` are **absent** — the whole 200-item
item pool is touched zero times during a sweep. `list.row.listItem.body` matches `list.row.body`
exactly (4 per hover), so the 4 rebuilt rows are the selection change itself: the newly selected row,
the previously selected one, and their `previous`/`next` neighbours, which the row reads for
`selectionAppearance`. `colorImage.from` is still called once per rebuilt row but now hits the cache
(`colorImage.cached`), so it costs ~0.03 ms instead of rasterizing.

What is left, and what it is not:

* The remaining ~14 ms of input latency and `fps` 36–59 are no longer a whole-list re-render. Part of it
  is the SwiftUI layout/commit of the 4 rebuilt rows, and each selection change also announces for
  accessibility and calls `preview.startAutoOpen`/`resetAutoOpenSuppression` — that path is the next
  thing to profile (Zone 3), not the row getters.
* Zone 1 and Zone 3 are unchanged, as expected — this change does not touch the first layout or the
  preview animation. The popup medians (163.2 → 148.9 ms) and the preview medians (323.8 → 319.5 ms)
  are within the run-to-run spread of the scenarios above.
* One `hover.cursorToCallback.ms` sample of 49428 ms appeared in the after-run (the first hover event
  delivered to a freshly installed tracking area carries a stale timestamp). It is an artifact of the
  event timestamp, not a stall; the next-worst sample is 41.6 ms.
* A confirmation run (same scenario, after marking the memo fields `@ObservationIgnored` so that
  filling a cache cannot invalidate the row that is reading it) reproduced the ratio exactly:
  68 hovers, 271 row bodies, **3.99 per hover**, still zero derived-value recomputations and no
  "modifying state during view update" messages; `hover.cursorToCallback.ms` p50 9.2 ms (min 2.4,
  max 15.3), `fps` p50 52.4.

## After removing the per-selection tail — announce and auto-open

The previous section left two things on the per-selection path: `announceForAccessibility` and
`preview.startAutoOpen`/`resetAutoOpenSuppression`, both called from `leadHistoryItem.didSet`.
They were profiled first, with signpost intervals around each one (2026-09-12, Debug, the same
200-item store and scenario):

| path | samples | min | p50 | max |
| --- | --- | --- | --- | --- |
| `accessibility.voiceOverCheck` (`NSWorkspace.shared.isVoiceOverEnabled`) | 106 | 0.010 ms | **0.020 ms** | 0.050 ms |
| `nav.announce` (the whole call, check included) | 106 | 0.06 ms | **0.07 ms** | 0.12 ms |
| `preview.autoOpen.start` (guards + `cancelAutoOpen`) | 112 | 0.04 ms | **0.05 ms** | 1.32 ms |
| `preview.autoOpen.cancel` | 116 | 0.00 ms | **0.00 ms** | 0.07 ms |
| `nav.leadHistoryItem.preview` (wrapper around the two above) | 157 | 0.02 ms | **0.07 ms** | 1.36 ms |

The numbers say the same thing twice:

* Both paths are already negligible. VoiceOver is off in this environment, so the announcement text
  is never built — the whole call is one `isVoiceOverEnabled` check at ~20 µs. Auto-open does no
  work when the preview is already on screen (the steady state of a sweep), ~50 µs when it has to
  reschedule the timer.
* The *measurement* cost more than the code: `nav.announce` (70 µs) is ~3.5× its own content
  (voiceOverCheck, 20 µs) — `Perf.measure` is a signpost interval pair plus a formatted metadata
  string. Wrapping per-event work in it distorts exactly what it measures.

So the change was to take the signposts back out of this path and keep the counters:

* `Perf.measure` wrappers removed from `nav.announce`, `nav.leadHistoryItem.preview`,
  `preview.autoOpen.start`, `preview.autoOpen.cancel` and `accessibility.voiceOverCheck`; the
  counters (`accessibility.announce.skipped/posted`, `preview.autoOpen.skipped.*`, `scheduled`,
  `fired`, `cancelled`) stay, so a hover window still shows that the path ran.
* `SlideoutController.startAutoOpen` returns before touching the timer when the preview is already
  open (`state.isOpen`, which includes `.opening`) — the pending-task cancel is skipped, not just
  made cheap. Cancelling still happens before the other guards bail out, so switching
  `openPreviewAutomatically` off mid-sweep cannot leave a scheduled open behind.
* `HistoryItemDecorator.previewText` is cached per item like the other derived values (it decodes
  the stored RTF/HTML representation, and the preview asks for it on every selection change while
  it is open). Counter: `decorator.previewText` vs `decorator.previewText.cached`.

Replayed with the same scenario (status-item click, `move` sweep with `smooth: true` over 20 rows,
preview open and following the cursor):

| metric | previous section | now |
| --- | --- | --- |
| row bodies rebuilt per hover event | 3.98 | **1.98** (85 bodies / 43 hovers) |
| `accessibility.announce.skipped` per hover | — | 0.98 (never `posted`, VoiceOver off) |
| `preview.autoOpen.scheduled` / `cancelled` during the sweep | — | **0 / 0** |
| `preview.autoOpen.skipped.alreadyOpen` per hover | — | 0.67 (undercounted, see caveats) |
| `decorator.previewText` computed vs cached | 1 compute per hover | **9 computes / 27 cache hits** |
| `decorator.hasImage`, `application.lookup`, `accessibilityLabel`, `imageData` | 0 | 0 |
| `hover.cursorToCallback.ms`, mean per second | p50 4.6 ms | **p50 3.2 ms** (min 2.7, max 9.2) |
| `fps` while sweeping | 36.0 – 58.9 | 37.8 – 58.5 (p50 50.3) |
| `hitches` / `dropped` per second | up to 12 / 25 | up to 11 / 23 |
| worst frame gap while sweeping | 35.6 – 130.5 ms | 34.4 – 90.4 ms |

The remaining cost of one hover event is the selection change itself: **2** row bodies (the row
losing the selection and the row gaining it), one `PreviewItemView.body` for the item the preview
now shows, one VoiceOver check and one already-open check on the auto-open timer. Nothing in that
list is work that can be dropped without changing what the popup does — the next thing to look at
is the SwiftUI layout/commit of those two rows, which needs Instruments rather than counters.

## SwiftUI trace (Instruments): what the remaining worst frames are made of

Method: same Debug build and the same 200-item copy, recorded with
`xctrace record --template 'Time Profiler' --instrument 'View Body (Legacy)' --instrument 'os_signpost'
--instrument 'Hangs' --attach <pid>`; one real click on the status item and four 2 s cursor sweeps
(`peekaboo move --at 1150,y --smooth --duration 2000 --steps 60`), recording stopped with `SIGINT`.

The SwiftUI template and the `Hitches` instrument cannot be recorded in this environment, and the
`Animation Hitches` template writes ~175 MB/s during a sweep (13 GB in 75 s), so the hitch *phase*
split (commit / render / GPU) is not available — everything below is CPU-time attribution.

Time Profiler samples only threads that are **running**, so consecutive 1 ms main-thread samples are
one uninterrupted CPU stretch — a “stall”. 42 stalls ≥30 ms were found; they hold **76 %** of the
main-thread CPU of the whole sweep (3396 of 4463 ms).

| trace: stall | CPU | app `frame.stats` in the same second |
| --- | --- | --- |
| 14:34:27.975 — 277 ms | 272 ms | fps 41, hitches 6, dropped 20, worst **110.21 ms** |
| 14:34:19.033 — 237 ms | 233 ms | fps 41, hitches 6, dropped 18, worst **103.18 ms** |
| 14:34:08.050 — 183 ms | 179 ms | fps 25, hitches 9, dropped 35, worst **155.85 ms** |
| 14:34:08.406 — 150 ms | 145 ms | (same second as above) |
| 14:33:57.917 — 125 ms | 123 ms | fps 27.4, hitches 14, dropped 32, worst **103.03 ms** |
| 14:33:36.242 — 172 ms | 167 ms | popup open, not hover |

Per-second CPU correlates exactly with the app's own report: idle seconds are 1–21 ms of CPU at
60 fps, the hover seconds are **67–688 ms** of CPU with fps 25–53 and `worst` 34–156 ms. The worst
frames are simply the seconds in which the main thread never finished draining the event queue.

The stalls are **event-processing** stalls, not render stalls: 88.7 % of all main-thread CPU sits
under `nextEventMatchingMask` / event dispatch and only 1.6 % under the display link.

Leaf-side partition (disjoint, shares sum to 100 %) — whole sweep vs the three worst stalls:

| what burned the CPU | sweep | 277 ms | 237 ms | 183 ms |
| --- | --- | --- | --- | --- |
| SwiftUI / SwiftUICore internals | 25.7 % | 28.3 % | 29.6 % | 30.2 % |
| Swift ARC / objc dispatch | 18.6 % | 21.3 % | 18.0 % | 16.2 % |
| allocation (`malloc`/`free`/`bzero`) | 9.9 % | 10.3 % | 6.4 % | 7.8 % |
| SwiftUI attribute graph | 7.4 % | 4.4 % | 6.0 % | 7.3 % |
| text shaping — CoreText/OTL/TRunGlue | 6.9 % | 8.5 % | 3.4 % | **16.2 %** |
| AppKit / UIFoundation | 5.9 % | 9.6 % | **14.2 %** | 5.6 % |
| Foundation / CF | 6.5 % | 5.9 % | 7.3 % | 4.5 % |
| CoreAnimation / CoreGraphics draw | 4.6 % | 3.7 % | 6.0 % | 3.4 % |
| image decode / resample | 1.9 % | 1.8 % | — | — |
| **our code (`Maccy.debug.dylib`)** | **1.5 %** | **2.2 %** | **2.1 %** | **1.7 %** |

Hottest *self-time* symbols inside the ≥30 ms stalls: `swift_retain` 142 ms, `objc_msgSend` 111,
`swift_release` 100, `mach_msg2_trap` 81, `_platform_bzero` 55, `free_tiny` 53,
`AG::Graph::UpdateStack::update` 53, `AG::Subgraph::update` 51, `AG::Graph::propagate_dirty` 45,
`tiny_malloc_should_clear` 43, `_platform_memmove` 43, `resample_horizontal_avx2` 35,
`__kdebug_trace64` 32, `OTL::GPOS::ApplyPairPosAccelerated` 26. There is **no single hotspot** — the
cost is thousands of small calls spread across SwiftUI's view-graph update, text layout and drawing.

App frames on the stack during the stalls (app entry point excluded): `closure #1 in
NSImage.resized(to:)` 111 ms, `ListItemView.body.getter` witness 26 ms, `LargeTextPreviewView.updateNSView`
23 ms / `makeNSView` 22 ms, `HoverSelectionModifier` closure 21 ms, `HistoryItemView.body` 21 ms,
`HeaderView.body` 21 ms, `Defaults.subscript.getter` 19 ms.

The counters in exactly those seconds name the trigger: `preview.itemView.body` fires **once per
selection change** (13 / 5 / 1 — the same count as `hover.onHover` and `nav.leadHistoryItem.changed`).
While the preview is open, every row crossing re-renders the preview content, and the preview's
`LargeTextPreviewView` (an `NSViewRepresentable` wrapping `NSTextView`) re-lays out its text; that is
why text shaping reaches 16 % in the worst seconds and `NSImage.resized(to:)` shows up at all.

Ranked, the remaining worst frames are: 1. SwiftUI view-graph + layout re-run for the selection
change (26–30 %), 2. ARC/objc + allocation (26 % together, amplified by `-Onone`), 3. the preview
content re-render and its text layout (CoreText up to 16 %, plus UIFoundation and `NSImage.resized`),
4. CoreText shaping of the row titles, 5. drawing (3–8 %). Our own code is ~2 % of it.

Trace-specific caveats:

* Debug build — the ARC/allocation share would shrink under `-O`, so only the *structure* transfers.
* SwiftUI's own frames live in the dyld shared cache and come out unsymbolicated (`0x7ff9…`), so the
  mid-stack path cannot be read; app-level frames and leaf symbols can.
* `View Body (Legacy)` produced only 57 intervals for a 54 s sweep — too sparse to use here.
* The instrumentation itself shows up as `__kdebug_trace64` 32 ms in the stalls (~1 %) — real, but
  two orders of magnitude below the stalls it measures.

## Caveats

* `frame.stats` prints at most ~700 characters of counters, so in a busy second the keys that sort
  last (`preview.*` before `nav.*`) are cut off. The per-hover ratios above therefore undercount the
  `preview.autoOpen.*` counters; the reliable figures are the ones that appear in every window
  (`list.row.body`, `accessibility.announce.skipped`) and the ones that never appear at all
  (`preview.autoOpen.scheduled` / `cancelled` during a sweep with the preview open).
* `startAutoOpen` still schedules a `Task` per selection change while the preview is **closed**
  (`preview.autoOpen.scheduled` 8–17 per second in a closed-preview sweep, cancelled just as
  often), so the timer never fires while the cursor keeps moving. That path is unchanged here.
* The instrumentation is on, which adds one lock + dictionary update per counter (~1000 s⁻¹ in the
  worst second) — measured work, not free, but two orders of magnitude below the observed stalls.
* The single worst frame gaps (≥0.5 s, e.g. `worst=1024.59ms`) are ~10× the rest and always land in
  the second in which the 1 KB `frame.stats` report is written, so they are an upper bound. The
  reproducible part is `fps` 14–40 and 20–86 dropped frames per second.
* Debug build (`-Onone`): release is faster in absolute terms (see the comparison above), but the
  *structure* — whole-list re-renders per hover, 88 % of the open latency outside AppKit — is the
  same.
* Zone 1 was measured with the popup opening at its final size; a short history would exercise the
  animated `verticallyResize` path instead, which this baseline does not cover.
