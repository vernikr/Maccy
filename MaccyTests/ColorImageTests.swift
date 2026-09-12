import XCTest
@testable import Maccy

class ColorImageTests: XCTestCase {
  func testColorImageFromShortHex() {
    XCTAssertNotNil(ColorImage.from("fff"))
  }

  func testColorFromFullHex() {
    XCTAssertNotNil(ColorImage.from("#ff8942"))
  }

  func testColorFromNotHex() {
    XCTAssertNil(ColorImage.from("foo"))
  }

  func testSwatchIsReusedForTheSameColor() {
    ColorImage.clearCache()
    defer { ColorImage.clearCache() }
    Perf.setEnabled(true)
    defer { Perf.setEnabled(nil) }
    PerfCounters.shared.flush()

    let first = ColorImage.from("#ff8942")
    let second = ColorImage.from("#ff8942")

    let counters = PerfCounters.shared.flush()
    XCTAssertNotNil(first)
    XCTAssertTrue(first === second, "the swatch must be rasterized once per hex string")
    XCTAssertEqual(counters["colorImage.from"]?.calls, 2)
    XCTAssertEqual(counters["colorImage.cached"]?.calls, 1)
  }

  func testSwatchesAreCachedPerColor() {
    ColorImage.clearCache()
    defer { ColorImage.clearCache() }

    let red = ColorImage.from("#ff0000")
    let blue = ColorImage.from("#0000ff")

    XCTAssertNotNil(red)
    XCTAssertNotNil(blue)
    XCTAssertFalse(red === blue)
  }
}
