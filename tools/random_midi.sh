#!/usr/bin/env bash
GAME_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
exec bash "$GAME_ROOT/tools/midi_import.sh" --random "$@"
