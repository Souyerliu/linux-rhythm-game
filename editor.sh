#!/usr/bin/env bash
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/game.sh"

# Consume escape sequences as one key so an arrow's final B/C cannot edit BPM.
read_editor_key() {
    local prefix char sequence='' count
    key=''; IFS= read -rsn1 -t "${1:-0.01}" key || :
    [[ $key == $'\e' ]] || return 0
    key=''
    IFS= read -rsn1 -t 0.05 prefix || return 0
    [[ $prefix == '[' || $prefix == O ]] || return 0
    for ((count=0; count<16; count++)); do
        char=''; IFS= read -rsn1 -t 0.05 char || return 0
        sequence+=$char
        [[ $char == [@-~] ]] && break
    done
    case $sequence in
        A) key=up ;; B) key=down ;; C) key=right ;; D) key=left ;;
    esac
    return 0
}

find_note() {
    selected=-1
    local i
    for ((i=0; i<total; i++)); do
        if ((note_times[i] == cursor && note_lanes[i] == lane)); then selected=$i; break; fi
    done
}

pause_preview() {
    if ((playing)); then
        audio_command pause || return 1
        cursor=$((audio_ms - chart_offset)); ((cursor < 0)) && cursor=0
        playing=0
    fi
    return 0
}

update_preview() {
    clock_ms
    if ((now_ms >= preview_next_sync)); then
        audio_command time || return 1
        clock_ms
        preview_anchor_ms=$now_ms preview_anchor_audio=$audio_ms
        preview_next_sync=$((now_ms + 100))
    fi
    cursor=$((preview_anchor_audio + now_ms - preview_anchor_ms - chart_offset))
    if ((audio_eof)); then cursor=$((audio_ms - chart_offset)); playing=0 status='Preview ended'; fi
    ((cursor < 0)) && cursor=0
    return 0
}

cycle_beat_grid() {
    local -a grids=(250000 500000 1000000)
    beat_grid_index=$(( ${beat_grid_index:-2} + $1 ))
    ((beat_grid_index < 0)) && beat_grid_index=0
    ((beat_grid_index > 2)) && beat_grid_index=2
    beat_step_ticks=${grids[beat_grid_index]}
    status='Beat grid changed; notes remain at their original positions'
}

shift_time() {
    local direction=$1 ticks
    if [[ ${view_mode:-ms} == beat ]]; then
        ms_to_beat "$cursor"
        ticks=$((beat_ticks + direction * ${beat_step_ticks:-1000000})); ((ticks < 0)) && ticks=0
        beat_to_ms "$ticks"; target_time=$mapped_ms
    else target_time=$((cursor + direction * step)); fi
    ((target_time < 0)) && target_time=0
    ((target_time > 999999999)) && target_time=999999999
    return 0
}

edit_current_bpm() {
    local operation=$1 beat value
    ms_to_beat "$cursor"; beat=$((beat_ticks / 1000000))
    bpm_at_beat "$((beat * 1000000))"
    case $operation in
        up) value=$((current_bpm + 1)) ;;
        down) value=$((current_bpm - 1)) ;;
        remove) change_tempo "$beat" "$current_bpm" 1; return ;;
        *) value=$operation ;;
    esac
    change_tempo "$beat" "$value"
}

