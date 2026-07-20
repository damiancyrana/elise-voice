#!/bin/zsh

set -euo pipefail

ROOT="${0:A:h:h}"
DATA_DIR="${1:-$ROOT/.build/wake-word-data}"
AUDIO_DEVICE="${ELISE_AUDIO_DEVICE:-:1}"
WORK=$(mktemp -d /tmp/elise-wake-calibration.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

typeset -a positive_phrases=("Ilis" "Iliz" "Elise" "Elajs" "Elice")
typeset -a negative_phrases=(
    "Lis"
    "Ile jest"
    "Ile jest godzin"
    "Eliza"
    "Elisa"
    "Ela jest"
    "Idź"
    "Halo"
    "Hej Siri"
    "Dziękuję"
    "Nagraj notatkę"
    "To jest zwykłe zdanie"
)
typeset -a confusable_phrases=("Lis" "Elisa" "Dziękuję")
typeset -a focused_positive_phrases=("Ilis" "Iliz" "Elajs")

function capture_sample() {
    local voice="$1"
    local phrase="$2"
    local rate="$3"
    local output="$4"
    local serial="$5"
    local raw="$WORK/raw-${serial}.wav"

    ffmpeg -hide_banner -loglevel error -y \
        -f avfoundation -i "$AUDIO_DEVICE" -t 2.2 \
        -ar 16000 -ac 1 -c:a pcm_s16le "$raw" &
    local recorder=$!
    sleep 0.45
    say -v "$voice" -r "$rate" "$phrase"
    wait "$recorder"

    # Remove the room silence around the utterance, then center it in the same
    # one-second window used by the on-device SoundAnalysis request.
    ffmpeg -hide_banner -loglevel error -y -i "$raw" \
        -af "silenceremove=start_periods=1:start_duration=0.03:start_threshold=-42dB:stop_periods=-1:stop_duration=0.05:stop_threshold=-42dB,adelay=140ms:all=1,apad=whole_dur=1.1,atrim=0:1.1" \
        -t 1.1 \
        -ar 16000 -ac 1 -c:a pcm_s16le "$output"
}

function capture_split() {
    local split="$1"
    local voice="$2"
    shift 2
    local -a rates=("$@")
    local phrase rate serial=0

    mkdir -p "$DATA_DIR/$split/elise" "$DATA_DIR/$split/background"
    for phrase in "${positive_phrases[@]}"; do
        for rate in "${rates[@]}"; do
            capture_sample "$voice" "$phrase" "$rate" \
                "$DATA_DIR/$split/elise/live-${voice// /_}-${serial}.wav" "$split-positive-${serial}"
            (( serial += 1 ))
        done
    done

    serial=0
    for phrase in "${negative_phrases[@]}"; do
        capture_sample "$voice" "$phrase" 175 \
            "$DATA_DIR/$split/background/live-${voice// /_}-${serial}.wav" "$split-negative-${serial}"
        (( serial += 1 ))
    done
}

function capture_confusable_negatives() {
    local voice="$1"
    local phrase rate serial=0
    mkdir -p "$DATA_DIR/Train/background"
    for phrase in "${confusable_phrases[@]}"; do
        for rate in 145 175 205; do
            capture_sample "$voice" "$phrase" "$rate" \
                "$DATA_DIR/Train/background/focused-${voice// /_}-${serial}.wav" \
                "focused-${voice// /_}-${serial}"
            (( serial += 1 ))
        done
    done
}

function capture_focused_positives() {
    local voice="$1"
    local phrase rate serial=0
    mkdir -p "$DATA_DIR/Train/elise"
    for phrase in "${focused_positive_phrases[@]}"; do
        for rate in 145 175 205; do
            capture_sample "$voice" "$phrase" "$rate" \
                "$DATA_DIR/Train/elise/focused-positive-${voice// /_}-${serial}.wav" \
                "focused-positive-${voice// /_}-${serial}"
            (( serial += 1 ))
        done
    done
}

function capture_boundary_pair() {
    local voice="$1"
    local rate serial=0
    mkdir -p "$DATA_DIR/Train/elise" "$DATA_DIR/Train/background"
    for rate in 145 175 205; do
        capture_sample "$voice" "Ilis" "$rate" \
            "$DATA_DIR/Train/elise/boundary-positive-${voice// /_}-${serial}.wav" \
            "boundary-positive-${voice// /_}-${serial}"
        capture_sample "$voice" "Elisa" "$rate" \
            "$DATA_DIR/Train/background/boundary-negative-${voice// /_}-${serial}.wav" \
            "boundary-negative-${voice// /_}-${serial}"
        (( serial += 1 ))
    done
}

if [[ "${ELISE_CALIBRATION_SCOPE:-all}" == "boundary" ]]; then
    capture_boundary_pair "Eddy (English (UK))"
    capture_boundary_pair "Flo (English (US))"
    capture_boundary_pair "Grandma (English (UK))"
    capture_boundary_pair "Grandpa (English (US))"
    echo "$DATA_DIR"
    exit 0
fi

if [[ "${ELISE_CALIBRATION_SCOPE:-all}" == "focused-positive" ]]; then
    capture_focused_positives Samantha
    capture_focused_positives Zosia
    capture_focused_positives Karen
    capture_focused_positives Fred
    echo "$DATA_DIR"
    exit 0
fi

if [[ "${ELISE_CALIBRATION_SCOPE:-all}" == "confusable" ]]; then
    capture_focused_positives Samantha
    capture_focused_positives Zosia
    capture_focused_positives Karen
    capture_focused_positives Fred
    capture_confusable_negatives Samantha
    capture_confusable_negatives Zosia
    capture_confusable_negatives Karen
    capture_confusable_negatives Fred
    echo "$DATA_DIR"
    exit 0
fi

capture_split Train Samantha 145 175 205
capture_split Train Zosia 155 190
capture_split Validation Daniel 155 190
capture_split Test Moira 155 190

echo "$DATA_DIR"
