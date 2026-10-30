#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
./build.sh /Applications/TX6Mac.app
HOST_DIR="${HOME}/Library/Application Support/Google/Chrome/NativeMessagingHosts"
mkdir -p "$HOST_DIR"
cat > "$HOST_DIR/local.tx6mac.browser.json" <<'JSON'
{
  "name": "local.tx6mac.browser",
  "description": "TX6Mac local Chrome tab volume and EQ bridge",
  "path": "/Applications/TX6Mac.app/Contents/MacOS/TX6BrowserHost",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://pphajfbmohpnobkajebnaaoildfenkcf/"]
}
JSON
chmod 600 "$HOST_DIR/local.tx6mac.browser.json"
codesign --verify --deep --strict /Applications/TX6Mac.app
printf '\nInstalled: /Applications/TX6Mac.app\nChrome extension folder: %s/BrowserExtension\n' "$PWD"
