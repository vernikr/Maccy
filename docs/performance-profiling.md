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
| `popup.open.firstFrame` | **Total** trigger → first presented frame, plus every step and note. |
| `popup.open.cancelled` | The popup was closed before the first frame (e.g. toggle-off). |
| `history.load` | One-shot: fetch/decorate durations and item count. |

Notes attached to `popup.open.firstFrame`:

- `size=WxH` — the size the window was opened with,
- `items=N` — how many history items existed at that moment (0 means `history.load()` was
  interleaved with this open),
- `wasVisible=false` means the window had to be laid out from scratch.

Counters in the same window (`popup.verticalResize`, `popup.verticalResize.beforeFirstFrame`,
`list.row.appear`, `list.row.body`, `history.pinnedItems`, `decorator.thumbnailImage.ms`)
attribute the latency to the resize-after-open, the row count, the `pinnedItems`/`unpinnedItems`
filter storm and the thumbnail generation.

## Zone 2 — hover selection

| Signpost | Meaning |
| --- | --- |
| `hover.onHover` | The row received the hover callback. |
| `hover.applySelection` | Applying the selection (`selectWithoutScrolling`) took this long. |
| `hover.select` | Same call, measured inside `NavigationManager`. |
| `hover.cursorToCallback.ms` | Counter: milliseconds between the mouse-moved event timestamp and the hover callback — the part that is pure AppKit/SwiftUI delivery. |

Counters: `hover.mouseMoved` (events per second), `hover.select.scannedItems` (how many items
the linear id lookup walks), `nav.isKeyboardNavigating.writes` vs `.noopWrites` (writes that did
not change the value), `nav.leadHistoryItem.changed/unchanged`, `decorator.accessibilityLabel`,
`decorator.application.lookup`, `colorImage.from`, `decorator.previewText`, `historyItem.image*`
and the `list.row.body` / `list.row.listItem.body` re-evaluations. Together they show whether the
lag is delivery, state propagation or per-row work.

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
— the `frame.stats` line of the second the animation happened in.

## Frame statistics

While the popup is visible a display link samples frames and once a second emits:

```
frame.stats zone=frames fps=59.8 frames=60 hitches=2 dropped=3 worst=41.20ms counters={…}
```

`counters={…}` is everything aggregated in that same second, so a hitch can be tied to the code
that ran in it (e.g. 40 `list.row.body` evaluations and 12 `colorImage.from` calls in one frame).

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
