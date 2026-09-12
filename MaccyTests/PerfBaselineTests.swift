import AppKit
import XCTest
@testable import Maccy

/// Drives the scenario from `docs/performance-profiling.md` in-process, so a baseline can be
/// repeated identically instead of depending on how fast a human sweeps the cursor:
///
///   * opens the popup on a non-empty history that contains image items and hex color titles,
///   * sweeps the selection over 20 rows using the same call the hover modifier makes,
///   * toggles the preview panel open and closed.
///
/// The instrumentation does the measuring; this test only moves the app through the phases and
/// prints a counter delta for each of them (`BASELINE phase=… counters={…}`). Notice-level
/// events are also written to the system log, so the run can be inspected afterwards:
///
///   MACCY_PERF_BASELINE=1 xcodebuild test -only-testing:MaccyTests/PerfBaselineTests \
///     -project Maccy.xcodeproj -scheme Maccy -destination 'platform=macOS'
///   log show --last 5m --predicate 'subsystem == "org.p0deje.Maccy"' |
///     grep -E "popup.open|history.load|preview.toggle|frame.stats"
///
/// Not covered here: the real status item click and AppKit's mouse-moved delivery (`onHover`),
/// which need actual user input — only the selection work they trigger is measured.
final class PerfBaselineTests: XCTestCase {
  private let repetitions = 5
  private let sweepRows = 20
  private let textItems = 180
  private let imageItems = 8
  private let colorItems = 4

  override func tearDown() {
    Perf.setEnabled(nil)
    super.tearDown()
  }

  @MainActor
  func testBaselineScenario() async throws { // swiftlint:disable:this function_body_length
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["MACCY_PERF_BASELINE"] == "1",
      "capture the baseline with MACCY_PERF_BASELINE=1"
    )

    Perf.setEnabled(true)

    let history = History.shared
    let appState = AppState.shared
    let panel = try XCTUnwrap(appState.appDelegate?.panel, "the popup panel is not created")

    let seededAt = Perf.now()
    try seedHistory()
    try await history.load()
    print(
      "BASELINE seed items=\(history.items.count) ms=\(format((Perf.now() - seededAt) * 1000))"
    )
    XCTAssertGreaterThanOrEqual(history.unpinnedItems.count, sweepRows)

    for repetition in 1...repetitions {
      Perf.event("baseline.rep", zone: .popup, "rep=\(repetition)")

      // 1. Open the popup, the same call the status item click ends up in.
      var snapshot = PerfCounters.shared.snapshot()
      let openStartedAt = Perf.now()
      panel.toggle(height: appState.popup.height)
      let openCallMs = (Perf.now() - openStartedAt) * 1000
      await wait(seconds: 0.4)
      print(
        "BASELINE phase=open rep=\(repetition) callMs=\(format(openCallMs)) "
          + "counters=\(describe(since: snapshot))"
      )

      // 2. Sweep 20 rows the way hovering does.
      snapshot = PerfCounters.shared.snapshot()
      let items = Array(history.unpinnedItems.prefix(sweepRows))
      var perRow: [Double] = []
      let sweepStartedAt = Perf.now()
      for item in items {
        let rowStartedAt = Perf.now()
        appState.navigator.selectWithoutScrolling(id: item.id)
        perRow.append((Perf.now() - rowStartedAt) * 1000)
      }
      let sweepMs = (Perf.now() - sweepStartedAt) * 1000
      print(
        "BASELINE phase=sweep rep=\(repetition) rows=\(items.count) totalMs=\(format(sweepMs)) "
          + "medianMs=\(format(median(perRow))) p95Ms=\(format(percentile(perRow, 0.95))) "
          + "maxMs=\(format(perRow.max() ?? 0)) counters=\(describe(since: snapshot))"
      )
      await wait(seconds: 1.05)

      // 3. Toggle the preview on the selected item and back off.
      snapshot = PerfCounters.shared.snapshot()
      let previewStartedAt = Perf.now()
      appState.preview.togglePreview(trigger: .manual)
      let opened = await waitUntil(seconds: 1.5) { appState.preview.state == .open }
      let previewOpenMs = (Perf.now() - previewStartedAt) * 1000
      print(
        "BASELINE phase=previewOpen rep=\(repetition) settled=\(opened) "
          + "ms=\(format(previewOpenMs)) counters=\(describe(since: snapshot))"
      )
      await wait(seconds: 0.4)

      appState.preview.togglePreview(trigger: .manual)
      _ = await waitUntil(seconds: 1.5) { appState.preview.state == .closed }
      await wait(seconds: 0.4)

      panel.close()
      await wait(seconds: 0.1)
    }

