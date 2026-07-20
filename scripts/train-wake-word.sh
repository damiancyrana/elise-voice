#!/bin/zsh

set -euo pipefail

ROOT="${0:A:h:h}"
DATA_DIR="$ROOT/.build/wake-word-data"
MODEL="$ROOT/Resources/Models/EliseWakeWord.mlmodel"
PERSONAL_MODEL="$ROOT/Resources/Models/ElisePersonalWakeVerifier.mlmodel"

"$ROOT/scripts/generate-wake-word-data.sh" "$DATA_DIR"
PERSONAL_DIR="$ROOT/.build/wake-word-personal"
if [[ -d "$PERSONAL_DIR" ]]; then
    for split in Train Validation Test; do
        for label in elise background; do
            source="$PERSONAL_DIR/$split/$label"
            [[ -d "$source" ]] || continue
            files=("$source"/*.wav(N))
            (( ${#files[@]} > 0 )) || continue
            cp "${files[@]}" "$DATA_DIR/$split/$label/"
        done
    done
fi
if [[ "${ELISE_CAPTURE_PERSONALIZED:-0}" == "1" ]]; then
    "$ROOT/scripts/capture-wake-word-calibration.sh" "$DATA_DIR"
    ELISE_CALIBRATION_SCOPE=confusable \
        "$ROOT/scripts/capture-wake-word-calibration.sh" "$DATA_DIR"
    ELISE_CALIBRATION_SCOPE=boundary \
        "$ROOT/scripts/capture-wake-word-calibration.sh" "$DATA_DIR"
fi
xcrun swift "$ROOT/scripts/train-wake-word.swift" "$DATA_DIR" "$MODEL"

if [[ -d "$PERSONAL_DIR/Train/elise" ]]; then
    PERSONAL_DATA="$ROOT/.build/wake-word-personal-verifier-data"
    rm -rf "$PERSONAL_DATA"
    for split in Train Validation Test; do
        mkdir -p "$PERSONAL_DATA/$split/elise" "$PERSONAL_DATA/$split/background"
        cp "$PERSONAL_DIR/$split/elise"/*.wav "$PERSONAL_DATA/$split/elise/"
        cp "$PERSONAL_DIR/$split/background"/*.wav "$PERSONAL_DATA/$split/background/"
        noise_files=("$DATA_DIR/$split/background"/noise-*.wav(N))
        (( ${#noise_files[@]} == 0 )) || \
            cp "${noise_files[@]}" "$PERSONAL_DATA/$split/background/"
    done
    xcrun swift "$ROOT/scripts/train-wake-word.swift" \
        "$PERSONAL_DATA" "$PERSONAL_MODEL"
fi

echo "$MODEL"
[[ ! -f "$PERSONAL_MODEL" ]] || echo "$PERSONAL_MODEL"
