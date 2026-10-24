#!/usr/bin/env python3
"""Live integration suite for StationAI's real conversation providers.

Shared scenarios run against the provider chosen with --provider or
STATIONAI_LIVE_PROVIDER (claude by default, codex, or all). Scenarios that
exercise one runtime's unique behavior run only for that provider, and the
cross-provider handoff runs only with `all`. Every scenario uses the real
installed CLI and its existing sign-in; nothing is mocked.
"""

import argparse
import fcntl
import json
import os
import plistlib
import queue
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
from pathlib import Path


MARKER_NAME = ".stationai-live-integration-owner"
MARKER_VALUE = "StationAI live integration suite owns this disposable workspace (v1).\n"
BRIDGE_FIXTURE_MARKER_VALUE = "StationAI bridge tests own this deterministic fixture (v1).\n"
WORKTREE_MARKER_VALUE = "StationAI live integration suite owns this worktree root.\n"
PROVIDERS = ("claude", "codex")
MINIMUM_CLAUDE_VERSION = "2.1.296"


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def response_from(completed, command):
    lines = [line for line in completed.stdout.splitlines() if line.strip()]
    require(lines, f"No JSON response for {command}: {completed.stderr}")
    try:
        response = json.loads(lines[-1])
    except json.JSONDecodeError as error:
        raise AssertionError(f"Final CLI output was not JSON: {lines[-1]!r}") from error
    require(completed.returncode == 0 and response.get("ok"), f"{command} failed: {response}")
    return response["result"]


def version_tuple(value):
    return tuple(int(part) for part in value.split()[0].split(".") if part.isdigit())


class StreamingTurn:
    """A `conversation send` whose JSON event lines are read as they arrive."""

    def __init__(self, process):
        self.process = process
        self.events = []
        self.final = None
        self.lines = queue.Queue()
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        for line in self.process.stdout:
            if line.strip():
                self.lines.put(json.loads(line))
        self.lines.put(None)

    def wait_for(self, predicate, timeout, description):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                value = self.lines.get(timeout=0.25)
            except queue.Empty:
                continue
            if value is None:
                self.lines.put(None)
                raise AssertionError(f"The turn ended before {description}: final={self.final}; events={self.events[-5:]}")
            self._record(value)
            if predicate(value):
                return value
        raise AssertionError(f"Timed out waiting for {description}; last events={self.events[-5:]}")

    def finish(self, timeout=600):
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            require(remaining > 0, f"Timed out waiting for the turn to finish; last events={self.events[-5:]}")
            value = self.lines.get(timeout=remaining)
            if value is None:
                break
            self._record(value)
        stderr = self.process.stderr.read() if self.process.stderr else ""
        self.process.wait(timeout=30)
        require(self.final is not None, f"The turn returned no final CLI response: {stderr}")
        return self.process.returncode, self.final

    def _record(self, value):
        if value.get("ok") is not None and "version" in value:
            self.final = value
        else:
            self.events.append(value)


