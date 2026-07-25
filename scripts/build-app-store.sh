#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/MeetRec.app"
PKG="$ROOT/MeetRec-AppStore.pkg"
APP_IDENTITY="${MEETREC_APPSTORE_APP_IDENTITY:-}"
INSTALLER_IDENTITY="${MEETREC_APPSTORE_INSTALLER_IDENTITY:-}"
PROVISIONING_PROFILE="${MEETREC_PROVISIONING_PROFILE:-}"
BUNDLE_VERSION="${MEETREC_BUNDLE_VERSION:-2}"

if [[ -z "$PROVISIONING_PROFILE" ]]; then
  PROVISIONING_PROFILE="$(find "$ROOT/app-store/profiles" -name '*.provisionprofile' 2>/dev/null | head -1 || true)"
fi

if [[ -z "$PROVISIONING_PROFILE" || ! -f "$PROVISIONING_PROFILE" ]]; then
  cat >&2 <<'EOF'
Missing Mac App Store provisioning profile.

Create a "Mac App Store Connect" distribution profile for jp.temosy.meetrec at
https://developer.apple.com/account/resources/profiles/list
then save the downloaded file as:

  app-store/profiles/MeetRec.provisionprofile

Or set MEETREC_PROVISIONING_PROFILE to its path.

Without an embedded profile, App Store Connect reports ITMS-90889 and the
uploaded build cannot be used with TestFlight.
EOF
  exit 1
fi

if [[ -z "$APP_IDENTITY" ]]; then
  APP_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(3rd Party Mac Developer Application:[^"]*\)".*/\1/p' \
    | head -1)"
fi

if [[ -z "$INSTALLER_IDENTITY" ]]; then
  INSTALLER_IDENTITY="$(security find-identity -v 2>/dev/null \
    | sed -n 's/.*"\(3rd Party Mac Developer Installer:[^"]*\)".*/\1/p' \
    | head -1)"
fi

if [[ -z "$APP_IDENTITY" || -z "$INSTALLER_IDENTITY" ]]; then
  echo "Missing Mac App Store signing identities." >&2
  echo >&2
  [[ -z "$APP_IDENTITY" ]] && echo "- 3rd Party Mac Developer Application" >&2
  [[ -z "$INSTALLER_IDENTITY" ]] && echo "- 3rd Party Mac Developer Installer" >&2
  cat >&2 <<'EOF'

Install the "3rd Party Mac Developer Application" and
"3rd Party Mac Developer Installer" certificates, or set:

  MEETREC_APPSTORE_APP_IDENTITY
  MEETREC_APPSTORE_INSTALLER_IDENTITY
EOF
  exit 1
fi

MEETREC_BUNDLE_IDENTIFIER="jp.temosy.meetrec" \
MEETREC_MARKETING_VERSION="1.0" \
MEETREC_BUNDLE_VERSION="$BUNDLE_VERSION" \
MEETREC_ENTITLEMENTS="$ROOT/entitlements/app-store.entitlements" \
MEETREC_CODESIGN_IDENTITY="$APP_IDENTITY" \
MEETREC_PROVISIONING_PROFILE="$PROVISIONING_PROFILE" \
"$ROOT/scripts/build-app.sh" >/dev/null

COPYFILE_DISABLE=1 productbuild \
  --component "$APP" /Applications \
  --sign "$INSTALLER_IDENTITY" \
  "$PKG"

echo "$PKG"
