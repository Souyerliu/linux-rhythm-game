#!/usr/bin/env python3
"""Line-oriented mpv IPC adapter; stdout is reserved for responses to Bash."""
import json
import math
import os
import signal
import socket
import subprocess
import sys
import tempfile
import time
import wave


def prepend_silence(source, target, delay_ms):
    """Create a continuous audio stream that starts before the first note."""
    try:
        pcm = wave.open(source, 'rb')
    except (wave.Error, EOFError):
        # An explicit audio override can be encoded in a format other than WAV.
        subprocess.run([
            'ffmpeg', '-nostdin', '-loglevel', 'error', '-i', source,
            '-map', '0:a:0', '-af', f'adelay={delay_ms}:all=1', '-c:a', 'pcm_s16le', target,
        ], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True)
        return
    with pcm, wave.open(target, 'wb') as padded:
        padded.setparams(pcm.getparams())
        frames = round(delay_ms * pcm.getframerate() / 1000)
        silence = b'\x80' if pcm.getsampwidth() == 1 else b'\x00' * pcm.getsampwidth()
        sample_frame = silence * pcm.getnchannels()
        for offset in range(0, frames, 65536):
            padded.writeframesraw(sample_frame * min(frames - offset, 65536))
        for block in iter(lambda: pcm.readframes(65536), b''):
            padded.writeframesraw(block)


def main():
    player = None
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    try:
        with tempfile.TemporaryDirectory(prefix='fourkeys-') as directory:
            path = os.path.join(directory, 'mpv.sock')
            audio_path = os.path.abspath(sys.argv[1])
            delay_ms = int(sys.argv[2]) if len(sys.argv) > 2 else 0
            if delay_ms:
                padded_path = os.path.join(directory, 'preroll.wav')
                prepend_silence(audio_path, padded_path, delay_ms)
                audio_path = padded_path
            with tempfile.TemporaryFile(mode='w+') as log:
                player = subprocess.Popen([
                    'mpv', '--no-config', '--no-video', '--no-terminal',
                    '--pause=yes', '--keep-open=yes', '--audio-display=no',
                    '--input-ipc-server=' + path, '--', audio_path,
                ], stdin=subprocess.DEVNULL, stdout=log, stderr=log)
                conn = socket.socket(socket.AF_UNIX)
                deadline = time.monotonic() + 8
                while True:
                    if player.poll() is not None:
                        raise RuntimeError('mpv exited before loading audio')
                    try:
                        conn.connect(path)
                        break
                    except (FileNotFoundError, ConnectionRefusedError):
                        if time.monotonic() > deadline:
                            raise RuntimeError('mpv socket timeout')
                        time.sleep(.03)
                conn.settimeout(2)
                stream = conn.makefile('rwb')
                request_id = 0

                def command(*args):
                    nonlocal request_id
                    request_id += 1
                    stream.write((json.dumps({'command': args, 'request_id': request_id}) + '\n').encode())
                    stream.flush()
                    while True:
                        line = stream.readline()
                        if not line:
                            raise RuntimeError('mpv disconnected')
                        result = json.loads(line)
                        if result.get('request_id') == request_id:
                            if result.get('error') != 'success':
                                raise RuntimeError(result.get('error', 'mpv error'))
                            return result.get('data')

                def audio_position():
                    # time-pos is updated on mpv's frame cadence; audio-pts is
                    # the higher resolution audio output clock (also on 0.37).
                    try:
                        value = command('get_property', 'audio-pts')
                        if isinstance(value, (int, float)):
                            return max(0.0, value)
                    except RuntimeError:
                        pass
                    return command('get_property', 'time-pos')

                while True:
                    try:
                        command('get_property', 'time-pos')
                        break
                    except RuntimeError:
                        if time.monotonic() > deadline:
                            raise RuntimeError('audio failed to load (check file and audio device)')
                        time.sleep(.03)
                try:
                    duration = command('get_property', 'duration')
                except RuntimeError:
                    duration = None
                duration_ms = (round(duration * 1000)
                               if isinstance(duration, (int, float)) and math.isfinite(duration) and duration > 0
                               else 0)
                print(f'READY {duration_ms}', flush=True)
                for line in sys.stdin:
                    parts = line.split()
                    if not parts:
                        continue
                    if parts[0] == 'play':
                        command('set_property', 'pause', False)
                    elif parts[0] == 'pause':
                        command('set_property', 'pause', True)
                    elif parts[0] == 'seek':
                        command('seek', max(0, int(parts[1])) / 1000, 'absolute+exact')
                        command('get_property', 'time-pos')
                    elif parts[0] != 'time':
                        raise RuntimeError('unknown bridge command')
                    position = audio_position()
                    if parts[0] == 'play' and delay_ms:
                        # A zero PTS at unpause can precede audio device startup.
                        deadline = time.monotonic() + 2
                        while position <= 0:
                            if time.monotonic() >= deadline:
                                raise RuntimeError('audio clock did not start')
                            time.sleep(.005)
                            position = audio_position()
                    sampled_ms = time.time_ns() // 1_000_000
                    ended = bool(command('get_property', 'eof-reached'))
                    print(f'OK {round(position * 1000)} {int(ended)} {sampled_ms}', flush=True)
                stream.close()
                conn.close()
    except Exception as error:
        print('ERR ' + str(error), flush=True)
        return 1
    finally:
        if player is not None and player.poll() is None:
            player.terminate()
            try:
                player.wait(timeout=2)
            except subprocess.TimeoutExpired:
                player.kill()
                player.wait()
    return 0


if __name__ == '__main__':
    sys.exit(main())
