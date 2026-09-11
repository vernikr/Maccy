import SwiftUI

private struct HoverSelectionModifier: ViewModifier {
  @Environment(AppState.self) private var appState
  var id: UUID

  func body(content: Content) -> some View {
    content.onHover { hovering in
      if hovering {
        Perf.count("hover.onHover")
        // How long the cursor took to reach this row: `mouseMoved` gives the event
        // timestamp, so the delta is the delivery latency up to this callback.
        if let latency = Perf.mouseMoveLatencyMilliseconds() {
          Perf.record("hover.cursorToCallback.ms", milliseconds: latency)
        }

        if !appState.navigator.isKeyboardNavigating && !appState.navigator.isMultiSelectInProgress {
          let interval = Perf.begin("hover.applySelection", zone: .hover)
          appState.navigator.selectWithoutScrolling(id: id)
          interval?.end()
        } else {
          Perf.count("hover.deferredWhileKeyboardNavigating")
          appState.navigator.hoverSelectionWhileKeyboardNavigating = id
        }
      }
    }
  }
}

extension View {
  func hoverSelectionId(_ id: UUID) -> some View {
    modifier(HoverSelectionModifier(id: id))
  }
}
