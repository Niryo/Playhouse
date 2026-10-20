#!/usr/bin/env python3
"""Track xcodebuild UI-test events and render a scrollable live dashboard."""

from __future__ import annotations

import argparse
import curses
import json
import os
import re
import sys
import time
from pathlib import Path
from typing import Any


EVENT_PATTERN = re.compile(
    r"Test Case '.*?\b(?P<case>test_[A-Za-z0-9_]+)\][\"']*\s+"
    r"(?P<event>started|passed|failed|skipped)"
    r"(?: \((?P<duration>[0-9]+(?:\.[0-9]+)?) seconds?\))?\."
)
CASE_PATTERN = re.compile(r"\b(test_[A-Za-z0-9_]+)\b")


def read_state(path: Path) -> dict[str, Any] | None:
    try:
        with path.open(encoding="utf-8") as state_file:
            value = json.load(state_file)
        return value if isinstance(value, dict) else None
    except (OSError, json.JSONDecodeError):
        return None


def write_state(path: Path, state: dict[str, Any]) -> None:
    temporary_path = path.with_name(path.name + ".tmp")
    with temporary_path.open("w", encoding="utf-8") as state_file:
        json.dump(state, state_file, ensure_ascii=False)
        state_file.write("\n")
        state_file.flush()
        os.fsync(state_file.fileno())
    os.replace(temporary_path, path)


def format_duration(seconds: float | int | None) -> str:
    if seconds is None:
        return "—"
    total_seconds = max(0, int(seconds))
    hours, remainder = divmod(total_seconds, 3600)
    minutes, seconds_part = divmod(remainder, 60)
    if hours:
        return f"{hours:02d}:{minutes:02d}:{seconds_part:02d}"
    return f"{minutes:02d}:{seconds_part:02d}"


def initialize(args: argparse.Namespace) -> int:
    with args.contract.open(encoding="utf-8") as contract_file:
        contracts = json.load(contract_file)
    known_cases = [entry["id"] for entry in contracts]
    selected_cases = args.case or known_cases
    if len(selected_cases) != len(set(selected_cases)):
        raise SystemExit("Focused UI test case IDs must be unique.")
    unknown_cases = sorted(set(selected_cases) - set(known_cases))
    if unknown_cases:
        raise SystemExit("Unknown UI test case IDs: " + ", ".join(unknown_cases))

    started_at = time.time()
    state = {
        "suite_status": "starting",
        "started_at": started_at,
        "finished_at": None,
        "active_case": None,
        "cases": [
            {"id": case_id, "status": "queued", "started_at": None, "duration": None}
            for case_id in selected_cases
        ],
        "batches": [],
        "summary": None,
    }
    write_state(args.state_file, state)
    print(len(selected_cases))
    return 0


def track(args: argparse.Namespace) -> int:
    state = read_state(args.state_file)
    if state is None:
        print(f"Could not read dashboard state: {args.state_file}", file=sys.stderr)
        return 2
    cases_by_id = {case["id"]: case for case in state["cases"]}
    state["suite_status"] = "running"
    write_state(args.state_file, state)

    with args.log_file.open("wb") as log_file:
        for raw_line in sys.stdin.buffer:
            log_file.write(raw_line)
            log_file.flush()
            sys.stdout.buffer.write(raw_line)
            sys.stdout.buffer.flush()

            line = raw_line.decode("utf-8", errors="replace")
            match = EVENT_PATTERN.search(line)
            if match is None:
                continue
            case_id = match.group("case")
            test_case = cases_by_id.get(case_id)
            if test_case is None:
                continue

            event = match.group("event")
            now = time.time()
            if event == "started":
                test_case["status"] = "running"
                test_case["started_at"] = now
                state["active_case"] = case_id
                if args.announce:
                    print(f"▶ RUNNING  {case_id}", file=sys.stderr, flush=True)
            else:
                test_case["status"] = event
                reported_duration = match.group("duration")
                if reported_duration is not None:
                    test_case["duration"] = float(reported_duration)
                elif test_case["started_at"] is not None:
                    test_case["duration"] = max(0.0, now - test_case["started_at"])
                if state.get("active_case") == case_id:
                    state["active_case"] = None
                if args.announce:
                    marker = {"passed": "✓ PASS", "failed": "✗ FAIL", "skipped": "– SKIP"}[event]
                    elapsed = format_duration(test_case["duration"])
                    print(f"{marker}  {case_id} ({elapsed})", file=sys.stderr, flush=True)
            write_state(args.state_file, state)

    return 0


