#!/bin/bash
# Signs a Maccy.app for local use: inside out, with hardened runtime, and with the sandbox
# entitlement on the app only.
#
# Why the nested code is signed separately. Sparkle's XPC services and its Updater app are the
# processes that reach the network and replace the bundle in /Applications. In the upstream build
# they carry no entitlements at all (check: `codesign -d --entitlements - ` on Downloader.xpc,
# Installer.xpc, Updater.app, Autoupdate prints an empty dict). `codesign --deep` stamps the *app's*
# entitlements on them instead — including app-sandbox — and then the update check quietly fails:
# a sandboxed process cannot open a network connection it has no entitlement for, and nothing in the
# app says so. So each nested item is signed on its own, without entitlements.
#
# Usage: scripts/sign-app.sh <path/to/Maccy.app>
#
#   CODESIGN_IDENTITY  certificate to sign with (default: the best one in the keychain —
#                      "Developer ID Application", then "Apple Development", then the local
#                      "Maccy Local Signing" created by scripts/create-signing-identity.sh, and
#                      finally ad-hoc, which costs the app its identity between rebuilds)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:?usage: scripts/sign-app.sh <path/to/Maccy.app>}"
[ -d "$APP" ] || { echo "error: no such app bundle: $APP" >&2; exit 1; }

fail() { echo "error: $*" >&2; exit 1; }

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")
ENTITLEMENTS=$(mktemp -t maccy-entitlements)
trap 'rm -f "$ENTITLEMENTS"' EXIT
# The file is written for Xcode, so its $(PRODUCT_BUNDLE_IDENTIFIER) is resolved here. Keeping it
# identical to upstream's is what lets an existing sandbox container be reused.
sed "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/g" "$ROOT_DIR/Maccy/Maccy.entitlements" > "$ENTITLEMENTS"

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
  # Not listed by `find-identity -v`: the certificate is self-signed, so it is not "valid".
  IDENTITY=$(security find-identity -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Maccy Local Signing\)".*/\1/p' | head -1 || true)
fi
if [ -z "$IDENTITY" ]; then
  IDENTITY="-"
  echo "  no certificate on this machine → signing ad-hoc. The sandbox still applies and the"
  echo "  container is still reused, but an ad-hoc signature is the hash of this build: every"
  echo "  rebuild looks like a different app to macOS, so permissions granted to Maccy (Accessibility"
  echo "  for pasting) are asked again. Fix once with scripts/create-signing-identity.sh."
else
  echo "  identity: $IDENTITY"
fi

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
if [ -d "$SPARKLE" ]; then
  for item in "$SPARKLE"/XPCServices/*.xpc "$SPARKLE/Updater.app" "$SPARKLE/Autoupdate"; do
    [ -e "$item" ] && codesign --force --sign "$IDENTITY" --options runtime "$item"
  done
  codesign --force --sign "$IDENTITY" --options runtime "$APP/Contents/Frameworks/Sparkle.framework"
fi
codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" --options runtime "$APP"

codesign --verify --strict "$APP" || fail "the signature does not verify"
codesign -d --entitlements - "$APP" 2>&1 | grep -q "com.apple.security.app-sandbox" \
  || fail "the signature carries no app-sandbox entitlement — the container would not be reused"
echo "  signed, sandbox entitlement present"

# Asserted rather than assumed: a sandbox on Sparkle's helpers breaks updates with no visible error.
if [ -d "$SPARKLE" ]; then
  for item in "$SPARKLE"/XPCServices/*.xpc "$SPARKLE/Updater.app" "$SPARKLE/Autoupdate"; do
    [ -e "$item" ] || continue
    codesign -d --entitlements - "$item" 2>&1 | grep -q "app-sandbox" \
      && fail "$(basename "$item") came out sandboxed — Sparkle could not download or install updates"
  done
  echo "  Sparkle helpers are not sandboxed: ok"
fi

# What macOS stores when it grants a permission (TCC, keychain ACLs) and re-checks later. A
# `certificate root = H"…"` requirement survives rebuilds; `cdhash H"…"` does not.
DR=$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^#* *designated => //p')
echo "  requirement: $DR"
case "$DR" in
  *cdhash*) echo "  ⚠ per-build requirement: a rebuild will look like a different app to macOS" ;;
  *)        echo "  ✓ stable across rebuilds (it names the certificate, not the binary)" ;;
esac
