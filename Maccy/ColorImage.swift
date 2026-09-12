import AppKit
import SwiftHEXColors

class ColorImage {
  /// Every row body evaluation asks for the swatch of the same handful of hex strings, so the
  /// rasterized 12x12 image is kept. `NSCache` is thread-safe and evicts under memory pressure.
  private static let cache = NSCache<NSString, NSImage>()

  static func from(_ colorHex: String) -> NSImage? {
    // Called from the row body on every evaluation, and it rasterizes synchronously.
    Perf.counted("colorImage.from") {
      let key = colorHex as NSString
      if let cached = cache.object(forKey: key) {
        Perf.count("colorImage.cached")
        return cached
      }

      guard let image = make(colorHex) else {
        return nil
      }

      cache.setObject(image, forKey: key)
      return image
    }
  }

  /// Drops every cached swatch, e.g. between tests.
  static func clearCache() {
    cache.removeAllObjects()
  }

  private static func make(_ colorHex: String) -> NSImage? {
    guard let color = NSColor(hexString: colorHex) else {
      return nil
    }

    let image = NSImage(size: NSSize(width: 12, height: 12))
    image.lockFocus()
    color.drawSwatch(in: NSRect(x: 0, y: 0, width: 12, height: 12))
    image.unlockFocus()

    return image
  }
}
