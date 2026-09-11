import Foundation

/// Measures the latency of one popup open: from the user action (status item click or
/// keyboard shortcut) to the first frame the display link ticked, plus the AppKit steps taken
/// in between and the state observed while opening.
///
/// Sub-steps are emitted as individual signposts and the total is reported once as
/// `popup.open.firstFrame`, so both the aggregate number and its breakdown are available.
final class PopupOpenProbe {
  static let shared = PopupOpenProbe()

  private struct Session {
    let source: String
    let startedAt: TimeInterval
    var steps: [String] = []
    var notes: [String] = []
  }

  private var session: Session?

  /// True while an open is being measured and no frame has been presented yet.
  var isActive: Bool { session != nil }

  /// Starts measuring, unless a session is already running (e.g. triggered from the shortcut).
  func begin(source: String) {
    guard Perf.isEnabled, session == nil else { return }

    session = Session(source: source, startedAt: Perf.now())
    Perf.event("popup.open.begin", zone: .popup, "source=\(source)")
  }

  /// Records the duration of a step that started at `startedAt`.
  func step(_ name: StaticString, since startedAt: TimeInterval) {
    guard session != nil else { return }

    let milliseconds = (Perf.now() - startedAt) * 1000
    session?.steps.append("\(String(describing: name))=\(String(format: "%.2f", milliseconds))ms")
    Perf.event(name, zone: .popup, "ms=\(String(format: "%.2f", milliseconds))")
  }

  /// Records the duration of a named step measured elsewhere.
  func step(_ name: StaticString, milliseconds: Double) {
    guard session != nil else { return }

    session?.steps.append("\(String(describing: name))=\(String(format: "%.2f", milliseconds))ms")
  }

  /// Records how long ago the current session started, e.g. when the window became key.
  func stepSinceStart(_ name: StaticString) {
    guard let session else { return }
    step(name, milliseconds: (Perf.now() - session.startedAt) * 1000)
  }

  /// Attaches a fact about the state observed while opening, e.g. the rendered row count.
  func note(_ text: String) {
    guard session != nil else { return }
    session?.notes.append(text)
  }

  /// Called by `PerfFrameMonitor` when the first frame of the just opened popup was presented.
  func framePresented() {
    guard let session else { return }

    let milliseconds = (Perf.now() - session.startedAt) * 1000
    let metadata = [
      "source=\(session.source)",
      "ms=\(String(format: "%.2f", milliseconds))",
      session.steps.isEmpty ? nil : "steps=[\(session.steps.joined(separator: " "))]",
      session.notes.isEmpty ? nil : "notes=[\(session.notes.joined(separator: " "))]"
    ].compactMap { $0 }.joined(separator: " ")

    PerfCounters.shared.recordMilliseconds("popup.open.firstFrame.ms", milliseconds)
    Perf.event("popup.open.firstFrame", zone: .popup, metadata)
    self.session = nil
  }

  /// Aborts the current session, e.g. because the popup was closed again.
  func cancel(reason: String) {
    guard let session else { return }

    Perf.event("popup.open.cancelled", zone: .popup, "reason=\(reason) source=\(session.source)")
    self.session = nil
  }
}