    Perf.event("baseline.done", zone: .popup, "repetitions=\(repetitions)")
  }

  // MARK: - Scenario helpers

  @MainActor
  private func seedHistory() throws { // swiftlint:disable:this function_body_length
    let context = Storage.shared.context
    let now = Date()

    // Newest first so the image rows are the ones on screen when the popup opens.
    for index in 0..<imageItems {
      let item = HistoryItem()
      item.application = "com.apple.finder"
      item.title = ""
      item.firstCopiedAt = now
      item.lastCopiedAt = now.addingTimeInterval(-Double(index))
      item.numberOfCopies = 2
      item.contents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.tiff.rawValue,
          value: imageData(index: index)
        )
      ]
      context.insert(item)
    }

    for index in 0..<colorItems {
      let item = HistoryItem()
      item.application = "com.apple.dt.Xcode"
      item.title = String(format: "#%02X%02X%02X", 40 + index * 20, 90, 200 - index * 10)
      item.firstCopiedAt = now
      item.lastCopiedAt = now.addingTimeInterval(-Double(imageItems + index))
      item.contents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: item.title.data(using: .utf8)
        )
      ]
      context.insert(item)
    }

    for index in 0..<textItems {
      let item = HistoryItem()
      item.application = index.isMultiple(of: 3) ? "com.apple.Safari" : "com.apple.Terminal"
      item.title = "baseline clipboard entry \(index) "
        + String(repeating: "lorem ipsum dolor sit amet ", count: 4)
      item.firstCopiedAt = now
      item.lastCopiedAt = now.addingTimeInterval(-Double(imageItems + colorItems + index))
      item.contents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: item.title.data(using: .utf8)
        )
      ]
      context.insert(item)
    }

    try context.save()
  }

  private func imageData(index: Int) -> Data? {
    let size = NSSize(width: 1400, height: 1000)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor(hue: CGFloat(index) / CGFloat(imageItems), saturation: 0.55, brightness: 0.9, alpha: 1)
      .setFill()
    NSRect(origin: .zero, size: size).fill()
    NSColor.white.withAlphaComponent(0.6).setStroke()
    for step in stride(from: 0, to: Int(size.width), by: 50) {
      let path = NSBezierPath()
      path.move(to: NSPoint(x: step, y: 0))
      path.line(to: NSPoint(x: 0, y: step))
      path.stroke()
    }
    image.unlockFocus()
    return image.tiffRepresentation
  }

  private func describe(since snapshot: [String: PerfCounters.Entry]) -> String {
    PerfCounters.describe(PerfCounters.delta(between: snapshot, and: PerfCounters.shared.snapshot()))
  }

  // MARK: - Waiting

  private func wait(seconds: TimeInterval) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
  }

  @discardableResult
  private func waitUntil(seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let deadline = Perf.now() + seconds
    while Perf.now() < deadline {
      if condition() {
        return true
      }
      await wait(seconds: 0.01)
    }
    return condition()
  }

  // MARK: - Small statistics

  private func median(_ values: [Double]) -> Double {
    percentile(values, 0.5)
  }

  private func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))
    return sorted[index]
  }

  private func format(_ value: Double) -> String {
    String(format: "%.2f", value)
  }
}
