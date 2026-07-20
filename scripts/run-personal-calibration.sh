#!/bin/zsh

set -u

ROOT="${0:A:h:h}"
STATUS="$ROOT/.build/personal-capture.status"

mkdir -p "$ROOT/.build"
print -r -- "running" > "$STATUS"

ELISE_INTERACTIVE=1 \
ELISE_AUDIO_DEVICE="${ELISE_AUDIO_DEVICE:-:1}" \
    "$ROOT/scripts/capture-personal-wake-word.sh"
result=$?
print -r -- "$result" > "$STATUS"

if (( result == 0 )); then
    print -r -- ""
    print -r -- "PRÓBKI ZAPISANE — możesz wrócić do Codex"
else
    print -r -- ""
    print -r -- "BŁĄD NAGRYWANIA — wróć do Codex"
fi

exit "$result"
