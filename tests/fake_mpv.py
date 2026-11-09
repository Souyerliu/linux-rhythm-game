#!/usr/bin/env python3
"""IPC test double. This does not play audio."""
import json
import os
import socket
import sys
import time

path = next(arg.split('=', 1)[1] for arg in sys.argv if arg.startswith('--input-ipc-server='))
if os.environ.get('TEST_MPV_PID'):
    with open(os.environ['TEST_MPV_PID'], 'w') as output:
        output.write(str(os.getpid()))
server = socket.socket(socket.AF_UNIX)
server.bind(path)
server.listen(1)
conn, _ = server.accept()
stream = conn.makefile('rwb')
paused = True
position = 0.0
anchor = time.monotonic()
for line in stream:
    request = json.loads(line)
    args = request['command']
    now = time.monotonic()
    if not paused:
        position += now - anchor
    duration = float(os.environ.get('TEST_MPV_DURATION', '1000000'))
    position = min(position, duration)
    anchor = now
    data = None
    if args[:2] == ['get_property', 'time-pos']:
        data = position + float(os.environ.get('TEST_MPV_POSITION_BIAS', '0'))
    elif args[:2] == ['get_property', 'audio-pts']:
        data = position
        spike_at = float(os.environ.get('TEST_MPV_PTS_SPIKE_AT', '-1'))
        if spike_at >= 0 and spike_at <= position < spike_at + float(os.environ.get('TEST_MPV_PTS_SPIKE_FOR', '.05')):
            data += float(os.environ.get('TEST_MPV_PTS_SPIKE_SIZE', '.35'))
    elif args[:2] == ['get_property', 'eof-reached']:
        time.sleep(float(os.environ.get('TEST_MPV_DELAY', '0')))
        data = position >= duration
    elif args[:2] == ['set_property', 'pause']:
        paused = args[2]
        if not paused and os.environ.get('TEST_MPV_PLAY_TIME'):
            with open(os.environ['TEST_MPV_PLAY_TIME'], 'w') as output:
                output.write(str(now))
    elif args[0] == 'seek':
        position = args[1]
    stream.write((json.dumps({'request_id': request['request_id'], 'error': 'success', 'data': data}) + '\n').encode())
    stream.flush()
