#!/usr/bin/env bash
# One continuous media clock for both input judgment and rendering. All phase
# corrections are gradual (at most +/-5% speed), never hard position changes.
game_clock_init() {
    local media_ms=$1 sampled_ms=$2 local_ms=$3
    game_clock_local=$local_ms
    game_clock_audio_us=$((media_ms * 1000 + (local_ms - sampled_ms) * 1000))
    game_clock_error_us=0 game_clock_last_sample=$sampled_ms
    game_clock_candidate_us=0 game_clock_candidate_count=0
}

game_clock_step() {
    local stamp=$1 dt correction limit
    dt=$((stamp - game_clock_local))
    if ((dt > 0)); then
        limit=$((dt * 50))
        correction=$game_clock_error_us
        ((correction > limit)) && correction=$limit
        ((correction < -limit)) && correction=$((-limit))
        game_clock_audio_us=$((game_clock_audio_us + dt * 1000 + correction))
        game_clock_error_us=$((game_clock_error_us - correction))
        game_clock_local=$stamp
    fi
    elapsed=$((game_clock_audio_us / 1000 - ${chart_offset:-0}))
}

game_clock_sample() {
    local media_ms=$1 sampled_ms=$2 local_ms=$3 error magnitude difference
    # Ignore duplicate, future and overly delayed samples. Keep running while
    # the asynchronous IPC response is in flight.
    ((sampled_ms > game_clock_last_sample && sampled_ms <= local_ms && local_ms - sampled_ms <= 500)) || return 0
    game_clock_step "$local_ms"
    game_clock_last_sample=$sampled_ms
    error=$((media_ms * 1000 + (local_ms - sampled_ms) * 1000 - game_clock_audio_us))
    magnitude=${error#-}
    if ((magnitude > 80000)); then
        difference=$((error - game_clock_candidate_us)); difference=${difference#-}
        if ((game_clock_candidate_count > 0 && difference <= 30000)); then
            ((game_clock_candidate_count+=1))
        else game_clock_candidate_count=1; fi
        game_clock_candidate_us=$error
        ((game_clock_candidate_count >= 2)) || return 0
    else game_clock_candidate_count=0; fi
    if ((magnitude <= 3000)); then game_clock_error_us=0
    else game_clock_error_us=$(((game_clock_error_us + error) / 2)); fi
    return 0
}
