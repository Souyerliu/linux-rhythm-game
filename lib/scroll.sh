#!/usr/bin/env bash
# Fixed-point tenths keep visual speed independent from the audio/game clock.
SCROLL_DEFAULT_SPEED=20

set_scroll_speed() {
    local value=$1 whole fraction speed
    [[ $value =~ ^[0-5](\.[0-9])?$ ]] || {
        printf 'Speed must be 0.5-5.0 (at most one decimal place)\n' >&2; return 1;
    }
    whole=${value%%.*}; fraction=0
    [[ $value != *.* ]] || fraction=${value#*.}
    speed=$((whole * 10 + fraction))
    ((speed >= 5 && speed <= 50)) || {
        printf 'Speed must be 0.5-5.0\n' >&2; return 1;
    }
    scroll_speed=$speed
    update_scroll_speed
}

update_scroll_speed() {
    scroll_window_ms=$((20000 / scroll_speed))
    printf -v scroll_label '%d.%d' "$((scroll_speed / 10))" "$((scroll_speed % 10))"
}

adjust_scroll_speed() {
    scroll_speed=$((${scroll_speed:-$SCROLL_DEFAULT_SPEED} + $1))
    ((scroll_speed >= 5)) || scroll_speed=5
    ((scroll_speed <= 50)) || scroll_speed=50
    update_scroll_speed
}
