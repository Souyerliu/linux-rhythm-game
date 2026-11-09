#!/usr/bin/env python3
"""Local best scores, keyed by MIDI content and the chart's minimum grid."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('get', 'record'))
    parser.add_argument('midi', type=Path)
    parser.add_argument('grid', choices=('1', '1/2', '1/4'))
    parser.add_argument('--score', type=int, default=0)
    parser.add_argument('--combo', type=int, default=0)
    parser.add_argument('--total', type=int, default=0)
    args = parser.parse_args()
    digest = hashlib.sha256(args.midi.read_bytes()).hexdigest()
    directory = Path(os.environ.get('RHYTHM_SCORE_DIR', Path(__file__).resolve().parent.parent / '.local' / 'scores'))
    path = directory / f'{digest}-grid{args.grid.replace("/", "of")}.json'

    def read():
        try:
            data = json.loads(path.read_text())
        except FileNotFoundError:
            return None
        if (not isinstance(data, dict) or data.get('midi_sha256') != digest
                or data.get('grid') != args.grid or type(data.get('score')) is not int
                or data['score'] < 0):
            raise ValueError(f'Invalid score record: {path}')
        return data

    if args.action == 'get':
        best = read()
        print(best['score'] if best else '-')
        return
    if not (0 <= args.score <= args.total * 1000 and 0 <= args.combo <= args.total):
        raise ValueError('Invalid score, combo or note count')
    directory.mkdir(parents=True, exist_ok=True)
    # Serialize competing sessions; publish only complete JSON files.
    with (directory / '.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        best = read()
        improved = best is None or args.score > best['score']
        if improved:
            best = {'midi_sha256': digest, 'grid': args.grid, 'score': args.score,
                    'max_combo': args.combo, 'total': args.total,
                    'song': args.midi.name}
            temporary = None
            try:
                with tempfile.NamedTemporaryFile(mode='w', dir=directory, delete=False) as output:
                    temporary = output.name
                    json.dump(best, output, ensure_ascii=False)
                    output.write('\n')
                    output.flush()
                    os.fsync(output.fileno())
                os.replace(temporary, path)
            finally:
                if temporary and os.path.exists(temporary):
                    os.unlink(temporary)
        print(f'High score (grid {args.grid}): {best["score"]}' + ('  NEW BEST!' if improved else ''))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError) as error:
        print(f'High score unavailable: {error}', file=sys.stderr)
        sys.exit(1)
