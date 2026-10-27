#!/usr/bin/env python3
"""Measure XTEST key injection to real RPC/Bash echo in X11 window pixels.

Uses a separate workspace/state and never types into an existing Exosuit window.
Always launches a private Xvfb display with software rendering; input never
reaches the user desktop. XGetImage observation includes polling/readback overhead;
this measures neither keyboard hardware nor compositor scanout/photons.
Build the graphical app and workspace agent before running.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import tempfile
import time

from PIL import Image
from Xlib import X, XK, display
from Xlib.ext import xtest

ROOT = Path(__file__).resolve().parent.parent
ACCENT = (145, 191, 255)


def distribution(values):
    ordered = sorted(values)
    def p(q):
        return ordered[max(0, math.ceil(q * len(ordered)) - 1)] if ordered else None
    return dict(count=len(ordered), median=statistics.median(ordered) if ordered else None,
                p95=p(.95), p99=p(.99), maximum=max(ordered) if ordered else None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--isolated-child', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--workspace', type=Path)
    parser.add_argument('--profile', action='store_true')
    parser.add_argument('--pairs', type=int, default=40)
    parser.add_argument('--bursts', type=int, default=3)
    parser.add_argument('--burst-size', type=int, default=30)
    parser.add_argument('--burst-interval-ms', type=float, default=5)
    args = parser.parse_args()
    if not args.isolated_child:
        environment = dict(os.environ, LIBGL_ALWAYS_SOFTWARE='1')
        subprocess.run(['xvfb-run', '-a', '-s', '-screen 0 1600x1000x24',
                        sys.executable, str(Path(__file__).resolve()), '--isolated-child', *sys.argv[1:]],
                       env=environment, check=True)
        return
    if args.pairs < 1 or args.bursts < 1 or not 1 <= args.burst_size <= 40 or not 0 < args.burst_interval_ms <= 50:
        parser.error('invalid sample or burst configuration')
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    workspace = args.workspace.resolve() if args.workspace else out / 'workspace'
    workspace.mkdir(exist_ok=True)
    home = ROOT / 'haxeon'
    runtime = home / '.tools/hashlink/hl'
    bytecode = ROOT / 'graphical/build/host/main.hl'
    agent = ROOT / 'agent/build/host/main.hl'
    for path in (runtime, bytecode, agent):
        if not path.is_file():
            raise RuntimeError('Build Exosuit first: missing ' + str(path))
    native = ROOT / 'graphical/build/host/native'
    libraries = [home / 'out', home / '.tools/hashlink',
                 *sorted(p for p in native.iterdir() if p.is_dir())]
    wrapper = out / 'shell'
    wrapper.write_text('#!/bin/sh\nexec /bin/bash --noprofile --norc -i\n')
    wrapper.chmod(0o755)
    title = 'Exosuit terminal latency ' + str(os.getpid())
    state = Path(tempfile.mkdtemp(prefix='exolat-'))  # Unix socket path must stay short.
    environment = dict(os.environ, LD_LIBRARY_PATH=os.pathsep.join(map(str, libraries)),
                       XDG_STATE_HOME=str(state), XDG_CONFIG_HOME=str(out / 'config'),
                       XDG_DATA_HOME=str(out / 'data'), XDG_CACHE_HOME=str(out / 'cache'),
                       PRAGTICAL_PORTABLE=str(out / 'settings'), SHELL=str(wrapper),
                       PS1='', PROMPT_COMMAND='', EXOSUIT_AGENT_LAUNCHER=str(agent))
    for key in ('EXOSUIT_AGENT_STATE_HOME', 'EXOSUIT_AGENT_ALWAYS_AVAILABLE'):
        environment.pop(key, None)
    if args.profile:
        environment['EXOSUIT_TERMINAL_LATENCY_TRACE'] = '1'
    metadata = dict(rootRevision=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                    haxeonRevision=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=home, text=True).strip(),
                    display=environment.get('DISPLAY'), workspace=str(workspace), profile=args.profile,
                    appSha256=hashlib.sha256(bytecode.read_bytes()).hexdigest(),
                    agentSha256=hashlib.sha256(agent.read_bytes()).hexdigest(),
                    configuration=vars(args) | {'output': str(out), 'workspace': str(workspace)})
    metadata['wallMinusPerfSeconds'] = time.time() - time.perf_counter()
    metadata['loadAverage'] = os.getloadavg()
    if shutil.which('glxinfo'):
        metadata['renderer'] = subprocess.check_output(['glxinfo', '-B'], env=environment, text=True)
    shutil.copy2(bytecode, out / 'app.hl')
    shutil.copy2(agent, out / 'agent.hl')
    (out / 'metadata.json').write_text(json.dumps(metadata, indent=2))
    for directory, name in [(ROOT, 'root'), (home, 'haxeon')]:
        (out / (name + '-dirty.patch')).write_bytes(subprocess.check_output(['git', 'diff'], cwd=directory))
    app = recorder = None
    connection = None
    try:
        command = [str(runtime)]
        if args.profile:
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0))
                port = sock.getsockname()[1]
            command += ['--diagnostics', str(port), '--diagnostics-wait']
        # Enough time for startup, calibration, isolated inputs and bursts, then diagnostics.
        seconds = max(35, 12 + args.pairs * .9 + args.bursts * (args.burst_size * args.burst_interval_ms / 1000 + .8))
        command += [str(bytecode), str(workspace), '--title=' + title, '--theme=dark',
                    '--capture-dir=' + str(out / 'capture'), '--capture-seconds=' + str(seconds)]
        with (out / 'app.log').open('w') as log:
            app = subprocess.Popen(command, cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT)
        if args.profile:
            with (out / 'recorder.log').open('w') as log:
                recorder = subprocess.Popen([str(home / '.tools/hashlink/hlprof-live'), '--sources', 'sampling',
                    '--rate', '1000', '--connect-timeout', '30', '--output', str(out / 'profile.hlpc'), str(port)],
                    stdout=log, stderr=subprocess.STDOUT)
        window_id = subprocess.check_output(['timeout', '40', 'xdotool', 'search', '--sync', '--onlyvisible',
                                             '--name', '^' + title + '$'], text=True).splitlines()[0]
        subprocess.run(['xdotool', 'windowsize', window_id, '1100', '700'], check=True)
        subprocess.run(['xdotool', 'windowfocus', '--sync', window_id], check=True)
        time.sleep(3)
        # Startup attachment is asynchronous: open only after the service has connected.
        subprocess.run(['xdotool', 'key', '--clearmodifiers', 'ctrl+grave'], check=True)
        time.sleep(1)
        ready = out / 'ready'
        setup = "PS1=''; printf ready > '" + str(ready) + "'; printf '\\033[2J\\033[H'"
        subprocess.run(['xdotool', 'type', '--clearmodifiers', '--delay', '2', setup], check=True)
        subprocess.run(['xdotool', 'key', 'Return'], check=True)
        deadline = time.monotonic() + 5
        while not ready.exists() and time.monotonic() < deadline:
            time.sleep(.02)
        if not ready.exists():
            raise RuntimeError('Real shell did not accept setup command; see capture and app.log')
        time.sleep(.3)
        connection = display.Display()
        window = connection.create_resource_object('window', int(window_id))
        size = window.get_geometry()
        def pixels(x, y, w, h):
            raw = window.get_image(x, y, w, h, X.ZPixmap, 0xffffffff)
            return Image.frombytes('RGB', (w, h), raw.data, 'raw', 'BGRX')
        initial = pixels(0, 0, size.width, size.height)
        initial.save(out / 'initial.png')
        candidates = []
        for y in range(size.height // 2, size.height):
            xs = [x for x in range(size.width) if initial.getpixel((x, y)) == ACCENT]
            if 3 <= len(xs) <= 16 and max(xs) - min(xs) < 16:
                candidates.append((min(xs), y))
        if not candidates:
            raise RuntimeError('No focused terminal caret found in initial.png')
        x0, baseline = candidates[-1]
        readbacks = []
        observations = []
        events = []
        def record(event):
            events.append(event)
            with (out / 'events.jsonl').open('a') as log:
                log.write(json.dumps(event) + '\n')
        def key(name):
            focused = connection.get_input_focus().focus
            focus_ids = []
            while hasattr(focused, 'id') and focused.id not in focus_ids:
                focus_ids.append(focused.id)
                if focused.id == window.id:
                    break
                focused = focused.query_tree().parent
            else:
                raise RuntimeError('Test window lost X11 focus; stopped injecting input: ' + str(focus_ids))
            code = connection.keysym_to_keycode(XK.string_to_keysym(name))
            if not code:
                raise RuntimeError('Unknown X11 key ' + name)
            at = time.perf_counter()
            xtest.fake_input(connection, X.KeyPress, code)
            xtest.fake_input(connection, X.KeyRelease, code)
            connection.flush()
            return at
        def cursor():
            before = time.perf_counter()
            row = pixels(x0, baseline, min(650, size.width - x0), 1)
            after = time.perf_counter()
            readbacks.append((after - before) * 1000)
            xs = [x for x in range(row.width) if row.getpixel((x, 0)) == ACCENT]
            return (min(xs) if xs else None), after
        # Infer fractional cell pitch from rendered positions, without hardcoding a font.
        for _ in range(32):
            key('x')
        deadline = time.perf_counter() + 3
        while True:
            position, _ = cursor()
            if position is not None and position > 240:
                time.sleep(.1)
                position, _ = cursor()
                break
            if time.perf_counter() > deadline:
                pixels(0, 0, size.width, size.height).save(out / 'calibration-failed.png')
                raise RuntimeError('Calibration echo timed out; last cursor offset=' + str(position))
            time.sleep(.001)
        pitch = position / 32
        if not 7 < pitch < 12:
            raise RuntimeError('Unexpected terminal cell pitch: ' + str(pitch))
        def observe():
            position, at = cursor()
            count = None if position is None else round(position / pitch)
            observations.append(dict(at=at, column=count))
            return count, at
        def await_column(expected, timeout=2):
            deadline = time.perf_counter() + timeout
            while True:
                count, at = observe()
                if count == expected:
                    return at
                if at > deadline:
                    raise RuntimeError('Caret did not reach column ' + str(expected) + '; last=' + str(count))
                time.sleep(.0005)
        def clear():
            for _ in range(40):
                key('BackSpace')
            await_column(0)
            time.sleep(.06)
        clear()
        # One character and its deletion, each after the previous echo has appeared.
        for index in range(args.pairs):
            for name, expected in [('x', 1), ('BackSpace', 0)]:
                at = key(name)
                observed = await_column(expected)
                record(dict(scenario='isolated', pair=index, key=name, column=expected,
                                   injectedAt=at, observedAt=observed, latencyMs=(observed-at)*1000))
                time.sleep(.03)
        print('Isolated:', distribution([e['latencyMs'] for e in events]), flush=True)
        burst_checks = []
        for burst in range(args.bursts):
            clear()
            sent = []
            seen = 0
            start = time.perf_counter()
            deadline = start + 4
            while len(sent) < args.burst_size or seen < args.burst_size:
                now = time.perf_counter()
                while len(sent) < args.burst_size and now >= start + len(sent) * args.burst_interval_ms / 1000:
                    sent.append(key('x'))
                    now = time.perf_counter()
                count, at = observe()
                if count is not None and count > seen:
                    if count > len(sent):
                        raise RuntimeError('Cursor advanced beyond injected input')
                    for index in range(seen, count):
                        record(dict(scenario='burst', burst=burst, key='x', column=index+1,
                                           injectedAt=sent[index], observedAt=at, latencyMs=(at-sent[index])*1000))
                    seen = count
                if at > deadline:
                    raise RuntimeError('Burst echo did not catch up')
                time.sleep(.0005)
            # Inspect glyphs as well as the cursor: all echoed cells need visible ink.
            image = pixels(x0, baseline-18, math.ceil((args.burst_size+2)*pitch), 19)
            image.save(out / ('burst-' + str(burst) + '.png'))
            ink = []
            for column in range(args.burst_size):
                cell = image.crop((round(column*pitch)+1, 2, round((column+1)*pitch)-1, 15))
                ink.append(sum(r > 170 and g > 175 and b > 180 for r, g, b in cell.getdata()))
            if not all(value >= 2 for value in ink):
                raise RuntimeError('Cursor caught up but echoed glyphs did not: ' + str(ink))
            burst_checks.append(dict(burst=burst, finalColumn=seen, finalCatchupMs=(at-sent[-1])*1000,
                                     glyphInkPixels=ink, actualIntervalsMs=[(b-a)*1000 for a,b in zip(sent,sent[1:])]))
            time.sleep(.15)
        clear()  # Leave no partial shell command, then shut down this test shell only.
        subprocess.run(['xdotool', 'type', '--clearmodifiers', '--delay', '1', 'exit'], check=True)
        key('Return')
        result = dict(metadata=metadata, caretOrigin=[x0, baseline], cellPitch=pitch, events=events,
                      bursts=burst_checks, observations=observations,
                      isolatedMs=distribution([e['latencyMs'] for e in events if e['scenario']=='isolated']),
                      burstMs=distribution([e['latencyMs'] for e in events if e['scenario']=='burst']),
                      readbackCallMs=distribution(readbacks))
        (out / 'results.json').write_text(json.dumps(result, indent=2))
        print(json.dumps({key:result[key] for key in ('isolatedMs','burstMs','readbackCallMs')}, indent=2), flush=True)
        if app.wait(timeout=seconds+15) != 0:
            raise RuntimeError('Exosuit exited unsuccessfully; see app.log')
        snapshot = json.loads((out / 'capture/app-state.json').read_text())
        if snapshot['workspaceConnection'] != 'Workspace connected' or snapshot['errors']:
            raise RuntimeError('Workspace/terminal errors: ' + str(snapshot['errors']))
        if recorder:
            recorder.wait(timeout=30)
            with (out / 'profile-report.txt').open('w') as log:
                subprocess.run([str(home/'.tools/hashlink/hlprof-live'), 'report', '--top', '30', str(out/'profile.hlpc')],
                               stdout=log, stderr=subprocess.STDOUT, check=True)
            subprocess.run([str(home/'.tools/hashlink/hlprof-live'), 'export', '--format', 'perfetto',
                            '--output', str(out/'trace.json'), str(out/'profile.hlpc')], check=True)
        print('PASS: real workspace RPC/Bash echo, fast-burst glyphs and cursor pixels', flush=True)
    finally:
        if connection:
            connection.close()
        for process in (app, recorder):
            if process and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        for endpoint in state.glob('exosuit/workspaces/*/endpoint.json'):
            try:
                os.kill(json.loads(endpoint.read_text())['managerPid'], signal.SIGTERM)
            except (FileNotFoundError, ProcessLookupError):
                pass
        for path in state.rglob('*.log'):
            target = out / 'state' / path.relative_to(state)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
        deadline = time.monotonic() + 3
        while list(state.glob('exosuit/workspaces/*/endpoint.json')) and time.monotonic() < deadline:
            time.sleep(.05)
        shutil.rmtree(state)


if __name__ == '__main__':
    main()
