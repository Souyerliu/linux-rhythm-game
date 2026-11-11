#!/usr/bin/env bash
# MIDI import, seeded chart generation and offline audio rendering.
set -euo pipefail
export LC_ALL=C
GAME_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fail() { printf 'MIDI import error: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'EOF'
Usage: bash tools/midi_import.sh MIDI [options]
  --analyze                     Print tracks and tempo map as JSON
  --output CHART.csv             Create a chart; never overwrite edits
  --track N --support-track N    Select tracks (zero based)
  --holds --grid 1|1/2|1/4      Include holds / choose rhythm grid
  --render-only                 Print cached rendered WAV path
  --soundfont FILE --loudness balanced|original
Random entry: ./random-play.sh MIDI [options]
  --seed 0..4294967295 --generate-only --output CHART.csv
  --track N --support-track N --holds --grid 1|1/2|1/4
  --fps 15..120 --offset MS --silent
EOF
}
MIDI_ACTION=chart MIDI_RANDOM=0 MIDI_TRACK='' MIDI_SUPPORT='' MIDI_HOLDS=0 MIDI_GRID=1 MIDI_SEED=''
source_path='' output='' soundfont='' loudness=${RHYTHM_MIDI_LOUDNESS:-balanced}
generate_only=0 fps=60 offset=0 silent=0
while (($#)); do
    case $1 in
        --help|-h) usage; exit 0 ;;
        --random) MIDI_RANDOM=1; shift ;;
        --analyze) MIDI_ACTION=analyze; shift ;;
        --render-only) MIDI_ACTION=render; shift ;;
        --holds) MIDI_HOLDS=1; shift ;;
        --generate-only) generate_only=1; shift ;;
        --silent) silent=1; shift ;;
        --track|--support-track|--grid|--seed|--output|--soundfont|--loudness|--fps|--offset)
            (($#>=2)) || fail "Missing value for $1"
            case $1 in
                --track) MIDI_TRACK=$2 ;; --support-track) MIDI_SUPPORT=$2 ;;
                --grid) MIDI_GRID=$2 ;; --seed) MIDI_SEED=$2 ;; --output) output=$2 ;;
                --soundfont) soundfont=$2 ;; --loudness) loudness=$2 ;;
                --fps) fps=$2 ;; --offset) offset=$2 ;;
            esac
            shift 2 ;;
        --) shift; (($#==1)) || fail 'Expected one MIDI file'; source_path=$1; shift ;;
        -*) fail "Unknown option: $1" ;;
        *) [[ -z $source_path ]] || fail 'Expected one MIDI file'; source_path=$1; shift ;;
    esac
