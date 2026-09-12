import XCTest
import Defaults
@testable import Maccy

/// Regression tests for the hover path.
///
/// The baseline in docs/performance-baseline.md showed that every hover event re-evaluated the
/// whole visible list (~30-57 row bodies), because the row body read `selection` through
/// `multiSelectionIndex`, and `selection` is reassigned on every hover. A second source of waste
/// was that the values a row derives from its item (image data, image presence, application name,
/// accessibility label, colour swatch) were recomputed on every body evaluation.
///
/// These tests pin both down: a plain selection change must not write anything the rows observe,
/// and the derived values must be resolved once per item.
@MainActor
final class NavigationSelectionTests: XCTestCase {
  private var navigator: NavigationManager { AppState.shared.navigator }

  override func setUp() {
    super.setUp()
    PerfCounters.shared.reset()
    navigator.isManualMultiSelect = false
    navigator.selectWithoutScrolling(item: nil)
    PerfCounters.shared.reset()
  }

  override func tearDown() {
    navigator.isManualMultiSelect = false
    navigator.selectWithoutScrolling(item: nil)
    Perf.setEnabled(nil)
    PerfCounters.shared.reset()
    super.tearDown()
  }

  // MARK: - The flag rows observe

  func testHoveringAnotherRowDoesNotFlipMultiSelectFlag() {
    Perf.setEnabled(true)
    let first = makeDecorator(title: "first")
    let second = makeDecorator(title: "second")

    navigator.selectWithoutScrolling(item: first)
    let afterFirstSelect = PerfCounters.shared.flush()

    navigator.selectWithoutScrolling(item: second)
    let afterSecondSelect = PerfCounters.shared.flush()

    XCTAssertFalse(navigator.isMultiSelectActive)
    XCTAssertNil(first.multiSelectionIndex)
    XCTAssertNil(second.multiSelectionIndex)

    // The point of the flag: plain selection changes must not write it, because every row
    // observes it and a write invalidates all of them.
    XCTAssertEqual(afterFirstSelect["nav.isMultiSelectActive.changes"]?.calls ?? 0, 0)
    XCTAssertEqual(afterSecondSelect["nav.isMultiSelectActive.changes"]?.calls ?? 0, 0)
    XCTAssertEqual(afterFirstSelect["nav.isMultiSelectActive.noopWrites"]?.calls ?? 0, 1)
    XCTAssertEqual(afterSecondSelect["nav.isMultiSelectActive.noopWrites"]?.calls ?? 0, 1)
    XCTAssertEqual(navigator.selection.count, 1)
  }

  func testMultiSelectFlagFollowsTheSelection() {
    let first = makeDecorator(title: "first")
    let second = makeDecorator(title: "second")

    navigator.selectWithoutScrolling(item: first)
    XCTAssertFalse(navigator.isMultiSelectActive)

    navigator.addToSelection(item: second)
    XCTAssertTrue(navigator.isMultiSelectActive)
    XCTAssertEqual(navigator.selection.count, 2)

    navigator.selectWithoutScrolling(item: first)
    XCTAssertFalse(navigator.isMultiSelectActive)
    XCTAssertNil(first.multiSelectionIndex)
  }

  func testManualMultiSelectFlipsTheFlag() {
    let first = makeDecorator(title: "first")
    navigator.selectWithoutScrolling(item: first)

    navigator.isManualMultiSelect = true
    XCTAssertTrue(navigator.isMultiSelectActive)
    XCTAssertEqual(first.multiSelectionIndex, 0)

    navigator.isManualMultiSelect = false
    XCTAssertFalse(navigator.isMultiSelectActive)
    XCTAssertNil(first.multiSelectionIndex)
  }

  // MARK: - Derived values

  func testDerivedValuesAreResolvedOnce() {
    Perf.setEnabled(true)
    let decorator = makeDecorator(title: "foo", image: sampleImage())
    PerfCounters.shared.flush()

    _ = decorator.accessibilityLabel

    let afterLabel = PerfCounters.shared.flush()
    let labelCounters = PerfCounters.describe(afterLabel)
    XCTAssertEqual(afterLabel["decorator.accessibilityLabel"]?.calls, 1, labelCounters)
    XCTAssertEqual(afterLabel["decorator.hasImage"]?.calls, 1, labelCounters)
    XCTAssertEqual(afterLabel["decorator.application.lookup"]?.calls, 1, labelCounters)
    XCTAssertEqual(afterLabel["historyItem.imageData"]?.calls, 1, labelCounters)

    // Reading them again must not touch the item at all.
    _ = decorator.hasImage
    _ = decorator.application
    _ = decorator.item.imageData

    let afterRepeat = PerfCounters.shared.flush()
    let repeatCounters = PerfCounters.describe(afterRepeat)
    XCTAssertNil(afterRepeat["decorator.hasImage"], repeatCounters)
    XCTAssertNil(afterRepeat["decorator.application.lookup"], repeatCounters)
    XCTAssertEqual(afterRepeat["historyItem.imageData.cached"]?.calls, 1, repeatCounters)

    _ = decorator.accessibilityLabel
    XCTAssertNil(
      PerfCounters.shared.flush()["decorator.accessibilityLabel"],
      "the label itself must be cached too"
    )
  }

