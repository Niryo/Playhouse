#!/usr/bin/env python3
"""Summarizes the atom-tree spike's benchmark runs (docs/atom-tree-performance.md).

Usage: summarize-atom-spike.py task-item|transcript DIR

Reads DIR/<scenario>-<variant>-run-<n>.json, writes DIR/summary.json with every numeric
metric's median and worst (largest) value per scenario and variant, and prints Markdown tables
of the main metrics: "median (worst)" per variant.
"""
import glob
import json
import os
import re
import statistics
import sys

ROWS = {
    "task-item": {
        "open": [
            ("Open: first frame (ms)", "open.totalMs"),
            ("Open: main-thread CPU (ms)", "open.cpuMs"),
            ("Open: memory added (MB)", "open.footprintDeltaMB"),
            ("Open: atom view bodies", "open.atomViewBodies"),
            ("Open: tree node bodies", "open.nodeBodies"),
            ("Open: prop decodes", "open.decodes"),
            ("Scroll: frame work median (ms)", "scroll.frameWork.median"),
            ("Scroll: frame work p95 (ms)", "scroll.frameWork.p95"),
            ("Scroll: longest frame (ms)", "scroll.frameWork.max"),
            ("Scroll: hitches (>16.7 ms)", "scroll.hitchCount"),
            ("Scroll: main-thread CPU (ms)", "scroll.cpuMs"),
            ("Memory after scroll (MB)", "afterScrollFootprintMB"),
            ("Peak memory (MB)", "peakFootprintMB"),
        ],
        "live": [
            ("Update work median (ms)", "live.updateWork.median"),
            ("Update work p95 (ms)", "live.updateWork.p95"),
            ("Update work max (ms)", "live.updateWork.max"),
            ("Main-thread busy per update, median (ms)", "live.busyPerUpdate.median"),
            ("Frame work p95 (ms)", "live.frameWork.p95"),
            ("Hitches in 30 s (>16.7 ms)", "live.hitchCount"),
            ("Main-thread CPU (%)", "live.mainThreadPercent"),
            ("Atom view bodies per update", "live.atomViewBodiesPerUpdate"),
            ("Prop decodes per update", "live.decodesPerUpdate"),
            ("Spec build total (ms)", "phases.specMs"),
            ("Reconcile total (ms)", "phases.reconcileMs"),
            ("Memory after (MB)", "afterLiveFootprintMB"),
        ],
        "interaction": [
            ("Idle: main-thread CPU (%)", "idle.mainThreadPercent"),
            ("Idle: atom view bodies per second", "idle.atomViewBodiesPerSecond"),
            ("Press to open action, median (ms)", "pressToAction.median"),
            ("Presses registered (of 36)", "pressedCards"),
            ("Hover move + frame, median (ms)", "hover.median"),
            ("Hover move + frame, max (ms)", "hover.max"),
            ("Press to open action + frame, median (ms)", "press.median"),
            ("Press, max (ms)", "press.max"),
            ("Right-click to menu shown, median (ms)", "menu.median"),
            ("Right-click to menu shown, max (ms)", "menu.max"),
            ("Drag preview render, median (ms)", "dragPreview.median"),
            ("Drag preview render, max (ms)", "dragPreview.max"),
        ],
    },
    "transcript": {
        "open": [
            ("Open: first screen (ms)", "open.totalMs"),
            ("Open: main-thread CPU (ms)", "open.cpuMs"),
            ("Open: build tree / spec (ms)", "open.buildMs"),
            ("Open: tree nodes", "open.nodes"),
            ("Open: memory added (MB)", "open.footprintDeltaMB"),
            ("Open: atom view bodies", "open.atomViewBodies"),
            ("Scroll to top: frame work median (ms)", "scrollUp.frameWork.median"),
            ("Scroll to top: frame work p95 (ms)", "scrollUp.frameWork.p95"),
            ("Scroll to top: longest frame (ms)", "scrollUp.frameWork.max"),
            ("Scroll to top: hitches", "scrollUp.hitchCount"),
            ("Scroll back down: frame work p95 (ms)", "scrollDown.frameWork.p95"),
            ("Scroll back down: hitches", "scrollDown.hitchCount"),
            ("Select all in a long message (ms)", "selection.selectAllMs"),
            ("Drag-select step, median (ms)", "selection.step.median"),
            ("Drag-select step, max (ms)", "selection.step.max"),
            ("Expand/collapse a tool call + frame, median (ms)", "toggle.median"),
            ("Expand/collapse, max (ms)", "toggle.max"),
            ("Jump to bottom (ms)", "jumpToBottom.ms"),
            ("Memory after scroll (MB)", "afterScrollFootprintMB"),
            ("Peak memory (MB)", "peakFootprintMB"),
        ],
        "stream": [
            ("Update work median (ms)", "stream.updateWork.median"),
            ("Update work p95 (ms)", "stream.updateWork.p95"),
            ("Update work max (ms)", "stream.updateWork.max"),
            ("Main-thread busy per update, median (ms)", "stream.busyPerUpdate.median"),
            ("Hitches in 60 s (>16.7 ms)", "stream.hitchCount"),
            ("Main-thread CPU (%)", "stream.mainThreadPercent"),
            ("Spec build per update, median (ms)", "stream.specWork.median"),
            ("Atom view bodies per update", "stream.atomViewBodiesPerUpdate"),
            ("Prop decodes per update", "stream.decodesPerUpdate"),
            ("Peak memory (MB)", "peakFootprintMB"),
        ],
    },
}

