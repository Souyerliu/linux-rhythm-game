#!/usr/bin/env bash

chart_error() { printf '%s\n' "$*" >&2; return 1; }
source "$GAME_ROOT/lib/timing.sh"

# Parse data only: chart headers are never executed as shell code.
load_chart() {
    local file=$1 line t lane extra number=0 base beat bpm ending
    local -A events=()
    [[ -f $file ]] || { chart_error "Chart not found: $file"; return 1; }
    chart_path=$file
    chart_audio='' chart_offset=0 chart_bpm=120
    note_times=() note_lanes=() note_ends=() note_states=()
    tempo_beats=(0) tempo_bpms=(120)
    while IFS= read -r line || [[ -n $line ]]; do
        ((number+=1))
        line=${line%$'\r'}
        case $line in
            '# audio='*) chart_audio=${line#'# audio='}; continue ;;
            '# offset_ms='*) chart_offset=${line#'# offset_ms='}; continue ;;
            '# bpm='*) chart_bpm=${line#'# bpm='}; continue ;;
            '# tempo='*)
                extra=${line#'# tempo='}
                [[ $extra =~ ^([0-9]{1,7}),([0-9]{1,4})$ ]] || { chart_error "$file:$number: expected # tempo=beat,bpm"; return 1; }
                beat=$((10#${BASH_REMATCH[1]})) bpm=$((10#${BASH_REMATCH[2]}))
                ((beat >= 2 && bpm >= 20 && bpm <= 400)) || { chart_error "$file:$number: tempo beat must be >=2, BPM 20-400"; return 1; }
                [[ ! ${events[$beat]:-} ]] || { chart_error "$file:$number: duplicate tempo beat"; return 1; }
                events[$beat]=$bpm; continue ;;
            '#'*|'') continue ;;
        esac
        if [[ ! $line =~ ^([0-9]{1,9}),([0-3])(,([0-9]{1,9}))?$ ]]; then
            chart_error "$file:$number: expected start_ms,track[,end_ms]"; return 1
        fi
        t=$((10#${BASH_REMATCH[1]})) lane=${BASH_REMATCH[2]}
        ending=$t
        if [[ -n ${BASH_REMATCH[4]} ]]; then
            ending=$((10#${BASH_REMATCH[4]}))
            ((ending > t)) || { chart_error "$file:$number: hold end must be after start"; return 1; }
        fi
        note_times+=( "$t" ); note_lanes+=( "$lane" ); note_ends+=( "$ending" )
    done < "$file"
    [[ $chart_offset =~ ^-?[0-9]{1,7}$ && $chart_bpm =~ ^[0-9]{1,4}$ ]] || {
        chart_error 'Invalid offset_ms or bpm header'; return 1;
    }
    local raw_offset=$chart_offset
    if [[ $raw_offset == -* ]]; then chart_offset=$((-10#${raw_offset#-})); else chart_offset=$((10#$raw_offset)); fi
    chart_bpm=$((10#$chart_bpm))
    ((chart_bpm >= 20 && chart_bpm <= 400)) || { chart_error 'BPM must be 20-400'; return 1; }
    while IFS=, read -r beat bpm; do
        [[ -n $beat ]] || continue
        tempo_beats+=( "$((beat - 1))" ); tempo_bpms+=( "$bpm" )
    done < <(for beat in "${!events[@]}"; do printf '%s,%s\n' "$beat" "${events[$beat]}"; done | sort -t, -k1,1n)
    build_timing
    sort_notes || return 1
    base=$(cd -- "$(dirname -- "$file")" && pwd) || return 1
    audio_path=$chart_audio
    [[ -z $audio_path || $audio_path == /* ]] || audio_path=$base/$audio_path
}

sort_notes() {
    local i t lane ending maximum=0
    local -a times=() lanes=() endings=() lane_ends=(-1 -1 -1 -1)
    while IFS=, read -r t lane ending; do
        [[ -n $t ]] || continue
        if ((ending < t || ending > 999999999 || t <= lane_ends[lane])); then
            chart_error "Overlapping notes or invalid hold in lane $lane at $t ms"; return 1
        fi
        lane_ends[lane]=$ending
        times+=( "$t" ); lanes+=( "$lane" ); endings+=( "$ending" )
    done < <(
        for ((i=0; i<${#note_times[@]}; i++)); do
            printf '%s,%s,%s\n' "${note_times[i]}" "${note_lanes[i]}" "${note_ends[i]:-${note_times[i]}}"
        done | LC_ALL=C sort -t, -k1,1n -k2,2n -k3,3n -u
    )
    note_times=( "${times[@]}" ); note_lanes=( "${lanes[@]}" ); note_ends=( "${endings[@]}" )
    note_prefix_ends=() note_colors=() hold_lanes=(-1 -1 -1 -1) hold_errors=()
    total=${#note_times[@]}; note_states=()
    expire_cursor=0
    for ((i=0; i<total; i++)); do
        note_states+=(pending)
        ((note_ends[i] > maximum)) && maximum=${note_ends[i]}
        note_prefix_ends+=( "$maximum" )
        note_color "${note_times[i]}"; note_colors+=( "$color_code" )
    done
    end_ms=$((maximum + 1200))
    return 0
}

lower_bound_note() {
    local time=$1 low=0 high=$total mid
    while ((low < high)); do
        mid=$(((low + high) / 2))
        if ((note_times[mid] < time)); then low=$((mid + 1)); else high=$mid; fi
    done
    note_index=$low
}

lower_bound_visible() {
    local time=$1 low=0 high=$total mid
    if ((${#note_prefix_ends[@]} != total)); then lower_bound_note "$time"; return; fi
    while ((low < high)); do
        mid=$(((low + high) / 2))
        if ((note_prefix_ends[mid] < time)); then low=$((mid + 1)); else high=$mid; fi
    done
    note_index=$low
}

note_color() {
    local ms=$1 ticks subdivision nearest difference
    if ((${#tempo_beats[@]})); then ms_to_beat "$ms"; ticks=$beat_ticks
    else ticks=$((ms * 2000)); fi
    color_code=95
    for subdivision in 1000000 500000 250000; do
        nearest=$(((ticks + subdivision / 2) / subdivision * subdivision))
        if ((${#tempo_beats[@]})); then beat_to_ms "$nearest"; difference=$((mapped_ms - ms))
        else difference=$((nearest / 2000 - ms)); fi
        difference=${difference#-}
        if ((difference <= 1)); then
            case $subdivision in 1000000) color_code=97 ;; 500000) color_code=96 ;; 250000) color_code=93 ;; esac
            break
        fi
    done
}

save_chart() {
    local temp i
    temp=$(mktemp -- "${chart_path}.tmp.XXXXXX") || return 1
    if ! {
        printf '# Four Keys chart v1\n# audio=%s\n# offset_ms=%d\n# bpm=%d\n' "$chart_audio" "$chart_offset" "$chart_bpm"
        for ((i=1; i<${#tempo_beats[@]}; i++)); do printf '# tempo=%d,%d\n' "$((tempo_beats[i] + 1))" "${tempo_bpms[i]}"; done
        for ((i=0; i<total; i++)); do
            printf '%d,%d' "${note_times[i]}" "${note_lanes[i]}"
            if (( ${note_ends[i]:-${note_times[i]}} > note_times[i] )); then printf ',%d' "${note_ends[i]}"; fi
            printf '\n'
        done
    } > "$temp"; then rm -f -- "$temp"; return 1; fi
    if ! mv -- "$temp" "$chart_path"; then rm -f -- "$temp"; return 1; fi
}

start_audio() {
    command -v mpv >/dev/null || { chart_error 'Music requires mpv. Install it with your package manager (e.g. sudo apt install mpv).'; return 1; }
    command -v python3 >/dev/null || { chart_error 'Music requires python3.'; return 1; }
    [[ -f $audio_path ]] || { chart_error "Audio not found: $audio_path"; return 1; }
    case ${audio_path,,} in
        *.mid|*.midi)
            local rendered_audio
            rendered_audio=$(bash "$GAME_ROOT/tools/midi_import.sh" "$audio_path" --render-only) || return 1
            audio_path=$rendered_audio ;;
    esac
    coproc MUSIC { python3 "$GAME_ROOT/tools/mpv_bridge.py" "$audio_path"; }
    audio_pid=$MUSIC_PID audio_in=${MUSIC[1]} audio_out=${MUSIC[0]}
    audio_eof=0
    local response
    if ! IFS= read -r -t 12 response <&"$audio_out" || [[ $response != READY ]]; then
        chart_error "Cannot start audio: ${response:-timeout}"; stop_audio; return 1
    fi
}

audio_command() {
    local response
    printf '%s\n' "$*" >&"$audio_in" || return 1
    IFS= read -r -t 3 response <&"$audio_out" || return 1
    parse_audio_response "$response"
}

parse_audio_response() {
    [[ $1 =~ ^OK\ ([0-9]+)\ ([01])\ ([0-9]+)$ ]] || { chart_error "Audio error: $1"; return 1; }
    audio_ms=${BASH_REMATCH[1]} audio_eof=${BASH_REMATCH[2]} audio_sample_ms=${BASH_REMATCH[3]}
}

stop_audio() {
    if [[ -n ${audio_pid:-} ]]; then
        kill "$audio_pid" 2>/dev/null || :
        wait "$audio_pid" 2>/dev/null || :
        exec {audio_in}>&-
        exec {audio_out}<&-
        audio_pid=''
    fi
}
