#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/MeetRec.app"
PKG="$ROOT/MeetRec-AppStore.pkg"
APP_IDENTITY="${MEETREC_APPSTORE_APP_IDENTITY:-}"
INSTALLER_IDENTITY="${MEETREC_APPSTORE_INSTALLER_IDENTITY:-}"

if [[ -z "$APP_IDENTITY" ]]; then
  APP_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(3rd Party Mac Developer Application:[^"]*\)".*/\1/p' \
    | head -1)"
fi

if [[ -z "$INSTALLER_IDENTITY" ]]; then
  INSTALLER_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(3rd Party Mac Developer Installer:[^"]*\)".*/\1/p' \
    | head -1)"
fi

if [[ -z "$APP_IDENTITY" || -z "$INSTALLER_IDENTITY" ]]; then
  cat >&2 <<'EOF'
Missing Mac App Store signing identities.

Install the "3rd Party Mac Developer Application" and
"3rd Party Mac Developer Installer" certificates, or set:

  MEETREC_APPSTORE_APP_IDENTITY
  MEETREC_APPSTORE_INSTALLER_IDENTITY
EOF
  exit 1
fi

MEETREC_BUNDLE_IDENTIFIER="jp.temosy.meetrec" \
MEETREC_ENTITLEMENTS="$ROOT/entitlements/app-store.entitlements" \
MEETREC_CODESIGN_IDENTITY="$APP_IDENTITY" \
"$ROOT/scripts/build-app.sh" >/dev/null

productbuild \
  --component "$APP" /Applications \
  --sign "$INSTALLER_IDENTITY" \
  "$PKG"

echo "$PKG"
