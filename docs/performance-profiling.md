# Profiling the popup, hover selection and preview animation

Maccy ships with `os_signpost` instrumentation for the three interactions that are
perceived as latency-sensitive:

1. opening the popup from the status bar icon or the keyboard shortcut,
2. hovering the history rows,
3. animating the preview panel in and out.

The instrumentation lives in `Maccy/Performance` and is disabled unless explicitly enabled,
so it can stay in release builds. Disabled it costs a single boolean check per hook.

## Enabling

Any of these enables signposts (the flag is read once, at startup):

```sh
MACCY_PERF=1 /Applications/Maccy.app/Contents/MacOS/Maccy     # per launch
defaults write org.p0deje.Maccy perfSignposts -bool YES       # persists
```

`MACCY_PERF=0|false|no|off` and `perfSignposts = false` keep it off. `perfSignposts` is
deliberately not exposed in the settings UI.

Add `MACCY_PERF_VERBOSE=1` to also write every individual interval/event as a debug log line
(noisy, useful when reading the log instead of Instruments).

Turn it off again:

```sh
defaults delete org.p0deje.Maccy perfSignposts
```

## Reading the data

Signposts are emitted on the `PointsOfInterest` category of the `org.p0deje.Maccy` subsystem,
so every interval shows up in the Instruments **Points of Interest** track. The zone is part of
the metadata (`zone=popup|hover|preview|frames`).

```sh
# text output (signposts as `type: signpost`, zone summaries as notice lines)
log stream --predicate 'subsystem == "org.p0deje.Maccy"' --level debug

# Instruments, live, with the Points of Interest track
scripts/perf.sh record /tmp/maccy-perf.trace 30

# or manually
xcrun xctrace record --template 'Points of Interest' \
  --launch /path/to/Maccy.app --time-limit 30s --output /tmp/maccy-perf.trace
```

Useful Instruments tracks alongside Points of Interest: **Time Profiler** (where main-thread
time goes), **SwiftUI** (view body evaluations, which correlates with the `*.body` counters),
**Animation Hitches** and **Hangs** (macOS 14+).

`scripts/perf.sh` wraps the common cases: `on`, `off`, `status`, `stream`, `validate`, `preflight`,
`record`, `build`. `validate` runs `scripts/validate-pbxproj.py`, and `build` runs `preflight`
(the validator plus a placeholder-token check) before calling `xcodebuild`, so project-reference
mistakes fail loudly instead of turning into a build that appears to succeed silently.

## Zone 1 — opening the popup

Latency is measured from the user action to the first frame that the display link ticked,
which is the closest available signal to "the user sees the popup".

| Signpost | Meaning |
| --- | --- |
| `popup.open.begin` | Trigger fired (`source=statusItem\|shortcut\|panel.open`). |
| `popup.open.setContentSize` | Window resized to the requested height before ordering front. |
| `popup.open.setFrameOrigin` | Window positioned (`PopupPosition.origin`). |
| `popup.open.orderFrontRegardless` | Cost of ordering the window front. |
| `popup.open.makeKey` | Cost of making the panel key. |
| `popup.open.becameKey` | Time from the trigger until `windowDidBecomeKey`. |
| `popup.open.displayLinkMonitor` | Creating the frame monitor's display link (0.1–0.2 ms once it is warmed up). |
| `popup.open.firstFrame` | **Total** trigger → first presented frame, plus every step and note. |
| `popup.open.cancelled` | The popup was closed before the first frame (e.g. toggle-off). |
| `popup.prewarm` | One-shot, ~1 s after launch: the hidden popup is built, laid out, presented offscreen and made key, so the first open does not pay for any of it. Reports `layout`/`present`/`displayLink` durations, `keyWarmed` and what it built (`layoutBuilt`, `presentBuilt`). |
| `history.load` | One-shot: fetch/decorate durations and item count. |

Notes attached to `popup.open.firstFrame`:

- `size=WxH` — the size the window was opened with,
- `items=N` — how many history items existed at that moment (0 means `history.load()` was
  interleaved with this open),
- `wasVisible=false` means the window had to be laid out from scratch,
- `prewarmed=true` means `FloatingPanel.prewarm()` already built the tree before this open.

Counters in the same window (`popup.verticalResize`, `popup.verticalResize.beforeFirstFrame`,
`list.row.appear`, `list.row.body`, `history.pinnedItems`, `decorator.thumbnailImage.ms`)
attribute the latency to the resize-after-open, the row count, the `pinnedItems`/`unpinnedItems`
filter storm and the thumbnail generation.

Two traps in this zone, both about the measurement rather than the app:

- **The first display link of the process costs 62–70 ms inside the first open.** CoreAnimation
  answers the first `CADisplayLink` of a display by enumerating every display mode
  (`-[CADisplay _initWithDisplay:] → SLSIsDisplayModeVRR`, vectors of `CGSDisplayMode`). With
  instrumentation on, that landed inside `popup.open.firstFrame` and was ~40 % of the cold-open
  number. `PerfFrameMonitor.warmUp(on:)` moves it to `popup.prewarm`; without it, do not read a
  cold `popup.open.firstFrame` as user-visible latency.
