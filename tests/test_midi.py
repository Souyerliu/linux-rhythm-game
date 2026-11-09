#!/usr/bin/env python3
"""Exercise the Shell/awk importer through its public command line."""
import array
from collections import Counter
import json
import math
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest
import wave

ROOT = Path(__file__).resolve().parent.parent

def vlq(value):
    out = [value & 127]
    while value >> 7:
        value >>= 7; out.insert(0, (value & 127) | 128)
    return bytes(out)


def fixture():
    def chunk(data): return b'MTrk' + struct.pack('>I', len(data)) + data
    tempo = b'\x00\xff\x51\x03\x07\xa1\x20' + vlq(1920) + b'\xff\x51\x03\x03\xd0\x90\x00\xff\x2f\x00'
    notes = b'\x00\xff\x03\x04Lead' + vlq(1920) + b'\x90\x3c\x64' + vlq(480) + b'\x40\x64' + vlq(480) + b'\x43\x64\x00\xff\x2f\x00'
    return b'MThd' + struct.pack('>IHHH', 6, 1, 2, 480) + chunk(tempo) + chunk(notes)


def hold_fixture():
    def chunk(data): return b'MTrk' + struct.pack('>I', len(data)) + data
    tempo = b'\x00\xff\x51\x03\x07\xa1\x20' + vlq(1920) + b'\xff\x51\x03\x03\xd0\x90\x00\xff\x2f\x00'
    notes = b'\x00\xff\x03\x04Lead'
    for i in range(10):
        pitch = 60 + i % 4
        notes += vlq(1920 if i == 0 else 960) + bytes((0x90,pitch,100))
        notes += vlq(960) + bytes((0x80 if i % 2 == 0 else 0x90,pitch,0))
    notes += b'\x00\xff\x2f\x00'
    return b'MThd' + struct.pack('>IHHH',6,1,2,480) + chunk(tempo) + chunk(notes)


def grid_fixture():
    track = b'\x00\xff\x51\x03\x07\xa1\x20'
    for i in range(16):
        pitch = 60+i%4
        track += vlq(1920 if i==0 else 60)+bytes((0x90,pitch,100))
        track += vlq(60)+bytes((0x80,pitch,0))
    track += b'\x00\xff\x2f\x00'
    return b'MThd'+struct.pack('>IHHH',6,0,1,480)+b'MTrk'+struct.pack('>I',len(track))+track


def sparse_piano_fixture():
    def chunk(name, beats):
        events = []
        for beat in beats:
            tick = round(beat * 480)
            events += [(tick, b'\x90\x3c\x64'), (tick + 60, b'\x80\x3c\x00')]
        data = b'\x00\xff\x03' + vlq(len(name)) + name
        previous = 0
        for tick, event in sorted(events):
            data += vlq(tick - previous) + event
            previous = tick
        data += vlq(40 * 480 - previous) + b'\xff\x2f\x00'
        return b'MTrk' + struct.pack('>I', len(data)) + data
    return (b'MThd' + struct.pack('>IHHH', 6, 1, 2, 480)
            + chunk(b'Lead', [4, 16, 28])
            + chunk(b'Piano', list(range(4, 39)) + [4.5, 12.5, 30.5]))


class MidiTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)
        self.source = self.directory / 'music with spaces.mid'
        self.source.write_bytes(fixture())

    def run_import(self, *args, random=False, root=ROOT, env=None):
        script = root / ('random-play.sh' if random else 'tools/midi_import.sh')
        return subprocess.run(['bash', str(script), str(self.source), *map(str, args)],
                              capture_output=True, text=True, env=env, cwd=ROOT)

    def chart(self, *args, random=False, root=ROOT):
        output = self.directory / 'chart.csv'
        output.unlink(missing_ok=True)
        result = self.run_import('--output', output, *args, random=random, root=root)
        self.assertEqual(result.returncode, 0, result.stderr)
        notes = [tuple(map(int, line.split(','))) for line in output.read_text().splitlines()
                 if line and not line.startswith('#')]
        loaded = subprocess.run(['bash', '-c', 'source ./game.sh; load_chart "$1"',
                                 'test', str(output)], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(loaded.returncode, 0, loaded.stderr)
        return output.read_text(), notes

    def test_running_status_tempo_and_analysis(self):
        result = self.run_import('--analyze')
        self.assertEqual(result.returncode, 0, result.stderr)
        info = json.loads(result.stdout)
        self.assertEqual(info['division'], 480)
        self.assertEqual(info['duration_ms'], 2500)
        self.assertEqual(info['tempos'], [[0, 120], [4, 240]])
        self.assertEqual(info['tracks'][1]['name'], 'Lead')
        self.assertEqual(info['tracks'][1]['notes'], 3)
        self.assertEqual(info['tracks'][1]['channels'], {'0': 3})
        text, notes = self.chart('--track', '1')
        self.assertEqual(notes, [(2000, 0), (2500, 2)])
        self.assertIn('# tempo=5,240', text)
        self.assertIn('# audio=music with spaces.mid', text)

    def test_json_track_names(self):
        self.source.write_bytes(fixture().replace(b'\x04Lead', b'\x04L"\\\n'))
        result = self.run_import('--analyze')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['tracks'][1]['name'], 'L"\\\n')

    def test_grids_and_offbeats(self):
        for offbeat in (False, True):
            content = grid_fixture()
            if offbeat: content = content.replace(vlq(1920), vlq(2040), 1)
            self.source.write_bytes(content)
            for grid, count, gap, first in [('1', 4, 500, 2500 if offbeat else 2000),
                                           ('1/2', 8, 250, 2250 if offbeat else 2000),
                                           ('1/4', 16, 125, 2125 if offbeat else 2000)]:
                _, notes = self.chart('--grid', grid)
                self.assertEqual(len(notes), count)
                self.assertEqual(notes[0][0], first)
                self.assertTrue(all(n[0] % gap == 0 for n in notes))
                self.assertTrue(all(b[0]-a[0] == gap for a,b in zip(notes,notes[1:])))

    def test_hold_durations_grid_and_missing_note_offs(self):
        self.source.write_bytes(hold_fixture())
        _, base = self.chart('--track', '1')
        _, notes = self.chart('--track', '1', '--holds')
        self.assertEqual([n[0] for n in base], [n[0] for n in notes])
        self.assertEqual([n for n in notes if len(n) == 3], [(2000,0,2500), (7000,1,7500)])
        # At 120 BPM, a 1.5-beat note ends on a half-beat: coarse tails round down.
        track = b'\x00\xff\x51\x03\x07\xa1\x20'
        for i in range(10):
            track += vlq(1920 if i == 0 else 240) + bytes((0x90, 60, 100))
            track += vlq(720) + bytes((0x80, 60, 0))
        track += b'\x00\xff\x2f\x00'
        self.source.write_bytes(b'MThd'+struct.pack('>IHHH',6,0,1,480)+b'MTrk'+struct.pack('>I',len(track))+track)
        for grid, end in [('1',2500), ('1/2',2750), ('1/4',2750)]:
            _, notes = self.chart('--holds', '--grid', grid, '--seed', '42', '--generate-only', random=True)
            self.assertEqual((notes[0][0],notes[0][2]), (2000,end))
        self.source.write_bytes(fixture())
        _, notes = self.chart('--holds')
        self.assertTrue(all(len(n)==2 for n in notes))

    def test_random_replay_balance_and_holds(self):
        self.source.write_bytes(hold_fixture())
        first = None
        timing = None
        lanes_by_seed = []
        for seed in [0, 1, 42, 123, 124, 4294967295]:
            text, notes = self.chart('--seed', seed, '--holds', '--generate-only', random=True)
            if first is None: first = text
            lanes_by_seed.append([n[1] for n in notes])
            self.assertIn('# random_mode=balanced-holds-shell-v4', text)
            self.assertIn('# hold_count=2', text)
            times = [(n[0], n[2] if len(n)==3 else n[0]) for n in notes]
            if timing is None: timing = times
            self.assertEqual(times, timing)
            self.assertEqual(Counter(n[1] for n in notes[:8]), {0:2,1:2,2:2,3:2})
            self.assertTrue(all(a[1]//2 != b[1]//2 for a,b in zip(notes,notes[1:])))
            ends = [-1]*4
            for n in notes:
                self.assertGreater(n[0], ends[n[1]])
                ends[n[1]] = n[2] if len(n)==3 else n[0]
        self.assertNotEqual(lanes_by_seed[3], lanes_by_seed[4])
        replay, _ = self.chart('--seed', 0, '--holds', '--generate-only', random=True)
        self.assertEqual(first, replay)

    def test_create_reuse_and_edit_protection(self):
        output = self.directory / 'chart.csv'
        result = self.run_import('--output', output)
        self.assertEqual(result.returncode, 0, result.stderr)
        original = output.read_bytes()
        self.assertNotEqual(self.run_import('--output', output).returncode, 0)
        self.assertEqual(original, output.read_bytes())
        output.unlink()
        args = ['--output', output, '--seed', '42', '--generate-only']
        self.assertEqual(self.run_import(*args, random=True).returncode, 0)
        original = output.read_bytes()
        self.assertEqual(self.run_import(*args, random=True).returncode, 0)
        self.assertEqual(original, output.read_bytes())
        output.write_bytes(original + b'# Edited\n')
        self.assertNotEqual(self.run_import(*args, random=True).returncode, 0)
        self.assertEqual(output.read_bytes(), original + b'# Edited\n')

    def test_generation_without_python_on_path(self):
        binaries = self.directory / 'bin'
        binaries.mkdir()
        for name in ['bash','dirname','realpath','od','awk','mktemp','cat','mkdir','ln','rm']:
            (binaries / name).symlink_to(shutil.which(name))
        output = self.directory / 'shell-only.csv'
        result = self.run_import('--output',output,'--seed','42','--generate-only',random=True,
                                 env={**os.environ,'PATH':str(binaries)})
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue(output.exists())

    def test_invalid_options_and_midi(self):
        for args in [('--seed','-1'),('--seed','4294967296'),('--seed','abc'),
                     ('--grid','1/8'),('--track','99'),('--support-track','99'),
                     ('--fps','14'),('--offset','10000000'),('--output',)]:
            self.assertNotEqual(self.run_import(*args, random=True).returncode, 0, args)
        for content in [b'', b'not midi', fixture()[:-5], fixture().replace(b'\x01\xe0',b'\xe7\x28',1),
                        fixture().replace(b'\x07\xa1\x20',b'\x00\x00\x00',1)]:
            self.source.write_bytes(content)
            self.assertNotEqual(self.run_import('--analyze').returncode, 0, content[:20])
        # Valid MIDI but a tempo event outside integer beats is unrepresentable in CSV v1.
        self.source.write_bytes(fixture().replace(vlq(1920),vlq(1921),1))
        output = self.directory / 'invalid.csv'
        result = self.run_import('--output', output)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())

    def isolated_project(self):
        root = self.directory / 'project'
        shutil.copytree(ROOT / 'tools', root / 'tools', ignore=shutil.ignore_patterns('__pycache__'))
        shutil.copy(ROOT / 'random-play.sh', root / 'random-play.sh')
        return root

    def test_random_launches_game_and_default_path(self):
        root = self.isolated_project()
        (root / 'game.sh').write_text('printf "%s\\n" "$@" > "$(dirname -- "$0")/arguments"\nexit 7\n')
        result = self.run_import('--seed','8','--silent','--fps','30','--offset','50', random=True, root=root)
        self.assertEqual(result.returncode, 7, result.stderr)
        args = (root / 'arguments').read_text().splitlines()
        self.assertEqual(args[1:], ['--fps','30','--offset','50','--silent'])
        self.assertIn('balanced-shell-v4', Path(args[0]).name)
        self.assertTrue(Path(args[0]).is_file())

    @unittest.skipUnless(shutil.which('ffmpeg') and shutil.which('ffprobe'), 'ffmpeg/ffprobe not installed')
    def test_render_cache_volume_and_timing(self):
        root = self.isolated_project()
        raw = self.directory / 'quiet.wav'
        rate = 8000
        samples = array.array('h', (0 if i < rate//2 else
                         round((.004 if i < rate*4 else .2)*32767*math.sin(2*math.pi*400*i/rate))
                         for i in range(rate*8)))
        with wave.open(str(raw),'wb') as out:
            out.setparams((1,2,rate,0,'NONE','not compressed')); out.writeframes(samples.tobytes())
        executable = self.directory / 'fluidsynth'
        executable.write_text('#!/usr/bin/env bash\nwhile [[ $1 != -F ]]; do shift; done\ncp -- "$TEST_RENDER_WAV" "$2"\n')
        executable.chmod(0o755)
        font = self.directory / 'font.sf2'; font.write_bytes(b'fake test font')
        env = {**os.environ,'PATH':str(self.directory)+':'+os.environ['PATH'],'TEST_RENDER_WAV':str(raw)}
        args = ['--render-only','--soundfont',font,'--loudness','original']
        result = self.run_import(*args,root=root,env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        original = Path(result.stdout.strip()); stamp = original.stat().st_mtime_ns
        self.assertEqual(original.read_bytes(),raw.read_bytes())
        result = self.run_import(*args,root=root,env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(Path(result.stdout.strip()).stat().st_mtime_ns,stamp)
        result = self.run_import('--render-only','--soundfont',font,'--loudness','balanced',root=root,env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        enhanced = Path(result.stdout.strip())
        with wave.open(str(enhanced)) as audio:
            self.assertEqual((audio.getnframes(),audio.getframerate(),audio.getnchannels()),(rate*8,rate,1))
            values = array.array('h'); values.frombytes(audio.readframes(rate*8))
        self.assertGreater(sum(v*v for v in values[rate:rate*2]),sum(v*v for v in samples[rate:rate*2])*16)
        self.assertLessEqual(max(abs(v) for v in values),round(.951*32768))
        self.assertEqual(next(i for i,v in enumerate(values) if v),next(i for i,v in enumerate(samples) if v))
        self.assertEqual(original.read_bytes(),raw.read_bytes())
        self.source.write_bytes(fixture()+b'changed')
        result = self.run_import(*args,root=root,env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual(Path(result.stdout.strip()),original)

    def test_supplied_midi_tracks_and_rhythm(self):
        source = ROOT / 'songs/saikoro - Far in the blue sky.mid'
        if not source.exists(): self.skipTest('User MIDI is not present')
        self.source = source
        text, notes = self.chart('--seed','42','--generate-only',random=True)
        self.assertIn('# melody_track=1',text)
        self.assertIn('# support_track=2',text)
        self.assertEqual(len(notes),95)
        self.assertGreaterEqual(notes[0][0],2000)
        self.assertTrue(all(b[0]-a[0]>=300 for a,b in zip(notes,notes[1:])))

    def test_sparse_easy_piano_fill_uses_real_onsets_and_preserves_manual_tracks(self):
        self.source.write_bytes(sparse_piano_fixture())
        text, notes = self.chart('--seed', '42', '--generate-only', random=True)
        self.assertIn('# density_fill_track=1', text)
        self.assertIn('# density_added=32', text)
        self.assertEqual(len(notes), 35)
        self.assertEqual([n[0] for n in notes], list(range(2000, 19500, 500)))
        replay, again = self.chart('--seed', '42', '--generate-only', random=True)
        self.assertEqual(text, replay)
        self.assertEqual(notes, again)
        _, other_seed = self.chart('--seed', '99', '--generate-only', random=True)
        self.assertEqual([n[0] for n in notes], [n[0] for n in other_seed])
        for args in (('--track', '0'), ('--support-track', '1'), ('--grid', '1/2'), ('--grid', '1/4')):
            text, _ = self.chart(*args, '--seed', '42', '--generate-only', random=True)
            self.assertNotIn('# density_fill_track=', text)
        text, manual = self.chart('--track', '0', '--seed', '42', '--generate-only', random=True)
        self.assertEqual([n[0] for n in manual], [2000, 8000, 14000])
        text, imported = self.chart('--track', '0')
        self.assertEqual([n[0] for n in imported], [2000, 8000, 14000])

    def test_petrichor_easy_density_matches_swan_song(self):
        petrichor = ROOT / 'songs/Petrichor.mid'
        swan = ROOT / 'songs/Swan_song_–_Void.mid'
        if not petrichor.exists() or not swan.exists(): self.skipTest('Reference MIDI songs are not present')
        self.source = petrichor
        text, notes = self.chart('--seed', '42', '--holds', '--generate-only', random=True)
        self.assertIn('# density_fill_track=3', text)
        self.assertEqual(len(notes), 288)
        self.assertTrue(all(b[0]-a[0] >= 300 for a,b in zip(notes,notes[1:])))
        self.assertLess(max(b[0]-a[0] for a,b in zip(notes,notes[1:])), 5000)
        _, baseline = self.chart('--track', '9', '--support-track', '12', '--seed', '42', '--generate-only', random=True)
        self.assertEqual(len(baseline), 166)
        self.assertTrue({n[0] for n in baseline} <= {n[0] for n in notes})
        _, other_seed = self.chart('--seed', '99', '--holds', '--generate-only', random=True)
        self.assertEqual([(n[0], n[2:]) for n in notes], [(n[0], n[2:]) for n in other_seed])
        _, taps = self.chart('--seed', '42', '--generate-only', random=True)
        self.assertEqual([n[0] for n in notes], [n[0] for n in taps])
        self.source = swan
        text, swan_notes = self.chart('--seed', '42', '--holds', '--generate-only', random=True)
        self.assertEqual(len(swan_notes), 282)
        self.assertNotIn('# density_fill_track=', text)
        self.assertLess(abs(len(notes)/164.705 - len(swan_notes)/160.541), .05)


if __name__ == '__main__': unittest.main(verbosity=2)