class LiveWorkspace:
    """Disposable copies of the committed fixture repositories plus isolated app data."""

    def __init__(self, provider, fixture, cli, service_name):
        self.provider = provider
        self.cli = cli
        self.root = Path(tempfile.mkdtemp(prefix=f"stationai-live-{provider}-"))
        (self.root / MARKER_NAME).write_text(MARKER_VALUE, encoding="utf-8")
        self.first = self.root / "primary"
        self.second = self.root / "secondary"
        shutil.copytree(fixture / "suggested-parent/primary", self.first)
        shutil.copytree(fixture / "suggested-parent/group/secondary", self.second)
        self.data_directory = self.root / "stationai-data"
        self.data_directory.mkdir()
        self.worktree_directory = self.data_directory / "worktrees"
        self.worktree_directory.mkdir()
        (self.worktree_directory / ".stationai-test-owner").write_text(WORKTREE_MARKER_VALUE, encoding="utf-8")
        self.environment = os.environ.copy()
        self.environment["STATIONAI_DATA_DIRECTORY"] = str(self.data_directory)
        self.environment["STATIONAI_E2E_WORKTREE_DIRECTORY"] = str(self.worktree_directory)
        self.environment["STATIONAI_E2E_DEFAULTS_SUITE"] = f"com.stationai.live-integration.{uuid.uuid4()}"
        self.environment["STATIONAI_BRIDGE_SERVICE_NAME"] = service_name

    def run_cli(self, *command):
        result = subprocess.run(
            [str(self.cli), *map(str, command)],
            check=False, capture_output=True, text=True, env=self.environment, timeout=180,
        )
        return response_from(result, command)

    def run_cli_raw(self, *command):
        result = subprocess.run(
            [str(self.cli), *map(str, command)],
            check=False, capture_output=True, text=True, env=self.environment, timeout=180,
        )
        lines = [line for line in result.stdout.splitlines() if line.strip()]
        require(lines, f"No JSON response for {command}: {result.stderr}")
        return result.returncode, json.loads(lines[-1])

    def create_task(self, title, *roots, provider=None):
        command = ["task", "create", "--title", title, "--provider", provider or self.provider]
        for root in roots or (self.first,):
            command += ["--root", root]
        return self.run_cli(*command)

    def start_turn(self, task_id, message, mode="default", answers=()):
        command = [str(self.cli), "conversation", "send", task_id, "--message", message, "--mode", mode]
        for answer in answers:
            command += ["--answer", answer]
        process = subprocess.Popen(
            command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=self.environment, bufsize=1,
        )
        return StreamingTurn(process)

    def stream_turn(self, task_id, message, mode="default", answers=()):
        turn = self.start_turn(task_id, message, mode=mode, answers=answers)
        status, final = turn.finish()
        require(status == 0 and final.get("ok"), f"{self.provider} turn failed: {final}")
        require(any(event.get("type") == "text_delta" for event in turn.events), f"{self.provider} produced no streamed assistant text before its final response.")
        require(any(event.get("requestID") == final.get("id") for event in turn.events), "Stream events did not match the request ID.")
        return final["result"], turn.events

    def fixture_diff(self, repository, path):
        return subprocess.run(
            ["git", "diff", "--no-ext-diff", "--", str(path)],
            cwd=repository, check=True, capture_output=True, text=True,
        ).stdout

    def repository_allocation_lock_path(self, repository):
        # Mirror RepositoryAllocationLock.fileName(for:)'s FNV-1a key, using
        # `task get`'s persisted repositoryPath to preserve the app-derived
        # spelling from resolvingSymlinksInPath().standardizedFileURL.path.
        # Python realpath() rewrites macOS's /var/folders alias to
        # /private/var/folders here and would target a different lock file.
        canonical_path = os.path.abspath(os.path.normpath(os.fspath(repository)))
        lock_hash = 14695981039346656037
        for byte in os.fsencode(canonical_path):
            lock_hash = ((lock_hash ^ byte) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
        lock_directory = self.data_directory / "repository-allocation-locks"
        lock_directory.mkdir(parents=True, exist_ok=True)
        return lock_directory / f"{lock_hash:016x}.lock"

    def hold_repository_allocation_lock(self, repository):
        lock_path = self.repository_allocation_lock_path(repository)
        descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.lockf(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB, 0, 0, os.SEEK_SET)
        except BaseException:
            os.close(descriptor)
            raise
        return descriptor, lock_path

    def task_operation_lock_is_held(self, task_id):
        task_lock_directory = self.data_directory / "task-operation-locks"
        task_lock_directory.mkdir(parents=True, exist_ok=True)
        task_lock_path = task_lock_directory / f"{str(uuid.UUID(task_id)).upper()}.lock"
        descriptor = os.open(task_lock_path, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            try:
                fcntl.lockf(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB, 0, 0, os.SEEK_SET)
            except BlockingIOError:
                return True
            fcntl.lockf(descriptor, fcntl.LOCK_UN, 0, 0, os.SEEK_SET)
            return False
        finally:
            os.close(descriptor)

    def repository_branch_worktree_state(self, repository):
        branches = subprocess.run(
            ["git", "-C", str(repository), "branch", "--list", "--format=%(refname:short)"],
            check=True, capture_output=True, text=True,
        ).stdout.splitlines()
        worktrees = subprocess.run(
            ["git", "-C", str(repository), "worktree", "list", "--porcelain"],
            check=True, capture_output=True, text=True,
        ).stdout
        managed_worktrees = sorted(
            path.name for path in self.worktree_directory.iterdir()
            if path.name != ".stationai-test-owner"
        )
        return {"branches": branches, "worktrees": worktrees, "managedWorktrees": managed_worktrees}

    def remove(self):
        marker = self.root / MARKER_NAME
        worktree_marker = self.worktree_directory / ".stationai-test-owner"
        if (
            marker.is_file() and marker.read_text(encoding="utf-8") == MARKER_VALUE
            and worktree_marker.is_file() and worktree_marker.read_text(encoding="utf-8") == WORKTREE_MARKER_VALUE
        ):
            shutil.rmtree(self.root)
        else:
            raise RuntimeError(f"Refusing to remove integration workspace without valid workspace and worktree ownership markers: {self.root}")


def activity_is_running(event, text):
    activity = event.get("payload", {}).get("activity", {}) if event.get("type") == "activity" else {}
    return activity.get("status") in {"inProgress", "running"} and text in json.dumps(activity)


# Shared scenarios: the same product behavior, run against the selected provider.

def scenario_plan_edit_resume_and_reload(ws):
    provider = ws.provider
    first, second = ws.first, ws.second
    created = ws.create_task(f"Two-root {provider} integration", first, second)
    task_id = created["id"]
    require(created["conversationProvider"] == provider, f"The task should use {provider}: {created}")
    primary_marker = "StationAI primary integration marker 7F34C2"
    secondary_marker = "StationAI secondary integration marker A19D06"
    primary_file = first / "stationai-primary.txt"
    secondary_file = second / "stationai-secondary.txt"
    primary_baseline = primary_file.read_text(encoding="utf-8")
    secondary_baseline = secondary_file.read_text(encoding="utf-8")
    plan_history, plan_events = ws.stream_turn(
        task_id,
        f"Plan how you would append exactly the line '{primary_marker}' to stationai-primary.txt. Inspect the repository as needed, but do not edit any files. Reply with a concise plan.",
        mode="plan",
    )
    require(primary_file.read_text(encoding="utf-8") == primary_baseline, "Plan mode changed the primary repository file.")
    require(secondary_file.read_text(encoding="utf-8") == secondary_baseline, "Plan mode changed the secondary repository file.")
    require(plan_history.get("messages"), "Plan mode did not return conversation messages.")
    require(any(m.get("role") == "assistant" and m.get("phase") == "final_answer" for m in plan_history["messages"]), "Plan mode returned no final plan.")
    require(all(m.get("provider") == provider for m in plan_history["messages"]), f"Plan-mode messages should be attributed to {provider}.")
    deletion_check = ws.run_cli("task", "delete-check", task_id)
    require(deletion_check.get("requiresConfirmation") is True, "A task with a real conversation must require confirmation before deletion.")

    first_history, first_events = ws.stream_turn(
        task_id,
        f"Edit the committed baseline files in both selected repositories. In {first.name}, append exactly the line '{primary_marker}' to stationai-primary.txt. In {second.name}, append exactly the line '{secondary_marker}' to stationai-secondary.txt. Then run a shell command that prints STATIONAI_FIRST_TURN_COMMAND_OK. Do not edit other files. Reply with a short summary.",
    )
    require(primary_marker in primary_file.read_text(encoding="utf-8"), "First turn did not change the primary repository file.")
    require(secondary_marker in secondary_file.read_text(encoding="utf-8"), "First turn did not change the secondary repository file.")
    require(any(event.get("type") == "activity" and "STATIONAI_FIRST_TURN_COMMAND_OK" in json.dumps(event) for event in first_events), "First turn did not stream the shell command output.")
    require(first_history.get("messages"), "First turn did not return conversation messages.")
    first_activities = first_history.get("activities", [])
    require(first_activities, "First turn history omitted its activity rows.")
    require(any(activity.get("status") == "completed" for activity in first_activities), "First turn history omitted completed activity state.")
    require(
        any(
            event.get("type") == "activity"
            and (event.get("payload", {}).get("activity", {}).get("status") in {"inProgress", "running"})
            for event in first_events
        ),
        "First turn did not stream a running activity state.",
    )
    first_diff = ws.fixture_diff(first, primary_file.name) + ws.fixture_diff(second, secondary_file.name)
    require(primary_marker in first_diff and secondary_marker in first_diff, "First turn diff omitted the actual changed lines from both repositories.")
    changed_rows = [
        event for event in first_events
        if event.get("type") == "activity"
        and ("editing" in json.dumps(event).lower() or "stationai-primary.txt" in json.dumps(event) or "stationai-secondary.txt" in json.dumps(event))
    ]
    require(changed_rows, "First turn did not report a file-change activity row.")

    followup_marker = "StationAI resumed integration marker 38BC11"
    second_history, second_events = ws.stream_turn(
        task_id,
        f"Continue from the instruction and changes in the previous turn. Append exactly the line '{followup_marker}' to stationai-secondary.txt only, then run a shell command that prints STATIONAI_RESUMED_COMMAND_OK. Reply with a short summary.",
    )
    require(followup_marker in secondary_file.read_text(encoding="utf-8"), "Resumed turn did not update the secondary repository file.")
    require(any(event.get("type") == "activity" and "STATIONAI_RESUMED_COMMAND_OK" in json.dumps(event) for event in second_events), "Resumed turn did not stream its command output.")
    require(len(second_history.get("messages", [])) >= len(first_history.get("messages", [])) + 2, "Resumed history did not retain both turns.")
    require(second_history.get("activities"), "Resumed turn history omitted its activity rows.")
    require(followup_marker in ws.fixture_diff(second, secondary_file.name), "Resumed turn diff omitted its changed line.")
    native_id = ws.run_cli("task", "get", task_id)["claudeSessionID" if provider == "claude" else "codexThreadID"]
    require(native_id, f"The task should keep its native {provider} conversation ID.")

    reopened = ws.run_cli("conversation", "history", task_id)
    require(len(reopened.get("messages", [])) == len(second_history.get("messages", [])), "Fresh CLI/XPC connection did not reload the complete conversation history.")
    return "plan, edit, resume, and reload"


def scenario_steer_active_turn(ws):
    task_id = ws.create_task(f"{ws.provider} steer integration")["id"]
    token = f"STEER_TOKEN_{uuid.uuid4().hex[:6].upper()}"
    prompt = "Run exactly one shell command: `sleep 25 && echo STATIONAI_STEER_WAIT_DONE`. When it finishes, reply with one short sentence."
    turn = ws.start_turn(task_id, prompt)
    try:
        turn.wait_for(lambda event: activity_is_running(event, "sleep 25"), 180, "the long command to start")
        steer_text = f"Also include the exact token {token} in your final reply."
        steered = ws.run_cli("conversation", "steer", task_id, "--message", steer_text)
        require(steered == {"accepted": True, "queued": False}, f"Steer should enter the active turn, not the queue: {steered}")
    except BaseException:
        turn.process.terminate()
        raise
    status, final = turn.finish()
    require(status == 0 and final.get("ok"), f"The steered turn failed: {final}")
    history = final["result"]
    users = [m for m in history["messages"] if m["role"] == "user"]
    original = next(m for m in users if m["text"] == prompt)
    steered_message = next((m for m in users if m["text"] == steer_text), None)
    require(steered_message is not None, f"The steered message is missing from history: {users}")
    require(steered_message.get("turnID") == original.get("turnID"), "The steered message should belong to the active turn, not a new one.")
    replies = [m for m in history["messages"] if m["role"] == "assistant" and (m.get("timelineOrder") or 0) > (steered_message.get("timelineOrder") or 0)]
    require(any(token in m["text"] for m in replies), f"The turn did not act on the steered input: {[m['text'][:120] for m in replies]}")
    require(ws.run_cli("conversation", "queue-list", task_id) == [], "A steer accepted by the active turn must not be queued.")
    return "steer into an active turn"


def scenario_stop_active_turn(ws):
    task_id = ws.create_task(f"{ws.provider} stop integration")["id"]
    # The output token is built from pieces so it never appears in the command text itself.
    turn = ws.start_turn(task_id, "Run exactly one shell command: `sleep 120 && printf 'STOP_%s' NOT_EXPECTED`. Then reply with one short sentence.")
    try:
        turn.wait_for(lambda event: activity_is_running(event, "sleep 120"), 180, "the long command to start")
        stopped_at = time.monotonic()
        stopped = ws.run_cli("conversation", "stop", task_id)
        require(stopped == {"interrupted": True}, f"Stop should reach the turn owned by another process: {stopped}")
    except BaseException:
        turn.process.terminate()
        raise
    status, final = turn.finish(timeout=90)
    require(time.monotonic() - stopped_at < 60, "The turn kept running long after Stop.")
    require(not final.get("ok"), f"A stopped turn should not report success: {final}")
    require(not any("STOP_NOT_EXPECTED" in json.dumps(event) for event in turn.events), "The interrupted command still produced its output.")
    record = ws.run_cli("task", "get", task_id)
    require(record["status"] in {"Blocked", "Waiting Response"}, f"A stopped turn should leave the task resumable: {record['status']}")
    return "stop an active turn from another process"


def scenario_concurrent_auto_branch(ws):
    provider = ws.provider
    first = ws.first
    data_directory = ws.data_directory
    run_cli = ws.run_cli
    repository_allocation_lock_path = ws.repository_allocation_lock_path
    hold_repository_allocation_lock = ws.hold_repository_allocation_lock
    task_operation_lock_is_held = ws.task_operation_lock_is_held
    repository_branch_worktree_state = ws.repository_branch_worktree_state

    def start_turn(task_id, message):
        # StreamingTurn owns stdout; never read the process directly here.
        return ws.start_turn(task_id, message)

    def exited_turn_diagnostics(turns):
        diagnostics = []
        for index, turn in enumerate(turns, start=1):
            if turn.process.poll() is None:
                continue
            diagnostics.append(f"turn {index} exited with status {turn.process.returncode}")
        return diagnostics

    def finish_turn(turn):
        return turn.finish(timeout=300)

    auto_title = f"Concurrent live auto branch {uuid.uuid4().hex[:8]}"
    auto_tasks = [
        run_cli("task", "create", "--title", auto_title, "--repo", first, "--provider", provider),
        run_cli("task", "create", "--title", auto_title, "--repo", first, "--provider", provider),
    ]
    auto_task_snapshots = [run_cli("task", "get", contender["id"]) for contender in auto_tasks]
    repository_paths = [
        snapshot["repositoryWorktrees"][0]["repositoryPath"]
        for snapshot in auto_task_snapshots
    ]
    expected_lock_paths = [repository_allocation_lock_path(path) for path in repository_paths]
    require(
        len(set(expected_lock_paths)) == 1,
        f"Auto-branch contenders did not persist the same repository allocation key: {repository_paths} -> {expected_lock_paths}",
    )
    lock_directory = expected_lock_paths[0].parent
    existing_lock_paths = sorted(lock_directory.glob("*.lock"))
    require(
        existing_lock_paths == expected_lock_paths[:1],
        f"The task-get repository path did not derive the existing Swift allocation lock: "
        f"repositoryPaths={repository_paths}; expected={expected_lock_paths[0]}; existing={existing_lock_paths}",
    )
    worktree_count_before = subprocess.run(
        ["git", "-C", str(first), "worktree", "list", "--porcelain"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.count("worktree ")
    repository_state_before_turns = repository_branch_worktree_state(repository_paths[0])
    lock_descriptor, lock_path = hold_repository_allocation_lock(repository_paths[0])
    turn_processes = []
    try:
        for contender in auto_tasks:
            turn_processes.append(start_turn(
                contender["id"],
                "Inspect the repository and respond exactly READY. Do not change any files.",
            ))
        task_ids = [contender["id"] for contender in auto_tasks]
        deadline = time.monotonic() + 20
        held_task_locks = [False] * len(task_ids)
        while time.monotonic() < deadline:
            diagnostics = exited_turn_diagnostics(turn_processes)
            if diagnostics:
                lock_paths_during_hold = sorted(lock_directory.glob("*.lock"))
                repository_state_during_hold = repository_branch_worktree_state(repository_paths[0])
                require(
                    False,
                    "A real provider turn exited before both requests reached repository preparation. "
                    f"Held repository lock={lock_path}; task IDs={task_ids}; "
                    f"task-operation locks held={held_task_locks}; "
                    f"lock files during hold={lock_paths_during_hold}; "
                    f"Git branch/worktree state before={repository_state_before_turns}; "
                    f"during={repository_state_during_hold}. "
                    + " | ".join(diagnostics),
                )
            held_task_locks = [task_operation_lock_is_held(task_id) for task_id in task_ids]
            if all(held_task_locks):
                diagnostics = exited_turn_diagnostics(turn_processes)
                if diagnostics:
                    require(
                        False,
                        "A real provider turn exited while task-operation locks were being confirmed. "
                        f"Held repository lock={lock_path}; task IDs={task_ids}; "
                        f"task-operation locks held={held_task_locks}; "
                        f"Git branch/worktree state before={repository_state_before_turns}; "
                        f"during={repository_branch_worktree_state(repository_paths[0])}. "
                        + " | ".join(diagnostics),
                    )
                break
            time.sleep(0.05)
        else:
            diagnostics = exited_turn_diagnostics(turn_processes)
            repository_state_during_hold = repository_branch_worktree_state(repository_paths[0])
            require(
                False,
                "Timed out waiting for both live turns to hold their task-operation locks while "
                "the repository allocation lock remained held. "
                f"Held repository lock={lock_path}; task IDs={task_ids}; "
                f"task-operation locks held={held_task_locks}; "
                f"lock files during hold={sorted(lock_directory.glob('*.lock'))}; "
                f"Git branch/worktree state before={repository_state_before_turns}; "
                f"during={repository_state_during_hold}. "
                + (" | " + " | ".join(diagnostics) if diagnostics else ""),
            )

        hold_deadline = time.monotonic() + 2
        hold_checks = 0
        while time.monotonic() < hold_deadline:
            diagnostics = exited_turn_diagnostics(turn_processes)
            held_task_locks = [task_operation_lock_is_held(task_id) for task_id in task_ids]
            repository_state_during_hold = repository_branch_worktree_state(repository_paths[0])
            require(
                not diagnostics,
                "A real provider turn exited during the repository-lock stabilization window. "
                f"Held repository lock={lock_path}; task IDs={task_ids}; "
                f"task-operation locks held={held_task_locks}; "
                f"Git branch/worktree state before={repository_state_before_turns}; "
                f"during={repository_state_during_hold}. "
                + " | ".join(diagnostics),
            )
            require(
                all(held_task_locks),
                "A task-operation lock was released before the repository allocation lock. "
                f"Held repository lock={lock_path}; task IDs={task_ids}; "
                f"task-operation locks held={held_task_locks}; "
                f"Git branch/worktree state before={repository_state_before_turns}; "
                f"during={repository_state_during_hold}",
            )
            require(
                repository_state_during_hold == repository_state_before_turns,
                "A contender branch or worktree was created while the repository allocation lock was held. "
                f"Held repository lock={lock_path}; task IDs={task_ids}; "
                f"task-operation locks held={held_task_locks}; "
                f"Git branch/worktree state before={repository_state_before_turns}; "
                f"during={repository_state_during_hold}",
            )
            hold_checks += 1
            time.sleep(0.05)

        diagnostics = exited_turn_diagnostics(turn_processes)
        held_task_locks = [task_operation_lock_is_held(task_id) for task_id in task_ids]
        repository_state_during_hold = repository_branch_worktree_state(repository_paths[0])
        require(
            not diagnostics and all(held_task_locks)
            and repository_state_during_hold == repository_state_before_turns,
            "The repository-lock stabilization window did not remain clean through its final check. "
            f"checks={hold_checks}; held repository lock={lock_path}; task IDs={task_ids}; "
            f"task-operation locks held={held_task_locks}; "
            f"Git branch/worktree state before={repository_state_before_turns}; "
            f"during={repository_state_during_hold}. "
            + (" | " + " | ".join(diagnostics) if diagnostics else ""),
        )
        lock_paths_during_hold = sorted(lock_directory.glob("*.lock"))
        require(
            lock_paths_during_hold == [lock_path],
            f"Conversation preparation used a different repository lock while the expected lock was held: "
            f"held={lock_path}; persisted repository paths={repository_paths}; "
            f"persisted-path keys={expected_lock_paths}; lock files during hold={lock_paths_during_hold}",
        )
    except BaseException:
        for turn in turn_processes:
            if turn.process.poll() is None:
                turn.process.terminate()
                try:
                    turn.process.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    turn.process.kill()
                    turn.process.wait()
        raise
    finally:
        fcntl.lockf(lock_descriptor, fcntl.LOCK_UN, 0, 0, os.SEEK_SET)
        os.close(lock_descriptor)
    outcomes = [finish_turn(turn) for turn in turn_processes]
    require(sorted(status for status, _ in outcomes) == [0, 2], f"Expected one live branch claim and one assignment conflict; got {[status for status, _ in outcomes]}.")
    successful = [response for _, response in outcomes if response.get("ok") is True]
    rejected = [response for _, response in outcomes if response.get("ok") is False]
    require(len(successful) == len(rejected) == 1, f"Expected one successful and one rejected live turn: {outcomes}")
    require(rejected[0].get("error", {}).get("code") == "invalid_argument", f"Unexpected auto branch conflict error: {rejected[0]}")
    require("already assigned" in rejected[0].get("error", {}).get("message", ""), f"Auto branch conflict omitted its explanation: {rejected[0]}")
    persisted = [run_cli("task", "get", contender["id"]) for contender in auto_tasks]
    prepared = [task for task in persisted if not task["repositoryWorktrees"][0]["isPending"]]
    pending = [task for task in persisted if task["repositoryWorktrees"][0]["isPending"]]
    require(len(prepared) == len(pending) == 1, f"Concurrent auto branch turns must leave one prepared task and one pending task: {persisted}")
    require(prepared[0]["status"] == "Review", f"The winning turn should finish in Review after reporting its outcome: {persisted}")
    require(pending[0]["status"] == "Backlog", f"A rejected branch claim must restore the losing contender to Backlog: {persisted}")
    require(pending[0].get("pendingSubmittedPrompt") is None, f"A rejected branch claim left a pending submitted prompt: {persisted}")
    prepared_path = Path(prepared[0]["repositoryWorktrees"][0]["worktreePath"])
    require(prepared_path.is_dir() and data_directory.joinpath("worktrees") in prepared_path.parents, f"The winning managed worktree is missing or outside the owned worktree directory: {prepared_path}")
    worktree_count_after = subprocess.run(
        ["git", "-C", str(first), "worktree", "list", "--porcelain"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.count("worktree ")
    require(worktree_count_after == worktree_count_before + 1, "Only the winning live turn should create a managed worktree.")
    return "concurrent auto-branch claim"


# Claude-only scenarios: behavior that Codex reaches through other means.

def scenario_claude_question_round_trip(ws):
    task_id = ws.create_task("Claude question integration")["id"]
    history, events = ws.stream_turn(
        task_id,
        "Before anything else, use the AskUserQuestion tool exactly once to ask me which color to use, with the options Red and Blue. After I answer, reply with one sentence that names the color I chose. Do not edit any files.",
        mode="plan",
        answers=("question-1=Blue",),
    )
    request = next((event for event in events if event.get("type") == "user_input"), None)
    require(request is not None, "Claude did not ask its question through StationAI.")
    questions = request["payload"]["userInputRequest"]["questions"]
    require([q["id"] for q in questions] == ["question-1"], f"Unexpected question IDs: {questions}")
    require({"Red", "Blue"} <= {o["label"] for o in questions[0]["options"]}, f"The question omitted its options: {questions}")
    final_replies = [m["text"] for m in history["messages"] if m["role"] == "assistant" and m.get("phase") == "final_answer"]
    require(any("Blue" in text for text in final_replies), f"Claude did not continue with the supplied answer: {final_replies}")
    return "question round trip"


def scenario_claude_capabilities(ws):
    task_id = ws.create_task("Claude capability integration")["id"]
    capabilities = {entry["provider"]: entry for entry in ws.run_cli("conversation", "provider", task_id, "capabilities")}
    claude = capabilities["claude"]
    require(claude["isAvailable"] and not claude.get("error"), f"Claude Code should report its capabilities: {claude}")
    require(version_tuple(claude["version"]) >= version_tuple(MINIMUM_CLAUDE_VERSION), f"Claude Code {claude['version']} is older than {MINIMUM_CLAUDE_VERSION}.")
    require(claude["supportsGoals"] is False and capabilities["codex"]["supportsGoals"] is True, "Goal support should be Codex-only.")
    models = ws.run_cli("conversation", "models", task_id)["models"]
    require(any(model["id"] == "default" and model["isDefault"] for model in models), f"Claude models should include the default alias: {models}")
    return "native capability report"


# Codex-only scenarios.

def scenario_codex_pinned_model(ws):
    task_id = ws.create_task("Codex model integration")["id"]
    models = ws.run_cli("conversation", "models", task_id)["models"]
    require(any(model["id"] == "gpt-6-luna" for model in models), f"Codex should offer the pinned Luna model: {models}")
    return "pinned Luna model (Goal runs in the live UI case)"


# Cross-provider scenario, run only with --provider all.

def scenario_cross_provider_handoff(ws):
    task_id = ws.create_task("Cross-provider handoff integration", provider="claude")["id"]
    ws.stream_turn(task_id, "Remember this first codeword for later in this task: PINEAPPLE-41. Reply with just OK.")
    require(ws.run_cli("conversation", "provider", task_id, "set", "codex")["conversationProvider"] == "codex", "The switch to Codex failed.")
    codex_history, _ = ws.stream_turn(task_id, "What first codeword did I ask you to remember earlier in this task? Reply with only the codeword.")
    require("PINEAPPLE-41" in codex_history["messages"][-1]["text"], f"Codex did not receive Claude's turn as context: {codex_history['messages'][-1]}")
    ws.stream_turn(task_id, "Remember this second codeword too: MANGO-17. Reply with just OK.")
    require(ws.run_cli("conversation", "provider", task_id, "set", "claude")["conversationProvider"] == "claude", "The switch back to Claude failed.")
    final, _ = ws.stream_turn(task_id, "What second codeword did I give you while you were away? Reply with only the codeword.")
    require("MANGO-17" in final["messages"][-1]["text"], f"Claude did not receive Codex's turns as context: {final['messages'][-1]}")
    boundaries = [boundary["provider"] for boundary in final["providerBoundaries"]]
    require(boundaries == ["codex", "claude"], f"Expected two provider boundaries in order: {final['providerBoundaries']}")
    providers = [message.get("provider") for message in final["messages"]]
    first_codex = providers.index("codex")
    last_codex = len(providers) - 1 - providers[::-1].index("codex")
    require(set(providers[:first_codex]) == {"claude"} and set(providers[first_codex:last_codex + 1]) == {"codex"} and set(providers[last_codex + 1:]) == {"claude"},
            f"The mixed transcript is out of provider order: {providers}")
    orders = [message["timelineOrder"] for message in final["messages"]]
    require(orders == sorted(orders), "The mixed transcript timeline is not ordered.")
    require(not any("<stationai-handoff-context>" in message["text"] for message in final["messages"]), "Handoff context leaked into the visible transcript.")
    reopened = ws.run_cli("conversation", "history", task_id)
    require([m["id"] for m in reopened["messages"]] == [m["id"] for m in final["messages"]], "A fresh connection reloaded a different mixed transcript.")
    return "Claude ⇄ Codex handoff"


SHARED_SCENARIOS = [
    scenario_plan_edit_resume_and_reload,
    scenario_steer_active_turn,
    scenario_stop_active_turn,
    scenario_concurrent_auto_branch,
]
UNIQUE_SCENARIOS = {
    "claude": [scenario_claude_question_round_trip, scenario_claude_capabilities],
    "codex": [scenario_codex_pinned_model],
}


def preflight(provider):
    if provider == "claude":
        result = subprocess.run(["claude", "auth", "status"], capture_output=True, text=True)
        require(result.returncode == 0 and json.loads(result.stdout or "{}").get("loggedIn"), "Live Claude turns require a working `claude` sign-in on this host.")
    else:
        result = subprocess.run(["codex", "login", "status"], capture_output=True, text=True)
        require(result.returncode == 0, "Live Codex turns require a working `codex login` on this host.")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--provider", choices=[*PROVIDERS, "all"], default=os.environ.get("STATIONAI_LIVE_PROVIDER", "claude"))
    parser.add_argument("--scenario", action="append", default=[], help="Run only the named scenario function (repeatable).")
    arguments = parser.parse_args()
    if os.environ.get("STATIONAI_RUN_LIVE_INTEGRATION") != "1" and os.environ.get("STATIONAI_RUN_CODEX_INTEGRATION") != "1":
        raise SystemExit("This suite makes live provider turns. Set STATIONAI_RUN_LIVE_INTEGRATION=1 after confirming the provider sign-in works.")
    providers = list(PROVIDERS) if arguments.provider == "all" else [arguments.provider]

    app_bundle = Path(os.environ.get(
        "STATIONAI_APP_PATH",
        str(Path(tempfile.gettempdir()) / "StationAI-DerivedData/Build/Products/Debug/StationAI.app"),
    ))
    cli = app_bundle / "Contents/MacOS/stationai-cli"
    service_info = app_bundle / "Contents/XPCServices/StationAIBridge.xpc/Contents/Info.plist"
    fixture = Path(os.environ.get("STATIONAI_BRIDGE_TEST_FIXTURE_ROOT", "/tmp/stationai-bridge-workspaces"))
    require(cli.is_file(), f"Bundled CLI is missing: {cli}; run scripts/run.sh first.")
    marker = fixture / ".stationai-bridge-fixture"
    require(
        marker.is_file() and marker.read_text(encoding="utf-8") == BRIDGE_FIXTURE_MARKER_VALUE,
        "Run scripts/prepare-e2e-fixture.py and verify its ownership marker before this suite.",
    )
    for repository in [fixture / "suggested-parent/primary", fixture / "suggested-parent/group/secondary"]:
        status = subprocess.run(["git", "-C", str(repository), "status", "--porcelain"], check=True, capture_output=True, text=True).stdout
        require(not status, f"Integration source fixture must start clean: {repository}: {status}")
    with service_info.open("rb") as plist_file:
        service_name = plistlib.load(plist_file)["CFBundleIdentifier"]

    plan = [(provider, scenario) for provider in providers for scenario in SHARED_SCENARIOS + UNIQUE_SCENARIOS[provider]]
    if arguments.provider == "all":
        plan.append(("all", scenario_cross_provider_handoff))
    if arguments.scenario:
        plan = [(provider, scenario) for provider, scenario in plan if scenario.__name__ in arguments.scenario]
        require(plan, f"No scenario matched {arguments.scenario}.")
    for provider in providers:
        preflight(provider)

    passed = []
    for provider, scenario in plan:
        started = time.monotonic()
        ws = LiveWorkspace("claude" if provider == "all" else provider, fixture, cli, service_name)
        try:
            print(f"Live {provider}: {scenario.__name__} ...", flush=True)
            summary = scenario(ws)
            passed.append(f"{provider}: {summary}")
            print(f"Live {provider}: {scenario.__name__} passed in {time.monotonic() - started:.1f}s", flush=True)
        finally:
            if os.environ.get("STATIONAI_LIVE_KEEP_WORKSPACE") == "1":
                print(f"Kept workspace for diagnosis: {ws.root}", flush=True)
            else:
                ws.remove()
    print(f"Live integration passed for {', '.join(providers)} ({len(passed)} scenarios):")
    for item in passed:
        print(f"  - {item}")


if __name__ == "__main__":
    main()
