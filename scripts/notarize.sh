#!/bin/zsh

set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/dist/EliseVoice.app"
ARCHIVE="$ROOT/dist/EliseVoice-notarization.zip"

: "${ELISE_SIGN_IDENTITY:?Ustaw ELISE_SIGN_IDENTITY na certyfikat Developer ID Application}"
: "${ELISE_NOTARY_PROFILE:?Ustaw ELISE_NOTARY_PROFILE na profil zapisany przez notarytool}"

cd "$ROOT"
ELISE_PRODUCTION=1 "$ROOT/scripts/build-app.sh"
codesign --verify --strict --verbose=2 "$APP"
ditto -c -k --keepParent "$APP" "$ARCHIVE"
xcrun notarytool submit "$ARCHIVE" \
    --keychain-profile "$ELISE_NOTARY_PROFILE" \
    --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

echo "$APP"
