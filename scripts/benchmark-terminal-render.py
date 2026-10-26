#!/usr/bin/env python3
"""Repeatable native terminal rendering benchmark; artifacts include every frame."""
import argparse
from collections import defaultdict
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import time


def monitor_process(process, directory):
    """Sample main-thread scheduling/fault counters without attaching a debugger."""
    rows = []
    pid_path = directory / "process-id"
    while process.poll() is None:
        if pid_path.exists():
            try:
                pid = int(pid_path.read_text())
                proc = Path(f"/proc/{pid}")
                # Fields after comm (which can contain spaces) start at field 3.
                fields = (proc / "stat").read_text().rsplit(")", 1)[1].split()
                scheduler = [int(x) for x in (proc / "schedstat").read_text().split()]
                rows.append(dict(at=time.time(), monotonic=time.monotonic(),
                                 state=fields[0], minorFaults=int(fields[7]), majorFaults=int(fields[9]),
                                 rssPages=int(fields[21]), cpuNs=scheduler[0], waitNs=scheduler[1],
                                 wchan=(proc / "wchan").read_text().strip()))
            except (OSError, ValueError, IndexError):
                pass
        time.sleep(.02)
    (directory / "process-timeline.jsonl").write_text("".join(json.dumps(row) + "\n" for row in rows))

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / 'tests/terminal-render-benchmark/haxeon.json'
BUILD = ROOT / 'build/terminal-render-benchmark/host'


def analyze_stalls(directory, state, timeline):
    samples = state['samples']
    process_rows = [json.loads(line) for line in (directory / 'process-timeline.jsonl').read_text().splitlines()]
    candidates = []
    worst_frame = max(timeline, key=lambda row: row['frameSeconds'])['frame']
    for sample, timing in zip(samples, timeline):
        if timing['frameSeconds'] < .05 and timing['frame'] != worst_frame:
            continue
        start = timing['startedAtSeconds']
        end = start + timing['frameSeconds']
        before = next((row for row in reversed(process_rows) if row['at'] <= start), None)
        after = next((row for row in process_rows if row['at'] >= end), None)
        evidence = None
        if before is not None and after is not None:
            inside = [row for row in process_rows if start <= row['at'] <= end]
            evidence = dict(bracketMs=(after['monotonic'] - before['monotonic']) * 1000,
                            cpuMs=(after['cpuNs'] - before['cpuNs']) / 1e6,
                            runQueueMs=(after['waitNs'] - before['waitNs']) / 1e6,
                            majorFaults=after['majorFaults'] - before['majorFaults'],
                            minorFaults=after['minorFaults'] - before['minorFaults'],
                            sampledStates=sorted(set(row['state'] + ':' + row['wchan'] for row in inside)))
        candidates.append(dict(sample=sample, timing=timing, processEvidence=evidence))
    analysis = dict(thresholdMs=50, sampleIntervalMs=20,
                    note='Process counters bracket the frame and can include neighboring work; thread CPU is measured directly within polling. Major faults include file-backed reads as well as swap-in.',
                    worstPoll=max(samples, key=lambda row: row['pollMs']),
                    stressMaxPoll=state.get('stressMaxPoll'), stressSlowPolls=state.get('stressSlowPolls', []),
                    slowFrames=candidates)
    (directory / 'stall-analysis.json').write_text(json.dumps(analysis, indent=2) + '\n')


