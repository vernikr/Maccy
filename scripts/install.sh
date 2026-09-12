#!/bin/bash
# Puts this fork on this machine in place of the Maccy you already have.
#
# Why it is not just "copy the app into /Applications": Maccy is sandboxed, so its clipboard
# history and its settings live in ~/Library/Containers/org.p0deje.Maccy, and macOS only lets an
# app use that container when the app is *signed with the sandbox entitlement*. A plain
# `xcodebuild` build is unsigned, so it would come up sandbox-free, with an empty history taken
# from ~/Library/Application Support/Maccy. This script therefore signs the build — ad-hoc when no
# Apple certificate is available, which is enough for the sandbox to apply and for this Mac to
# keep the very same container, the same history and the same settings.
#
# Usage: scripts/install.sh [--no-build] [--no-launch] [--dry-run]
#
#   CODESIGN_IDENTITY  certificate to sign with (default: the best one in the keychain —
#                      "Developer ID Application", then "Apple Development", then the
#                      local "Maccy Local Signing"; with no certificate at all the script
#                      falls back to ad-hoc signing, which works but changes the app's
#                      identity on every rebuild — see scripts/create-signing-identity.sh)
#   APP_DIR            where the app is installed            (default: /Applications)
#   BACKUP_DIR         where the app and the container are   (default: ~/Library/Application Support/MaccyFork)
#                      copied before being touched
#   SOURCE_APP         the .app to install                     (default: the Release build in .build)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BUILD=1
LAUNCH=1
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    --no-launch) LAUNCH=0 ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

APP_DIR="${APP_DIR:-/Applications}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/Library/Application Support/MaccyFork}"
# SOURCE_APP lets you install a build made with another -derivedDataPath, which is how a rebuild can
# be told apart from what is already installed.
BUILT_APP="${SOURCE_APP:-$ROOT_DIR/.build/Build/Products/Release/Maccy.app}"
LOG=/tmp/maccy-install-build.log

step() { echo; echo "=== $*"; }
run() {
  if [ "$DRY_RUN" = 1 ]; then echo "  [dry run] $*"; else "$@"; fi
}
fail() { echo "error: $*" >&2; exit 1; }

# MARK: - Build

if [ "$BUILD" = 1 ]; then
  step "Building Release into .build"
  bash scripts/perf.sh validate
  # Rule 2 of AGENTS.md: never diagnose from `tail`; the whole log goes to a file.
  if [ "$DRY_RUN" = 1 ]; then
    echo "  [dry run] xcodebuild build -configuration Release … > $LOG"
  else
    xcodebuild build -project Maccy.xcodeproj -scheme Maccy -configuration Release \
      -derivedDataPath .build -destination 'platform=macOS' \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" > "$LOG" 2>&1 \
      || { grep -n "error:" "$LOG" | head -20; fail "the build failed, full log in $LOG"; }
  fi
fi

[ -d "$BUILT_APP" ] || fail "no $BUILT_APP — build it first (or drop --no-build)"
[ "$DRY_RUN" = 1 ] || [ -x "$BUILT_APP/Contents/MacOS/Maccy" ] || fail "$BUILT_APP is not a complete app bundle"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$BUILT_APP/Contents/Info.plist")
BUILD_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$BUILT_APP/Contents/Info.plist")
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$BUILT_APP/Contents/Info.plist")
TARGET_APP="$APP_DIR/Maccy.app"
CONTAINER="$HOME/Library/Containers/$BUNDLE_ID"
STORE="$CONTAINER/Data/Library/Application Support/Maccy/Storage.sqlite"

echo
echo "Installing Maccy $VERSION ($BUILD_VERSION), bundle id $BUNDLE_ID"
echo "  from  $BUILT_APP"
echo "  to    $TARGET_APP"
echo "  data  $CONTAINER"

# MARK: - Sign

step "Signing"

# The entitlements file is written for Xcode, so its $(PRODUCT_BUNDLE_IDENTIFIER) has to be
# resolved here. The values are the ones upstream ships; keeping them identical is what lets the
# existing sandbox container be reused.
ENTITLEMENTS=$(mktemp -t maccy-entitlements)
sed "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/g" Maccy/Maccy.entitlements > "$ENTITLEMENTS"

IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1 || true)
fi
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1 || true)
fi
if [ -z "$IDENTITY" ]; then
  # A certificate this machine made for itself: same designated requirement on every build, so the
  # permissions macOS attaches to the app survive rebuilds. See scripts/create-signing-identity.sh.
  IDENTITY=$(security find-identity -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Maccy Local Signing\)".*/\1/p' | head -1 || true)
  if [ -n "$IDENTITY" ]; then
    echo "  signing with the certificate created by scripts/create-signing-identity.sh"
  fi