  func testImageDataIsResolvedOnce() {
    Perf.setEnabled(true)
    let decorator = makeDecorator(title: "foo")
    PerfCounters.shared.flush()

    XCTAssertNil(decorator.item.imageData)
    XCTAssertNil(decorator.item.imageData)

    let counters = PerfCounters.shared.flush()
    XCTAssertEqual(counters["historyItem.imageData"]?.calls, 2)
    XCTAssertEqual(counters["historyItem.imageData.cached"]?.calls, 1)
  }

  func testInvalidatingDerivedValuesForcesRecomputation() {
    Perf.setEnabled(true)
    let decorator = makeDecorator(title: "foo")
    _ = decorator.accessibilityLabel
    _ = decorator.hasImage
    PerfCounters.shared.flush()

    decorator.invalidateDerivedValues()
    _ = decorator.accessibilityLabel
    _ = decorator.hasImage

    let counters = PerfCounters.shared.flush()
    XCTAssertEqual(counters["decorator.accessibilityLabel"]?.calls, 1)
    XCTAssertEqual(counters["decorator.hasImage"]?.calls, 1)
  }

  func testAccessibilityLabelFollowsMultiSelection() {
    Perf.setEnabled(true)
    let first = makeDecorator(title: "first")
    let second = makeDecorator(title: "second")

    navigator.selectWithoutScrolling(item: first)
    let singleLabel = first.accessibilityLabel
    XCTAssertNil(first.multiSelectionIndex)
    PerfCounters.shared.flush()

    navigator.addToSelection(item: second)
    let multiLabel = first.accessibilityLabel

    XCTAssertEqual(first.multiSelectionIndex, 0)
    XCTAssertNotEqual(multiLabel, singleLabel, "the cached label must be keyed by the multi-selection index")
    XCTAssertEqual(PerfCounters.shared.flush()["decorator.accessibilityLabel"]?.calls, 1)
  }

  /// The label says "Selected, 1 of 3", so growing the selection has to rebuild the labels of the
  /// rows that were already selected even though their own index did not change.
  func testAccessibilityLabelTracksTheNumberOfSelectedItems() {
    let first = makeDecorator(title: "first")
    let second = makeDecorator(title: "second")
    let third = makeDecorator(title: "third")

    navigator.selectWithoutScrolling(item: first)
    navigator.addToSelection(item: second)
    let twoSelected = first.accessibilityLabel
    XCTAssertEqual(navigator.multiSelectCount, 2)

    navigator.addToSelection(item: third)
    let threeSelected = first.accessibilityLabel

    XCTAssertEqual(navigator.multiSelectCount, 3)
    XCTAssertEqual(first.multiSelectionIndex, 0, "the row's own index did not change")
    XCTAssertNotEqual(threeSelected, twoSelected, "the label embeds the total number of selected items")
  }

  /// The regression that these tests exist for: hovering another row must not invalidate anything
  /// the untouched row derives from its item.
  func testPlainHoverDoesNotInvalidateDerivedValues() {
    Perf.setEnabled(true)
    let first = makeDecorator(title: "first", image: sampleImage())
    let second = makeDecorator(title: "second")

    navigator.selectWithoutScrolling(item: first)
    _ = first.accessibilityLabel
    _ = first.hasImage
    PerfCounters.shared.flush()

    navigator.selectWithoutScrolling(item: second)

    _ = first.accessibilityLabel
    _ = first.hasImage
    _ = first.application

    let counters = PerfCounters.shared.flush()
    let description = PerfCounters.describe(counters)
    XCTAssertNil(counters["decorator.accessibilityLabel"], description)
    XCTAssertNil(counters["decorator.hasImage"], description)
    XCTAssertNil(counters["decorator.application.lookup"], description)
    XCTAssertEqual(counters["nav.isMultiSelectActive.changes"]?.calls ?? 0, 0, description)
  }

  // MARK: - Helpers

  private func makeDecorator(title: String, image: NSImage? = nil) -> HistoryItemDecorator {
    let item = HistoryItem()
    Storage.shared.context.insert(item)

    if let image, let data = image.tiffRepresentation {
      item.contents = [
        HistoryItemContent(type: NSPasteboard.PasteboardType.tiff.rawValue, value: data)
      ]
    } else {
      item.contents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: title.data(using: .utf8)
        )
      ]
    }

    item.title = title
    item.application = "com.apple.finder"
    item.numberOfCopies = 1

    return HistoryItemDecorator(item)
  }

  private func sampleImage() -> NSImage {
    let image = NSImage(size: NSSize(width: 20, height: 20))
    image.lockFocus()
    NSColor.systemBlue.setFill()
    NSRect(x: 0, y: 0, width: 20, height: 20).fill()
    image.unlockFocus()
    return image
  }
}