def percentile(values, fraction):
    values = sorted(values)
    position = (len(values) - 1) * fraction
    lo = int(position)
    return values[lo] + (values[min(lo + 1, len(values) - 1)] - values[lo]) * (position - lo)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--row-cache', choices=('default', 'raster', 'none'), default='default',
                        help='Override terminal row raster caching for comparison')
    parser.add_argument('--progress-repeats', type=int, default=1,
                        help='Poll the progress sequence N times per frame for content stress testing')
    parser.add_argument('--output', type=Path, default=ROOT / 'out/terminal-render-benchmark')
    parser.add_argument('--skip-build', action='store_true')
    parser.add_argument('--diagnose', action='store_true', help='Sample Linux scheduling and page faults every 20 ms')
    parser.add_argument('--display', action='store_true', help='Use existing DISPLAY instead of isolated Xvfb')
    parser.add_argument('--hardware', action='store_true', help='Allow hardware OpenGL on the existing display')
    args = parser.parse_args()
    if args.hardware and not args.display:
        parser.error('--hardware requires --display')
    if args.runs < 1 or args.progress_repeats < 1:
        parser.error('--runs and --progress-repeats must be positive')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if not args.skip_build:
        with (output / 'build.log').open('w') as log:
            subprocess.run([str(ROOT / 'haxeon/scripts/haxeon'), 'build', '--project', str(PROJECT)],
                           cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
    libraries = [ROOT / 'haxeon/out', ROOT / 'haxeon/.tools/hashlink',
                 *sorted(path for path in (BUILD / 'native').iterdir() if path.is_dir())]
    environment = dict(os.environ, LD_LIBRARY_PATH=os.pathsep.join(map(str, libraries)),
                       LIBGL_ALWAYS_SOFTWARE='0' if args.hardware else '1',
                       EXOSUIT_TERMINAL_PROGRESS_REPEATS=str(args.progress_repeats),
                       EXOSUIT_TERMINAL_ROW_CACHE=args.row_cache)
    prefix = [] if args.display else ['xvfb-run', '-a', '-s', '-screen 0 1280x900x24']
    renderer = subprocess.run([*prefix, 'glxinfo', '-B'], env=environment, capture_output=True, text=True)
    metadata = dict(platform=platform.platform(), cpu=platform.processor(),
                    cpuCount=os.cpu_count(), softwareRendering=not args.hardware, isolatedXvfb=not args.display,
                    renderer=renderer.stdout, runs=args.runs, viewport=[1100, 700],
                    timestamp=time.strftime('%Y-%m-%dT%H:%M:%S%z'),
                    rowCache=args.row_cache,
                    scope='Native TerminalPane + real emulator/session + desktop UI rendering; deterministic echo backend; excludes PTY/RPC, shell and physical input latency')
    metadata['revision'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    metadata['workingTree'] = subprocess.check_output(['git', 'status', '--short'], cwd=ROOT, text=True)
    groups = defaultdict(list)
    per_run = []
    for run in range(args.runs):
        directory = output / f'run-{run + 1}'
        directory.mkdir(exist_ok=True)
        env = dict(environment, XDG_STATE_HOME=str(directory / 'state'),
                   PRAGTICAL_PORTABLE=str(directory / 'settings'))
        command = [*prefix, str(ROOT / 'haxeon/.tools/hashlink/hl'), str(BUILD / 'main.hl'), str(directory)]
        with (directory / 'app.log').open('w') as log:
            if args.diagnose:
                import threading
                (directory / 'process-id').unlink(missing_ok=True)
                process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
                watcher = threading.Thread(target=monitor_process, args=(process, directory), daemon=True)
                watcher.start()
                try:
                    process.wait(timeout=180)
                except subprocess.TimeoutExpired:
                    process.terminate()
                    process.wait(timeout=10)
                    raise
                finally:
                    watcher.join(timeout=5)
                if process.returncode:
                    raise subprocess.CalledProcessError(process.returncode, command)
            else:
                subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT,
                               check=True, timeout=180)
        state = json.loads((directory / 'app-state.json').read_text())
        timeline = [json.loads(line) for line in (directory / 'frame-timeline.jsonl').read_text().splitlines()]
        if args.diagnose:
            analyze_stalls(directory, state, timeline)
        metadata['progressRepeats'] = state.get('progressRepeats', 1)
        metadata['diagnostics'] = args.diagnose
        assert len(state['samples']) == len(timeline) == state['framesPerScenario'] * len(state['scenarios'])
        assert state['columns'] > 80 and state['rows'] > 24, state
        assert state['inputBytes'] == state['framesPerScenario'], state['inputBytes']
        previous = None
        run_groups = defaultdict(list)
        for sample, timing in zip(state['samples'], timeline):
            assert sample['frame'] == timing['frame'], (sample, timing)
            interval = None if previous is None else (timing['startedAtSeconds'] - previous) * 1000
            previous = timing['startedAtSeconds']
            if not sample['measured']:
                continue
            record = dict(sample, totalMs=timing['frameSeconds'] * 1000,
                          paintMs=timing['paintSeconds'] * 1000,
                          submitMs=timing['applicationSubmitSeconds'] * 1000,
                          gcMs=timing['frameGcSeconds'] * 1000,
                          allocatedKiB=timing['allocatedBytes'] / 1024,
                          intervalMs=interval)
            groups[sample['scenario']].append(record)
            run_groups[sample['scenario']].append(record)
        assert all(row['changedRows'] == 0 for row in run_groups['idle']), 'Idle invalidated retained rows'
        assert all(row['changedRows'] <= 2 for row in run_groups['typing']), 'Typing invalidated unrelated rows'
        per_run.append({name: statistics.median(row['totalMs'] for row in rows) for name, rows in run_groups.items()})
        metadata['grid'] = [state['columns'], state['rows']]
        print(f'Completed run {run + 1}/{args.runs}', flush=True)
    results = {}
    for name, rows in groups.items():
        results[name] = dict(samples=len(rows),
                            **{metric: dict(median=statistics.median(row[metric] for row in rows),
                                           p95=percentile([row[metric] for row in rows], .95),
                                           maximum=max(row[metric] for row in rows))
                               for metric in ('totalMs', 'pollMs', 'paintMs', 'submitMs', 'gcMs', 'allocatedKiB', 'intervalMs', 'changedRows')},
                            framesOver16_67ms=sum(row['totalMs'] > 1000 / 60 for row in rows))
    (output / 'results.json').write_text(json.dumps(dict(metadata=metadata, scenarios=results,
                                                       runMedianMs=per_run), indent=2) + '\n')
    lines = ['| Scenario | Frame median / p95 (ms) | Poll median (ms) | Paint median (ms) | Alloc KiB/frame | Changed rows | >16.67ms |',
             '|---|---:|---:|---:|---:|---:|---:|']
    for name, result in results.items():
        lines.append(f"| {name} | {result['totalMs']['median']:.2f} / {result['totalMs']['p95']:.2f} | "
                     f"{result['pollMs']['median']:.2f} | {result['paintMs']['median']:.2f} | "
                     f"{result['allocatedKiB']['median']:.0f} | {result['changedRows']['median']:.0f} | "
                     f"{result['framesOver16_67ms']}/{result['samples']} |")
    report = '\n'.join(lines) + '\n'
    (output / 'summary.md').write_text(report)
    print(report)
    print(f'Artifacts: {output}')


if __name__ == '__main__':
    main()
