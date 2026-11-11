#!/usr/bin/env bash
# Four-lane terminal rhythm game. Requires Bash 5 or newer.
GAME_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$GAME_ROOT/lib/chart.sh"
source "$GAME_ROOT/lib/terminal.sh"
source "$GAME_ROOT/lib/game_clock.sh"
source "$GAME_ROOT/lib/scores.sh"

if (( BASH_VERSINFO[0] < 5 )); then
    printf 'Please run this game with Bash 5 or newer.\n' >&2
    exit 1
fi

clock_ms() {
    local stamp=$EPOCHREALTIME
    now_ms=$(( ${stamp%.*} * 1000 + 10#${stamp#*.} / 1000 ))
}

make_chart() {
    local i lane
    note_times=() note_lanes=() note_ends=() note_states=()
    chart_bpm=120 tempo_beats=(0) tempo_bpms=(120); build_timing
    for ((i=0; i<48; i++)); do
        lane=$(( (i / 8 + i) % 4 ))
        note_times+=( "$((2500 + i * 500))" )
        note_lanes+=( "$lane" )
        note_states+=( pending )
        if (( i % 8 == 7 )); then
            note_times+=( "$((2500 + i * 500))" )
            note_lanes+=( "$(((lane + 2) % 4))" )
            note_states+=( pending )
        fi
    done
    sort_notes
}

set_feedback() {
    feedback=$1
    feedback_until=$((elapsed + 600))
}

finish_note() {
    local i=$1 delta=$2 distance judgment direction message
    distance=${delta#-}
    if ((distance <= 45)); then
        note_states[i]=perfect; ((perfect+=1, score+=1000)); judgment=PERFECT
    elif ((distance <= 90)); then
        note_states[i]=great; ((great+=1, score+=700)); judgment=GREAT
    else
        note_states[i]=good; ((good+=1, score+=300)); judgment=GOOD
    fi
    hit_errors+=( "$delta" )
    direction=LATE; ((delta < 0)) && direction=EARLY
    ((delta == 0)) && direction=ON-TIME
    printf -v message '%s %+dms %s' "$judgment" "$delta" "$direction"
    set_feedback "$message"
    ((combo+=1))
    ((combo > max_combo)) && max_combo=$combo
    return 0
}

hit_lane() {
    local lane=$1 i delta distance head_distance
    i=${hold_lanes[lane]:--1}
    if ((i >= 0)) && [[ ${note_states[i]} == holding ]]; then
        delta=$((elapsed - note_ends[i])); distance=${delta#-}
        if ((distance <= 140)); then
            head_distance=${hold_errors[i]#-}
            ((head_distance > distance)) && delta=${hold_errors[i]}
            finish_note "$i" "$delta"
            hold_lanes[lane]=-1
        fi
        return 0
    fi
    lower_bound_note "$((elapsed - 140))"
    for ((i=note_index; i<total && note_times[i]<=elapsed+140; i++)); do
        [[ ${note_states[i]} == pending && ${note_lanes[i]} == "$lane" ]] || continue
        delta=$((elapsed - note_times[i]))
        if (( ${note_ends[i]:-${note_times[i]}} > note_times[i] )); then
            note_states[i]=holding; hold_lanes[lane]=$i; hold_errors[i]=$delta
            set_feedback 'HOLD: hit tail on time'
        else finish_note "$i" "$delta"; fi
        return 0
    done
    return 0
}

expire_notes() {
    local i lane
    for ((i=${expire_cursor:-0}; i<total && elapsed-note_times[i]>140; i++)); do
        if [[ ${note_states[i]} == pending ]] && ((elapsed - note_times[i] > 140)); then
            note_states[i]=miss
            ((miss+=1))
            combo=0
            set_feedback MISS
        fi
    done
    expire_cursor=$i
    for ((lane=0; lane<4; lane++)); do
        i=${hold_lanes[lane]:--1}
        if ((i >= 0 && elapsed - note_ends[i] > 140)) && [[ ${note_states[i]} == holding ]]; then
            note_states[i]=miss; hold_lanes[lane]=-1
            ((miss+=1)); combo=0; set_feedback 'MISS: hold tail'
        fi
    done
}

paint_game_cell() {
    local r=$1 lane=$2 glyph=$3 code=$4 priority=$5 key
    key=$((r * 4 + lane))
    if ((priority >= ${cell_priority[key]:-0})); then
        cells[key]=$'\e['"$code"'m'"$glyph"$'\e[0m'
        cell_priority[key]=$priority; occupied_rows[r]=1
    fi
}

# Game-time synchronization must never wait for mpv on the input path.
# Only one request is outstanding; editor commands retain their synchronous API.
poll_game_audio() {
    local response='' read_status
    if ((sync_pending)); then
        if IFS= read -r -t 0 <&"$audio_out"; then
            # Readiness promises bytes, not a complete line. A timed-out read
            # consumes its partial result, so preserve it for the next poll.
            if IFS= read -r -t 0.001 response <&"$audio_out"; then
                response=${sync_response_buffer:-}$response
                sync_response_buffer=''
                parse_audio_response "$response" || return 1
                clock_ms
                game_clock_sample "$audio_ms" "$audio_sample_ms" "$now_ms"
                sync_pending=0
            else
                read_status=$?
                if ((read_status > 128)); then
                    sync_response_buffer+=$response
                else
                    chart_error 'Audio disconnected'; return 1
                fi
            fi
        fi
        if ((sync_pending && now_ms - sync_requested_ms > 3000)); then
            chart_error 'Audio synchronization timed out'; return 1
        fi
    fi
    if ((!sync_pending && !audio_eof && runtime >= next_sync)); then
        printf 'time\n' >&"$audio_in" || return 1
        sync_pending=1 sync_requested_ms=$now_ms next_sync=$((runtime + 50))
    fi
    return 0
}

render() {
    local row lane i remaining y tail ending code glyph frame='' line cell body_cell key height=${playfield_rows:-16}
    local -a cells=() occupied_rows=() cell_priority=()
    lower_bound_visible "$((elapsed - 140))"
    for ((i=note_index; i<total && note_times[i]<=elapsed+2000; i++)); do
        [[ ${note_states[i]} == pending || ${note_states[i]} == holding ]] || continue
        remaining=$((note_times[i] - elapsed))
        ending=${note_ends[i]:-${note_times[i]}}
        code=${note_colors[i]:-}
        if [[ -z $code ]]; then note_color "${note_times[i]}"; code=$color_code; fi
        if ((ending > note_times[i] && ending >= elapsed - 140)); then
            y=$height; ((remaining > 0)) && y=$((height - remaining * height / 2000))
            tail=$((height - (ending - elapsed) * height / 2000))
            ((tail < 0)) && tail=0; ((tail > height)) && tail=$height
            body_cell=$'\e['"$code"'m  |  '$'\e[0m'
            for ((row=tail; row<=y; row++)); do
                key=$((row * 4 + note_lanes[i]))
                if [[ ! ${cells[key]:-} ]]; then
                    cells[key]=$body_cell; cell_priority[key]=1; occupied_rows[row]=1
                fi
            done
            if ((ending <= elapsed + 2000)); then paint_game_cell "$tail" "${note_lanes[i]}" '[---]' "$code" 2; fi
            glyph='[===]'
            if [[ ${note_states[i]} == holding ]]; then glyph='[HLD]'; ((ending <= elapsed)) && glyph='[---]'; fi
            paint_game_cell "$y" "${note_lanes[i]}" "$glyph" "$code" 3
        elif ((remaining >= -140 && remaining <= 2000)); then
            y=$height
            ((remaining > 0)) && y=$((height - remaining * height / 2000))
            paint_game_cell "$y" "${note_lanes[i]}" '[===]' "$code" 3
        fi
    done
    local title=${mode_label:-PRACTICE}
    [[ -z ${score_grid:-} ]] || title+=" | GRID $score_grid | HIGH $best_score"
    printf -v frame '  FOUR KEYS - %s\n  Beat:white\t Half:cyan\t Quarter:yellow\t Other:purple\n  SCORE %06d     COMBO %03d     BEST %03d\n\n' "$title" "$score" "$combo" "$max_combo"
    frame+='          +-----+-----+-----+-----+'
    frame+=$'\n'
    for ((row=0; row<=height; row++)); do
        if [[ ! ${occupied_rows[row]:-} ]] && ((row != height)); then
            frame+=$'          |     |     |     |     |\n'
            continue
        fi
        line='          |'
        for ((lane=0; lane<4; lane++)); do
            cell='     '
            [[ ${cells[row * 4 + lane]:-} ]] && cell=${cells[row * 4 + lane]}
            if ((row == height)) && [[ $cell == '     ' ]]; then
                cell=$'\e[90m-----\e[0m'
            fi
            line+="$cell|"
        done
        frame+="$line"$'\n'
    done
    frame+='          +-----+-----+-----+-----+'
    frame+=$'\n          |  D  |  F  |  J  |  K  |\n\n'
    ((elapsed > feedback_until)) && feedback=''
    if ((total > 0 && elapsed < note_times[0])); then
        printf -v line '  Get ready! First note in %.1f s' "$((note_times[0] - elapsed))e-3"
    else
        printf -v line '  %-24s  %2d / %2d s' "$feedback" "$((elapsed / 1000))" "$((end_ms / 1000))"
    fi
    frame+="$line"$'\n  D F J K: hit / hold head+tail    Q / Esc: quit\n'
    # A single write per frame; clear below the frame to remove stale text.
    present_frame "$frame"
}

cleanup() {
    stop_audio
    if [[ -n ${saved_stty:-} ]]; then
        stty "$saved_stty"
        printf '\e[0m\e[?25h\e[?1049l'
    fi
}

extend_playback_end() {
    # Chart time is media time minus offset. Keep both the last note's
    # judgment window and the audio's full outro, including reverb release.
    (($1 > 0)) || return 0
    local media_end=$(($1 - chart_offset))
    ((media_end > end_ms)) && end_ms=$media_end
    return 0
}

main() {
    if (($# == 0)) || [[ ${1:-} == --menu ]]; then
        [[ ${1:-} != --menu ]] || shift
        bash "$GAME_ROOT/menu.sh" "$@"
        return $?
    fi
    local file='' audio_override='' offset_override='' silent=0
    local render_fps=60
    while (($#)); do
    case $1 in
        -h|--help)
            printf 'Usage: ./game.sh [--menu | --practice | chart.csv] [--audio FILE] [--offset MS] [--fps 15-120] [--silent]\nNo arguments: song and difficulty menu. --practice: built-in practice.\nDefault: 60 FPS; playfield expands to terminal height at startup.\nMusic and high scores require python3; music also requires mpv.\nD F J K: hit; Q / Esc: quit. Positive offset delays notes.\n'
            return 0 ;;
        --audio|--offset|--fps)
            (($# >= 2)) || { chart_error "Missing value for $1"; return 1; }
            case $1 in
                --audio) audio_override=$2 ;;
                --offset) offset_override=$2 ;;
                --fps)
                    [[ $2 =~ ^[0-9]{1,3}$ ]] || { chart_error 'FPS must be an integer from 15 to 120'; return 1; }
                    render_fps=$((10#$2))
                    ((render_fps >= 15 && render_fps <= 120)) || { chart_error 'FPS must be 15-120'; return 1; } ;;
            esac
            shift ;;
        --silent) silent=1 ;;
        --practice) ;;
        -*) chart_error "Unknown option: $1"; return 1 ;;
        *) [[ -z $file ]] || { chart_error 'Only one chart may be supplied'; return 1; }; file=$1 ;;
    esac
    shift
    done
    if [[ -n $file ]]; then
        load_chart "$file" || return 1
        ((total)) || { chart_error 'Chart has no notes. Add notes with editor.sh first.'; return 1; }
        mode_label=CHART
    else
        make_chart
        chart_offset=0 audio_path='' mode_label=PRACTICE
    fi
    [[ -z $audio_override ]] || audio_path=$audio_override
    prepare_score_context "$audio_path"
    if [[ -n $offset_override ]]; then
        [[ $offset_override =~ ^-?[0-9]{1,7}$ ]] || { chart_error 'Offset must be an integer in milliseconds'; return 1; }
        if [[ $offset_override == -* ]]; then chart_offset=$((-10#${offset_override#-})); else chart_offset=$((10#$offset_override)); fi
    fi
    ((silent)) && audio_path=''
    [[ -z $audio_path || -n $file ]] || { chart_error '--audio requires a chart'; return 1; }
    if [[ ! -t 0 || ! -t 1 || ${TERM:-dumb} == dumb ]]; then
        printf 'Run this game in an interactive ANSI terminal.\n' >&2
        return 1
    fi
    local dimensions rows cols
    dimensions=$(stty size)
    read -r rows cols <<< "$dimensions"
    if (( rows < 28 || cols < 56 )); then
        printf 'Terminal too small: need at least 56 columns x 28 rows (current %s x %s).\n' "$cols" "$rows" >&2
        return 1
    fi
    # Leave space for header, borders, score, feedback and one spare terminal
    # row so the final newline never scrolls the whole screen.
    playfield_rows=$((rows - 12))
    score=0 combo=0 max_combo=0 perfect=0 great=0 good=0 miss=0
    elapsed=0 feedback='' feedback_until=0 expire_cursor=0 hit_errors=()
    saved_stty=$(stty -g)
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    if [[ -n $audio_path ]]; then
        start_audio || return 1
        extend_playback_end "$audio_duration_ms"
    fi
    stty -echo -icanon min 0 time 0 -ixon
    printf '\e[?1049h\e[?25l\e[2J'
    # Prepare input and the first screen before releasing the paused player.
    render
    if [[ -n ${audio_pid:-} ]]; then audio_command play || return 1; fi
    local start_ms next_frame=0 key quit=0 next_sync=0 runtime sync_pending=0 sync_requested_ms=0 sync_response_buffer='' wait_ms input_timeout
    clock_ms
    start_ms=$now_ms
    if [[ -n ${audio_pid:-} ]]; then game_clock_init "$audio_ms" "$audio_sample_ms" "$now_ms"; fi
    next_frame=0
    while :; do
        key=''
        # Timed read also yields the CPU between frames.
        clock_ms
        wait_ms=$((next_frame - (now_ms - start_ms)))
        ((wait_ms < 1)) && wait_ms=1
        ((wait_ms > 5)) && wait_ms=5
        printf -v input_timeout '0.%03d' "$wait_ms"
        IFS= read -rsn1 -t "$input_timeout" key || :
        clock_ms
        runtime=$((now_ms - start_ms))
        if [[ -n ${audio_pid:-} ]]; then
            game_clock_step "$now_ms"
        else
            elapsed=$((runtime - chart_offset))
        fi
        # Finish even if the song ends before the last note.
        if [[ -n ${audio_pid:-} ]] && ((runtime > end_ms + chart_offset + 5000 && !audio_eof)); then
            chart_error 'Audio stopped advancing before the chart ended.'
            return 1
        fi
        expire_notes
        if ((elapsed >= end_ms)); then
            # With a known duration, confirm EOF instead of cutting the final
            # audio buffer because the smoothed game clock is slightly ahead.
            if [[ -z ${audio_pid:-} ]] || ((audio_duration_ms == 0 || audio_eof)); then break; fi
        fi
        case $key in
            d|D) hit_lane 0 ;; f|F) hit_lane 1 ;;
            j|J) hit_lane 2 ;; k|K) hit_lane 3 ;;
            q|Q|$'\e') quit=1; break ;;
        esac
        if [[ -n ${audio_pid:-} ]]; then poll_game_audio || return 1; fi
        if ((runtime >= next_frame)); then
            # Drawing uses the same clock, sampled immediately before building
            # the frame rather than the earlier input-poll timestamp.
            clock_ms
            if [[ -n ${audio_pid:-} ]]; then game_clock_step "$now_ms"
            else elapsed=$((now_ms - start_ms - chart_offset)); fi
            render
            clock_ms
            advance_frame_deadline "$((now_ms - start_ms))" "$render_fps"
        fi
    done
    cleanup
    saved_stty=''
    printf '\n%s %s\nScore: %d   Max combo: %d / %d\nPerfect: %d   Great: %d   Good: %d   Miss: %d\n' \
        "$mode_label" \
        "$([[ $quit == 1 ]] && printf stopped || printf complete)" \
        "$score" "$max_combo" "$total" "$perfect" "$great" "$good" "$miss"
    if ((!quit)); then record_high_score || :; fi
    if ((${#hit_errors[@]} >= 4)); then
        local -a ordered_errors=()
        local middle median
        mapfile -t ordered_errors < <(printf '%s\n' "${hit_errors[@]}" | sort -n)
        middle=$((${#ordered_errors[@]} / 2))
        median=${ordered_errors[middle]}
        if ((${#ordered_errors[@]} % 2 == 0)); then median=$(((ordered_errors[middle-1] + median) / 2)); fi
        printf 'Median hit error: %+d ms (+ late / - early). Current offset: %+d ms\n' "$median" "$chart_offset"
    fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
