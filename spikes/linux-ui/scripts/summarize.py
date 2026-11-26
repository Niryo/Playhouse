#!/usr/bin/env python3
"""Turns out/perf/results*.jsonl (one JSON line per probe event per run) into
markdown tables: median and worst over runs for each library and test.
Usage: summarize.py results.jsonl [results-fork.jsonl ...]"""
import json
import statistics
import sys
from collections import defaultdict

rows = [json.loads(line) for path in sys.argv[1:] for line in open(path) if line.strip()]
LIBS = {
    "scui": "SwiftCrossUI",
    "scui-fork-plain": "SwiftCrossUI fork",
    "scui-fork-granular": "SwiftCrossUI fork, granular card",
    "scui-fork-granular+lazy": "SwiftCrossUI fork, granular card, LazyVStack board",
    "scui-fork-plain+noanim": "SwiftCrossUI fork (animations off)",
    "scui-fork-granular+noanim": "SwiftCrossUI fork, granular card (animations off)",
    "scui-fork-granular+lazy+noanim": "SwiftCrossUI fork, granular card, LazyVStack board (animations off)",
    "adwaita": "Adwaita for Swift",
}
LIBS = {lib: name for lib, name in LIBS.items() if any(r["lib"] == lib for r in rows)}


def by(test, event):
    groups = defaultdict(list)
    for row in rows:
        if row["test"] == test and row["event"] == event:
            groups[row["lib"]].append(row)
    return groups


def med_worst(values, worst=max, fmt="{:.0f}"):
    if not values:
        return "n/a"
    return f"{fmt.format(statistics.median(values))} / {fmt.format(worst(values))}"


print("### Startup (ms from exec to frame; MB resident after first content frame)\n")
print("| Library | Cards | First frame (median / worst) | Content laid out (median / worst) | RSS MB (median / worst) | Runs |")
print("|---|---:|---:|---:|---:|---:|")
for cards in (50, 500, 2000):
    test = f"startup-{cards}"
    first, content = by(test, "first_frame"), by(test, "content_frame")
    report = by(test, "startup")
    for lib, name in LIBS.items():
        if lib not in report and lib not in content:
            continue
        f = [r["ms"] for r in first.get(lib, [])]
        c = [r["ms"] for r in content.get(lib, [])]
        rss = [r["hwm_kb"] / 1024 for r in report.get(lib, [])]
        print(f"| {name} | {cards} | {med_worst(f)} | {med_worst(c)} | {med_worst(rss)} | {len(report.get(lib, []))} |")

print("\n### Scrolling 500 cards (40 px per frame, down and back; frame times in ms)\n")
print("| Library | Frames | Interval median | Interval p95 | Interval worst | Work median | Work p95 | Frames > 33 ms | Runs |")
print("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
for lib, name in LIBS.items():
    runs = by("scroll-500", "scroll").get(lib, [])
    if not runs:
        if lib == "scui" or lib == "adwaita":
            print(f"| {name} | n/a |||||||  0 |")
        continue
    pick = lambda key, stat: statistics.median(r[key][stat] for r in runs if r[key]["n"])
    worst = max(r["interval_ms"]["max"] for r in runs)
    frames = statistics.median(r["interval_ms"]["n"] for r in runs)
    print(f"| {name} | {frames:.0f} | {pick('interval_ms', 'median'):.1f} | {pick('interval_ms', 'p95'):.1f} | {worst:.0f} | "
          f"{pick('work_ms', 'median'):.1f} | {pick('work_ms', 'p95'):.1f} | see p95/p99 | {len(runs)} |")

print("\n### Live updates (board of 100 cards, all updating usage + tokens, plus the clock, 10x per second for 30 s)\n")
print("| Library | Ticks done of 300 (median) | Frames painted (median) | CPU % (median / worst) | Model mutation ms (median / worst) | Update → frame latency ms (median / p95 / worst) | Frame work ms (median / p95) | Runs |")
print("|---|---:|---:|---:|---:|---:|---:|---:|")
for lib, name in LIBS.items():
    summary = by("live-100", "live_summary").get(lib, [])
    live = by("live-100", "live").get(lib, [])
    if not summary:
        continue
        continue
    ticks = statistics.median(r["ticks"] for r in summary)
    cpu = [r["cpu_percent"] for r in summary]
    mut = [r["mutation_median_ms"] for r in summary]
    mut_worst = max(r["mutation_max_ms"] for r in summary)
    lat = [r["latency_ms"] for r in live if r["latency_ms"]["n"]]
    work = [r["work_ms"] for r in live if r["work_ms"]["n"]]
    lat_text = (f"{statistics.median(l['median'] for l in lat):.1f} / {statistics.median(l['p95'] for l in lat):.1f} / "
                f"{max(l['max'] for l in lat):.0f}") if lat else "n/a"
    work_text = f"{statistics.median(w['median'] for w in work):.1f} / {statistics.median(w['p95'] for w in work):.1f}" if work else "n/a"
    frames = statistics.median(r["interval_ms"].get("n", 0) for r in live) if live else 0
    print(f"| {name} | {ticks:.0f} | {frames:.0f} | {med_worst(cpu, fmt='{:.1f}')} | {statistics.median(mut):.2f} / {mut_worst:.1f} | {lat_text} | {work_text} | {len(summary)} |")
