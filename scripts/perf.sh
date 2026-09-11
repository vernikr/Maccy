#!/usr/bin/env bash
# Helper around the Maccy performance instrumentation (see docs/performance-profiling.md).
#
#   scripts/perf.sh on            enable signposts for every launch (persisted preference)
#   scripts/perf.sh off           disable them
#   scripts/perf.sh status        show whether they are currently enabled
#   scripts/perf.sh stream        tail signpost/zone summaries with `log stream`
#   scripts/perf.sh validate      check project references with scripts/validate-pbxproj.py
#   scripts/perf.sh preflight     validate + placeholder check (build runs this automatically)
#   scripts/perf.sh build         run preflight, then build a Debug app into .build (no signing)
#   scripts/perf.sh record [trace] [seconds]
#                                 record a trace with the Instruments "Points of Interest"
#                                 template and launch the app
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATOR="$ROOT_DIR/scripts/validate-pbxproj.py"
BUNDLE_ID="org.p0deje.Maccy"
DEFAULT_APP="$ROOT_DIR/.build/Build/Products/Debug/Maccy.app"
APP="${MACCY_APP:-$DEFAULT_APP}"

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
}

require_app() {
  if [[ ! -d "$APP" ]]; then
    echo "Maccy.app not found at: $APP" >&2
    echo "Build it first with 'scripts/perf.sh build' or set MACCY_APP=/path/to/Maccy.app." >&2
    exit 1
  fi
}

cmd_validate() {
  python3 "$VALIDATOR" "$ROOT_DIR/Maccy.xcodeproj" "$@"
}

# Runs before every build: catches project mistakes that Xcode reports silently
# (an ignored build-phase entry shows up much later as "Executed 0 tests").
cmd_preflight() {
  local status=0 hits

  echo "== project references =="
  cmd_validate || status=1

  echo "== placeholder tokens in Swift sources =="
  hits="$(grep -rIn --include='*.swift' -E '([[:alnum:]]-placeholder|TODO: remove)' \
    "$ROOT_DIR/Maccy" "$ROOT_DIR/MaccyTests" "$ROOT_DIR/MaccyUITests" 2>/dev/null || true)"
  if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" >&2
    echo "error: placeholder token left in the source" >&2
    status=1
  else
    echo "ok: no placeholder tokens"
  fi

  return "$status"
}

cmd_build() {
  if ! cmd_preflight; then
    echo "error: preflight failed, not building" >&2
    exit 1
  fi

  echo "Building Debug into $ROOT_DIR/.build …"
  xcodebuild \
    -project "$ROOT_DIR/Maccy.xcodeproj" \
    -scheme Maccy \
    -configuration Debug \
    -derivedDataPath "$ROOT_DIR/.build" \
    build \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
  echo "Built: $DEFAULT_APP"
}

cmd_on() {
  defaults write "$BUNDLE_ID" perfSignposts -bool YES
  echo "Signposts enabled for $BUNDLE_ID. Relaunch Maccy to apply."
  echo "For a single run instead: MACCY_PERF=1 '$APP/Contents/MacOS/Maccy'"
}

cmd_off() {
  defaults delete "$BUNDLE_ID" perfSignposts 2>/dev/null || true
  echo "Signposts disabled for $BUNDLE_ID. Relaunch Maccy to apply."
}

cmd_status() {
  local stored env
  stored="$(defaults read "$BUNDLE_ID" perfSignposts 2>/dev/null || echo "unset")"
  env="${MACCY_PERF:-unset}"
  echo "perfSignposts preference: $stored"
  echo "MACCY_PERF environment:   $env"
  echo "App path:                 $APP"
}

cmd_stream() {
  echo "Streaming $BUNDLE_ID logs (signposts + zone summaries). Ctrl-C to stop."
  log stream --predicate "subsystem == \"$BUNDLE_ID\"" --level debug --style compact
}

cmd_record() {
  local output="${1:-/tmp/maccy-perf.trace}" seconds="${2:-30}"
  require_app
  rm -rf "$output"
  echo "Recording ${seconds}s with the 'Points of Interest' template into $output …"
  xcrun xctrace record \
    --template 'Points of Interest' \
    --launch "$APP" \
    --time-limit "${seconds}s" \
    --output "$output"
  echo "Done: $output"
  echo "Add more instruments (Time Profiler, SwiftUI, Animation Hitches) in the trace UI."
}

case "${1:-}" in
  on) cmd_on ;;
  off) cmd_off ;;
  status) cmd_status ;;
  stream) cmd_stream ;;
  validate) shift; cmd_validate "$@" ;;
  preflight) cmd_preflight ;;
  build) cmd_build ;;
  record) shift; cmd_record "${1:-/tmp/maccy-perf.trace}" "${2:-30}" ;;
  *) usage ;;
esac
