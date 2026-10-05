#!/usr/bin/env python3
"""Build and measure an isolated graphical workload. Linux /proc is required."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--runs', type=int, default=3)
parser.add_argument('--cycles', type=int, default=10)
parser.add_argument('--skip-build', action='store_true')
parser.add_argument('--heap-dump', action='store_true', help='Dump the retained managed heap after final cleanup')
args = parser.parse_args()
if not 1 <= args.cycles <= 1000 or args.runs < 1:
    parser.error("cycles must be 1..1000 and runs must be positive")
root = Path(__file__).resolve().parents[1]
haxeon = Path(os.environ.get('HAXEON_ROOT', root / 'haxeon'))
project = root / 'tests/memory-workload'
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=False)
fixtures = output / 'fixtures'
fixtures.mkdir()
for index in range(12):
    count = 20000 if index == 11 else 300
    (fixtures / f'file-{index}.txt').write_text(''.join(
        f'line {line}: workload needle file {index} with some text to shape and scroll\n'
        for line in range(count)))
if not args.skip_build:
    subprocess.run([str(haxeon / 'scripts/haxeon'), 'build', '--project', str(project / 'haxeon.json')], check=True)
results = []
for run in range(1, args.runs + 1):
    directory = output / f'run-{run}'
    directory.mkdir()
    state = directory / 'state'
    state.mkdir()
    env = os.environ.copy()
    env.pop('EXOSUIT_STARTUP_MEMORY_STOP_AT', None)
    env.pop('LD_PRELOAD', None)
    env.pop('EXOSUIT_WORKLOAD_HEAP_DUMP', None)
    if args.heap_dump:
        env['EXOSUIT_WORKLOAD_HEAP_DUMP'] = '1'
    env.update(PRAGTICAL_PORTABLE=str(state), HAXEON_ROOT=str(haxeon),
               LD_LIBRARY_PATH=':'.join([str(haxeon / 'out'), str(haxeon / '.tools/hashlink')] +
               [str(project / 'build/host/native' / item) for item in ['exosuit-ui-native', 'pluginhost', 'terminalkit']]))
    started = time.monotonic()
    with (directory / 'app.log').open('w') as log:
        process = subprocess.Popen([str(haxeon / '.tools/hashlink/hl'), str(project / 'build/host/main.hl'),
                                    str(fixtures), str(directory), str(args.cycles)], cwd=root / 'graphical', env=env,
                                   stdout=log, stderr=subprocess.STDOUT)
        peak_rss = 0
        while process.poll() is None:
            try:
                status = Path(f'/proc/{process.pid}/status').read_text()
                match = re.search(r'^VmRSS:\s+(\d+)', status, re.M)
                if match:
                    peak_rss = max(peak_rss, int(match.group(1)) * 1024)
            except FileNotFoundError:
                pass
            if time.monotonic() - started > max(240, args.cycles * 8):
                process.kill()
                process.wait()
                raise RuntimeError('workload exceeded its cycle-scaled timeout')
            time.sleep(.05)
        if process.returncode:
            raise RuntimeError(f'workload failed: {directory / "app.log"}')
    samples = []
    for path in directory.glob('*.json'):
        if not path.with_suffix('.rollup').exists():
            continue
        counters = json.loads(path.read_text())
        rollup = path.with_suffix('.rollup').read_text()
        for key in ['Rss', 'Pss', 'Private_Dirty', 'Private_Clean']:
            counters[key + 'Bytes'] = int(re.search(r'^' + key + r':\s+(\d+)', rollup, re.M).group(1)) * 1024
        counters['ui'] = json.loads(path.with_suffix('.ui.json').read_text())
        samples.append(counters)
    expected_samples = 4 + args.cycles * 3
    if len(samples) != expected_samples:
        raise RuntimeError(f'expected {expected_samples} checkpoints, got {len(samples)}')
    results.append(dict(run=run, cycles=args.cycles, elapsedSeconds=time.monotonic()-started, peakRssBytes=peak_rss, samples=samples))
    (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print(f'run {run} complete, peak RSS {peak_rss / 1048576:.1f} MiB', flush=True)
