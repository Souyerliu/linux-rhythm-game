#!/usr/bin/env python3
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

import test_game
from test_midi import fixture

ROOT = Path(__file__).resolve().parent.parent


class ScoreTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)
        self.midi = self.directory / 'song with spaces.mid'
        self.midi.write_bytes(fixture())
        self.records = self.directory / 'scores'
        self.env = {**os.environ, 'RHYTHM_SCORE_DIR': str(self.records)}

    def score(self, action, grid='1/2', value=1000, midi=None):
        args = ['python3', 'tools/highscores.py', action, str(midi or self.midi), grid]
        if action == 'record': args += ['--score', str(value), '--combo', '1', '--total', '2']
        result = subprocess.run(args, cwd=ROOT, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def test_only_higher_scores_replace_record_and_grids_are_independent(self):
        self.assertEqual(self.score('get'), '-')
        self.assertIn('NEW BEST', self.score('record'))
        self.assertNotIn('NEW BEST', self.score('record', value=700))
        self.assertNotIn('NEW BEST', self.score('record', value=1000))
        self.assertEqual(self.score('get'), '1000')
        self.assertEqual(self.score('get', '1/4'), '-')
        self.score('record', '1/4', 1700)
        self.score('record', '1', 0)
        self.assertEqual(self.score('get', '1/4'), '1700')
        self.assertEqual(self.score('get', '1'), '0')

    def test_identity_survives_move_but_distinguishes_different_midi(self):
        self.score('record')
        renamed = self.directory / 'renamed.MIDI'
        self.midi.rename(renamed)
        self.assertEqual(self.score('get', midi=renamed), '1000')
        self.midi.write_bytes(fixture() + b'changed')
        self.assertEqual(self.score('get'), '-')

    def test_concurrent_sessions_keep_the_highest(self):
        processes = [subprocess.Popen(
            ['python3', 'tools/highscores.py', 'record', str(self.midi), '1/2',
             '--score', str(value), '--combo', '1', '--total', '2'],
            cwd=ROOT, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            for value in (300, 1800, 700, 1000, 0)]
        for process in processes:
            _, error = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0, error)
        self.assertEqual(self.score('get'), '1800')
        self.assertEqual(len(list(self.records.glob('*.json'))), 1)

    def test_invalid_record_is_reported_without_overwriting(self):
        self.score('record')
        path = next(self.records.glob('*.json'))
        path.write_text('broken')
        result = subprocess.run(['python3', 'tools/highscores.py', 'record', str(self.midi), '1/2'],
                                cwd=ROOT, env=self.env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('High score unavailable', result.stderr)
        self.assertEqual(path.read_text(), 'broken')

    def test_complete_game_records_and_aborted_game_does_not(self):
        chart = self.directory / 'chart.csv'
        chart.write_text(f'# audio={self.midi.name}\n# rhythm_grid=1/2\n200,0\n')
        terminal = test_game.GameTests().terminal
        data = terminal(['bash', 'game.sh', str(chart), '--silent'], [], self.env)
        self.assertIn(b'High score (grid 1/2): 0  NEW BEST!', data)
        self.assertEqual(self.score('get'), '0')
        self.score('record')
        # The other seed/hold variant shares the song+grid record.
        chart.write_text(f'# audio={self.midi.name}\n# rhythm_grid=1/2\n# random_seed=99\n200,0,600\n')
        data = terminal(['bash', 'game.sh', str(chart), '--silent'], [], self.env)
        self.assertIn(b'High score (grid 1/2): 1000', data)
        self.assertNotIn(b'NEW BEST', data)
        chart.write_text(f'# audio={self.midi.name}\n# rhythm_grid=1/4\n200,0\n')
        data = terminal(['bash', 'game.sh', str(chart), '--silent'], [(.15, b'q')], self.env)
        self.assertIn(b'CHART stopped', data)
        self.assertEqual(self.score('get', '1/4'), '-')

    def test_chart_grid_roundtrip_and_legacy_inference(self):
        chart = self.directory / 'chart.csv'
        for header, onset, expected in (('# rhythm_grid=1/4\n', 1000, '1/4'),
                                         ('', 1000, '1'), ('', 1250, '1/2'),
                                         ('', 1125, '1/4'), ('', 1166, '')):
            chart.write_text(f'# audio={self.midi.name}\n{header}{onset},0\n')
            result = test_game.bash('''source ./game.sh
export RHYTHM_SCORE_DIR="$4"
load_chart "$1" || exit 1
prepare_score_context "$audio_path"
[[ $score_grid == "$2" ]] || exit 2
save_chart || exit 3
load_chart "$1" || exit 4
[[ $chart_grid == "$3" ]]
''', chart, expected, '1/4' if header else '', self.records)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_menu_navigation_shows_scores_and_restores_terminal(self):
        self.score('record')
        (self.directory / 'second.MIDI').write_bytes(fixture() + b'second')
        data = test_game.GameTests().terminal(
            ['bash', 'game.sh', '--menu', '--songs', str(self.directory)],
            [(.2, b'\x1b[C'), (.3, b'h'), (.4, b'\x1b[B'), (.5, b'w'), (.6, b'q')], self.env)
        self.assertIn(b'SONG SELECT', data)
        self.assertIn(b'High score: 1000', data)
        self.assertIn(b'> Hard', data)
        self.assertIn(b'Holds: OFF', data)
        self.assertIn(b'Song 2 / 2', data)

    def test_menu_empty_library(self):
        empty = self.directory / 'empty'; empty.mkdir()
        data = test_game.GameTests().terminal(
            ['bash', 'menu.sh', '--songs', str(empty)], [], self.env)
        self.assertIn(b'No MIDI songs found', data)

    def test_default_menu_practice_and_return(self):
        data = test_game.GameTests().terminal(
            ['bash', 'game.sh'],
            [(.3, b'p'), (.6, b'q'), (.9, b' '), (1.3, b'q')], self.env)
        self.assertIn(b'PRACTICE stopped', data)
        self.assertGreaterEqual(data.count(b'SONG SELECT'), 2)

    def test_menu_play_complete_and_return_refreshes_best(self):
        # An isolated launcher keeps the generated chart out of the user's songs.
        app = self.directory / 'app'; app.mkdir()
        shutil.copy(ROOT / 'menu.sh', app / 'menu.sh')
        (app / 'lib').symlink_to(ROOT / 'lib', target_is_directory=True)
        (app / 'tools').symlink_to(ROOT / 'tools', target_is_directory=True)
        output = self.directory / 'generated.csv'
        (app / 'random-play.sh').write_text(
            'exec bash ' + shlex.quote(str(ROOT / 'random-play.sh'))
            + ' "$@" --output ' + shlex.quote(str(output)) + '\n')
        data = test_game.GameTests().terminal(
            ['bash', str(app / 'menu.sh'), '--songs', str(self.directory), '--silent', '--seed', '42'],
            [(.3, b'dh\n'), (4.6, b' '), (5.0, b'q')], self.env)
        self.assertIn(b'CHART complete', data[-10000:])
        self.assertIn(b'High score (grid 1/4): 0  NEW BEST!', data[-10000:])
        self.assertGreaterEqual(data.count(b'SONG SELECT'), 2)
        self.assertIn(b'High score: 0', data[-3000:])
        self.assertIn('# rhythm_grid=1/4', output.read_text())
        self.assertNotIn('# hold_count=', output.read_text())
        self.assertEqual(self.score('get', '1/4'), '0')


if __name__ == '__main__':
    unittest.main(verbosity=2)
