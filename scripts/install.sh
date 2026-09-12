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
# Usage: scripts/install.sh [--no-build] [--no-launch] [--no-auto-update] [--dry-run]
#
#   --no-auto-update   leave Sparkle's preferences alone (by default the script turns on silent
#                      updates, so this fork keeps itself current without a rebuild)
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
AUTO_UPDATE=1
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    --no-launch) LAUNCH=0 ;;
    --no-auto-update) AUTO_UPDATE=0 ;;
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

if [ "$DRY_RUN" = 1 ]; then
  echo "  [dry run] scripts/sign-app.sh \"$BUILT_APP\""
else
  # All of the signature lives in one place (scripts/sign-app.sh): which identity, the sandbox
  # entitlement on the app, and Sparkle's helpers deliberately left unsandboxed so that the update
  # check can still reach the network.
  bash "$ROOT_DIR/scripts/sign-app.sh" "$BUILT_APP"
fi

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

# MARK: - Sparkle preferences

# An installed build should keep itself current: Sparkle checks at launch, and
# SUAutomaticallyUpdate makes it install the update on quit instead of waiting for someone to
# agree to a dialog. Both live in the app's sandbox container. The path is spelled out rather than
# using the bundle id: rule 10 of AGENTS.md — `defaults` on a bundle id resolves to whichever app
# holds that id, so a stray `defaults write org.p0deje.Maccy` from a non-installed build lands
# somewhere else entirely.
if [ "$AUTO_UPDATE" = 1 ]; then
  step "Letting Sparkle keep this install up to date"
  PREF_DOMAIN="$CONTAINER/Data/Library/Preferences/$BUNDLE_ID"
  FEED=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$TARGET_APP/Contents/Info.plist" 2>/dev/null || true)
  echo "  feed: ${FEED:-<none — nothing could ever update>}"
  run mkdir -p "$(dirname "$PREF_DOMAIN")"
  run defaults write "$PREF_DOMAIN" SUAutomaticallyUpdate -bool true
  # Forgetting the last check makes the next launch check immediately instead of in a day.
  run defaults delete "$PREF_DOMAIN" SULastCheckTime 2>/dev/null || true
  if [ "$DRY_RUN" = 0 ]; then
    echo "  SUAutomaticallyUpdate = $(defaults read "$PREF_DOMAIN" SUAutomaticallyUpdate 2>/dev/null || echo '?')"
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

  It also keeps itself current on its own: Sparkle checks at launch and installs the update when
  you quit, from this fork's own appcast. Push a release with scripts/local-release.sh and the app
  picks it up; run with --no-auto-update to leave those preferences alone.
EOF
