import Defaults
import SwiftUI

/// Decides when the warm-up runloop turn has done the work it exists for.
///
/// The turn used to be a fixed 0.2 s — the shortest that reliably moved the key-window work off
/// the first open in the session it was tuned in — and that is a worst case paid on every launch,
/// whether the work needs it or not. What the tree actually does after `makeKey()` cannot be told
/// from a duration either: sampled per 20 ms slice, the first two slices burn 37 ms and 75 ms of
/// main-thread CPU, the next two 6–13 ms each, and then the same window dribbles 2–5 ms per slice
/// for another 300 ms without anything the first open notices. So the turn ends on the dwell —
/// once a slice stops burning a meaningful fraction of the busiest one — which follows the work
/// instead of a number that was right for one machine on one day.
struct PrewarmQuiescence {
  /// One slice of runloop. Short enough that the turn ends close to the last work.
  var sliceDuration: TimeInterval = 0.02
  /// Slices to run before any stop is allowed: the key-window work starts asynchronously.
  var minimumSlices = 4
  /// A slice that burns less than this fraction of the busiest slice so far counts as idle.
  var busyFraction = 0.2
  /// Floor for the idle threshold, so a trivial peak cannot turn a few microseconds into the bar.
  var minimumBusyMilliseconds = 1.0
  /// Consecutive idle slices that end the turn.
  var idleSlicesToStop = 2
  /// Upper bound, so a tree that never settles cannot hold the launch.
  var maximumSlices = 25

  private(set) var slices = 0
  private(set) var idleSlices = 0
  private(set) var peakMilliseconds = 0.0

  /// Whether the turn should keep running after a slice that burned `cpuMilliseconds`.
  mutating func shouldContinue(afterSliceBurning cpuMilliseconds: Double) -> Bool {
    slices += 1
    peakMilliseconds = max(peakMilliseconds, cpuMilliseconds)

    let idleThreshold = max(minimumBusyMilliseconds, peakMilliseconds * busyFraction)
    idleSlices = cpuMilliseconds >= idleThreshold ? 0 : idleSlices + 1

    guard slices < maximumSlices else { return false }
    guard slices >= minimumSlices else { return true }
    return idleSlices < idleSlicesToStop
  }

  /// CPU time the calling thread has burned so far, in milliseconds.
  /// `clock_gettime` here is a vDSO call, cheap enough to sample every slice.
  static func threadCPUMilliseconds() -> Double {
    var time = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
    return Double(time.tv_sec) * 1000 + Double(time.tv_nsec) / 1_000_000
  }
}

// An NSPanel subclass that implements floating panel traits.
// https://stackoverflow.com/questions/46023769/how-to-show-a-window-without-stealing-focus-on-macos
class FloatingPanel<Content: View>: NSPanel, NSWindowDelegate {
  var isPresented: Bool = false
  var statusBarButton: NSStatusBarButton?
  let onClose: () -> Void

  /// Whether `prewarm()` already built the view tree, reported as a note of the first open.
  private(set) var didPrewarm = false
  /// Once the panel has been shown there is nothing left to warm.
  private var hasEverBeenPresented = false
  /// Whether `prewarm()` may make the panel key. VoiceOver turns it off, because there a focus
  /// change on an invisible window is something the user hears; tests turn it off so warming up
  /// does not touch the test host's key window.
  var prewarmMakesKey = !NSWorkspace.shared.isVoiceOverEnabled
  /// True only while `prewarm()` runs; see `constrainFrameRect(_:to:)`.
  private var isPrewarming = false

  override var isMovable: Bool {
    get { Defaults[.popupPosition] != .statusItem }
    set {}
  }

