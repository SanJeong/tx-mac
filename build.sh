#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
DEST="${1:-${HOME}/Library/Developer/TX6Mac/Build/TX6Mac.app}"
if [[ -z "${SIGN_IDENTITY+x}" ]]; then
  VALID_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  SIGN_IDENTITY="$(print -r -- "$VALID_IDENTITIES" | awk '
    length($2) == 40 && $2 ~ /^[[:xdigit:]]+$/ {
      if ($0 ~ /"Developer ID Application:/ && !developer_id) developer_id = $2
      if ($0 ~ /"Apple Development:/ && !development) development = $2
    }
    END { if (developer_id) print developer_id; else if (development) print development; else print "-" }
  ')"
fi
APP_VERSION="${APP_VERSION:-1.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-6}"
fail() { print -u2 -- "$*"; exit 1; }
[[ "$DEST" == *.app ]] || fail 'Build destination must end in .app.'
[[ ! -L "$DEST" ]] || fail 'Refusing to replace a symlink.'
[[ "$APP_VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || fail 'APP_VERSION must be major.minor.patch.'
[[ "$BUILD_NUMBER" =~ '^[1-9][0-9]*$' ]] || fail 'BUILD_NUMBER must be a positive integer.'
mkdir -p "${DEST:h}"
DEST="${DEST:a}"
check_destination() {
  if [[ -e "$DEST" ]]; then
    [[ -d "$DEST" && ! -L "$DEST" ]] || fail 'Refusing to replace a non-app destination.'
    [[ "$(stat -f %u "$DEST")" == "$(id -u)" ]] || fail 'Existing app belongs to another user.'
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null || true)" == local.tx6mac.mixer ]] || fail 'Existing destination is not TX6Mac.'
    [[ -z "$(lsof -a -d txt -t "$DEST/Contents/MacOS/TX6Mac" 2>/dev/null || true)" ]] || fail 'Quit the installed TX6Mac before updating it.'
  fi
}
check_destination
BUILD_WORK="$(mktemp -d "${DEST:h}/.tx6mac-build.XXXXXX")"
APP="$BUILD_WORK/TX6Mac.app"
BACKUP=""
cleanup() {
  if [[ -n "$BACKUP" && -d "$BACKUP" && ! -e "$DEST" ]]; then mv "$BACKUP" "$DEST"; fi
  rm -rf "$BUILD_WORK"
}
trap cleanup EXIT
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TX6Mac</string>
<key>CFBundleIdentifier</key><string>local.tx6mac.mixer</string>
<key>CFBundleName</key><string>TX6Mac</string>
<key>CFBundleDisplayName</key><string>TX6Mac</string>
<key>NSHumanReadableCopyright</key><string>Copyright 2026 San Jeong. PolyForm Noncommercial License 1.0.0.</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>ko</string><string>ja</string></array>
<key>CFBundleShortVersionString</key><string>1.1.0</string>
<key>CFBundleVersion</key><string>6</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSMultipleInstancesProhibited</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAudioCaptureUsageDescription</key><string>TX6Mac processes system audio locally so TX-6 controls can adjust each app’s volume and EQ. Audio is not saved or uploaded.</string>
<key>NSMicrophoneUsageDescription</key><string>The optional USB level diagnostic reads only the TX-6 USB main-mix return to measure signal levels. It does not play, save, or upload audio. Normal mixer use does not request microphone access.</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>TX6Mac connects to TX-6 over Bluetooth MIDI to receive fader, knob, and button controls.</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
xcrun clang -fobjc-arc -fmodules -std=gnu11 -O2 -Wall -Wextra -Wno-unused-parameter -mmacosx-version-min=26.0 \
  Sources/Audio.m Sources/MIDI.m Sources/BrowserBridge.m Sources/Localization.m Sources/Scenes.m Sources/USBLevelDiagnostic.m Sources/App.m \
  -framework Cocoa -framework CoreAudio -framework CoreMIDI -framework CoreAudioKit -framework CoreBluetooth -framework AVFoundation -framework AudioUnit \
  -o "$APP/Contents/MacOS/TX6Mac"
xcrun clang -fobjc-arc -fmodules -std=gnu11 -O2 -Wall -Wextra -mmacosx-version-min=26.0 Sources/BrowserHost.m -framework Foundation -o "$APP/Contents/MacOS/TX6BrowserHost"
ditto --norsrc --noextattr LICENSE "$APP/Contents/Resources/LICENSE"
if [[ -d BrowserExtension ]]; then
  ditto --norsrc --noextattr BrowserExtension "$APP/Contents/Resources/BrowserExtension"
fi
for language in en ko ja; do
  for table in Localizable InfoPlist; do
    [[ -f "Resources/$language.lproj/$table.strings" ]] || fail "Missing $language $table localization."
    plutil -lint "Resources/$language.lproj/$table.strings"
  done
  ditto --norsrc --noextattr "Resources/$language.lproj" "$APP/Contents/Resources/$language.lproj"
done
ICONSET="$BUILD_WORK/AppIcon.iconset"
swift Sources/Icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
xattr -cr "$APP"
APP_SIGN_OPTIONS=()
HOST_SIGN_OPTIONS=()
if [[ "$SIGN_IDENTITY" != - ]]; then
  APP_SIGN_OPTIONS=(--options runtime --timestamp --entitlements Resources/TX6Mac.entitlements)
  HOST_SIGN_OPTIONS=(--options runtime --timestamp)
fi
codesign --force --sign "$SIGN_IDENTITY" "${HOST_SIGN_OPTIONS[@]}" --identifier local.tx6mac.browser.host "$APP/Contents/MacOS/TX6BrowserHost"
codesign --force --sign "$SIGN_IDENTITY" "${APP_SIGN_OPTIONS[@]}" --identifier local.tx6mac.mixer "$APP"
codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/TX6Mac" --self-check
check_destination
if [[ -e "$DEST" ]]; then BACKUP="$BUILD_WORK/Previous.app"; mv "$DEST" "$BACKUP"; fi
mv "$APP" "$DEST"
xattr -dr com.apple.FinderInfo "$DEST" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$DEST" 2>/dev/null || true
if ! codesign --verify --deep --strict "$DEST"; then
  mv "$DEST" "$BUILD_WORK/Failed.app"
  if [[ -n "$BACKUP" ]]; then mv "$BACKUP" "$DEST"; BACKUP=""; fi
  fail 'Final installed signature verification failed; previous app was restored.'
fi
print -- "Built: $DEST"
print -- "Signing identity: $SIGN_IDENTITY (notarization is not performed)"
