#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
APP="${1:-${PWD}/TX6Mac.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TX6Mac</string>
<key>CFBundleIdentifier</key><string>local.tx6mac.mixer</string>
<key>CFBundleName</key><string>TX6Mac</string>
<key>CFBundleDisplayName</key><string>TX6Mac</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAudioCaptureUsageDescription</key><string>TX-6 페이더와 노브로 프로그램별 음량 및 EQ를 조절하려면 시스템 오디오에 접근해야 합니다. 오디오는 맥에서 실시간 처리하며 녹음하거나 외부로 전송하지 않습니다.</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>TX-6를 Bluetooth MIDI 컨트롤러로 연결합니다.</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
xcrun clang -fobjc-arc -fmodules -std=gnu11 -O2 -Wall -Wextra -Wno-unused-parameter -mmacosx-version-min=26.0 \
  Sources/Audio.m Sources/MIDI.m Sources/BrowserBridge.m Sources/App.m \
  -framework Cocoa -framework CoreAudio -framework CoreMIDI -framework CoreAudioKit \
  -o "$APP/Contents/MacOS/TX6Mac"
xcrun clang -fobjc-arc -fmodules -std=gnu11 -O2 -Wall -Wextra -mmacosx-version-min=26.0 Sources/BrowserHost.m -framework Foundation -o "$APP/Contents/MacOS/TX6BrowserHost"
if [[ -d BrowserExtension ]]; then
  ditto --norsrc --noextattr BrowserExtension "$APP/Contents/Resources/BrowserExtension"
fi
BUILD_WORK="$(mktemp -d "${TMPDIR:-/tmp}/tx6mac-build.XXXXXX")"
trap 'rm -rf "$BUILD_WORK"' EXIT
ICONSET="$BUILD_WORK/AppIcon.iconset"
swift Sources/Icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
xattr -cr "$APP"
codesign --force --sign - --identifier local.tx6mac.browser.host "$APP/Contents/MacOS/TX6BrowserHost"
codesign --force --sign - --identifier local.tx6mac.mixer "$APP"
"$APP/Contents/MacOS/TX6Mac" --self-check
printf 'Built: %s\n' "$APP"
