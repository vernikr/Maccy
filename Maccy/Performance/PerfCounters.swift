import Foundation

/// Aggregates event counters and durations that are flushed once a second by
/// `PerfFrameMonitor`, so a single timing line describes everything that happened
/// inside one second of interaction.
///
/// Access is guarded by a lock because some instrumented getters can run off the main
/// thread. Callers are expected to be gated by `Perf.isEnabled` already.
final class PerfCounters: @unchecked Sendable {
  static let shared = PerfCounters()

  struct Entry {
    var calls = 0
    var sum = 0
    var totalMilliseconds: Double = 0
    var maximumMilliseconds: Double = 0

    var description: String {
      var parts = ["calls=\(calls)"]
      if sum != calls {
        parts.append("sum=\(sum)")
      }
      if totalMilliseconds > 0 {
        parts.append(String(format: "total=%.2fms", totalMilliseconds))
        parts.append(String(format: "max=%.2fms", maximumMilliseconds))
      }
      return parts.joined(separator: " ")
    }
  }

  /// Timestamp of the last mouse-moved event, used by `Perf.mouseMoveLatencyMilliseconds()`.
  private var _lastMouseMoveTimestamp: TimeInterval?

  private var entries: [String: Entry] = [:]
  private let lock = NSLock()

  private init() {}

  var lastMouseMoveTimestamp: TimeInterval? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _lastMouseMoveTimestamp
    }
    set {
      lock.lock()
      _lastMouseMoveTimestamp = newValue
      lock.unlock()
    }
  }

  func count(_ key: String, _ value: Int = 1) {
    lock.lock()
    defer { lock.unlock() }

    var entry = entries[key] ?? Entry()
    entry.calls += 1
    entry.sum += value
    entries[key] = entry
  }

  func recordMilliseconds(_ key: String, _ milliseconds: Double) {
    lock.lock()
    defer { lock.unlock() }

    var entry = entries[key] ?? Entry()
    entry.calls += 1
    entry.sum += 1
    entry.totalMilliseconds += milliseconds
    entry.maximumMilliseconds = max(entry.maximumMilliseconds, milliseconds)
    entries[key] = entry
  }

  /// Returns the collected counters sorted by key and clears them.
  func flush() -> [String: Entry] {
    lock.lock()
    defer { lock.unlock() }

    let snapshot = entries
    entries.removeAll(keepingCapacity: true)
    return snapshot
  }

  func reset() {
    lock.lock()
    defer { lock.unlock() }
    entries.removeAll(keepingCapacity: true)
  }

  /// Formats counters as `key[calls=… total=…ms]` joined by `; `, trimmed to `limit` characters.
  static func describe(_ counters: [String: Entry], limit: Int = 700) -> String {
    var text = ""
    for key in counters.keys.sorted() {
      guard let entry = counters[key] else { continue }
      let part = "\(key)[\(entry.description)]"
      if text.count + part.count + 2 > limit {
        text += "; …"
        break
      }
      text += text.isEmpty ? part : "; \(part)"
    }
    return text
  }
}
