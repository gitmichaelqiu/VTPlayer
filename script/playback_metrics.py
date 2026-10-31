#!/usr/bin/env python3
"""Collect VTPlayer's existing playback diagnostics for a running process."""
import argparse
import json
import re
import statistics
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--pid', type=int, required=True, help='PID of the VTPlayer instance')
parser.add_argument('--seconds', type=int, default=20, help='capture duration (at least 6 seconds recommended)')
args = parser.parse_args()
if args.seconds <= 0:
    parser.error('--seconds must be positive')
try:
    subprocess.run(['kill', '-0', str(args.pid)], check=True, capture_output=True)
except subprocess.CalledProcessError:
    sys.exit('Process is not running or is inaccessible')

command = ['/usr/bin/log', 'stream', '--style', 'compact', '--level', 'info',
           '--predicate', f'processIdentifier == {args.pid}']
process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    output, errors = process.communicate(timeout=args.seconds)
except subprocess.TimeoutExpired:
    process.terminate()
    output, errors = process.communicate()
if process.returncode not in (0, -15):
    sys.exit(f'Log capture failed: {errors.strip()}')

prefix = re.compile(r'\b(RENDER-CADENCE|RENDER-INTERVALS|CACHE-PRESENTATION|DIAG|PERF|CACHE|RENDER|FI):\s*(.*)')
pair = re.compile(r'([\w]+)=([^\s]+)')
records = []
for line in output.splitlines():
    match = prefix.search(line)
    if match:
        records.append({'category': match.group(1), 'fields': dict(pair.findall(match.group(2))), 'message': match.group(2)})
samples = {}
for record in records:
    for key, value in record['fields'].items():
        try:
            number = float(value)
        except ValueError:
            continue
        samples.setdefault(f"{record['category']}.{key}", []).append(number)
statistics_by_field = {
    key: {'count': len(values), 'median': statistics.median(values),
          'min': min(values), 'max': max(values)}
    for key, values in samples.items()
}
summary = {'pid': args.pid, 'durationSeconds': args.seconds,
           'statistics': statistics_by_field, 'records': records,
           'note': 'Only emitted diagnostics are reported; missing data is not zero. Audio/video output sync is not measured.'}
print(json.dumps(summary, indent=2))
if not records:
    print('No playback diagnostics captured. Play an enhanced video for at least 6 seconds and retry.', file=sys.stderr)
    sys.exit(2)
