#!/bin/zsh

set -euo pipefail

ROOT="${0:A:h:h}"
FINAL_OUTPUT="$ROOT/.build/wake-word-personal"
OUTPUT="$ROOT/.build/wake-word-personal.staging.$$"
BACKUP="$ROOT/.build/wake-word-personal.previous.$$"
AUDIO_DEVICE="${ELISE_AUDIO_DEVICE:-:1}"
INTERACTIVE="${ELISE_INTERACTIVE:-0}"
WORK=$(mktemp -d /tmp/elise-personal-wake.XXXXXX)

function cleanup {
    rm -rf "$WORK" "$OUTPUT"
    if [[ -e "$BACKUP" && ! -e "$FINAL_OUTPUT" ]]; then
        mv "$BACKUP" "$FINAL_OUTPUT"
    fi
}
trap cleanup EXIT

command -v ffmpeg >/dev/null || {
    echo "Brakuje ffmpeg wymaganego do kalibracji." >&2
    exit 1
}
rm -rf "$OUTPUT" "$BACKUP"

typeset -a positive=("ILIS" "ILIZ" "ELAJS")
typeset -a negative=(
    "Lis" "Ile jest" "Elisa" "Eliza" "Ela jest" "Alice"
    "Dziękuję" "Hej Siri" "Nagraj notatkę" "To jest zwykłe zdanie"
)

function record_sample {
    local label="$1" phrase="$2" index="$3" split="$4"
    local raw="$WORK/raw.wav"
    local destination="$OUTPUT/$split/$label/personal-${label}-${index}.wav"
    mkdir -p "${destination:h}"

    print -r -- ""
    print -r -- "[$((index + 1))] Powiedz: $phrase"
    if [[ "$INTERACTIVE" == "1" ]]; then
        read -r "?Naciśnij Enter, gdy jesteś gotowy… "
        for count in 3 2 1; do
            print -n -r -- "$count… "
            sleep 0.45
        done
        ffmpeg -hide_banner -loglevel error -y \
            -f avfoundation -i "$AUDIO_DEVICE" -t 3.0 \
            -ar 16000 -ac 1 -c:a pcm_s16le "$raw" &
        local capture_pid=$!
        sleep 0.4
        print -r -- "MÓW"
        wait "$capture_pid"
    else
        print -r -- "Nagrywanie rozpocznie się za sekundę…"
        sleep 1
        ffmpeg -hide_banner -loglevel error -y \
            -f avfoundation -i "$AUDIO_DEVICE" -t 2.4 \
            -ar 16000 -ac 1 -c:a pcm_s16le "$raw"
    fi
    ffmpeg -hide_banner -loglevel error -y -i "$raw" \
        -af "silenceremove=start_periods=1:start_duration=0.03:start_threshold=-46dB:stop_periods=-1:stop_duration=0.06:stop_threshold=-46dB,adelay=120ms:all=1,apad=whole_dur=1.0,atrim=0:1.0" \
        -ar 16000 -ac 1 -c:a pcm_s16le "$destination"
}

serial=0
for repetition in {1..8}; do
    for phrase in "${positive[@]}"; do
        split=Train
        (( serial % 6 == 0 )) && split=Validation
        (( serial % 11 == 0 )) && split=Test
        record_sample elise "$phrase" "$serial" "$split"
        (( serial += 1 ))
    done
done

serial=0
for repetition in {1..3}; do
    for phrase in "${negative[@]}"; do
        split=Train
        (( serial % 6 == 0 )) && split=Validation
        (( serial % 11 == 0 )) && split=Test
        record_sample background "$phrase" "$serial" "$split"
        (( serial += 1 ))
    done
done

if [[ -e "$FINAL_OUTPUT" ]]; then
    mv "$FINAL_OUTPUT" "$BACKUP"
fi
if ! mv "$OUTPUT" "$FINAL_OUTPUT"; then
    [[ ! -e "$BACKUP" ]] || mv "$BACKUP" "$FINAL_OUTPUT"
    exit 1
fi
rm -rf "$BACKUP"
echo "$FINAL_OUTPUT"
