import AppKit.NSImage

// Based on https://stackoverflow.com/questions/73062803/resizing-nsimage-keeping-aspect-ratio-reducing-the-image-size-while-trying-to-sc.
extension NSImage {
  /// Returns the pixel dimensions of the image.
  /// On Retina displays, this differs from `size` which returns logical points.
  var pixelSize: NSSize {
    if let bitmapRep = representations.first(where: { $0 is NSBitmapImageRep }) as? NSBitmapImageRep {
      return NSSize(width: CGFloat(bitmapRep.pixelsWide), height: CGFloat(bitmapRep.pixelsHigh))
    }
    // Fallback to logical size if no bitmap representation is available
    return size
  }
  func resized(to newSize: NSSize) -> NSImage {
    let ratioX = newSize.width / size.width
    let ratioY = newSize.height / size.height
    let ratio = ratioX < ratioY ? ratioX : ratioY
    let newHeight = size.height * ratio
    let newWidth = size.width * ratio
    let newSize = NSSize(width: newWidth, height: newHeight)

    // Don't attempt to size up.
    if newSize.height >= size.height {
      return self
    }

    return NSImage(size: newSize, flipped: false) { destRect in
      if let context = NSGraphicsContext.current {
        context.imageInterpolation = .high
        self.draw(in: destRect, from: NSRect.zero, operation: .copy, fraction: 1)
      }

      return true
    }
  }

  /// Same as `resized(to:)`, but with the drawing already done, so a later draw is a plain blit.
  ///
  /// `resized(to:)` hands back a lazily drawn image: its handler only runs on the first draw. For a
  /// history row that first draw happens inside the popup's first paint, on the main thread, which is
  /// where the cold-start latency goes (see Zone 1, "Cold start", in `docs/performance-baseline.md`).
  /// Rasterizing here instead lets the caller do that work off the main thread.
  ///
  /// `scale` is the backing scale factor to rasterize at. Callers resolve it on the main thread,
  /// because `NSScreen` must not be queried from a background one.
  func rasterized(to newSize: NSSize, scale: CGFloat) -> NSImage {
    guard size.width > 0, size.height > 0 else {
      return self
    }

    return resized(to: newSize).materialized(scale: scale)
  }

  /// Draws the image into a bitmap of its own size, so painting it later needs no drawing handler.
  private func materialized(scale: CGFloat) -> NSImage {
    let pointSize = size
    let pixelsWide = Int((pointSize.width * scale).rounded())
    let pixelsHigh = Int((pointSize.height * scale).rounded())

    guard pixelsWide > 0, pixelsHigh > 0,
          let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
          ),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
      return self
    }

    // The bitmap is `scale` times larger than the image, which is what keeps it crisp on Retina.
    bitmap.size = pointSize

    // `NSGraphicsContext.current` is per thread, so this is safe off the main thread.
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    // The context draws in the rep's pixels, not in the rep's points: without this the picture
    // lands in one `scale`-sized corner of the bitmap while the image still reports the full point
    // size, so a row shows a half-size thumbnail in a full-size box (pinned by
    // `ThumbnailRasterizationTests.testRasterizedImageCoversTheWholeBitmap`).
    context.cgContext.scaleBy(x: scale, y: scale)
    draw(in: NSRect(origin: .zero, size: pointSize), from: .zero, operation: .copy, fraction: 1)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    let image = NSImage(size: pointSize)
    image.addRepresentation(bitmap)
    return image
  }
}