prompt_bpm() {
    local input='' char
    while :; do
        status="BPM at this beat (20-400): $input  Enter=apply Esc=cancel"
        render_editor
        char=''; IFS= read -rsn1 char || return
        case $char in
            '')
                if [[ $input =~ ^[0-9]{1,3}$ ]]; then edit_current_bpm "$((10#$input))"; else status='BPM edit cancelled'; fi
                return ;;
            $'\e') status='BPM edit cancelled'; return ;;
            $'\x7f'|$'\b') input=${input%?} ;;
            [0-9]) ((${#input} < 3)) && input+=$char ;;
        esac
    done
}

edit_note() {
    local action=$1 target_time=$cursor target_lane=$lane i old_cursor=$cursor old_lane=$lane ticks
    local -a old_times=( "${note_times[@]}" ) old_lanes=( "${note_lanes[@]}" ) old_ends=()
    for ((i=0; i<total; i++)); do old_ends+=( "${note_ends[i]:-${note_times[i]}}" ); done
    note_ends=( "${old_ends[@]}" )
    find_note
    case $action in
        add)
            ((selected < 0)) || { status='A note already exists here'; return 0; }
            note_times+=( "$cursor" ); note_lanes+=( "$lane" ); note_ends+=( "$cursor" ) ;;
        delete)
            ((selected >= 0)) || { status='No note at cursor'; return 0; }
            unset 'note_times[selected]' 'note_lanes[selected]' 'note_ends[selected]' ;;
        hold|shorter|longer)
            ((selected >= 0)) || { status='Select a note head first (N/P)'; return 0; }
            if [[ $action == hold ]] && ((note_ends[selected] > cursor)); then
                note_ends[selected]=$cursor
            elif [[ $action == hold ]]; then
                ms_to_beat "$cursor"; beat_to_ms "$((beat_ticks + 1000000))"
                note_ends[selected]=$mapped_ms
            else
                ((note_ends[selected] > cursor)) || { status='V converts a tap to a hold'; return 0; }
                ticks=1; [[ $action == shorter ]] && ticks=-1
                if [[ ${view_mode:-ms} == beat ]]; then
                    ms_to_beat "${note_ends[selected]}"; ticks=$((beat_ticks + ticks * ${beat_step_ticks:-1000000}))
                    ((ticks > 0)) || { status='Hold end must be after its start'; return 0; }
                    beat_to_ms "$ticks"; target_time=$mapped_ms
                else target_time=$((note_ends[selected] + ticks * step)); fi
                ((target_time > cursor)) || { status='Hold end must be after its start'; return 0; }
                note_ends[selected]=$target_time
            fi ;;
        earlier|later|left|right)
            ((selected >= 0)) || { status='Select a note first (N/P)'; return 0; }
            case $action in
                earlier) shift_time -1 ;; later) shift_time 1 ;;
                left) target_lane=$((lane - 1)) ;; right) target_lane=$((lane + 1)) ;;
            esac
            ((target_time >= 0 && target_time <= 999999999 && target_lane >= 0 && target_lane <= 3)) || return 0
            for ((i=0; i<total; i++)); do
                if ((i != selected && note_times[i] == target_time && note_lanes[i] == target_lane)); then
                    status='Move blocked: a note already exists there'; return 0
                fi
            done
            if [[ $action == earlier || $action == later ]]; then
                if [[ ${view_mode:-ms} == beat ]]; then
                    ms_to_beat "$cursor"; ticks=$((-beat_ticks))
                    ms_to_beat "$target_time"; ticks=$((ticks + beat_ticks))
                    local move_ticks=$ticks
                    ms_to_beat "${note_ends[selected]}"; ticks=$((beat_ticks + move_ticks))
                    if ((ticks < 0)); then ticks=0; fi
                    beat_to_ms "$ticks"; note_ends[selected]=$mapped_ms
                else note_ends[selected]=$((note_ends[selected] + target_time - cursor)); fi
            fi
            note_times[selected]=$target_time; note_lanes[selected]=$target_lane
            cursor=$target_time lane=$target_lane ;;
    esac
    note_times=( "${note_times[@]}" ); note_lanes=( "${note_lanes[@]}" ); note_ends=( "${note_ends[@]}" )
    if ! sort_notes; then
        note_times=( "${old_times[@]}" ); note_lanes=( "${old_lanes[@]}" ); note_ends=( "${old_ends[@]}" )
        cursor=$old_cursor lane=$old_lane; sort_notes
        status='Edit blocked: same-lane overlap or invalid hold'; return 0
    fi
    dirty=1 status='Modified (E saves)'
}

