import AppKit.NSWorkspace
import Defaults
import Foundation
import Observation
import Sauce

@Observable
class HistoryItemDecorator: Identifiable, Hashable, HasVisibility {
  static func == (lhs: HistoryItemDecorator, rhs: HistoryItemDecorator) -> Bool {
    return lhs.id == rhs.id
  }

  static var previewImageSize: NSSize { NSScreen.forPopup?.visibleFrame.size ?? NSSize(width: 2048, height: 1536) }
  static var thumbnailImageSize: NSSize { NSSize(width: 340, height: Defaults[.imageMaxHeight]) }

  let id = UUID()

  var title: String = ""
  var attributedTitle: AttributedString?

  var isVisible: Bool = true
  var selectionIndex: Int = -1
  var isSelected: Bool {
    return selectionIndex != -1
  }
  var shortcuts: [KeyShortcut] = []

  // Memoization only: these are filled while a row body is being evaluated, so they are kept out
  // of the observation graph (writing them must not invalidate the row that is reading them).
  @ObservationIgnored private var cachedApplication: String??
  @ObservationIgnored private var cachedHasImage: Bool?
  @ObservationIgnored private var cachedAccessibilityLabel: String?
  @ObservationIgnored private var cachedAccessibilityLabelContext: MultiSelectionContext?
  @ObservationIgnored private var cachedPreviewText: String?

  var application: String? {
    if item.universalClipboard {
      return "iCloud"
    }

    if let cachedApplication {
      return cachedApplication
    }

    // Resolved once per item, not on every row body evaluation.
    guard let bundle = item.application else {
      cachedApplication = .some(nil)
      return nil
    }

    let url = Perf.counted("decorator.application.lookup") {
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
    }

    let name = url?.deletingPathExtension().lastPathComponent
    cachedApplication = .some(name)
    return name
  }

  var hasImage: Bool {
    if let cachedHasImage {
      return cachedHasImage
    }

    // `item.image` scans the stored contents (and may decode an image), so the answer is kept.
    let value = Perf.counted("decorator.hasImage") { item.image != nil }
    cachedHasImage = value
    return value
  }

  var previewImageGenerationTask: Task<(), Error>?
  var thumbnailImageGenerationTask: Task<(), Error>?
  var previewImage: NSImage?
  var previewText: String {
    if let cachedPreviewText {
      Perf.count("decorator.previewText.cached")
      return cachedPreviewText
    }

    // `previewableText` walks the stored contents, and for rich items it decodes the RTF/HTML
    // representation. The preview asks for it again on every selection change while it is open,
    // so the answer is remembered until the item changes underneath the decorator.
    let value = Perf.counted("decorator.previewText") { item.previewableText }
    cachedPreviewText = value
    return value
  }
  var thumbnailImage: NSImage?
  var applicationImage: ApplicationImage

  // 10k characters seems to be more than enough on large displays
  var text: String { previewText.shortened(to: 10_000) }

  var isPinned: Bool { item.pin != nil }
  var isUnpinned: Bool { item.pin == nil }

  func hash(into hasher: inout Hasher) {
    // We need to hash title and attributedTitle, so SwiftUI knows it needs to update the view if they chage
    hasher.combine(id)
    hasher.combine(title)
    hasher.combine(attributedTitle)
  }

  private(set) var item: HistoryItem
  
  /// Everything the accessibility label needs about the current multi-selection. Both fields come
  /// from `NavigationManager` properties that are quiet during ordinary navigation.
  struct MultiSelectionContext: Equatable {
    var index: Int
    var count: Int
  }

  /// The row's own position in the multi-selection, or `nil` outside of it.
  var multiSelectionIndex: Int? {
    // `isMultiSelectActive` (not `isMultiSelectInProgress`) on purpose: the latter reads
    // `selection`, which is reassigned on every hover, and observing it from a row body would
    // invalidate every visible row on every hover event.
    guard AppState.shared.navigator.isMultiSelectActive else {
      return nil
    }
    return selectionIndex
  }

  private var multiSelectionContext: MultiSelectionContext? {
    guard AppState.shared.navigator.isMultiSelectActive else {
      return nil
    }
    return MultiSelectionContext(
      index: selectionIndex,
      count: AppState.shared.navigator.multiSelectCount
    )
  }

  // Describe the complete item independently of its potentially truncated visual content.
  var accessibilityLabel: String {
    let context = multiSelectionContext

    if cachedAccessibilityLabelContext == context,
       let cachedAccessibilityLabel {
      return cachedAccessibilityLabel
    }

    let label = Perf.counted("decorator.accessibilityLabel") { buildAccessibilityLabel(context) }
    cachedAccessibilityLabel = label
    cachedAccessibilityLabelContext = context
    return label
  }

  /// Drops everything derived from `item`. Has to be called whenever the item changes underneath
  /// the decorator, otherwise the row keeps rendering the previous title, pin or image state.
  func invalidateDerivedValues() {
    cachedApplication = nil
    cachedHasImage = nil
    cachedAccessibilityLabel = nil
    cachedAccessibilityLabelContext = nil
    cachedPreviewText = nil
  }

