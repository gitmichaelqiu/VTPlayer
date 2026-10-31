#!/usr/bin/env python3
"""Capture a reproducible VTPlayer diagnostic window as JSON."""
import argparse
import datetime
import json
import math
import os
import platform
import re
import statistics
import subprocess
import sys
import threading
import time

PREFIX = re.compile(r'\b(PLAYBACK-METRICS|RENDER-CADENCE|RENDER-INTERVALS|CACHE-PRESENTATION|DIAG|PERF|CACHE|RENDER|FI):\s*(.*)')
PAIR = re.compile(r'([\w]+)=([^\s]+)')


def command(*args):
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=5)
        return result.stdout.strip() if result.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def describe(values):
    values = sorted(values)
    return {'count': len(values), 'median': statistics.median(values), 'min': values[0],
            'max': values[-1], 'p95': values[math.ceil(len(values) * .95) - 1]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', type=int, help='VTPlayer PID; required for CPU and memory sampling')
    parser.add_argument('--log-file', help='Read appended output from a redirected VTPlayer process')
    parser.add_argument('--seconds', type=int, default=30, help='capture duration')
    parser.add_argument('--label', default='', help='scenario label, including video and enhancements')
    parser.add_argument('--compare', help='previous JSON report to compare median values')
    args = parser.parse_args()
    if not args.pid and not args.log_file:
        parser.error('provide --pid, --log-file, or both')
    if args.seconds <= 0:
        parser.error('--seconds must be positive')
    if args.pid and command('/bin/ps', '-p', str(args.pid), '-o', 'pid=') is None:
        sys.exit('Process is not running or is inaccessible')

    resources = []
    done = threading.Event()
    def sample_resources():
        while not done.is_set():
            output = command('/bin/ps', '-p', str(args.pid), '-o', '%cpu=,rss=')
            if output:
                try:
                    cpu, rss = output.split()
                    resources.append({'elapsedSeconds': round(time.monotonic() - start, 2),
                                      'cpuPercent': float(cpu), 'residentMB': int(rss) / 1024})
                except ValueError:
                    pass
            done.wait(1)

    start = time.monotonic()
    sampler = None
    if args.pid:
        sampler = threading.Thread(target=sample_resources, daemon=True)
        sampler.start()
    try:
        if args.log_file:
            with open(args.log_file, encoding='utf-8', errors='replace') as stream:
                stream.seek(0, os.SEEK_END)
                time.sleep(args.seconds)
                output = stream.read()
        else:
            process = subprocess.Popen(['/usr/bin/log', 'stream', '--style', 'compact', '--level', 'info',
                '--predicate', f'processIdentifier == {args.pid}'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                output, errors = process.communicate(timeout=args.seconds)
            except subprocess.TimeoutExpired:
                process.terminate()
                output, errors = process.communicate()
            if process.returncode not in (0, -15):
                sys.exit(f'Log capture failed: {errors.strip()}')
    finally:
        done.set()
        if sampler:
            sampler.join(timeout=6)

    records = []
    samples = {}
    for line in output.splitlines():
        match = PREFIX.search(line)
        if not match:
            continue
        category, message = match.groups()
        fields = dict(PAIR.findall(message))
        records.append({'category': category, 'fields': fields, 'message': message})
        for key, value in fields.items():
            if category == 'PLAYBACK-METRICS' and key == 'audioVideoOffsetSeconds' and fields.get('audioClockAvailable') != '1':
                continue
            try:
                number = float(value)
                if number == number and abs(number) != float('inf'):
                    samples.setdefault(f'{category}.{key}', []).append(number)
            except ValueError:
                pass
    for key in ('cpuPercent', 'residentMB'):
        if resources:
            samples['process.' + key] = [item[key] for item in resources]
    stats = {key: describe(values) for key, values in samples.items()}
    comparison = {}
    if args.compare:
        with open(args.compare, encoding='utf-8') as stream:
            baseline = json.load(stream)
        for key, value in stats.items():
            previous = baseline.get('statistics', {}).get(key, {}).get('median')
            if isinstance(previous, (int, float)):
                comparison[key] = {'baselineMedian': previous, 'currentMedian': value['median'],
                                   'difference': value['median'] - previous}
    categories = {record['category'] for record in records}
    checks = {'diagnosticsCaptured': bool(records), 'playbackSamples': 'DIAG' in categories,
              'cadenceSamples': 'RENDER-CADENCE' in categories,
              'audioClockSamples': 'PLAYBACK-METRICS.audioVideoOffsetSeconds' in stats,
              'processSamples': bool(resources),
              'presentationCallbacksObserved': stats.get('RENDER-CADENCE.actualHz', {}).get('max', 0) > 0}
    report = {'schemaVersion': 1, 'capturedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'label': args.label, 'pid': args.pid, 'logFile': args.log_file, 'durationSeconds': args.seconds,
              'environment': {'macOS': platform.mac_ver()[0], 'architecture': platform.machine(),
                              'hardware': command('/usr/sbin/sysctl', '-n', 'machdep.cpu.brand_string')},
              'checks': checks, 'statistics': stats, 'comparison': comparison,
              'resources': resources, 'records': records,
              'limitations': ['CPU is percent of one core; RSS excludes some GPU allocations.',
                              'Audio offset compares transport time to submitted video PTS, not audible output or physical presentation.',
                              'Zero actualHz can mean presentation callbacks are unavailable; refresh callbacks are not physical refresh measurements.',
                              'Cache size reflects reported in-memory frame cache, not total disk use.']}
    print(json.dumps(report, indent=2, allow_nan=False))
    if not records:
        print('No playback diagnostics captured. Ensure enhanced playback is active; Xcode may redirect NSLog, so use --log-file.', file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
