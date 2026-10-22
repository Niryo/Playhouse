#!/usr/bin/env python3

import json
import fcntl
import os
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid
from pathlib import Path


MARKER_NAME = ".stationai-codex-integration-owner"
MARKER_VALUE = "StationAI Codex integration suite owns this disposable workspace (v1).\n"
BRIDGE_FIXTURE_MARKER_VALUE = "StationAI bridge tests own this deterministic fixture (v1).\n"
WORKTREE_MARKER_VALUE = "StationAI Codex integration suite owns this worktree root.\n"


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


def main():
    if os.environ.get("STATIONAI_RUN_CODEX_INTEGRATION") != "1":
        raise SystemExit(
            "This suite makes live Codex turns. Set STATIONAI_RUN_CODEX_INTEGRATION=1 after confirming `codex login` works."
        )

    repository_root = Path(__file__).resolve().parent.parent
    app_bundle = Path(os.environ.get(
        "STATIONAI_APP_PATH",
        str(Path(tempfile.gettempdir()) / "StationAI-DerivedData/Build/Products/Debug/StationAI.app"),
    ))
    cli = app_bundle / "Contents/MacOS/stationai-cli"
    service_info = app_bundle / "Contents/XPCServices/StationAIBridge.xpc/Contents/Info.plist"
    fixture = Path(os.environ.get("STATIONAI_BRIDGE_TEST_FIXTURE_ROOT", "/tmp/stationai-bridge-workspaces"))
    require(cli.is_file(), f"Bundled CLI is missing: {cli}; run scripts/run.sh first.")
    bridge_fixture_marker = fixture / ".stationai-bridge-fixture"
    require(
        bridge_fixture_marker.is_file()
        and bridge_fixture_marker.read_text(encoding="utf-8") == BRIDGE_FIXTURE_MARKER_VALUE,
        "Run scripts/prepare-e2e-fixture.py and verify its ownership marker before this suite.",
    )
    for repository in [fixture / "suggested-parent/primary", fixture / "suggested-parent/group/secondary"]:
        status = subprocess.run(
            ["git", "-C", str(repository), "status", "--porcelain"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        require(not status, f"Integration source fixture must start clean: {repository}: {status}")

    root = Path(tempfile.mkdtemp(prefix="stationai-codex-integration-"))
    marker = root / MARKER_NAME
    marker.write_text(MARKER_VALUE, encoding="utf-8")
    first = root / "primary"
    second = root / "secondary"
    shutil.copytree(fixture / "suggested-parent/primary", first)
    shutil.copytree(fixture / "suggested-parent/group/secondary", second)
    data_directory = root / "stationai-data"
    data_directory.mkdir()
    worktree_directory = data_directory / "worktrees"
    worktree_directory.mkdir()
    worktree_marker = worktree_directory / ".stationai-test-owner"
    worktree_marker.write_text(WORKTREE_MARKER_VALUE, encoding="utf-8")
    environment = os.environ.copy()
    environment["STATIONAI_DATA_DIRECTORY"] = str(data_directory)
    environment["STATIONAI_E2E_WORKTREE_DIRECTORY"] = str(worktree_directory)
    environment["STATIONAI_E2E_DEFAULTS_SUITE"] = f"com.stationai.codex-integration.{uuid.uuid4()}"
    with service_info.open("rb") as plist_file:
        environment["STATIONAI_BRIDGE_SERVICE_NAME"] = plistlib.load(plist_file)["CFBundleIdentifier"]

    def run_cli(*command):
        result = subprocess.run(
            [str(cli), *map(str, command)],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
            timeout=180,
        )
        return response_from(result, command)

    def stream_turn(task_id, message, mode="default"):
        process = subprocess.Popen(
            [str(cli), "conversation", "send", task_id, "--message", message, "--mode", mode],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment,
            bufsize=1,
        )
        events = []
        final = None
        assert process.stdout is not None
        for line in process.stdout:
            if not line.strip():
                continue
            value = json.loads(line)
            if value.get("ok") is not None and "version" in value:
                final = value
            else:
                events.append(value)
        stderr = process.stderr.read() if process.stderr else ""
        exit_code = process.wait(timeout=30)
        require(exit_code == 0 and final and final.get("ok"), f"Codex turn failed: {final}; {stderr}")
        text_events = [event for event in events if event.get("type") == "text_delta"]
        require(text_events, "Codex produced no streamed assistant text delta before its final response.")
        require(any(event.get("requestID") == final.get("id") for event in events), "Stream events did not match the request ID.")
        return final["result"], events

    def start_turn(task_id, message, mode="plan"):
        return subprocess.Popen(
            [str(cli), "conversation", "send", task_id, "--message", message, "--mode", mode],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment,
            bufsize=1,
        )

    def finish_turn(process):
        stdout, stderr = process.communicate(timeout=300)
        records = [json.loads(line) for line in stdout.splitlines() if line.strip()]
        final = next((record for record in reversed(records) if "version" in record and "ok" in record), None)
        require(final is not None, f"Concurrent Codex turn returned no final CLI response: {stderr}")
        return process.returncode, final

    def repository_allocation_lock_path(repository):
        # Mirror RepositoryAllocationLock.fileName(for:)'s FNV-1a key, using
        # `task get`'s persisted repositoryPath to preserve the app-derived
        # spelling from resolvingSymlinksInPath().standardizedFileURL.path.
        # Python realpath() rewrites macOS's /var/folders alias to
        # /private/var/folders here and would target a different lock file.
        canonical_path = os.path.abspath(os.path.normpath(os.fspath(repository)))
        lock_hash = 14695981039346656037
        for byte in os.fsencode(canonical_path):
            lock_hash = ((lock_hash ^ byte) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
        lock_directory = data_directory / "repository-allocation-locks"
        lock_directory.mkdir(parents=True, exist_ok=True)
        return lock_directory / f"{lock_hash:016x}.lock"

    def hold_repository_allocation_lock(repository):
        lock_path = repository_allocation_lock_path(repository)
        descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.lockf(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB, 0, 0, os.SEEK_SET)
        except BaseException:
            os.close(descriptor)
            raise
        return descriptor, lock_path

    def task_operation_lock_is_held(task_id):
        task_lock_directory = data_directory / "task-operation-locks"
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

    def exited_turn_diagnostics(turn_processes):
        diagnostics = []
        for index, process in enumerate(turn_processes, start=1):
            if process.poll() is None:
                continue
            stdout, stderr = process.communicate()
            diagnostics.append(
                f"turn {index} exited with status {process.returncode}; "
                f"stdout tail={stdout[-8000:]!r}; stderr tail={stderr[-4000:]!r}"
            )
        return diagnostics

    def repository_branch_worktree_state(repository):
        branches = subprocess.run(
            ["git", "-C", str(repository), "branch", "--list", "--format=%(refname:short)"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.splitlines()
        worktrees = subprocess.run(
            ["git", "-C", str(repository), "worktree", "list", "--porcelain"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        managed_worktrees = sorted(
            path.name for path in worktree_directory.iterdir()
            if path.name != ".stationai-test-owner"
        )
        return {
            "branches": branches,
            "worktrees": worktrees,
            "managedWorktrees": managed_worktrees,
        }

    def fixture_diff(repository, path):
        result = subprocess.run(
            ["git", "diff", "--no-ext-diff", "--", str(path)],
            cwd=repository,
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout

    try:
        created = run_cli("task", "create", "--title", "Two-root Codex integration", "--root", first, "--root", second)
        task_id = created["id"]
        primary_marker = "StationAI primary integration marker 7F34C2"
        secondary_marker = "StationAI secondary integration marker A19D06"
        primary_file = first / "stationai-primary.txt"
        secondary_file = second / "stationai-secondary.txt"
        primary_baseline = primary_file.read_text(encoding="utf-8")
        secondary_baseline = secondary_file.read_text(encoding="utf-8")
        plan_history, plan_events = stream_turn(
            task_id,
            f"Plan how you would append exactly the line '{primary_marker}' to stationai-primary.txt. Inspect the repository as needed, but do not edit any files. Reply with a concise plan.",
            mode="plan",
        )
        require(primary_file.read_text(encoding="utf-8") == primary_baseline, "Plan mode changed the primary repository file.")
        require(secondary_file.read_text(encoding="utf-8") == secondary_baseline, "Plan mode changed the secondary repository file.")
        require(plan_history.get("messages"), "Plan mode did not return conversation messages.")
        require(any(event.get("type") == "text_delta" for event in plan_events), "Plan mode produced no streamed assistant text.")
        deletion_check = run_cli("task", "delete-check", task_id)
        require(deletion_check.get("requiresConfirmation") is True, "A task with real Codex conversation history must require confirmation before deletion.")

        first_history, first_events = stream_turn(
            task_id,
            f"Edit the committed baseline files in both selected repositories. In {first.name}, append exactly the line '{primary_marker}' to stationai-primary.txt. In {second.name}, append exactly the line '{secondary_marker}' to stationai-secondary.txt. Then run a shell command that prints STATIONAI_FIRST_TURN_COMMAND_OK. Do not edit other files. Reply with a short summary.",
        )

        first_file = primary_file
        second_file = secondary_file
        require(primary_marker in first_file.read_text(encoding="utf-8"), "First Codex turn did not change the primary repository file.")
        require(secondary_marker in second_file.read_text(encoding="utf-8"), "First Codex turn did not change the secondary repository file.")
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
        first_diff = fixture_diff(first, primary_file.name) + fixture_diff(second, secondary_file.name)
        require(primary_marker in first_diff and secondary_marker in first_diff, "First turn diff omitted the actual changed lines from both repositories.")
        changed_rows = [
            event for event in first_events
            if event.get("type") == "activity"
            and ("editing" in json.dumps(event).lower() or "stationai-primary.txt" in json.dumps(event) or "stationai-secondary.txt" in json.dumps(event))
        ]
        require(changed_rows, "First turn did not report a file-change activity row.")

        followup_marker = "StationAI resumed integration marker 38BC11"
        second_history, second_events = stream_turn(
            task_id,
            f"Continue from the instruction and changes in the previous turn. Append exactly the line '{followup_marker}' to stationai-secondary.txt only, then run a shell command that prints STATIONAI_RESUMED_COMMAND_OK. Reply with a short summary.",
        )
        require(followup_marker in second_file.read_text(encoding="utf-8"), "Resumed Codex turn did not update the secondary repository file.")
        require(any(event.get("type") == "activity" and "STATIONAI_RESUMED_COMMAND_OK" in json.dumps(event) for event in second_events), "Resumed turn did not stream its command output.")
        require(len(second_history.get("messages", [])) >= len(first_history.get("messages", [])) + 2, "Resumed history did not retain both turns.")
        require(second_history.get("activities"), "Resumed turn history omitted its activity rows.")
        second_diff = fixture_diff(second, secondary_file.name)
        require(followup_marker in second_diff, "Resumed turn diff omitted its changed line.")

        reopened = run_cli("conversation", "history", task_id)
        require(len(reopened.get("messages", [])) == len(second_history.get("messages", [])), "Fresh CLI/XPC connection did not reload the complete conversation history.")

        auto_title = f"Concurrent live auto branch {uuid.uuid4().hex[:8]}"
        auto_tasks = [
            run_cli("task", "create", "--title", auto_title, "--repo", first),
            run_cli("task", "create", "--title", auto_title, "--repo", first),
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
                        "A real Codex turn exited before both requests reached repository preparation. "
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
                            "A real Codex turn exited while task-operation locks were being confirmed. "
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
                    "A real Codex turn exited during the repository-lock stabilization window. "
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
            for process in turn_processes:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.communicate(timeout=20)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.communicate()
            raise
        finally:
            fcntl.lockf(lock_descriptor, fcntl.LOCK_UN, 0, 0, os.SEEK_SET)
            os.close(lock_descriptor)
        outcomes = [finish_turn(process) for process in turn_processes]
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
        require(prepared[0]["status"] == "Review" and pending[0]["status"] == "Backlog", f"Task statuses do not match the branch allocation result: {persisted}")
        prepared_path = Path(prepared[0]["repositoryWorktrees"][0]["worktreePath"])
        require(prepared_path.is_dir() and data_directory.joinpath("worktrees") in prepared_path.parents, f"The winning managed worktree is missing or outside the owned worktree directory: {prepared_path}")
        worktree_count_after = subprocess.run(
            ["git", "-C", str(first), "worktree", "list", "--porcelain"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.count("worktree ")
        require(worktree_count_after == worktree_count_before + 1, "Only the winning live Codex turn should create a managed worktree.")
        print("Codex integration passed: Plan mode left both roots unchanged, Code mode streamed turns and changed files in two roots, command output and diffs were captured, the thread resumed, history reloaded, and concurrent live turns produced exactly one managed auto-branch worktree.")
    finally:
        current_marker = root / MARKER_NAME
        current_worktree_marker = worktree_directory / ".stationai-test-owner"
        if (
            current_marker.is_file()
            and current_marker.read_text(encoding="utf-8") == MARKER_VALUE
            and current_worktree_marker.is_file()
            and current_worktree_marker.read_text(encoding="utf-8") == WORKTREE_MARKER_VALUE
        ):
            shutil.rmtree(root)
        else:
            raise RuntimeError(f"Refusing to remove integration workspace without valid workspace and worktree ownership markers: {root}")


if __name__ == "__main__":
    main()