select_neighbor() {
    local direction=$1 i chosen=-1
    if [[ $direction == next ]]; then
        for ((i=0; i<total; i++)); do
            if ((note_times[i] > cursor || (note_times[i] == cursor && note_lanes[i] > lane))); then chosen=$i; break; fi
        done
    else
        for ((i=total-1; i>=0; i--)); do
            if ((note_times[i] < cursor || (note_times[i] == cursor && note_lanes[i] < lane))); then chosen=$i; break; fi
        done
    fi
    if ((chosen >= 0)); then cursor=${note_times[chosen]}; lane=${note_lanes[chosen]}; fi
}

render_editor() {
    local frame line row t track cell i index difference start cursor_ticks row_ticks label marker row_bpm window_start window_end ending code tail_index ticks_ready grid=${beat_step_ticks:-1000000} grid_label
    local -A visible=()
    local -a row_times=() row_beats=()
    ms_to_beat "$cursor"; cursor_ticks=$beat_ticks
    format_beat "$cursor_ticks"
    printf -v frame '  FOUR KEYS - EDITOR   notes:%d   modified:%s\n' "$total" "$dirty"
    if [[ ${view_mode:-ms} == beat ]]; then
        start=$((cursor_ticks / grid * grid - 8 * grid))
        case $grid in 250000) grid_label=1/4 ;; 500000) grid_label=1/2 ;; *) grid_label=1 ;; esac
        printf -v line '  BEAT %s (%d ms)   Step: %s beat   BPM: %d   Offset: %+d\n' "$beat_label" "$cursor" "$grid_label" "$current_bpm" "$chart_offset"
        frame+="$line"$'  BEAT        BPM      D     F     J     K\n'
    else
        start=$((cursor - 8 * step))
        printf -v line '  Cursor: %d ms   Step: %d ms   BPM: %d   Offset: %+d ms\n' "$cursor" "$step" "$current_bpm" "$chart_offset"
        frame+="$line"$'  TIME (ms)   BPM      D     F     J     K\n'
    fi
    for ((row=0; row<17; row++)); do
        if [[ ${view_mode:-ms} == beat ]]; then
            row_ticks=$((start + row * grid)); row_beats[row]=$row_ticks
            if ((row_ticks < 0)); then row_times[row]=-1; continue; fi
            beat_to_ms "$row_ticks"; row_times[row]=$mapped_ms
        else row_times[row]=$((start + row * step)); fi
    done
    if [[ ${view_mode:-ms} == beat ]]; then
        window_start=0
        if ((start > 0)); then beat_to_ms "$start"; window_start=$mapped_ms; fi
        beat_to_ms "$((start + 17 * grid))"; window_end=$mapped_ms
    else
        window_start=$start; ((window_start < 0)) && window_start=0
        window_end=$((start + 16 * step + step / 2))
    fi
    lower_bound_visible "$window_start"
    for ((i=note_index; i<total && note_times[i]<=window_end; i++)); do
        ending=${note_ends[i]:-${note_times[i]}}
        ((ending >= window_start)) || continue
        code=${note_colors[i]:-}
        ticks_ready=0
        if [[ -z $code ]]; then note_color "${note_times[i]}"; code=$color_code; ticks_ready=1; fi
        if ((ending > note_times[i])); then
            for ((row=0; row<17; row++)); do
                if ((row_times[row] > note_times[i] && row_times[row] < ending)); then
                    visible[$row,${note_lanes[i]}]=$'\e['"$code"'m  |   '$'\e[0m'
                fi
            done
            if [[ ${view_mode:-ms} == beat ]]; then
                ms_to_beat "$ending"; tail_index=$(((beat_ticks - start) / grid))
                ticks_ready=0
                ((beat_ticks < start)) && tail_index=-1
            else tail_index=$(((ending - start + step / 2) / step)); fi
            if ((tail_index >= 0 && tail_index <= 16)); then
                visible[$tail_index,${note_lanes[i]}]=$'\e['"$code"'m[---] '$'\e[0m'
            fi
        fi
        if [[ ${view_mode:-ms} == beat ]]; then
            ((ticks_ready)) || ms_to_beat "${note_times[i]}"
            difference=$((beat_ticks - start))
            ((difference >= 0 && difference < 17 * grid)) || continue
            index=$((difference / grid))
        else
            difference=$((note_times[i] - start))
            ((difference >= 0 && difference <= 16 * step + step / 2)) || continue
            index=$(((difference + step / 2) / step))
        fi
        cell='[~~~] '
        ((index <= 16 && note_times[i] == row_times[index])) && cell='[===] '
        visible[$index,${note_lanes[i]}]=$'\e['"$code"'m'"$cell"$'\e[0m'
    done
    for ((row=0; row<17; row++)); do
        t=${row_times[row]}
        if ((t < 0)); then frame+=$'\n'; continue; fi
        if [[ ${view_mode:-ms} == beat ]]; then
            row_ticks=${row_beats[row]}; format_beat "$row_ticks"; label=$beat_label
            bpm_at_beat "$row_ticks"
        else
            label=$t; ms_to_beat "$t"; row_ticks=$beat_ticks
        fi
        row_bpm=$current_bpm; marker=' '
        ((row_ticks == tempo_beats[timing_segment] * 1000000)) && marker='*'
        printf -v line '  %9s %3d%s    ' "$label" "$row_bpm" "$marker"
        for ((track=0; track<4; track++)); do
            cell=${visible[$row,$track]:-'  .   '}
            if ((row == 8 && track == lane)); then cell=$'\e[7m'"$cell"$'\e[0m'; fi
            line+="$cell"
        done
        frame+="$line"$'\n'
    done
    frame+=$'  Up/Down: time  Left/Right: lane  N/P: select  T: ms/beat\n  F: add  X: delete  H/L: move time  U/I: move lane\n  V: tap/hold  J/K: shorten/extend hold tail\n  [/]: grid step  B/b: BPM +/-1  C: set BPM  R: remove BPM\n  O/o: offset +/-10ms  Space: preview  E: save\n  Q: quit (twice to discard)  *: BPM change starts here\n'
    printf -v line '  %-70.70s\n' "$status"
    frame+="$line"
    present_frame "$frame"
}

