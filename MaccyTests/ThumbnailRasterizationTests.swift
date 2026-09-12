import XCTest
@testable import Maccy

/// Regression tests for thumbnail rasterization.
///
/// `NSImage.resized(to:)` returns a lazily drawn image: its drawing handler only runs on the first
/// draw. For a history row that first draw used to happen inside the popup's first paint, on the main
/// thread, which is where the cold-start latency went — `docs/performance-baseline.md` (Zone 1,
/// "Cold start") measures 209–299 ms for the first open of the popup against 82 ms for a later one,
/// and a 131 ms `NSImage.resized` stall when rows scrolled into view for the first time.
///
/// These tests pin the fix down: the rasterization runs off the main thread, and the row receives an
/// image that is already drawn, so painting it can only blit.
@MainActor
final class ThumbnailRasterizationTests: XCTestCase {
  private var originalRasterize: ((NSImage, NSSize, CGFloat) -> NSImage)!

  override func setUp() {
    super.setUp()
    originalRasterize = HistoryItemDecorator.rasterizeImage
  }

  override func tearDown() {
    HistoryItemDecorator.rasterizeImage = originalRasterize
    super.tearDown()
  }

  // MARK: - The rasterizer itself

  func testResizingStaysLazyWhileRasterizingDrawsNow() {
    var draws = 0
    let source = NSImage(size: NSSize(width: 400, height: 200), flipped: false) { _ in
      draws += 1
      return true
    }

    _ = source.resized(to: NSSize(width: 40, height: 20))
    XCTAssertEqual(draws, 0, "resized(to:) must stay lazy")

    let rasterized = source.rasterized(to: NSSize(width: 40, height: 20), scale: 2)
    XCTAssertEqual(draws, 1, "rasterized(to:scale:) must draw right away")

    XCTAssertEqual(rasterized.size, NSSize(width: 40, height: 20))
    let bitmap = rasterized.representations.compactMap { $0 as? NSBitmapImageRep }.first
    XCTAssertEqual(bitmap?.pixelsWide, 80, "the thumbnail must be rasterized at the requested scale")
    XCTAssertEqual(bitmap?.pixelsHigh, 40)
  }

  func testRasterizingDoesNotSizeUp() {
    var draws = 0
    let source = NSImage(size: NSSize(width: 200, height: 100), flipped: false) { _ in
      draws += 1
      return true
    }

    let rasterized = source.rasterized(to: NSSize(width: 340, height: 150), scale: 2)

    XCTAssertEqual(rasterized.size, NSSize(width: 200, height: 100))
    XCTAssertEqual(draws, 1, "the image still has to be drawn, just at its own size")
    XCTAssertNotNil(rasterized.representations.compactMap { $0 as? NSBitmapImageRep }.first)
  }

  // MARK: - The row

  func testThumbnailIsRasterizedOffTheMainThread() async throws {
    let recorder = ThreadRecorder()
    HistoryItemDecorator.rasterizeImage = { image, size, scale in
      recorder.record(isMainThread: Thread.isMainThread)
      return image.rasterized(to: size, scale: scale)
    }

    let decorator = makeDecorator(image: makeImage(size: NSSize(width: 1600, height: 900)))
    decorator.ensureThumbnailImage()

    let thumbnail = try await waitForThumbnail(of: decorator)

    XCTAssertEqual(recorder.wasOnMainThread, false, "the thumbnail must not be rasterized on the main thread")
    XCTAssertNotNil(thumbnail.representations.compactMap { $0 as? NSBitmapImageRep }.first,
                    "the row must receive an image that no longer needs a drawing handler")
  }

  func testThumbnailIsScaledIntoTheThumbnailBox() async throws {
    let decorator = makeDecorator(image: makeImage(size: NSSize(width: 1600, height: 900)))
    decorator.ensureThumbnailImage()

    let thumbnail = try await waitForThumbnail(of: decorator)

    XCTAssertLessThanOrEqual(thumbnail.size.width, HistoryItemDecorator.thumbnailImageSize.width + 0.5)
    XCTAssertLessThan(thumbnail.size.height, 900)
    XCTAssertEqual(thumbnail.size.width / thumbnail.size.height, 1600.0 / 900.0, accuracy: 0.01,
                   "the aspect ratio must survive the resize")
  }

  func testItemWithoutAnImageNeverRasterizes() async throws {
    var calls = 0
    HistoryItemDecorator.rasterizeImage = { image, size, scale in
      calls += 1
      return image.rasterized(to: size, scale: scale)
    }

    let decorator = makeDecorator(image: nil)
    decorator.ensureThumbnailImage()
    try await Task.sleep(nanoseconds: 100_000_000)

    XCTAssertEqual(calls, 0)
    XCTAssertNil(decorator.thumbnailImage)
  }

  // MARK: - Helpers

  private final class ThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?

    var wasOnMainThread: Bool? {
      lock.lock()
      defer { lock.unlock() }
      return value
    }

    func record(isMainThread: Bool) {
      lock.lock()
      value = isMainThread
      lock.unlock()
    }
  }

  private func makeImage(size: NSSize) -> NSImage {
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.systemRed.setFill()
    NSRect(origin: .zero, size: size).fill()
    image.unlockFocus()
    return image
  }

  private func makeDecorator(image: NSImage?) -> HistoryItemDecorator {
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
          value: "no image".data(using: .utf8)
        )
      ]
    }

    item.title = "thumbnail"
    return HistoryItemDecorator(item)
  }

  private func waitForThumbnail(
    of decorator: HistoryItemDecorator,
    timeout: TimeInterval = 5
  ) async throws -> NSImage {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      if let thumbnail = decorator.thumbnailImage {
        return thumbnail
      }
      try await Task.sleep(nanoseconds: 5_000_000)
    }

    XCTFail("the thumbnail was never generated")
    throw CancellationError()
  }
}