fi
if [ -z "$IDENTITY" ]; then
  IDENTITY="-"
  echo "  no certificate on this machine → signing ad-hoc. The sandbox still applies and the"
  echo "  container is still reused, but an ad-hoc signature is the *hash of this build*: every"
  echo "  rebuild looks like a different app to macOS, so permissions granted to Maccy"
  echo "  (Accessibility for pasting) are asked again. Fix once with:"
  echo "      scripts/create-signing-identity.sh"
fi
[ "$IDENTITY" = "-" ] || echo "  identity: $IDENTITY"

# --deep signs Sparkle.framework and its helpers with the same entitlements, which is what the
# sandboxed upstream build does too. Notarization is a separate matter — see docs/releasing.md.
run codesign --force --deep --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" --options runtime "$BUILT_APP"
if [ "$DRY_RUN" = 0 ]; then
  codesign --verify --strict "$BUILT_APP"
  codesign -d --entitlements - "$BUILT_APP" 2>&1 | grep -q "com.apple.security.app-sandbox" \
    || fail "the signature carries no app-sandbox entitlement — the container would not be reused"
  echo "  signed, sandbox entitlement present"
  # The designated requirement is what macOS stores (in TCC, in keychain ACLs) and later re-checks
  # against the app. Ours is printed here so that "are permissions stable?" is answerable without
  # guessing: `certificate` means yes, `cdhash` means only until the next rebuild.
  DR=$(codesign -d -r- "$BUILT_APP" 2>&1 | sed -n 's/^#* *designated => //p')
  echo "  requirement: $DR"
  case "$DR" in
    *cdhash*) echo "  ⚠ per-build requirement: a rebuild will look like a different app to macOS" ;;
    *)        echo "  ✓ stable across rebuilds (it names the certificate, not the binary)" ;;
  esac
fi
rm -f "$ENTITLEMENTS"

# MARK: - Backup

STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="$BACKUP_DIR/backup-$STAMP"

step "Backing up what is about to be replaced"
run mkdir -p "$BACKUP"
if [ -d "$CONTAINER" ]; then
  run ditto "$CONTAINER" "$BACKUP/container"
  echo "  container → $BACKUP/container"
else
  echo "  no container yet ($CONTAINER) — nothing to keep"
fi
if [ -d "$TARGET_APP" ]; then
  run ditto "$TARGET_APP" "$BACKUP/Maccy.app"
  echo "  app       → $BACKUP/Maccy.app"
fi
if [ "$DRY_RUN" = 0 ]; then
  printf '%s\n' "replaced by $VERSION ($BUILD_VERSION) built from $(git rev-parse --short HEAD 2>/dev/null || echo '?')" \
    > "$BACKUP/WHAT-WAS-HERE.txt"
fi

# MARK: - Replace

step "Quitting the running Maccy"
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
for _ in $(seq 1 20); do
  pgrep -x Maccy >/dev/null || break
  sleep 0.25
done
if pgrep -x Maccy >/dev/null; then
  echo "  did not quit on its own, killing it"
  run pkill -x Maccy || true
  sleep 1
fi
echo "  done"

step "Installing"
run rm -rf "$TARGET_APP"
run ditto "$BUILT_APP" "$TARGET_APP"
run xattr -dr com.apple.quarantine "$TARGET_APP"
# Without this LaunchServices can keep the old bundle's icon and Mach-O in place for a while.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREGISTER" ] && run "$LSREGISTER" -f "$TARGET_APP"

if [ "$DRY_RUN" = 0 ]; then
  step "Verifying"
  codesign --verify --strict --verbose=1 "$TARGET_APP" 2>&1 | sed 's/^/  /'
  echo "  installed version: $(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$TARGET_APP/Contents/Info.plist") ($(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$TARGET_APP/Contents/Info.plist"))"
  if [ -f "$STORE" ]; then
    # The store is the Core Data database, so the entity lands in ZHISTORYITEM.
    ITEMS=$(sqlite3 -readonly "$STORE" "select count(*) from ZHISTORYITEM" 2>/dev/null || echo "?")
    echo "  history in the container: $ITEMS items ($STORE)"
  else
    echo "  no history yet at $STORE — the app will create it"
  fi
fi

# MARK: - Launch

if [ "$LAUNCH" = 1 ]; then
  step "Opening the installed app"
  run open "$TARGET_APP"
fi

cat <<EOF

=== Installed

  $TARGET_APP is now Maccy $VERSION ($BUILD_VERSION).
  The sandbox container was left in place, so the history and the settings are the ones you had.
  Autostart at login still points at $TARGET_APP and keeps working.

  To go back:
    rm -rf "$TARGET_APP" "$CONTAINER"
    ditto "$BACKUP/Maccy.app" "$TARGET_APP"
    ditto "$BACKUP/container" "$CONTAINER"

  To update later, after pulling:
    git pull && scripts/install.sh
EOF
