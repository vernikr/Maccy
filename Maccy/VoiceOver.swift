import AppKit

/// Posts an announcement when VoiceOver is enabled.
///
/// Medium priority avoids interrupting rapid selection updates. Use high priority only
/// for announcements that should interrupt current speech.
func announceForAccessibility(_ announcement: () -> String, priority: NSAccessibilityPriorityLevel = .medium) {
  // Called on every selection change. The announcement text is built lazily, so with VoiceOver
  // off (the common case) this is only the `isVoiceOverEnabled` check — profiled at ~0.02 ms,
  // which is why there is no wrapper around it (an `os_signpost` pair costs more than that).
  guard NSWorkspace.shared.isVoiceOverEnabled else {
    Perf.count("accessibility.announce.skipped")
    return
  }
  Perf.count("accessibility.announce.posted")
  NSAccessibility.post(
    element: NSApp as Any,
    notification: .announcementRequested,
    userInfo: [
      .announcement: announcement(),
      .priority: priority.rawValue
    ]
  )
}
