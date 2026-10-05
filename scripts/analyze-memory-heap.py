#!/usr/bin/env python3
"""Classify a workload's final HashLink heap and Linux resident mappings.

Run after measure-memory-workload.py --heap-dump. Heap capacity is virtual
capacity; live block sizes include allocation rounding. Mixed mappings cannot
be split accurately from smaps and are reported separately.
"""
import argparse
import collections
import json
import re
import struct
from pathlib import Path


def analyze(directory):
    pages = []
    heap = collections.Counter()
    with (directory / 'startup.heap').open('rb') as dump:
        if dump.read(4) != b'HMD1':
            raise ValueError('expected a HashLink HMD1 heap dump')

        def read(fmt):
            return struct.unpack('<' + fmt, dump.read(struct.calcsize('<' + fmt)))[0]

        flags = read('i')
        pointer = 'Q' if flags & 1 else 'I'
        heap['metadataBytes'] = read('i')
        heap['markStackBytes'] = read('i')
        count = read('i')
        for _ in range(count):
            base, kind, size = read(pointer), read('i'), read('i')
            read('i')  # Per-page private metadata, included in the header total.
            pages.append((base, base + size))
            live = 0
            while read(pointer):
                length = read('i')
                live += length
                if kind & 2 and length >= struct.calcsize(pointer):
                    read(pointer)
            heap['capacityBytes'] += size
            heap['liveBytes'] += live
            heap['emptyPageCapacityBytes' if live == 0 else 'unusedOccupiedPageCapacityBytes'] += size if live == 0 else size - live
            if not kind & 2:
                dump.seek(size, 1)
        heap['pages'] = count

    mappings = []
    for line in (directory / 'final-idle-gc.smaps').read_text().splitlines():
        match = re.match(r'^([0-9a-f]+)-([0-9a-f]+)\s+(\S+)\s+\S+\s+\S+\s+\S+\s*(.*)', line)
        if match:
            start, end, permissions, name = match.groups()
            mappings.append(dict(start=int(start, 16), end=int(end, 16), permissions=permissions, name=name))
        elif ':' in line and mappings:
            key, value = line.split(':', 1)
            words = value.split()
            if words and words[0].isdigit():
                mappings[-1][key] = int(words[0]) * 1024

    groups = collections.defaultdict(collections.Counter)
    for mapping in mappings:
        name = mapping['name']
        covered = sum(max(0, min(mapping['end'], end) - max(mapping['start'], start)) for start, end in pages)
        if covered == mapping['end'] - mapping['start']:
            category = 'managedHeap'
        elif covered:
            category = 'mixedManagedAndNative'
        elif name == '[heap]':
            category = 'nativeMallocMainHeap'
        elif not name and 'x' in mapping['permissions']:
            category = 'anonymousExecutable'
        elif not name:
            category = 'otherAnonymousNative'
        elif name.startswith('[stack'):
            category = 'stack'
        elif name.startswith('/dev/') or 'memfd:' in name:
            category = 'deviceOrSharedBuffers'
        else:
            category = 'otherFileMappings'
        groups[category].update({key + 'Bytes': mapping.get(key, 0) for key in ('Rss', 'Pss', 'Size', 'Swap')})
    return dict(heap=heap, residentMappings=groups,
                note='Heap capacity and allocator statistics overlap resident mappings; do not add them to RSS. Mixed mappings are not apportioned.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    print(json.dumps(analyze(args.directory), indent=2))
