import AppKit
import XCTest
@testable import Maccy

/// Guards the instrumentation harness itself: it must collect nothing when disabled and
/// aggregate counts, sums and durations when enabled.
final class PerfInstrumentationTests: XCTestCase {
  override func setUp() {
    super.setUp()
    PerfCounters.shared.reset()
    PopupOpenProbe.shared.cancel(reason: "test-setup")
  }

  override func tearDown() {
    Perf.setEnabled(nil)
    PerfCounters.shared.reset()
    PopupOpenProbe.shared.cancel(reason: "test-teardown")
    super.tearDown()
  }

  func testDisabledInstrumentationCollectsNothing() {
    Perf.setEnabled(false)

    XCTAssertNil(Perf.begin("perf.test.interval", zone: .popup))
    Perf.count("perf.test.counter")
    Perf.record("perf.test.duration.ms", milliseconds: 5)
    _ = Perf.measure("perf.test.measure", zone: .popup) { 1 }
    _ = Perf.counted("perf.test.counted") { 1 }
    Perf.noteMouseMoved(timestamp: Perf.now())

    XCTAssertTrue(PerfCounters.shared.flush().isEmpty)
    XCTAssertNil(Perf.mouseMoveLatencyMilliseconds())
  }

  func testCountersAggregateCallsSumsAndDurations() {
    Perf.setEnabled(true)

    Perf.count("perf.test.scanned", 7)
    Perf.count("perf.test.scanned", 3)
    Perf.record("perf.test.duration.ms", milliseconds: 4)
    Perf.record("perf.test.duration.ms", milliseconds: 10)

    let counters = PerfCounters.shared.flush()
    XCTAssertEqual(counters["perf.test.scanned"]?.calls, 2)
    XCTAssertEqual(counters["perf.test.scanned"]?.sum, 10)
    XCTAssertEqual(counters["perf.test.duration.ms"]?.calls, 2)
    XCTAssertEqual(counters["perf.test.duration.ms"]?.totalMilliseconds ?? 0, 14, accuracy: 0.001)
    XCTAssertEqual(counters["perf.test.duration.ms"]?.maximumMilliseconds ?? 0, 10, accuracy: 0.001)

    // Flushing clears the counters, so the frame monitor reports disjoint windows.
    XCTAssertTrue(PerfCounters.shared.flush().isEmpty)
  }

  func testCountedReturnsValueAndMeasuresIt() {
    Perf.setEnabled(true)

    let value = Perf.counted("perf.test.counted") { 42 }

    XCTAssertEqual(value, 42)
    let counters = PerfCounters.shared.flush()
    XCTAssertEqual(counters["perf.test.counted"]?.calls, 1)
    XCTAssertEqual(counters["perf.test.counted.ms"]?.calls, 1)
  }

  func testIntervalReturnsNonNegativeDuration() {
    Perf.setEnabled(true)

    let interval = Perf.begin("perf.test.interval", zone: .hover)
    XCTAssertNotNil(interval)

    let milliseconds = interval?.end("extra=1") ?? -1
    XCTAssertGreaterThanOrEqual(milliseconds, 0)
  }

  func testMouseMoveLatencyIsDerivedFromEventTimestamp() {
    Perf.setEnabled(true)

    Perf.noteMouseMoved(timestamp: Perf.now() - 0.05)

    let latency = Perf.mouseMoveLatencyMilliseconds()
    XCTAssertNotNil(latency)
    XCTAssertGreaterThanOrEqual(latency ?? 0, 50)
    XCTAssertEqual(PerfCounters.shared.flush()["hover.mouseMoved"]?.calls, 1)
  }

  func testPopupOpenProbeRecordsFirstFrameLatency() {
    Perf.setEnabled(true)
    let probe = PopupOpenProbe.shared

    probe.begin(source: "unit-test")
    XCTAssertTrue(probe.isActive)

    // A second begin (e.g. the shortcut firing after the click) must not reset the session.
    probe.begin(source: "unit-test-second")
    XCTAssertTrue(probe.isActive)

    probe.step("popup.open.setContentSize", since: Perf.now())
    probe.stepSinceStart("popup.open.becameKey")
    probe.note("items=3")
    probe.framePresented()

    XCTAssertFalse(probe.isActive)
    let counters = PerfCounters.shared.flush()
    XCTAssertEqual(counters["popup.open.firstFrame.ms"]?.calls, 1)
  }

  func testPopupOpenProbeCancelEndsSession() {
    Perf.setEnabled(true)
    let probe = PopupOpenProbe.shared

    probe.begin(source: "unit-test")
    XCTAssertTrue(probe.isActive)

    probe.cancel(reason: "unit-test")

    XCTAssertFalse(probe.isActive)
    XCTAssertTrue(PerfCounters.shared.flush().isEmpty)
  }

  func testFrameMonitorDoesNotStartWhenDisabled() {
    Perf.setEnabled(false)

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )

    if let contentView = window.contentView {
      PerfFrameMonitor.shared.start(on: contentView)
    }

    XCTAssertFalse(PerfFrameMonitor.shared.isRunning)
    PerfFrameMonitor.shared.stop()
  }
}