  init(
    contentRect: NSRect,
    identifier: String = "",
    statusBarButton: NSStatusBarButton? = nil,
    onClose: @escaping () -> Void,
    view: () -> Content
  ) {
    self.onClose = onClose

    super.init(
        contentRect: contentRect,
        styleMask: [.nonactivatingPanel, .resizable, .closable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )

    self.statusBarButton = statusBarButton
    self.identifier = NSUserInterfaceItemIdentifier(identifier)

    Defaults[.windowSize] = contentRect.size
    delegate = self

    animationBehavior = .none
    isFloatingPanel = true
    // Chrome autofill uses window layer 999; screenSaver (1000) sits just above it
    // while still covering status items / Spotlight. See #1403.
    level = .screenSaver
    collectionBehavior = [.auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary]
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    isMovableByWindowBackground = true
    hidesOnDeactivate = false
    backgroundColor = .clear
    titlebarSeparatorStyle = .none

    // Hide all traffic light buttons
    standardWindowButton(.closeButton)?.isHidden = true
    standardWindowButton(.miniaturizeButton)?.isHidden = true
    standardWindowButton(.zoomButton)?.isHidden = true

    contentView = NSHostingView(
      rootView: view()
        // The safe area is ignored because the title bar still interferes with the geometry
        .ignoresSafeArea()
        .gesture(DragGesture()
          .onEnded { _ in
            self.saveWindowPosition()
        })
    )
    contentView?.layer?.cornerRadius = Popup.cornerRadius + Popup.horizontalPadding
  }

  func toggle(height: CGFloat, at popupPosition: PopupPosition = Defaults[.popupPosition]) {
    if isPresented {
      close()
    } else {
      open(height: height, at: popupPosition)
    }
  }

  func open(height: CGFloat, at popupPosition: PopupPosition = Defaults[.popupPosition]) {
    let probe = PopupOpenProbe.shared
    let wasVisible = isVisible
    probe.begin(source: "panel.open")
    Perf.count("popup.open")

    let finalSize = contentSize(for: height)

    var stepStartedAt = Perf.now()
    setContentSize(finalSize)
    probe.step("popup.open.setContentSize", since: stepStartedAt)

    stepStartedAt = Perf.now()
    setFrameOrigin(popupPosition.origin(size: frame.size, statusBarButton: statusBarButton))
    probe.step("popup.open.setFrameOrigin", since: stepStartedAt)

    stepStartedAt = Perf.now()
    orderFrontRegardless()
    probe.step("popup.open.orderFrontRegardless", since: stepStartedAt)

    stepStartedAt = Perf.now()
    makeKey()
    probe.step("popup.open.makeKey", since: stepStartedAt)

    isPresented = true
    hasEverBeenPresented = true

    probe.note("size=\(String(format: "%.0fx%.0f", finalSize.width, finalSize.height))")
    probe.note("items=\(AppState.shared.history.items.count)")
    probe.note("position=\(popupPosition)")
    probe.note("wasVisible=\(wasVisible)")
    probe.note("prewarmed=\(didPrewarm)")

    // The display link ticks on the first presented frame, which is the closest signal
    // to "the user can see the popup" that AppKit offers.
    stepStartedAt = Perf.now()
    PerfFrameMonitor.shared.onFirstFrame = { PopupOpenProbe.shared.framePresented() }
    if let contentView {
      PerfFrameMonitor.shared.start(on: contentView)
    }
    probe.step("popup.open.displayLinkMonitor", since: stepStartedAt)

    if popupPosition == .statusItem {
      DispatchQueue.main.async {
        self.statusBarButton?.isHighlighted = true
      }
    }
  }

  /// Builds, lays out and presents the popup's view tree while the panel is still hidden.
  ///
  /// The panel and its hosting view are created once at launch, but SwiftUI builds and lays out
  /// the list tree only when the window is first displayed, AppKit presents it for the first time
  /// only then, and the search field's first focus and the window's first active appearance also
  /// happen on that first display. The trace of the first open is 41 % allocations — creation,
  /// not rendering — and it costs 238–334 ms against 77–105 ms for a repeat. Doing all of it here
  /// moves it off the open path, where nobody waits for it.
  ///
  /// Everything happens offscreen: the panel is ordered front at a point outside every screen and
  /// ordered out again, because laying out a hidden window does *not* make AppKit present it.
  /// The app itself is never activated. The panel is made key, because that is where a large part
  /// of the remaining cost lives (measured: the penalty of a first open over a repeat 166 → 59 ms),
  /// but not when VoiceOver is running — there a focus change is something the user hears (see
  /// `prewarmMakesKey`). The key state is held while the tree keeps working, not for a fixed
  /// duration: see `PrewarmQuiescence`.
  func prewarm() {
    guard !didPrewarm, !hasEverBeenPresented, !isPresented, !isVisible else { return }

    let startedAt = Perf.now()
    let size = contentSize(for: prewarmHeight)

    // CoreAnimation's first display link of the process is created here rather than inside the
    // first open, where it would be charged to the user (and to the probe).
    let linkStartedAt = Perf.now()
    if let contentView {
      PerfFrameMonitor.shared.warmUp(on: contentView)
    }
    let linkMs = (Perf.now() - linkStartedAt) * 1000

    var before = PerfCounters.shared.snapshot()
    let layoutStartedAt = Perf.now()
    setContentSize(size)
    contentView?.layoutSubtreeIfNeeded()
    let layoutMs = (Perf.now() - layoutStartedAt) * 1000
    let layoutBuilt = PerfCounters.delta(between: before, and: PerfCounters.shared.snapshot())

    if Perf.isEnabled {
      before = PerfCounters.shared.snapshot()
    }
    let presentedAt = Perf.now()
    let savedOrigin = frame.origin
    isPrewarming = true
    setFrameOrigin(offscreenOrigin())
    orderFrontRegardless()
    contentView?.layoutSubtreeIfNeeded()
    contentView?.displayIfNeeded()

    let keyWarmed = prewarmMakesKey
    var turnMs = 0.0
    var quiescence = PrewarmQuiescence()
    if keyWarmed {
      makeKey()
      // The focus and appearance work is driven by the key-window notifications and needs a few
      // runloop turns to run. It happens here so that the first open only pays a warm `makeKey`.
      let turnStartedAt = Perf.now()

      while true {
        let cpuBefore = PrewarmQuiescence.threadCPUMilliseconds()
        RunLoop.current.run(until: Date().addingTimeInterval(quiescence.sliceDuration))
        let burned = PrewarmQuiescence.threadCPUMilliseconds() - cpuBefore
        guard quiescence.shouldContinue(afterSliceBurning: burned) else { break }
      }

      turnMs = (Perf.now() - turnStartedAt) * 1000
    }

    // A runloop turn can deliver a click on the status item; leave a popup that was opened
    // during it alone instead of ordering it out from under the user.
    let openedDuringWarmUp = isPresented
    if !openedDuringWarmUp {
      orderOut(nil)
      setFrameOrigin(savedOrigin)
    }
    isPrewarming = false
    let presentMs = (Perf.now() - presentedAt) * 1000
    didPrewarm = true

    guard Perf.isEnabled else { return }
    let presentBuilt = PerfCounters.delta(between: before, and: PerfCounters.shared.snapshot())

    Perf.event(
      "popup.prewarm",
      zone: .popup,
      "ms=\(Perf.milliseconds(Perf.now() - startedAt)) layout=\(Perf.milliseconds(layoutMs / 1000)) "
        + "present=\(Perf.milliseconds(presentMs / 1000)) "
        + "displayLink=\(Perf.milliseconds(linkMs / 1000)) "
        + "turn=\(Perf.milliseconds(turnMs / 1000)) "
        + "slices=\(quiescence.slices) idle=\(quiescence.idleSlices) "
        + "peakCpu=\(Perf.milliseconds(quiescence.peakMilliseconds / 1000)) "
        + "size=\(String(format: "%.0fx%.0f", size.width, size.height)) "
        + "keyWarmed=\(keyWarmed) openedDuringWarmUp=\(openedDuringWarmUp) "
        + "layoutBuilt={\(PerfCounters.describe(layoutBuilt, limit: 160))} "
        + "presentBuilt={\(PerfCounters.describe(presentBuilt, limit: 240))}"
    )
  }

#if DEBUG
  /// Test hook: pretends the panel was shown, so `prewarm()` must become a no-op.
  func markPresentedForTesting() {
    hasEverBeenPresented = true
  }
#endif

  /// The list height `prewarm()` lays out at: the height the popup has measured for itself, or,
  /// before it measured anything, the tallest the popup can ever be opened.
  var prewarmHeight: CGFloat {
    let height = AppState.shared.popup.height
    return height > 0 ? height : Defaults[.windowSize].height
  }

  /// Keeps the panel outside the screens while `prewarm()` runs.
  ///
  /// AppKit pulls an offscreen window back onto a screen with `constrainFrameRect(_:to:)`, which
  /// would turn the warm-up into a popup flashing in a screen corner at launch. Outside the
  /// warm-up the normal constraint applies, so a user cannot park the popup somewhere unreachable.
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    isPrewarming ? frameRect : super.constrainFrameRect(frameRect, to: screen)
  }

