#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/MeetRec.app"
INSTALLED_APP="/Applications/MeetRec.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

sign_app() {
  local app="$1"
  local identity="${MEETREC_CODESIGN_IDENTITY:-}"

  if [[ -z "$identity" ]]; then
    identity="$(security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
      | head -1)"
  fi

  if [[ -n "$identity" ]]; then
    codesign --force --deep --sign "$identity" "$app" >/dev/null
  else
    codesign --force --deep --sign - "$app" >/dev/null
  fi
}

cd "$ROOT"
scripts/build-app.sh >/dev/null

ditto "$APP" "$INSTALLED_APP"
sign_app "$INSTALLED_APP"
"$LSREGISTER" -f "$INSTALLED_APP"
touch "$INSTALLED_APP"

echo "$INSTALLED_APP"
