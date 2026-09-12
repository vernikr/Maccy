# Changelog

All notable changes to this fork are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Upstream Maccy keeps its own notes in [its releases](https://github.com/p0deje/Maccy/releases); this
file covers what the fork changes on top of the upstream version it is based on. Measurements behind
the numbers are in [docs/performance-baseline.md](docs/performance-baseline.md).

## [2.7.3] — 2026-09-12

### Added

* **Updates check themselves.** Sparkle used to be started only from the settings pane, so a build
  nobody opened that pane in was never told about a new version. It is now started at launch, as in
  any other Sparkle app, and `SUEnableAutomaticChecks` is set in
  `Info.plist` so Sparkle schedules its check silently instead of asking permission on second
  launch. Test hosts and instrumented perf runs skip it: an update installing in the middle of a
  measurement would be worse than noise.
* **`scripts/local-release.sh`** — a release a locally installed build updates itself from: builds
  Release, signs with the local certificate, signs the zip with this fork's Sparkle key (EdDSA is
  what an update is accepted on), publishes the archive as a GitHub release and adds the appcast
  entry. Companion pieces: `scripts/create-signing-identity.sh` (a stable identity, so an update
  keeps the permissions macOS granted) and `scripts/install.sh` (installs a build in place of the app
  you already have, keeping your history).

### Fixed

* **Sparkle's helpers are no longer sandboxed.** `codesign --deep` stamped the app's sandbox
  entitlement on `Downloader.xpc`, `Installer.xpc`, `Updater.app` and `Autoupdate` — the processes
  that reach the network and replace the bundle — so an update check would fail with nothing in the
  UI to explain it. They are signed on their own without entitlements now, exactly like the upstream
  build, and the installer asserts it.

## [2.7.2] — 2026-09-12

Based on upstream Maccy 2.7.1. No features were added or removed: same settings, same shortcuts, same
history file, same translations. This release is about the two things that were felt as slow.

### Performance

* **The popup opens as fast the first time after launch as it does later.** The first opening used to
  cost ~170 ms (Debug) / ~167 ms (Release) against ~72 / ~63 ms for a repeat, i.e. a cold-start penalty
  of ~100 ms in both configurations — it was structural, not `-Onone`. `FloatingPanel.prewarm()`
  builds, lays out and presents the hidden panel outside every screen about a second after launch, so
  the first opening no longer pays for the first layout of the list, the first trip to the window
  server or the first display link. First opening: ~65 ms, the same as a repeat.
* **The first opening is warmed up only as long as the work lasts.** The key-window part of the
  warm-up runs while the runloop slices still burn main-thread CPU (157–172 ms measured per 20 ms
  slice), instead of a fixed 0.2 s; the whole warm-up is ~400 ms of main-thread work at launch.
* **Rows stop rebuilding on every mouse move.** Only the rows whose selection changed are invalidated,
  and everything a row derives from its item (image data, accessibility label, application, colour
  swatch, preview text) is cached. Rows rebuilt per hover event ~57 → 2, cursor-to-highlight ~53 ms →
  ~3 ms (worst case ~0.7 s → ~35 ms), and frames per second while sweeping 5.7–55 → 36–59.
* **Row thumbnails are rasterized off the main thread** (`NSImage.rasterized(to:scale:)` in a detached
  task), removing a 131 ms main-thread stall when rows with images scrolled into view for the first
  time. The first `CADisplayLink` of the process (62–70 ms — it enumerates every display mode) is
  created during the warm-up rather than inside the first open.
* **The per-selection path no longer does work a plain hover cannot see**: the accessibility
  announcement and the preview auto-open are not wrapped in signposts (the counters remain), the
  auto-open timer is left alone when the preview is already open, and the preview text is cached.

### Fixed

* Row thumbnails were drawn into a quarter of their bitmap on Retina displays, so they appeared half
  size inside a full-height row. `ThumbnailRasterizationTests.testRasterizedImageCoversTheWholeBitmap`
  now walks the bitmap and requires the painted pixels to reach its far edge.

### Added

* `PrewarmQuiescence`: the stopping rule for the warm-up turn, with tests.
* `docs/performance-baseline.md` and `docs/performance-profiling.md`: the measured baseline, the
  scenarios behind it, the Instruments recipe, and the pitfalls that produced wrong diagnoses.
* `scripts/validate-pbxproj.py`, wired into `scripts/perf.sh build` as a preflight: it catches dangling
  file references, duplicate build-phase entries, dead records and `.swift` files that are never
  compiled.
* `docs/releasing.md`: the release procedure for this fork.

### Notes

* `SUFeedURL` now points at this repository's `appcast.xml` instead of upstream's, so a build of this
  fork is never silently replaced by an upstream release. A released build of the fork must be signed
  with the fork's own Sparkle key — see [docs/releasing.md](docs/releasing.md).

[2.7.2]: https://github.com/vernikr/Maccy/releases/tag/v2.7.2
