import Sparkle

@Observable
class SoftwareUpdater {
  /// One updater for the whole process, so that the settings pane and the launch-time start talk to
  /// the same Sparkle instance (Sparkle must not be started twice).
  private static let controller = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: nil,
    userDriverDelegate: nil
  )

  /// Starts Sparkle from the app delegate, which is what makes automatic checks happen at all: the
  /// only place that used to create an updater was the settings pane, so a user who never opened it
  /// was never told about a new version. Sparkle schedules its check from here, obeying the
  /// "check for updates automatically" preference.
  static func start() {
    _ = controller
  }

  var automaticallyChecksForUpdates = false {
    didSet {
      updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
    }
  }

  private var updater: SPUUpdater
  private var automaticallyChecksForUpdatesObservation: NSKeyValueObservation?

  init() {
    updater = Self.controller.updater
    automaticallyChecksForUpdatesObservation = updater.observe(
      \.automaticallyChecksForUpdates,
      options: [.initial, .new, .old]
    ) { [unowned self] updater, change in
      guard change.newValue != change.oldValue else {
        return
      }

      self.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
    }
  }

  func checkForUpdates() {
    updater.checkForUpdates()
  }
}
