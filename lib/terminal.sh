#!/usr/bin/env bash

present_frame() {
    # A newline moves the cursor but does not erase the old row. Clear every
    # line, including empty rows before beat 1 and shortened header/status text.
    local output=${1//$'\n'/$'\e[K\n'}
    printf '\e[H%s\e[J' "$output"
}

advance_frame_deadline() {
    local timestamp=$1 fps=${2:-0} tick
    # Keep a fixed cadence (33 ms for the editor, explicit FPS for the game).
    # Skip missed frames instead of bursting or accumulating processing time.
    if ((timestamp >= next_frame)); then
        if ((fps > 0)); then
            # Rational frame times: 17,34,50,... at 60 FPS, without rounding
            # every interval to 16/17 ms and accumulating a clock error.
            tick=$((timestamp * fps / 1000 + 1))
            next_frame=$(((tick * 1000 + fps - 1) / fps))
        else
            next_frame=$((next_frame + ((timestamp - next_frame) / 33 + 1) * 33))
        fi
    fi
}
