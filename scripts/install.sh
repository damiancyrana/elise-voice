#!/bin/zsh

set -euo pipefail

ROOT="${0:A:h:h}"
SOURCE="$ROOT/dist/EliseVoice.app"
DESTINATION="/Applications/EliseVoice.app"
STAGING="/Applications/.EliseVoice.installing.$$.app"
BACKUP="/Applications/.EliseVoice.previous.$$.app"
DOCK_URL="file:///Applications/EliseVoice.app/"

function cleanup {
    if [[ -e "$BACKUP" && ! -e "$DESTINATION" ]]; then
        mv "$BACKUP" "$DESTINATION"
    fi
    rm -rf "$STAGING" "$BACKUP"
}
trap cleanup EXIT

cd "$ROOT"
"$ROOT/scripts/build-app.sh"

pkill -x EliseVoice 2>/dev/null || true
for _ in {1..40}; do
    pgrep -x EliseVoice >/dev/null || break
    sleep 0.1
done
if pgrep -x EliseVoice >/dev/null; then
    echo "Elise Voice nie zakończyła procesu w wymaganym czasie." >&2
    exit 1
fi

ditto --rsrc --extattr --acl "$SOURCE" "$STAGING"
codesign --verify --deep --strict "$STAGING"
spctl --assess --type execute "$STAGING" 2>/dev/null || [[ "${ELISE_SIGN_IDENTITY:--}" == "-" ]]

if [[ -e "$DESTINATION" ]]; then
    mv "$DESTINATION" "$BACKUP"
fi
if ! mv "$STAGING" "$DESTINATION"; then
    [[ -e "$BACKUP" ]] && mv "$BACKUP" "$DESTINATION"
    exit 1
fi
rm -rf "$BACKUP"

if ! defaults read com.apple.dock persistent-apps 2>/dev/null | rg -Fq "$DOCK_URL"; then
    defaults write com.apple.dock persistent-apps -array-add \
        "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>$DOCK_URL</string><key>_CFURLStringType</key><integer>15</integer></dict><key>file-label</key><string>Elise Voice</string></dict><key>tile-type</key><string>file-tile</string></dict>"
    killall Dock 2>/dev/null || true
fi

launched=false
for _ in {1..5}; do
    if open "$DESTINATION"; then
        launched=true
        break
    fi
    sleep 0.4
done
if [[ "$launched" != true ]]; then
    echo "Aplikacja została zainstalowana, ale Launch Services nie uruchomił jej." >&2
    exit 1
fi

echo "$DESTINATION"
