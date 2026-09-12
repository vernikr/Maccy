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
}
