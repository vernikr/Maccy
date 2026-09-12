#!/bin/bash
# Cuts a release that a locally installed build can update itself from — no Developer ID and no
# notarization needed, which is the point: `scripts/release.sh` exists for the public, signed path,
# this one for the machine you are sitting at.
#
# What makes a self-signed build updateable: Sparkle accepts an update when *either* the archive's
# EdDSA signature verifies against the running app's SUPublicEDKey *or* the two apps' code signatures
# match (Sparkle/SUUpdateValidator.m: `if (passedDSACheck || passedCodeSigning)`). A local build has
# this fork's public key, and this script signs the archive with the matching private half, so the
# first condition is what carries the update. The app's own signature is not required to match — but
# because it is a certificate signature rather than ad-hoc, the app also keeps the permissions macOS
# granted it across the update (see docs/installing.md).
#
# Usage: scripts/local-release.sh [--version X.Y.Z] [--build N] [--no-publish] [--dry-run]
#
#   VERSION / BUILD    read from Maccy.xcodeproj/project.pbxproj unless overridden
#   SPARKLE_BIN        directory holding sign_update (default: the SPM checkout)
#   OUT_DIR            where the archive and the zip go      (default: /tmp/maccy-local-release-<version>)
#   GH_REPO            repository to publish the archive to    (default: vernikr/Maccy)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION=""
BUILD=""
PUBLISH=1
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
    --build) BUILD="${2:?--build needs a value}"; shift 2 ;;
    --no-publish) PUBLISH=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$VERSION" ] || VERSION=$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' Maccy.xcodeproj/project.pbxproj | head -1)
[ -n "$BUILD" ] || BUILD=$(sed -n 's/.*CURRENT_PROJECT_VERSION = \(.*\);/\1/p' Maccy.xcodeproj/project.pbxproj | head -1)
[ -n "$VERSION" ] && [ -n "$BUILD" ] || { echo "error: cannot read the version from project.pbxproj" >&2; exit 1; }

SPARKLE_BIN="${SPARKLE_BIN:-$ROOT_DIR/.build/SourcePackages/artifacts/sparkle/Sparkle/bin}"
GH_REPO="${GH_REPO:-vernikr/Maccy}"
OUT_DIR="${OUT_DIR:-/tmp/maccy-local-release-$VERSION}"
TAG="v$VERSION"
APP="$OUT_DIR/Maccy.app"
ZIP="$OUT_DIR/Maccy-$VERSION.zip"
LOG=/tmp/maccy-local-release-build.log

step() { echo; echo "=== $*"; }
run() { if [ "$DRY_RUN" = 1 ]; then echo "  [dry run] $*"; else "$@"; fi; }
fail() { echo "error: $*" >&2; exit 1; }

step "Local release $VERSION (build $BUILD), output $OUT_DIR"

grep -q "^## \[$VERSION\]" CHANGELOG.md || echo "  note: CHANGELOG.md has no section for $VERSION"
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "  note: the working tree has uncommitted changes; this release will not match a commit exactly"
fi
[ -x "$SPARKLE_BIN/sign_update" ] || fail "sign_update not found in $SPARKLE_BIN (set SPARKLE_BIN)"
PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" Maccy/Info.plist 2>/dev/null || true)
[ -n "$PUBLIC_KEY" ] || fail "Maccy/Info.plist has no SUPublicEDKey — nothing could verify the archive"
FEED_URL=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" Maccy/Info.plist 2>/dev/null || true)
echo "  feed the app reads: $FEED_URL"
echo "  archive will be signed with the private key for $PUBLIC_KEY"

# MARK: - Build and sign

step "Building"
mkdir -p "$OUT_DIR"
run rm -rf "$APP"
if [ "$DRY_RUN" = 1 ]; then
  echo "  [dry run] xcodebuild build -configuration Release MARKETING_VERSION=$VERSION …"
else
  xcodebuild build -project Maccy.xcodeproj -scheme Maccy -configuration Release \
    -derivedDataPath "$OUT_DIR/dd" -destination 'platform=macOS' \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" > "$LOG" 2>&1 \
    || { grep -n "error:" "$LOG" | head -20; fail "the build failed, full log in $LOG"; }
  ditto "$OUT_DIR/dd/Build/Products/Release/Maccy.app" "$APP"
