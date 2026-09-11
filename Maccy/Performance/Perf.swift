import Defaults
import Foundation
import os

/// Signpost-based instrumentation for the popup, hover selection and preview animation.
///
/// Everything is gated by `Perf.isEnabled`, which is resolved once from the `MACCY_PERF`
/// environment variable or the `perfSignposts` preference, so the instrumentation can stay
/// in release builds and costs a single flag check when it is off.
///
/// Intervals and events are emitted on the `PointsOfInterest` category so they show up in the
/// Instruments "Points of Interest" track; the zone is passed as `zone=` metadata. Text lines
/// go to the `org.p0deje.Maccy` logger under a per-zone category and can be tailed with
/// `log stream --predicate 'subsystem == "org.p0deje.Maccy"' --level debug`.
enum Perf {
  /// Instrumentation zones. Also used as the logger category.
  enum Zone: String {
    case popup
    case hover
    case preview
    case frames
  }

  static let subsystem = "org.p0deje.Maccy"

  /// `MACCY_PERF=0|false|no|off` disables instrumentation, any other value enables it.
  /// Without the environment variable the `perfSignposts` preference is used.
  private static let resolvedEnabled: Bool = {
    if let raw = ProcessInfo.processInfo.environment["MACCY_PERF"]?.lowercased() {
      return !["", "0", "false", "no", "off"].contains(raw)
    }
    return Defaults[.perfSignposts]
  }()

  private static var overrideEnabled: Bool?

  /// Whether instrumentation is currently collecting data.
  static var isEnabled: Bool { overrideEnabled ?? resolvedEnabled }

  /// Forces instrumentation on or off regardless of the environment; nil restores the
  /// resolved value. Used by tests and available from the debugger.
  static func setEnabled(_ enabled: Bool?) {
    overrideEnabled = enabled
  }

  /// Verbose per-call lines are opt-in to keep the log readable.
  static let isVerbose: Bool = {
    guard let raw = ProcessInfo.processInfo.environment["MACCY_PERF_VERBOSE"]?.lowercased() else {
      return false
    }
    return !["", "0", "false", "no", "off"].contains(raw)
  }()

  private static let signposter = OSSignposter(subsystem: subsystem, category: "PointsOfInterest")

  private static let loggers: [Zone: Logger] = [
    .popup: Logger(subsystem: subsystem, category: Zone.popup.rawValue),
    .hover: Logger(subsystem: subsystem, category: Zone.hover.rawValue),
    .preview: Logger(subsystem: subsystem, category: Zone.preview.rawValue),
    .frames: Logger(subsystem: subsystem, category: Zone.frames.rawValue)
  ]

  static func logger(_ zone: Zone) -> Logger {
    loggers[zone] ?? Logger(subsystem: subsystem, category: zone.rawValue)
  }

  /// Monotonic clock shared with `NSEvent.timestamp`, so hover latencies can be derived
  /// from the timestamp of the event that triggered them.
  @inline(__always)
  static func now() -> TimeInterval {
    ProcessInfo.processInfo.systemUptime
  }

  static func milliseconds(_ seconds: TimeInterval) -> String {
    String(format: "%.2f", seconds * 1000)
  }

  static func metadata(zone: Zone, _ extra: String = "") -> String {
    extra.isEmpty ? "zone=\(zone.rawValue)" : "zone=\(zone.rawValue) \(extra)"
  }

  // MARK: - Intervals

  /// Starts a signpost interval. Returns nil when instrumentation is disabled.
  @inline(__always)
  static func begin(_ name: StaticString, zone: Zone) -> PerfInterval? {
    guard isEnabled else { return nil }
    let state = signposter.beginInterval(name, "\(metadata(zone: zone), privacy: .public)")
    return PerfInterval(
      signposter: signposter,
      state: state,
      name: name,
      zone: zone,
      startedAt: now()
    )
  }

  /// Measures a closure and emits a signpost interval with its duration.
  @inline(__always)
  static func measure<T>(_ name: StaticString, zone: Zone, _ body: () throws -> T) rethrows -> T {
    guard isEnabled else { return try body() }

    let state = signposter.beginInterval(name, "\(metadata(zone: zone), privacy: .public)")
    let startedAt = now()

    defer {
      let text = metadata(zone: zone, "ms=\(milliseconds(now() - startedAt))")
      signposter.endInterval(name, state, "\(text, privacy: .public)")
      logMicro(name, zone: zone, text)
    }

    return try body()
  }

  // MARK: - Events

  /// One-shot marker: session summaries, mode changes, first frames.
  @inline(__always)
  static func event(_ name: StaticString, zone: Zone, _ extra: String = "") {
    guard isEnabled else { return }

    let text = metadata(zone: zone, extra)
    signposter.emitEvent(name, "\(text, privacy: .public)")
    logger(zone).notice("\(String(describing: name), privacy: .public) \(text, privacy: .public)")
  }

  private static func logMicro(_ name: StaticString, zone: Zone, _ text: String) {
    guard isVerbose else { return }
    logger(zone).debug("\(String(describing: name), privacy: .public) \(text, privacy: .public)")
  }

  // MARK: - Counters

  /// Counts calls to a hot code path.
  @inline(__always)
  static func count(_ key: String, _ value: Int = 1) {
    guard isEnabled else { return }
    PerfCounters.shared.count(key, value)
  }

  /// Records a duration measured elsewhere.
  @inline(__always)
  static func record(_ key: String, milliseconds: Double) {
    guard isEnabled else { return }
    PerfCounters.shared.recordMilliseconds(key, milliseconds)
  }

  /// Counts calls and records their total duration under `key` and `key.ms`.
  @inline(__always)
  static func counted<T>(_ key: String, _ body: () throws -> T) rethrows -> T {
    guard isEnabled else { return try body() }

    PerfCounters.shared.count(key)
    let startedAt = now()
    defer { PerfCounters.shared.recordMilliseconds("\(key).ms", (now() - startedAt) * 1000) }
    return try body()
  }

  // MARK: - Hover clock

  /// Remembers the timestamp of a mouse-moved event so the delay between the cursor
  /// reaching a row and the selection being applied can be measured.
  @inline(__always)
  static func noteMouseMoved(timestamp: TimeInterval) {
    guard isEnabled else { return }
    PerfCounters.shared.count("hover.mouseMoved")
    PerfCounters.shared.lastMouseMoveTimestamp = timestamp
  }

  /// Milliseconds since the last mouse-moved event, or nil when it is unknown.
  @inline(__always)
  static func mouseMoveLatencyMilliseconds() -> Double? {
    guard isEnabled, let timestamp = PerfCounters.shared.lastMouseMoveTimestamp else {
      return nil
    }

    let latency = (now() - timestamp) * 1000
    return latency >= 0 ? latency : nil
  }
}

/// A running signpost interval. `end()` returns the measured duration in milliseconds.
struct PerfInterval {
  fileprivate let signposter: OSSignposter
  fileprivate let state: OSSignpostIntervalState
  fileprivate let name: StaticString
  fileprivate let zone: Perf.Zone
  fileprivate let startedAt: TimeInterval

  /// Ends the interval. `extra` is appended to the signpost metadata, e.g. `source=statusItem`.
  @discardableResult
  func end(_ extra: String = "") -> Double {
    let elapsed = Perf.now() - startedAt
    let text = Perf.metadata(zone: zone, extra.isEmpty ? "ms=\(Perf.milliseconds(elapsed))"
      : "ms=\(Perf.milliseconds(elapsed)) \(extra)")

    signposter.endInterval(name, state, "\(text, privacy: .public)")
    return elapsed * 1000
  }
}
