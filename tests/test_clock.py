#!/usr/bin/env python3
import unittest
from test_game import bash


class ClockTests(unittest.TestCase):
    def check(self, code):
        result = bash('source ./game.sh\nchart_offset=0\n' + code)
        self.assertEqual(result.returncode,0,result.stderr)

    def test_jitter_and_spikes_cannot_teleport_notes(self):
        self.check('''game_clock_init 0 0 0
jitter=(0 12 -15 20 -8 3); previous=0
for ((stamp=5;stamp<=5000;stamp+=5)); do
    game_clock_step "$stamp"
    delta=$((game_clock_audio_us - previous))
    ((delta >= 4750 && delta <= 5250)) || exit 1
    previous=$game_clock_audio_us
    if ((stamp % 50 == 0)); then
        sample=$((stamp + jitter[stamp / 50 % 6]))
        ((stamp == 1000)) && ((sample+=350))
        before=$game_clock_audio_us
        game_clock_sample "$sample" "$stamp" "$stamp"
        [[ $game_clock_audio_us == "$before" ]] || exit 2
    fi
    error=$((game_clock_audio_us - stamp * 1000)); error=${error#-}
    ((error < 25000)) || exit 3
done
''')

    def test_persistent_drift_is_corrected_gradually(self):
        self.check('''game_clock_init 0 0 0
for ((stamp=10;stamp<=5000;stamp+=10)); do
    game_clock_step "$stamp"
    if ((stamp % 50 == 0)); then game_clock_sample "$((stamp + 60))" "$stamp" "$stamp"; fi
done
error=$((game_clock_audio_us - 5060000)); error=${error#-}
((error <= 4000)) || exit 1
''')

    def test_delayed_duplicate_and_future_samples(self):
        self.check('''game_clock_init 0 0 0
game_clock_step 400
game_clock_sample 100 100 400
[[ $game_clock_audio_us == 400000 && $game_clock_error_us == 0 ]] || exit 1
game_clock_sample 900 100 400
[[ $game_clock_audio_us == 400000 && $game_clock_error_us == 0 ]] || exit 2
game_clock_sample 900 500 400
[[ $game_clock_audio_us == 400000 && $game_clock_error_us == 0 ]] || exit 3
game_clock_step 1000
game_clock_sample 100 200 1000
[[ $game_clock_audio_us == 1000000 && $game_clock_error_us == 0 ]] || exit 4
game_clock_step 900
[[ $game_clock_audio_us == 1000000 ]] || exit 5
''')


if __name__ == '__main__': unittest.main(verbosity=2)