- **Do not use the coordinate click on the status item as the trigger.** It lands only sometimes
  (`AGENTS.md`, rule 20), and a retry loop can warm the very thing being measured. Reopening the
  app is deterministic: `open -a .build/Build/Products/Debug/Maccy.app` on a running instance
  reaches `applicationShouldHandleReopen` → `panel.toggle` → `source=panel.open`, 4 runs out of 4.
  It activates the app first, so part of the activation cost falls outside the measured interval —
  compare builds with the same trigger, not with the older click-based table.

## Zone 2 — hover selection

| Signpost | Meaning |
| --- | --- |
| `hover.applySelection` | Applying the selection (`selectWithoutScrolling`) took this long. |
| `hover.select` | Same call, measured inside `NavigationManager`. |

Counters: `hover.onHover` (rows that received the hover callback), `hover.mouseMoved` (events per
second), `hover.cursorToCallback.ms` (milliseconds between the mouse-moved event timestamp and the
hover callback — the part that is pure AppKit/SwiftUI delivery), `hover.select.scannedItems` (how
many items the linear id lookup walks), `nav.isKeyboardNavigating.writes` vs `.noopWrites` (writes
that did not change the value), `nav.isMultiSelectActive.changes` vs `.noopWrites` (the flag every
row body reads — a `.changes` in a hover window means the rows were invalidated),
`nav.leadHistoryItem.changed/unchanged`, `decorator.accessibilityLabel`,
`decorator.application.lookup`, `colorImage.from` vs `colorImage.cached`,
`decorator.previewText` vs `decorator.previewText.cached`,
`historyItem.imageData` vs `historyItem.imageData.cached`, `accessibility.announce.skipped` vs
`.posted`, `preview.autoOpen.skipped.*` / `.scheduled` / `.fired` / `.cancelled`
and the `list.row.body` / `list.row.listItem.body` re-evaluations. Together they show whether the
lag is delivery, state propagation or per-row work.

Everything that runs on **every** selection change is deliberately counter-only, without a
`Perf.measure` interval: the signpost pair plus its formatted metadata costs ~50–70 µs, which is
more than the code it would measure (`NSWorkspace.shared.isVoiceOverEnabled` is ~20 µs, the whole
announce call ~70 µs, `startAutoOpen` with an open preview ~50 µs — see
[performance-baseline.md](performance-baseline.md)). Adding a wrapper there measures the
instrumentation, not the app.

The decisive ratio is `list.row.body / hover.onHover` inside one `frame.stats` window: it is the
number of rows one hover costs. An **empty** `frame.stats`-window counter set for
`decorator.accessibilityLabel`, `decorator.hasImage`, `historyItem.imageData` and
`decorator.application.lookup` is the point, not a measurement failure — in a healthy run the
derived values are resolved on first layout and never again during a sweep.

## Zone 3 — preview animation

| Signpost | Meaning |
| --- | --- |
| `preview.toggle.begin` / `.end` | The full open/close animation, with `trigger`, `placement` and resulting `state`. |
| `preview.toggle` | Same interval, named for slicing in Instruments. |
| `decorator.previewImage` | Building the downscaled preview image (on the main actor). |
| `decorator.asyncGetPreviewImage` | Waiting for that image when the preview appears. |
| `preview.largeText.make` | Constructing the `NSTextView` for a large text preview. |
| `historyItem.htmlParse` / `historyItem.rtfParse` | Parsing rich text into `previewableText`. |
| `preview.layout` / `preview.layout.animating` | `SlideoutView` body evaluations, split by whether an animation is running. |

Counters to watch during the animation: `preview.swiftuiAnimation.ms` (the SwiftUI animation
completion, which can drift from the AppKit window animation), `preview.itemView.body`,
`preview.slideoutView.body`, `preview.autoOpen.scheduled/fired/cancelled`, and — most importantly
— the `frame.stats` line of the second the animation happened in. While the slideout is closed it
is not built at all (`SlideoutView` skips the content), so an empty `preview.itemView.body` there
is expected rather than a sign that the preview failed to render.

## Frame statistics

While the popup is visible a display link samples frames and once a second emits:

```
frame.stats zone=frames fps=59.8 frames=60 hitches=2 dropped=3 worst=41.20ms counters={…}
```

`counters={…}` is everything aggregated in that same second, so a hitch can be tied to the code
that ran in it (e.g. 40 `list.row.body` evaluations and 12 `colorImage.from` calls in one frame).
It is trimmed to ~700 characters, so in a busy second the keys that sort last (`preview.*` sits
after `nav.*`) are missing from the line. An absent counter in one window therefore means
"truncated or absent", not automatically "did not run" — which is why the comparison procedure
below is about ratios that survive every window (`list.row.body / hover.onHover`) and about
counters that should be missing (`preview.autoOpen.scheduled` during a sweep with an open preview).

