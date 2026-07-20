#!/bin/zsh

set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT="${1:-$ROOT/.build/wake-word-data}"
WORK="$OUTPUT/.work"

rm -rf "$OUTPUT"
mkdir -p \
    "$OUTPUT/Train/elise" \
    "$OUTPUT/Train/background" \
    "$OUTPUT/Validation/elise" \
    "$OUTPUT/Validation/background" \
    "$OUTPUT/Test/elise" \
    "$OUTPUT/Test/background" \
    "$WORK"

typeset -a train_voices=(
    "Zosia"
    "Samantha"
    "Karen"
    "Eddy (English (UK))"
    "Flo (English (US))"
    "Fred"
    "Kathy"
    "Grandma (English (UK))"
    "Grandpa (English (US))"
    "Reed (English (UK))"
    "Sandy (English (US))"
    "Shelley (English (UK))"
)
typeset -a validation_voices=("Daniel")
typeset -a test_voices=("Moira")
typeset -a positive_phrases=(
    "Ilis"
    "Iliz"
    "Eelis"
    "Eeliz"
    "E lease"
    "E Liz"
    "Elajs"
    "Elice"
    "Elise"
    "Elyse"
)
typeset -a negative_phrases=(
    "Ile jest"
    "Ile jest godzin"
    "Eliza pisze wiadomość"
    "Elisa wraca jutro"
    "Lis"
    "Idź"
    "Halo"
    "Hej Siri"
    "Ela jest w domu"
    "Ela już idzie"
    "Proszę zapisać ten tekst"
    "Dziękuję"
    "To jest zwykłe zdanie"
    "Nagraj krótką notatkę"
)
typeset -a rates=(145 175 205)
typeset -a delays=(0.02 0.08 0.14)

function render_sample() {
    local voice="$1"
    local phrase="$2"
    local rate="$3"
    local delay="$4"
    local output="$5"
    local gain="$6"
    local base="$WORK/${output:t:r}.aiff"

    say -v "$voice" -r "$rate" -o "$base" "$phrase"
    ffmpeg -hide_banner -loglevel error -y \
        -i "$base" \
        -af "adelay=${delay}s:all=1,volume=${gain},highpass=f=70,lowpass=f=7600,apad,atrim=0:1.0" \
        -ar 16000 -ac 1 -c:a pcm_s16le "$output"
    rm -f "$base"
}

function render_split() {
    local split="$1"
    shift
    local -a voices=("$@")
    local voice phrase rate delay gain serial=0

    for voice in "${voices[@]}"; do
        for phrase in "${positive_phrases[@]}"; do
            for rate in "${rates[@]}"; do
                delay="${delays[$((serial % ${#delays[@]} + 1))]}"
                gain=$(awk "BEGIN { printf \"%.2f\", 0.72 + (($serial % 5) * 0.09) }")
                render_sample "$voice" "$phrase" "$rate" "$delay" \
                    "$OUTPUT/$split/elise/elise-${serial}.wav" "$gain"
                (( serial += 1 ))
            done
        done
    done

    serial=0
    for voice in "${voices[@]}"; do
        for phrase in "${negative_phrases[@]}"; do
            for rate in "${rates[@]}"; do
                delay="${delays[$((serial % ${#delays[@]} + 1))]}"
                gain=$(awk "BEGIN { printf \"%.2f\", 0.70 + (($serial % 5) * 0.08) }")
                render_sample "$voice" "$phrase" "$rate" "$delay" \
                    "$OUTPUT/$split/background/speech-${serial}.wav" "$gain"
                (( serial += 1 ))
            done
        done
    done

    # The negative class must also teach the model that silence, room noise,
    # keyboard-like clicks and steady tones are not the wake phrase.
    local noise_count=12
    [[ "$split" == "Train" ]] || noise_count=4
    for (( index = 0; index < noise_count; index += 1 )); do
        local amplitude
        amplitude=$(awk "BEGIN { printf \"%.4f\", 0.002 + (($index % 6) * 0.0015) }")
        ffmpeg -hide_banner -loglevel error -y \
            -f lavfi -i "anoisesrc=color=pink:amplitude=${amplitude}:duration=1.0:sample_rate=16000" \
            -ac 1 -c:a pcm_s16le "$OUTPUT/$split/background/noise-${index}.wav"
    done
}

render_split Train "${train_voices[@]}"
render_split Validation "${validation_voices[@]}"
render_split Test "${test_voices[@]}"

rm -rf "$WORK"
echo "$OUTPUT"