def finish(args: argparse.Namespace) -> int:
    state = read_state(args.state_file)
    if state is None:
        print(f"Could not read dashboard state: {args.state_file}", file=sys.stderr)
        return 2

    summary = None
    if args.summary is not None:
        try:
            with args.summary.open(encoding="utf-8") as summary_file:
                summary = json.load(summary_file)
        except (OSError, json.JSONDecodeError):
            summary = None

    failure_cases: set[str] = set()
    if summary:
        for failure in summary.get("testFailures", []):
            match = CASE_PATTERN.search(failure.get("testName", ""))
            if match:
                failure_cases.add(match.group(1))

    cases = state["cases"]
    if args.case:
        expected_cases = args.case
        if len(expected_cases) != len(set(expected_cases)):
            print("Batch UI test case IDs must be unique.", file=sys.stderr)
            return 2
        if len(expected_cases) > 8:
            print("A UI test batch cannot contain more than 8 cases.", file=sys.stderr)
            return 2
        known_cases = {case["id"] for case in cases}
        unknown_cases = sorted(set(expected_cases) - known_cases)
        if unknown_cases:
            print("Unknown batch UI test case IDs: " + ", ".join(unknown_cases), file=sys.stderr)
            return 2
        completed_batch_cases = {
            case_id
            for batch in state.get("batches", [])
            for case_id in batch.get("cases", [])
        }
        repeated_cases = sorted(set(expected_cases) & completed_batch_cases)
        if repeated_cases:
            print("UI cases may appear in only one batch: " + ", ".join(repeated_cases), file=sys.stderr)
            return 2

        batch_passed = bool(
            summary
            and summary.get("result") == "Passed"
            and summary.get("totalTestCount") == len(expected_cases)
            and summary.get("passedTests") == len(expected_cases)
            and summary.get("failedTests", 0) == 0
            and summary.get("skippedTests", 0) == 0
            and args.exit_status == 0
        )
        for test_case in cases:
            if test_case["id"] not in expected_cases:
                continue
            status = test_case["status"]
            if test_case["id"] in failure_cases:
                test_case["status"] = "failed"
            elif status in {"queued", "running"}:
                test_case["status"] = "passed" if batch_passed else "not_run"

        state.setdefault("batches", []).append({
            "cases": expected_cases,
            "passed": batch_passed,
            "result": summary.get("result") if summary else None,
            "total": summary.get("totalTestCount") if summary else None,
            "passed_count": summary.get("passedTests") if summary else None,
            "failed_count": summary.get("failedTests") if summary else None,
            "skipped_count": summary.get("skippedTests") if summary else None,
            "xcodebuild_exit": args.exit_status,
        })
        state["active_case"] = None
        write_state(args.state_file, state)
        return 0

    if state.get("batches"):
        selected_case_ids = [case["id"] for case in cases]
        batched_case_ids = [
            case_id
            for batch in state["batches"]
            for case_id in batch.get("cases", [])
        ]
        exact_batch_coverage = batched_case_ids == selected_case_ids
        for test_case in cases:
            if test_case["status"] in {"queued", "running"}:
                test_case["status"] = "not_run"
        all_cases_passed = bool(cases) and all(case["status"] == "passed" for case in cases)
        all_batches_passed = bool(state["batches"]) and all(batch["passed"] for batch in state["batches"])
        state["suite_status"] = "passed" if exact_batch_coverage and all_cases_passed and all_batches_passed else "failed"
        state["active_case"] = None
        state["finished_at"] = time.time()
        state["summary"] = {
            "result": state["suite_status"].title(),
            "total": len(cases),
            "passed": sum(case["status"] == "passed" for case in cases),
            "failed": sum(case["status"] == "failed" for case in cases),
            "skipped": sum(case["status"] == "skipped" for case in cases),
            "not_run": sum(case["status"] == "not_run" for case in cases),
            "batch_count": len(state["batches"]),
            "exact_batch_coverage": exact_batch_coverage,
        }
        write_state(args.state_file, state)
        return 0

    summary_passed_all = bool(
        summary
        and summary.get("result") == "Passed"
        and summary.get("totalTestCount") == len(cases)
        and summary.get("passedTests") == len(cases)
        and summary.get("failedTests", 0) == 0
        and summary.get("skippedTests", 0) == 0
        and args.exit_status == 0
    )
    for test_case in cases:
        case_id = test_case["id"]
        status = test_case["status"]
        if case_id in failure_cases:
            test_case["status"] = "failed"
        elif status == "queued":
            test_case["status"] = "passed" if summary_passed_all else "not_run"
        elif status == "running":
            if summary_passed_all:
                test_case["status"] = "passed"
            elif args.exit_status != 0:
                test_case["status"] = "failed"
            else:
                test_case["status"] = "not_run"

    counts = {
        status: sum(case["status"] == status for case in cases)
        for status in ("passed", "failed", "skipped", "not_run")
    }
    summary_result = summary.get("result") if summary else None
    expected = len(cases)
    suite_passed = bool(
        summary_passed_all
        and counts["passed"] == expected
        and not counts["failed"]
        and not counts["skipped"]
        and not counts["not_run"]
    )
    state["suite_status"] = "passed" if suite_passed else "failed"
    state["active_case"] = None
    state["finished_at"] = time.time()
    state["summary"] = {
        "result": summary_result,
        "total": summary.get("totalTestCount") if summary else None,
        "passed": summary.get("passedTests") if summary else counts["passed"],
        "failed": summary.get("failedTests") if summary else counts["failed"],
        "skipped": summary.get("skippedTests") if summary else counts["skipped"],
        "xcodebuild_exit": args.exit_status,
    }
    write_state(args.state_file, state)
    return 0