  /// A point outside every screen, so that ordering the panel front cannot be seen.
  /// The app's own activation state is never touched: the panel is non-activating.
  private func offscreenOrigin() -> NSPoint {
    let screens = NSScreen.screens
    let maxX = screens.map(\.frame.maxX).max() ?? 0
    let minY = screens.map(\.frame.minY).min() ?? 0
    return NSPoint(x: maxX + 10_000, y: minY)
  }

  /// The size the panel is opened with for a requested list height. `prewarm()` uses it too so
  /// that both lay the tree out at the same size.
  func contentSize(for height: CGFloat) -> NSSize {
    let size = Defaults[.windowSize]
    let minimumHeight: CGFloat = AppState.shared.popup.minimumHeight
    return NSSize(
      width: min(frame.width, size.width),
      height: max(min(height, size.height), minimumHeight)
    )
  }

  func verticallyResize(to newHeight: CGFloat) {
    let startedAt = Perf.now()
    let beforeFirstFrame = PopupOpenProbe.shared.isActive

    var newSize = frame.size
    newSize.height = newHeight
    var newOrigin = frame.origin
    newOrigin.y += (frame.height - newSize.height)

    NSAnimationContext.runAnimationGroup { (context) in
      context.duration = 0.2
      context.completionHandler = {
        Perf.record("popup.verticalResize.ms", milliseconds: (Perf.now() - startedAt) * 1000)
      }
      animator().setFrame(NSRect(origin: newOrigin, size: newSize), display: true)
    }

    Perf.count("popup.verticalResize")
    if beforeFirstFrame {
      // Any resize queued before the popup was even presented adds a second layout pass
      // to the first frame the user sees.
      Perf.count("popup.verticalResize.beforeFirstFrame")
    }
  }

