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

## Caveats

* The instrumentation is on, which adds one lock + dictionary update per counter (~1000 s⁻¹ in the
  worst second) — measured work, not free, but two orders of magnitude below the observed stalls.
* The single worst frame gaps (≥0.5 s, e.g. `worst=1024.59ms`) are ~10× the rest and always land in
  the second in which the 1 KB `frame.stats` report is written, so they are an upper bound. The
  reproducible part is `fps` 14–40 and 20–86 dropped frames per second.
* Debug build (`-Onone`): release will be faster in absolute terms, but the *ratios* — 57 rows per
  hover, 88 % of the open latency outside AppKit — are structural.
* Zone 1 was measured with the popup opening at its final size; a short history would exercise the
  animated `verticallyResize` path instead, which this baseline does not cover.
