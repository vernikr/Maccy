#!/bin/bash
# Cuts a release of this fork: verified build → signed and notarized archive → zip → Sparkle
# signature → appcast entry.
#
# It must run on a machine that has
#   * a Developer ID Application certificate in the login keychain,
#   * notarytool credentials stored under a keychain profile
#     (`xcrun notarytool store-credentials <profile> --apple-id … --team-id …`),
#   * this fork's Sparkle private key in the login keychain (Sparkle's `bin/generate_keys`).
#
# What each piece is for, and what to do when one of them is missing, is in docs/releasing.md.
#
# Usage: TEAM_ID=ABCDE12345 scripts/release.sh [--skip-tests] [--dry-run]
#   NOTARY_PROFILE   keychain profile for notarytool       (default: maccy-notary)
#   SPARKLE_BIN      directory with sign_update/generate_keys (default: the SPM checkout)
#   OUT_DIR          where the archive and the zip go       (default: /tmp/maccy-release-<version>)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SKIP_TESTS=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --skip-tests) SKIP_TESTS=1 ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

NOTARY_PROFILE="${NOTARY_PROFILE:-maccy-notary}"
SPARKLE_BIN="${SPARKLE_BIN:-$ROOT_DIR/.build/SourcePackages/artifacts/sparkle/Sparkle/bin}"

fail() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "=== $*"; }
run() {
  if [ "$DRY_RUN" = 1 ]; then echo "  [dry run] $*"; else "$@"; fi
}

# MARK: - What is being released

VERSION=$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' Maccy.xcodeproj/project.pbxproj | head -1)
BUILD=$(sed -n 's/.*CURRENT_PROJECT_VERSION = \(.*\);/\1/p' Maccy.xcodeproj/project.pbxproj | head -1)
[ -n "$VERSION" ] && [ -n "$BUILD" ] || fail "cannot read the version from Maccy.xcodeproj/project.pbxproj"

TAG="v$VERSION"
OUT_DIR="${OUT_DIR:-/tmp/maccy-release-$VERSION}"
ARCHIVE="$OUT_DIR/Maccy.xcarchive"
EXPORT_DIR="$OUT_DIR/export"
ZIP="$OUT_DIR/Maccy-$VERSION.zip"
export_options="$OUT_DIR/exportOptions.plist"

step "Releasing $VERSION (build $BUILD), tag $TAG, output $OUT_DIR"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  fail "tag $TAG already exists — bump MARKETING_VERSION and CURRENT_PROJECT_VERSION first"
fi
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  fail "the working tree has uncommitted changes; commit or stash them first"
fi
grep -q "^## \[$VERSION\]" CHANGELOG.md || fail "CHANGELOG.md has no section for $VERSION"
if [ -z "${TEAM_ID:-}" ]; then
  fail "set TEAM_ID to your Apple Developer team id (used for signing and notarization)"
fi
[ -x "$SPARKLE_BIN/sign_update" ] || fail "sign_update not found in $SPARKLE_BIN (set SPARKLE_BIN)"

PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" Maccy/Info.plist 2>/dev/null || true)
[ -n "$PUBLIC_KEY" ] || fail "Maccy/Info.plist has no SUPublicEDKey (see docs/releasing.md, step 4)"

mkdir -p "$OUT_DIR"

# MARK: - Verify

step "Checks"
run bash scripts/perf.sh validate
run bash scripts/perf.sh build
if [ "$SKIP_TESTS" = 0 ]; then
  run xcodebuild test -project Maccy.xcodeproj -scheme Maccy -configuration Debug \
    -derivedDataPath .build -destination 'platform=macOS' \
    -only-testing:MaccyTests \
    -skip-testing:MaccyTests/ClipboardTests/testIgnoreApplication \
    -skip-testing:MaccyTests/ClipboardTests/testIgnoreAllApplicationsExcept \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
fi

# MARK: - Archive, sign, notarize

step "Archiving"
run xcodebuild archive -project Maccy.xcodeproj -scheme Maccy -configuration Release \
  -archivePath "$ARCHIVE" -destination 'generic/platform=macOS' \
  CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM="$TEAM_ID"

cat > "$export_options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
</dict>
</plist>
PLIST

step "Exporting the signed app"
run rm -rf "$EXPORT_DIR"
run xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$export_options" \
  -exportPath "$EXPORT_DIR"

APP="$EXPORT_DIR/Maccy.app"
if [ "$DRY_RUN" = 0 ]; then
  [ -d "$APP" ] || fail "no Maccy.app in $EXPORT_DIR"
  codesign --verify --deep --strict --verbose=2 "$APP"

  step "Notarizing (this waits for Apple, usually a couple of minutes)"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute -vv "$APP"
fi

# MARK: - Update feed

step "Signing the archive for Sparkle"
rm -f "$ZIP"
if [ "$DRY_RUN" = 0 ]; then
  ditto -c -k --keepParent "$APP" "$ZIP"
fi
SIGNATURE_OUTPUT=$("$SPARKLE_BIN/sign_update" "$ZIP")
echo "  $SIGNATURE_OUTPUT"
ED_SIGNATURE=$(printf '%s' "$SIGNATURE_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
LENGTH=$(printf '%s' "$SIGNATURE_OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')
[ -n "$ED_SIGNATURE" ] && [ -n "$LENGTH" ] || fail "cannot parse the output of sign_update"
URL="https://github.com/vernikr/Maccy/releases/download/$TAG/Maccy-$VERSION.zip"

step "Adding the appcast entry"
if [ "$DRY_RUN" = 1 ]; then
  echo "  [dry run] would add $VERSION (build $BUILD) to appcast.xml"
else
  cp appcast.xml "$OUT_DIR/appcast.xml.bak"
  VERSION="$VERSION" BUILD="$BUILD" URL="$URL" LENGTH="$LENGTH" SIGNATURE="$ED_SIGNATURE" \
  python3 - <<'PY'
import os, pathlib
path = pathlib.Path("appcast.xml")
text = path.read_text(encoding="utf-8")
item = f"""    <item>
      <title>{os.environ["VERSION"]}</title>
      <link>https://github.com/vernikr/Maccy/releases/tag/v{os.environ["VERSION"]}</link>
      <sparkle:version>{os.environ["BUILD"]}</sparkle:version>
      <sparkle:shortVersionString>{os.environ["VERSION"]}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="{os.environ["URL"]}"
                 sparkle:edSignature="{os.environ["SIGNATURE"]}"
                 length="{os.environ["LENGTH"]}"
                 type="application/octet-stream" />
    </item>
"""
marker = "    <language>en</language>\n"
if marker not in text:
    raise SystemExit("appcast.xml has no <language> element to insert after")
path.write_text(text.replace(marker, marker + item, 1), encoding="utf-8")
print("  appcast.xml updated (backup in the output directory)")
PY
fi

# MARK: - What is left for the human

cat <<EOF

=== Ready to publish

  git add appcast.xml
  git commit -m "chore(release): publish $VERSION"
  git tag -a $TAG -m "$VERSION"
  git push origin master $TAG
  gh release create $TAG --repo vernikr/Maccy --title "$VERSION" \\
    --notes-file <the $VERSION section of CHANGELOG.md> "$ZIP"

The archive is signed with this fork's Sparkle key by the enclosure above, so a build already
installed can update to it.
EOF
