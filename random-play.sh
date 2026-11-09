#!/usr/bin/env bash
# Keep the original terminal and signal handling for the game subprocess.
GAME_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec bash "$GAME_ROOT/tools/random_midi.sh" "$@"