  func determinePreviewPlacement() {
    let preview = AppState.shared.preview
    guard !preview.state.isOpen else { return }
    let newSize = preview.computeSizeWithPreview(frame.size, state: .open)
    preview.placement = preview.computePlacement(window: self, for: newSize)
  }

  func saveWindowPosition() {
    if let screenFrame = screen?.visibleFrame {
      // Only store the size of the window without the preview
      let width = AppState.shared.preview.contentWidth

      let anchorX = frame.minX + width / 2 - screenFrame.minX
      let anchorY = frame.maxY - screenFrame.minY
      Defaults[.windowPosition] = NSPoint(x: anchorX / screenFrame.width, y: anchorY / screenFrame.height)
    }
  }

  func saveWindowFrame(frame: NSRect) {
    Defaults[.windowSize] = frame.size
    saveWindowPosition()
  }

  func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
    let preview = AppState.shared.preview

    if inLiveResize && preview.resizingMode == .none {
      let screenPoint = NSEvent.mouseLocation
      let windowPoint = convertPoint(fromScreen: screenPoint)
      let location: SlideoutPlacement = windowPoint.x <= frame.width / 2 ? .left : .right
      if (location == preview.placement) && preview.state == .open {
        preview.startResize(mode: .slideout)
      } else {
        preview.startResize(mode: .content)
      }
    }

    var finalFrameSize = frameSize
    var minContent = preview.minimumContentWidth
    var minPreview = 0.0

    if inLiveResize && preview.resizingMode != .none {
      if preview.resizingMode == .content && preview.state == .open {
        minPreview = preview.slideoutWidth
      }
      if preview.resizingMode == .slideout {
        minPreview = preview.minimumSlideoutWidth
        minContent = preview.contentWidth
      }
    }
    finalFrameSize.width = max(finalFrameSize.width, minContent + minPreview)

    if !AppState.shared.preview.state.isAnimating {
      var size = frame.size
      // Only store the size of the window without the preview
      size.width = AppState.shared.preview.contentWidth
      saveWindowFrame(frame: NSRect(origin: frame.origin, size: size))
    }

    let minimumHeight = AppState.shared.popup.minimumHeight
    finalFrameSize.height = max(finalFrameSize.height, minimumHeight)

    return finalFrameSize
  }

  func windowWillMove(_ notification: Notification) {
    determinePreviewPlacement()
  }

  func windowDidMove(_ notification: Notification) {
    determinePreviewPlacement()
  }

  func windowWillStartLiveResize(_ notification: Notification) {
    AppState.shared.preview.cancelAutoOpen()
  }

  func windowDidEndLiveResize(_ notification: Notification) {
    AppState.shared.preview.startAutoOpen()
    AppState.shared.preview.endResize()
  }

  func windowDidBecomeKey(_ notification: Notification) {
    PopupOpenProbe.shared.stepSinceStart("popup.open.becameKey")

    AppState.shared.preview.enableAutoOpen()

    if AppState.shared.navigator.leadHistoryItem != nil {
      AppState.shared.preview.startAutoOpen()
    }
  }

  func windowDidResignKey(_ notification: Notification) {
    AppState.shared.preview.disableAutoOpen()
  }

  // Close automatically when out of focus, e.g. outside click.
  override func resignKey() {
    super.resignKey()
    // Don't hide if confirmation is shown.
    if NSApp.alertWindow == nil {
      close()
    }
  }

  override func close() {
    super.close()
    PerfFrameMonitor.shared.stop()
    PopupOpenProbe.shared.cancel(reason: "closed")
    Perf.count("popup.close")
    AppState.shared.preview.state = .closed
    isPresented = false
    statusBarButton?.isHighlighted = false
    onClose()
  }

  // Allow text inputs inside the panel can receive focus
  override var canBecomeKey: Bool {
    return true
  }
}