fi

step "Signing"
if [ "$DRY_RUN" = 1 ]; then
  echo "  [dry run] scripts/sign-app.sh $APP"
else
  bash scripts/sign-app.sh "$APP"
  echo "  built version: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist"))"
fi

# MARK: - Sparkle signature

step "Signing the archive for Sparkle"
if [ "$DRY_RUN" = 1 ]; then
  echo "  [dry run] ditto -c -k --keepParent $APP $ZIP && sign_update $ZIP"
  SIGNATURE_OUTPUT='sparkle:edSignature="SIMULATED" length="0"'
else
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  # The first read of the private key may make macOS ask for permission; approve once and it stops
  # asking (docs/releasing.md, step 4).
  SIGNATURE_OUTPUT=$("$SPARKLE_BIN/sign_update" "$ZIP")
fi
echo "  $SIGNATURE_OUTPUT"
ED_SIGNATURE=$(printf '%s' "$SIGNATURE_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
LENGTH=$(printf '%s' "$SIGNATURE_OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')
[ "$DRY_RUN" = 1 ] || { [ -n "$ED_SIGNATURE" ] && [ -n "$LENGTH" ] || fail "cannot parse sign_update output"; }

# MARK: - Publish the archive

ASSET_URL="https://github.com/$GH_REPO/releases/download/$TAG/Maccy-$VERSION.zip"
NOTES="$OUT_DIR/release-notes.md"
cat > "$NOTES" <<EOF
Local build of this fork, $VERSION ($BUILD), signed with the fork's own certificate instead of a
Developer ID, and not notarized.

This archive exists so that a machine already running a locally signed build of this fork can
update itself through Sparkle: the zip is signed with the fork's Sparkle key, which is what
Sparkle verifies. Because the certificate is self-signed and unknown elsewhere, macOS will refuse
to run it on any other machine.

Everyone else should use upstream Maccy or Homebrew.
EOF

if [ "$PUBLISH" = 1 ]; then
  step "Publishing the archive as a GitHub release"
  run cp appcast.xml "$OUT_DIR/appcast.xml.before"
  if [ "$DRY_RUN" = 1 ]; then
    echo "  [dry run] gh release create $TAG --repo $GH_REPO … $ZIP"
  elif gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1; then
    gh release upload "$TAG" "$ZIP" --repo "$GH_REPO" --clobber
  else
    gh release create "$TAG" --repo "$GH_REPO" --title "$VERSION" --notes-file "$NOTES" "$ZIP"
  fi
else
  step "Not publishing (--no-publish)"
  echo "  the appcast entry below points at $ASSET_URL"
fi

# MARK: - The appcast entry

step "Adding the entry to appcast.xml"
run python3 scripts/update-appcast.py --version "$VERSION" --build "$BUILD" \
  --url "$ASSET_URL" --length "${LENGTH:-0}" --signature "${ED_SIGNATURE:-SIMULATED}"

cat <<EOF

=== Publish the feed

  git add appcast.xml
  git commit -m "chore(release): publish $VERSION"
  git push origin master

Then an installed build whose feed is this repository's appcast.xml finds the release on its own:
Sparkle checks at launch, and once the last check is older than a day it checks immediately. Two
preferences decide how that goes, and they live in the *installed* app's sandbox container — aiming
`defaults` at the bundle id from a non-installed build would write somewhere else entirely
(AGENTS.md rule 10):

  P="$HOME/Library/Containers/org.p0deje.Maccy/Data/Library/Preferences"
  defaults write "$P/org.p0deje.Maccy" SUAutomaticallyUpdate -bool true   # install on quit, no alert
  defaults delete "$P/org.p0deje.Maccy" SULastCheckTime                   # forget the last check

`scripts/install.sh` seeds both, so an installed build keeps itself current from here on.

To watch an update land without waiting for the daily schedule, delete SULastCheckTime (above) and
relaunch the app: the check, the download, the EdDSA verification and the install-on-quit all show up
in `log show --predicate 'subsystem CONTAINS "sparkle"'`. The new version is what starts next time.
EOF
