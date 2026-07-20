#!/bin/zsh

set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

"$ROOT/scripts/check.sh"
"$ROOT/scripts/check-wake-word.sh"
"$ROOT/scripts/check-personal-wake-verifier.sh"
"$ROOT/scripts/check-wake-verifier.sh"
"$ROOT/scripts/check-long-dictation.sh"
"$ROOT/scripts/build-app.sh"

APP="$ROOT/dist/EliseVoice.app"
codesign --verify --strict --verbose=2 "$APP"
[[ "$(lipo -archs "$APP/Contents/MacOS/EliseVoice")" == "arm64" ]]
[[ "$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)" == "1.5.0" ]]
[[ "$(defaults read "$APP/Contents/Info" CFBundleVersion)" == "12" ]]
[[ -f "$APP/Contents/Resources/EliseWakeWord.mlmodel" ]]
[[ -f "$APP/Contents/Resources/ElisePersonalWakeVerifier.mlmodel" ]]

echo "Pakiet produkcyjny Elise Voice przeszedł wszystkie kontrole."
