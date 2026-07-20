#!/bin/zsh

set -euo pipefail

ROOT="${0:A:h:h}"
APP_NAME="EliseVoice"
APP_BUNDLE="$ROOT/dist/$APP_NAME.app"
SIGN_IDENTITY="${ELISE_SIGN_IDENTITY:--}"
PRODUCTION="${ELISE_PRODUCTION:-0}"

if [[ "$PRODUCTION" == "1" ]]; then
    [[ "$SIGN_IDENTITY" == Developer\ ID\ Application:* ]] || {
        echo "Build produkcyjny wymaga ELISE_SIGN_IDENTITY='Developer ID Application: …'." >&2
        exit 1
    }
    security find-identity -v -p codesigning | rg -Fq "\"$SIGN_IDENTITY\"" || {
        echo "Nie znaleziono wskazanego certyfikatu Developer ID w pęku kluczy." >&2
        exit 1
    }
fi

cd "$ROOT"
swift build -c release
"$ROOT/scripts/generate-icon.sh" >/dev/null

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$ROOT/.build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$ROOT/.build/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/Images/AppIcon-1024.png" "$APP_BUNDLE/Contents/Resources/AppIcon-1024.png"
cp "$ROOT/Resources/Images/ElisePortraitTransparent-v5.png" "$APP_BUNDLE/Contents/Resources/ElisePortraitTransparent-v5.png"
[[ -f "$ROOT/Resources/Models/EliseWakeWord.mlmodel" ]] || {
    echo "Brakuje modelu ELISE. Uruchom scripts/train-wake-word.sh." >&2
    exit 1
}
cp "$ROOT/Resources/Models/EliseWakeWord.mlmodel" "$APP_BUNDLE/Contents/Resources/EliseWakeWord.mlmodel"
if [[ -f "$ROOT/Resources/Models/ElisePersonalWakeVerifier.mlmodel" ]]; then
    cp "$ROOT/Resources/Models/ElisePersonalWakeVerifier.mlmodel" \
        "$APP_BUNDLE/Contents/Resources/ElisePersonalWakeVerifier.mlmodel"
fi
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP_BUNDLE/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$ROOT/.build/checkouts/argmax-oss-swift/LICENSE" "$APP_BUNDLE/Contents/Resources/ARGMAX_LICENSE"
cp "$ROOT/.build/checkouts/argmax-oss-swift/NOTICES" "$APP_BUNDLE/Contents/Resources/ARGMAX_NOTICES"

plutil -lint "$APP_BUNDLE/Contents/Info.plist"
typeset -a sign_arguments=(
    --force
    --options runtime
    --entitlements "$ROOT/Resources/EliseVoice.entitlements"
    --sign "$SIGN_IDENTITY"
)
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    sign_arguments+=(--timestamp)
else
    # A stable local requirement keeps TCC identity consistent for private
    # development builds. Developer ID builds use Apple's stronger generated
    # requirement, which binds the bundle to the signing team.
    sign_arguments+=(--requirements '=designated => identifier "com.elisevoice.app"')
fi
codesign "${sign_arguments[@]}" "$APP_BUNDLE"
codesign --verify --strict "$APP_BUNDLE"
codesign -dr - "$APP_BUNDLE" 2>&1 \
    | rg -Fq 'designated => identifier "com.elisevoice.app"'
if [[ "$PRODUCTION" == "1" ]]; then
    codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1 | rg -q 'TeamIdentifier=.+$'
fi

echo "$APP_BUNDLE"
