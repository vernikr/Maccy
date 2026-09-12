# Releasing this fork

Upstream Maccy releases itself. This is what a release of the fork has to do, and what it must not
inherit from upstream.

## 1. Version

`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` live in `Maccy.xcodeproj/project.pbxproj` (four
lines — both configurations). Bump the marketing version by SemVer (`fix` → PATCH, `feat` → MINOR,
breaking → MAJOR) and the build number by one, then add the matching section to
[CHANGELOG.md](../CHANGELOG.md).

## 2. Verify before tagging

CI does the same on every push ([`.github/workflows/tests.yml`](../.github/workflows/tests.yml)); it
skips the two `ClipboardTests` cases that assert which application is frontmost.

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

`scripts/release.sh` does everything below in one run and refuses to start when something is missing
(unknown tag already present, a dirty tree, no `CHANGELOG.md` section for the version, no `TEAM_ID`, no
Sparkle key). Run it with `TEAM_ID=<your team id> scripts/release.sh`; the rest of this file is what it
does and why.

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

1. **Own Sparkle key — already done for this fork.** The pair was generated with Sparkle's
   `bin/generate_keys`; the public half is in `Maccy/Info.plist` as `SUPublicEDKey`
   (`kfZtXtJQ1rmyaMjydt2XDq6yKsGrHPhAamkii1H4np8=`), the private half is in the login keychain of the
   machine that ran it. Back the private key up somewhere safe (`generate_keys -p` prints it) and treat
   it as the release secret: **without it no future release of this fork can be signed**, and
   regenerating the pair would orphan every build that is already installed. The updater refuses an
   archive signed with a key it does not trust, which is exactly the protection wanted here.
2. **Sign the archive.** `sign_update Maccy.zip` prints the `sparkle:edSignature` value. The first
   read of the private key makes macOS ask for permission to use it — allow it, and pick "Always
   Allow" so `scripts/release.sh` can run unattended afterwards. If no dialog appears, the command is
   simply waiting for it: check the screen rather than assuming it hung.
3. **Add the item** on top of `appcast.xml`: `<sparkle:version>` (build number),
   `<sparkle:shortVersionString>` (marketing version), and the enclosure with its URL, length, type and
   signature. Existing entries stay below; `<link>` already points at this repository's raw URL.

A channel with no `<item>` is valid and means "no update available" — that is what a fork build sees
until its first signed release is published.

## 5. Tag and publish

```bash
git tag -a v2.7.2 -m "2.7.2"
git push origin master v2.7.2
gh release create v2.7.2 --repo vernikr/Maccy --title 2.7.2 --notes-file <notes> Maccy.zip
```

Use the matching `CHANGELOG.md` section as the release notes. The `--repo` flag matters: this clone
has an `upstream` remote as well, and `gh` otherwise aims the release at `p0deje/Maccy`.

## 6. After the release

Re-measure the scenarios in [performance-baseline.md](performance-baseline.md) against a baseline
rebuilt **in the same session** before putting any number into release notes: timings taken in
different sessions are not comparable, and this cost a wrong conclusion once already (rule 25 in
`AGENTS.md`).
