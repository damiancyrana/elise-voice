#!/bin/zsh

set -euo pipefail

ROOT="${0:A:h:h}"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
AUDIO="$TEMP_DIR/long-polish.aiff"

cd "$ROOT"
say -v Zosia -r 150 -f Tests/Fixtures/long-polish.txt -o "$AUDIO"

DURATION="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$AUDIO")"
if (( ${DURATION%.*} < 60 )); then
    echo "Nagranie testowe jest za krótkie: ${DURATION}s" >&2
    exit 1
fi

TRANSCRIPT="$(swift run -c release EliseVoiceASRCheck "$AUDIO")"

if ! print -r -- "$TRANSCRIPT" | rg -qi "dzisiaj testuję długie dyktowanie"; then
    echo "Brakuje początku nagrania w transkrypcji." >&2
    exit 1
fi
if ! print -r -- "$TRANSCRIPT" | rg -qi "koniec długiego testu"; then
    echo "Brakuje końca nagrania w transkrypcji." >&2
    exit 1
fi

echo "Transkrypcja nagrania ${DURATION}s zawiera początek i koniec wypowiedzi."
