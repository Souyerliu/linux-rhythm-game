#!/usr/bin/env python3
from pathlib import Path
import tempfile
import unittest
import test_game
from test_game import bash, terminal_screen


class HoldTests(unittest.TestCase):
    def test_quarter_grid_movement_and_tail_across_tempo(self):
        self.chart('# bpm=148\n# tempo=5,240\n0,0\n', '''
cursor=0 lane=0 step=1 view_mode=beat dirty=0 beat_grid_index=2 beat_step_ticks=1000000
cycle_beat_grid -1; [[ $beat_step_ticks == 500000 ]] || exit 1
cycle_beat_grid -1; [[ $beat_step_ticks == 250000 ]] || exit 2
for ((j=1;j<=20;j++)); do
    shift_time 1; cursor=$target_time
    beat_to_ms "$((j * 250000))"; [[ $cursor == "$mapped_ms" ]] || exit 3
done
for ((j=19;j>=0;j--)); do
    shift_time -1; cursor=$target_time
    beat_to_ms "$((j * 250000))"; [[ $cursor == "$mapped_ms" ]] || exit 4
done
edit_note hold
beat_to_ms 1000000; [[ ${note_ends[0]} == "$mapped_ms" ]] || exit 5
edit_note longer
beat_to_ms 1250000; [[ ${note_ends[0]} == "$mapped_ms" ]] || exit 6
edit_note later
beat_to_ms 250000; [[ $cursor == "$mapped_ms" ]] || exit 7
beat_to_ms 1500000; [[ ${note_ends[0]} == "$mapped_ms" ]] || exit 8
''')

    def test_quarter_grid_editor_keyboard(self):
        with tempfile.TemporaryDirectory() as directory:
            chart = Path(directory) / 'chart.csv'
            data = test_game.GameTests().terminal(['bash','editor.sh',str(chart)],[(.15,b't[[sfvfke'),(.4,b'q')])
            self.assertIn(b'Step: 1/4 beat',data)
            self.assertIn('125,0,750',chart.read_text())

    def chart(self, text, code):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'chart.csv'
            path.write_text(text)
            result = bash('source ./editor.sh\nload_chart "$1" || exit 99\n' + code, path)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout

    def test_colors_with_tempo_changes_and_rounding(self):
        self.chart('# bpm=120\n# tempo=5,240\n1000,0\n1125,0\n1166,0\n1250,0\n2063,0\n2125,0\n2250,0\n', '''
[[ ${note_colors[*]} == '97 93 95 96 93 96 97' ]] || exit 1
''')

    def test_format_roundtrip_and_latest_tail(self):
        self.chart('1000,0,3000\n1500,1\n2000,2,5000\n3500,0\n', '''
[[ $end_ms == 6200 && ${note_ends[*]} == '3000 1500 5000 3500' ]] || exit 1
save_chart || exit 2
load_chart "$1" || exit 3
[[ $total == 4 && ${note_ends[*]} == '3000 1500 5000 3500' ]] || exit 4
''')

    def test_invalid_holds_and_same_lane_overlaps(self):
        for text in ('1000,0,1000', '1000,0,999', '1000,0,1000000000',
                     '1000,0,3000\n2000,0', '1000,0,3000\n3000,0', '1000,0,2000\n1000,0,2500'):
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'chart.csv'; path.write_text(text+'\n')
                result = bash('source ./game.sh; load_chart "$1"', path)
                self.assertNotEqual(result.returncode, 0, text)

    def test_head_tail_and_miss_count(self):
        self.chart('1000,0,2000\n2500,1\n', '''
score=0 combo=0 max_combo=0 perfect=0 great=0 good=0 miss=0
elapsed=1000; hit_lane 0
[[ ${note_states[0]} == holding && $score == 0 ]] || exit 1
elapsed=1500; hit_lane 0
[[ ${note_states[0]} == holding ]] || exit 2
elapsed=2000; hit_lane 0
[[ ${note_states[0]} == perfect && $score == 1000 && $combo == 1 ]] || exit 3
elapsed=4000; expire_notes
[[ $miss == 1 && $perfect == 1 ]] || exit 4
load_chart "$1"; score=0 combo=0 perfect=0 miss=0
elapsed=1000; hit_lane 0
elapsed=2141; expire_notes
elapsed=2200; expire_notes
[[ $miss == 1 && ${note_states[0]} == miss && $score == 0 ]] || exit 5
load_chart "$1"; miss=0
elapsed=1141; expire_notes
elapsed=2000; hit_lane 0; expire_notes
[[ $miss == 1 && ${note_states[0]} == miss ]] || exit 6
''')

    def test_hold_edits_tempo_retime_and_overlap_rollback(self):
        self.chart('# bpm=120\n# tempo=5,240\n1000,0\n', '''
cursor=1000 lane=0 step=125 view_mode=beat dirty=0
edit_note hold; [[ ${note_ends[0]} == 1500 ]] || exit 1
edit_note longer; edit_note longer
[[ ${note_ends[0]} == 2250 ]] || exit 2
edit_note later
[[ $cursor == 1500 && ${note_ends[0]} == 2500 ]] || exit 3
edit_current_bpm 60 || exit 4
[[ $cursor == 1500 && ${note_ends[0]} == 3000 ]] || exit 5
save_chart; load_chart "$1"
[[ ${note_ends[0]} == 3000 ]] || exit 6
cursor=1500; edit_note hold
[[ ${note_ends[0]} == 1500 ]] || exit 7
''')
        self.chart('1000,0\n1250,0\n', '''
cursor=1000 lane=0 step=125 view_mode=ms dirty=0
edit_note hold
[[ ${note_ends[*]} == '1000 1250' && $dirty == 0 ]] || exit 1
''')

    def test_hold_body_visible_after_head_leaves_view(self):
        output = self.chart('1000,0,5000\n', '''
score=0 combo=0 max_combo=0 perfect=0 great=0 good=0 miss=0 feedback='' feedback_until=0
elapsed=1000; hit_lane 0
elapsed=2500; render
''')
        screen = terminal_screen(output)
        self.assertIn('[HLD]', screen[21])
        self.assertTrue(all('  |  ' in row for row in screen[5:21]))

    def test_editor_does_not_draw_tails_before_viewport(self):
        output = self.chart('0,0,5000\n1000,1,2400\n', '''
cursor=3500 lane=0 step=125 view_mode=ms dirty=0 status=Ready
render_editor
''')
        self.assertNotIn('[---]', output)

    def test_editor_keyboard_creates_hold_and_game_completes(self):
        runner = test_game.GameTests()
        with tempfile.TemporaryDirectory() as directory:
            chart = Path(directory) / 'chart.csv'
            runner.terminal(['bash','editor.sh',str(chart)],[(.15,b'sfvke'),(.4,b'q')])
            self.assertIn('125,0,750',chart.read_text())
            chart.write_text('# bpm=120\n200,0,600\n')
            data = runner.terminal(['bash','game.sh',str(chart),'--silent'],[(.2,b'd'),(.6,b'd')])
            self.assertIn(b'Max combo: 1 / 1',data)
            self.assertIn(b'Miss: 0',data)


if __name__ == '__main__': unittest.main(verbosity=2)
