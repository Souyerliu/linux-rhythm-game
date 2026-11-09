#!/usr/bin/env bash
# Musical coordinates: zero-based beats, 1,000,000 ticks per beat.
# Segment start times use microseconds to avoid cumulative ms rounding.
build_timing() {
    local i span
    tempo_beats[0]=0 tempo_bpms[0]=$chart_bpm tempo_us=(0)
    for ((i=1; i<${#tempo_beats[@]}; i++)); do
        span=$(((tempo_beats[i] - tempo_beats[i-1]) * 60000000))
        tempo_us[i]=$((tempo_us[i-1] + (span + tempo_bpms[i-1] / 2) / tempo_bpms[i-1]))
    done
}

bpm_at_beat() {
    local ticks=$1 low=0 high=$((${#tempo_beats[@]} - 1)) mid
    while ((low < high)); do
        mid=$(((low + high + 1) / 2))
        if ((ticks >= tempo_beats[mid] * 1000000)); then low=$mid; else high=$((mid - 1)); fi
    done
    timing_segment=$low
    current_bpm=${tempo_bpms[timing_segment]}
}

beat_to_ms() {
    local ticks=$1 micros
    bpm_at_beat "$ticks"
    micros=$((tempo_us[timing_segment] + ((ticks - tempo_beats[timing_segment] * 1000000) * 60 + current_bpm / 2) / current_bpm))
    mapped_ms=$(((micros + 500) / 1000))
}

ms_to_beat() {
    local ms=$1 segment=0 nearest difference original low=0 high=$((${#tempo_us[@]} - 1)) mid
    while ((low < high)); do
        mid=$(((low + high + 1) / 2))
        if ((ms * 1000 >= tempo_us[mid])); then low=$mid; else high=$((mid - 1)); fi
    done
    segment=$low
    beat_ticks=$((tempo_beats[segment] * 1000000 + (ms * 1000 - tempo_us[segment]) * tempo_bpms[segment] / 60))
    # Exact quarter-beat boundaries may round up/down in integer ms. Recover
    # them before further grid movement so repeated 1/4 steps do not drift.
    nearest=$(((beat_ticks + 125000) / 250000 * 250000))
    original=$beat_ticks
    beat_to_ms "$nearest"
    difference=$((mapped_ms - ms)); difference=${difference#-}
    if ((difference == 0)); then beat_ticks=$nearest; else beat_ticks=$original; fi
    bpm_at_beat "$beat_ticks"
}

format_beat() {
    local ticks=$1
    printf -v beat_label '%d.%03d' "$((ticks / 1000000 + 1))" "$((ticks % 1000000 / 1000))"
}

# Replace/remove one integer-beat event and preserve note positions in beats.
change_tempo() {
    local beat=$1 bpm=$2 remove=${3:-0} i inserted=0 cursor_ticks t key
    local -a ticks=() end_ticks=() new_times=() new_ends=() beats=() bpms=()
    local -a old_times=( "${note_times[@]}" ) old_ends=()
    local -a old_beats=( "${tempo_beats[@]}" ) old_bpms=( "${tempo_bpms[@]}" )
    local old_bpm=$chart_bpm
    local -A occupied=()
    ((bpm >= 20 && bpm <= 400)) || { status='BPM must be 20-400'; return 1; }
    if ((remove && beat == 0)); then status='The first beat needs a BPM'; return 1; fi
    for ((i=0; i<total; i++)); do
        ms_to_beat "${note_times[i]}"; ticks+=( "$beat_ticks" )
        old_ends+=( "${note_ends[i]:-${note_times[i]}}" )
        ms_to_beat "${old_ends[i]}"; end_ticks+=( "$beat_ticks" )
    done
    ms_to_beat "$cursor"; cursor_ticks=$beat_ticks
    for ((i=0; i<${#tempo_beats[@]}; i++)); do
        if ((!inserted && tempo_beats[i] >= beat)); then
            if ((!remove)); then beats+=( "$beat" ); bpms+=( "$bpm" ); fi
            inserted=1
        fi
        ((tempo_beats[i] == beat)) && continue
        beats+=( "${tempo_beats[i]}" ); bpms+=( "${tempo_bpms[i]}" )
    done
    if ((!inserted && !remove)); then beats+=( "$beat" ); bpms+=( "$bpm" ); fi
    tempo_beats=( "${beats[@]}" ); tempo_bpms=( "${bpms[@]}" ); chart_bpm=${tempo_bpms[0]}
    build_timing
    for ((i=0; i<total; i++)); do
        beat_to_ms "${ticks[i]}"; t=$mapped_ms; key=$t,${note_lanes[i]}
        if ((t > 999999999)) || [[ ${occupied[$key]:-} ]]; then
            tempo_beats=( "${old_beats[@]}" ); tempo_bpms=( "${old_bpms[@]}" ); chart_bpm=$old_bpm
            build_timing
            status='BPM change blocked: note collision or time limit'; return 1
        fi
        occupied[$key]=1; new_times+=( "$t" )
        beat_to_ms "${end_ticks[i]}"
        if ((mapped_ms > 999999999 || (old_ends[i] > old_times[i] && mapped_ms <= t))); then
            tempo_beats=( "${old_beats[@]}" ); tempo_bpms=( "${old_bpms[@]}" ); chart_bpm=$old_bpm
            build_timing; status='BPM change blocked: invalid hold duration'; return 1
        fi
        new_ends+=( "$mapped_ms" )
    done
    beat_to_ms "$cursor_ticks"
    if ((mapped_ms > 999999999)); then
        tempo_beats=( "${old_beats[@]}" ); tempo_bpms=( "${old_bpms[@]}" ); chart_bpm=$old_bpm
        build_timing; status='BPM change blocked: cursor time limit'; return 1
    fi
    local new_cursor=$mapped_ms
    note_times=( "${new_times[@]}" ); note_ends=( "${new_ends[@]}" )
    if ! sort_notes; then
        tempo_beats=( "${old_beats[@]}" ); tempo_bpms=( "${old_bpms[@]}" ); chart_bpm=$old_bpm
        note_times=( "${old_times[@]}" ); note_ends=( "${old_ends[@]}" ); build_timing; sort_notes
        status='BPM change blocked: hold overlap or time limit'; return 1
    fi
    cursor=$new_cursor
    dirty=1 status='BPM map changed; notes kept at their beat positions'
}
