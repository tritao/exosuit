#!/usr/bin/env python3
"""Capture terminal scenarios with hlprof-live and summarize measured frames."""
import argparse
from bisect import bisect_right
from collections import Counter, defaultdict
import json
import os
from pathlib import Path
import statistics
import subprocess

ROOT = Path(__file__).resolve().parent.parent
PROFILER = ROOT / 'haxeon/.tools/hashlink/hlprof-live'


def analyze(directory):
    capture = directory / 'profile.hlpc'
    trace = directory / 'profile.json'
    with (directory / 'export-json.log').open('w') as log:
        subprocess.run([str(PROFILER), 'export', '--format', 'perfetto', '--output', str(trace), str(capture)],
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    events = json.loads(trace.read_text())['traceEvents']
    stacks = defaultdict(list)
    active = {}
    frames = []
    for event in events:
        tid, phase = event.get('tid'), event.get('ph')
        if phase == 'B':
            name = event['name']
            stacks[tid].append((name, event['ts']))
            if name == 'ui.frame':
                active[tid] = dict(start=event['ts'], spans=defaultdict(float), scenario=None)
            elif name.startswith('terminal.measured.') and tid in active:
                active[tid]['scenario'] = name.removeprefix('terminal.measured.')
        elif phase == 'E' and stacks[tid]:
            name, start = stacks[tid].pop()
            if tid in active:
                frame = active[tid]
                frame['spans'][name] += (event['ts'] - start) / 1000
                if name == 'ui.frame':
                    frame['end'] = event['ts']
                    frame['tid'] = tid
                    if frame['scenario'] is not None:
                        frames.append(frame)
                    del active[tid]
    frames.sort(key=lambda frame: frame['start'])
    starts = [frame['start'] for frame in frames]
    samples = defaultdict(Counter)
    for event in events:
        if event.get('cat') != 'hl.sample':
            continue
        index = bisect_right(starts, event['ts']) - 1
        if index < 0:
            continue
        frame = frames[index]
        if event['ts'] <= frame['end'] and event['tid'] == frame['tid']:
            samples[frame['scenario']][event['name']] += 1
    grouped = defaultdict(list)
    for frame in frames:
        grouped[frame['scenario']].append(frame)
    expected = json.loads((directory / 'capture/app-state.json').read_text())
    expected_count = expected['framesPerScenario'] - expected['warmupFrames']
    assert set(grouped) == set(expected['scenarios']), set(grouped)
    results = {}
    metrics = ['ui.frame', 'ui.prepare', 'ui.submit', 'ui.render', 'ui.frame.gc', 'terminal.poll',
               'terminal.ui-submit', 'ui.TerminalPane.refreshRows', 'terminalkit.Emulator.rowCells',
               'haxeon.ui.TextLayout.setText', 'haxeon.ui.TextLayout.setColorRanges']
    lines = ['| Scenario | Frame mean (ms) | Render mean (ms) | Poll mean (ms) | setText mean (ms) | In-frame samples |',
             '|---|---:|---:|---:|---:|---:|']
    for scenario, rows in grouped.items():
        assert len(rows) == expected_count, (scenario, len(rows), expected_count)
        summary = {name: statistics.mean(frame['spans'].get(name, 0) for frame in rows) for name in metrics}
        count = sum(samples[scenario].values())
        top = [dict(function=name, samples=value, percent=100 * value / count)
               for name, value in samples[scenario].most_common(20)]
        results[scenario] = dict(frames=len(rows), meanMs=summary, inFrameSamples=count, sampledLeafBoundaries=top)
        lines.append(f"| {scenario} | {summary['ui.frame']:.2f} | {summary['ui.render']:.2f} | "
                     f"{summary['terminal.poll']:.2f} | {summary['haxeon.ui.TextLayout.setText']:.2f} | {count} |")
        frame_start, frame_end = int(rows[0]['start'] / 1000), int(rows[-1]['end'] / 1000)
        with (directory / f'{scenario}-samples.txt').open('w') as log:
            subprocess.run([str(PROFILER), 'report', '--lines', '--top', '25', '--start-ms', str(frame_start),
                            '--end-ms', str(frame_end), str(capture)], stdout=log, stderr=subprocess.STDOUT, check=True)
    stalls = [event for event in events if event.get('name') == 'profiler stall']
    result = dict(scenarios=results, profilerStalls=len(stalls),
                  interpretation='Profiled means include instrumentation overhead. Function totals are inclusive and overlap. Short calls under 10 us are filtered in the default capture; omitted work is charged to retained parents. Linux samples attribute opaque native execution to the nearest named Haxe boundary. Scenario samples here include measured main-thread ui.frame intervals only; text reports use elapsed scenario windows and may include event waits.')
    (directory / 'analysis.json').write_text(json.dumps(result, indent=2) + '\n')
    (directory / 'summary.md').write_text('\n'.join(lines) + '\n')
    print('\n'.join(lines))
    print(f'Profiler stalls: {len(stalls)}; artifacts: {directory}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'out/terminal-hlprof/instrument')
    parser.add_argument('--analyze-only', action='store_true')
    args = parser.parse_args()
    directory = args.output.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    if not args.analyze_only:
        (directory / 'capture').mkdir(exist_ok=True)
        env = dict(os.environ, LIBGL_ALWAYS_SOFTWARE='1', EXOSUIT_TERMINAL_PROGRESS_REPEATS='1',
                   XDG_STATE_HOME=str(directory / 'state'), PRAGTICAL_PORTABLE=str(directory / 'settings'))
        command = ['xvfb-run', '-a', '-s', '-screen 0 1280x900x24', str(ROOT / 'haxeon/scripts/haxeon'),
                   'run', '--project', str(ROOT / 'tests/terminal-render-benchmark/haxeon.json'),
                   '--profile=instrument,sampling', '--profile-min-call=10',
                   '--profile-output', str(directory / 'profile.hlpc'), '--', str(directory / 'capture')]
        with (directory / 'run.log').open('w') as log:
            subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    analyze(directory)


if __name__ == '__main__':
    main()