VARIANT_ORDER = ["native", "tree", "tree-dynamic", "tree-full", "tree-blocks"]


def flatten(value, prefix=""):
    if isinstance(value, dict):
        for key, inner in value.items():
            yield from flatten(inner, f"{prefix}.{key}" if prefix else key)
    elif isinstance(value, (int, float)) and not isinstance(value, bool):
        yield prefix, float(value)


def main():
    kind, directory = sys.argv[1], sys.argv[2]
    pattern = re.compile(r"^(?P<scenario>.+)-(?P<variant>native|tree|tree-dynamic|tree-full|tree-blocks)-run-(?P<run>\d+)\.json$")
    groups = {}
    errors = []
    for path in sorted(glob.glob(os.path.join(directory, "*-run-*.json"))):
        match = pattern.match(os.path.basename(path))
        if not match:
            continue
        result = json.load(open(path))
        if "error" in result:
            errors.append(f"{os.path.basename(path)}: {result['error']}")
        groups.setdefault(match["scenario"], {}).setdefault(match["variant"], []).append(result)
    summary = {}
    for scenario, variants in groups.items():
        for variant, results in variants.items():
            columns = {}
            for result in results:
                for key, value in flatten(result):
                    columns.setdefault(key, []).append(value)
            summary.setdefault(scenario, {})[variant] = {
                key: {"median": statistics.median(values), "worst": max(values), "runs": len(values)} for key, values in columns.items()
            }
    json.dump(summary, open(os.path.join(directory, "summary.json"), "w"), indent=2, sort_keys=True)
    print(f"Results in {directory}")
    for scenario in sorted(summary, key=lambda name: (re.sub(r"\d+", "", name), int(re.sub(r"\D", "", name) or 0))):
        variants = [variant for variant in VARIANT_ORDER if variant in summary[scenario]]
        family = "live" if scenario.startswith("live") else "interaction" if scenario.startswith("interaction") else "stream" if scenario.startswith("stream") else "open"
        rows = ROWS[kind][family]
        runs = summary[scenario][variants[0]].get(rows[0][1], {}).get("runs", 0)
        print(f"\n### {scenario} (median of {runs} runs, worst in parentheses)\n")
        print("| Metric | " + " | ".join(variants) + " |")
        print("| --- |" + " ---: |" * len(variants))
        for label, key in rows:
            cells = []
            for variant in variants:
                metric = summary[scenario][variant].get(key)
                cells.append("–" if metric is None else f"{metric['median']:.2f} ({metric['worst']:.2f})")
            if any(cell != "–" for cell in cells):
                print(f"| {label} | " + " | ".join(cells) + " |")
    timeouts_path = os.path.join(directory, "timeouts.tsv")
    if os.path.exists(timeouts_path):
        print("\nRuns that did not finish (no numbers; they are left out of the medians above):\n")
        for line in open(timeouts_path):
            scenario, variant, run, seconds = line.rstrip("\n").split("\t")
            print(f"- {scenario}, {variant}, run {run}: still running after {seconds} s")
    if errors:
        print("\nErrors:\n" + "\n".join(errors))
        sys.exit(1)


if __name__ == "__main__":
    main()
