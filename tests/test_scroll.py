import unittest
import test_game
from test_game import bash, terminal_screen


class ScrollTests(unittest.TestCase):
    def test_validation_and_limits(self):
        result = bash('''source ./lib/scroll.sh
set_scroll_speed 2; [[ $scroll_window_ms == 1000 && $scroll_label == 2.0 ]] || exit 1
set_scroll_speed 0.5; adjust_scroll_speed -1
[[ $scroll_label == 0.5 && $scroll_window_ms == 4000 ]] || exit 2
set_scroll_speed 5; adjust_scroll_speed 1
[[ $scroll_label == 5.0 && $scroll_window_ms == 400 ]] || exit 3
for bad in 0 0.4 5.1 6 -1 1.25 nan '1+1' ''; do
    if set_scroll_speed "$bad"; then exit 4; fi
done
''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_tap_and_hold_positions_and_judgment(self):
        for speed, head_row, tail_row in [('1', 17, 13), ('2', 13, 5)]:
            result = bash('''source ./game.sh
note_times=(1000 1000); note_lanes=(0 1); note_ends=(1000 1500)
chart_bpm=120; tempo_beats=(0); tempo_bpms=(120); build_timing; sort_notes
score=0 combo=0 max_combo=0 perfect=0 great=0 good=0 miss=0
feedback='' feedback_until=0 elapsed=500
set_scroll_speed "$1"; render
elapsed=1000; hit_lane 0; hit_lane 1
elapsed=1500; hit_lane 1
[[ $score == 2000 && $perfect == 2 ]] || exit 1
''', speed)
            self.assertEqual(result.returncode, 0, result.stderr)
            screen = terminal_screen(result.stdout)
            self.assertEqual(screen[head_row].count('[===]'), 2)
            self.assertIn('[---]', screen[tail_row])

    def test_gameplay_keeps_initial_speed(self):
        data = test_game.GameTests().terminal(
            ['bash', 'game.sh', '--practice', '--speed', '2'],
            [(.15, b'=+'), (.3, b'-_'), (.45, b'q')], size=(28, 56))
        self.assertIn(b'SPEED 2.0x', data)
        self.assertNotIn(b'SPEED 2.1x', data)
        self.assertNotIn(b'SPEED 2.2x', data)
        self.assertNotIn(b'SPEED 1.9x', data)
        self.assertNotIn(b'SPEED 1.8x', data)
        self.assertNotIn(b'-/+: speed', data)


if __name__ == '__main__':
    unittest.main()
