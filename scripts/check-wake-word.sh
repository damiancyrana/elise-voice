#!/bin/zsh

set -euo pipefail

ROOT="${0:A:h:h}"
MODEL="$ROOT/Resources/Models/EliseWakeWord.mlmodel"
DATA="$ROOT/.build/wake-word-data"

[[ -f "$MODEL" ]] || "$ROOT/scripts/train-wake-word.sh"
[[ -d "$DATA/Test" ]] || "$ROOT/scripts/generate-wake-word-data.sh" "$DATA"
xcrun swift "$ROOT/scripts/check-wake-word.swift" "$MODEL" "$DATA/Test"
