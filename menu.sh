#!/usr/bin/env bash
# Terminal song selector. Gameplay remains in its own process/terminal session.
GAME_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$GAME_ROOT/lib/terminal.sh"

menu_cleanup() {
    if [[ -n ${menu_stty:-} ]]; then
        stty "$menu_stty"
        printf '\e[0m\e[?25h\e[?1049l'
        menu_stty=''
    fi
}

menu_enter() {
    menu_stty=$(stty -g)
    stty -echo -icanon min 1 time 0 -ixon
    printf '\e[?1049h\e[?25l\e[2J'
}

menu_scores() {
    local grid value
    highs=()
    for grid in "${grids[@]}"; do
        value=$(python3 "$GAME_ROOT/tools/highscores.py" get "${songs[selected]}" "$grid" 2>/dev/null) || value='unavailable'
        highs+=( "$value" )
    done
}

menu_render() {
    local frame='' line i first=$((selected / page_size * page_size)) title marker
    printf -v frame '  FOUR KEYS - SONG SELECT\n\n  W/S or Up/Down: song    A/D or Left/Right: grid\n  H: holds    Enter: play    P: practice    Q: quit\n\n'
    for ((i=first; i<${#songs[@]} && i<first+page_size; i++)); do
        title=${songs[i]#"$song_dir/"}
        title=${title%.*}
        # Keep filenames from introducing terminal controls or wrapping rows.
        title=${title//[[:cntrl:]]/?}
        marker=' '; ((i == selected)) && marker='>'
        printf -v line '  %s %s\n' "$marker" "${title:0:width}"
        frame+=$line
    done
    printf -v line '\n  Song %d / %d\n\n' "$((selected + 1))" "${#songs[@]}"
    frame+=$line
    for ((i=0; i<3; i++)); do
        marker=' '; ((i == difficulty)) && marker='>'
        printf -v line '  %s %-6s  grid %-3s  High score: %s\n' "$marker" "${labels[i]}" "${grids[i]}" "${highs[i]}"
        frame+=$line
    done
    printf -v line '\n  Holds: %s\n  %s\n' "$([[ $holds == 1 ]] && printf ON || printf OFF)" "$status"
    frame+=$line
    present_frame "$frame"
}

main() {
    local song_dir=$GAME_ROOT/songs selected=0 difficulty=1 holds=1 key suffix status='Choose a song and difficulty.'
    local menu_stty='' dimensions rows cols page_size width result song
    local -a songs=() grids=(1 1/2 1/4) labels=(Easy Normal Hard) highs=() options=() practice_options=() command=()
    while (($#)); do
        case $1 in
            --songs) (($# >= 2)) || return 1; song_dir=$2; shift 2 ;;
            --silent) options+=( "$1" ); practice_options+=( "$1" ); shift ;;
            --fps|--offset|--seed)
                (($# >= 2)) || { printf 'Missing value for %s\n' "$1" >&2; return 1; }
                [[ $1 == --seed ]] || practice_options+=( "$1" "$2" )
                options+=( "$1" "$2" ); shift 2 ;;
            -h|--help)
                printf 'Usage: ./menu.sh [--songs DIR] [--silent] [--fps N] [--offset MS] [--seed N]\n'
                return 0 ;;
            *) printf 'Unknown menu option: %s\n' "$1" >&2; return 1 ;;
        esac
    done
    [[ -t 0 && -t 1 && ${TERM:-dumb} != dumb ]] || { printf 'Run the menu in an interactive ANSI terminal.\n' >&2; return 1; }
    command -v python3 >/dev/null || { printf 'Song selection and scores require python3.\n' >&2; return 1; }
    [[ -d $song_dir ]] || { printf 'Song directory not found: %s\n' "$song_dir" >&2; return 1; }
    song_dir=$(cd -- "$song_dir" && pwd)
    while IFS= read -r -d '' song; do
        [[ $song != *$'\n'* && $song != *$'\r'* ]] && songs+=( "$song" )
    done < <(find "$song_dir" -type f \( -iname '*.mid' -o -iname '*.midi' \) -print0 | LC_ALL=C sort -z)
    ((${#songs[@]})) || { printf 'No MIDI songs found in %s. Add .mid/.midi files and restart.\n' "$song_dir"; return 0; }
    dimensions=$(stty size); read -r rows cols <<< "$dimensions"
    ((rows >= 28 && cols >= 56)) || { printf 'Terminal too small: need at least 56 columns x 28 rows.\n' >&2; return 1; }
    page_size=$((rows - 17)); width=$(((cols - 6) / 2))
    trap menu_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    menu_enter
    menu_scores
    while :; do
        menu_render
        IFS= read -rsn1 key || break
        if [[ $key == $'\e' ]]; then
            suffix=''
            IFS= read -rsn2 -t 0.05 suffix || :
            case $suffix in '[A') key=w ;; '[B') key=s ;; '[C') key=d ;; '[D') key=a ;; *) continue ;; esac
        fi
        case $key in
            q|Q) break ;;
            w|W) selected=$(((selected + ${#songs[@]} - 1) % ${#songs[@]})); menu_scores ;;
            s|S) selected=$(((selected + 1) % ${#songs[@]})); menu_scores ;;
            a|A) difficulty=$(((difficulty + 2) % 3)) ;;
            d|D) difficulty=$(((difficulty + 1) % 3)) ;;
            h|H) holds=$((1 - holds)) ;;
            ''|p|P)
                menu_cleanup
                if [[ $key == p || $key == P ]]; then
                    command=(bash "$GAME_ROOT/game.sh" --practice "${practice_options[@]}")
                else
                    command=(bash "$GAME_ROOT/random-play.sh" "${songs[selected]}" --grid "${grids[difficulty]}" "${options[@]}")
                    ((!holds)) || command+=(--holds)
                fi
                "${command[@]}"; result=$?
                printf '\nPress any key to return to song selection.'
                IFS= read -rsn1 _
                menu_enter
                status='Choose a song and difficulty.'
                ((result == 0)) || status="Playback failed (exit $result). See output above."
                menu_scores ;;
        esac
    done
    menu_cleanup
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
