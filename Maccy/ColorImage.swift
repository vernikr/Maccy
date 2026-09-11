import AppKit
import SwiftHEXColors

class ColorImage {
  static func from(_ colorHex: String) -> NSImage? {
    // Called from the row body on every evaluation, and it rasterizes synchronously.
    Perf.counted("colorImage.from") { make(colorHex) }
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