  private func buildAccessibilityLabel(_ context: MultiSelectionContext?) -> String {
    var parts: [String] = []
    if hasImage, let image = item.image {
      let size = image.pixelSize
      parts.append(String(format: NSLocalizedString("history_item_image_accessibility_label_no_app", comment: ""), Int(size.width), Int(size.height)))
    } else {
      parts.append(title)
    }
    if let application = application {
      parts.append(application)
    }
    if isPinned {
      parts.append(NSLocalizedString("history_item_pinned_accessibility_value", comment: ""))
    }
    if let context {
      parts.append(String(format: NSLocalizedString("history_item_selected_accessibility_value", comment: ""), context.index + 1, context.count))
    }
    return parts.joined(separator: ", ")
  }

  init(_ item: HistoryItem, shortcuts: [KeyShortcut] = []) {
    self.item = item
    self.shortcuts = shortcuts
    self.title = item.title
    self.applicationImage = ApplicationImageCache.shared.getImage(item: item)

    synchronizeItemPin()
    synchronizeItemTitle()
  }

  @MainActor
  func ensureThumbnailImage() {
    guard item.image != nil else {
      return
    }
    guard thumbnailImage == nil else {
      return
    }
    guard thumbnailImageGenerationTask == nil else {
      return
    }
    Perf.count("decorator.ensureThumbnailImage")
    thumbnailImageGenerationTask = Task { [weak self] in
      self?.generateThumbnailImage()
    }
  }

  @MainActor
  func ensurePreviewImage() {
    guard item.image != nil else {
      return
    }
    guard previewImage == nil else {
      return
    }
    guard previewImageGenerationTask == nil else {
      return
    }
    Perf.count("decorator.ensurePreviewImage")
    previewImageGenerationTask = Task { [weak self] in
      self?.generatePreviewImage()
    }
  }

  @MainActor
  func asyncGetPreviewImage() async -> NSImage? {
    if let image = previewImage {
      return image
    }

    let interval = Perf.begin("decorator.asyncGetPreviewImage", zone: .preview)
    ensurePreviewImage()
    _ = await previewImageGenerationTask?.result
    interval?.end("cached=false")
    return previewImage
  }

  @MainActor
  func cleanupImages() {
    thumbnailImageGenerationTask?.cancel()
    previewImageGenerationTask?.cancel()
    thumbnailImage?.recache()
    previewImage?.recache()
    thumbnailImage = nil
    previewImage = nil
    item.clearDecodedImageCache()
  }

  @MainActor
  private func generateThumbnailImage() {
    guard let image = item.image else {
      return
    }
    // `NSImage.resized` returns a lazily drawn image: the actual rasterization happens
    // on the first draw, which is why `frame.stats` hitches matter here.
    thumbnailImage = Perf.measure("decorator.thumbnailImage", zone: .popup) {
      image.resized(to: HistoryItemDecorator.thumbnailImageSize)
    }
  }

  @MainActor
  private func generatePreviewImage() {
    guard let image = item.image else {
      return
    }
    previewImage = Perf.measure("decorator.previewImage", zone: .preview) {
      image.resized(to: HistoryItemDecorator.previewImageSize)
    }
  }

  @MainActor
  func sizeImages() {
    generatePreviewImage()
    generateThumbnailImage()
  }

  func highlight(_ query: String, _ ranges: [Range<String.Index>]) {
    guard !query.isEmpty, !title.isEmpty else {
      attributedTitle = nil
      return
    }

    var attributedString = AttributedString(title.shortened(to: 500))
    for range in ranges {
      if let lowerBound = AttributedString.Index(range.lowerBound, within: attributedString),
         let upperBound = AttributedString.Index(range.upperBound, within: attributedString) {
        switch Defaults[.highlightMatch] {
        case .bold:
          attributedString[lowerBound..<upperBound].font = .bold(.body)()
        case .italic:
          attributedString[lowerBound..<upperBound].font = .italic(.body)()
        case .underline:
          attributedString[lowerBound..<upperBound].underlineStyle = .single
        default:
          attributedString[lowerBound..<upperBound].backgroundColor = .findHighlightColor
          attributedString[lowerBound..<upperBound].foregroundColor = .black
        }
      }
    }

    attributedTitle = attributedString
  }

  @MainActor
  func togglePin() {
    if item.pin != nil {
      item.pin = nil
    } else {
      let pin = HistoryItem.randomAvailablePin
      item.pin = pin
    }
  }

  private func synchronizeItemPin() {
    _ = withObservationTracking {
      item.pin
    } onChange: {
      DispatchQueue.main.async {
        self.invalidateDerivedValues()
        if let pin = self.item.pin {
          self.shortcuts = KeyShortcut.create(character: pin)
        }
        self.synchronizeItemPin()
      }
    }
  }

  private func synchronizeItemTitle() {
    _ = withObservationTracking {
      item.title
    } onChange: {
      DispatchQueue.main.async {
        self.invalidateDerivedValues()
        self.title = self.item.title
        self.synchronizeItemTitle()
      }
    }
  }
}