def status_text(test_case: dict[str, Any], now: float) -> tuple[str, str, str]:
    status = test_case["status"]
    started_at = test_case.get("started_at")
    duration = test_case.get("duration")
    if status == "running" and started_at is not None:
        duration_text = format_duration(now - started_at)
    else:
        duration_text = format_duration(duration)
    labels = {
        "queued": ("○", "queued"),
        "running": ("▶", "running"),
        "passed": ("✓", "passed"),
        "failed": ("✗", "failed"),
        "skipped": ("–", "skipped"),
        "not_run": ("—", "not run"),
    }
    return (*labels.get(status, ("?", status)), duration_text)


def draw_text(screen: Any, row: int, column: int, content: str, width: int, color: int = 0) -> None:
    if row < 0 or column >= width or width <= 0:
        return
    try:
        screen.addstr(row, column, content[: max(0, width - column)], color)
    except curses.error:
        pass


def render_dashboard(screen: Any, state_path: Path, follow: bool, scroll: int) -> tuple[int, int, bool]:
    state = read_state(state_path)
    screen.erase()
    height, width = screen.getmaxyx()
    if state is None:
        draw_text(screen, 0, 0, "Waiting for the UI test runner…", width)
        screen.refresh()
        return scroll, 0, False

    now = time.time()
    finished_at = state.get("finished_at")
    elapsed = (finished_at or now) - state.get("started_at", now)
    cases = state.get("cases", [])
    counts = {
        status: sum(case.get("status") == status for case in cases)
        for status in ("passed", "failed", "skipped", "not_run", "running", "queued")
    }
    completed = counts["passed"] + counts["failed"] + counts["skipped"] + counts["not_run"]
    suite_status = state.get("suite_status", "starting")
    title_color = curses.color_pair(2) if suite_status == "failed" else curses.color_pair(1)
    draw_text(screen, 0, 0, f"StationAI visible UI tests · {suite_status.upper()}", width, title_color | curses.A_BOLD)
    progress_line = (
        f"Progress {completed}/{len(cases)}  ✓ {counts['passed']} passed  "
        f"✗ {counts['failed']} failed  ○ {counts['queued']} remaining"
    )
    draw_text(screen, 1, 0, progress_line, width)
    timing_line = (
        f"Elapsed {format_duration(elapsed)}  ·  {counts['skipped']} skipped  ·  "
        f"{counts['not_run']} not run"
    )
    draw_text(screen, 2, 0, timing_line, width)

    active_case = state.get("active_case")
    if active_case:
        test_case = next((item for item in cases if item["id"] == active_case), None)
        active_duration = None
        if test_case and test_case.get("started_at") is not None:
            active_duration = format_duration(now - test_case["started_at"])
        active_line = f"▶ CURRENT: {active_case}  ·  running {active_duration or '00:00'}"
        active_color = curses.color_pair(3) | curses.A_BOLD
    elif suite_status in {"passed", "failed"}:
        active_line = f"UI test process finished with {suite_status.upper()}. Press q to close this dashboard."
        active_color = (curses.color_pair(1) if suite_status == "passed" else curses.color_pair(2)) | curses.A_BOLD
    else:
        active_line = "Waiting for the next XCTest case to start…"
        active_color = curses.A_DIM
    draw_text(screen, 3, 0, active_line, width, active_color)
    if len(cases) > 0:
        draw_text(screen, 4, 0, "Test case                                             status       time", width, curses.A_UNDERLINE)

    list_top = 5
    visible_rows = max(1, height - list_top - 2)
    active_index = next((i for i, item in enumerate(cases) if item["id"] == active_case), None)
    if follow:
        anchor = active_index
        if anchor is None:
            resolved_indexes = [
                index for index, item in enumerate(cases)
                if item["status"] in {"passed", "failed", "skipped", "not_run"}
            ]
            anchor = resolved_indexes[-1] if resolved_indexes else 0
        scroll = max(0, min(anchor - visible_rows + 1, max(0, len(cases) - visible_rows)))
    else:
        scroll = max(0, min(scroll, max(0, len(cases) - visible_rows)))

    colors = {
        "queued": curses.A_DIM,
        "running": curses.color_pair(3) | curses.A_BOLD,
        "passed": curses.color_pair(1),
        "failed": curses.color_pair(2) | curses.A_BOLD,
        "skipped": curses.color_pair(4),
        "not_run": curses.A_DIM,
    }
    for offset, test_case in enumerate(cases[scroll : scroll + visible_rows]):
        row = list_top + offset
        marker, label, duration = status_text(test_case, now)
        color = colors.get(test_case["status"], 0)
        marker_color = color
        draw_text(screen, row, 0, marker, width, marker_color)
        case_width = max(8, width - 26)
        draw_text(screen, row, 2, test_case["id"], case_width, color)
        draw_text(screen, max(0, row), max(3, width - 22), f"{label:>8}  {duration:>8}", width, color)

    if cases:
        end = min(len(cases), scroll + visible_rows)
        range_text = f"Showing {scroll + 1}–{end} of {len(cases)}"
    else:
        range_text = "No UI test cases selected"
    footer = f"{range_text} · ↑/↓ scroll · PgUp/PgDn page · f follow active · q close"
    draw_text(screen, height - 1, 0, footer, width, curses.A_DIM)
    screen.refresh()
    return scroll, visible_rows, suite_status in {"passed", "failed"}


