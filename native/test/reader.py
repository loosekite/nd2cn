#!/usr/bin/env python3
"""Plays the dashboard page: reads the JSON file every 40 ms and reports
what it saw. usage: reader.py FILE SECONDS [START_DELAY]"""
import json
import sys
import time

path, seconds = sys.argv[1], float(sys.argv[2])
time.sleep(float(sys.argv[3]) if len(sys.argv) > 3 else 0)
t0 = time.time()
reads = bad = idle = 0
seqs = []
times = []
last = None
first_active = None
brakes = []
while time.time() - t0 < seconds:
    reads += 1
    try:
        with open(path) as f:
            text = f.read()
        o = json.loads(text)
    except (OSError, ValueError):
        bad += 1
        time.sleep(0.04)
        continue
    if o.get("idle"):
        idle += 1
    elif not seqs or o["seq"] != seqs[-1]:
        if first_active is None:
            first_active = time.time() - t0
        seqs.append(o["seq"])
        times.append(time.time())
        last = o
        # the brake as the page gets it: switch, pressure, its zero and the highest seen
        b = (o.get("brake"), o.get("brake_p"), o.get("brake_p0"), o.get("brake_pmax"))
        if not brakes or brakes[-1][1:] != b:
            brakes.append((round(time.time() - t0, 1),) + b)
    time.sleep(0.04)
gaps = [round((b - a) * 1000) for a, b in zip(times, times[1:])]
span = (times[-1] - times[0]) if len(times) > 1 else 0
print("reads=%d unreadable=%d idle_reads=%d samples=%d first_sample_after=%s" % (
    reads, bad, idle, len(seqs), "%.2fs" % first_active if first_active is not None else "never"))
if span:
    print("sample rate=%.1f/s  gap ms: min=%d median=%d max=%d  seq skipped=%d" % (
        (len(times) - 1) / span, min(gaps), sorted(gaps)[len(gaps) // 2], max(gaps),
        (seqs[-1] - seqs[0] + 1) - len(seqs)))
print("last:", json.dumps(last, separators=(",", ":")))
print("brake (s, switch, pressure, zero, highest):", " ".join("%s:%s/%s/%s/%s" % x for x in brakes))
print("sample bytes:", len(json.dumps(last, separators=(",", ":"))) if last else 0)
