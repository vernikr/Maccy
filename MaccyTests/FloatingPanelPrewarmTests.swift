import Defaults
import SwiftUI
import XCTest
@testable import Maccy

/// `FloatingPanel.prewarm()` moves the first open's work — building and laying out the SwiftUI
/// tree, presenting the window and becoming key for the first time — to launch, while the panel
/// is still hidden. Measured effect on the first open: `popup.open.firstFrame` 238–334 ms → 78–131 ms.
///
/// These tests pin the contracts that must hold for that to be invisible to the user: the panel is
/// never shown, it is ordered front outside every screen, it is sized exactly like an open would
/// size it, and the warm-up is skipped once the panel has been shown.
@MainActor
final class FloatingPanelPrewarmTests: XCTestCase {
  /// Records what `prewarm()` does to the window, because the window is the only observable.
  private final class SpyPanel: FloatingPanel<Text> {
    private(set) var contentSizes: [NSSize] = []
    private(set) var framesWhenOrderedFront: [NSRect] = []

    init() {
      super.init(
        contentRect: NSRect(origin: .zero, size: Defaults[.windowSize]),
        identifier: "org.p0deje.Maccy.prewarm-test",
        onClose: {}
      ) {
        Text("prewarm test")
      }
      // Warming up must not touch the test host's key window.
      prewarmMakesKey = false
    }

    override func setContentSize(_ size: NSSize) {
      contentSizes.append(size)
      super.setContentSize(size)
    }

    override func orderFrontRegardless() {
      framesWhenOrderedFront.append(frame)
      super.orderFrontRegardless()
    }
  }

  func testPrewarmSizesThePanelLikeAnOpenAndLaysTheContentOut() {
    let panel = SpyPanel()
    XCTAssertFalse(panel.isVisible)
    // The popup can re-measure its own height while the warm-up runs, so the expectation is
    // captured the way `prewarm()` reads it: at the moment it is called.
    let sizeAnOpenWouldUse = panel.contentSize(for: panel.prewarmHeight)

    panel.prewarm()

    XCTAssertTrue(panel.didPrewarm)
    XCTAssertFalse(panel.isVisible, "prewarming must not show the panel")
    XCTAssertFalse(panel.isPresented, "prewarming must not change the presented state")
    XCTAssertEqual(panel.contentSizes.first, sizeAnOpenWouldUse)
    XCTAssertGreaterThan(panel.contentView?.frame.height ?? 0, 0, "the tree must be laid out")
  }

  func testPrewarmOrdersThePanelFrontOutsideEveryScreen() throws {
    let panel = SpyPanel()

    panel.prewarm()

    let warmedUpFrame = try XCTUnwrap(
      panel.framesWhenOrderedFront.first,
      "the warm-up must present the window, otherwise AppKit does not run any of it"
    )
    XCTAssertFalse(
      NSScreen.screens.contains { $0.visibleFrame.intersects(warmedUpFrame) },
      "the warmed up panel must stay offscreen, otherwise the user would see it"
    )
    XCTAssertFalse(panel.isVisible, "the panel must be ordered out again")
  }

  func testPrewarmHappensOnlyOnce() {
    let panel = SpyPanel()

    panel.prewarm()
    let sizesAfterFirstWarmUp = panel.contentSizes
    panel.prewarm()

    XCTAssertTrue(panel.didPrewarm)
    XCTAssertEqual(panel.contentSizes, sizesAfterFirstWarmUp, "the tree must not be rebuilt")
    XCTAssertEqual(panel.framesWhenOrderedFront.count, 1, "the second call must not present the window again")
    XCTAssertFalse(panel.isVisible)
  }

  func testPrewarmIsSkippedOnceThePanelWasShown() {
    let panel = SpyPanel()
    panel.markPresentedForTesting()

    panel.prewarm()

    XCTAssertFalse(panel.didPrewarm, "a panel that was already shown has nothing left to warm")
    XCTAssertTrue(panel.contentSizes.isEmpty)
    XCTAssertTrue(panel.framesWhenOrderedFront.isEmpty)
  }

  // MARK: - The length of the warm-up turn

  /// The measured shape of a real warm-up: two heavy slices, then a dwell of much smaller ones.
  private let measuredWarmUp: [Double] = [37.3, 75.6, 9.6, 9.8, 6.5, 3.5, 3.7, 2.2]