def watch(args: argparse.Namespace) -> int:
    state_path: Path = args.state_file
    result = {"finished": False, "closed_early": False}

    def dashboard(screen: Any) -> None:
        follow = True
        scroll = 0
        screen.keypad(True)
        screen.nodelay(True)
        try:
            curses.curs_set(0)
        except curses.error:
            pass
        if curses.has_colors():
            try:
                curses.start_color()
                curses.use_default_colors()
                curses.init_pair(1, curses.COLOR_GREEN, -1)
                curses.init_pair(2, curses.COLOR_RED, -1)
                curses.init_pair(3, curses.COLOR_CYAN, -1)
                curses.init_pair(4, curses.COLOR_YELLOW, -1)
            except curses.error:
                pass

        while True:
            scroll, visible_rows, finished = render_dashboard(screen, state_path, follow, scroll)
            key = screen.getch()
            if key in (ord("q"), ord("Q")):
                result["closed_early"] = not finished
                result["finished"] = finished
                return
            if key in (curses.KEY_UP, ord("k")):
                follow = False
                scroll -= 1
            elif key in (curses.KEY_DOWN, ord("j")):
                follow = False
                scroll += 1
            elif key == curses.KEY_PPAGE:
                follow = False
                scroll -= max(1, visible_rows)
            elif key == curses.KEY_NPAGE:
                follow = False
                scroll += max(1, visible_rows)
            elif key == curses.KEY_HOME:
                follow = False
                scroll = 0
            elif key == curses.KEY_END:
                follow = False
                scroll = 10**9
            elif key in (ord("f"), ord("F")):
                follow = True
            time.sleep(0.2)

    try:
        curses.wrapper(dashboard)
    except curses.error as error:
        print(f"Dashboard terminal rendering failed: {error}", file=sys.stderr)
        return 1

    state = read_state(state_path)
    if result["closed_early"]:
        print(f"Dashboard closed; UI tests are still running. State: {state_path}")
    elif state is not None:
        cases = state.get("cases", [])
        print(f"StationAI visible UI tests · {state.get('suite_status', 'finished').upper()}")
        for test_case in cases:
            marker, label, duration = status_text(test_case, time.time())
            print(f"{marker} {label:>8}  {duration:>8}  {test_case['id']}")
        print("Use q in the dashboard window to close it.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    init_parser = subparsers.add_parser("init", help="create the initial dashboard state")
    init_parser.add_argument("--state-file", type=Path, required=True)
    init_parser.add_argument("--contract", type=Path, required=True)
    init_parser.add_argument("--case", action="append", default=[])
    init_parser.set_defaults(handler=initialize)

    track_parser = subparsers.add_parser("track", help="parse xcodebuild output from stdin")
    track_parser.add_argument("--state-file", type=Path, required=True)
    track_parser.add_argument("--log-file", type=Path, required=True)
    track_parser.add_argument("--announce", action="store_true")
    track_parser.set_defaults(handler=track)

    finish_parser = subparsers.add_parser("finish", help="reconcile dashboard with xcresult summary")
    finish_parser.add_argument("--state-file", type=Path, required=True)
    finish_parser.add_argument("--exit-status", type=int, required=True)
    finish_parser.add_argument("--summary", type=Path)
    finish_parser.add_argument("--case", action="append", default=[], help="case selected for this Xcode batch")
    finish_parser.set_defaults(handler=finish)

    watch_parser = subparsers.add_parser("watch", help="open the interactive terminal dashboard")
    watch_parser.add_argument("--state-file", type=Path, required=True)
    watch_parser.set_defaults(handler=watch)

    args = parser.parse_args()
    return args.handler(args)


if __name__ == "__main__":
    raise SystemExit(main())