editor_main() {
    local file=${1:-} override='' key rows cols dimensions armed=0 next_frame=0 runtime redraw=1 wait_ms input_timeout
    if [[ -z $file || $file == --help || $file == -h ]]; then
        printf 'Usage: ./editor.sh CHART.csv [--audio FILE]\nNew charts are created on save. Music preview requires mpv + python3.\n'
        [[ -n $file ]]; return
    fi
    shift
    if (($#)); then
        [[ $# == 2 && $1 == --audio ]] || { chart_error 'Expected --audio FILE'; return 1; }
        override=$2
    fi
    if [[ -f $file ]]; then load_chart "$file" || return 1
    else
        [[ -d $(dirname -- "$file") ]] || { chart_error 'Create the chart directory first'; return 1; }
        chart_path=$file chart_audio='' audio_path='' chart_bpm=120 chart_offset=0
        tempo_beats=(0) tempo_bpms=(120); build_timing
        note_times=() note_lanes=() note_ends=() note_states=(); sort_notes
    fi
    dirty=0
    if [[ -n $override ]]; then
        [[ -f $override ]] || { chart_error "Audio not found: $override"; return 1; }
        audio_path=$(cd -- "$(dirname -- "$override")" && printf '%s/%s' "$PWD" "$(basename -- "$override")")
        chart_audio=$audio_path dirty=1
    fi
    [[ -t 0 && -t 1 && ${TERM:-dumb} != dumb ]] || { chart_error 'Use an interactive ANSI terminal'; return 1; }
    dimensions=$(stty size); read -r rows cols <<< "$dimensions"
    ((rows >= 28 && cols >= 76)) || { chart_error 'Editor needs 76 columns x 28 rows'; return 1; }
    saved_stty=$(stty -g)
    trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM HUP
    stty -echo -icanon min 0 time 0 -ixon
    printf '\e[?1049h\e[?25l\e[2J'
    cursor=0 lane=0 playing=0 step_index=6 beat_grid_index=2 beat_step_ticks=1000000 view_mode=ms status='Ready. T toggles beat view; N selects next note.'
    local -a steps=(1 5 10 25 50 100)
    local step
    clock_ms; next_frame=$now_ms
    while :; do
        clock_ms; runtime=$now_ms
        if ((runtime >= next_frame && (redraw || playing))); then
            if ((playing)); then update_preview || return 1; fi
            ms_to_beat "$cursor"
            steps[6]=$((60000 / current_bpm / 4)); steps[7]=$((60000 / current_bpm / 2)); steps[8]=$((60000 / current_bpm))
            step=${steps[step_index]}
            render_editor; redraw=0
            clock_ms; advance_frame_deadline "$now_ms"
        fi
        wait_ms=100
        if ((redraw || playing)); then
            clock_ms; wait_ms=$((next_frame - now_ms))
            ((wait_ms < 1)) && wait_ms=1
            ((wait_ms > 33)) && wait_ms=33
        fi
        printf -v input_timeout '0.%03d' "$wait_ms"
        read_editor_key "$input_timeout"
        [[ -n $key ]] || continue
        redraw=1
        if [[ $key == q ]]; then
            if ((dirty && !armed)); then status='UNSAVED! E saves; Q again discards.'; armed=1; continue; fi
            break
        fi
        armed=0
        if [[ $key == ' ' ]]; then
            if ((playing)); then pause_preview || return 1; status='Preview paused'
            elif [[ -z $audio_path ]]; then status='No audio: reopen with --audio FILE'
            else
                if [[ -z ${audio_pid:-} ]]; then
                    if ! start_audio; then status='Cannot start mpv (check dependency/audio file)'; continue; fi
                fi
                audio_command seek "$((cursor + chart_offset))" && audio_command play || return 1
                clock_ms
                preview_anchor_ms=$now_ms preview_anchor_audio=$audio_ms preview_next_sync=$((now_ms + 100))
                playing=1 status='Preview playing; any edit/navigation key pauses'
            fi
            continue
        fi
        pause_preview || return 1
        ms_to_beat "$cursor"
        steps[6]=$((60000 / current_bpm / 4)); steps[7]=$((60000 / current_bpm / 2)); steps[8]=$((60000 / current_bpm))
        step=${steps[step_index]}
        case $key in
            up|w) shift_time -1; cursor=$target_time ;;
            down|s) shift_time 1; cursor=$target_time ;;
            left|a) ((lane > 0)) && ((lane-=1)) ;; right|d) ((lane < 3)) && ((lane+=1)) ;;
            n) select_neighbor next ;; p) select_neighbor previous ;;
            f) edit_note add ;; x) edit_note delete ;;
            h) edit_note earlier ;; l) edit_note later ;;
            u) edit_note left ;; i) edit_note right ;;
            v) edit_note hold ;; j) edit_note shorter ;; k) edit_note longer ;;
            t) if [[ $view_mode == ms ]]; then view_mode=beat; else view_mode=ms; fi ;;
            '[') if [[ $view_mode == beat ]]; then cycle_beat_grid -1; else ((step_index > 0)) && ((step_index-=1)); fi ;;
            ']') if [[ $view_mode == beat ]]; then cycle_beat_grid 1; else ((step_index < 8)) && ((step_index+=1)); fi ;;
            B) edit_current_bpm up ;; b) edit_current_bpm down ;;
            c) prompt_bpm ;; r) edit_current_bpm remove ;;
            O) ((chart_offset < 9999989)) && { ((chart_offset+=10)); dirty=1; } ;;
            o) ((chart_offset > -9999989)) && { ((chart_offset-=10)); dirty=1; } ;;
            e) if save_chart; then dirty=0 status='Saved'; else status='SAVE FAILED: check path and permissions'; fi ;;
        esac
    done
    cleanup; saved_stty=''
    printf 'Editor closed. Chart: %s\n' "$chart_path"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then editor_main "$@"; fi
