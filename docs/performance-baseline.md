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
