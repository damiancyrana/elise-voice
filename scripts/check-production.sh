#!/bin/zsh

set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

"$ROOT/scripts/check.sh"
"$ROOT/scripts/check-long-dictation.sh"
"$ROOT/scripts/build-app.sh"

APP="$ROOT/dist/EliseVoice.app"
codesign --verify --strict --verbose=2 "$APP"
[[ "$(lipo -archs "$APP/Contents/MacOS/EliseVoice")" == "arm64" ]]
[[ "$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)" == "1.8.0" ]]
[[ "$(defaults read "$APP/Contents/Info" CFBundleVersion)" == "17" ]]
[[ ! -e "$APP/Contents/Resources/EliseWakeWord.mlmodel" ]]
[[ ! -e "$APP/Contents/Resources/ElisePersonalWakeVerifier.mlmodel" ]]
if strings "$APP/Contents/MacOS/EliseVoice" \
    | rg -q 'Dedicated ELISE keyword model loaded|Personal acoustic wake verifier loaded'; then
    echo "Binarka nadal zawiera kod aktywacji głosowej." >&2
    exit 1
fi

echo "Pakiet produkcyjny Elise Voice przeszedł wszystkie kontrole."