  /// The turn ends when the tree stops burning CPU, not when a duration was served: the same
  /// window dribbles for hundreds of ms after the part the first open actually needs.
  func testQuiescenceStopsWhenTheWorkDropsToADwell() {
    var quiescence = PrewarmQuiescence()
    var slicesRun = 0

    for burned in measuredWarmUp {
      slicesRun += 1
      if !quiescence.shouldContinue(afterSliceBurning: burned) { break }
    }

    XCTAssertEqual(slicesRun, 4, "the turn must end on the first dwell, not on the late dribble")
    XCTAssertLessThan(slicesRun, measuredWarmUp.count, "the dribble after the dwell must not be waited for")
    XCTAssertEqual(quiescence.peakMilliseconds, 75.6)
  }

  /// The bar is a fraction of the busiest slice, so a machine that is twice as slow keeps the turn
  /// alive twice as long instead of cutting it in the middle of the work.
  func testTheIdleThresholdFollowsTheBusiestSlice() {
    var slow = PrewarmQuiescence()
    var fast = PrewarmQuiescence()

    for _ in 1...slow.minimumSlices {
      XCTAssertTrue(slow.shouldContinue(afterSliceBurning: 200))
      XCTAssertTrue(fast.shouldContinue(afterSliceBurning: 40))
    }
    // 30 ms is a dwell against a 200 ms peak, but still work against a 40 ms one.
    XCTAssertTrue(slow.shouldContinue(afterSliceBurning: 30))
    XCTAssertFalse(slow.shouldContinue(afterSliceBurning: 30))
    XCTAssertTrue(fast.shouldContinue(afterSliceBurning: 30))
    XCTAssertTrue(fast.shouldContinue(afterSliceBurning: 5))
    XCTAssertFalse(fast.shouldContinue(afterSliceBurning: 5))
  }

  /// A quiet launch must not turn a fraction of a microsecond into the bar.
  func testAnIdleThresholdHasAFloor() {
    var quiescence = PrewarmQuiescence()

    for _ in 1..<quiescence.minimumSlices {
      XCTAssertTrue(quiescence.shouldContinue(afterSliceBurning: 0.05), "trivial work must not set the bar")
    }
    XCTAssertTrue(quiescence.shouldContinue(afterSliceBurning: 2), "2 ms is still work, not a dwell")
    XCTAssertEqual(quiescence.idleSlices, 0)
  }

  /// One quiet moment in the middle of the work must not end the turn early.
  func testQuiescenceKeepsRunningWhenWorkResumesAfterAnIdleSlice() {
    var quiescence = PrewarmQuiescence()
    let minimumSlices = quiescence.minimumSlices

    for _ in 1...minimumSlices {
      XCTAssertTrue(quiescence.shouldContinue(afterSliceBurning: 50))
    }
    XCTAssertTrue(quiescence.shouldContinue(afterSliceBurning: 2))
    XCTAssertTrue(quiescence.shouldContinue(afterSliceBurning: 50), "work resumed")
    XCTAssertEqual(quiescence.idleSlices, 0, "a busy slice must reset the idle count")
  }

  /// The key-window work starts asynchronously, so a quiet first slice proves nothing.
  func testQuiescenceRunsTheFirstSlicesRegardlessOfWork() {
    var quiescence = PrewarmQuiescence()

    for _ in 1..<quiescence.minimumSlices {
      XCTAssertTrue(
        quiescence.shouldContinue(afterSliceBurning: 0),
        "the turn must not end before the work had a chance to start"
      )
    }
  }

  /// A tree that never settles must not hold the main thread for the whole launch.
  func testQuiescenceIsBounded() {
    var quiescence = PrewarmQuiescence()
    let maximumSlices = quiescence.maximumSlices
    var slices = 0

    while quiescence.shouldContinue(afterSliceBurning: 100) {
      slices += 1
      XCTAssertLessThan(slices, maximumSlices + 1, "the turn must end on its own")
    }

    XCTAssertEqual(quiescence.slices, maximumSlices)
    XCTAssertLessThan(
      Double(maximumSlices) * quiescence.sliceDuration,
      1.0,
      "the worst case must stay well below a visible freeze"
    )
  }

  func testThreadCPUMillisecondsAdvancesWithWork() {
    let before = PrewarmQuiescence.threadCPUMilliseconds()
    var accumulator = 0.0
    for value in 1...2_000_000 { accumulator += Double(value).squareRoot() }
    let after = PrewarmQuiescence.threadCPUMilliseconds()

    XCTAssertGreaterThan(after, before, "busy work must be visible to the turn's clock")
    XCTAssertGreaterThan(accumulator, 0)
  }
}
