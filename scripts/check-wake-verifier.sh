#!/bin/zsh

set -euo pipefail

ROOT="${0:A:h:h}"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

function render {
    local voice="$1" phrase="$2" output="$3"
    local source="$TEMP_DIR/${output:t:r}.aiff"
    say -v "$voice" -r 155 -o "$source" "$phrase"
    ffmpeg -hide_banner -loglevel error -y -i "$source" \
        -af "adelay=500ms:all=1,apad=whole_dur=2.4,atrim=0:2.4" \
        -ar 16000 -ac 1 -c:a pcm_s16le "$output"
}

render Samantha "E lease" "$TEMP_DIR/positive-ilis.wav"
render Samantha "E lies" "$TEMP_DIR/positive-elajs.wav"
render Zosia "Lis" "$TEMP_DIR/negative-lis.wav"
render Zosia "Elisa" "$TEMP_DIR/negative-elisa.wav"

cd "$ROOT"
RESULT="$({ swift run -c release EliseVoiceASRCheck --verify-wake \
    "$TEMP_DIR/positive-ilis.wav" \
    "$TEMP_DIR/positive-elajs.wav" \
    "$TEMP_DIR/negative-lis.wav" \
    "$TEMP_DIR/negative-elisa.wav"; } 2>/dev/null)"

print -r -- "$RESULT"
print -r -- "$RESULT" | rg -q '^accepted[[:space:]]+positive-ilis\.wav$'
print -r -- "$RESULT" | rg -q '^accepted[[:space:]]+positive-elajs\.wav$'
print -r -- "$RESULT" | rg -q '^rejected[[:space:]]+negative-lis\.wav$'
print -r -- "$RESULT" | rg -q '^rejected[[:space:]]+negative-elisa\.wav$'

echo "Weryfikator drugiego etapu rozróżnia oba hasła od trudnych negatywów."
