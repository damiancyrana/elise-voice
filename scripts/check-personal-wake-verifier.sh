#!/bin/zsh

set -euo pipefail

ROOT="${0:A:h:h}"
MODEL="$ROOT/Resources/Models/ElisePersonalWakeVerifier.mlmodel"
DATA="$ROOT/.build/wake-word-personal"

[[ -f "$MODEL" ]]
[[ -d "$DATA/Test/elise" && -d "$DATA/Test/background" ]]

swift run --package-path "$ROOT" EliseVoiceASRCheck \
    --verify-personal-wake "$MODEL" "$DATA"
