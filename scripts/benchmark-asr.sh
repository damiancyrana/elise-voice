#!/bin/zsh

set -euo pipefail

ROOT="${0:A:h:h}"
AUDIO="${1:-/tmp/elise-long-polish.aiff}"

if [[ ! -f "$AUDIO" ]]; then
    say -v Zosia -r 150 -f "$ROOT/Tests/Fixtures/long-polish.txt" -o "$AUDIO"
fi

cd "$ROOT"
swift build -c release --product EliseVoiceASRCheck >/dev/null
zmodload zsh/datetime
for workers in 1 2 3 4; do
    started=$EPOCHREALTIME
    transcript=$(ELISE_ASR_WORKERS="$workers" \
        "$ROOT/.build/release/EliseVoiceASRCheck" "$AUDIO")
    finished=$EPOCHREALTIME
    elapsed=$(awk "BEGIN { printf \"%.3f\", $finished - $started }")
    print -r -- "workers=$workers seconds=$elapsed characters=${#transcript}"
done