done
[[ -n $source_path && -f $source_path ]] || fail 'Specify an existing MIDI file'
source_path=$(realpath -- "$source_path")
[[ $source_path != *$'\n'* && $source_path != *$'\r'* ]] || fail 'Newlines in MIDI paths are unsupported by chart CSV'
for value in "$MIDI_TRACK" "$MIDI_SUPPORT"; do
    [[ -z $value || ( $value =~ ^[0-9]+$ && ${#value} -le 9 ) ]] || fail 'Track index must be a nonnegative integer'
done
[[ -z $MIDI_TRACK ]] || MIDI_TRACK=$((10#$MIDI_TRACK))
[[ -z $MIDI_SUPPORT ]] || MIDI_SUPPORT=$((10#$MIDI_SUPPORT))
[[ $MIDI_GRID == 1 || $MIDI_GRID == 1/2 || $MIDI_GRID == 1/4 ]] || fail 'Grid must be 1, 1/2 or 1/4'
[[ $fps =~ ^[0-9]{1,3}$ ]] || fail 'FPS must be 15-120'
fps=$((10#$fps)); ((fps>=15 && fps<=120)) || fail 'FPS must be 15-120'
[[ $offset =~ ^-?[0-9]{1,7}$ ]] || fail 'Offset is out of range'
if [[ $offset == -* ]]; then offset=$((-10#${offset#-})); else offset=$((10#$offset)); fi
if [[ -n $MIDI_SEED ]]; then
    [[ $MIDI_SEED =~ ^[0-9]{1,10}$ ]] || fail 'Seed must be 0-4294967295'
    MIDI_SEED=$((10#$MIDI_SEED)); ((MIDI_SEED<=4294967295)) || fail 'Seed must be 0-4294967295'
else
    MIDI_SEED=$(od -An -N4 -tu4 /dev/urandom); MIDI_SEED=${MIDI_SEED//[[:space:]]/}
fi
work=$(mktemp -d)
publish_temp=''
cleanup() {
    [[ -z $publish_temp ]] || rm -f -- "$publish_temp"
    rm -rf -- "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

render_audio() {
    local executable font='' candidate key cache raw processed temp filter version before after
    [[ $loudness == balanced || $loudness == original ]] || fail 'MIDI loudness must be balanced or original'
    executable=$(command -v fluidsynth || true)
    if [[ -z $executable && -f $GAME_ROOT/.cache/midi-tools/usr/bin/fluidsynth ]]; then
        executable=$GAME_ROOT/.cache/midi-tools/usr/bin/fluidsynth
        local -a libraries=("$GAME_ROOT"/.cache/midi-tools/usr/lib/*-linux-gnu)
        local library_path
        printf -v library_path '%s:' "${libraries[@]}"
        export LD_LIBRARY_PATH=$library_path${LD_LIBRARY_PATH:-}
    fi
    [[ -n $executable ]] || fail 'MIDI needs FluidSynth: sudo apt install fluidsynth timgm6mb-soundfont'
    for candidate in "$soundfont" "${RHYTHM_SOUNDFONT:-}" \
        "$GAME_ROOT/.cache/midi-tools/usr/share/sounds/sf2/TimGM6mb.sf2" \
        /usr/share/sounds/sf2/TimGM6mb.sf2 /usr/share/sounds/sf2/default-GM.sf2 /usr/share/sounds/sf2/FluidR3_GM.sf2; do
        if [[ -n $candidate && -f $candidate ]]; then font=$(realpath -- "$candidate"); break; fi
    done
    [[ -n $font ]] || fail 'No SoundFont found; install timgm6mb-soundfont or set RHYTHM_SOUNDFONT'
    key=$({ cat -- "$source_path"; printf '%s\n' "$font"; stat -c '%y' -- "$font"; printf '44100-gain0.5-shell-v1'; } | sha256sum)
    key=${key%% *}; cache=$GAME_ROOT/.cache/midi
    mkdir -p -- "$cache"
    raw=$cache/$key.wav
    if [[ ! -f $raw ]] || (($(stat -c %s -- "$raw")<=44)); then
        temp=$work/render.wav
        printf 'Rendering MIDI: %s (first playback only)\n' "${source_path##*/}" >&2
        if ! OMP_NUM_THREADS=1 timeout --kill-after=2 120 "$executable" -ni -F "$temp" -T wav -r 44100 -g 0.5 "$font" "$source_path" >"$work/render.log" 2>&1; then
            tail -c 1000 -- "$work/render.log" >&2; fail 'FluidSynth failed'
        fi
        [[ -s $temp ]] && (($(stat -c %s -- "$temp")>44)) || fail 'FluidSynth produced no audio'
        mv -- "$temp" "$raw"
    fi
    if [[ $loudness == original ]]; then printf '%s\n' "$raw"; return; fi
    command -v ffmpeg >/dev/null || fail 'Volume enhancement needs ffmpeg (or RHYTHM_MIDI_LOUDNESS=original)'
    command -v ffprobe >/dev/null || fail 'Volume timing validation needs ffprobe'
    filter='dynaudnorm=f=250:g=15:p=0.9:m=16:r=0.14:b=1:t=0.001,alimiter=limit=0.95:attack=5:release=50:level=0:latency=1'
    version=$(printf '%s' "$filter" | sha256sum); version=${version:0:12}
    processed=${raw%.wav}-balanced-$version.wav
    if [[ ! -f $processed ]] || (($(stat -c %s -- "$processed")<=44)); then
        printf 'Balancing MIDI volume (quiet passages receive more gain)...\n' >&2
        temp=$work/balanced.wav
        timeout --kill-after=2 120 ffmpeg -nostdin -hide_banner -loglevel error -y -i "$raw" -af "$filter" -c:a pcm_s16le "$temp" || fail 'MIDI volume processing failed'
        before=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate,channels,duration_ts,time_base -of csv=p=0 "$raw")
        after=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate,channels,duration_ts,time_base -of csv=p=0 "$temp")
        [[ -n $before && $before == "$after" ]] || fail 'Volume processing changed audio timing; refusing misaligned output'
        mv -- "$temp" "$processed"
    fi
    printf '%s\n' "$processed"
}
if [[ $MIDI_ACTION == render ]]; then render_audio; exit; fi
MIDI_MODE=balanced-shell-v5
((!MIDI_HOLDS)) || MIDI_MODE=balanced-holds-shell-v5
[[ $MIDI_GRID == 1 ]] || MIDI_MODE+=-grid${MIDI_GRID/\//of}
if [[ $MIDI_ACTION == chart ]]; then
    if [[ -z $output ]]; then
        ((MIDI_RANDOM)) || fail 'Specify --output chart.csv or --analyze/--render-only'
        digest=$({ cat -- "$source_path"; printf '%s' "$source_path"; } | sha256sum)
        name=${source_path##*/}; name=${name%.*}
        name=$(printf '%s' "$name" | tr -c 'a-zA-Z0-9._-' '-')
        output=$GAME_ROOT/songs/generated/${name:0:48}-${digest:0:12}-$MIDI_MODE-t${MIDI_TRACK:-auto}-b${MIDI_SUPPORT:-auto}-seed$MIDI_SEED.csv
    fi
    output=$(realpath -m -- "$output")
    MIDI_AUDIO=$(realpath -m --relative-to="$(dirname -- "$output")" -- "$source_path")
    [[ $MIDI_AUDIO != *$'\n'* && $MIDI_AUDIO != *$'\r'* ]] || fail 'Newlines in chart paths are unsupported'
else
    MIDI_AUDIO=''
fi
export MIDI_ACTION MIDI_RANDOM MIDI_TRACK MIDI_SUPPORT MIDI_GRID MIDI_HOLDS MIDI_SEED MIDI_MODE MIDI_AUDIO
od -An -v -tu1 -- "$source_path" | awk -f "$GAME_ROOT/tools/midi_chart.awk" >"$work/chart"
if [[ $MIDI_ACTION == analyze ]]; then cat -- "$work/chart"; exit; fi
mkdir -p -- "$(dirname -- "$output")"
# Hard-link publication creates the destination atomically without overwriting it.
publish_temp=$(mktemp -- "${output}.tmp.XXXXXXXX")
cat -- "$work/chart" >"$publish_temp"
if ln -T -- "$publish_temp" "$output" 2>/dev/null; then
    rm -f -- "$publish_temp"
else
    rm -f -- "$publish_temp"
    if ((!MIDI_RANDOM)) || ! cmp -s -- "$work/chart" "$output"; then
        fail "Chart already exists or cannot be created: $output. Choose another --output or --seed"
    fi
fi
publish_temp=''
((!MIDI_RANDOM)) || printf 'Seed: %s | Grid: %s beat\n' "$MIDI_SEED" "$MIDI_GRID"
printf 'Chart: %s\n' "$output"
if ((MIDI_RANDOM && !generate_only)); then
    command=(bash "$GAME_ROOT/game.sh" "$output" --fps "$fps" --offset "$offset")
    ((!silent)) || command+=(--silent)
    "${command[@]}"
fi