The monitor only runs while the popup is open (started in `FloatingPanel.open`, stopped in
`close`), so counters are flushed roughly once a second during the interaction and once more on
close. Counters accumulate in the last partial second otherwise.

## How to compare before/after a change

1. Enable instrumentation and reproduce the same scenario three times: open the popup with a
   non-empty history (ideally with image items), sweep the cursor down 20 rows, then let the
   preview auto-open.
2. Record the signpost log and the trace, keeping the median of the three runs, not the best one.
3. Compare `popup.open.firstFrame > ms`, `hover.cursorToCallback.ms > total`, the per-frame
   `fps/hitches/worst`, and the counter set of the worst second.
4. Only then change code, and re-measure with the same scenario.

The numbers to beat, and the exact live-GUI procedure behind them, are in
[performance-baseline.md](performance-baseline.md).

### Running the real thing without touching the user's history

The Debug build is not sandboxed, so it keeps its store in `~/Library/Application Support/Maccy/`
and never collides with an installed `/Applications/Maccy.app`. To profile against realistic data
anyway, copy a store and point the app at it:

```bash
sqlite3 "file:$HOME/Library/Containers/org.p0deje.Maccy/Data/Library/Application\
 Support/Maccy/Storage.sqlite?mode=ro" ".backup /tmp/maccy-baseline/Storage.sqlite"

open -n -g -a .build/Build/Products/Debug/Maccy.app \
  --env MACCY_PERF=1 --env MACCY_PERF_VERBOSE=1 \
  --env MACCY_STORAGE_PATH=/tmp/maccy-baseline/Storage.sqlite --args enable-testing
```

`MACCY_STORAGE_PATH` is only honoured together with `enable-testing` (see `Storage.init`), which
also moves preferences into a throwaway suite and turns off update checks. Drive the popup with
`⌘⇧C` or by clicking the status item, and move the real cursor across the rows — AppleScript and
AX presses do not produce `mouseMoved` events, so hover has to come from a physical pointer.
Peekaboo MCP does move the real pointer: `click` with `foreground: true` on the status item, then
`move` with `smooth: true` + `duration` + `steps` (without `smooth` the tool teleports the cursor in
0.00 s and nothing hovers). Its `see` output is also the quickest way to get the row geometry:
first row at `y=59`, then every `Popup.itemHeight` (22 pt) down.

## Instruments (xctrace)

`xctrace` cannot record the `SwiftUI` template or the `Hitches` instrument in this environment
(`Failed starting ktrace session`; adding `Hitches` segfaults `xctrace`), and the `Animation Hitches`
template writes ~175 MB/s during a live sweep (13 GB in 75 s), so it is unusable here. A working,
cheap recipe — record and drive the sweep from the same shell command, and stop with `SIGINT`
instead of waiting for the time limit:

```bash
xcrun xctrace record --template 'Time Profiler' \
  --instrument 'View Body (Legacy)' --instrument 'os_signpost' --instrument 'Hangs' \
  --attach "$PID" --time-limit 90s --output /tmp/sweep.trace --no-prompt &
REC=$!
# … click the status item, sweep the cursor over the rows …
kill -INT "$REC"; wait "$REC"
```

```bash
xcrun xctrace export --input /tmp/sweep.trace --toc            # which schemas the run has
xcrun xctrace export --input /tmp/sweep.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > /tmp/tp.xml
```

Time Profiler samples **only threads that are running**, so consecutive 1 ms samples on the main
thread are one uninterrupted CPU stretch — the stall itself. Grouping the main thread's samples into
such bursts hands you the worst frames without guessing from `frame.stats`, and the leaf symbol of
each sample says what they were made of. Two parsing traps: `time-profile` and
`swiftui-body-interval` timestamps are nanoseconds from the start of the run, and the export
deduplicates frames and backtraces through `ref=` attributes that must be resolved — without that
~31 % of the leaves are lost and the diagnosis shifts to the callers. Frames from the dyld shared
cache often come out unsymbolicated (`0x7ff9…`).

A worked example, with numbers, is the “SwiftUI trace (Instruments)” section of
`docs/performance-baseline.md`.

## Caveats

- `popup.open.firstFrame` is a lower bound: it is the first ticked frame, not the moment the
  WindowServer finished compositing it.
- `NSImage(data:)` and `NSImage.resized(to:)` are lazy — the decode and the scaling interpolation
  happen on the first draw, i.e. inside a frame. The `decorator.*Image` measurements only cover
  construction; the real cost shows up as `frame.stats` hitches.
- Debug-level log lines are only captured with `--level debug`; signpost events are visible at the
  default level.
- `history.search` includes the 200 ms `Throttler` delay by design, so its duration is not pure
  search cost.
