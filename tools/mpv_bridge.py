#!/usr/bin/env python3
"""Line-oriented mpv IPC adapter; stdout is reserved for responses to Bash."""
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import time


def main():
    player = None
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    try:
        with tempfile.TemporaryDirectory(prefix='fourkeys-') as directory:
            path = os.path.join(directory, 'mpv.sock')
            with tempfile.TemporaryFile(mode='w+') as log:
                player = subprocess.Popen([
                    'mpv', '--no-config', '--no-video', '--no-terminal',
                    '--pause=yes', '--keep-open=yes', '--audio-display=no',
                    '--input-ipc-server=' + path, '--', os.path.abspath(sys.argv[1]),
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
                print('READY', flush=True)
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
