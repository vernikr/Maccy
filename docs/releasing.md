# Releasing this fork

Upstream Maccy releases itself. This is what a release of the fork has to do, and what it must not
inherit from upstream.

## 1. Version

`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` live in `Maccy.xcodeproj/project.pbxproj` (four
lines — both configurations). Bump the marketing version by SemVer (`fix` → PATCH, `feat` → MINOR,
breaking → MAJOR) and the build number by one, then add the matching section to
[CHANGELOG.md](../CHANGELOG.md).

## 2. Verify before tagging

```bash
bash scripts/perf.sh validate     # project references and placeholders, must be 0 errors
bash scripts/perf.sh build        # preflight + Debug build
xcodebuild test -project Maccy.xcodeproj -scheme Maccy -derivedDataPath .build \
  -destination 'platform=macOS' -only-testing:MaccyTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
```

`FloatingPanelPrewarmTests`, `ThumbnailRasterizationTests` and the row/selection tests are the ones
this fork changed. Two `ClipboardTests` cases need Xcode to be the frontmost application and fail in a
headless run on the fork *and* on upstream — the note is in `AGENTS.md`.

## 3. Build, sign, notarize

```bash
xcodebuild archive -project Maccy.xcodeproj -scheme Maccy -configuration Release \
  -archivePath /tmp/Maccy.xcarchive
xcodebuild -exportArchive -archivePath /tmp/Maccy.xcarchive \
  -exportOptionsPlist <your export options plist> -exportPath /tmp/Maccy-export
codesign --verify --deep --strict /tmp/Maccy-export/Maccy.app
xcrun notarytool submit /tmp/Maccy.zip --keychain-profile <profile> --wait
xcrun stapler staple /tmp/Maccy-export/Maccy.app
```

The bundle identifier has to stay `org.p0deje.Maccy`: the preferences and the history of everyone who
already uses Maccy live under it. A fork that wants to coexist with an installed Maccy has to change it
deliberately, and accept that it starts with an empty history and its own settings.

## 4. The update feed

`Maccy/Info.plist` points `SUFeedURL` at this repository's `appcast.xml`, not upstream's, so a build of
the fork can never be silently replaced by an upstream release — that would delete everything this fork
changes. Publishing an update therefore takes three steps:

1. **Own Sparkle key.** Once: generate a key pair (`generate_keys` from the Sparkle distribution) and
   put the public key into `Maccy/Info.plist` as `SUPublicEDKey`. The updater refuses an archive signed
   with a key it does not trust, which is exactly the protection wanted here.
2. **Sign the archive.** `sign_update Maccy.zip` prints the `sparkle:edSignature` value.
3. **Add the item** on top of `appcast.xml`: `<sparkle:version>` (build number),
   `<sparkle:shortVersionString>` (marketing version), and the enclosure with its URL, length, type and
   signature. Existing entries stay below; `<link>` already points at this repository's raw URL.

A channel with no `<item>` is valid and means "no update available" — that is what a fork build sees
until its first signed release is published.

## 5. Tag and publish

```bash
git tag -a v2.7.2 -m "2.7.2"
git push origin master v2.7.2
gh release create v2.7.2 --title 2.7.2 --notes-file <notes> Maccy.zip
```

Use the matching `CHANGELOG.md` section as the release notes.

## 6. After the release

Re-measure the scenarios in [performance-baseline.md](performance-baseline.md) against a baseline
rebuilt **in the same session** before putting any number into release notes: timings taken in
different sessions are not comparable, and this cost a wrong conclusion once already (rule 25 in
`AGENTS.md`).
