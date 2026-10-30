#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
INSTALL_DIR="${1:-/Applications}"
DEST="$INSTALL_DIR/TX6Mac.app"
HOST_DIR="${HOME}/Library/Application Support/Google/Chrome/NativeMessagingHosts"
HOST_FILE="$HOST_DIR/local.tx6mac.browser.json"
fail() { print -u2 -- "$*"; exit 1; }
[[ ! -L "$HOST_FILE" ]] || fail 'Refusing to replace a symlinked Chrome host manifest.'
if [[ -e "$HOST_FILE" ]]; then
  [[ -f "$HOST_FILE" && "$(stat -f %u "$HOST_FILE")" == "$(id -u)" ]] || fail 'Chrome host manifest is not a file owned by this user.'
  [[ "$(plutil -extract name raw -o - "$HOST_FILE" 2>/dev/null || true)" == local.tx6mac.browser ]] || fail 'Existing Chrome host manifest is not TX6Mac.'
fi
./build.sh "$DEST"
DEST="${DEST:a}"
mkdir -p "$HOST_DIR"
HOST_TEMP="$(mktemp "$HOST_DIR/.tx6mac-host.XXXXXX")"
trap 'rm -f "$HOST_TEMP"' EXIT
plutil -create xml1 "$HOST_TEMP"
plutil -insert name -string local.tx6mac.browser "$HOST_TEMP"
plutil -insert description -string 'TX6Mac local Chrome tab volume and EQ bridge' "$HOST_TEMP"
plutil -insert path -string "$DEST/Contents/MacOS/TX6BrowserHost" "$HOST_TEMP"
plutil -insert type -string stdio "$HOST_TEMP"
plutil -insert allowed_origins -json '["chrome-extension://pphajfbmohpnobkajebnaaoildfenkcf/"]' "$HOST_TEMP"
plutil -convert json "$HOST_TEMP"
chmod 600 "$HOST_TEMP"
mv -f "$HOST_TEMP" "$HOST_FILE"
printf '\nInstalled: %s\nChrome extension folder: %s/Contents/Resources/BrowserExtension\n' "$DEST" "$DEST"
