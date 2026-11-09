#!/usr/bin/env python3
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import socket
import struct
import subprocess
import tempfile
import termios
import time
import unittest
import wave

ROOT = Path(__file__).resolve().parent.parent


def bash(code, *args):
    return subprocess.run(['bash', '-c', code, 'test', *map(str, args)], cwd=ROOT,
                          capture_output=True, text=True)


def terminal_screen(output, rows=28, cols=90):
    """Model the cursor/erase operations used by the renderer, including stale cells."""
    import re
    screen = [[' '] * cols for _ in range(rows)]
    y = x = 0
    position = 0
    ansi = re.compile(r'\x1b\[([0-9;?]*)([A-Za-z])')
    while position < len(output):
        match = ansi.match(output, position)
        if match:
            value, command = match.groups()
            if command == 'H':
                parts = (value or '1;1').split(';')
                y = int(parts[0] or 1) - 1
                x = int(parts[1] or 1) - 1 if len(parts) > 1 else 0
            elif command == 'K':
                start = 0 if value == '2' else x
                screen[y][start:] = [' '] * (cols - start)
            elif command == 'J':
                if value == '2': screen = [[' '] * cols for _ in range(rows)]
                else:
                    screen[y][x:] = [' '] * (cols - x)
                    for row in range(y + 1, rows): screen[row] = [' '] * cols
            position = match.end()
            continue
        char = output[position]
        if char == '\n': y = min(y + 1, rows - 1); x = 0
        elif char == '\r': x = 0
        elif char >= ' ':
            if x < cols: screen[y][x] = char
            x += 1
        position += 1
    return [''.join(row).rstrip() for row in screen]


class GameTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.audio = Path(directory.name) / 'silence.wav'
        with wave.open(str(self.audio), 'wb') as audio:
            audio.setparams((1, 2, 8000, 0, 'NONE', 'not compressed'))
            audio.writeframes(b'\0\0' * (8 * 8000))

    def test_audio_position_spikes_do_not_skip_taps_or_hold_tail(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            executable = directory / 'mpv'
            shutil.copy(ROOT / 'tests/fake_mpv.py', executable); executable.chmod(0o755)
            chart = directory / 'chart.csv'; chart.write_text('800,0,1300\n800,1\n1800,2\n')
            play_time = directory / 'play-time'
            env = {'PATH':str(directory)+':'+os.environ['PATH'], 'TEST_MPV_PLAY_TIME':str(play_time),
                   'TEST_MPV_PTS_SPIKE_AT':'.65', 'TEST_MPV_PTS_SPIKE_FOR':'.25', 'TEST_MPV_PTS_SPIKE_SIZE':'.35'}
            def at(target):
                return lambda _age: (play_time.exists() and bool(play_time.read_text())
                                     and time.monotonic()-float(play_time.read_text()) >= target)
            actions = [(at(.8),b'df'),(at(1.3),b'd'),(at(1.8),b'j')]
            data = self.terminal(['bash','game.sh',str(chart),'--audio',str(self.audio)],actions,env)
            self.assertIn(b'Max combo: 3 / 3',data)
            self.assertIn(b'Miss: 0',data)

    def test_random_midi_play_entry(self):
        midi = ROOT / 'songs/saikoro - Far in the blue sky.mid'
        if not midi.exists(): self.skipTest('User MIDI is not present')
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            executable = directory / 'mpv'
            shutil.copy(ROOT / 'tests/fake_mpv.py', executable); executable.chmod(0o755)
            chart = directory / 'random.csv'
            data = self.terminal(['bash','random-play.sh',str(midi),'--seed','42','--holds','--output',str(chart)],[(.5,b'q')],
                                 {'PATH': str(directory) + ':' + os.environ['PATH']})
            self.assertIn(b'Seed: 42', data)
            self.assertIn(b'CHART stopped', data)
            self.assertIn('# random_seed=42', chart.read_text())
            self.assertIn('# hold_count=0', chart.read_text())
            self.assertEqual(len([line for line in chart.read_text().splitlines() if not line.startswith('#')]),95)

    def test_game_uses_terminal_height(self):
        for rows in (28,48):
            data = self.terminal(['bash','game.sh','--practice'],[(.15,b'q')],size=(rows,90))
            frame = data.split(b'\x1b[H')[1]
            self.assertEqual(sum(line.startswith(b'          |') for line in frame.splitlines()),rows-10)

    def test_sixty_fps_deadlines(self):
        result = bash('''source ./game.sh
next_frame=0; count=0
for ((stamp=0; stamp<1000; stamp++)); do
    if ((stamp >= next_frame)); then ((count+=1)); advance_frame_deadline "$stamp" 60; fi
done
[[ $count == 60 && $next_frame == 1000 ]] || exit 1
next_frame=0
advance_frame_deadline 4 60; [[ $next_frame == 17 ]] || exit 2
advance_frame_deadline 40 60; [[ $next_frame == 50 ]] || exit 3
advance_frame_deadline 140 60; [[ $next_frame == 150 ]] || exit 4
''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_tall_game_field_and_judgment_position(self):
        for height in (16, 36, 60):
            result = bash('''source ./game.sh
note_times=(1000); note_lanes=(0); note_states=(pending); total=1 end_ms=2200
elapsed=1030 score=0 combo=0 max_combo=0 feedback='' feedback_until=0
playfield_rows=$1
render
''', height)
            self.assertEqual(result.returncode, 0, result.stderr)
            screen = terminal_screen(result.stdout, rows=height + 12)
            self.assertIn('[===]', screen[height + 5])
            self.assertEqual(result.stdout.count('\n'), height + 11)
            self.assertFalse(screen[-1])

    def test_fps_option_validation(self):
        for value in ('0','14','121','abc','60;exit'):
            result = subprocess.run(['bash','game.sh','--fps',value],cwd=ROOT,capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0)
            self.assertIn('FPS',result.stderr)

    def test_midi_bgm_game_loading(self):
        midi = ROOT / 'songs/saikoro - Far in the blue sky.mid'
        cache = ROOT / '.cache/midi'
        if not midi.exists() or not any(p.stat().st_size > 44 for p in cache.glob('*.wav')):
            self.skipTest('Rendered user MIDI is not present')
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            executable = directory / 'mpv'
            shutil.copy(ROOT / 'tests/fake_mpv.py', executable); executable.chmod(0o755)
            chart = directory / 'chart.csv'; chart.write_text('100,0\n')
            data = self.terminal(['bash','game.sh',str(chart),'--audio',str(midi)], [],
                                 {'PATH': str(directory) + ':' + os.environ['PATH']})
            self.assertIn(b'Miss: 1', data)
            self.assertNotIn(b'MIDI import error', data)

    def test_game_uses_audio_clock_instead_of_biased_progress(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            executable = directory / 'mpv'
            shutil.copy(ROOT / 'tests/fake_mpv.py', executable)
            executable.chmod(0o755)
            chart = directory / 'chart.csv'
            chart.write_text('800,0\n1300,1\n1800,2\n2300,3\n')
            play_time = directory / 'play-time'
            env = {'PATH': str(directory) + ':' + os.environ['PATH'],
                   'TEST_MPV_POSITION_BIAS': '.3', 'TEST_MPV_PLAY_TIME': str(play_time)}
            def at(target):
                return lambda _age: (play_time.exists() and bool(play_time.read_text())
                                     and time.monotonic() - float(play_time.read_text()) >= target)
            actions = [(at(t), key) for t, key in [(0.8,b'd'),(1.3,b'f'),(1.8,b'j'),(2.3,b'k')]]
            data = self.terminal(['bash', 'game.sh', str(chart), '--audio', str(self.audio)], actions, env)
            self.assertIn(b'Miss: 0', data)
            self.assertIn(b'Max combo: 4 / 4', data)
            self.assertIn(b'Median hit error:', data)

    @unittest.skipUnless(shutil.which('mpv'), 'real mpv is not installed')
    def test_real_mpv_audio_clock(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            chart = directory / 'chart.csv'
            chart.write_text('1500,0\n2000,1\n2500,2\n3000,3\n3500,0\n4000,1\n4500,2\n5000,1\n5000,3\n5500,1\n6000,0\n')
            real_mpv = shutil.which('mpv')
            socket_file = directory / 'socket-path'
            wrapper = directory / 'mpv'
            wrapper.write_text('#!/usr/bin/env python3\nimport os,sys\n'
                               f'open({str(socket_file)!r},"w").write(next(x.split("=",1)[1] for x in sys.argv if x.startswith("--input-ipc-server=")))\n'
                               f'os.execv({real_mpv!r},[{real_mpv!r},"--ao=null"]+sys.argv[1:])\n')
            wrapper.chmod(0o755)
            env = {'PATH': str(directory) + ':' + os.environ['PATH']}
            conn = None
            stream = None
            request_id = 0

            def at(target):
                def due(_age):
                    nonlocal conn, stream, request_id
                    if stream is None:
                        if not socket_file.exists() or not socket_file.read_text(): return False
                        conn = socket.socket(socket.AF_UNIX)
                        try: conn.connect(socket_file.read_text())
                        except (FileNotFoundError, ConnectionRefusedError): conn.close(); return False
                        conn.settimeout(1)
                        stream = conn.makefile('rwb')
                    request_id += 1
                    stream.write((json.dumps({'command':['get_property','audio-pts'],'request_id':request_id})+'\n').encode())
                    stream.flush()
                    while True:
                        result = json.loads(stream.readline())
                        if result.get('request_id') == request_id:
                            value = result.get('data')
                            return isinstance(value,(int,float)) and value >= target
                return due

            actions = [(at(t), key) for t,key in [(1.5,b'd'),(2,b'f'),(2.5,b'j'),(3,b'k'),
                                                  (3.5,b'd'),(4,b'f'),(4.5,b'j'),(5,b'fk'),(5.5,b'f'),(5.6,b'q')]]
            try:
                data = self.terminal(['bash','game.sh',str(chart),'--audio',str(self.audio)],actions,env)
                self.assertIn(b'Miss: 0',data)
                self.assertIn(b'Max combo: 10 / 11',data)
            finally:
                if stream is not None: stream.close()
                if conn is not None: conn.close()

    def test_game_note_visible_at_judgment_line(self):
        result = bash('''source ./game.sh
note_times=(1000); note_lanes=(0); note_states=(pending); total=1 end_ms=2200
elapsed=1030 score=0 combo=0 max_combo=0 feedback='' feedback_until=0
render
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('[===]', terminal_screen(result.stdout)[21])

    def test_game_hits_do_not_wait_for_slow_audio(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            executable = directory / 'mpv'
            shutil.copy(ROOT / 'tests/fake_mpv.py', executable)
            executable.chmod(0o755)
            chart = directory / 'chart.csv'
            chart.write_text('800,0\n800,1\n')
            play_time = directory / 'play-time'
            env = {'PATH': str(directory) + ':' + os.environ['PATH'],
                   'TEST_MPV_DELAY': '.22', 'TEST_MPV_PLAY_TIME': str(play_time)}

            def at_note(_age):
                return (play_time.exists() and bool(play_time.read_text())
                        and time.monotonic() - float(play_time.read_text()) >= .8)

            data = self.terminal(['bash', 'game.sh', str(chart), '--audio', str(self.audio)],
                                 [(at_note, b'df')], env)
            self.assertIn(b'Miss: 0', data)
            self.assertIn(b'Max combo: 2 / 2', data)

    def test_audio_reply_can_arrive_in_fragments(self):
        result = bash('''source ./game.sh
clock_ms
stamp=$now_ms
exec {audio_out}< <(printf 'OK 12'; sleep .05; printf '3 0 %s' "$stamp"; sleep .05; printf '\\n')
sync_pending=1 sync_requested_ms=$now_ms runtime=0 next_sync=10000 audio_eof=0
sync_response_buffer=''
game_clock_init 0 "$stamp" "$stamp"
for ((attempt=0; attempt<100 && sync_pending; attempt++)); do
    clock_ms
    poll_game_audio || exit 1
    sleep .005
done
[[ $sync_pending == 0 && $audio_ms == 123 && $audio_sample_ms == "$stamp" && -z $sync_response_buffer ]]
''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_frame_deadlines_do_not_drift_or_burst(self):
        result = bash('''source ./game.sh
next_frame=0
advance_frame_deadline 4; [[ $next_frame == 33 ]] || exit 1
advance_frame_deadline 40; [[ $next_frame == 66 ]] || exit 2
advance_frame_deadline 140; [[ $next_frame == 165 ]] || exit 3
advance_frame_deadline 145; [[ $next_frame == 165 ]] || exit 4
''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_editor_only_converts_visible_notes(self):
        result = bash('''source ./editor.sh
chart_bpm=120 chart_offset=0; tempo_beats=(0); tempo_bpms=(120); build_timing
note_times=(); note_lanes=()
for ((n=0; n<10000; n++)); do note_times+=( "$((n * 100))" ); note_lanes+=( "$((n % 4))" ); done
total=10000 cursor=500000 step=125 lane=0 dirty=0 status=Ready view_mode=beat
eval "$(declare -f ms_to_beat | sed '1s/ms_to_beat/original_ms_to_beat/')"
conversions=0
ms_to_beat() { ((conversions+=1)); original_ms_to_beat "$1"; }
render_editor >/dev/null
((conversions < 120 && conversions > 50))
''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_editor_idle_does_not_redraw(self):
        with tempfile.TemporaryDirectory() as directory:
            data = self.terminal(['bash', 'editor.sh', str(Path(directory) / 'new.csv')], [(.35, b'q')])
            self.assertEqual(data.count(b'\x1b[H'), 1)

    def test_editor_return_to_start_erases_previous_rows(self):
        result = bash('''source ./editor.sh
chart_bpm=120; chart_offset=0; tempo_beats=(0); tempo_bpms=(120); build_timing
note_times=(0 500 1000); note_lanes=(0 1 2); total=3
step=125 lane=0 dirty=0 status=Ready
for view_mode in ms beat; do
    for cursor in 0 1500 0; do render_editor; done
done
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        frames = result.stdout.split('\x1b[H')[1:]
        for start in (0, 3):
            screen = terminal_screen(''.join('\x1b[H' + frame for frame in frames[start:start + 3]))
            self.assertTrue(all(not row for row in screen[3:11]), screen)
            self.assertEqual(sum('[===]' in row for row in screen), 3)

    def test_editor_arrow_navigation(self):
        with tempfile.TemporaryDirectory() as directory:
            chart = Path(directory) / 'arrows.csv'
            keys = (b'\x1b[B\x1b[Cf\x1b[A\x1b[Df'
                    b't\x1bOB\x1bOCf\x1b[1;2B\x1b[99~e')
            self.terminal(['bash', 'editor.sh', str(chart)], [(.15, keys), (.5, b'q')])
            self.assertEqual(chart.read_text(),
                             '# Four Keys chart v1\n# audio=\n# offset_ms=0\n# bpm=120\n'
                             '0,0\n125,1\n500,1\n')

    def test_variable_tempo_coordinates_and_save(self):
        with tempfile.TemporaryDirectory() as directory:
            chart = Path(directory) / 'tempo.csv'
            chart.write_text('# bpm=120\n# tempo=9,60\n# tempo=5,240\n2000,0\n2250,1\n3000,2\n')
            result = bash('''source ./editor.sh
load_chart "$1" || exit 1
[[ ${tempo_beats[*]} == '0 4 8' ]] || exit 2
for pair in '4000000 2000' '5000000 2250' '8000000 3000' '9000000 4000'; do
    read -r ticks ms <<< "$pair"
    beat_to_ms "$ticks"; [[ $mapped_ms == "$ms" ]] || exit 3
    ms_to_beat "$ms"; [[ $beat_ticks == "$ticks" ]] || exit 4
done
cursor=2000 lane=0 view_mode=beat step=1 dirty=0
shift_time -1; [[ $target_time == 1500 ]] || exit 5
shift_time 1; [[ $target_time == 2250 ]] || exit 6
edit_current_bpm 120 || exit 7
[[ ${note_times[*]} == '2000 2500 4000' ]] || exit 8
cursor=2500 lane=1; edit_note later
[[ $cursor == 3000 ]] || exit 9
save_chart || exit 10
load_chart "$1" || exit 11
[[ ${tempo_bpms[*]} == '120 120 60' && ${note_times[*]} == '2000 3000 4000' ]] || exit 12
cursor=2000; edit_current_bpm remove || exit 13
[[ ${tempo_beats[*]} == '0 8' ]] || exit 14
cursor=0; edit_current_bpm 60 || exit 15
[[ ${note_times[*]} == '4000 6000 8000' ]] || exit 16
''', chart)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_tempo_validation_rounding_and_collision_rollback(self):
        with tempfile.TemporaryDirectory() as directory:
            chart = Path(directory) / 'tempo.csv'
            for invalid in ['# tempo=1,120', '# tempo=2,0', '# tempo=2,500',
                            '# tempo=-1,120', '# tempo=2.5,120', '# tempo=2,120\n# tempo=2,180']:
                chart.write_text(invalid + '\n')
                self.assertNotEqual(bash('source ./game.sh; load_chart "$1"', chart).returncode, 0)
            chart.write_text('# bpm=180\n# tempo=4,137\n0,0\n1,0\n667,1\n')
            result = bash('''source ./editor.sh
load_chart "$1" || exit 1
ms_to_beat 667; [[ $beat_ticks == 2000000 ]] || exit 2
ms_to_beat 1; ((beat_ticks > 0)) || exit 3
for ticks in 3000000 4000000 100000000 1000000000; do
    beat_to_ms "$ticks"; ms=$mapped_ms
    ms_to_beat "$ms"; [[ $beat_ticks == "$ticks" ]] || exit 4
done
cursor=0; dirty=0
if edit_current_bpm 400; then exit 5; fi
[[ $chart_bpm == 180 && ${note_times[*]} == '0 1 667' && $dirty == 0 ]] || exit 6
''', chart)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_editor_beat_keyboard_and_bpm_prompt(self):
        with tempfile.TemporaryDirectory() as directory:
            chart = Path(directory) / 'new.csv'
            data = self.terminal(['bash', 'editor.sh', str(chart)],
                                 [(.15, b'tsfsc180\n'), (.45, b'fe'), (.7, b'q')])
            self.assertIn(b'BEAT', data)
            self.assertIn(b'Step: 1 beat', data)
            self.assertIn('# tempo=3,180', chart.read_text())
            self.assertIn('500,0\n', chart.read_text())
            self.assertIn('1000,0\n', chart.read_text())

    def test_chart_validation_and_sort(self):
        with tempfile.TemporaryDirectory() as directory:
            chart = Path(directory) / 'chart.csv'
            chart.write_text('# bpm=0120\n# offset_ms=-0010\n200,3\n100,0\n100,0\n')
            result = bash('source ./game.sh; load_chart "$1" || exit; '
                          '[[ $total == 2 && ${note_times[0]} == 100 && $chart_offset == -10 && $chart_bpm == 120 ]]', chart)
            self.assertEqual(result.returncode, 0, result.stderr)
            for invalid in ['-1,0', '100,4', '1,0,extra', '$(touch HACK),0', '# bpm=0', '# offset_ms=oops']:
                chart.write_text(invalid + '\n')
                result = bash('source ./game.sh; load_chart "$1"', chart)
                self.assertNotEqual(result.returncode, 0, invalid)

    def test_edit_roundtrip_and_collision(self):
        with tempfile.TemporaryDirectory() as directory:
            chart = Path(directory) / 'chart.csv'
            chart.write_text('# audio=music.wav\n1000,0\n1125,0\n')
            result = bash('''source ./editor.sh
load_chart "$1" || exit 1
cursor=1000 lane=0 step=125 dirty=0
edit_note later
[[ $cursor == 1000 && $total == 2 ]] || exit 2
edit_note right
[[ $lane == 1 ]] || exit 3
edit_note later
[[ $cursor == 1125 ]] || exit 4
edit_note delete
[[ $total == 1 ]] || exit 5
cursor=42 lane=3
edit_note add; edit_note add
[[ $total == 2 ]] || exit 6
save_chart || exit 7
load_chart "$1" || exit 8
[[ $total == 2 && ${note_times[0]} == 42 && ${note_lanes[0]} == 3 && $chart_audio == music.wav ]]
''', chart)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_judgment(self):
        result = bash('''source ./game.sh
for spec in '45 perfect 1000' '-45 perfect 1000' '46 great 700' '90 great 700' '91 good 300' '140 good 300'; do
read -r offset expected points <<< "$spec"
note_times=(1000); note_lanes=(0); note_states=(pending); total=1
score=0 combo=0 max_combo=0 perfect=0 great=0 good=0 miss=0
elapsed=$((1000 + offset)); hit_lane 0
[[ ${note_states[0]} == "$expected" && $score == "$points" ]] || exit 1
done
note_states=(pending); elapsed=859; hit_lane 0
[[ ${note_states[0]} == pending ]] || exit 2
elapsed=1141; expire_notes
[[ ${note_states[0]} == miss && $combo == 0 && $miss == 1 ]]
''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def terminal(self, command, actions, env=None, expected=0, size=(32,90)):
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', *size, 0, 0))
        before = termios.tcgetattr(slave)
        proc = subprocess.Popen(command, cwd=ROOT, stdin=slave, stdout=slave, stderr=slave,
                                env={**os.environ, 'TERM': 'xterm-256color', **(env or {})})
        data = b''
        start = time.monotonic()
        index = 0
        try:
            while proc.poll() is None:
                age = time.monotonic() - start
                when = actions[index][0] if index < len(actions) else None
                due = when(age) if callable(when) else when is not None and age >= when
                if due:
                    action = actions[index][1]
                    if isinstance(action, bytes): os.write(master, action)
                    else: proc.send_signal(action)
                    index += 1
                if select.select([master], [], [], .02)[0]: data += os.read(master, 65536)
                if age > 8: self.fail('terminal test timeout: ' + repr(data[-1000:]))
            while select.select([master], [], [], 0)[0]: data += os.read(master, 65536)
            self.assertEqual(proc.returncode, expected, data[-2000:].decode(errors='replace'))
            self.assertEqual(termios.tcgetattr(slave), before)
            return data
        finally:
            if proc.poll() is None: proc.kill(); proc.wait()
            os.close(master); os.close(slave)

    def test_editor_keyboard_save_and_dirty_quit(self):
        with tempfile.TemporaryDirectory() as directory:
            chart = Path(directory) / 'new.csv'
            data = self.terminal(['bash', 'editor.sh', str(chart)], [(.15, b'fslie'), (.4, b'q')])
            self.assertIn(b'Editor closed', data)
            self.assertIn('0,0\n', chart.read_text())
            original = chart.read_text()
            data = self.terminal(['bash', 'editor.sh', str(chart)], [(.15, b'nxq'), (.4, b'q')])
            self.assertIn(b'UNSAVED!', data)
            self.assertEqual(chart.read_text(), original)

    def test_practice_interrupt(self):
        self.terminal(['bash', 'game.sh', '--practice'], [(.15, signal.SIGINT)], expected=130)

    def test_silent_chart_completion(self):
        with tempfile.TemporaryDirectory() as directory:
            chart = Path(directory) / 'short.csv'
            chart.write_text('100,0\n')
            data = self.terminal(['bash', 'game.sh', str(chart), '--silent'], [])
            self.assertIn(b'Miss: 1', data)

    def test_music_and_preview_ipc_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            executable = directory / 'mpv'
            shutil.copy(ROOT / 'tests/fake_mpv.py', executable)
            executable.chmod(0o755)
            chart = directory / 'chart.csv'
            chart.write_text('100,0\n')
            pidfile = directory / 'pid'
            env = {'PATH': str(directory) + ':' + os.environ['PATH'], 'TEST_MPV_PID': str(pidfile), 'TEST_MPV_DURATION': '.25'}
            audio = self.audio
            data = self.terminal(['bash', 'game.sh', str(chart), '--audio', str(audio)], [], env)
            self.assertIn(b'Miss: 1', data)
            with self.assertRaises(ProcessLookupError): os.kill(int(pidfile.read_text()), 0)
            del env['TEST_MPV_DURATION']
            data = self.terminal(['bash', 'editor.sh', str(chart), '--audio', str(audio)],
                                 [(.2, b' '), (.5, b' '), (.7, b'eq')], env)
            self.assertIn(b'Preview paused', data)
            with self.assertRaises(ProcessLookupError): os.kill(int(pidfile.read_text()), 0)

    def test_audio_outro_finishes_after_the_last_chart_note(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            executable = directory / 'mpv'
            shutil.copy(ROOT / 'tests/fake_mpv.py', executable)
            executable.chmod(0o755)
            chart = directory / 'chart.csv'
            chart.write_text('100,0\n')
            play_time = directory / 'play-time'
            env = {'PATH': str(directory) + ':' + os.environ['PATH'],
                   'TEST_MPV_DURATION': '2.4', 'TEST_MPV_PLAY_TIME': str(play_time)}
            data = self.terminal(['bash', 'game.sh', str(chart), '--audio', str(self.audio)], [], env)
            self.assertGreaterEqual(time.monotonic() - float(play_time.read_text()), 2.4)
            self.assertIn(b'CHART complete', data)
            self.assertIn(b'Miss: 1', data)

    def test_audio_duration_respects_offset_and_never_truncates_chart(self):
        result = bash('''source ./game.sh
for chart_offset in -200 0 300; do
    end_ms=1300
    extend_playback_end 0
    [[ $end_ms == 1300 ]] || exit 3
    extend_playback_end 2400
    [[ $end_ms == $((2400 - chart_offset)) ]] || exit 1
    end_ms=5000
    extend_playback_end 2400
    [[ $end_ms == 5000 ]] || exit 2
done
''')
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
