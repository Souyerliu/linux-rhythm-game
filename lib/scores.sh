#!/usr/bin/env bash

# Capture the MIDI path before audio rendering replaces it with a cached WAV.
prepare_score_context() {
    score_midi='' score_grid='' best_score='-'
    local source=$1 color
    [[ ${source,,} == *.mid || ${source,,} == *.midi ]] || return 0
    [[ -f $source ]] || return 0
    score_grid=${chart_grid:-}
    if [[ -z $score_grid ]]; then
        # Legacy charts have no grid header. Infer their finest onset position.
        score_grid=1
        for color in "${note_colors[@]}"; do
            case $color in
                97) ;;
                96) [[ $score_grid == 1 ]] && score_grid=1/2 ;;
                93) score_grid=1/4 ;;
                *) score_grid=''; return 0 ;;
            esac
        done
    fi
    case $score_grid in 1|1/2|1/4) ;; *) score_grid=''; return 0 ;; esac
    score_midi=$source
    best_score=$(python3 "$GAME_ROOT/tools/highscores.py" get "$score_midi" "$score_grid") || best_score='-'
}

record_high_score() {
    [[ -n ${score_midi:-} && -n ${score_grid:-} ]] || return 0
    python3 "$GAME_ROOT/tools/highscores.py" record "$score_midi" "$score_grid" \
        --score "$score" --combo "$max_combo" --total "$total"
}
