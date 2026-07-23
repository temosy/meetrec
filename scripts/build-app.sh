#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/MeetRec.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
BUNDLE_IDENTIFIER="${MEETREC_BUNDLE_IDENTIFIER:-local.haruo.meetrec}"
ENTITLEMENTS="${MEETREC_ENTITLEMENTS:-}"

sign_app() {
  local app="$1"
  local identity="${MEETREC_CODESIGN_IDENTITY:-}"

  if [[ -z "$identity" ]]; then
    identity="$(security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
      | head -1)"
  fi

  if [[ -n "$identity" ]]; then
    if [[ -n "$ENTITLEMENTS" ]]; then
      codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign "$identity" "$app" >/dev/null
    else
      codesign --force --deep --sign "$identity" "$app" >/dev/null
    fi
  else
    if [[ -n "$ENTITLEMENTS" ]]; then
      codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign - "$app" >/dev/null
    else
      codesign --force --deep --sign - "$app" >/dev/null
    fi
  fi
}

cd "$ROOT"
swift build -c release --product MeetRecGUI
scripts/make-icon.sh >/dev/null

mkdir -p "$MACOS" "$RESOURCES"
cp "$ROOT/.build/release/MeetRecGUI" "$MACOS/MeetRec"
cp "$ROOT/assets/MeetRec.icns" "$RESOURCES/MeetRec.icns"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>MeetRec</string>
  <key>CFBundleIdentifier</key>
  <string>__BUNDLE_IDENTIFIER__</string>
  <key>CFBundleName</key>
  <string>MeetRec</string>
  <key>CFBundleDisplayName</key>
  <string>MeetRec</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>MeetRec</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>2</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.productivity</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026 Haruo Shimote. Released under the MIT License.</string>
  <key>ITSAppUsesNonExemptEncryption</key>
  <false/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>自分の声も録音する設定をONにした場合のみ、マイク音声を録音します。 / MeetRec records microphone audio only when “Record my voice” is enabled.</string>
</dict>
</plist>
PLIST

plutil -replace CFBundleIdentifier -string "$BUNDLE_IDENTIFIER" "$CONTENTS/Info.plist"

sign_app "$APP"
touch "$APP"

echo "$APP"
