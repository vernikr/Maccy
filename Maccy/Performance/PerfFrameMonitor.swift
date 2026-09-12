import AppKit
import QuartzCore

/// Samples the display link while the popup is visible.
///
/// Once a second it reports frames, hitches, dropped frames and the worst frame gap together
/// with the counters collected in the same window, so a stall can be attributed to the code
/// that ran inside it. It also reports the very first ticked frame, which is used by
/// `PopupOpenProbe` as evidence that the popup actually got composited.
final class PerfFrameMonitor {
  static let shared = PerfFrameMonitor()

  /// Called once per `start(on:)` when the first frame ticked.
  var onFirstFrame: (() -> Void)?

  private var link: CADisplayLink?
  private var lastTick: CFTimeInterval = 0
  private var windowStart: CFTimeInterval = 0
  private var frames = 0
  private var hitches = 0
  private var dropped = 0
  private var worstGap: CFTimeInterval = 0
  private var didReportFirstFrame = false

  private init() {}

  var isRunning: Bool { link != nil }

  /// Creates and discards a display link once, before the popup is ever opened.
  ///
  /// CoreAnimation creates a process-wide `CADisplay` on the first display link of a display, and
  /// that call enumerates every display mode of the screen: the cold-open trace shows 69 ms of a
  /// 197 ms first-open stall inside `-[CADisplay _initWithDisplay:] → SLSIsDisplayModeVRR`. Left
  /// alone it lands inside the first `start(on:)`, i.e. inside the first open, and inflates the
  /// very number the probe reports. Nothing to do for real users: instrumentation is off there.
  func warmUp(on view: NSView) {
    guard Perf.isEnabled, link == nil else { return }
    view.displayLink(target: self, selector: #selector(tick(_:))).invalidate()
  }

  /// Starts sampling on the given view, e.g. the hosting view of the popup.
  func start(on view: NSView) {
    guard Perf.isEnabled, link == nil else { return }

    let link = view.displayLink(target: self, selector: #selector(tick(_:)))
    link.add(to: .main, forMode: .common)
    self.link = link

    lastTick = 0
    windowStart = CACurrentMediaTime()
    frames = 0
    hitches = 0
    dropped = 0
    worstGap = 0
    didReportFirstFrame = false
  }

  func stop() {
    link?.invalidate()
    link = nil
    onFirstFrame = nil
  }

  @objc
  private func tick(_ link: CADisplayLink) { // swiftlint:disable:this cyclomatic_complexity
    let timestamp = link.timestamp
    let expected = max(link.targetTimestamp - link.timestamp, 1.0 / 120.0)

    if lastTick > 0 {
      let gap = timestamp - lastTick
      worstGap = max(worstGap, gap)
      if gap > expected * 1.5 {
        hitches += 1
        dropped += max(Int((gap / expected).rounded()) - 1, 1)
      }
    }

    lastTick = timestamp
    frames += 1

    if !didReportFirstFrame {
      didReportFirstFrame = true
      onFirstFrame?()
    }

    let elapsed = timestamp - windowStart
    guard elapsed >= 1.0 else { return }

    report(elapsed: elapsed)
    windowStart = timestamp
    frames = 0
    hitches = 0
    dropped = 0
    worstGap = 0
  }

  private func report(elapsed: CFTimeInterval) {
    let counters = PerfCounters.shared.flush()
    let summary = String(
      format: "fps=%.1f frames=%d hitches=%d dropped=%d worst=%.2fms",
      Double(frames) / elapsed,
      frames,
      hitches,
      dropped,
      worstGap * 1000
    )

    Perf.event("frame.stats", zone: .frames, "\(summary) counters={\(PerfCounters.describe(counters))}")
  }
}
