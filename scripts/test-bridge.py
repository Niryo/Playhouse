#!/usr/bin/env python3

import argparse
import base64
import errno
import fcntl
import json
import plistlib
import os
import select
import signal
import shutil
import shlex
import sqlite3
import stat
import struct
import subprocess
import tempfile
import threading
import time
import unittest
import uuid
from pathlib import Path


parser = argparse.ArgumentParser()
parser.add_argument("--cli", required=True, type=Path)
parser.add_argument("--fixture-root", required=True, type=Path)
parser.add_argument("--data-root", required=True, type=Path)
parser.add_argument("--service-name", required=True)
parser.add_argument("--legacy-store-seeder", required=True, type=Path)
parser.add_argument("--case", action="append", default=[], dest="selected_cases")
arguments = parser.parse_args()
CONTRACT_PATH = Path(__file__).resolve().parent.parent / "StationAI/BridgeTests/BridgeTestContracts.json"


class GitConfigReadBarrier:
    """Hold a real Git config read open so a second XPC request can update task state."""

    def __init__(self, repository):
        self.config = Path(repository) / ".git" / "config"
        self.backup = self.config.with_name(f"config.stationai-test-{uuid.uuid4()}")
        self.contents = self.config.read_bytes()
        self.writer = None
        os.replace(self.config, self.backup)
        try:
            os.mkfifo(self.config)
        except BaseException:
            os.replace(self.backup, self.config)
            raise

    def wait_for_reader(self, timeout=15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                self.writer = os.open(self.config, os.O_WRONLY | os.O_NONBLOCK)
                return
            except OSError as error:
                if error.errno != errno.ENXIO:
                    raise
                time.sleep(0.005)
        raise TimeoutError(f"Git did not open the owned config FIFO: {self.config}")

    def release(self):
        if self.writer is None and self.config.exists() and stat.S_ISFIFO(self.config.stat().st_mode):
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                try:
                    self.writer = os.open(self.config, os.O_WRONLY | os.O_NONBLOCK)
                    break
                except OSError as error:
                    if error.errno != errno.ENXIO:
                        raise
                    time.sleep(0.005)
        if self.config.exists() and stat.S_ISFIFO(self.config.stat().st_mode):
            self.config.unlink()
        if self.backup.exists():
            os.replace(self.backup, self.config)
        if self.writer is not None:
            try:
                os.write(self.writer, self.contents)
            finally:
                os.close(self.writer)
                self.writer = None


class TaskOperationLockBarrier:
    """Hold the real per-task advisory lock while another XPC operation runs."""

    def __init__(self, data_directory, task_id):
        directory = Path(data_directory) / "task-operation-locks"
        directory.mkdir(parents=True, exist_ok=True)
        self.descriptor = os.open(directory / f"{task_id}.lock", os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.lockf(self.descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB, 0, 0, os.SEEK_SET)
        except BaseException:
            os.close(self.descriptor)
            self.descriptor = None
            raise

    def release(self):
        if self.descriptor is None:
            return
        fcntl.lockf(self.descriptor, fcntl.LOCK_UN, 0, 0, os.SEEK_SET)
        os.close(self.descriptor)
        self.descriptor = None


class TaskStoreWriteLockBarrier:
    """Hold the real shared task-store write lock across a final conversation save."""

    def __init__(self, data_directory):
        self.descriptor = os.open(Path(data_directory) / "store-write.lock", os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.lockf(self.descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB, 0, 0, os.SEEK_SET)
        except BaseException:
            os.close(self.descriptor)
            self.descriptor = None
            raise

    def release(self):
        if self.descriptor is None:
            return
        fcntl.lockf(self.descriptor, fcntl.LOCK_UN, 0, 0, os.SEEK_SET)
        os.close(self.descriptor)
        self.descriptor = None


class ConversationTurnLockBarrier:
    """Hold the real per-task conversation-turn reservation across XPC requests."""

    def __init__(self, data_directory, task_id):
        directory = Path(data_directory) / "conversation-turn-locks"
        directory.mkdir(parents=True, exist_ok=True)
        self.descriptor = os.open(directory / f"{task_id}.lock", os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.lockf(self.descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB, 0, 0, os.SEEK_SET)
        except BaseException:
            os.close(self.descriptor)
            self.descriptor = None
            raise

    def release(self):
        if self.descriptor is None:
            return
        fcntl.lockf(self.descriptor, fcntl.LOCK_UN, 0, 0, os.SEEK_SET)
        os.close(self.descriptor)
        self.descriptor = None


class RepositoryAllocationLockBarrier:
    """Hold the real repository-wide allocation lock across concurrent XPC requests."""

    def __init__(self, data_directory, repository):
        canonical_path = os.path.abspath(os.path.normpath(repository))
        lock_hash = 14695981039346656037
        for byte in os.fsencode(canonical_path):
            lock_hash = ((lock_hash ^ byte) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
        directory = Path(data_directory) / "repository-allocation-locks"
        directory.mkdir(parents=True, exist_ok=True)
        self.descriptor = os.open(directory / f"{lock_hash:016x}.lock", os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.lockf(self.descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB, 0, 0, os.SEEK_SET)
        except BaseException:
            os.close(self.descriptor)
            self.descriptor = None
            raise

    def release(self):
        if self.descriptor is None:
            return
        fcntl.lockf(self.descriptor, fcntl.LOCK_UN, 0, 0, os.SEEK_SET)
        os.close(self.descriptor)
        self.descriptor = None


class StationAIBridgeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cli = arguments.cli.absolute()
        cls.fixture = arguments.fixture_root.absolute()
        marker = cls.fixture / ".stationai-bridge-fixture"
        if not marker.is_file() or marker.read_text(encoding="utf-8") != "StationAI bridge tests own this deterministic fixture (v1).\n":
            raise RuntimeError(f"Refusing to use fixture without a valid ownership marker: {cls.fixture}")
        cls.primary = cls.fixture / "suggested-parent" / "primary"
        cls.secondary = cls.fixture / "suggested-parent" / "group" / "secondary"
        cls.alternate = cls.fixture / "suggested-parent" / "alternate-parent" / "alternate"
        cls.custom = cls.fixture / "suggested-parent" / "custom-folder"
        cls.changes = cls.fixture / "suggested-parent" / "changes"
        cls.empty_git_repository = cls.fixture / "empty-git-repo"
        cls.nested = cls.primary / "nested"
        cls.external = cls.fixture / "outside-parent" / "linked-outside"
        for path in [cls.primary, cls.secondary, cls.alternate, cls.custom, cls.nested, cls.external, cls.empty_git_repository]:
            if not path.is_dir():
                raise RuntimeError(f"Missing expected Git repository fixture: {path}")
        if not (cls.empty_git_repository / ".git").is_dir():
            raise RuntimeError(f"Missing empty Git repository metadata: {cls.empty_git_repository}")

    def setUp(self):
        self.test_id = f"{self._testMethodName}-{uuid.uuid4()}"
        self.data_directory = arguments.data_root / self.test_id
        self.data_directory.mkdir(parents=True)
        self.worktree_directory = self.data_directory / "worktrees"
        self.worktree_directory.mkdir()
        (self.worktree_directory / ".stationai-test-owner").write_text("StationAI bridge test owns this worktree root.\n", encoding="utf-8")
        self.defaults_suite = f"com.stationai.bridge-tests.{uuid.uuid4()}"
        if self._testMethodName != "test_task_store_repairs_missing_pending_prompt_column":
            self.assert_success(self.call_cli("settings", "set-parent", self.fixture / "suggested-parent")[0])

    def tearDown(self):
        marker = self.worktree_directory / ".stationai-test-owner"
        if marker.is_file() and marker.read_text(encoding="utf-8") == "StationAI bridge test owns this worktree root.\n":
            shutil.rmtree(self.worktree_directory)
            for repository in [self.primary, self.secondary, self.alternate, self.changes]:
                subprocess.run(["git", "-C", str(repository), "worktree", "prune"], check=False, capture_output=True)
        else:
            self.fail(f"Refusing to remove worktree fixture without its ownership marker: {self.worktree_directory}")

    def call_cli(self, *command, expected_status=0, timeout=90, extra_environment=None):
        environment = os.environ.copy()
        environment["STATIONAI_DATA_DIRECTORY"] = str(self.data_directory)
        environment["STATIONAI_E2E_WORKTREE_DIRECTORY"] = str(self.worktree_directory)
        environment["STATIONAI_E2E_DEFAULTS_SUITE"] = self.defaults_suite
        environment["STATIONAI_BRIDGE_SERVICE_NAME"] = arguments.service_name
        environment["CODEX_HOME"] = str(self.data_directory / "codex-home")
        environment.update(extra_environment or {})
        completed = subprocess.run(
            [str(self.cli), *map(str, command)],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
            timeout=timeout,
        )
        self.assertEqual(
            completed.returncode,
            expected_status,
            f"CLI exit mismatch for {command}: stdout={completed.stdout!r}; stderr={completed.stderr!r}",
        )
        lines = [line for line in completed.stdout.splitlines() if line.strip()]
        self.assertTrue(lines, f"CLI returned no JSON output for {command}: {completed.stderr}")
        try:
            response = json.loads(lines[-1])
        except json.JSONDecodeError as error:
            self.fail(f"CLI final output was not JSON for {command}: {error}; {lines[-1]!r}")
        self.assertEqual(response.get("version"), 1)
        self.assertIn("id", response)
        return response, [json.loads(line) for line in lines[:-1]]

    def start_cli(self, *command, extra_environment=None, binary_output=False):
        environment = os.environ.copy()
        environment["STATIONAI_DATA_DIRECTORY"] = str(self.data_directory)
        environment["STATIONAI_E2E_WORKTREE_DIRECTORY"] = str(self.worktree_directory)
        environment["STATIONAI_E2E_DEFAULTS_SUITE"] = self.defaults_suite
        environment["STATIONAI_BRIDGE_SERVICE_NAME"] = arguments.service_name
        environment["CODEX_HOME"] = str(self.data_directory / "codex-home")
        environment.update(extra_environment or {})
        return subprocess.Popen(
            [str(self.cli), *map(str, command)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=not binary_output,
            bufsize=0 if binary_output else -1,
            env=environment,
        )

    def finish_cli(self, process, command, expected_status=0, timeout=90):
        stdout, stderr = process.communicate(timeout=timeout)
        self.assertEqual(
            process.returncode,
            expected_status,
            f"CLI exit mismatch for {command}: stdout={stdout!r}; stderr={stderr!r}",
        )
        lines = [line for line in stdout.splitlines() if line.strip()]
        self.assertTrue(lines, f"CLI returned no JSON output for {command}: {stderr}")
        response = json.loads(lines[-1])
        self.assertEqual(response.get("version"), 1)
        self.assertIn("id", response)
        return response, [json.loads(line) for line in lines[:-1]]

    def restart_provider(self, executable):
        # The bridge daemon keeps one provider process alive across CLI calls, so
        # a fresh CLI read no longer implies a fresh provider. Stop this test's own
        # fixture provider (its path is unique to the test) so the next call
        # relaunches it and loads the thread again, as after a provider restart.
        subprocess.run(["pkill", "-f", str(executable)], check=False)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if subprocess.run(["pgrep", "-f", str(executable)], capture_output=True).returncode != 0:
                return
            time.sleep(0.05)
        self.fail(f"The fixture provider did not stop: {executable}")

    def assert_success(self, response):
        self.assertTrue(response.get("ok"), response.get("error"))
        return response.get("result")

    def assert_failure(self, response, code):
        self.assertFalse(response.get("ok"))
        self.assertEqual(response.get("error", {}).get("code"), code)

    def diagnostic_events(self):
        path = self.data_directory / "Diagnostics.jsonl"
        if not path.is_file():
            return []
        return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]

    def create_task(self, title="Bridge task", roots=None, provider=None):
        if roots is None:
            roots = [self.primary]
        command = ["task", "create", "--title", title]
        for root in roots:
            command.extend(["--root", root])
        if provider:
            command.extend(["--provider", provider])
        response, _ = self.call_cli(*command)
        return self.assert_success(response)

    def assert_user_stop_pauses_provider_turn(self, title, provider, environment_name, fixture_name):
        task = self.create_task(title, provider=provider)
        fixture_source = Path(__file__).resolve().parent / "fixtures" / fixture_name
        executable = self.data_directory / f"{provider}-fixture-hold-interrupt"
        shutil.copyfile(fixture_source, executable)
        executable.chmod(0o755)
        marker_name, marker_value = (
            (".stationai-codex-fixture-owner", "StationAI test owns this Codex protocol fixture (v1).\n")
            if provider == "codex" else
            (".stationai-claude-fixture-owner", "StationAI test owns this Claude Code protocol fixture (v1).\n")
        )
        (self.data_directory / marker_name).write_text(marker_value, encoding="utf-8")
        environment = {environment_name: str(executable)}
        ready = Path(str(executable) + ".interrupt-ready")
        received = Path(str(executable) + ".interrupt-received")
        release = Path(str(executable) + ".interrupt-release")
        send_results = {}
        send_failures = []
        stop_results = {}
        stop_failures = []

        def send_turn():
            try:
                send_results["response"], send_results["events"] = self.call_cli(
                    "conversation", "send", task["id"], "--message", "Hold until stopped.",
                    expected_status=1, timeout=45, extra_environment=environment,
                )
            except Exception as error:
                send_failures.append(error)

        sender = threading.Thread(target=send_turn, daemon=True)
        sender.start()
        deadline = time.monotonic() + 15
        while not ready.is_file() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(ready.is_file(), f"{provider} should reach its active thinking fixture before Stop.")
        active = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(active["status"], "In Progress")
        thread_id = active["codexThreadID"] if provider == "codex" else active["claudeSessionID"]
        self.assertTrue(thread_id, f"The {provider} turn should have a native conversation ID while it thinks.")
        thinking = self.assert_success(self.call_cli("conversation", "runtime")[0])
        self.assertIn(thread_id, thinking["activeThreadIDs"], "The daemon should report the thinking turn as active.")
        self.assertIn(thread_id, thinking["interruptibleThreadIDs"], "The daemon should report the thinking turn as interruptible.")

        def stop_turn():
            try:
                stop_results["response"] = self.call_cli(
                    "conversation", "stop", task["id"], timeout=20, extra_environment=environment,
                )[0]
            except Exception as error:
                stop_failures.append(error)

        stopper = threading.Thread(target=stop_turn, daemon=True)
        stopper.start()
        interrupt_deadline = time.monotonic() + 10
        while not received.is_file() and time.monotonic() < interrupt_deadline:
            time.sleep(0.02)
        self.assertTrue(received.is_file(), f"{provider} should receive its native interrupt before acknowledging it.")
        stopping = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(stopping["status"], "Waiting Response", "The task should leave In Progress before the provider acknowledges Stop.")
        release.write_text("acknowledge interrupt\n", encoding="utf-8")
        stopper.join(timeout=20)
        self.assertFalse(stopper.is_alive(), f"The {provider} interrupt acknowledgment should settle.")
        self.assertEqual(stop_failures, [])
        stopped = self.assert_success(stop_results["response"])
        self.assertTrue(stopped["interrupted"], f"{provider} should acknowledge its native turn interrupt.")
        sender.join(timeout=20)
        self.assertFalse(sender.is_alive(), f"The {provider} send should finish after its active turn is interrupted.")
        self.assertEqual(send_failures, [])
        self.assertTrue(received.is_file(), f"The {provider} fixture should confirm it received the native interrupt.")
        persisted = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(persisted["status"], "Waiting Response")
        settled = self.assert_success(self.call_cli("conversation", "runtime")[0])
        self.assertNotIn(thread_id, settled["activeThreadIDs"], "A stopped turn is no longer active in the daemon.")
        self.assertIn(thread_id, settled["interruptedThreadIDs"], "The daemon should remember that the turn was paused.")
        events = self.diagnostic_events()
        self.assertTrue(any(
            event.get("event") == "conversation.interrupt.finished"
            and event.get("taskID") == task["id"]
            and event.get("interrupted") == "true"
            for event in events
        ), f"The {provider} stop should be recorded as accepted.")
        failed_send = next((event for event in events
                            if event.get("event") == "conversation.send.failed"
                            and event.get("taskID") == task["id"]), None)
        self.assertIsNotNone(failed_send, "The stopped provider turn should settle through the send failure path.")
        self.assertIsNone(persisted.get("statusMessage"))

    # case-contract: test_codex_stop_interrupts_thinking_turn_and_waits_for_response | Clicking Stop during Codex reasoning immediately moves the task to Waiting Response and sends Codex's turn-scoped turn/interrupt request. The accepted interruption settles the send without changing the task to Blocked, and a fresh CLI/XPC read confirms the status persisted. A fresh `conversation runtime` read from the daemon reports the turn active and interruptible while it thinks, and interrupted but no longer active once the stop settles.
    def test_codex_stop_interrupts_thinking_turn_and_waits_for_response(self):
        self.assert_user_stop_pauses_provider_turn(
            "Codex stop while thinking", "codex", "STATIONAI_E2E_CODEX_EXECUTABLE", "codex-app-server-fixture.py"
        )

    # case-contract: test_claude_stop_interrupts_thinking_turn_and_waits_for_response | Clicking Stop during Claude reasoning immediately moves the task to Waiting Response and sends Claude's session-scoped control interrupt. The accepted interruption settles the send without changing the task to Blocked, and a fresh CLI/XPC read confirms the status persisted. A fresh `conversation runtime` read from the daemon reports the turn active and interruptible while it thinks, and interrupted but no longer active once the stop settles.
    def test_claude_stop_interrupts_thinking_turn_and_waits_for_response(self):
        self.assert_user_stop_pauses_provider_turn(
            "Claude stop while thinking", "claude", "STATIONAI_E2E_CLAUDE_EXECUTABLE", "claude-code-fixture.py"
        )

    def read_watcher_snapshot(self, watcher, predicate, timeout=15):
        """Reads `conversation runtime --watch` event lines until one runtime snapshot satisfies `predicate`."""
        deadline = time.monotonic() + timeout
        seen = []
        while time.monotonic() < deadline:
            readable, _, _ = select.select([watcher.stdout], [], [], 0.1)
            if not readable:
                continue
            line = watcher.stdout.readline()
            if not line.strip():
                continue
            event = json.loads(line.decode("utf-8"))
            if event.get("type") != "runtime_state":
                continue
            seen.append(event["payload"])
            if predicate(event["payload"]):
                return event["payload"]
        self.fail(f"No matching runtime snapshot arrived within {timeout}s; saw {seen}")

    @staticmethod
    def process_is_running(pid):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        return True

    def wait_until_process_exits(self, pid, timeout):
        deadline = time.monotonic() + timeout
        while self.process_is_running(pid) and time.monotonic() < deadline:
            time.sleep(0.1)
        return not self.process_is_running(pid)

    # case-contract: test_bridge_daemon_starts_on_demand_serves_watchers_and_exits_when_idle | The bridge daemon starts on the first request, serves later requests from the same process, and stays alive while any connection (such as a window's runtime watcher) is open. A watcher receives the daemon's runtime snapshots as a turn starts and stops, and the daemon exits by itself once the last connection closes and no request is running; the next request starts a fresh daemon on demand without any manual step.
    def test_bridge_daemon_starts_on_demand_serves_watchers_and_exits_when_idle(self):
        service = f"{arguments.service_name}.lifecycle-{uuid.uuid4().hex[:8]}"
        fixture_source = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-hold-interrupt"
        shutil.copyfile(fixture_source, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-codex-fixture-owner").write_text(
            "StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        environment = {
            "STATIONAI_BRIDGE_SERVICE_NAME": service,
            "STATIONAI_BRIDGE_IDLE_GRACE_SECONDS": "3",
            "STATIONAI_E2E_CODEX_EXECUTABLE": str(executable),
        }
        task = self.create_task("Daemon watcher", provider="codex")

        first = self.assert_success(self.call_cli("status", extra_environment=environment)[0])
        daemon_pid = first["processID"]
        self.assertTrue(self.process_is_running(daemon_pid), "The first request should have started a daemon.")
        second = self.assert_success(self.call_cli("status", extra_environment=environment)[0])
        self.assertEqual(second["processID"], daemon_pid, "Later requests should reuse the running daemon.")

        watcher = self.start_cli("conversation", "runtime", "--watch", extra_environment=environment, binary_output=True)
        try:
            idle = self.read_watcher_snapshot(watcher, lambda snapshot: True)
            self.assertEqual(idle["activeThreadIDs"], [], "A daemon with no turns reports nothing active.")
            time.sleep(4.5)
            self.assertTrue(self.process_is_running(daemon_pid), "An open watcher keeps the daemon alive past its idle grace.")
            self.assertEqual(
                self.assert_success(self.call_cli("status", extra_environment=environment)[0])["processID"], daemon_pid
            )

            ready = Path(str(executable) + ".interrupt-ready")
            release = Path(str(executable) + ".interrupt-release")
            sent = {}

            def send_turn():
                sent["response"], _ = self.call_cli(
                    "conversation", "send", task["id"], "--message", "Hold until stopped.",
                    expected_status=1, timeout=45, extra_environment=environment,
                )

            sender = threading.Thread(target=send_turn, daemon=True)
            sender.start()
            deadline = time.monotonic() + 15
            while not ready.is_file() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(ready.is_file(), "The held turn should be thinking before the watcher is checked.")
            thread_id = self.assert_success(self.call_cli("task", "get", task["id"])[0])["codexThreadID"]
            running = self.read_watcher_snapshot(watcher, lambda snapshot: thread_id in snapshot["activeThreadIDs"])
            self.assertIn(thread_id, running["interruptibleThreadIDs"])

            stopper = threading.Thread(
                target=lambda: self.call_cli("conversation", "stop", task["id"], timeout=20, extra_environment=environment),
                daemon=True,
            )
            stopper.start()
            received = Path(str(executable) + ".interrupt-received")
            deadline = time.monotonic() + 10
            while not received.is_file() and time.monotonic() < deadline:
                time.sleep(0.02)
            release.write_text("acknowledge interrupt\n", encoding="utf-8")
            stopper.join(timeout=20)
            sender.join(timeout=20)
            stopped = self.read_watcher_snapshot(watcher, lambda snapshot: thread_id not in snapshot["activeThreadIDs"])
            self.assertIn(thread_id, stopped["interruptedThreadIDs"])
        finally:
            watcher.terminate()
            watcher.wait(timeout=10)

        self.assertTrue(
            self.wait_until_process_exits(daemon_pid, timeout=20),
            "The daemon should exit by itself once its last connection closes and no request is running.",
        )
        restarted = self.assert_success(self.call_cli("status", extra_environment=environment)[0])
        self.assertNotEqual(restarted["processID"], daemon_pid, "The next request should start a fresh daemon on demand.")
        self.assertTrue(self.process_is_running(restarted["processID"]))

    # case-contract: test_bridge_daemon_death_fails_the_turn_and_recovers_on_next_request | When the bridge daemon dies in the middle of a turn, that turn's send fails with a connection error instead of hanging. The next request starts a fresh daemon on demand, which reconciles the task out of In Progress into a resumable Waiting Response, and that daemon can run and stop a new turn.
    def test_bridge_daemon_death_fails_the_turn_and_recovers_on_next_request(self):
        service = f"{arguments.service_name}.death-{uuid.uuid4().hex[:8]}"
        fixture_source = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-hold-interrupt"
        shutil.copyfile(fixture_source, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-codex-fixture-owner").write_text(
            "StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        environment = {
            "STATIONAI_BRIDGE_SERVICE_NAME": service,
            "STATIONAI_E2E_CODEX_EXECUTABLE": str(executable),
        }
        task = self.create_task("Daemon death", provider="codex")
        first_pid = self.assert_success(self.call_cli("status", extra_environment=environment)[0])["processID"]
        ready = Path(str(executable) + ".interrupt-ready")
        received = Path(str(executable) + ".interrupt-received")
        release = Path(str(executable) + ".interrupt-release")
        sent = {}

        def send_turn(key, expected_status):
            sent[key], _ = self.call_cli(
                "conversation", "send", task["id"], "--message", "Hold until the daemon dies.",
                expected_status=expected_status, timeout=45, extra_environment=environment,
            )

        sender = threading.Thread(target=send_turn, args=("first", 69), daemon=True)
        sender.start()
        deadline = time.monotonic() + 15
        while not ready.is_file() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(ready.is_file(), "The turn should be running before the daemon dies.")
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task["id"])[0])["status"], "In Progress")

        os.kill(first_pid, signal.SIGKILL)
        sender.join(timeout=20)
        self.assertFalse(sender.is_alive(), "A send must fail promptly when its daemon dies, not hang.")
        self.assert_failure(sent["first"], "service_unavailable")
        self.restart_provider(executable)

        # The next request starts a fresh daemon, which settles the orphaned turn.
        self.assert_success(self.call_cli("conversation", "history", task["id"], extra_environment=environment)[0])
        recovered = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(recovered["status"], "Waiting Response")
        self.assertIn("closed while this turn was running", recovered.get("statusMessage") or "")
        second_pid = self.assert_success(self.call_cli("status", extra_environment=environment)[0])["processID"]
        self.assertNotEqual(second_pid, first_pid)
        self.assertTrue(self.process_is_running(second_pid))

        # The fresh daemon owns turns again: run one and stop it.
        for marker in (ready, received, release):
            marker.unlink(missing_ok=True)
        rerun = threading.Thread(target=send_turn, args=("second", 1), daemon=True)
        rerun.start()
        deadline = time.monotonic() + 15
        while not ready.is_file() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(ready.is_file(), "The fresh daemon should run a new turn.")
        stopper = threading.Thread(
            target=lambda: self.call_cli("conversation", "stop", task["id"], timeout=20, extra_environment=environment),
            daemon=True,
        )
        stopper.start()
        deadline = time.monotonic() + 10
        while not received.is_file() and time.monotonic() < deadline:
            time.sleep(0.02)
        release.write_text("acknowledge interrupt\n", encoding="utf-8")
        stopper.join(timeout=20)
        rerun.join(timeout=20)
        self.assertFalse(rerun.is_alive())
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task["id"])[0])["status"], "Waiting Response")

    def assert_rejected_stop_restores_active_status(self, provider, environment_name, fixture_name):
        task = self.create_task(f"{provider.title()} rejected stop", provider=provider)
        fixture_source = Path(__file__).resolve().parent / "fixtures" / fixture_name
        executable = self.data_directory / f"{provider}-fixture-hold-reject-interrupt"
        shutil.copyfile(fixture_source, executable)
        executable.chmod(0o755)
        marker_name, marker_value = (
            (".stationai-codex-fixture-owner", "StationAI test owns this Codex protocol fixture (v1).\n")
            if provider == "codex" else
            (".stationai-claude-fixture-owner", "StationAI test owns this Claude Code protocol fixture (v1).\n")
        )
        (self.data_directory / marker_name).write_text(marker_value, encoding="utf-8")
        environment = {environment_name: str(executable)}
        ready = Path(str(executable) + ".interrupt-ready")
        received = Path(str(executable) + ".interrupt-received")
        reject = Path(str(executable) + ".interrupt-reject")
        release = Path(str(executable) + ".interrupt-release")
        send_result = {}
        send_failures = []

        def send_turn():
            try:
                send_result["response"], _ = self.call_cli(
                    "conversation", "send", task["id"], "--message", "Hold until stopped.",
                    timeout=45, extra_environment=environment,
                )
            except Exception as error:
                send_failures.append(error)

        sender = threading.Thread(target=send_turn, daemon=True)
        sender.start()
        deadline = time.monotonic() + 15
        while not ready.is_file() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(ready.is_file(), f"{provider} should be thinking before rejected Stop.")
        stop_result = {}
        stop_failures = []

        def reject_stop():
            try:
                stop_result["response"], _ = self.call_cli(
                    "conversation", "stop", task["id"], expected_status=1, timeout=20, extra_environment=environment,
                )
            except Exception as error:
                stop_failures.append(error)

        stopper = threading.Thread(target=reject_stop, daemon=True)
        stopper.start()
        interrupt_deadline = time.monotonic() + 10
        while not received.is_file() and time.monotonic() < interrupt_deadline:
            time.sleep(0.02)
        self.assertTrue(received.is_file(), f"{provider} should receive its native interrupt before rejecting it.")
        stopping = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(stopping["status"], "Waiting Response", "The optimistic pause should persist while rejection is pending.")
        reject.write_text("reject interrupt\n", encoding="utf-8")
        stopper.join(timeout=20)
        self.assertFalse(stopper.is_alive(), f"{provider} should return its interrupt rejection.")
        self.assertEqual(stop_failures, [])
        failed_stop = stop_result["response"]
        self.assertFalse(failed_stop.get("ok", True), f"{provider} rejection should reach the caller as a failed stop.")
        active = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(active["status"], "In Progress", "A rejected interrupt must restore the active task while its turn continues.")
        release.write_text("finish active turn\n", encoding="utf-8")
        sender.join(timeout=20)
        self.assertFalse(sender.is_alive(), f"{provider} should complete after the fixture releases its still-active turn.")
        self.assertEqual(send_failures, [])
        self.assert_success(send_result["response"])
        completed = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(completed["status"], "Waiting Response", "The non-interrupted turn should finish normally and return the task for review.")

    # case-contract: test_codex_stop_rejection_restores_active_task | If Codex rejects turn/interrupt while its turn is still active, Stop reports the provider failure and the task returns to In Progress; releasing the fixture lets the original turn complete normally into Waiting Response.
    def test_codex_stop_rejection_restores_active_task(self):
        self.assert_rejected_stop_restores_active_status("codex", "STATIONAI_E2E_CODEX_EXECUTABLE", "codex-app-server-fixture.py")

    # case-contract: test_claude_stop_rejection_restores_active_task | If Claude rejects its session control interrupt while its turn is still active, Stop reports the provider failure and the task returns to In Progress; releasing the fixture lets the original turn complete normally into Waiting Response.
    def test_claude_stop_rejection_restores_active_task(self):
        self.assert_rejected_stop_restores_active_status("claude", "STATIONAI_E2E_CLAUDE_EXECUTABLE", "claude-code-fixture.py")

    def create_repo_task(self, title, repositories, branches=None, branch_from=None, roots=None, merge_targets=None, materialize=False):
        command = ["task", "create", "--title", title]
        for repository in repositories:
            command.extend(["--repo", repository])
        for repository, branch in (branches or {}).items():
            command.extend(["--branch", f"{repository}={branch}"])
        for repository, branch in (branch_from or {}).items():
            command.extend(["--branch-from", f"{repository}={branch}"])
        for repository, branch in (merge_targets or {}).items():
            command.extend(["--merge-target", f"{repository}={branch}"])
        for root in roots or []:
            command.extend(["--root", root])
        response, _ = self.call_cli(*command)
        task = self.assert_success(response)
        if materialize:
            self.complete_fixture_turn(task["id"])
            task = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        return task

    def complete_fixture_turn(self, task_id, executable_name="codex-fixture", message="Complete this task."):
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / executable_name
        hold_marker = Path(str(executable) + ".hold-release")
        hold_marker.touch()
        (self.data_directory / ".stationai-codex-fixture-owner").write_text(
            "StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        environment = {
            "STATIONAI_E2E_CODEX_EXECUTABLE": str(executable),
        }
        command = [
            "conversation", "send", task_id, "--message", message,
            "--answer", "color=Blue", "--answer", "token=fixture-secret",
        ]
        active = Path(str(executable) + ".turn-active")
        release = Path(str(executable) + ".turn-release")
        active.unlink(missing_ok=True)
        release.unlink(missing_ok=True)
        process = self.start_cli(*command, extra_environment=environment)
        try:
            deadline = time.monotonic() + 90
            outcome_count = 0
            while process.poll() is None and time.monotonic() < deadline:
                if active.exists() and not release.exists():
                    response, _ = self.call_cli(
                        "task", "outcome", task_id, "completed", extra_environment=environment,
                    )
                    self.assertEqual(self.assert_success(response)["outcome"], "completed")
                    outcome_count += 1
                    release.write_text("Release the completed fixture turn.\n", encoding="utf-8")
                time.sleep(0.02)
            self.assertGreater(outcome_count, 0, "The fixture should hold each turn until its explicit outcome is reported.")
            response, _ = self.finish_cli(process, command)
        finally:
            if process.poll() is None:
                release.write_text("Release the fixture turn.\n", encoding="utf-8")
                process.communicate(timeout=20)
            active.unlink(missing_ok=True)
            release.unlink(missing_ok=True)
            hold_marker.unlink(missing_ok=True)
        result = self.assert_success(response)
        current, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(current)["status"], "Review")
        return result

    def complete_standalone_chat_fixture_turn(self, chat_task_id, message, continues=True, new_title=None, executable_name="codex-fixture-chat", skip_close_turn=False):
        """Drive one real provider turn on the hidden standalone chat task, simulating the
        agent's mandatory `chat page close-turn` tool call instead of `task outcome`.
        `skip_close_turn=True` simulates an agent that forgets to classify the turn, so the
        missed-signal compliance tracking can be exercised."""
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / executable_name
        hold_marker = Path(str(executable) + ".hold-release")
        hold_marker.touch()
        (self.data_directory / ".stationai-codex-fixture-owner").write_text(
            "StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        environment = {"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)}
        command = ["conversation", "send", chat_task_id, "--message", message]
        active = Path(str(executable) + ".turn-active")
        release = Path(str(executable) + ".turn-release")
        active.unlink(missing_ok=True)
        release.unlink(missing_ok=True)
        process = self.start_cli(*command, extra_environment=environment)
        try:
            deadline = time.monotonic() + 90
            close_turn_count = 0
            while process.poll() is None and time.monotonic() < deadline:
                if active.exists() and not release.exists():
                    if not skip_close_turn:
                        close_turn_args = [
                            "chat", "page", "close-turn", chat_task_id,
                            "--continues", "true" if continues else "false",
                        ]
                        if new_title:
                            close_turn_args += ["--new-title", new_title]
                        response, _ = self.call_cli(*close_turn_args, extra_environment=environment)
                        self.assert_success(response)
                        close_turn_count += 1
                    release.write_text("Release the completed fixture turn.\n", encoding="utf-8")
                time.sleep(0.02)
            if not skip_close_turn:
                self.assertGreater(close_turn_count, 0, "The fixture should hold the turn until its chat page close-turn signal.")
            response, _ = self.finish_cli(process, command)
        finally:
            if process.poll() is None:
                release.write_text("Release the fixture turn.\n", encoding="utf-8")
                process.communicate(timeout=20)
            active.unlink(missing_ok=True)
            release.unlink(missing_ok=True)
            hold_marker.unlink(missing_ok=True)
        return self.assert_success(response)

    def seed_legacy_standalone_chat_task(self, session_id="legacy-chat-session"):
        """Recreate a standalone chat stored as a hidden board task, as before the split."""
        repository_root = Path(__file__).resolve().parent.parent
        executable = self.data_directory / "seed-legacy-standalone-chat-task"
        subprocess.run(
            [
                # Self-contained: it declares the pre-split BoardTask itself, so compiling it
                # against the current models would redeclare the entity.
                "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-O",
                str(repository_root / "scripts" / "seed-legacy-standalone-chat-task.swift"),
                "-o", str(executable),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        result = subprocess.run(
            [str(executable), str(self.data_directory), session_id],
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip().splitlines()[-1]

    def seed_done_task_pull_request(self, task_id, number=123, repository_index=0):
        repository_root = Path(__file__).resolve().parent.parent
        executable = self.data_directory / "seed-task-pr-link"
        subprocess.run(
            [
                "xcrun", "swiftc", "-module-name", "StationAI",
                str(repository_root / "StationAI" / "App" / "BoardTask.swift"),
                str(repository_root / "StationAI" / "App" / "ConversationSubject.swift"),
                str(repository_root / "scripts" / "seed-task-pr-link.swift"),
                "-o", str(executable),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        seeded_url = f"https://github.com/stationai-test/fixture/pull/{number}"
        command = [str(executable), str(self.data_directory), task_id, str(number), seeded_url]
        if repository_index:
            command.append(str(repository_index))
        result = subprocess.run(
            command,
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertIn(f"Seeded linked PR #{number}", result.stdout)
        return seeded_url

    def start_progress_fixture_turn(self, task_id, fixture_name, answers=()):
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / fixture_name
        (self.data_directory / ".stationai-codex-fixture-owner").write_text(
            "StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        environment = os.environ.copy()
        environment.update({
            "STATIONAI_DATA_DIRECTORY": str(self.data_directory),
            "STATIONAI_E2E_WORKTREE_DIRECTORY": str(self.worktree_directory),
            "STATIONAI_E2E_DEFAULTS_SUITE": self.defaults_suite,
            "STATIONAI_BRIDGE_SERVICE_NAME": arguments.service_name,
            "STATIONAI_E2E_CODEX_EXECUTABLE": str(executable),
        })
        command = [str(self.cli), "conversation", "send", task_id, "--message", "Work on this task."]
        for answer in answers:
            command.extend(["--answer", answer])
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment)
        active = Path(str(executable) + ".turn-active")
        release = Path(str(executable) + ".turn-release")
        deadline = time.monotonic() + 10
        while not active.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        if not active.exists():
            release.write_text("Release the active turn.\n", encoding="utf-8")
            process.communicate(timeout=20)
            self.fail(f"Fixture turn {fixture_name} did not become active.")
        return process, executable, active, release

    def prepare_workspace_changes(self):
        marker = self.fixture / ".stationai-bridge-fixture"
        if not marker.is_file() or marker.read_text(encoding="utf-8") != "StationAI bridge tests own this deterministic fixture (v1).\n":
            raise RuntimeError(f"Refusing to modify the Git fixture without its ownership marker: {self.fixture}")

        self.run_git(self.changes, "reset", "--mixed", "HEAD")
        self.run_git(self.changes, "checkout", "--", ".")
        (self.changes / "staged.txt").write_text("Staged index version.\n", encoding="utf-8")
        (self.changes / "shared.txt").write_text("Shared index version.\n", encoding="utf-8")
        (self.changes / "syntax.json").write_text('{"value":"working version"}\n', encoding="utf-8")
        for path in ["staged.txt", "shared.txt"]:
            self.run_git(self.changes, "add", path)
        (self.changes / "shared.txt").write_text("Shared working version.\n", encoding="utf-8")
        (self.changes / "working.txt").write_text("Working tree version.\n", encoding="utf-8")
        (self.changes / "deleted.txt").unlink(missing_ok=True)
        (self.changes / "untracked.txt").write_text("Untracked file.\n", encoding="utf-8")
        if (self.changes / "staged-deleted.txt").exists():
            self.run_git(self.changes, "rm", "staged-deleted.txt")

    def run_git(self, repository, *arguments):
        completed = subprocess.run(
            ["git", "-C", str(repository), *arguments],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, f"{completed.stderr}\n{completed.stdout}")
        return completed.stdout

    def branch_exists(self, repository, branch):
        return subprocess.run(
            ["git", "-C", str(repository), "show-ref", "--verify", "--quiet", f"refs/heads/{branch}"],
            check=False,
            capture_output=True,
            text=True,
        ).returncode == 0

    def changes_diff(self, task_id, path, group, expected_status=0, repository=None):
        response, _ = self.call_cli(
            "task", "changes", "diff", task_id,
            "--repository", repository or self.changes,
            "--path", path,
            "--group", group,
            expected_status=expected_status,
        )
        return response

    # case-contract: test_standalone_chat_legacy_hidden_task_migrates | A standalone chat left in the store as a hidden board task is converted once into its own model: it keeps its ID so the existing conversation transcript stays attached, keeps its provider session, carries its in-flight turn state across with the status message and progress report that explain it, is removed from the board so it never lists or resolves as a task, and reopening the chat returns that same migrated chat rather than creating a second one.
    def test_standalone_chat_legacy_hidden_task_migrates(self):
        # The seeded row is a real hidden board task, exactly as the old design stored it.
        # Reading the board is itself a migration trigger, so the first read already asserts
        # the converted state rather than the pre-migration one.
        legacy_id = self.seed_legacy_standalone_chat_task(session_id="legacy-chat-session")

        opened = self.assert_success(self.call_cli("chat", "open")[0])
        self.assertEqual(
            opened["id"], legacy_id,
            "The migrated chat must keep its ID so its existing transcript stays attached.",
        )
        self.assertEqual(opened["claudeSessionID"], "legacy-chat-session", "The chat's provider session must survive migration.")
        # The turn state must arrive with its explanation, not just the raw status.
        self.assertEqual(opened["status"], "In Progress")
        self.assertEqual(opened["statusMessage"], "Carried from the legacy chat task.")
        self.assertEqual(opened["progressType"], "searching")
        self.assertEqual(opened["progressLabel"], "Searching")
        self.assertEqual(opened["progressDetail"], "Looking into volcanoes")
        self.assertEqual(opened["repositoryWorktrees"], [])

        self.assertEqual(
            self.assert_success(self.call_cli("task", "list")[0])["tasks"], [],
            "The migrated chat must no longer be a board task.",
        )
        response, _ = self.call_cli("task", "get", legacy_id, expected_status=3)
        self.assert_failure(response, "not_found")

        reopened = self.assert_success(self.call_cli("chat", "open")[0])
        self.assertEqual(reopened["id"], legacy_id, "Migration must run once, not create a second chat.")

    # case-contract: test_standalone_chat_separate_model_and_pages_round_trip | The Chat button opens the standalone chat — its own model rather than a board task — in a sliding sidebar that never appears on the board, task commands cannot reach it by ID, and the bridge rejects any attempt to add a repository or worktree root to it. The GUI composer works without a configured repository parent and omits task status, repository controls, and the Changes sidebar. Its CLI page close-turn signal keeps a continuing reply on the active page and starts a new titled page on a topic change, a completed turn's user and assistant messages persist onto the active page without leaking onto other pages, and pages are findable by search. Each page is also stored in a separate atomic JSON file in a discoverable archive directory; pages already present before file archiving are backfilled once, and each file tracks current metadata and messages. A turn that omits close-turn is tracked as missed, then a background low-effort Luna fallback rejects one malformed classification and retries, moves both messages to its correctly titled page, keeps page evaluation visually quiet while the primary answer remains usable, then updates the transcript separator with the title when classification completes; a following send waits for that decision, and preserves chronological order on a later append. An explicit page start during a pending fallback cancels its stale result, keeps the missed turn on its original page, and clears the warning. If all helper results are invalid, the pending decision remains durable, blocks the next provider send, and retries after the helper recovers; the UI keeps the unresolved state visually quiet and sends successfully once recovery completes. Earlier pages stay visible in the transcript after their page session rotates, and a board task conversation rejects a chat page as turn context. While a chat turn is held active, queuing a follow-up on the chat resolves the chat rather than a board task and the queued message can be removed, and selecting the provider the chat already uses returns the chat unchanged instead of failing. The chat's own turn state changes (In Progress, then Waiting Response) during a send, and it never renders as a card on the visible Kanban board in any state. A chat turn never triggers the private task-outcome reminders, because the chat is told not to report an outcome; its developer instructions teach it that task language means StationAI's own board and give it the StationAI task CLI, and they never ask it to write the page title into its visible answer.
    def test_standalone_chat_separate_model_and_pages_round_trip(self):
        opened = self.assert_success(self.call_cli("chat", "open")[0])
        self.assertEqual(opened["title"], "Chat")
        self.assertEqual(opened["repositoryWorktrees"], [])
        self.assertEqual(opened["workspaceRoots"], [])
        chat_task_id = opened["id"]

        reopened = self.assert_success(self.call_cli("chat", "open")[0])
        self.assertEqual(reopened["id"], chat_task_id, "Opening chat twice must reuse the same chat.")

        tasks = self.assert_success(self.call_cli("task", "list")[0])["tasks"]
        self.assertFalse(
            any(task["id"] == chat_task_id for task in tasks),
            "The standalone chat must never appear in board.list/task.list.",
        )
        # The chat is its own model, not a task, so task commands cannot reach it at all.
        # This is the separation itself, not a filter that could be forgotten somewhere.
        response, _ = self.call_cli("task", "get", chat_task_id, expected_status=3)
        self.assert_failure(response, "not_found")
        response, _ = self.call_cli("task", "move", chat_task_id, "Done", expected_status=3)
        self.assert_failure(response, "not_found")
        self.assert_success(self.call_cli("settings", "clear-parent")[0])
        self.assertIsNone(self.assert_success(self.call_cli("settings", "get")[0])["defaultParentFolder"])

        kyoto = self.assert_success(self.call_cli("chat", "page", "new", "--title", "Trip to Kyoto")[0])["page"]
        self.assertEqual(kyoto["title"], "Trip to Kyoto")
        self.assertEqual(kyoto["messageCount"], 0)

        continued = self.assert_success(
            self.call_cli("chat", "page", "close-turn", chat_task_id, "--continues", "true")[0]
        )["page"]
        self.assertEqual(continued["id"], kyoto["id"], "Continuing must append to the already-active page.")

        recipes = self.assert_success(
            self.call_cli(
                "chat", "page", "close-turn", chat_task_id,
                "--continues", "false", "--new-title", "Dinner recipes",
            )[0]
        )["page"]
        self.assertNotEqual(recipes["id"], kyoto["id"], "A topic change must start a new page.")
        self.assertEqual(recipes["title"], "Dinner recipes")

        self.call_cli(
            "chat", "page", "close-turn", chat_task_id, "--continues", "false",
            expected_status=2,
        )

        page_listing = self.assert_success(self.call_cli("chat", "page", "list")[0])
        pages = page_listing["pages"]
        self.assertEqual({page["id"] for page in pages}, {kyoto["id"], recipes["id"]})
        archive_directory = self.data_directory / "StandaloneChat-Pages"
        self.assertEqual(page_listing["archiveDirectory"], str(archive_directory))
        self.assertEqual(
            {path.stem for path in archive_directory.glob("*.json")},
            {kyoto["id"], recipes["id"]},
            "Every page should have a separate JSON file with its page ID as the filename.",
        )
        # Recreate the pre-archive database state: pages exist, but the one-time
        # export migration marker does not. The next manager open must backfill.
        with sqlite3.connect(self.data_directory / "StandaloneChat-v1.sqlite") as connection:
            connection.execute("DELETE FROM chat_archive_migrations WHERE version = 1")
        (archive_directory / f"{kyoto['id']}.json").unlink()
        self.assert_success(self.call_cli("chat", "page", "list")[0])
        self.assertTrue((archive_directory / f"{kyoto['id']}.json").is_file(), "Opening a pre-archive database should backfill missing page files once.")
        for page in pages:
            archive = json.loads((archive_directory / f"{page['id']}.json").read_text(encoding="utf-8"))
            self.assertEqual(archive["page"]["title"], page["title"])
            self.assertEqual(archive["messages"], [])

        matches = self.assert_success(self.call_cli("chat", "page", "search", "Kyoto")[0])["matches"]
        self.assertTrue(
            any(match["page"]["id"] == kyoto["id"] for match in matches),
            "Searching the old page's title should find it even after a newer page is active.",
        )

        read_back = self.assert_success(self.call_cli("chat", "page", "read", kyoto["id"])[0])
        self.assertEqual(read_back["page"]["id"], kyoto["id"])
        self.assertEqual(read_back["messages"], [])

        # A real provider turn that continues the active page ("Dinner recipes") must persist
        # both the user's message and the assistant's reply into that page, not just bookkeeping.
        self.complete_standalone_chat_fixture_turn(chat_task_id, "What's a good side dish?", continues=True, executable_name="codex-fixture-chat-unique-turns-hold-release")
        recipes_archive_path = archive_directory / f"{recipes['id']}.json"
        recipes_archive = json.loads(recipes_archive_path.read_text(encoding="utf-8"))
        self.assertEqual(recipes_archive["page"]["title"], "Dinner recipes")
        self.assertTrue(any(message["text"] == "What's a good side dish?" for message in recipes_archive["messages"]))
        recipes_messages = self.assert_success(self.call_cli("chat", "page", "read", recipes["id"])[0])["messages"]
        self.assertTrue(
            any(message["role"] == "user" and message["text"] == "What's a good side dish?" for message in recipes_messages),
            "The user's message should be persisted on the page the agent's close-turn call selected.",
        )
        self.assertTrue(
            any(message["role"] == "assistant" and message["text"] for message in recipes_messages),
            "The assistant's reply should also be persisted on that page.",
        )
        # A send moves the chat's own turn state away from Backlog. That state used to belong to
        # a hidden BoardTask, which is how the chat leaked onto the visible Kanban board; it now
        # lives on the chat's own model, so no status value can put it in a board column.
        chat_turn_state = self.assert_success(self.call_cli("chat", "open")[0])["status"]
        self.assertIn(chat_turn_state, ["In Progress", "Waiting Response"], "A completed send should move the chat's own turn state.")
        self.assertEqual(
            self.assert_success(self.call_cli("task", "list")[0])["tasks"], [],
            "The standalone chat must stay absent from task/board listing in every turn state.",
        )
        # The chat is told never to report a task outcome, so chasing one with private
        # reminders can only spend extra provider turns and bury the user's next message in
        # a reminder turn that answers nobody.
        chat_fixture_history = json.loads(
            Path(str(self.data_directory / "codex-fixture-chat-unique-turns-hold-release") + ".history").read_text(encoding="utf-8")
        )
        self.assertTrue(chat_fixture_history.get("turns"), "The chat fixture should have recorded its turns.")
        self.assertFalse(
            any("outcome reminder" in (turn.get("userMessage") or "").lower() for turn in chat_fixture_history["turns"]),
            "A standalone chat turn must not trigger the private task-outcome reminders.",
        )
        # The chat must know it is StationAI's own chat and own the board through the CLI,
        # instead of reaching for an unrelated task tool that the user can never see.
        chat_instructions = chat_fixture_history.get("threadStartDeveloperInstructions") or ""
        self.assertIn("task create", chat_instructions, "The chat must be taught the StationAI task CLI.")
        self.assertIn("they always mean StationAI", chat_instructions)
        # Page titles reach the user as transcript separators, parsed from close-turn.
        # Assert the prohibition positively too: pinning only the old wording would let the
        # instruction come back phrased differently.
        self.assertIn("never write the page name", chat_instructions)
        self.assertNotIn("Page: <current page title>", chat_instructions)
        recipes_read = self.assert_success(self.call_cli("chat", "page", "read", recipes["id"])[0])
        self.assertEqual(recipes_read["filePath"], str(recipes_archive_path))
        recipes_archive = json.loads(Path(recipes_read["filePath"]).read_text(encoding="utf-8"))
        self.assertEqual(recipes_archive["page"]["title"], "Dinner recipes")
        self.assertEqual(
            [message["text"] for message in recipes_archive["messages"]],
            [message["text"] for message in recipes_messages],
            "The per-page file should contain the current persisted transcript.",
        )
        self.assertEqual(
            self.assert_success(self.call_cli("chat", "page", "read", kyoto["id"])[0])["messages"], [],
            "Messages from the recipes turn must not leak onto an unrelated page.",
        )

        # The compliant turn above must be reflected as compliant in chat status.
        status = self.assert_success(self.call_cli("chat", "status")[0])
        self.assertFalse(status["missedPreviousPageSignal"], "A turn that called close-turn must not be flagged as missed.")
        self.assertEqual(status["activePage"]["id"], recipes["id"])

        # Standalone chat can never gain a repository/worktree, regardless of who tries.
        self.assert_failure(
            self.call_cli("task", "repository", "add", chat_task_id, "--repo", str(self.primary), expected_status=2)[0],
            "invalid_argument",
        )

        # The primary agent omits close-turn; the cheap, background Codex fallback must
        # classify the distinct topic and move that turn onto a titled page.
        classifier_executable = self.data_directory / "codex-fixture-chat-unique-turns-hold-release"
        classifier_hold = Path(str(classifier_executable) + ".hold-classifier")
        classifier_active = Path(str(classifier_executable) + ".classifier-active")
        classifier_release = Path(str(classifier_executable) + ".classifier-release")
        classifier_active.unlink(missing_ok=True)
        classifier_release.unlink(missing_ok=True)
        classifier_hold.touch()
        self.complete_standalone_chat_fixture_turn(
            chat_task_id,
            "Tell me about Saturn's rings",
            skip_close_turn=True,
            executable_name="codex-fixture-chat-unique-turns-hold-release",
        )
        classifier_command = ("chat", "status")
        classifier_process = self.start_cli(
            *classifier_command,
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(classifier_executable)},
        )
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and not classifier_active.exists():
            time.sleep(0.02)
        self.assertTrue(classifier_active.exists(), "The fixture should hold the fallback after the primary send returns.")

        followup_command = ("conversation", "send", chat_task_id, "--message", "One more thought about Saturn")
        followup_turn_hold = Path(str(classifier_executable) + ".hold-release")
        followup_turn_active = Path(str(classifier_executable) + ".turn-active")
        followup_turn_release = Path(str(classifier_executable) + ".turn-release")
        followup_turn_active.unlink(missing_ok=True)
        followup_turn_release.unlink(missing_ok=True)
        followup_turn_hold.touch()
        followup_process = self.start_cli(
            *followup_command,
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(classifier_executable)},
        )
        try:
            time.sleep(0.2)
            self.assertIsNone(followup_process.poll(), "A follow-up turn must wait until the pending page decision finishes.")
            pending_history = json.loads(Path(str(classifier_executable) + ".history").read_text(encoding="utf-8"))
            self.assertFalse(
                any((turn.get("userMessage") or "").startswith("One more thought about Saturn") for turn in pending_history.get("turns", [])),
                "The next provider turn must not overtake the held page classification.",
            )
        finally:
            classifier_release.write_text("Release classifier.\n", encoding="utf-8")
        classifier_response, _ = self.finish_cli(classifier_process, classifier_command)
        fallback_status = self.assert_success(classifier_response)
        fallback_archive_path = archive_directory / f"{fallback_status['activePage']['id']}.json"
        fallback_archive = json.loads(fallback_archive_path.read_text(encoding="utf-8"))
        self.assertEqual(fallback_archive["page"]["title"], "Saturn Rings")
        self.assertTrue(any(message["text"] == "Tell me about Saturn's rings" for message in fallback_archive["messages"]))
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and not followup_turn_active.exists():
            time.sleep(0.02)
        self.assertTrue(followup_turn_active.exists(), "The queued follow-up should reach the fixture after classification resolves.")
        # Queuing is a conversation action, so it must resolve the chat and not look for a
        # board task. The turn is held active here, which is exactly when a follow-up queues.
        queued_in_chat = self.assert_success(
            self.call_cli("conversation", "queue", chat_task_id, "--message", "Queue this for after the chat turn.")[0]
        )
        self.assertEqual(queued_in_chat["text"], "Queue this for after the chat turn.")
        self.assertEqual(queued_in_chat["taskID"], chat_task_id)
        self.assert_success(self.call_cli("conversation", "queue-remove", chat_task_id, queued_in_chat["id"])[0])
        # Selecting the provider the chat already uses is a no-op that must return the chat.
        unchanged_provider = self.assert_success(
            self.call_cli("conversation", "provider", chat_task_id, "set", "codex")[0]
        )
        self.assertEqual(unchanged_provider["id"], chat_task_id)
        self.assertEqual(unchanged_provider["conversationProvider"], "codex")
        followup_turn_release.write_text("Release follow-up turn.\n", encoding="utf-8")
        followup_response, _ = self.finish_cli(followup_process, followup_command)
        followup_turn_hold.unlink(missing_ok=True)
        followup_turn_active.unlink(missing_ok=True)
        followup_turn_release.unlink(missing_ok=True)
        self.assert_success(followup_response)
        followup_status = self.assert_success(self.call_cli(
            "chat", "status",
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(classifier_executable)},
        )[0])
        self.assertFalse(followup_status["missedPreviousPageSignal"])
        self.assertEqual(followup_status["activePage"]["title"], "Saturn Rings")

        self.assertFalse(fallback_status["missedPreviousPageSignal"], "The background fallback should clear the missed-signal warning after applying its classification.")
        self.assertEqual(fallback_status["activePage"]["title"], "Saturn Rings", "The fallback title should appear as soon as its result is persisted.")
        classifier_history = json.loads(Path(str(classifier_executable) + ".history").read_text(encoding="utf-8"))
        classifier_turns = classifier_history.get("turns", [])
        classifier_turns = [turn for turn in classifier_turns if (turn.get("userMessage") or "").startswith("Classify the latest user message for StationAI's continuous chat page index.")]
        self.assertEqual(len(classifier_turns), 3, "The fallback should reject one malformed result, retry, and classify the held follow-up.")
        classifier_turn = classifier_turns[-1]
        self.assertEqual(classifier_turn.get("modelID"), "gpt-6-luna", "The Codex fallback should use Luna.")
        self.assertEqual(classifier_turn.get("reasoningEffort"), "low", "The fallback must use low effort.")
        self.assertIn("Saturn Rings", self.assert_success(self.call_cli("chat", "page", "list")[0])["pages"][0]["title"])
        fallback_read = self.assert_success(self.call_cli("chat", "page", "read", fallback_status["activePage"]["id"])[0])
        fallback_archive = json.loads(Path(fallback_read["filePath"]).read_text(encoding="utf-8"))
        self.assertEqual(fallback_archive["page"]["title"], "Saturn Rings")
        missed_messages = fallback_read["messages"]
        self.assertEqual([message["text"] for message in fallback_archive["messages"]], [message["text"] for message in missed_messages])
        self.assertTrue(
            any(message["role"] == "user" and message["text"] == "Tell me about Saturn's rings" for message in missed_messages),
            "The fallback-classified turn's messages must be moved onto its new page.",
        )
        self.assertFalse(
            any(message["role"] == "user" and message["text"] == "Tell me about Saturn's rings"
                for message in self.assert_success(self.call_cli("chat", "page", "read", recipes["id"])[0])["messages"]),
            "The fallback-classified turn must not remain duplicated on the prior page.",
        )

        # Compliance resumes once the agent calls close-turn again on a later turn.
        self.complete_standalone_chat_fixture_turn(
            chat_task_id, "Thanks, that's all for now.", continues=True,
            executable_name="codex-fixture-chat-unique-turns-hold-release",
        )
        recovered_status = self.assert_success(self.call_cli(
            "chat", "status",
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(classifier_executable)},
        )[0])
        self.assertFalse(recovered_status["missedPreviousPageSignal"], "Compliance should clear once close-turn is called again.")
        recovered_messages = self.assert_success(self.call_cli("chat", "page", "read", fallback_status["activePage"]["id"])[0])["messages"]
        ordered = [message["text"] for message in recovered_messages]
        self.assertEqual(ordered, [
            "Tell me about Saturn's rings", "Answers received: Blue / fixture-secret.",
            "One more thought about Saturn", "Answers received: Blue / fixture-secret.",
            "Thanks, that's all for now.", "Answers received: Blue / fixture-secret.",
        ], "After fallback moves a turn, a later append must follow it in transcript order.")

        # Codex answers visible history from its own thread, and page sessions rotate, so the
        # transcript must restore earlier pages from the local archive instead of losing them.
        visible = self.assert_success(self.call_cli(
            "conversation", "history", chat_task_id,
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(classifier_executable)},
        )[0])
        visible_texts = [message["text"] for message in visible["messages"]]
        self.assertTrue(
            any(text.endswith("What's a good side dish?") for text in visible_texts),
            "An earlier Codex page must stay visible after its page session rotated.",
        )
        self.assertTrue(
            any(text.endswith("Thanks, that's all for now.") for text in visible_texts),
            "The live Codex page must stay visible alongside the restored earlier pages.",
        )
        # A chat page only belongs to the standalone chat, never to a board task.
        board_task = self.create_task("Context page rejection")
        self.assert_failure(self.call_cli(
            "conversation", "send", board_task["id"], "--message", "Hello",
            "--context-page", fallback_status["activePage"]["id"], expected_status=2,
        )[0], "invalid_argument")

        # An explicit page start while the fallback is in flight supersedes its
        # eventual Neptune classification without moving the old turn.
        neptune_classifier_hold = Path(str(classifier_executable) + ".hold-neptune-classifier")
        neptune_classifier_hold.touch()
        self.complete_standalone_chat_fixture_turn(
            chat_task_id, "Tell me about Neptune", skip_close_turn=True,
            executable_name="codex-fixture-chat-unique-turns-hold-release",
        )
        classifier_process = self.start_cli(
            "chat", "status",
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(classifier_executable)},
        )
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and not classifier_active.exists():
            time.sleep(0.02)
        self.assertTrue(classifier_active.exists(), "The second fallback should be held before the explicit page start.")
        explicit_page = self.assert_success(self.call_cli("chat", "page", "new", "--title", "Explicit topic")[0])["page"]
        self.assertEqual(self.assert_success(self.call_cli("chat", "page", "list")[0])["pages"][0]["id"], explicit_page["id"])
        classifier_release.write_text("Release classifier.\n", encoding="utf-8")
        classifier_response, _ = self.finish_cli(classifier_process, ("chat", "status"))
        self.assert_success(classifier_response)
        final_status = self.assert_success(self.call_cli(
            "chat", "status",
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(classifier_executable)},
        )[0])
        self.assertFalse(final_status["missedPreviousPageSignal"], "Explicit page creation should clear the missed-signal warning.")
        self.assertEqual(final_status["activePage"]["id"], explicit_page["id"], "A stale classifier must not replace an explicit page start.")
        self.assertEqual(final_status["activePage"]["title"], "Explicit topic")
        explicit_messages = self.assert_success(self.call_cli("chat", "page", "read", explicit_page["id"])[0])["messages"]
        self.assertEqual(explicit_messages, [], "The missed turn remains archived on its original page.")
        old_page_messages = self.assert_success(self.call_cli("chat", "page", "read", fallback_status["activePage"]["id"])[0])["messages"]
        self.assertTrue(any(message["text"] == "Tell me about Neptune" for message in old_page_messages))
        self.assertTrue(any(message["role"] == "assistant" for message in old_page_messages[-1:]))

        # Exhausted helper retries keep the pending turn authoritative and prevent
        # a later provider turn from overtaking it. Once the helper is healthy, retry.
        classifier_failure = Path(str(classifier_executable) + ".fail-classifier")
        classifier_failure.touch()
        self.complete_standalone_chat_fixture_turn(
            chat_task_id, "Tell me about Mars", skip_close_turn=True,
            executable_name="codex-fixture-chat-unique-turns-hold-release",
        )
        failed_status = self.assert_success(self.call_cli(
            "chat", "status",
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(classifier_executable)},
        )[0])
        self.assertTrue(failed_status["missedPreviousPageSignal"], "An invalid fallback response must leave the page decision pending.")
        blocked_response, _ = self.call_cli(
            "conversation", "send", chat_task_id, "--message", "Do not overtake Mars",
            expected_status=1,
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(classifier_executable)},
        )
        self.assert_failure(blocked_response, "operation_failed")
        blocked_history = json.loads(Path(str(classifier_executable) + ".history").read_text(encoding="utf-8"))
        self.assertFalse(
            any((turn.get("userMessage") or "") == "Do not overtake Mars" for turn in blocked_history.get("turns", [])),
            "An unresolved page decision must prevent the rejected prompt from reaching Codex.",
        )
        classifier_failure.unlink()
        recovered_status = self.assert_success(self.call_cli(
            "chat", "status",
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(classifier_executable)},
        )[0])
        self.assertFalse(recovered_status["missedPreviousPageSignal"])
        self.assertEqual(recovered_status["activePage"]["title"], "Mars")
        self.complete_standalone_chat_fixture_turn(
            chat_task_id, "Another thought about Mars", continues=True,
            executable_name="codex-fixture-chat-unique-turns-hold-release",
        )
        recovered_messages = self.assert_success(self.call_cli("chat", "page", "read", recovered_status["activePage"]["id"])[0])["messages"]
        self.assertFalse(any(message["text"] == "Do not overtake Mars" for message in recovered_messages))
        self.assertIn("Another thought about Mars", [message["text"] for message in recovered_messages])

    # case-contract: test_standalone_chat_page_sessions_isolate_context | Each standalone chat page is its own provider session: the first turn of a page starts a fresh session carrying the system prompt plus only that page's own turns, later turns on that page resume it without repeating the page context, and a different page never shares it, so an earlier page's turns never reach a later page. An annotation that quotes an earlier page carries just that page into the current turn, and rotating sessions still leaves every page's messages visible in the transcript.
    def test_standalone_chat_page_sessions_isolate_context(self):
        self.assert_success(self.call_cli("settings", "set-default-provider", "claude")[0])
        self.assert_success(self.call_cli("settings", "clear-parent")[0])
        executable = self.data_directory / "claude-fixture-chat-page-sessions"
        shutil.copyfile(Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py", executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-claude-fixture-owner").write_text(
            "StationAI test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        environment = {"STATIONAI_E2E_CLAUDE_EXECUTABLE": str(executable)}
        chat_id = self.assert_success(self.call_cli("chat", "open", extra_environment=environment)[0])["id"]
        history_path = Path(str(executable) + ".history")

        def wait_for_page(title):
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                status = self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])
                if not status["missedPreviousPageSignal"] and status["activePage"]["title"] == title:
                    return status
                time.sleep(0.1)
            self.fail(f"The chat never settled on page {title!r}.")

        def send(message, *extra):
            self.assert_success(self.call_cli(
                "conversation", "send", chat_id, "--message", message, *extra, extra_environment=environment
            )[0])

        def answer_turns():
            turns = json.loads(history_path.read_text(encoding="utf-8"))["turns"]
            return [
                turn for turn in turns
                if not (turn.get("userText") or "").startswith("Classify the latest user message")
            ]

        def turn_for(message):
            matches = [turn for turn in answer_turns() if (turn.get("userText") or "").endswith(message)]
            self.assertTrue(matches, f"The fixture never received a turn ending with {message!r}.")
            return matches[-1]

        send("Tell me about volcanoes")
        volcanoes = wait_for_page("Volcanoes")["activePage"]
        send("Tell me about Saturn's rings")
        saturn = wait_for_page("Saturn Rings")["activePage"]
        self.assertNotEqual(saturn["id"], volcanoes["id"])
        send("One more thought about Saturn")
        wait_for_page("Saturn Rings")

        first = turn_for("Tell me about volcanoes")
        second = turn_for("Tell me about Saturn's rings")
        third = turn_for("One more thought about Saturn")
        # The turn that opens a page still answers in the page it was sent into; only once the
        # classifier moves it does the next turn get that new page's own session.
        self.assertEqual(first["sessionID"], second["sessionID"], "One page answers in one session.")
        self.assertNotEqual(
            third["sessionID"], first["sessionID"],
            "A different page must never share another page's provider session.",
        )
        for turn in (first, third):
            self.assertFalse(turn["resumed"], "A page's first turn starts that page's own session.")
            instructions = turn["arguments"][turn["arguments"].index("--append-system-prompt") + 1]
            self.assertIn(
                "chat page close-turn", instructions,
                "Every page session must carry the standalone chat system prompt.",
            )
        self.assertTrue(second["resumed"], "A turn sent into an existing page resumes its session.")
        self.assertIn(
            "Tell me about Saturn's rings", third["userText"],
            "A fresh page session is seeded with its own page's turns.",
        )
        self.assertNotIn(
            "Tell me about volcanoes", third["userText"],
            "An earlier page must never be sent as context for a later page.",
        )
        self.assertNotIn("Tell me about volcanoes", second["userText"])

        # A later turn on the same page resumes its session without repeating the page block.
        send("Another thought about Mars")
        wait_for_page("Saturn Rings")
        fourth = turn_for("Another thought about Mars")
        self.assertEqual(fourth["sessionID"], third["sessionID"], "The same page keeps one session.")
        self.assertTrue(fourth["resumed"], "A continuing turn resumes the page's session.")
        self.assertNotIn(
            "<stationai-handoff-context>", fourth["userText"],
            "A resumed page session already holds its page, so it must not repeat the context block.",
        )

        # An annotation that quotes an earlier page carries only that page into this turn.
        send("What did we say before?", "--context-page", volcanoes["id"])
        wait_for_page("Saturn Rings")
        annotated = turn_for("What did we say before?")
        self.assertIn(
            "Tell me about volcanoes", annotated["userText"],
            "A page referenced by an annotation travels with the turn that quotes it.",
        )

        # Rotating sessions must not hide earlier pages from the visible transcript.
        visible = self.assert_success(self.call_cli("conversation", "history", chat_id, extra_environment=environment)[0])
        texts = [message["text"] for message in visible["messages"]]
        self.assertTrue(any(text.endswith("Tell me about volcanoes") for text in texts))
        self.assertTrue(any(text.endswith("One more thought about Saturn") for text in texts))

    # case-contract: test_standalone_chat_claude_fallback_classifier | When a standalone chat uses Claude, a missed page signal invokes the Haiku helper at low effort; a malformed result is rejected and retried, an unrelated later question and its assistant reply move to a new titled page, the UI keeps page evaluation visually quiet without blocking the primary answer, updates the transcript separator when classification completes, and holds a following send until the decision resolves, and appends the related follow-up in chronological order. The Claude-specific model and effort arguments are verified through the real CLI/XPC path. An explicit page start during a pending fallback cancels its stale result, keeps the missed turn on its original page, and clears the warning. If all helper results are invalid, the pending decision remains durable, blocks the next provider send, and retries after the helper recovers; the UI keeps the unresolved state visually quiet and sends successfully once recovery completes.
    def test_standalone_chat_claude_fallback_classifier(self):
        self.assert_success(self.call_cli("settings", "set-default-provider", "claude")[0])
        self.assert_success(self.call_cli("settings", "clear-parent")[0])
        executable = self.data_directory / "claude-fixture-chat-page-fallback"
        shutil.copyfile(Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py", executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-claude-fixture-owner").write_text(
            "StationAI test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        environment = {"STATIONAI_E2E_CLAUDE_EXECUTABLE": str(executable)}
        chat = self.assert_success(self.call_cli("chat", "open", extra_environment=environment)[0])
        chat_id = chat["id"]
        first = self.assert_success(self.call_cli("chat", "page", "new", "--title", "General chat", extra_environment=environment)[0])["page"]

        def wait_for_page(title):
            deadline = time.monotonic() + 30
            status = self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])
            while time.monotonic() < deadline:
                if not status["missedPreviousPageSignal"] and status["activePage"]["title"] == title:
                    return status
                time.sleep(0.1)
                status = self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])
            self.fail(f"Claude fallback did not resolve the active page as {title!r}: {status!r}")

        classifier_hold = Path(str(executable) + ".hold-classifier")
        classifier_active = Path(str(executable) + ".classifier-active")
        classifier_release = Path(str(executable) + ".classifier-release")
        classifier_active.unlink(missing_ok=True)
        classifier_release.unlink(missing_ok=True)
        classifier_hold.touch()
        self.assert_success(self.call_cli(
            "conversation", "send", chat_id, "--message", "Tell me about volcanoes", extra_environment=environment
        )[0])
        classifier_command = ("chat", "status")
        classifier_process = self.start_cli(*classifier_command, extra_environment=environment)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and not classifier_active.exists():
            time.sleep(0.02)
        self.assertTrue(classifier_active.exists(), "Claude send should return while Haiku classification is held in the background.")
        queued_turn = ("conversation", "send", chat_id, "--message", "Tell me about Saturn's rings")
        queued_process = self.start_cli(*queued_turn, extra_environment=environment)
        try:
            time.sleep(0.2)
            self.assertIsNone(queued_process.poll(), "Claude should hold a subsequent turn behind pending page resolution.")
            pending_history = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
            self.assertFalse(
                any((turn.get("userText") or "").startswith("Tell me about Saturn's rings") for turn in pending_history.get("turns", [])),
                "A queued Claude turn must not reach its provider before the page decision is persisted.",
            )
        finally:
            classifier_release.write_text("Release classifier.\n", encoding="utf-8")
        classifier_response, _ = self.finish_cli(classifier_process, classifier_command)
        classifier_status = self.assert_success(classifier_response)
        self.assertFalse(classifier_status["missedPreviousPageSignal"])
        queued_result, _ = self.finish_cli(queued_process, queued_turn)
        self.assert_success(queued_result)
        second_status = wait_for_page("Saturn Rings")
        self.assertNotEqual(second_status["activePage"]["id"], first["id"], "An unrelated turn should start a Claude-classified page.")
        self.assertEqual(self.assert_success(self.call_cli("chat", "page", "list", extra_environment=environment)[0])["pages"][1]["title"], "Volcanoes")
        self.assert_success(self.call_cli(
            "conversation", "send", chat_id, "--message", "One more thought about Saturn", extra_environment=environment
        )[0])
        third_status = wait_for_page("Saturn Rings")
        self.assertEqual(third_status["activePage"]["id"], second_status["activePage"]["id"], "The related follow-up should continue the Saturn page.")
        first_messages = self.assert_success(self.call_cli("chat", "page", "read", first["id"], extra_environment=environment)[0])["messages"]
        second_messages = self.assert_success(self.call_cli("chat", "page", "read", third_status["activePage"]["id"], extra_environment=environment)[0])["messages"]
        self.assertEqual(
            [message["text"] for message in second_messages],
            ["Tell me about Saturn's rings", "OK.", "One more thought about Saturn", "OK."],
            "A later appended turn must follow messages moved by the Claude fallback.",
        )
        self.assertTrue(any(message["text"] == "Tell me about volcanoes" for message in first_messages))
        self.assertTrue(any(message["text"] == "Tell me about Saturn's rings" for message in second_messages))
        self.assertFalse(any(message["text"] == "Tell me about Saturn's rings" for message in first_messages))
        history = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
        classification_turns = [turn for turn in history["turns"] if (turn.get("userText") or "").startswith("Classify the latest user message for StationAI's continuous chat page index.")]
        self.assertEqual(len(classification_turns), 4, "The fallback should retry one malformed result and classify a later follow-up.")
        for turn in classification_turns:
            self.assertEqual(turn["effort"], "low", "Claude fallback must set low effort.")
            self.assertEqual(turn["arguments"][turn["arguments"].index("--model") + 1], "haiku", "Claude fallback must use Haiku.")

        classifier_hold.touch()
        self.assert_success(self.call_cli(
            "conversation", "send", chat_id, "--message", "Tell me about Neptune", extra_environment=environment
        )[0])
        classifier_process = self.start_cli("chat", "status", extra_environment=environment)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and not classifier_active.exists():
            time.sleep(0.02)
        self.assertTrue(classifier_active.exists(), "The Claude fallback should be pending when the explicit page starts.")
        explicit_page = self.assert_success(self.call_cli(
            "chat", "page", "new", "--title", "Explicit topic", extra_environment=environment
        )[0])["page"]
        self.assertEqual(self.assert_success(self.call_cli("chat", "page", "list", extra_environment=environment)[0])["pages"][0]["id"], explicit_page["id"])
        classifier_release.write_text("Release classifier.\n", encoding="utf-8")
        classifier_response, _ = self.finish_cli(classifier_process, ("chat", "status"))
        self.assert_success(classifier_response)
        final_status = self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])
        self.assertFalse(final_status["missedPreviousPageSignal"], "Explicit page creation should clear the missed-signal warning.")
        self.assertEqual(final_status["activePage"]["id"], explicit_page["id"])
        self.assertEqual(final_status["activePage"]["title"], "Explicit topic")
        self.assertEqual(self.assert_success(self.call_cli("chat", "page", "read", explicit_page["id"], extra_environment=environment)[0])["messages"], [])
        old_page_messages = self.assert_success(self.call_cli("chat", "page", "read", second_status["activePage"]["id"], extra_environment=environment)[0])["messages"]
        self.assertTrue(any(message["text"] == "Tell me about Neptune" for message in old_page_messages))
        self.assertTrue(any(message["role"] == "assistant" and message["text"] == "OK." for message in old_page_messages))

        classifier_failure = Path(str(executable) + ".fail-classifier")
        classifier_failure.touch()
        self.assert_success(self.call_cli(
            "conversation", "send", chat_id, "--message", "Tell me about Mars", extra_environment=environment
        )[0])
        failed_status = self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])
        self.assertTrue(failed_status["missedPreviousPageSignal"], "Invalid Haiku responses must leave the classification pending.")
        blocked_response, _ = self.call_cli(
            "conversation", "send", chat_id, "--message", "Do not overtake Mars",
            expected_status=1, extra_environment=environment,
        )
        self.assert_failure(blocked_response, "operation_failed")
        blocked_history = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
        self.assertFalse(
            any((turn.get("userText") or "") == "Do not overtake Mars" for turn in blocked_history.get("turns", [])),
            "An unresolved page decision must prevent the rejected prompt from reaching Claude.",
        )
        classifier_failure.unlink()
        recovered_status = self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])
        self.assertFalse(recovered_status["missedPreviousPageSignal"])
        self.assertEqual(recovered_status["activePage"]["title"], "Mars")
        self.assert_success(self.call_cli(
            "conversation", "send", chat_id, "--message", "Another thought about Mars", extra_environment=environment
        )[0])
        recovered_messages = self.assert_success(self.call_cli(
            "chat", "page", "read", recovered_status["activePage"]["id"], extra_environment=environment
        )[0])["messages"]
        self.assertFalse(any(message["text"] == "Do not overtake Mars" for message in recovered_messages))
        self.assertIn("Another thought about Mars", [message["text"] for message in recovered_messages])

    # case-contract: test_service_reports_bridge_version | StationAI opens one main board window titled with its worktree label, displays the transparent theater logo in the board header, uses the same foreground artwork for the Dock AppIcon on a solid #2C2F36 background, and the bridge reports API version 1.
    def test_service_reports_bridge_version(self):
        response, _ = self.call_cli("status")
        status = self.assert_success(response)
        process_id = status.pop("processID")
        self.assertEqual(status, {"bridgeVersion": 1, "service": "StationAI"})
        self.assertGreater(process_id, 0, "The bridge should report the daemon process that answered.")
        self.assertTrue(self.process_is_running(process_id))
        app_bundle = self.cli.parent.parent.parent
        assets_catalog = app_bundle / "Contents" / "Resources" / "Assets.car"
        catalog = subprocess.run(
            ["/usr/bin/assetutil", "--info", str(assets_catalog)],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(catalog.returncode, 0, f"Could not inspect the app asset catalog: {catalog.stderr}")
        assets = json.loads(catalog.stdout)
        bundled_assets = {asset.get("Name") for asset in assets}
        self.assertTrue(
            {"StationAILogo", "AppIcon"}.issubset(bundled_assets),
            f"The app bundle should contain StationAILogo and AppIcon assets; found {bundled_assets}.",
        )
        repository_root = Path(__file__).resolve().parent.parent
        app_icon = repository_root / "StationAI/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
        header_logo = repository_root / "StationAI/Assets.xcassets/StationAILogo.imageset/StationAILogo.png"
        def bitmap(path, output):
            converted = subprocess.run(
                ["/usr/bin/sips", "-s", "format", "bmp", str(path), "--out", str(output)],
                check=False, capture_output=True, text=True,
            )
            self.assertEqual(converted.returncode, 0, converted.stderr)
            data = output.read_bytes()
            self.assertEqual(data[:2], b"BM")
            offset = struct.unpack_from("<I", data, 10)[0]
            width, signed_height = struct.unpack_from("<ii", data, 18)
            self.assertEqual(struct.unpack_from("<H", data, 28)[0], 32)
            self.assertLess(signed_height, 0, "Expected a top-down bitmap from sips")
            height = -signed_height

            def pixel(x, y):
                blue, green, red, alpha = data[offset + (y * width + x) * 4:offset + (y * width + x + 1) * 4]
                return red, green, blue, alpha

            return width, height, pixel

        with tempfile.TemporaryDirectory() as directory:
            icon_width, icon_height, icon_pixel = bitmap(app_icon, Path(directory) / "icon.bmp")
            logo_width, logo_height, logo_pixel = bitmap(header_logo, Path(directory) / "logo.bmp")
            background = icon_pixel(0, 0)[:3]
            self.assertEqual(background, (44, 47, 54), "The Dock icon should use the board's solid background.")
            self.assertLess(logo_pixel(0, 0)[3], 255, "The in-app logo should retain its transparent background.")

            def bounds(width, height, pixel, visible):
                points = ((x, y) for y in range(height) for x in range(width) if visible(pixel(x, y)))
                first = next(points, None)
                self.assertIsNotNone(first, "Artwork should have visible pixels")
                left = right = first[0]
                top = bottom = first[1]
                for x, y in points:
                    left, right = min(left, x), max(right, x)
                    top, bottom = min(top, y), max(bottom, y)
                return left, top, right, bottom

            icon_bounds = bounds(icon_width, icon_height, icon_pixel,
                                 lambda color: max(abs(color[channel] - background[channel]) for channel in range(3)) > 25)
            logo_bounds = bounds(logo_width, logo_height, logo_pixel, lambda color: color[3] > 25)

            def sample(pixel, box, x, y):
                left, top, right, bottom = box
                color = pixel(left + (right - left) * x // 63, top + (bottom - top) * y // 63)
                alpha = color[3] / 255
                return tuple(round(color[channel] * alpha + background[channel] * (1 - alpha)) for channel in range(3))

            differences = [
                abs(icon_pixel(icon_bounds[0] + (icon_bounds[2] - icon_bounds[0]) * x // 63,
                               icon_bounds[1] + (icon_bounds[3] - icon_bounds[1]) * y // 63)[channel]
                    - sample(logo_pixel, logo_bounds, x, y)[channel])
                for y in range(64) for x in range(64) for channel in range(3)
            ]
            self.assertLess(sum(differences) / len(differences), 10,
                            "The Dock icon and header should contain the same artwork.")

    # case-contract: test_app_override_rejects_incompatible_bundles | Explicit app overrides reject obsolete compatibility metadata, foreign worktree or bridge identities, test IDs that do not match the current worktree, and nonisolated test data before launching; the current app preserves a saved draft across restart.
    def test_app_override_rejects_incompatible_bundles(self):
        task = self.assert_success(self.call_cli("task", "create", "--title", "Protected store", "--root", self.primary)[0])
        self.assert_success(self.call_cli("task", "prompt", task["id"], "--text", "Protected draft", "--status", "Backlog")[0])
        root = Path(__file__).resolve().parent.parent
        launch_contract = subprocess.run(
            ["python3", str(root / "scripts/check-app-launch-contract.py"), str(self.cli.parent.parent.parent), str(root), str(self.data_directory)],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            launch_contract.returncode,
            0,
            f"App launch contract check failed: {launch_contract.stdout}\n{launch_contract.stderr}",
        )
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task["id"])[0])["savedPrompt"], "Protected draft")

    # case-contract: test_worktree_app_profiles_isolate_identity_and_store | The primary and linked source worktrees resolve to stable, distinct app and XPC identities, build paths, data stores, logs, and managed worktree roots; a saved conversation remains visible after an app restart.
    def test_worktree_app_profiles_isolate_identity_and_store(self):
        script = Path(__file__).resolve().parent / "app-profile.sh"
        linked = self.fixture / "existing-worktree"

        def profile(path):
            result = subprocess.run(["bash", str(script), str(path)], check=True, capture_output=True, text=True)
            return json.loads(result.stdout)

        primary_profile = profile(self.primary)
        linked_profile = profile(linked)
        self.assertEqual(primary_profile["kind"], "primary")
        self.assertEqual(primary_profile["bundleID"], "com.stationai.app")
        self.assertEqual(primary_profile["dataDirectory"], str(Path.home() / "Library/Application Support/StationAI"))
        self.assertEqual(linked_profile, profile(linked))
        self.assertEqual(linked_profile["kind"], "linked")
        self.assertNotEqual(primary_profile["bundleID"], linked_profile["bundleID"])
        self.assertNotEqual(primary_profile["bridgeID"], linked_profile["bridgeID"])
        self.assertNotEqual(primary_profile["derivedData"], linked_profile["derivedData"])
        self.assertNotEqual(primary_profile["dataDirectory"], linked_profile["dataDirectory"])
        self.assertNotEqual(primary_profile["logFile"], linked_profile["logFile"])
        self.assertNotEqual(primary_profile["worktreeRoot"], linked_profile["worktreeRoot"])
        self.assertTrue(linked_profile["bundleID"].endswith(linked_profile["key"]))
        self.assertEqual(linked_profile["bridgeID"], linked_profile["bundleID"] + ".bridge")
        self.assertEqual(
            linked_profile["dataDirectory"],
            str(Path.home() / "Library/Application Support/StationAI/Worktrees" / linked_profile["key"]),
        )
        verify_build = 'source "$1"; stationai_load_app_profile "$2"; stationai_verify_build_identity "$3"'
        self.assertEqual(subprocess.run(
            ["bash", "-c", verify_build, "profile-check", str(script), str(linked), linked_profile["bundleID"]],
            capture_output=True, text=True,
        ).returncode, 0)
        self.assertNotEqual(subprocess.run(
            ["bash", "-c", verify_build, "profile-check", str(script), str(linked), primary_profile["bundleID"]],
            capture_output=True, text=True,
        ).returncode, 0)
        self.assertNotEqual(subprocess.run(
            ["bash", "-c", verify_build, "profile-check", str(script), str(self.primary), linked_profile["bundleID"] + ".e2e.fixture"],
            capture_output=True, text=True,
        ).returncode, 0)
        # The bridge daemon and CLI ship flat in Contents/MacOS and resolve
        # their identity from this same Info.plist via `Bundle.main` (no
        # separate XPC bundle/Info.plist to cross-check anymore); the service
        # name is just that identifier plus ".bridge", matching
        # `BridgeContract.serviceName(forApplication:)`.
        app_info = plistlib.loads((self.cli.parent.parent / "Info.plist").read_bytes())
        self.assertEqual(arguments.service_name, app_info["CFBundleIdentifier"] + ".bridge")

        task = self.assert_success(self.call_cli("task", "create", "--title", "Profile restart", "--root", self.primary)[0])
        saved = self.assert_success(self.call_cli(
            "task", "prompt", task["id"], "--text", "Keep this draft after restart.", "--status", "Backlog",
        )[0])
        self.assertEqual(saved["savedPrompt"], "Keep this draft after restart.")
        self.assertTrue((self.data_directory / "StationAI-v2.store").is_file())
        reopened = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(reopened["title"], "Profile restart")
        self.assertEqual(reopened["savedPrompt"], "Keep this draft after restart.")

    # case-contract: test_task_creation_rejects_invalid_title_roots_and_missing_folder | New Task opens with the repository picker closed and composer focused; no selected repository is valid and shows no red missing-folder warning when the required repository root is configured. A standalone conversation can be sent without repository roots, while GUI and CLI reject sends if the configured repository root is missing. The UI and CLI accept standalone sends after the root is configured. The CLI accepts empty-root tasks and rejects blank titles, missing folders, unavailable roots, and invalid merge targets.
    def test_task_creation_rejects_invalid_title_roots_and_missing_folder(self):
        response, _ = self.call_cli(
            "task", "create", "--title", "   ", "--root", self.primary,
            expected_status=2,
        )
        self.assert_failure(response, "invalid_argument")

        response, _ = self.call_cli(
            "task", "create", "--title", "Bad merge target", "--repo", self.primary,
            "--merge-target", f"{self.primary}=not-a-local-branch", expected_status=2,
        )
        self.assert_failure(response, "invalid_argument")
        self.assertIn("must name an existing local branch", response["error"]["message"])

        response, _ = self.call_cli("task", "create", "--title", "No roots")
        empty_task = self.assert_success(response)
        self.assertEqual(empty_task["workspaceRoots"], [])
        self.assertEqual(empty_task["repositoryWorktrees"], [])
        persisted_empty_task = self.assert_success(self.call_cli("task", "get", empty_task["id"])[0])
        self.assertEqual(persisted_empty_task["title"], "No roots")
        self.assertEqual(persisted_empty_task["workspaceRoots"], [])
        self.assertEqual(persisted_empty_task["repositoryWorktrees"], [])
        self.complete_fixture_turn(empty_task["id"], message="Explain what nothingness means without editing a repository.")
        completed_standalone = self.assert_success(self.call_cli("task", "get", empty_task["id"])[0])
        self.assertEqual(completed_standalone["workspaceRoots"], [])
        self.assertEqual(completed_standalone["repositoryWorktrees"], [])
        self.assertEqual(completed_standalone["status"], "Review")
        main_history_path = self.data_directory / "codex-fixture.history"
        main_history = json.loads(main_history_path.read_text(encoding="utf-8"))
        instructions = main_history["threadStartDeveloperInstructions"]
        self.assertIn("read-only inspection of returned source paths", instructions)
        self.assertIn("Add a repository to this task only when you intend to create or commit changes in it", instructions)
        self.assertIn("workspace repos list", instructions)
        self.assertIn("task repository add", instructions)
        self.assertIn("Do not interrupt the user or ask them to confirm the selection merely because the task appears unrelated.", instructions)
        self.assertFalse((self.data_directory / "codex-fixture.assessment.history").exists(), "A new conversation should not launch a separate repository assessment.")
        deleted, _ = self.call_cli("task", "delete", empty_task["id"])
        self.assertTrue(self.assert_success(deleted)["deleted"])

        no_root_task = self.assert_success(self.call_cli("task", "create", "--title", "Root required")[0])
        self.assert_success(self.call_cli("settings", "clear-parent")[0])
        response, _ = self.call_cli(
            "conversation", "send", no_root_task["id"], "--message", "This must be blocked",
            expected_status=1,
        )
        self.assert_failure(response, "settings_required")
        untouched = self.assert_success(self.call_cli("task", "get", no_root_task["id"])[0])
        self.assertEqual(untouched["status"], "Backlog", "Missing root validation must happen before task state changes.")
        self.assertIsNone(untouched.get("savedPrompt"))
        self.assertEqual(untouched["repositoryWorktrees"], [])
        self.assert_success(self.call_cli("settings", "set-parent", self.fixture / "suggested-parent")[0])
        deleted, _ = self.call_cli("task", "delete", no_root_task["id"])
        self.assertTrue(self.assert_success(deleted)["deleted"])

        response, _ = self.call_cli(
            "task", "create", "--title", "Missing folder", "--root", self.fixture / "missing",
            expected_status=2,
        )
        self.assert_failure(response, "invalid_argument")

    # case-contract: test_task_creation_persists_ordered_roots_across_fresh_connections | A directly created conversation can add repositories in order, edit pending branch settings, and add a context folder; these settings persist across fresh connections without creating branches or worktrees before the first send. The conversation shows the additional context folder without repeating repository worktrees in a Working in summary. Saving an unsent prompt records task creation, prompt save, and subsequent reads with safe argument metadata, result state, and outcome while excluding prompt text.
    def test_task_creation_persists_ordered_roots_across_fresh_connections(self):
        branch_token = uuid.uuid4().hex[:8]
        title = f"Bridge task {branch_token}"
        generated_branch = f"bridge-task-{branch_token}"
        created = self.create_repo_task(
            title, [self.primary], branch_from={str(self.primary): "branch-source"},
            merge_targets={str(self.primary): "branch-source"}, roots=[self.custom]
        )
        task_id = created["id"]
        self.assertEqual(created["status"], "Backlog")
        self.assertEqual(created["repositoryWorktrees"][0]["repositoryPath"], str(self.primary))
        self.assertEqual(created["repositoryWorktrees"][0]["branch"], "auto")
        self.assertTrue(created["repositoryWorktrees"][0]["isPending"])
        self.assertEqual(created["repositoryWorktrees"][0]["worktreePath"], str(self.primary))
        self.assertEqual(created["repositoryWorktrees"][0]["branchFrom"], "branch-source")
        self.assertEqual(created["repositoryWorktrees"][0]["mergeTarget"], "branch-source")
        self.assertFalse(self.branch_exists(self.primary, generated_branch))
        self.assertEqual(created["contextFolders"], [str(self.custom)])
        self.assertEqual(created["workspaceRoots"], [str(self.primary), str(self.custom)])
        prompt = f"PROMPT_TEXT_NOT_IN_DIAGNOSTICS_{uuid.uuid4().hex}"
        response, _ = self.call_cli("task", "prompt", task_id, "--text", prompt)
        self.assertEqual(self.assert_success(response)["savedPrompt"], prompt)

        # Each CLI call starts a new process and XPC connection over the same real store.
        response, _ = self.call_cli("task", "get", task_id)
        task = self.assert_success(response)
        self.assertEqual(task["title"], title)
        self.assertEqual(task["repositoryWorktrees"], created["repositoryWorktrees"])
        self.assertEqual(task["workspaceRoots"], created["workspaceRoots"])
        response, _ = self.call_cli("board", "list")
        self.assertEqual([task["id"] for task in self.assert_success(response)["tasks"]], [task_id])
        operation_events = [
            event for event in self.diagnostic_events()
            if event.get("event") in {"bridge.request.started", "bridge.request.succeeded"}
        ]
        created_event = next(
            event for event in operation_events
            if event.get("event") == "bridge.request.succeeded" and event.get("command") == "task.create"
        )
        self.assertEqual(created_event.get("result.status"), "Backlog")
        self.assertEqual(created_event.get("argument.repositories.0.repositoryPath"), str(self.primary))
        task_write = next(
            event for event in self.diagnostic_events()
            if event.get("event") == "persistence.write.succeeded"
            and "create(title:repositories:contextFolders:" in event.get("operation", "")
        )
        self.assertEqual(task_write.get("entity"), "BoardTask")
        worktree_read = next(
            event for event in self.diagnostic_events()
            if event.get("event") == "git.operation.succeeded"
            and event.get("operation") == "worktree.prepare"
        )
        self.assertEqual(worktree_read.get("repositoryPath"), str(self.primary))
        get_event = next(
            event for event in operation_events
            if event.get("event") == "bridge.request.succeeded" and event.get("command") == "task.get"
        )
        self.assertEqual(get_event.get("argument.taskID"), task_id)
        self.assertTrue(any(
            event.get("event") == "persistence.read.succeeded"
            and event.get("operation") == "BoardTaskManager.requireTask"
            and event.get("taskID") == task_id
            for event in self.diagnostic_events()
        ))
        list_event = next(
            event for event in operation_events
            if event.get("event") == "bridge.request.succeeded" and event.get("command") == "board.list"
        )
        self.assertEqual(list_event.get("resultKind"), "object")
        prompt_event = next(
            event for event in operation_events
            if event.get("event") == "bridge.request.succeeded" and event.get("command") == "task.prompt.save"
        )
        self.assertEqual(prompt_event.get("argument.prompt.utf8Bytes"), str(len(prompt.encode("utf-8"))))
        self.assertNotIn(prompt, json.dumps(self.diagnostic_events()))

    # case-contract: test_task_creation_reuses_existing_branch_worktree | A selected existing branch remains pending until task start, then reuses its exact existing worktree path.
    def test_task_creation_reuses_existing_branch_worktree(self):
        existing = self.worktree_directory / "external-existing"
        branch = f"already-here-{uuid.uuid4().hex[:8]}"
        self.run_git(self.primary, "worktree", "add", "-b", branch, str(existing), "main")
        task = self.create_repo_task("Reuse branch", [self.primary], branches={str(self.primary): branch})
        self.assertTrue(task["repositoryWorktrees"][0]["isPending"])
        self.assertEqual(task["repositoryWorktrees"][0]["worktreePath"], str(self.primary))
        self.complete_fixture_turn(task["id"])
        task = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertFalse(task["repositoryWorktrees"][0]["isPending"])
        self.assertEqual(task["repositoryWorktrees"][0]["worktreePath"], str(existing))
        self.assertFalse(task["repositoryWorktrees"][0]["createdByStationAI"])

    # case-contract: test_task_creation_creates_worktrees_in_multiple_repositories | The conversation picker can add multiple repositories; unset branch settings display defaults and persist pending auto records resolved to local main without creating branches or worktrees before the first send.
    def test_task_creation_creates_worktrees_in_multiple_repositories(self):
        branch_token = uuid.uuid4().hex[:8]
        title = f"Multi repository {branch_token}"
        generated_branch = f"multi-repository-{branch_token}"
        task = self.create_repo_task(title, [self.secondary, self.primary])
        self.assertEqual([item["repositoryPath"] for item in task["repositoryWorktrees"]], [str(self.secondary), str(self.primary)])
        self.assertEqual([item["branch"] for item in task["repositoryWorktrees"]], ["auto", "auto"])
        self.assertTrue(all(item["isPending"] for item in task["repositoryWorktrees"]))
        self.assertEqual([item["branchFrom"] for item in task["repositoryWorktrees"]], ["main", "main"])
        for repository in [self.secondary, self.primary]:
            self.assertFalse(self.branch_exists(repository, generated_branch))
        self.assertEqual(task["workspaceRoots"], [str(self.secondary), str(self.primary)])

    # case-contract: test_task_creation_supports_non_git_folder_only_context | A folder-only task persists its context without Git worktrees and reaches Done after a successful turn without attempting a merge.
    def test_task_creation_supports_non_git_folder_only_context(self):
        task = self.create_task("Folder only", roots=[self.custom])
        self.assertEqual(task["repositoryWorktrees"], [])
        self.assertEqual(task["contextFolders"], [str(self.custom)])
        self.assertEqual(task["workspaceRoots"], [str(self.custom)])
        self.complete_fixture_turn(task["id"])
        completed, _ = self.call_cli("task", "move", task["id"], "Done")
        self.assertEqual(self.assert_success(completed)["status"], "Done")
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task["id"])[0])["contextFolders"], [str(self.custom)])

    # case-contract: test_task_creation_rejects_worktree_assigned_to_active_task | Adding a repository branch already assigned to another active task is rejected in the new conversation, and the existing task and repository reservation remain unchanged.
    def test_task_creation_rejects_worktree_assigned_to_active_task(self):
        first = self.create_repo_task("First owner", [self.primary], branches={str(self.primary): "active-shared"}, materialize=True)
        response, _ = self.call_cli(
            "task", "create", "--title", "Second owner", "--repo", self.primary,
            "--branch", f"{self.primary}=active-shared", expected_status=2,
        )
        self.assert_failure(response, "invalid_argument")
        self.assertIn("already assigned", response["error"]["message"])
        self.assertEqual(len(self.assert_success(self.call_cli("task", "list")[0])["tasks"]), 1)
        self.assertTrue(Path(first["repositoryWorktrees"][0]["worktreePath"]).is_dir())

    # case-contract: test_task_creation_serializes_repository_branch_reservations | Two concurrent CLI/XPC creates targeting the same explicit branch in one repository serialize through a shared cross-process lock, leaving exactly one persisted active task and rejecting the other.
    def test_task_creation_serializes_repository_branch_reservations(self):
        branch = f"concurrent-reservation-{uuid.uuid4().hex[:8]}"
        barrier = RepositoryAllocationLockBarrier(self.data_directory, self.primary)
        processes = []
        commands = []
        try:
            for title in ["Reservation contender one", "Reservation contender two"]:
                command = [
                    "task", "create", "--title", title,
                    "--repo", self.primary,
                    "--branch", f"{self.primary}={branch}",
                ]
                commands.append(command)
                processes.append(self.start_cli(*command))
            time.sleep(1)
            for process, command in zip(processes, commands):
                if process.poll() is not None:
                    stdout, stderr = process.communicate()
                    self.fail(f"Create exited before the repository lock was released: {command}; stdout={stdout!r}; stderr={stderr!r}")
        finally:
            barrier.release()
            for process in processes:
                if process.poll() is None:
                    try:
                        process.wait(timeout=90)
                    except subprocess.TimeoutExpired:
                        process.terminate()
                        process.wait(timeout=20)

        outcomes = []
        for process, command in zip(processes, commands):
            stdout, stderr = process.communicate(timeout=20)
            lines = [line for line in stdout.splitlines() if line.strip()]
            self.assertTrue(lines, f"CLI returned no JSON for {command}: {stderr}")
            response = json.loads(lines[-1])
            self.assertEqual(response.get("version"), 1)
            outcomes.append((process.returncode, response))

        self.assertEqual(sorted(status for status, _ in outcomes), [0, 2])
        successful = [response for _, response in outcomes if response.get("ok")]
        rejected = [response for _, response in outcomes if not response.get("ok")]
        self.assertEqual(len(successful), 1)
        self.assertEqual(len(rejected), 1)
        self.assertEqual(rejected[0].get("error", {}).get("code"), "invalid_argument")
        self.assertIn("already assigned", rejected[0]["error"]["message"])

        tasks = self.assert_success(self.call_cli("task", "list")[0])["tasks"]
        self.assertEqual(len(tasks), 1)
        task = self.assert_success(self.call_cli("task", "get", tasks[0]["id"])[0])
        record = task["repositoryWorktrees"][0]
        self.assertEqual(record["branch"], branch)
        self.assertTrue(record["isPending"])

    # case-contract: test_task_store_serializes_cross_process_writes | If another process holds the shared task-store write lock when a Codex turn completes after an explicit completed outcome, final status persistence waits and then saves Review status and full history across fresh CLI/XPC reads. Correlated persistence diagnostics include task ID, store path, lock wait, attempts, and retry count; task reads correlate started and completed events by read ID and store path, while failed reads include store file and sidecar state. Reopening the conversation in the UI shows the saved exchange without a store error.
    def test_task_store_serializes_cross_process_writes(self):
        task = self.create_repo_task("Store write contention", [self.primary])
        fixture_path = self.data_directory / "codex-fixture-store-write-success-wait"
        self.assertFalse(fixture_path.exists(), "A new, unique per-case fixture path must not replace an existing file.")
        shutil.copyfile(Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py", fixture_path)
        fixture_path.chmod(0o755)
        (self.data_directory / ".stationai-codex-fixture-owner").write_text(
            "StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        ready = Path(str(fixture_path) + ".resolve-ready")
        continuation = Path(str(fixture_path) + ".resolve-continue")
        command = ["conversation", "send", task["id"], "--message", "Persist this completed turn."]
        process = self.start_cli(
            *command,
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(fixture_path)},
        )
        barrier = None
        try:
            deadline = time.monotonic() + 15
            while not ready.is_file() and time.monotonic() < deadline:
                if process.poll() is not None:
                    stdout, stderr = process.communicate()
                    self.fail(f"The fixture turn ended before it could be held: stdout={stdout!r}; stderr={stderr!r}")
                time.sleep(0.02)
            self.assertTrue(ready.is_file(), "The real app-server fixture did not pause inside the active turn.")
            outcome, _ = self.call_cli("task", "outcome", task["id"], "completed")
            self.assertEqual(self.assert_success(outcome)["outcome"], "completed")
            barrier = TaskStoreWriteLockBarrier(self.data_directory)
            continuation.write_text("Release the completed fixture turn.\n", encoding="utf-8")

            deadline = time.monotonic() + 15
            completed_event_seen = False
            while time.monotonic() < deadline:
                diagnostics = self.data_directory / "Diagnostics.jsonl"
                if diagnostics.is_file():
                    completed_event_seen = any(
                        event.get("event") == "codex.turn.ended" and event.get("turnStatus") == "completed"
                        for event in (json.loads(line) for line in diagnostics.read_text(encoding="utf-8").splitlines() if line.strip())
                    )
                if completed_event_seen:
                    break
                time.sleep(0.02)
            self.assertTrue(completed_event_seen, "Codex should finish before final task-status persistence begins.")
            time.sleep(0.2)
            self.assertIsNone(process.poll(), "The completed turn must wait for the shared store write lock.")
            current, _ = self.call_cli("task", "get", task["id"])
            self.assertEqual(self.assert_success(current)["status"], "In Progress")
        except BaseException:
            continuation.touch(exist_ok=True)
            if barrier is not None:
                barrier.release()
            if process.poll() is None:
                process.terminate()
                process.communicate(timeout=20)
            raise
        finally:
            continuation.touch(exist_ok=True)
            if barrier is not None:
                barrier.release()

        response, _ = self.finish_cli(process, command)
        self.assert_success(response)
        current, _ = self.call_cli("task", "get", task["id"])
        current = self.assert_success(current)
        self.assertEqual(current["status"], "Review")
        self.assertIsNone(current.get("pendingSubmittedPrompt"))
        history, _ = self.call_cli(
            "conversation", "history", task["id"],
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(fixture_path)},
        )
        messages = self.assert_success(history)["messages"]
        self.assertTrue(any(item["role"] == "user" and item["text"] == "Persist this completed turn." for item in messages))
        self.assertTrue(any(
            item["role"] == "assistant" and item["text"] == "Answers received: Blue / fixture-secret."
            for item in messages
        ))
        failures = [
            json.loads(line) for line in (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8").splitlines()
            if json.loads(line).get("taskID") == task["id"] and json.loads(line).get("event") == "conversation.send.failed"
        ]
        self.assertEqual(failures, [], "A transient store lock must not surface as a failed conversation send.")
        store_write_events = [
            json.loads(line) for line in (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8").splitlines()
            if json.loads(line).get("taskID") == task["id"]
            and json.loads(line).get("event") == "persistence.write.lock_acquired"
        ]
        self.assertTrue(store_write_events, "The final task save should log when its shared store lock is acquired.")
        waited_write = next(event for event in store_write_events if int(event.get("lockWaitMilliseconds", "0")) > 0)
        self.assertEqual(waited_write["storePath"], str(self.data_directory / "StationAI-v2.store"))
        matching_success = next(
            json.loads(line) for line in (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8").splitlines()
            if (event := json.loads(line)).get("taskID") == task["id"]
            and event.get("event") == "persistence.write.succeeded"
            and event.get("writeID") == waited_write["writeID"]
        )
        self.assertEqual(matching_success["attemptCount"], "1")
        self.assertEqual(matching_success["retryCount"], "0")

        read_events = [
            json.loads(line) for line in (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8").splitlines()
            if json.loads(line).get("taskID") == task["id"]
            and json.loads(line).get("operation") == "BoardTaskManager.requireTask"
            and json.loads(line).get("event") in {"persistence.read.started", "persistence.read.succeeded"}
        ]
        successful_read = next(event for event in read_events if event["event"] == "persistence.read.succeeded")
        read_id = successful_read["readID"]
        matching_read_start = next(
            event for event in read_events
            if event["event"] == "persistence.read.started" and event.get("readID") == read_id
        )
        expected_store_path = str(self.data_directory / "StationAI-v2.store")
        snapshot_prefixes = ("storeDirectory", "storeFile", "storeWAL", "storeSHM")
        for read_event in (matching_read_start, successful_read):
            self.assertEqual(read_event["storePath"], expected_store_path)
            self.assertFalse(
                any(key.startswith(snapshot_prefixes) for key in read_event),
                f"Successful read events should omit filesystem snapshots: {read_event}",
            )
        self.assertIn("durationMilliseconds", successful_read)

    # case-contract: test_persistence_store_open_failure_records_detailed_error | A real ModelContainer open failure against an isolated invalid store path returns an error and durably logs the phase, exact underlying NSError domain/code/userInfo, resolved store path, file/sidecar snapshot, and read-only schema probe failure; the paired visible UI case keeps StationAI open on its normal board while the same isolated CLI/XPC request fails and verifies the persisted diagnostic.
    def test_persistence_store_open_failure_records_detailed_error(self):
        failure_directory = self.data_directory / "invalid-store-open"
        failure_directory.mkdir()
        store = failure_directory / "StationAI-v2.store"
        store.mkdir()

        response, _ = self.call_cli(
            "task", "list", expected_status=1,
            extra_environment={"STATIONAI_DATA_DIRECTORY": str(failure_directory)},
        )
        self.assertFalse(response["ok"], response)
        diagnostic_path = failure_directory / "Diagnostics.jsonl"
        events = [
            json.loads(line) for line in diagnostic_path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
        failed_open = next(event for event in events if event.get("event") == "persistence.store.open.failed")
        self.assertEqual(failed_open["phase"], "model-container-open")
        self.assertEqual(failed_open["storePath"], str(store))
        self.assertEqual(failed_open["storeFileExists"], "true")
        self.assertIn("storeWALExists", failed_open)
        self.assertIn("storeSHMExists", failed_open)
        self.assertTrue(failed_open.get("errorDescription"))
        self.assertTrue(failed_open.get("error0Domain"))
        self.assertTrue(failed_open.get("error0Code"))
        self.assertIn("error0UserInfoKeys", failed_open)
        self.assertIn("error0UserInfoKeyCount", failed_open)
        self.assertIn("error0UserInfo", failed_open)
        self.assertEqual(failed_open["schemaProbeResult"], "open-failed")
        self.assertTrue(failed_open.get("schemaProbeSQLiteMessage"))

    # case-contract: test_persistence_read_failure_records_detailed_error | A real SwiftData fetch failure against an isolated store with a missing task column returns an error and logs a correlated read ID, NSError domain/code/userInfo, store path, file/sidecar snapshot, and the exact missing-column message from a read-only schema probe before the CLI/XPC request completes; the paired visible UI case keeps the normal task board open and verifies the same isolated failure record.
    def test_persistence_read_failure_records_detailed_error(self):
        self.create_task("Missing column read failure")
        store = self.data_directory / "StationAI-v2.store"
        with sqlite3.connect(store) as database:
            database.execute("ALTER TABLE ZBOARDTASK DROP COLUMN ZPROGRESSLABEL")

        response, _ = self.call_cli("task", "list", expected_status=1)
        self.assertFalse(response["ok"], response)
        events = self.diagnostic_events()
        failed_read = next(
            event for event in events
            if event.get("event") == "persistence.read.failed"
            and event.get("operation") == "BoardTaskManager.list"
        )
        self.assertTrue(failed_read.get("readID"))
        self.assertEqual(failed_read["storePath"], str(store))
        self.assertEqual(failed_read["storeFileExists"], "true")
        self.assertIn("storeWALExists", failed_read)
        self.assertIn("storeSHMExists", failed_read)
        self.assertTrue(failed_read.get("errorDescription"))
        self.assertTrue(failed_read.get("error0Domain"))
        self.assertTrue(failed_read.get("error0Code"))
        self.assertIn("error0UserInfoKeys", failed_read)
        self.assertIn("error0UserInfoKeyCount", failed_read)
        self.assertIn("error0UserInfo", failed_read)
        self.assertEqual(failed_read["schemaProbeResult"], "prepare-failed")
        self.assertEqual(failed_read["schemaProbeSQLiteCode"], "1")
        self.assertIn("no such column: t0.ZPROGRESSLABEL", failed_read["schemaProbeSQLiteMessage"])
        self.assertTrue(any(
            event.get("event") == "persistence.read.started"
            and event.get("readID") == failed_read["readID"]
            and event.get("storePath") == str(store)
            for event in events
        ))

    # case-contract: test_legacy_store_import_failure_preserves_original | An invalid legacy database fails import without changing the source or publishing a destination or partial snapshot; the normal isolated board remains usable.
    def test_legacy_store_import_failure_preserves_original(self):
        self.assert_success(self.call_cli("task", "create", "--title", "Healthy board", "--root", self.primary)[0])
        failure = self.data_directory / "invalid-legacy"
        failure.mkdir()
        source = failure / "StationAI.store"
        contents = b"Not a SQLite database"
        source.write_bytes(contents)
        response, _ = self.call_cli("task", "list", expected_status=1, extra_environment={"STATIONAI_DATA_DIRECTORY": str(failure)})
        self.assertFalse(response["ok"])
        self.assertEqual(source.read_bytes(), contents)
        self.assertFalse((failure / "StationAI-v2.store").exists())
        self.assertFalse(list(failure.glob(".store-import-*")))
        self.assertEqual(self.assert_success(self.call_cli("task", "list")[0])["tasks"][0]["title"], "Healthy board")

    # case-contract: test_task_store_repairs_missing_pending_prompt_column | A real legacy SwiftData task store with in-progress timing columns and no submitted-prompt column waits for the store-write lock while CLI/XPC reads concurrently; migration backs up before adding the missing VARCHAR prompt column as nullable with no default and preserves elapsed time at zero. The CLI preserves the task and draft, and the visible app opens the migrated store and preserves the draft through a subsequent restart with duration still zero; metadata advances and later opens create no additional backup. The store is imported once into the protected filename and the legacy database remains unchanged. Committed WAL-only draft data survives import, and a subsequent edited draft survives restart without reimport.
    def test_task_store_repairs_missing_pending_prompt_column(self):
        seeded = subprocess.run(
            [str(arguments.legacy_store_seeder), str(self.data_directory)],
            check=True, capture_output=True, text=True,
        )
        task_id = seeded.stdout.strip()
        draft = "Keep this draft through the store repair."
        store = self.data_directory / "StationAI-v2.store"
        legacy_store = self.data_directory / "StationAI.store"
        with sqlite3.connect(legacy_store) as database:
            columns = {row[1] for row in database.execute("PRAGMA table_info(ZBOARDTASK)")}
            self.assertNotIn("ZPENDINGSUBMITTEDPROMPT", columns)
            self.assertTrue({"ZINPROGRESSSTARTEDAT", "ZTOTALINPROGRESSSECONDS"} <= columns)
            self.assertEqual(database.execute("SELECT count(*) FROM ZBOARDTASK").fetchone()[0], 1)
            legacy_metadata = plistlib.loads(database.execute("SELECT Z_PLIST FROM Z_METADATA").fetchone()[0])
            legacy_hash = legacy_metadata["NSStoreModelVersionHashes"]["BoardTask"]
            self.assertEqual(len(legacy_hash), 32)

        wal = sqlite3.connect(legacy_store)
        self.addCleanup(wal.close)
        wal.execute("PRAGMA journal_mode=WAL")
        wal.execute("PRAGMA wal_autocheckpoint=0")
        draft = "Committed WAL draft must survive import."
        wal.execute("UPDATE ZBOARDTASK SET ZSAVEDPROMPT = ?", (draft,))
        wal.commit()
        self.assertGreater(Path(str(legacy_store) + "-wal").stat().st_size, 0)
        legacy_bytes = legacy_store.read_bytes()
        barrier = TaskStoreWriteLockBarrier(self.data_directory)
        try:
            waiting = self.start_cli("task", "get", task_id)
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline and not any(
                event.get("event") == "persistence.store.schema_migration.waiting_for_write_lock"
                for event in self.diagnostic_events()
            ):
                time.sleep(0.05)
            self.assertTrue(any(
                event.get("event") == "persistence.store.schema_migration.waiting_for_write_lock"
                for event in self.diagnostic_events()
            ), "The legacy-store open should wait for the real store-write lock.")
            self.assertIsNone(waiting.poll(), "The XPC read must not bypass the held migration lock.")
            self.assertFalse(list(self.data_directory.glob("StationAI.store.before-pending-prompt-*.backup")))
        finally:
            barrier.release()
        reopened, _ = self.finish_cli(waiting, ("task", "get", task_id))
        self.assertEqual(self.assert_success(reopened)["savedPrompt"], draft)
        self.assertEqual(self.assert_success(reopened)["title"], "Legacy pending prompt store")
        self.assertTrue(any(
            event.get("event") == "persistence.store.schema_migration.write_lock_acquired"
            and int(event.get("waitMilliseconds", "0")) > 0
            for event in self.diagnostic_events()
        ))
        backups = list(self.data_directory.glob("StationAI.store.before-pending-prompt-*.backup"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(stat.S_IMODE(backups[0].stat().st_mode), 0o600)
        with sqlite3.connect(backups[0]) as backup:
            self.assertEqual(backup.execute("PRAGMA quick_check").fetchone()[0], "ok")
            self.assertEqual(backup.execute("SELECT count(*) FROM ZBOARDTASK").fetchone()[0], 1)
            backup_columns = {row[1] for row in backup.execute("PRAGMA table_info(ZBOARDTASK)")}
            self.assertNotIn("ZPENDINGSUBMITTEDPROMPT", backup_columns)
            self.assertTrue({"ZINPROGRESSSTARTEDAT", "ZTOTALINPROGRESSSECONDS"} <= backup_columns)
        listed, _ = self.call_cli("board", "list")
        self.assertEqual([item["id"] for item in self.assert_success(listed)["tasks"]], [task_id])
        self.assertEqual(len(list(self.data_directory.glob("StationAI.store.before-pending-prompt-*.backup"))), 1)
        self.assertEqual(legacy_store.read_bytes(), legacy_bytes)
        with sqlite3.connect(store) as database:
            migrated_columns = {row[1] for row in database.execute("PRAGMA table_info(ZBOARDTASK)")}
            self.assertTrue({"ZPENDINGSUBMITTEDPROMPT", "ZINPROGRESSSTARTEDAT", "ZTOTALINPROGRESSSECONDS"} <= migrated_columns)
            prompt_column = next(row for row in database.execute("PRAGMA table_info(ZBOARDTASK)") if row[1] == "ZPENDINGSUBMITTEDPROMPT")
            self.assertEqual((prompt_column[2], prompt_column[3], prompt_column[4]), ("VARCHAR", 0, None))
            duration_column = next(row for row in database.execute("PRAGMA table_info(ZBOARDTASK)") if row[1] == "ZTOTALINPROGRESSSECONDS")
            self.assertEqual((duration_column[2], duration_column[3], duration_column[4]), ("FLOAT", 0, None))
            self.assertEqual(database.execute("SELECT ZTOTALINPROGRESSSECONDS FROM ZBOARDTASK").fetchone()[0], 0)
            migrated_metadata = plistlib.loads(database.execute("SELECT Z_PLIST FROM Z_METADATA").fetchone()[0])
            self.assertNotEqual(migrated_metadata["NSStoreModelVersionHashes"]["BoardTask"], legacy_hash)
        self.assertEqual(
            len([event for event in self.diagnostic_events() if event.get("event") == "persistence.store.schema_repaired"]),
            1,
        )

        self.assert_success(self.call_cli("task", "prompt", task_id, "--text", "Edited after import", "--status", "Backlog")[0])
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["savedPrompt"], "Edited after import")
        self.assertEqual(len([e for e in self.diagnostic_events() if e.get("event") == "persistence.store.legacy_imported"]), 1)

    # case-contract: test_test_bundle_rejects_unisolated_data_directory | A test-built StationAI service rejects a data directory outside the temporary test area and a linked store inside it before creating or opening either store; the visible app remains on its isolated board and can still read its tasks.
    def test_test_bundle_rejects_unisolated_data_directory(self):
        unsafe = Path.home() / "Library" / "Caches" / f"StationAI-bridge-guard-{uuid.uuid4()}"
        self.assertFalse(unsafe.exists())
        unsafe.mkdir(parents=True)
        marker = unsafe / ".stationai-test-owner"
        marker.write_text("StationAI bridge guard test (v1).\n", encoding="utf-8")
        try:
            response, _ = self.call_cli(
                "board", "list", expected_status=1,
                extra_environment={"STATIONAI_DATA_DIRECTORY": str(unsafe)},
            )
            self.assert_failure(response, "operation_failed")
            self.assertIn("isolated temporary data directory", response["error"]["message"])
            self.assertFalse((unsafe / "StationAI-v2.store").exists())
            linked = self.data_directory / "linked-store"
            linked.mkdir()
            (linked / "StationAI-v2.store").symlink_to(unsafe / "StationAI-v2.store")
            response, _ = self.call_cli(
                "board", "list", expected_status=1,
                extra_environment={"STATIONAI_DATA_DIRECTORY": str(linked)},
            )
            self.assert_failure(response, "operation_failed")
            self.assertIn("linked task store", response["error"]["message"])
            self.assertFalse((unsafe / "StationAI-v2.store").exists())
            good, _ = self.call_cli("board", "list")
            self.assertEqual(self.assert_success(good)["tasks"], [])
        finally:
            self.assertEqual(marker.read_text(encoding="utf-8"), "StationAI bridge guard test (v1).\n")
            shutil.rmtree(unsafe)

    # case-contract: test_task_worktree_preparation_serializes_auto_branch_claims | Tasks with the same automatic branch choice remain pending without creating a worktree before conversation start. When one task has claimed the generated branch, a send from the other (through the CLI, or through the composer, which shows the error and returns the prompt to it) is rejected without creating a worktree and restores the task to Backlog with its prompt saved as a draft and no pending submitted prompt; the opt-in live provider integration sends both turns concurrently and confirms only one task claims the generated branch.
    def test_task_worktree_preparation_serializes_auto_branch_claims(self):
        title = f"Concurrent auto branch {uuid.uuid4().hex[:8]}"
        existing_worktree_count = self.run_git(self.primary, "worktree", "list", "--porcelain").count("worktree ")
        tasks = [
            self.create_repo_task(title, [self.primary]),
            self.create_repo_task(title, [self.primary]),
        ]
        self.assertEqual(self.run_git(self.primary, "worktree", "list", "--porcelain").count("worktree "), existing_worktree_count)
        records = [self.assert_success(self.call_cli("task", "get", task["id"])[0]) for task in tasks]
        self.assertTrue(all(record["repositoryWorktrees"][0]["isPending"] for record in records))
        self.assertTrue(all(record["repositoryWorktrees"][0]["branch"] == "auto" for record in records))
        self.assertTrue(all(record["repositoryWorktrees"][0]["worktreePath"] == str(self.primary) for record in records))
        self.assertTrue(all(record["status"] == "Backlog" for record in records))
        winner, loser = tasks
        self.complete_fixture_turn(winner["id"])
        claimed = self.assert_success(self.call_cli("task", "get", winner["id"])[0])["repositoryWorktrees"][0]
        self.assertFalse(claimed["isPending"])
        claimed_count = self.run_git(self.primary, "worktree", "list", "--porcelain").count("worktree ")
        self.assertEqual(claimed_count, existing_worktree_count + 1)
        loser_prompt = "Claim the same generated branch."
        response, _ = self.call_cli(
            "conversation", "send", loser["id"], "--message", loser_prompt,
            expected_status=2,
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(self.data_directory / "codex-fixture")},
        )
        self.assert_failure(response, "invalid_argument")
        rejected = self.assert_success(self.call_cli("task", "get", loser["id"])[0])
        self.assertEqual(rejected["status"], "Backlog", "A rejected branch claim must restore the task's prior status.")
        self.assertTrue(rejected["repositoryWorktrees"][0]["isPending"])
        self.assertEqual(rejected["savedPrompt"], loser_prompt)
        self.assertIsNone(rejected.get("pendingSubmittedPrompt"))
        self.assertIsNone(rejected.get("codexThreadID"))
        self.assertEqual(self.run_git(self.primary, "worktree", "list", "--porcelain").count("worktree "), claimed_count)

    # case-contract: test_task_done_preserves_worktree_and_branch | Sending the first message derives an auto branch from the generated task title, with a prompt fallback when title generation fails. Every linked PR must be merged before the task can move to Done. App focus checks each linked PR no more than once per 20 seconds; rapid focus changes are coalesced into one refresh after the cooldown. An unmerged PR keeps its link and suppresses the completion button. PR links and the green completion button have hit targets of at least 30×30 points. After all PRs merge, a later focus check replaces their links with a green completion button; clicking it waits for the task lock and then trusts that already-confirmed merge state, moving the task to Done immediately without re-querying GitHub even if merge status changed while the lock was held. The CLI's task move command has no such cached state, so it always verifies merge status directly with GitHub before completing, including rechecking after waiting for a contended task lock, and reports unmerged pull requests instead of completing when a PR is not actually merged. Completion preserves the source branch and worktree without merging into the local target, retains conversation history, and exposes the task in the searchable read-only archive; the CLI searches matching local Codex JSONL session files, including current input_text and output_text message content, without loading conversation histories, while the visible archive searches both user input_text and assistant output_text, loads the newest 40 first, and reveals older tasks as the user scrolls.
    def test_task_done_preserves_worktree_and_branch(self):
        task = self.create_repo_task("Untitled task", [self.primary, self.secondary])
        draft = "Please update the README and add concise setup steps for first time contributors tomorrow."
        self.assertEqual(self.assert_success(self.call_cli("task", "prompt", task["id"], "--text", draft)[0])["savedPrompt"], draft)
        self.assertTrue(task["repositoryWorktrees"][0]["isPending"])
        self.assertEqual(task["repositoryWorktrees"][0]["branch"], "auto")
        self.assertEqual(task["repositoryWorktrees"][0]["worktreePath"], str(self.primary))
        executable = self.data_directory / "codex-fixture"
        self.complete_fixture_turn(task["id"], message=draft)
        started = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        record = started["repositoryWorktrees"][0]
        self.assertFalse(record["isPending"])
        self.assertEqual(record["branch"], "generated-fixture-title")
        worktree = Path(record["worktreePath"])
        codex_history = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
        self.assertEqual(codex_history["threadStartCwd"], str(worktree), "The Codex thread must start in the managed task worktree.")
        self.assertEqual(codex_history["turns"][0]["cwd"], str(worktree), "The user turn must run from the managed task worktree.")
        self.assertEqual(codex_history["turns"][0]["runtimeWorkspaceRoots"], [item["worktreePath"] for item in started["repositoryWorktrees"]])
        target_head = self.run_git(self.primary, "rev-parse", "main")
        self.assertEqual(self.run_git(worktree, "rev-parse", "HEAD"), target_head)
        current, _ = self.call_cli("task", "get", task["id"])
        self.assertEqual(self.assert_success(current)["status"], "Review")
        pr_url = self.seed_done_task_pull_request(task["id"])
        second_pr_url = self.seed_done_task_pull_request(task["id"], number=456, repository_index=1)
        gh_directory = self.data_directory / "gh-fixture"
        gh_directory.mkdir()
        gh_state = gh_directory / "state"
        gh_calls = gh_directory / "calls"
        gh_state.write_text("123=merged\n456=unmerged\n", encoding="utf-8")
        gh = gh_directory / "gh"
        shutil.copyfile(Path(__file__).resolve().parent / "fixtures" / "gh-fixture.sh", gh)
        gh.chmod(0o755)
        gh_environment = {
            "PATH": f"{gh_directory}:{os.environ.get('PATH', '')}",
            "STATIONAI_E2E_GH_STATE_PATH": str(gh_state),
            "STATIONAI_E2E_GH_CALL_LOG": str(gh_calls),
        }
        linked = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(linked["repositoryWorktrees"][0]["pullRequestURL"], pr_url)
        self.assertEqual(linked["repositoryWorktrees"][1]["pullRequestURL"], second_pr_url)
        (self.primary / "target-only.txt").write_text("Master advanced after this task branch was created.\n", encoding="utf-8")
        self.run_git(self.primary, "add", "target-only.txt")
        self.run_git(self.primary, "commit", "-m", "Advance merge target while task is under review")
        target_head = self.run_git(self.primary, "rev-parse", "main")
        move_lock = TaskOperationLockBarrier(self.data_directory, task["id"])
        move_command = ["task", "move", task["id"], "Done"]
        move_process = self.start_cli(*move_command, extra_environment=gh_environment)
        try:
            time.sleep(0.25)
            self.assertIsNone(move_process.poll(), "Moving a task to Done must wait for an active per-task operation.")
            current, _ = self.call_cli("task", "get", task["id"])
            self.assertEqual(self.assert_success(current)["status"], "Review")
        finally:
            move_lock.release()
        response, _ = self.finish_cli(move_process, move_command, expected_status=1)
        self.assert_failure(response, "invalid_transition")
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task["id"])[0])["status"], "Review")
        gh_state.write_text("123=merged\n456=merged\n", encoding="utf-8")
        response, _ = self.call_cli(*move_command, extra_environment=gh_environment)
        self.assertEqual(self.assert_success(response)["status"], "Done")
        self.assertEqual(gh_calls.read_text(encoding="utf-8").splitlines(), ["123", "456", "123", "456"])
        self.assertTrue(worktree.exists(), "Moving a task to Done must preserve its worktree.")
        self.assertTrue(self.branch_exists(self.primary, "generated-fixture-title"))
        self.assertEqual(self.run_git(self.primary, "rev-parse", "main"), target_head, "Moving a task to Done must not merge into the local target.")
        self.assertEqual((self.primary / "target-only.txt").read_text(encoding="utf-8"), "Master advanced after this task branch was created.\n")
        self.assertFalse((self.primary / "task-result.txt").exists())
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task["id"])[0])["repositoryWorktrees"][0]["mergeTarget"], "main")
        completed, _ = self.call_cli("task", "get", task["id"])
        self.assertEqual(self.assert_success(completed)["savedPrompt"], draft)
        board, _ = self.call_cli("board", "list")
        archived = next(item for item in self.assert_success(board)["tasks"] if item["id"] == task["id"])
        self.assertEqual(archived["status"], "Done")
        history, _ = self.call_cli(
            "conversation", "history", task["id"],
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(self.data_directory / "codex-fixture")},
        )
        messages = self.assert_success(history)["messages"]
        self.assertTrue(any(message["role"] == "assistant" and "Answers received: Blue / fixture-secret." in message["text"] for message in messages))
        thread_id = started["codexThreadID"]
        sessions = self.data_directory / "codex-home" / "sessions" / "2026" / "10" / "22"
        sessions.mkdir(parents=True)
        session_file = sessions / f"rollout-2026-10-22T00-00-00-{thread_id}.jsonl"
        session_file.write_text(
            json.dumps({"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "LOCAL-SESSION-ONLY-user-token"}]}})
            + "\n"
            + json.dumps({"type": "response_item", "payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "LOCAL-SESSION-ONLY-assistant-token"}]}})
            + "\n",
            encoding="utf-8",
        )
        search_env = {"CODEX_HOME": str(self.data_directory / "codex-home")}
        for query in ("local-session-only-user-TOKEN", "local-session-only-assistant-TOKEN"):
            search, _ = self.call_cli("archive", "search", query, extra_environment=search_env)
            search_results = self.assert_success(search)
            self.assertEqual([result["id"] for result in search_results], [task["id"]], "Archive search should find current Codex input_text/output_text content in the task's local session file.")
        invalid_search, _ = self.call_cli("archive", "search", "   ", expected_status=2, extra_environment=search_env)
        self.assert_failure(invalid_search, "invalid_argument")
        filler_ids = []
        for index in range(1, 41):
            filler = self.assert_success(self.call_cli("task", "create", "--title", f"Archive page filler {index}", "--root", str(self.custom))[0])
            filler_ids.append(filler["id"])
            self.complete_fixture_turn(filler["id"])
            moved = self.assert_success(self.call_cli("task", "move", filler["id"], "Done")[0])
            self.assertEqual(moved["status"], "Done")
        board, _ = self.call_cli("board", "list")
        archived_tasks = [item for item in self.assert_success(board)["tasks"] if item["status"] == "Done"]
        archived_ids = {item["id"] for item in archived_tasks}
        self.assertGreaterEqual(len(archived_tasks), 41, "The CLI board read should retain completed tasks beyond the first visible archive page.")
        self.assertTrue(set(filler_ids).issubset(archived_ids), "All persisted archive records should remain available across pages.")

    # case-contract: test_task_done_preserves_dirty_worktree | Moving a reviewed task to Done changes only task status and preserves dirty worktree files, branch, and target commit without committing or merging.
    def test_task_done_preserves_dirty_worktree(self):
        task = self.create_repo_task("Dirty cleanup", [self.primary], materialize=True)
        worktree = Path(task["repositoryWorktrees"][0]["worktreePath"])
        self.complete_fixture_turn(task["id"])
        tracked = worktree / "stationai-primary.txt"
        tracked.write_text("Edited after review\n", encoding="utf-8")
        untracked = worktree / "unsaved.txt"
        untracked.write_text("keep me\n", encoding="utf-8")
        target_before = self.run_git(self.primary, "rev-parse", "main")
        branch = task["repositoryWorktrees"][0]["branch"]
        branch_head = self.run_git(worktree, "rev-parse", "HEAD")
        response, _ = self.call_cli("task", "move", task["id"], "Done")
        self.assertEqual(self.assert_success(response)["status"], "Done")
        self.assertTrue(worktree.exists())
        self.assertEqual(tracked.read_text(encoding="utf-8"), "Edited after review\n")
        self.assertEqual(untracked.read_text(encoding="utf-8"), "keep me\n")
        self.assertEqual(self.run_git(self.primary, "rev-parse", "main"), target_before)
        self.assertEqual(self.run_git(worktree, "rev-parse", "HEAD"), branch_head)
        self.assertTrue(self.branch_exists(self.primary, branch))

    # case-contract: test_task_pr_create_reports_real_gh_failure | The CLI confirms a new repository-backed task persists in Backlog; the UI shows no PR control there, then shows the active-card PR action after the conversation completes with a minimum 30-point hit target. The Done archive control retains its help and waits for the task lock before a real GitHub CLI or branch publication failure without saving a PR link or changing Done status.
    def test_task_pr_create_reports_real_gh_failure(self):
        task = self.create_repo_task(
            "PR failure", [self.primary], merge_targets={self.primary: "main"}
        )
        self.assertEqual(task["status"], "Backlog")
        persisted_backlog = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(persisted_backlog["status"], "Backlog")
        self.complete_fixture_turn(task["id"])
        task = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(task["repositoryWorktrees"][0]["mergeTarget"], "main")
        conflicts, _ = self.call_cli("task", "pr", "conflicts", task["id"])
        self.assertEqual(self.assert_success(conflicts)["repositories"], [])
        completed, _ = self.call_cli("task", "move", task["id"], "Done")
        self.assertEqual(self.assert_success(completed)["status"], "Done")

        command = ["task", "pr", "create", task["id"]]
        operation_lock = TaskOperationLockBarrier(self.data_directory, task["id"])
        process = self.start_cli(*command)
        try:
            time.sleep(0.25)
            self.assertIsNone(process.poll(), "PR creation should wait on the active per-task operation lock before calling gh.")
            current = self.assert_success(self.call_cli("task", "get", task["id"])[0])
            self.assertEqual(current["status"], "Done")
            self.assertIsNone(current["repositoryWorktrees"][0].get("pullRequestNumber"))
            self.assertIsNone(current["repositoryWorktrees"][0].get("pullRequestURL"))
        except BaseException:
            if process.poll() is None:
                process.terminate()
                process.communicate()
            raise
        finally:
            operation_lock.release()
        response, _ = self.finish_cli(process, command, expected_status=1)
        self.assert_failure(response, "operation_failed")
        self.assertTrue(
            "gh auth login" in response["error"]["message"]
            or "couldn't publish the task branch" in response["error"]["message"],
            response["error"]["message"],
        )
        current = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        record = current["repositoryWorktrees"][0]
        self.assertEqual(record["mergeTarget"], "main")
        self.assertIsNone(record.get("pullRequestNumber"))
        self.assertIsNone(record.get("pullRequestURL"))
        self.assertEqual(current["status"], "Done")

    # case-contract: test_review_pr_conflicts_probe_and_verify | Separate Review task cards probe their linked pull requests concurrently on app focus, with refreshes limited to one per 20 seconds, with focus events during cooldown coalesced into one trailing refresh. A conflicting PR or a mergeable PR whose remote head is not pushed locally retains the imported conflict action with its indicator artwork beside its PR link; the UI renders the artwork inside the action, keeps it beside the PR link, and gives both controls hit targets of at least 30×30 points. Clicking the conflict action sends the corrected request in the task conversation. CLI and UI use the same GitHub mergeability and head checks, retry once when resolution remains unconfirmed, and clear the action only after GitHub confirms the pushed head.
    def test_review_pr_conflicts_probe_and_verify(self):
        task = self.create_repo_task("Review PR conflict probe", [self.primary, self.secondary], materialize=True)
        self.assertEqual(task["status"], "Review")
        self.assertEqual(self.assert_success(self.call_cli("task", "pr", "status", task["id"])[0]), [])
        self.seed_done_task_pull_request(task["id"], number=123)
        self.seed_done_task_pull_request(task["id"], number=456, repository_index=1)

        directory = self.data_directory / "review-pr-gh-fixture"
        directory.mkdir()
        state = directory / "state"
        state.write_text("123=CONFLICTING\n456=MERGEABLE\n", encoding="utf-8")
        started = directory / "started"
        started.mkdir()
        executable = directory / "gh"
        executable.write_text(
            "#!/bin/sh\n"
            "if [ \"$1\" != pr ] || [ \"$2\" != view ] || { [ \"$3\" != 123 ] && [ \"$3\" != 456 ]; } || [ \"$4\" != --json ] || [ \"$5\" != mergedAt,mergeable,headRefOid ]; then\n"
            "  echo 'Unexpected gh fixture command' >&2\n"
            "  exit 2\n"
            "fi\n"
            f"touch {shlex.quote(str(started))}/\"$3\"\n"
            f"for attempt in $(seq 1 100); do [ -f {shlex.quote(str(started / '123'))} ] && [ -f {shlex.quote(str(started / '456'))} ] && break; sleep 0.02; done\n"
            f"if [ ! -f {shlex.quote(str(started / '123'))} ] || [ ! -f {shlex.quote(str(started / '456'))} ]; then echo 'PR probes did not run in parallel' >&2; exit 3; fi\n"
            f"mergeable=$(awk -F= -v number=\"$3\" '$1 == number {{ print $2 }}' {shlex.quote(str(state))})\n"
            "head=$(git rev-parse HEAD)\n"
            "if [ \"$mergeable\" = HEAD_MISMATCH ]; then head=remote-head-not-pushed; mergeable=MERGEABLE; fi\n"
            "if [ \"$mergeable\" = CONFLICTING ]; then printf '{\"mergedAt\":null,\"mergeable\":\"CONFLICTING\",\"headRefOid\":\"%s\"}\\n' \"$head\"; else printf '{\"mergedAt\":null,\"mergeable\":\"MERGEABLE\",\"headRefOid\":\"%s\"}\\n' \"$head\"; fi\n",
            encoding="utf-8",
        )
        executable.chmod(0o755)
        environment = {"PATH": f"{directory}:{os.environ.get('PATH', '')}"}
        status, _ = self.call_cli("task", "pr", "status", task["id"], extra_environment=environment)
        states = self.assert_success(status)
        self.assertEqual({item["number"] for item in states}, {123, 456})
        self.assertEqual({item["number"] for item in states if item["hasConflicts"]}, {123})
        self.assertTrue(all(item["headRefOid"] == item["localHeadOid"] for item in states))
        self.assertTrue((started / "123").is_file() and (started / "456").is_file(), "Both linked PR probes should overlap.")

        (started / "123").unlink()
        (started / "456").unlink()
        still_conflicted, _ = self.call_cli("task", "pr", "verify", task["id"], extra_environment=environment)
        self.assertEqual(self.assert_success(still_conflicted)["status"], "stillConflicted")
        self.assertTrue((started / "123").is_file() and (started / "456").is_file())

        state.write_text("123=MERGEABLE\n456=HEAD_MISMATCH\n", encoding="utf-8")
        for number in (123, 456):
            (started / str(number)).unlink()
        mismatch, _ = self.call_cli("task", "pr", "verify", task["id"], extra_environment=environment)
        self.assertEqual(self.assert_success(mismatch)["status"], "stillConflicted", "A mergeable PR with a remote head that is not pushed locally must retain the conflict indicator.")
        mismatch_status, _ = self.call_cli("task", "pr", "status", task["id"], extra_environment=environment)
        mismatch_state = next(item for item in self.assert_success(mismatch_status) if item["number"] == 456)
        self.assertNotEqual(mismatch_state["headRefOid"], mismatch_state["localHeadOid"])

        state.write_text("123=MERGEABLE\n456=MERGEABLE\n", encoding="utf-8")
        for number in (123, 456):
            (started / str(number)).unlink()
        verification, _ = self.call_cli("task", "pr", "verify", task["id"], extra_environment=environment)
        self.assertEqual(self.assert_success(verification)["status"], "resolved")

    # case-contract: test_task_pr_conflicts_detect_without_mutation | The real Git CLI detects conflicts without mutation and blocks PR creation until conflicts are resolved in the task worktree; CLI/XPC resolves staged conflicts locally without pushing and commits and pushes a staged resolution without changing the target. The paired UI verifies PR creation directs the user to resolve conflicts in the task worktree and leaves unresolved conflicts uncommitted and unpublished.
    def test_task_pr_conflicts_detect_without_mutation(self):
        task = self.create_repo_task("PR conflict detection", [self.primary], merge_targets={self.primary: "main"}, materialize=True)
        record = task["repositoryWorktrees"][0]
        worktree = Path(record["worktreePath"])
        conflict_path = "stationai-pr-conflict-fixture.txt"
        remote = self.data_directory / "pr-conflict-origin.git"
        subprocess.run(["git", "init", "--bare", str(remote)], check=True, capture_output=True, text=True)
        self.run_git(self.primary, "remote", "add", "origin", str(remote))
        self.run_git(self.primary, "push", "--set-upstream", "origin", "main")
        target_file = self.primary / conflict_path
        target_file.write_text("target branch version\n", encoding="utf-8")
        self.run_git(self.primary, "add", conflict_path)
        self.run_git(self.primary, "commit", "-m", "Update PR target fixture")
        self.run_git(self.primary, "push", "origin", "main")
        branch_file = worktree / conflict_path
        branch_file.write_text("task branch version\n", encoding="utf-8")
        self.run_git(worktree, "add", conflict_path)
        self.run_git(worktree, "commit", "-m", "Update task branch fixture")
        branch_head = self.run_git(worktree, "rev-parse", "HEAD").strip()
        target_head = self.run_git(self.primary, "rev-parse", "main").strip()

        checked, _ = self.call_cli("task", "pr", "conflicts", task["id"])
        self.assertEqual(self.assert_success(checked)["repositories"], [str(self.primary)])
        self.assertEqual(self.run_git(worktree, "rev-parse", "HEAD").strip(), branch_head)
        self.assertEqual(self.run_git(self.primary, "rev-parse", "main").strip(), target_head)
        self.assertEqual((worktree / conflict_path).read_text(encoding="utf-8"), "task branch version\n")
        self.assertEqual(target_file.read_text(encoding="utf-8"), "target branch version\n")
        requires_ui, _ = self.call_cli("task", "pr", "create", task["id"], expected_status=1)
        self.assert_failure(requires_ui, "conflicts_require_confirmation")
        self.assertEqual(self.run_git(worktree, "rev-parse", "HEAD").strip(), branch_head)
        task_branch_ref = f"refs/heads/{record['branch']}"
        kept_remote_branch = subprocess.run(
            ["git", "--git-dir", str(remote), "show-ref", "--verify", "--quiet", task_branch_ref],
            check=False, capture_output=True, text=True,
        )
        self.assertEqual(kept_remote_branch.returncode, 1, "A blocked PR creation must not publish the task branch.")
        self.run_git(worktree, "fetch", "origin", "main")
        merge = subprocess.run(
            ["git", "-C", str(worktree), "merge", "--no-commit", "--no-ff", "FETCH_HEAD"],
            check=False, capture_output=True, text=True,
        )
        self.assertEqual(merge.returncode, 1, f"Expected the real Git fixture merge to conflict: {merge.stderr}")
        resolved_content = "resolved task and target versions\n"
        branch_file.write_text(resolved_content, encoding="utf-8")
        self.run_git(worktree, "add", conflict_path)
        resolved_only, _ = self.call_cli("task", "pr", "resolve", task["id"], "resolve-only")
        self.assertEqual(self.assert_success(resolved_only)["id"], task["id"])
        resolved_only_head = self.run_git(worktree, "rev-parse", "HEAD").strip()
        self.assertNotEqual(resolved_only_head, branch_head, "Resolve-only should commit a fully staged conflict resolution locally.")
        self.assertEqual(self.run_git(self.primary, "rev-parse", "main").strip(), target_head, "Conflict resolution must leave the target branch unchanged.")
        self.assertEqual(branch_file.read_text(encoding="utf-8"), resolved_content)
        unresolved_remote_branch = subprocess.run(
            ["git", "--git-dir", str(remote), "show-ref", "--verify", "--quiet", task_branch_ref],
            check=False, capture_output=True, text=True,
        )
        self.assertEqual(unresolved_remote_branch.returncode, 1, "Resolve-only must commit locally without publishing the task branch.")

        target_file.write_text("target branch version two\n", encoding="utf-8")
        self.run_git(self.primary, "add", conflict_path)
        self.run_git(self.primary, "commit", "-m", "Advance PR target fixture again")
        self.run_git(self.primary, "push", "origin", "main")
        target_head_second = self.run_git(self.primary, "rev-parse", "main").strip()
        branch_file.write_text("task branch version two\n", encoding="utf-8")
        self.run_git(worktree, "add", conflict_path)
        self.run_git(worktree, "commit", "-m", "Advance task branch fixture again")
        branch_head_second = self.run_git(worktree, "rev-parse", "HEAD").strip()
        self.run_git(worktree, "fetch", "origin", "main")
        second_merge = subprocess.run(
            ["git", "-C", str(worktree), "merge", "--no-commit", "--no-ff", "FETCH_HEAD"],
            check=False, capture_output=True, text=True,
        )
        self.assertEqual(second_merge.returncode, 1, f"Expected the second real Git fixture merge to conflict: {second_merge.stderr}")
        pushed_content = "resolved task and target versions two\n"
        branch_file.write_text(pushed_content, encoding="utf-8")
        self.run_git(worktree, "add", conflict_path)
        resolved, _ = self.call_cli("task", "pr", "resolve", task["id"], "resolve-and-push")
        self.assertEqual(self.assert_success(resolved)["id"], task["id"])
        resolved_head = self.run_git(worktree, "rev-parse", "HEAD").strip()
        self.assertNotEqual(resolved_head, branch_head_second, "A fully staged resolution should be committed when resuming the second merge.")
        self.assertEqual(self.run_git(self.primary, "rev-parse", "main").strip(), target_head_second, "Conflict resolution must leave the target branch unchanged.")
        self.assertEqual(branch_file.read_text(encoding="utf-8"), pushed_content)
        remote_branch_head = self.run_git(remote, "rev-parse", task_branch_ref).strip()
        self.assertEqual(remote_branch_head, resolved_head, "Resolve-and-push must publish the resolved task branch.")
        remote_content = subprocess.run(
            ["git", "--git-dir", str(remote), "show", f"{task_branch_ref}:{conflict_path}"],
            check=True, capture_output=True, text=True,
        ).stdout
        self.assertEqual(remote_content, pushed_content)
        self.assertIsNone(self.assert_success(self.call_cli("task", "get", task["id"])[0])["repositoryWorktrees"][0].get("pullRequestNumber"))
        invalid, _ = self.call_cli("task", "pr", "resolve", task["id"], "unknown", expected_status=2)
        self.assert_failure(invalid, "invalid_argument")
        self.run_git(self.primary, "remote", "remove", "origin")

    # case-contract: test_done_archive_displays_existing_pull_request_link | CLI/XPC fresh reads confirm saved PR data; the UI shows active and archived PR links and an active task's Create PR button. Hovering the outer padded edge of each control triggers its hover feedback.
    def test_done_archive_displays_existing_pull_request_link(self):
        task = self.create_repo_task("Archived linked PR", [self.primary], materialize=True)
        completed, _ = self.call_cli("task", "move", task["id"], "Done")
        self.assertEqual(self.assert_success(completed)["status"], "Done")
        url = self.seed_done_task_pull_request(task["id"])

        current = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(current["status"], "Done")
        record = current["repositoryWorktrees"][0]
        self.assertEqual(record["pullRequestNumber"], 123)
        self.assertEqual(record["pullRequestURL"], url)
        archived = next(item for item in self.assert_success(self.call_cli("board", "list")[0])["tasks"] if item["id"] == task["id"])
        self.assertEqual(archived["repositoryWorktrees"][0]["pullRequestNumber"], 123)

    # case-contract: test_task_lifecycle_rollout_clears_records_and_clean_worktrees | The one-time lifecycle rollout clears task records and clean managed worktrees, preserves branches, and retains dirty managed worktrees with a notice.
    def test_task_lifecycle_rollout_clears_records_and_clean_worktrees(self):
        clean = self.create_repo_task("Rollout clean", [self.primary], materialize=True)
        dirty = self.create_repo_task(
            "Rollout dirty", [self.secondary], branch_from={str(self.secondary): "main"}, materialize=True
        )
        clean_record = clean["repositoryWorktrees"][0]
        dirty_record = dirty["repositoryWorktrees"][0]
        clean_path = Path(clean_record["worktreePath"])
        dirty_path = Path(dirty_record["worktreePath"])
        retained_file = dirty_path / "stationai-secondary.txt"
        retained_file.write_text("Secondary baseline.\nKeep this worktree.\n", encoding="utf-8")
        (self.data_directory / "task-lifecycle-v2-reset").unlink()

        listed, _ = self.call_cli("task", "list")
        self.assertEqual(self.assert_success(listed)["tasks"], [])
        self.assertFalse(clean_path.exists())
        self.assertEqual(retained_file.read_text(encoding="utf-8"), "Secondary baseline.\nKeep this worktree.\n")
        self.assertEqual(self.run_git(self.primary, "show-ref", "--verify", "--quiet", f"refs/heads/{clean_record['branch']}"), "")
        self.assertEqual(self.run_git(self.secondary, "show-ref", "--verify", "--quiet", f"refs/heads/{dirty_record['branch']}"), "")
        notice = json.loads((self.data_directory / "task-lifecycle-v2-notice.json").read_text(encoding="utf-8"))
        self.assertEqual(notice, [str(dirty_path)])

    # case-contract: test_task_status_transitions_and_rejects_unknown_status | With both pairs populated, the board keeps Blocked above Backlog and Waiting Response above In Progress, allows vertical scrolling to reach lower backlog tasks, leaves Review as its own column, hides empty status sections, removes Done from the columns, and rejects manual changes to Codex-owned task status; ⌘F reveals and focuses a prominent board search that filters task cards by title as text changes, while close restores all cards. Answering a question without an explicit completed outcome leaves the task in Waiting Response. Task card titles use slightly expanded letter spacing and line spacing.
    def test_task_status_transitions_and_rejects_unknown_status(self):
        task_id = self.create_task()["id"]
        response, _ = self.call_cli("task", "move", task_id, "Unknown", expected_status=2)
        self.assert_failure(response, "invalid_argument")
        for status in ["In Progress", "Blocked", "Waiting Response", "Review", "Backlog"]:
            response, _ = self.call_cli("task", "move", task_id, status, expected_status=2)
            self.assert_failure(response, "invalid_argument")
            self.assertIn("controlled by Codex", response["error"]["message"])
        response, _ = self.call_cli("task", "move", task_id, "Done", expected_status=2)
        self.assert_failure(response, "invalid_argument")
        self.assertIn("Only a task in Review", response["error"]["message"])
        response, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(response)["status"], "Backlog")

        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        blocked_id = self.create_task("Blocked layout", roots=[self.secondary])["id"]
        empty_fixture = self.data_directory / "codex-fixture-status-empty"
        shutil.copyfile(fixture, empty_fixture)
        empty_fixture.chmod(0o755)
        (self.data_directory / ".stationai-codex-fixture-owner").write_text(
            "StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        blocked_response, _ = self.call_cli(
            "conversation", "send", blocked_id, "--message", "Please ask your questions.",
            expected_status=1,
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(empty_fixture)},
        )
        self.assert_failure(blocked_response, "operation_failed")
        blocked = self.assert_success(self.call_cli("task", "get", blocked_id)[0])
        self.assertEqual(blocked["status"], "Blocked")
        self.assertIn("question response", blocked["statusMessage"].lower())

        waiting_id = self.create_task("Waiting layout", roots=[self.primary])["id"]
        question_fixture = self.data_directory / "codex-fixture-status-question-flow"
        shutil.copyfile(fixture, question_fixture)
        question_fixture.chmod(0o755)
        question_response, question_events = self.call_cli(
            "conversation", "send", waiting_id, "--message", "Please ask your questions.",
            "--mode", "plan", "--answer", "color=Blue", "--answer", "token=fixture-secret",
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(question_fixture)},
        )
        self.assert_success(question_response)
        self.assertTrue(any(
            event.get("type") == "started" and event.get("payload", {}).get("taskStatus") == "In Progress"
            for event in question_events
        ), "Starting the question turn should move the task into In Progress.")
        input_event = next(event for event in question_events if event.get("type") == "user_input")
        self.assertEqual(input_event["payload"].get("taskStatus"), "Waiting Response")
        self.assertTrue(any(event.get("type") == "task_status"
                            and event.get("payload", {}).get("taskStatus") == "In Progress"
                            for event in question_events),
                        "Submitting the answer should resume the active task.")
        waiting = self.assert_success(self.call_cli("task", "get", waiting_id)[0])
        self.assertEqual(waiting["status"], "Waiting Response")
        self.assertEqual(self.assert_success(self.call_cli("task", "get", blocked_id)[0])["status"], "Blocked")

    # case-contract: test_task_progress_reports_publish_persist_and_clear | The CLI publishes standard and custom progress only during an active task turn, persists each report across fresh CLI/XPC connections, rejects invalid reports, and clears explicitly. During an active turn the CLI accepts completed and waiting-response outcomes, rejects invalid or inactive outcomes, and persists the selected status; provider processes started from the CLI/XPC service or the app's composer inherit that app's bridge service name and store directory, and an outcome reported with exactly that inherited environment reaches the task. A successful turn without an outcome receives up to two private follow-up requests to report one; a completed report during either reminder moves the task to Review, a waiting-response report during a reminder stops retries and leaves the task in Waiting Response, and no report after both reminders falls back to Waiting Response. The board shows progress details and places completed tasks in Review and waiting outcomes in Waiting Response. New threads receive hidden progress and outcome instructions at thread start, and existing threads receive them on resume; turn requests do not repeat the instructions. Those instructions require updates at phase changes, around substantial tools, and at least every 30 seconds during long work. Only an explicit completed outcome reaches Review. When a final answer ends with the outcome command written as text instead of run, the final answer, fresh history, and transcript hide that command, and it counts as the turn's outcome only when it names this task. Private reminder prompts, replies, and turn-scoped activities remain absent from Codex history and the visible transcript, including after later ordinary turns. Fresh Codex history after those reminders also retains the latest ordinary-turn diff while keeping reminder-only replies hidden.
    def test_task_progress_reports_publish_persist_and_clear(self):
        task_id = self.create_task("Progress reports", roots=[self.primary])["id"]
        response, _ = self.call_cli("task", "progress", "publish", task_id, "--type", "building", expected_status=1)
        self.assert_failure(response, "invalid_transition")
        inactive_outcome, _ = self.call_cli("task", "outcome", task_id, "completed", expected_status=1)
        self.assert_failure(inactive_outcome, "invalid_transition")

        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-unique-turns-hold-release"
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-codex-fixture-owner").write_text(
            "StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        environment = os.environ.copy()
        environment.update({
            "STATIONAI_DATA_DIRECTORY": str(self.data_directory),
            "STATIONAI_E2E_WORKTREE_DIRECTORY": str(self.worktree_directory),
            "STATIONAI_E2E_DEFAULTS_SUITE": self.defaults_suite,
            "STATIONAI_BRIDGE_SERVICE_NAME": arguments.service_name,
            "STATIONAI_E2E_CODEX_EXECUTABLE": str(executable),
        })
        turn = subprocess.Popen(
            [str(self.cli), "conversation", "send", task_id, "--message", "Work on this task."],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment,
        )
        active_marker = Path(str(executable) + ".turn-active")
        release_marker = Path(str(executable) + ".turn-release")
        try:
            deadline = time.monotonic() + 20
            while not active_marker.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(active_marker.exists(), "The fixture turn did not become active.")
            current, _ = self.call_cli("task", "get", task_id)
            self.assertEqual(self.assert_success(current)["status"], "In Progress")

            published, _ = self.call_cli("task", "progress", "publish", task_id, "--type", "building", "--detail", "Compiling the app")
            record = self.assert_success(published)
            self.assertEqual(record["progressType"], "building")
            self.assertEqual(record["progressLabel"], "Building")
            self.assertEqual(record["progressDetail"], "Compiling the app")
            fresh, _ = self.call_cli("task", "get", task_id)
            self.assertEqual(self.assert_success(fresh)["progressDetail"], "Compiling the app")

            invalid_type, _ = self.call_cli("task", "progress", "publish", task_id, "--type", "unknown", expected_status=2)
            self.assert_failure(invalid_type, "invalid_argument")
            custom, _ = self.call_cli("task", "progress", "custom", task_id, "--label", "Checking migration", "--detail", "Reading the stored task data")
            custom_record = self.assert_success(custom)
            self.assertIsNone(custom_record.get("progressType"))
            self.assertEqual(custom_record["progressLabel"], "Checking migration")
            self.assertEqual(custom_record["progressDetail"], "Reading the stored task data")
            blank_custom, _ = self.call_cli("task", "progress", "custom", task_id, "--label", " ", expected_status=2)
            self.assert_failure(blank_custom, "invalid_argument")

            invalid_outcome, _ = self.call_cli("task", "outcome", task_id, "unknown", expected_status=2)
            self.assert_failure(invalid_outcome, "invalid_argument")

            cleared, _ = self.call_cli("task", "progress", "clear", task_id)
            self.assertIsNone(self.assert_success(cleared).get("progressLabel"))
            final_report, _ = self.call_cli("task", "progress", "publish", task_id, "--type", "testing")
            self.assertEqual(self.assert_success(final_report)["progressLabel"], "Testing")
            # The provider process must inherit this service's name and store, so
            # its in-turn outcome call reaches this task rather than the defaults.
            bridge_environment = json.loads(Path(str(executable) + ".bridge-environment").read_text(encoding="utf-8"))
            self.assertEqual(bridge_environment["STATIONAI_BRIDGE_SERVICE_NAME"], arguments.service_name)
            self.assertEqual(Path(bridge_environment["STATIONAI_DATA_DIRECTORY"]).resolve(), self.data_directory.resolve())
            completed, _ = self.call_cli("task", "outcome", task_id, "completed", extra_environment=bridge_environment)
            completed_record = self.assert_success(completed)
            self.assertEqual(completed_record["outcome"], "completed")
            self.assertEqual(completed_record["taskStatus"], "In Progress", "The outcome is staged until the Codex turn completes successfully.")
            release_marker.write_text("Release the active turn.\n", encoding="utf-8")
            stdout, stderr = turn.communicate(timeout=20)
            self.assertEqual(turn.returncode, 0, f"Fixture conversation failed: {stdout}; {stderr}")
            final_response = json.loads([line for line in stdout.splitlines() if line.strip()][-1])
            self.assertTrue(final_response["ok"], final_response.get("error"))
            finished, _ = self.call_cli("task", "get", task_id)
            finished_record = self.assert_success(finished)
            self.assertEqual(finished_record["status"], "Review")
            self.assertIsNone(finished_record.get("progressLabel"))
            follow_up = subprocess.Popen(
                [str(self.cli), "conversation", "send", task_id, "--message", "Continue on this task."],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment,
            )
            try:
                deadline = time.monotonic() + 10
                while not active_marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(active_marker.exists(), "The resumed fixture turn did not become active.")
                waiting_outcome, _ = self.call_cli("task", "outcome", task_id, "waiting-response")
                waiting_record = self.assert_success(waiting_outcome)
                self.assertEqual(waiting_record["outcome"], "waiting-response")
                self.assertEqual(waiting_record["taskStatus"], "In Progress")
                release_marker.write_text("Release the resumed turn.\n", encoding="utf-8")
                follow_stdout, follow_stderr = follow_up.communicate(timeout=20)
                self.assertEqual(follow_up.returncode, 0, f"Resumed fixture conversation failed: {follow_stdout}; {follow_stderr}")
                follow_response = json.loads([line for line in follow_stdout.splitlines() if line.strip()][-1])
                self.assertTrue(follow_response["ok"], follow_response.get("error"))
            finally:
                if follow_up.poll() is None:
                    release_marker.write_text("Release the resumed turn.\n", encoding="utf-8")
                    follow_up.communicate(timeout=20)
            omitted_follow_up = subprocess.Popen(
                [str(self.cli), "conversation", "send", task_id, "--message", "A turn without an outcome."],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment,
            )
            try:
                deadline = time.monotonic() + 10
                while not active_marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(active_marker.exists(), "The no-outcome fixture turn should become active.")
                for reminder_index in range(3):
                    self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["status"], "In Progress", "The fallback status should be deferred until both reminders finish.")
                    release_marker.write_text(f"Release turn {reminder_index + 1}.\n", encoding="utf-8")
                    if reminder_index < 2:
                        deadline = time.monotonic() + 10
                        while active_marker.exists() and time.monotonic() < deadline:
                            time.sleep(0.02)
                        self.assertFalse(active_marker.exists(), "The fixture should finish the current unreported turn.")
                        deadline = time.monotonic() + 10
                        while not active_marker.exists() and time.monotonic() < deadline:
                            time.sleep(0.02)
                        self.assertTrue(active_marker.exists(), "StationAI should send the next private outcome reminder.")
                omitted_stdout, omitted_stderr = omitted_follow_up.communicate(timeout=20)
                self.assertEqual(omitted_follow_up.returncode, 0, f"No-outcome fixture conversation failed: {omitted_stdout}; {omitted_stderr}")
                omitted_record, _ = self.call_cli("task", "get", task_id)
                self.assertEqual(self.assert_success(omitted_record)["status"], "Waiting Response")
                visible_history, _ = self.call_cli(
                    "conversation", "history", task_id,
                    extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)},
                )
                visible_history_record = self.assert_success(visible_history)
                visible_messages = visible_history_record["messages"]
                self.assertFalse(any("previous request finished" in item.get("text", "") for item in visible_messages), "Private reminder text must not appear in conversation history.")
                self.assertFalse(any("Fixture internal reminder reply." in item.get("text", "") for item in visible_messages), "Private reminder replies must not appear in conversation history.")
                self.assertIn("ordinary-turn-diff-after-reminders", visible_history_record["diff"]["unifiedDiff"], "Private reminders must not replace the latest ordinary-turn diff.")
            finally:
                if omitted_follow_up.poll() is None:
                    release_marker.write_text("Release the no-outcome turn.\n", encoding="utf-8")
                    omitted_follow_up.communicate(timeout=20)
            recovered_follow_up = subprocess.Popen(
                [str(self.cli), "conversation", "send", task_id, "--message", "Report the outcome after a reminder."],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment,
            )
            try:
                deadline = time.monotonic() + 10
                while not active_marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(active_marker.exists(), "The reminder recovery fixture turn should become active.")
                release_marker.write_text("Release the initial unreported turn.\n", encoding="utf-8")
                deadline = time.monotonic() + 10
                while active_marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertFalse(active_marker.exists(), "The initial unreported turn should finish before the reminder.")
                deadline = time.monotonic() + 10
                while not active_marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(active_marker.exists(), "StationAI should send a private reminder after the omitted outcome.")
                completed_reminder, _ = self.call_cli("task", "outcome", task_id, "completed", extra_environment=bridge_environment)
                self.assertEqual(self.assert_success(completed_reminder)["outcome"], "completed")
                release_marker.write_text("Release the reminder after its outcome is reported.\n", encoding="utf-8")
                recovered_stdout, recovered_stderr = recovered_follow_up.communicate(timeout=20)
                self.assertEqual(recovered_follow_up.returncode, 0, f"Reminder recovery fixture conversation failed: {recovered_stdout}; {recovered_stderr}")
                recovered_record, _ = self.call_cli("task", "get", task_id)
                self.assertEqual(self.assert_success(recovered_record)["status"], "Review", "A completed CLI outcome reported during a private reminder should be honored.")
            finally:
                if recovered_follow_up.poll() is None:
                    release_marker.write_text("Release the reminder recovery turn.\n", encoding="utf-8")
                    recovered_follow_up.communicate(timeout=20)
            waiting_follow_up = subprocess.Popen(
                [str(self.cli), "conversation", "send", task_id, "--message", "Report waiting after a reminder."],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment,
            )
            try:
                deadline = time.monotonic() + 10
                while not active_marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(active_marker.exists(), "The waiting outcome fixture turn should become active.")
                release_marker.write_text("Release the initial unreported turn.\n", encoding="utf-8")
                deadline = time.monotonic() + 10
                while active_marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertFalse(active_marker.exists(), "The initial turn should finish before asking for its outcome.")
                deadline = time.monotonic() + 10
                while not active_marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(active_marker.exists(), "StationAI should send a reminder before reporting a waiting outcome.")
                waiting_reminder, _ = self.call_cli("task", "outcome", task_id, "waiting-response", extra_environment=bridge_environment)
                self.assertEqual(self.assert_success(waiting_reminder)["outcome"], "waiting-response")
                release_marker.write_text("Release the reminder after its outcome is reported.\n", encoding="utf-8")
                waiting_stdout, waiting_stderr = waiting_follow_up.communicate(timeout=20)
                self.assertEqual(waiting_follow_up.returncode, 0, f"Waiting reminder fixture conversation failed: {waiting_stdout}; {waiting_stderr}")
                waiting_record, _ = self.call_cli("task", "get", task_id)
                self.assertEqual(self.assert_success(waiting_record)["status"], "Waiting Response", "A waiting-response outcome reported during a private reminder should be honored.")
            finally:
                if waiting_follow_up.poll() is None:
                    release_marker.write_text("Release the waiting reminder turn.\n", encoding="utf-8")
                    waiting_follow_up.communicate(timeout=20)
            # A model can write its outcome command as answer text instead of running
            # it. The echo is hidden, and it counts only when it names this task.
            for echoed_task_id, expected_status in [(str(uuid.uuid4()).upper(), "Waiting Response"), (task_id, "Review")]:
                echoed_turn = subprocess.Popen(
                    [str(self.cli), "conversation", "send", task_id, "--message", f"Echo the outcome command for {echoed_task_id}."],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment,
                )
                try:
                    deadline = time.monotonic() + 10
                    while not active_marker.exists() and time.monotonic() < deadline:
                        time.sleep(0.02)
                    self.assertTrue(active_marker.exists(), "The echoed-outcome fixture turn should become active.")
                    held_turns = 3 if expected_status == "Waiting Response" else 1
                    for held_turn_index in range(held_turns):
                        release_marker.write_text(f"Release echoed turn {held_turn_index + 1}.\n", encoding="utf-8")
                        if held_turn_index < held_turns - 1:
                            deadline = time.monotonic() + 10
                            while active_marker.exists() and time.monotonic() < deadline:
                                time.sleep(0.02)
                            self.assertFalse(active_marker.exists(), "The current echoed turn should finish before a private reminder.")
                            deadline = time.monotonic() + 10
                            while not active_marker.exists() and time.monotonic() < deadline:
                                time.sleep(0.02)
                            self.assertTrue(active_marker.exists(), "StationAI should send a private reminder for an unreported echoed outcome.")
                    echoed_stdout, echoed_stderr = echoed_turn.communicate(timeout=20)
                    self.assertEqual(echoed_turn.returncode, 0, f"Echoed-outcome fixture conversation failed: {echoed_stdout}; {echoed_stderr}")
                    echoed_events = [json.loads(line) for line in echoed_stdout.splitlines() if line.strip()]
                    finals = [event["payload"]["text"] for event in echoed_events if event.get("type") == "assistant_final"]
                    self.assertEqual(finals, ["Fixture answer with an echoed outcome."], "The streamed final answer must hide the echoed outcome command.")
                    echoed_record, _ = self.call_cli("task", "get", task_id)
                    self.assertEqual(self.assert_success(echoed_record)["status"], expected_status)
                    echoed_history = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)})[0])
                    self.assertTrue(any(item["text"] == "Fixture answer with an echoed outcome." for item in echoed_history["messages"]))
                    self.assertFalse(any("task outcome" in message["text"] for message in echoed_history["messages"]), "A fresh history read must hide the echoed outcome command.")
                    self.assertFalse(any(item.get("text") == "[StationAI private outcome reminder hidden]" for item in echoed_history["messages"]), "A later Codex history refresh must omit earlier private reminders.")
                    self.assertFalse(any(item.get("text") == "[StationAI private outcome response hidden]" for item in echoed_history["messages"]), "A later Codex history refresh must omit earlier private reminder replies.")
                    self.assertFalse(any("previous request finished without reporting" in item.get("text", "") or "Fixture internal reminder reply." in item.get("text", "") for item in echoed_history["messages"]), "Later history refreshes must not reveal prior reminder prompts or replies.")
                    self.assertFalse(any(item.get("id", "").startswith("item_private_reminder_activity_") for item in echoed_history.get("activities", [])), "Later ordinary Codex history must omit activities owned by private reminders.")
                finally:
                    if echoed_turn.poll() is None:
                        release_marker.write_text("Release the echoed-outcome turn.\n", encoding="utf-8")
                        echoed_turn.communicate(timeout=20)
            turn_data = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
            self.assertEqual(turn_data["threadStartCount"], 1)
            self.assertGreaterEqual(turn_data["threadResumeCount"], 1)
            self.assertEqual(len(turn_data["turns"]), 13)
            reminder_turns = [turn for turn in turn_data["turns"] if "previous request finished without reporting" in turn.get("userMessage", "")]
            self.assertEqual(len(reminder_turns), 6, "Only the missing-outcome sends should receive private reminders.")
            self.assertTrue(all("task outcome" in turn["userMessage"] and ("reminder 1 of 2" in turn["userMessage"] or "reminder 2 of 2" in turn["userMessage"]) for turn in reminder_turns), "Each hidden request should explicitly direct the agent to report an outcome.")
            self.assertTrue(all(turn["developerInstructions"] is None for turn in turn_data["turns"]), "Thread-scoped task instructions should not be repeated in turn requests.")
            instructions = turn_data["threadStartDeveloperInstructions"]
            self.assertIn(str(self.cli), instructions)
            self.assertIn("task progress publish", instructions)
            self.assertIn("hidden from the conversation", instructions)
            self.assertIn("at least every 30 seconds", instructions)
            self.assertIn("active suite/case and position", instructions)
            self.assertIn("CLI/XPC 3/8", instructions)
            self.assertIn("under 80 characters", instructions)
            self.assertIn("task outcome", instructions)
            self.assertIn("up to two private follow-up messages", instructions)
            self.assertIn("waiting-response", instructions)
            self.assertIn("final CLI action", instructions)
            self.assertIn("Active task worktrees for edits", instructions)
            self.assertIn("Never silently edit a source repository path.", instructions)
            self.assertIn("workspace repos list", instructions)
            self.assertIn("read-only inspection of returned source paths", instructions)
            self.assertIn("Add a repository to this task only when you intend to create or commit changes in it", instructions)
            self.assertIn("Do not interrupt the user or ask them to confirm the selection merely because the task appears unrelated.", instructions)
            resume_instructions = turn_data["threadResumeDeveloperInstructions"]
            self.assertTrue(resume_instructions, "Resumed task threads should receive updated task instructions.")
            self.assertTrue(all("task outcome" in instructions for instructions in resume_instructions))
        finally:
            if turn.poll() is None:
                release_marker.write_text("Release the active turn.\n", encoding="utf-8")
                turn.communicate(timeout=20)
            active_marker.unlink(missing_ok=True)
            release_marker.unlink(missing_ok=True)

    # case-contract: test_task_progress_reports_clear_on_failed_turns_and_questions | Progress reports clear when turns fail or are interrupted and when Codex requests user input; a staged completed outcome is discarded if its turn fails, leaving the task Blocked. The task card removes the report while lifecycle states remain Blocked or In Progress. A blocking structured question appears inline and moves the task to Waiting Response; its answer resumes the active turn in In Progress, and the answered turn finishes in Waiting Response. First-thread instructions distinguish source repository paths from active task worktree paths, allow read-only inspection without attaching a repo, and reserve repository add APIs for changes that need a worktree.
    def test_task_progress_reports_clear_on_failed_turns_and_questions(self):
        for fixture_name, expected_reason in [
            ("codex-fixture-progress-hold-release-failed", "failed"),
            ("codex-fixture-progress-hold-release-interrupted", "interrupted"),
        ]:
            task_id = self.create_task(f"Progress {expected_reason}", roots=[self.primary])["id"]
            process, executable, active, release = self.start_progress_fixture_turn(task_id, fixture_name)
            try:
                report, _ = self.call_cli("task", "progress", "publish", task_id, "--type", "testing", "--detail", "Waiting for the result")
                self.assertEqual(self.assert_success(report)["progressLabel"], "Testing")
                staged, _ = self.call_cli("task", "outcome", task_id, "completed")
                staged_record = self.assert_success(staged)
                self.assertEqual(staged_record["outcome"], "completed")
                self.assertEqual(staged_record["taskStatus"], "In Progress")
                release.write_text("Release the active turn.\n", encoding="utf-8")
                stdout, stderr = process.communicate(timeout=20)
                self.assertEqual(process.returncode, 1, f"Expected the fixture {expected_reason} turn to fail: {stdout}; {stderr}")
                final_response = json.loads([line for line in stdout.splitlines() if line.strip()][-1])
                self.assert_failure(final_response, "operation_failed")
                current, _ = self.call_cli("task", "get", task_id)
                current_record = self.assert_success(current)
                self.assertEqual(current_record["status"], "Blocked")
                self.assertIsNone(current_record.get("progressLabel"))
            finally:
                if process.poll() is None:
                    release.write_text("Release the active turn.\n", encoding="utf-8")
                    process.communicate(timeout=20)
                active.unlink(missing_ok=True)
                release.unlink(missing_ok=True)

        task_id = self.create_repo_task("Progress question", [self.primary])["id"]
        process, executable, active, release = self.start_progress_fixture_turn(
            task_id, "codex-fixture-progress-user-question",
            answers=["question_action=Continue"],
        )
        outcome_hold = Path(str(executable) + ".outcome-hold")
        outcome_active = Path(str(executable) + ".outcome-active")
        outcome_release = Path(str(executable) + ".outcome-release")
        try:
            report, _ = self.call_cli("task", "progress", "publish", task_id, "--type", "reviewing")
            self.assertEqual(self.assert_success(report)["progressLabel"], "Reviewing")
            outcome_hold.write_text("Hold final turn completion for answer status verification.\n", encoding="utf-8")
            release.write_text("Release the active turn.\n", encoding="utf-8")
            deadline = time.monotonic() + 10
            while not outcome_active.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(outcome_active.is_file(), "The fixture should acknowledge the answer and hold final completion.")
            current, _ = self.call_cli("task", "get", task_id)
            self.assertEqual(self.assert_success(current)["status"], "In Progress", "The accepted answer should resume the active task in In Progress.")
            outcome_release.write_text("Release final turn completion.\n", encoding="utf-8")
            stdout, stderr = process.communicate(timeout=20)
            self.assertEqual(process.returncode, 0, f"Answering the fixture question should complete the turn: {stdout}; {stderr}")
            final_response = json.loads([line for line in stdout.splitlines() if line.strip()][-1])
            self.assertTrue(final_response["ok"], final_response.get("error"))
            current, _ = self.call_cli("task", "get", task_id)
            current_record = self.assert_success(current)
            self.assertEqual(current_record["status"], "Waiting Response")
            self.assertEqual([item["repositoryPath"] for item in current_record["repositoryWorktrees"]], [str(self.primary)])
            self.assertIsNone(current_record.get("progressLabel"))
            history = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
            instructions = history["threadStartDeveloperInstructions"]
            self.assertIn("read-only inspection of returned source paths", instructions)
            self.assertIn("Add a repository to this task only when you intend to create or commit changes in it", instructions)
            self.assertIn("workspace repos list", instructions)
            self.assertIn("task repository add", instructions)
            self.assertIn("Do not interrupt the user or ask them to confirm the selection merely because the task appears unrelated.", instructions)
            self.assertFalse(Path(str(executable) + ".assessment.history").exists())
        finally:
            if process.poll() is None:
                release.write_text("Release the active turn.\n", encoding="utf-8")
                outcome_release.write_text("Release final turn completion.\n", encoding="utf-8")
                process.communicate(timeout=20)
            active.unlink(missing_ok=True)
            release.unlink(missing_ok=True)
            outcome_hold.unlink(missing_ok=True)
            outcome_active.unlink(missing_ok=True)
            outcome_release.unlink(missing_ok=True)

    # case-contract: test_task_rename_persists_and_rejects_blank_title | A rename waits for the real per-task operation lock, then persists across fresh CLI/XPC reads; rejecting a blank rename preserves the last valid title.
    def test_task_rename_persists_and_rejects_blank_title(self):
        task_id = self.create_task()["id"]
        barrier = TaskOperationLockBarrier(self.data_directory, task_id)
        process = self.start_cli("task", "rename", task_id, "--title", "Renamed through XPC")
        try:
            time.sleep(0.25)
            waited_for_lock = process.poll() is None
        finally:
            barrier.release()
        response, _ = self.finish_cli(process, ("task", "rename", task_id, "--title", "Renamed through XPC"))
        self.assertTrue(waited_for_lock, "Rename should wait while another process holds the real task-operation lock.")
        self.assertEqual(self.assert_success(response)["title"], "Renamed through XPC")
        response, _ = self.call_cli("task", "rename", task_id, "--title", " ", expected_status=2)
        self.assert_failure(response, "invalid_argument")
        response, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(response)["title"], "Renamed through XPC")

    # case-contract: test_task_roots_set_get_order_deduplication_and_validation | Root editing preserves order, removes duplicates, rejects an empty list, and waits for an active conversation turn; a stale Git-folder validation is rejected after a newer folder edit, and the newer roots remain saved.
    def test_task_roots_set_get_order_deduplication_and_validation(self):
        task_id = self.create_task()["id"]
        response, _ = self.call_cli(
            "task", "roots", "set", task_id,
            "--root", self.secondary,
            "--root", self.custom,
            "--root", self.primary,
            "--root", self.secondary,
        )
        expected_roots = [str(self.secondary), str(self.custom), str(self.primary)]
        self.assertEqual(self.assert_success(response)["workspaceRoots"], expected_roots)
        response, _ = self.call_cli("task", "roots", "get", task_id)
        self.assertEqual(self.assert_success(response)["roots"], expected_roots)

        reservation_task = self.create_task("Conversation reservation for roots", [self.primary])
        reservation_id = reservation_task["id"]
        reservation = ConversationTurnLockBarrier(self.data_directory, reservation_id)
        roots_command = ["task", "roots", "set", reservation_id, "--root", self.custom]
        roots_process = None
        continue_roots_process = False
        try:
            roots_process = self.start_cli(*roots_command)
            time.sleep(0.25)
            self.assertIsNone(roots_process.poll(), "Workspace-root edits should wait for the active conversation-turn reservation.")
            unchanged, _ = self.call_cli("task", "get", reservation_id)
            self.assertEqual(self.assert_success(unchanged)["workspaceRoots"], [str(self.primary)])
            continue_roots_process = True
        finally:
            reservation.release()
            if not continue_roots_process and roots_process is not None and roots_process.poll() is None:
                roots_process.terminate()
                try:
                    roots_process.communicate(timeout=20)
                except subprocess.TimeoutExpired:
                    roots_process.kill()
                    roots_process.communicate()
        self.assertIsNotNone(roots_process)
        roots_response, _ = self.finish_cli(roots_process, roots_command)
        self.assertEqual(self.assert_success(roots_response)["workspaceRoots"], [str(self.custom)])

        concurrent_task = self.create_repo_task("Concurrent root edit", [self.primary])
        concurrent_id = concurrent_task["id"]
        barrier = GitConfigReadBarrier(self.secondary)
        stale_command = [
            "task", "roots", "set", concurrent_id,
            "--root", self.secondary,
        ]
        stale_process = None
        continue_stale_process = False
        try:
            stale_process = self.start_cli(*stale_command)
            barrier.wait_for_reader()
            newer, _ = self.call_cli("task", "roots", "set", concurrent_id, "--root", self.custom)
            newer_record = self.assert_success(newer)
            self.assertEqual(newer_record["workspaceRoots"], [str(self.custom)])
            self.assertEqual(newer_record["repositoryWorktrees"], [])
            continue_stale_process = True
        finally:
            barrier.release()
            if not continue_stale_process and stale_process is not None and stale_process.poll() is None:
                stale_process.terminate()
                try:
                    stale_process.communicate(timeout=20)
                except subprocess.TimeoutExpired:
                    stale_process.kill()
                    stale_process.communicate()
        self.assertIsNotNone(stale_process)
        stale, _ = self.finish_cli(stale_process, stale_command, expected_status=1)
        self.assert_failure(stale, "invalid_transition")
        final, _ = self.call_cli("task", "get", concurrent_id)
        final_record = self.assert_success(final)
        self.assertEqual(final_record["workspaceRoots"], [str(self.custom)])
        self.assertEqual(final_record["contextFolders"], [str(self.custom)])
        self.assertEqual(final_record["repositoryWorktrees"], [])
        response, _ = self.call_cli("task", "roots", "set", task_id, expected_status=2)
        self.assert_failure(response, "invalid_argument")
        response, _ = self.call_cli("task", "roots", "get", task_id)
        self.assertEqual(self.assert_success(response)["roots"], expected_roots)

    # case-contract: test_conversation_repository_picker_adds_repository_worktree | Repository suggestions can be filtered and navigated with Up/Down, and Enter selects the highlighted repository; UI selection waits for an active turn and persists a pending auto branch. While the conversation is empty, a prominent theme-colored heading names all selected repositories and updates as repository APIs add or replace context; compact repository labels remain in the header without a duplicate repository summary. Dark and light themes use distinct prominent title colors, the supporting model prompt sits below with generous spacing, and the generic Start a conversation heading is absent. Additional context folders remain identifiable. The task repository API remains available during an active turn, prepares a managed worktree, updates saved repository selection, replaces repository context safely, and the paired UI shows API additions/removals. The main assistant is instructed to list repositories through StationAI, inspect listed source paths read-only without attaching them, and add repositories only when it needs a task worktree for changes or commits.
    def test_conversation_repository_picker_adds_repository_worktree(self):
        task = self.create_task("Add repository in conversation", [self.primary])
        task_id = task["id"]
        self.assertEqual(task["repositoryWorktrees"], [])
        self.assertEqual(task["workspaceRoots"], [str(self.primary)])
        reservation = ConversationTurnLockBarrier(self.data_directory, task_id)
        try:
            added_response, _ = self.call_cli("task", "repository", "add", task_id, "--repo", self.primary)
            updated = self.assert_success(added_response)
            self.assertEqual(len(updated["repositoryWorktrees"]), 1)
            added = updated["repositoryWorktrees"][0]
            self.assertEqual(added["repositoryPath"], str(self.primary))
            self.assertFalse(added["isPending"], "The AI-facing repository API should prepare an editable worktree immediately.")
            self.assertNotEqual(added["worktreePath"], str(self.primary))
            self.assertTrue(Path(added["worktreePath"]).is_dir())
            self.assertTrue(Path(added["worktreePath"]).is_relative_to(self.worktree_directory))
            replacement_response, _ = self.call_cli(
                "task", "repository", "replace", task_id, "--repo", self.secondary
            )
            replaced = self.assert_success(replacement_response)
            self.assertEqual([item["repositoryPath"] for item in replaced["repositoryWorktrees"]], [str(self.secondary)])
            self.assertFalse(replaced["repositoryWorktrees"][0]["isPending"])
            self.assertTrue(Path(replaced["repositoryWorktrees"][0]["worktreePath"]).is_dir())
            self.assertTrue(Path(added["worktreePath"]).is_dir(), "The active turn must keep its old cwd until it releases the reservation.")
            unchanged, _ = self.call_cli("task", "get", task_id)
            self.assertEqual(self.assert_success(unchanged)["repositoryWorktrees"], replaced["repositoryWorktrees"])
        finally:
            reservation.release()
        response, _ = self.call_cli("settings", "get")
        self.assertEqual(self.assert_success(response)["lastSelectedRepositories"], [str(self.secondary)])
        self.assertEqual(added["branch"], "add-repository-in-conversation")
        self.assertTrue(added["branchFrom"])
        self.assertTrue(added["mergeTarget"])
        self.assertEqual(updated["workspaceRoots"], [added["worktreePath"]])
        self.assertEqual(updated["contextFolders"], [])
        duplicate, _ = self.call_cli("task", "repository", "add", task_id, "--repo", self.secondary, expected_status=2)
        self.assert_failure(duplicate, "invalid_argument")
        invalid, _ = self.call_cli("task", "repository", "add", task_id, "--repo", self.custom, expected_status=1)
        self.assert_failure(invalid, "operation_failed")
        fresh, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(fresh)["repositoryWorktrees"], replaced["repositoryWorktrees"])


    # case-contract: test_task_repository_settings_validate_persist_and_lock_after_start | Pending repository branch, merge-from, and merge-to settings wait for an active conversation turn, then persist across fresh CLI/XPC reads; invalid settings leave prior values intact, and settings are locked after worktree creation.
    def test_task_repository_settings_validate_persist_and_lock_after_start(self):
        task = self.create_repo_task("Repository settings", [self.primary])
        task_id = task["id"]
        initial = task["repositoryWorktrees"][0]
        edit_command = [
            "task", "repository", "edit", task_id,
            "--repo", self.primary,
            "--branch", "settings-edited",
            "--branch-from", "branch-source",
            "--merge-target", "branch-source",
        ]
        reservation = ConversationTurnLockBarrier(self.data_directory, task_id)
        edit_process = None
        continue_edit_process = False
        try:
            edit_process = self.start_cli(*edit_command)
            time.sleep(0.25)
            self.assertIsNone(edit_process.poll(), "Repository settings should wait for the active conversation-turn reservation.")
            unchanged, _ = self.call_cli("task", "get", task_id)
            self.assertEqual(self.assert_success(unchanged)["repositoryWorktrees"][0]["branch"], initial["branch"])
            continue_edit_process = True
        finally:
            reservation.release()
            if not continue_edit_process and edit_process is not None and edit_process.poll() is None:
                edit_process.terminate()
                try:
                    edit_process.communicate(timeout=20)
                except subprocess.TimeoutExpired:
                    edit_process.kill()
                    edit_process.communicate()
        self.assertIsNotNone(edit_process)
        changed, _ = self.finish_cli(edit_process, edit_command)
        edited = self.assert_success(changed)["repositoryWorktrees"][0]
        self.assertEqual(edited["branch"], "settings-edited")
        self.assertEqual(edited["branchFrom"], "branch-source")
        self.assertEqual(edited["mergeTarget"], "branch-source")
        self.assertTrue(edited["isPending"])
        self.assertEqual(edited["worktreePath"], self.primary.as_posix())

        invalid, _ = self.call_cli(
            "task", "repository", "edit", task_id,
            "--repo", self.primary,
            "--branch", "invalid branch",
            "--branch-from", "branch-source",
            "--merge-target", "branch-source",
            expected_status=2,
        )
        self.assert_failure(invalid, "invalid_argument")
        invalid_target, _ = self.call_cli(
            "task", "repository", "edit", task_id,
            "--repo", self.primary,
            "--branch", "settings-edited",
            "--branch-from", "branch-source",
            "--merge-target", "missing-local-branch",
            expected_status=2,
        )
        self.assert_failure(invalid_target, "invalid_argument")
        fresh, _ = self.call_cli("task", "get", task_id)
        unchanged = self.assert_success(fresh)["repositoryWorktrees"][0]
        self.assertEqual(unchanged["branch"], edited["branch"])
        self.assertEqual(unchanged["branchFrom"], edited["branchFrom"])
        self.assertEqual(unchanged["mergeTarget"], edited["mergeTarget"])
        self.assertNotEqual(initial["branch"], unchanged["branch"])

        self.complete_fixture_turn(task_id)
        started, _ = self.call_cli("task", "get", task_id)
        started_record = self.assert_success(started)["repositoryWorktrees"][0]
        self.assertFalse(started_record["isPending"])
        self.assertEqual(started_record["branch"], "settings-edited")
        self.assertTrue(Path(started_record["worktreePath"]).is_dir())
        locked, _ = self.call_cli(
            "task", "repository", "edit", task_id,
            "--repo", self.primary,
            "--branch", "changed-after-start",
            "--branch-from", "branch-source",
            "--merge-target", "branch-source",
            expected_status=1,
        )
        self.assert_failure(locked, "invalid_transition")
        final, _ = self.call_cli("task", "get", task_id)
        final_record = self.assert_success(final)["repositoryWorktrees"][0]
        self.assertEqual(final_record["branch"], "settings-edited")
        self.assertEqual(final_record["branchFrom"], "branch-source")
        self.assertEqual(final_record["mergeTarget"], "branch-source")

    # case-contract: test_task_repository_edit_rejects_stale_validation_after_removal | If a pending repository is removed while its settings are being validated, the stale edit is rejected and the newer repository removal and context root remain saved.
    def test_task_repository_edit_rejects_stale_validation_after_removal(self):
        task = self.create_repo_task("Concurrent repository edit", [self.primary], roots=[str(self.custom)])
        task_id = task["id"]
        initial = task["repositoryWorktrees"][0]
        command = [
            "task", "repository", "edit", task_id,
            "--repo", self.primary,
            "--branch", "stale-edit",
            "--branch-from", initial["branchFrom"],
            "--merge-target", initial["mergeTarget"],
        ]
        barrier = GitConfigReadBarrier(self.primary)
        stale_process = None
        continue_stale_process = False
        try:
            stale_process = self.start_cli(*command)
            barrier.wait_for_reader()
            removed, _ = self.call_cli("task", "repository", "remove", task_id, "--repo", self.primary)
            removed_record = self.assert_success(removed)
            self.assertEqual(removed_record["repositoryWorktrees"], [])
            self.assertEqual(removed_record["workspaceRoots"], [str(self.custom)])
            self.assertEqual(removed_record["contextFolders"], [str(self.custom)])
            continue_stale_process = True
        finally:
            barrier.release()
            if not continue_stale_process and stale_process is not None and stale_process.poll() is None:
                stale_process.terminate()
                try:
                    stale_process.communicate(timeout=20)
                except subprocess.TimeoutExpired:
                    stale_process.kill()
                    stale_process.communicate()
        self.assertIsNotNone(stale_process)
        stale, _ = self.finish_cli(stale_process, command, expected_status=1)
        self.assert_failure(stale, "invalid_transition")
        fresh, _ = self.call_cli("task", "get", task_id)
        fresh_record = self.assert_success(fresh)
        self.assertEqual(fresh_record["repositoryWorktrees"], [])
        self.assertEqual(fresh_record["workspaceRoots"], [str(self.custom)])
        self.assertEqual(fresh_record["contextFolders"], [str(self.custom)])

    # case-contract: test_task_repository_removal_preserves_state_on_dirty_worktree | Removing the only pending repository leaves the task with no workspace and preserves the source repository; removing a pending repository preserves other context folders; removing a clean managed worktree through the GUI waits for an active turn, while the task repository API removes it from context immediately and defers clean worktree deletion until the turn releases; a bridge service restart preserves the cleanup intent and a fresh request completes removal; if the active turn writes files before release, deferred cleanup preserves that worktree and its changes; a dirty worktree rejects removal and preserves its task record and files.
    def test_task_repository_removal_preserves_state_on_dirty_worktree(self):
        sole = self.create_repo_task("Sole repository removal", [self.primary])
        sole_removed, _ = self.call_cli("task", "repository", "remove", sole["id"], "--repo", self.primary)
        sole_result = self.assert_success(sole_removed)
        self.assertEqual(sole_result["repositoryWorktrees"], [])
        self.assertEqual(sole_result["workspaceRoots"], [])
        self.assertEqual(sole_result["contextFolders"], [])
        self.assertTrue(self.primary.is_dir(), "Removing a pending repository must preserve its source repository.")

        pending = self.create_repo_task("Pending repository removal", [self.primary], roots=[self.custom])
        pending_id = pending["id"]
        removed_pending, _ = self.call_cli("task", "repository", "remove", pending_id, "--repo", self.primary)
        pending_result = self.assert_success(removed_pending)
        self.assertEqual(pending_result["repositoryWorktrees"], [])
        self.assertEqual(pending_result["contextFolders"], [str(self.custom)])
        self.assertEqual(pending_result["workspaceRoots"], [str(self.custom)])
        self.assertTrue(self.primary.is_dir(), "Removing a pending repository must preserve its source repository.")

        clean_active = self.create_repo_task("Clean active repository removal", [self.alternate], roots=[self.custom])
        clean_active_id = clean_active["id"]
        self.complete_fixture_turn(clean_active_id)
        clean_active, _ = self.call_cli("task", "get", clean_active_id)
        clean_record = self.assert_success(clean_active)["repositoryWorktrees"][0]
        clean_worktree = Path(clean_record["worktreePath"])
        clean_lock = ConversationTurnLockBarrier(self.data_directory, clean_active_id)
        clean_removed, _ = self.call_cli("task", "repository", "remove", clean_active_id, "--repo", self.alternate)
        self.assertEqual(self.assert_success(clean_removed)["repositoryWorktrees"], [])
        self.assertTrue(clean_worktree.exists())
        scheduled = next(
            event for event in self.diagnostic_events()
            if event.get("event") == "workspace.repository.deferred_removal_scheduled"
            and event.get("taskID") == clean_active_id
        )
        bridge_pid = int(scheduled["processID"])
        try:
            os.kill(bridge_pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        service_exit_deadline = time.monotonic() + 5
        while time.monotonic() < service_exit_deadline:
            try:
                os.kill(bridge_pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.02)
        else:
            self.fail("The isolated bridge service should exit before testing durable cleanup recovery.")
        clean_lock.release()
        self.call_cli("task", "get", clean_active_id)
        clean_deadline = time.monotonic() + 30
        while clean_worktree.exists() and time.monotonic() < clean_deadline:
            time.sleep(0.02)
        self.assertFalse(clean_worktree.exists(), "Deferred cleanup should remove an unchanged managed worktree after the turn releases.")

        active = self.create_repo_task("Started repository removal", [self.secondary], roots=[self.custom])
        active_id = active["id"]
        self.complete_fixture_turn(active_id)
        active, _ = self.call_cli("task", "get", active_id)
        record = self.assert_success(active)["repositoryWorktrees"][0]
        self.assertTrue(record["createdByStationAI"], "Started task worktrees should be eligible for cleanup after the turn reservation releases.")
        worktree = Path(record["worktreePath"])
        dirty_file = worktree / "repository-removal-dirty.txt"
        dirty_file.write_text("keep this worktree intact\n", encoding="utf-8")

        rejected, _ = self.call_cli(
            "task", "repository", "remove", active_id, "--repo", self.secondary,
            expected_status=1,
        )
        self.assert_failure(rejected, "operation_failed")
        retained, _ = self.call_cli("task", "get", active_id)
        retained_result = self.assert_success(retained)
        self.assertEqual(len(retained_result["repositoryWorktrees"]), 1)
        self.assertEqual(retained_result["repositoryWorktrees"][0]["worktreePath"], str(worktree))
        self.assertEqual(retained_result["workspaceRoots"], [str(worktree), str(self.custom)])
        self.assertTrue(dirty_file.is_file())

        dirty_file.unlink()
        lock_barrier = ConversationTurnLockBarrier(self.data_directory, active_id)
        removed_active, _ = self.call_cli("task", "repository", "remove", active_id, "--repo", self.secondary)
        active_result = self.assert_success(removed_active)
        self.assertEqual(active_result["repositoryWorktrees"], [])
        self.assertEqual(active_result["contextFolders"], [str(self.custom)])
        self.assertEqual(active_result["workspaceRoots"], [str(self.custom)])
        self.assertTrue(worktree.exists(), "The active turn's cwd must remain until the reservation is released.")
        still_attached, _ = self.call_cli("task", "get", active_id)
        self.assertEqual(self.assert_success(still_attached)["repositoryWorktrees"], [])
        in_flight_file = worktree / "written-during-removal.txt"
        in_flight_file.write_text("preserve edits made before the turn ended\n", encoding="utf-8")
        lock_barrier.release()
        self.call_cli("task", "get", active_id)
        cleanup_deadline = time.monotonic() + 30
        while not any(event.get("event") == "workspace.repository.deferred_removal_kept_dirty" for event in self.diagnostic_events()) and time.monotonic() < cleanup_deadline:
            time.sleep(0.02)
        self.assertTrue(any(event.get("event") == "workspace.repository.deferred_removal_kept_dirty" for event in self.diagnostic_events()), "Deferred cleanup should report that active-turn edits were preserved.")
        self.assertTrue(worktree.exists(), "Deferred cleanup must preserve a worktree dirtied by the active turn.")
        self.assertTrue(in_flight_file.is_file(), "Deferred cleanup must preserve files written by the active turn.")
    # case-contract: test_task_delete_removes_task_and_later_lookup_is_not_found | The task context menu offers deletion. Pending repository tasks delete without confirmation and preserve the source repository; confirmed deletion waits for an active conversation turn; clean started worktrees can be deleted; dirty started worktrees require confirmation, and canceling preserves the task and worktree. CLI delete-check derives and reports the confirmation requirement from saved task and worktree state without resuming the Codex thread; confirmed deletion removes the managed worktree.
    def test_task_delete_removes_task_and_later_lookup_is_not_found(self):
        pending = self.create_repo_task("Pending delete", [self.primary])
        pending_id = pending["id"]
        pending_path = pending["repositoryWorktrees"][0]["worktreePath"]
        self.assertTrue(pending["repositoryWorktrees"][0]["isPending"])
        self.assertEqual(pending_path, str(self.primary))
        response, _ = self.call_cli("task", "delete-check", pending_id)
        self.assertFalse(self.assert_success(response)["requiresConfirmation"])
        lock_barrier = ConversationTurnLockBarrier(self.data_directory, pending_id)
        delete_command = ["task", "delete", pending_id]
        delete_process = None
        continue_delete_process = False
        try:
            delete_process = self.start_cli(*delete_command)
            time.sleep(0.25)
            self.assertIsNone(delete_process.poll(), "Task deletion should wait for the active conversation-turn reservation.")
            retained, _ = self.call_cli("task", "get", pending_id)
            self.assertEqual(self.assert_success(retained)["id"], pending_id)
            continue_delete_process = True
        finally:
            lock_barrier.release()
            if not continue_delete_process and delete_process is not None and delete_process.poll() is None:
                delete_process.terminate()
                try:
                    delete_process.communicate(timeout=20)
                except subprocess.TimeoutExpired:
                    delete_process.kill()
                    delete_process.communicate()
        self.assertIsNotNone(delete_process)
        response, _ = self.finish_cli(delete_process, delete_command)
        self.assertTrue(self.assert_success(response)["deleted"])
        diagnostic_lines = [
            json.loads(line)
            for line in (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8").splitlines()
        ]
        delete_event = next(
            event for event in diagnostic_lines
            if event.get("event") == "task.delete.succeeded" and event.get("taskID") == pending_id
        )
        self.assertEqual(delete_event["taskStatus"], "Backlog")
        self.assertIn("processID", delete_event)
        self.assertIn("storePath", delete_event)
        self.assertTrue(Path(pending_path).is_dir(), "Deleting a pending task must preserve the source repository.")
        response, _ = self.call_cli("task", "get", pending_id, expected_status=3)
        self.assert_failure(response, "not_found")

        clean = self.create_repo_task(f"Clean delete {uuid.uuid4().hex[:8]}", [self.primary], materialize=True)
        clean_id = clean["id"]
        self.complete_fixture_turn(clean_id)
        clean, _ = self.call_cli("task", "get", clean_id)
        clean = self.assert_success(clean)
        clean_worktree = Path(clean["repositoryWorktrees"][0]["worktreePath"])
        self.assertEqual(self.run_git(clean_worktree, "status", "--porcelain").strip(), "")
        clean_thread_id = clean["codexThreadID"]
        resume_events_before = sum(
            event.get("event") == "codex.thread.resume_started" and event.get("threadID") == clean_thread_id
            for event in (
                json.loads(line)
                for line in (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8").splitlines()
            )
        )
        response, _ = self.call_cli("task", "delete-check", clean_id)
        self.assertTrue(self.assert_success(response)["requiresConfirmation"])
        resume_events_after = sum(
            event.get("event") == "codex.thread.resume_started" and event.get("threadID") == clean_thread_id
            for event in (
                json.loads(line)
                for line in (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8").splitlines()
            )
        )
        self.assertEqual(resume_events_after, resume_events_before, "Delete-check must not resume a conversation thread already owned by the app.")
        response, _ = self.call_cli("task", "delete", clean_id)
        self.assertTrue(self.assert_success(response)["deleted"])
        self.assertFalse(clean_worktree.exists(), "Deleting a clean managed worktree must remove it.")

        dirty = self.create_repo_task(f"Delete dirty {uuid.uuid4().hex[:8]}", [self.secondary], materialize=True)
        dirty_id = dirty["id"]
        dirty_worktree = Path(dirty["repositoryWorktrees"][0]["worktreePath"])
        (dirty_worktree / "unsaved-work.txt").write_text("work that needs confirmation\n", encoding="utf-8")
        response, _ = self.call_cli("task", "delete-check", dirty_id)
        self.assertTrue(self.assert_success(response)["requiresConfirmation"])
        response, _ = self.call_cli("task", "delete", dirty_id)
        self.assertTrue(self.assert_success(response)["deleted"])
        self.assertFalse(dirty_worktree.exists(), "Confirmed deletion must remove the dirty managed worktree.")
        response, _ = self.call_cli("task", "get", dirty_id, expected_status=3)
        self.assert_failure(response, "not_found")

        response, _ = self.call_cli("board", "list")
        self.assertEqual(self.assert_success(response)["tasks"], [])

    # case-contract: test_task_delete_reports_real_worktree_failure_and_allows_retry | A real worktree-removal failure records the task title and task, thread, process, phase, and underlying error details, including bounded NSError user-info keys and values, without recording conversation text; the failed task and worktree remain available and deletion succeeds after the repository is restored.
    def test_task_delete_reports_real_worktree_failure_and_allows_retry(self):
        broken_repository = self.data_directory / "delete-failure-repository"
        broken_repository.mkdir()
        self.run_git(broken_repository, "init", "--initial-branch=main")
        self.run_git(broken_repository, "config", "user.name", "StationAI Test")
        self.run_git(broken_repository, "config", "user.email", "stationai-test@example.invalid")
        (broken_repository / "README.md").write_text("owned diagnostic fixture\n", encoding="utf-8")
        self.run_git(broken_repository, "add", "README.md")
        self.run_git(broken_repository, "commit", "-m", "Baseline")
        failure_title = f"PRIVATE_DELETE_TITLE_{uuid.uuid4().hex[:8]}"
        failure_prompt = f"PRIVATE_CONVERSATION_TEXT_{uuid.uuid4().hex[:8]}"
        broken = self.create_repo_task(failure_title, [broken_repository])
        broken_id = broken["id"]
        self.complete_fixture_turn(broken_id, message=failure_prompt)
        broken, _ = self.call_cli("task", "get", broken_id)
        broken = self.assert_success(broken)
        broken_worktree = Path(broken["repositoryWorktrees"][0]["worktreePath"])
        moved_repository = self.data_directory / "delete-failure-repository-restored-after-error"
        broken_repository.rename(moved_repository)
        response, _ = self.call_cli("task", "delete", broken_id, expected_status=1)
        self.assert_failure(response, "operation_failed")
        diagnostic_lines = [
            json.loads(line)
            for line in (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8").splitlines()
        ]
        failure_event = next(
            event for event in diagnostic_lines
            if event.get("event") == "task.delete.failed" and event.get("taskID") == broken_id
        )
        self.assertEqual(failure_event["phase"], "worktree-removal")
        self.assertTrue(failure_event.get("threadID"))
        self.assertIn("processID", failure_event)
        self.assertIn("error0Domain", failure_event)
        self.assertIn("error0Code", failure_event)
        self.assertIn("error0UserInfoKeys", failure_event)
        self.assertIn("error0UserInfoKeyCount", failure_event)
        self.assertIn("error0UserInfo", failure_event)
        serialized_diagnostics = json.dumps(diagnostic_lines)
        self.assertIn(failure_title, serialized_diagnostics)
        self.assertNotIn(failure_prompt, serialized_diagnostics)
        self.assertTrue(broken_worktree.exists(), "A failed worktree removal must leave its worktree available for recovery.")
        preserved, _ = self.call_cli("task", "get", broken_id)
        self.assertEqual(self.assert_success(preserved)["id"], broken_id)
        moved_repository.rename(broken_repository)
        response, _ = self.call_cli("task", "delete", broken_id)
        self.assertTrue(self.assert_success(response)["deleted"])
        self.assertFalse(broken_worktree.exists())

    # case-contract: test_default_parent_settings_read_write_clear_and_validation | The default parent can be read, changed, cleared, and an unavailable path is rejected; a fresh CLI read and repository discovery use the persisted parent. Dark and Light appearance choices persist, the removed PR conflict preference is absent from CLI/XPC and Settings, and appearance changes update the open Settings picker. Clearing the default parent does not change roots already saved on a task.
    def test_default_parent_settings_read_write_clear_and_validation(self):
        self.assert_success(self.call_cli("settings", "clear-parent")[0])
        response, _ = self.call_cli("settings", "get")
        self.assertIsNone(self.assert_success(response)["defaultParentFolder"])
        self.assertEqual(self.assert_success(response)["appearance"], "dark")
        self.assertNotIn("pullRequestConflictAction", self.assert_success(response))
        self.call_cli("settings", "set-pr-conflict-action", "ask", expected_status=2)
        response, _ = self.call_cli("settings", "set-appearance", "light")
        self.assertEqual(self.assert_success(response)["appearance"], "light")
        response, _ = self.call_cli("settings", "set-appearance", "dark")
        self.assertEqual(self.assert_success(response)["appearance"], "dark")
        appearance_writes = [
            event for event in self.diagnostic_events()
            if event.get("event") == "settings.write.succeeded" and event.get("setting") == "appearance"
        ]
        self.assertTrue(any(event.get("value") == "light" for event in appearance_writes))
        self.assertTrue(any(event.get("value") == "dark" for event in appearance_writes))

        response, _ = self.call_cli("settings", "set-parent", self.fixture / "suggested-parent")
        self.assertEqual(self.assert_success(response)["defaultParentFolder"], str(self.fixture / "suggested-parent"))
        response, _ = self.call_cli("settings", "get")
        persisted_parent = self.assert_success(response)["defaultParentFolder"]
        self.assertEqual(persisted_parent, str(self.fixture / "suggested-parent"))
        response, _ = self.call_cli("workspace", "suggest", "--parent", persisted_parent)
        self.assertEqual(
            self.assert_success(response)["repositories"],
            sorted([str(self.primary), str(self.secondary), str(self.alternate), str(self.changes)]),
            "A fresh bridge request should discover repositories under the persisted default parent.",
        )
        alternate_parent = self.alternate.parent
        response, _ = self.call_cli("settings", "set-parent", alternate_parent)
        self.assertEqual(self.assert_success(response)["defaultParentFolder"], str(alternate_parent))
        response, _ = self.call_cli("settings", "get")
        persisted_parent = self.assert_success(response)["defaultParentFolder"]
        self.assertEqual(persisted_parent, str(alternate_parent))
        response, _ = self.call_cli("workspace", "suggest", "--parent", persisted_parent)
        self.assertEqual(self.assert_success(response)["repositories"], [str(self.alternate)])
        response, _ = self.call_cli("settings", "set-parent", self.fixture / "absent", expected_status=2)
        self.assert_failure(response, "invalid_argument")
        response, _ = self.call_cli("settings", "get")
        self.assertEqual(self.assert_success(response)["defaultParentFolder"], str(alternate_parent))
        response, _ = self.call_cli("settings", "clear-parent")
        self.assertIsNone(self.assert_success(response)["defaultParentFolder"])

    # case-contract: test_repository_suggestions_skip_nested_repositories_and_symlinks | The configured-root workspace repos list API returns top-level Git repositories while excluding nested repositories and symlink targets. The conversation picker shows those suggestions, filters by repository name or parent path, and reports no matches for non-repository folders.
    def test_repository_suggestions_skip_nested_repositories_and_symlinks(self):
        root = self.fixture / "suggested-parent"
        _, _ = self.call_cli("settings", "set-parent", root)
        response, _ = self.call_cli("workspace", "repos", "list")
        repository_list = self.assert_success(response)
        self.assertEqual(repository_list["root"], str(root))
        self.assertEqual(repository_list["repositories"], sorted([str(self.primary), str(self.secondary), str(self.alternate), str(self.changes)]))
        self.assertNotIn(str(self.nested), repository_list["repositories"])
        self.assertNotIn(str(self.external), repository_list["repositories"])

        response, _ = self.call_cli("workspace", "suggest", "--parent", self.fixture / "suggested-parent")
        repositories = self.assert_success(response)["repositories"]
        self.assertEqual(repositories, sorted([str(self.primary), str(self.secondary), str(self.alternate), str(self.changes)]))
        self.assertNotIn(str(self.nested), repositories)
        self.assertNotIn(str(self.external), repositories)

    # case-contract: test_new_task_remembers_last_selected_repositories | The CLI reads and writes ordered last-selected repositories across fresh XPC connections; repository batches prepare managed worktrees in order, use task-title-derived branches and main/main merge settings, and set the active task roots to those worktrees. The selected source repository list remains saved and applies to subsequent tasks. Invalid repository paths are rejected without changing the saved preference. In the UI, a new conversation automatically attaches saved repositories in order while the picker stays closed and the composer remains focused. Opening the picker and choosing another suggestion adds it to the ordered context and saved selection for subsequent conversations.
    def test_new_task_remembers_last_selected_repositories(self):
        response, _ = self.call_cli("settings", "set-last-repositories", "--repo", self.secondary, "--repo", self.primary)
        self.assertEqual(self.assert_success(response)["lastSelectedRepositories"], [str(self.secondary), str(self.primary)])
        response, _ = self.call_cli("settings", "get")
        self.assertEqual(self.assert_success(response)["lastSelectedRepositories"], [str(self.secondary), str(self.primary)])

        created, _ = self.call_cli("task", "create", "--title", "Apply remembered repositories")
        first_task_id = self.assert_success(created)["id"]
        restored, _ = self.call_cli(
            "task", "repository", "add-batch", first_task_id,
            "--repo", self.secondary,
            "--repo", self.primary,
        )
        restored_task = self.assert_success(restored)
        expected_repositories = [str(self.secondary), str(self.primary)]
        first_repositories = restored_task["repositoryWorktrees"]
        self.assertEqual([item["repositoryPath"] for item in first_repositories], expected_repositories)
        self.assertEqual(
            restored_task["workspaceRoots"],
            [item["worktreePath"] for item in first_repositories],
            "The AI-facing repository API should return active managed worktrees as task roots.",
        )
        self.assertEqual([item["branch"] for item in first_repositories], ["apply-remembered-repositories"] * 2)
        self.assertTrue(all(not item["isPending"] for item in first_repositories))
        self.assertEqual([item["branchFrom"] for item in first_repositories], ["main", "main"])
        self.assertEqual([item["mergeTarget"] for item in first_repositories], ["main", "main"])

        response, _ = self.call_cli("settings", "set-last-repositories", "--repo", self.alternate)
        self.assertEqual(self.assert_success(response)["lastSelectedRepositories"], [str(self.alternate)])
        response, _ = self.call_cli("settings", "get")
        self.assertEqual(self.assert_success(response)["lastSelectedRepositories"], [str(self.alternate)])

        created, _ = self.call_cli("task", "create", "--title", "Apply updated remembered repository")
        second_task_id = self.assert_success(created)["id"]
        restored, _ = self.call_cli(
            "task", "repository", "add-batch", second_task_id,
            "--repo", self.alternate,
        )
        restored_task = self.assert_success(restored)
        second_repositories = restored_task["repositoryWorktrees"]
        self.assertEqual([item["repositoryPath"] for item in second_repositories], [str(self.alternate)])
        self.assertEqual(restored_task["workspaceRoots"], [second_repositories[0]["worktreePath"]])
        self.assertEqual([item["branch"] for item in second_repositories], ["apply-updated-remembered-repository"])
        self.assertEqual([item["branchFrom"] for item in second_repositories], ["main"])
        self.assertEqual([item["mergeTarget"] for item in second_repositories], ["main"])
        response, _ = self.call_cli("settings", "get")
        self.assertEqual(self.assert_success(response)["lastSelectedRepositories"], [str(self.alternate)])

        response, _ = self.call_cli("settings", "set-last-repositories", "--repo", self.fixture / "absent", expected_status=2)
        self.assert_failure(response, "invalid_argument")
        response, _ = self.call_cli("settings", "get")
        self.assertEqual(self.assert_success(response)["lastSelectedRepositories"], [str(self.alternate)])

    # case-contract: test_new_task_repository_restore_is_atomic_on_invalid_default | Applying an ordered repository batch with a valid repository followed by an empty Git repository fails without mutation: the CLI reports invalid_argument and fresh reads show no repository attachments or workspace roots; New Task automatically applies saved repositories; an invalid batch shows an error, attaches neither repository, keeps roots empty, preserves the saved order, and leaves the picker closed by default.
    def test_new_task_repository_restore_is_atomic_on_invalid_default(self):
        created, _ = self.call_cli("task", "create", "--title", "Atomic repository restore")
        task_id = self.assert_success(created)["id"]
        initial, _ = self.call_cli("task", "get", task_id)
        initial_task = self.assert_success(initial)
        self.assertEqual(initial_task["workspaceRoots"], [])
        self.assertEqual(initial_task["repositoryWorktrees"], [])
        saved_defaults, _ = self.call_cli(
            "settings", "set-last-repositories",
            "--repo", self.primary,
            "--repo", self.empty_git_repository,
        )
        self.assertEqual(
            self.assert_success(saved_defaults)["lastSelectedRepositories"],
            [str(self.primary), str(self.empty_git_repository)],
        )

        response, _ = self.call_cli(
            "task", "repository", "add-batch", task_id,
            "--repo", self.primary,
            "--repo", self.empty_git_repository,
            expected_status=2,
        )
        self.assert_failure(response, "invalid_argument")

        fresh, _ = self.call_cli("task", "get", task_id)
        fresh_task = self.assert_success(fresh)
        self.assertEqual(fresh_task["workspaceRoots"], [], "A failed batch must not persist any roots.")
        self.assertEqual(fresh_task["repositoryWorktrees"], [], "A failed batch must not persist a partial repository attachment.")
        roots, _ = self.call_cli("task", "roots", "get", task_id)
        self.assertEqual(self.assert_success(roots)["roots"], [])
        settings, _ = self.call_cli("settings", "get")
        self.assertEqual(
            self.assert_success(settings)["lastSelectedRepositories"],
            [str(self.primary), str(self.empty_git_repository)],
            "A failed restore must preserve the ordered repository defaults.",
        )

    # case-contract: test_new_task_has_empty_conversation_history | The CLI creates an Untitled task with no roots, logs task.create.succeeded for its ID, verifies empty history, and deletes it cleanly. New Task logs start and completion events with the same attempt ID and created task ID, then opens one empty conversation with the repository picker closed, the composer focused, and no create sheet. With no selected repositories, the empty conversation prominently says no repository is selected; typing starts immediately and, with a configured repository root, the UI enables standalone Send. Adding folder-only context leaves history empty, and backing out deletes the pending task without confirmation.
    def test_new_task_has_empty_conversation_history(self):
        response, _ = self.call_cli("task", "create", "--title", "Untitled task")
        task_id = self.assert_success(response)["id"]
        task_create = next((event for event in self.diagnostic_events()
                            if event.get("event") == "task.create.succeeded" and event.get("taskID") == task_id), None)
        self.assertIsNotNone(task_create, "Creating a task through CLI/XPC should persist its success diagnostic.")
        response, _ = self.call_cli("task", "get", task_id)
        task = self.assert_success(response)
        self.assertEqual(task["title"], "Untitled task")
        self.assertEqual(task["contextFolders"], [])
        self.assertEqual(task["workspaceRoots"], [])
        self.assertEqual(task["repositoryWorktrees"], [])
        response, _ = self.call_cli("conversation", "history", task_id)
        history = self.assert_success(response)
        self.assertEqual(history["activities"], [])
        self.assertEqual(history["messages"], [])
        self.assertIsNone(history.get("diff"))
        response, _ = self.call_cli("task", "delete", task_id)
        self.assertTrue(self.assert_success(response)["deleted"])
        response, _ = self.call_cli("task", "get", task_id, expected_status=3)
        self.assert_failure(response, "not_found")

    # case-contract: test_new_task_failure_diagnostics | A real directory at the task-store write-lock path makes CLI task creation fail with operation_failed and leaves no task persisted; the paired New Task button shows the save error and writes correlated start and failure diagnostics with the same attempt ID, error domain, and code.
    def test_new_task_failure_diagnostics(self):
        write_lock = self.data_directory / "store-write.lock"
        write_lock.mkdir()
        try:
            response, _ = self.call_cli("task", "create", "--title", "Must not persist", expected_status=1)
            self.assert_failure(response, "operation_failed")
            tasks, _ = self.call_cli("board", "list")
            self.assertEqual(self.assert_success(tasks)["tasks"], [])
            events = self.diagnostic_events()
            self.assertTrue(any(
                event.get("event") == "bridge.request.failed"
                and "Couldn't open the task-store-write lock" in event.get("errorDescription", "")
                for event in events
            ), "The real lock-path failure should be recorded by the bridge.")
        finally:
            write_lock.rmdir()

    # case-contract: test_task_prompt_draft_persists_after_back | Creating a repository task leaves its selected branch pending while the composer automatically saves an unsent prompt as it is typed; clearing the composer clears the stored draft, backing out needs no Save button, and reopening restores the draft without creating a branch or worktree. Blank drafts cannot be stored, and invalid status changes are rejected without mutation. If the title is renamed while delayed title generation is in flight, the late result is skipped, the renamed title persists, and diagnostics record the skip reason without prompt or title text.
    def test_task_prompt_draft_persists_after_back(self):
        suggestions, _ = self.call_cli("workspace", "suggest", "--parent", self.fixture / "suggested-parent")
        self.assertIn(str(self.primary), self.assert_success(suggestions)["repositories"])
        task = self.create_repo_task("Draft persistence", [self.primary], branches={str(self.primary): "draft-persistence"})
        self.assertEqual(task["repositoryWorktrees"][0]["branch"], "draft-persistence")
        self.assertTrue(task["repositoryWorktrees"][0]["isPending"])
        self.assertEqual(task["repositoryWorktrees"][0]["worktreePath"], str(self.primary))
        task_id = task["id"]
        prompt = "Please update the README and explain the change."
        response, _ = self.call_cli("task", "prompt", task_id, "--text", prompt, "--status", "Backlog")
        saved = self.assert_success(response)
        self.assertEqual(saved["savedPrompt"], prompt)
        self.assertEqual(saved["status"], "Backlog")
        invalid, _ = self.call_cli("task", "prompt", task_id, "--text", "Changed", "--status", "Not a status", expected_status=2)
        self.assert_failure(invalid, "invalid_argument")
        invalid_transition, _ = self.call_cli("task", "prompt", task_id, "--text", "Changed", "--status", "Done", expected_status=2)
        self.assert_failure(invalid_transition, "invalid_argument")
        renamed, _ = self.call_cli("task", "rename", task_id, "--title", "Stable draft title")
        self.assertEqual(self.assert_success(renamed)["title"], "Stable draft title")
        reopened, _ = self.call_cli("task", "get", task_id)
        reopened_task = self.assert_success(reopened)
        self.assertEqual(reopened_task["savedPrompt"], prompt)
        self.assertEqual(reopened_task["status"], "Backlog")
        cleared, _ = self.call_cli("task", "prompt", task_id, "--text", "")
        self.assertIsNone(self.assert_success(cleared).get("savedPrompt"))
        restored, _ = self.call_cli("task", "prompt", task_id, "--text", prompt)
        self.assertEqual(self.assert_success(restored)["savedPrompt"], prompt)
        self.assertEqual(reopened_task["title"], "Stable draft title")

        delayed_task = self.create_task(title="Untitled task", roots=[self.primary])
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-title-success-wait"
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        fixture_owner = self.data_directory / ".stationai-codex-fixture-owner"
        fixture_owner.write_text("StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8")
        ready = Path(str(executable) + ".resolve-ready")
        resume = Path(str(executable) + ".resolve-continue")
        environment = os.environ.copy()
        environment.update({
            "STATIONAI_DATA_DIRECTORY": str(self.data_directory),
            "STATIONAI_E2E_WORKTREE_DIRECTORY": str(self.worktree_directory),
            "STATIONAI_E2E_DEFAULTS_SUITE": self.defaults_suite,
            "STATIONAI_BRIDGE_SERVICE_NAME": arguments.service_name,
            "STATIONAI_E2E_CODEX_EXECUTABLE": str(executable),
        })
        process = subprocess.Popen(
            [
                str(self.cli), "conversation", "send", delayed_task["id"],
                "--message", "Explain the delayed title result.",
                "--answer", "color=Blue", "--answer", "token=fixture-secret",
            ],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment,
        )
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline and not ready.exists():
            time.sleep(0.02)
        if not ready.exists():
            resume.write_text("Release the title-generation fixture.\n", encoding="utf-8")
            output, error_output = process.communicate(timeout=30)
            self.fail(f"Title generation did not reach its delayed response: {output}\n{error_output}")
        renamed_title = "Stable title chosen while generation is pending"
        renamed, _ = self.call_cli("task", "rename", delayed_task["id"], "--title", renamed_title)
        self.assertEqual(self.assert_success(renamed)["title"], renamed_title)
        resume.write_text("Release the title-generation fixture.\n", encoding="utf-8")
        output, error_output = process.communicate(timeout=30)
        self.assertEqual(process.returncode, 0, f"CLI send failed: {output}\n{error_output}")
        delayed_result = json.loads([line for line in output.splitlines() if line.strip()][-1])
        self.assertTrue(delayed_result.get("ok"), delayed_result.get("error"))
        final_task = self.assert_success(self.call_cli("task", "get", delayed_task["id"])[0])
        self.assertEqual(final_task["title"], renamed_title)
        title_events = [
            json.loads(line)
            for line in (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8").splitlines()
            if json.loads(line).get("taskID") == delayed_task["id"]
            and json.loads(line).get("event", "").startswith("task.title_")
        ]
        skipped = next(event for event in title_events if event["event"] == "task.title_apply.skipped")
        self.assertEqual(skipped["reason"], "title_changed")
        self.assertEqual(skipped["currentTitleState"], "custom")
        self.assertEqual(skipped["titleSource"], "codex")
        serialized_title_events = json.dumps(title_events)
        self.assertNotIn("Explain the delayed title result.", serialized_title_events)
        self.assertNotIn("Generated fixture title", serialized_title_events)
    # case-contract: test_conversation_composer_rejects_blank_and_supports_live_turn_controls | Shift+Enter inserts a newline at the caret without sending and Return submits; multiline drafts persist, expand to the editor limit, remain scrollable and editable across reopening, and submitted prompts persist in history. As content is typed in short increments through successive wrapped lines after a line break, the newest insertion remains inside the visible composer viewport while its internal document follows the caret without scrolling backward. Blank drafts cannot be sent or stored. Sending requires a configured repository root, while a task with no selected repository can still be sent as standalone. If a submitted prompt has no Codex thread or active send reservation after restart, the task returns to Waiting Response, clears its pending marker, preserves the draft, and returns it to the composer. Sending to an Untitled auto-branch task derives its branch from the generated title or prompt fallback before preparing the worktree and starting the conversation; if it is concurrently renamed while title generation is pending, the custom title determines the auto branch. A standalone Untitled task starts and persists its provider thread while background title generation is still pending. Pause remains disabled until the turn is interruptible. Diagnostics correlate title generation with the task and thread while excluding prompt and title text. Queued follow-ups persist with task and thread identity, dispatch after a completed turn, and remain visible for explicit retry after interruption. During an active turn, Return queues a follow-up and queued rows offer Steer. The obsolete footer Queue and Steer buttons are absent.
    def test_conversation_composer_rejects_blank_and_supports_live_turn_controls(self):
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        task_id = self.create_task(title="Blank conversation send", roots=[self.primary])["id"]
        response, _ = self.call_cli(
            "task", "prompt", task_id, "--text", "Invalid submitted prompt", "--submitted", "true", expected_status=2
        )
        self.assert_failure(response, "invalid_argument")
        response, _ = self.call_cli(
            "task", "prompt", task_id, "--text", " ", "--status", "In Progress", "--submitted", "true", expected_status=2
        )
        self.assert_failure(response, "invalid_argument")
        response, _ = self.call_cli("conversation", "send", task_id, "--message", " ", expected_status=2)
        self.assert_failure(response, "invalid_argument")
        response, _ = self.call_cli("conversation", "history", task_id)
        history = self.assert_success(response)
        self.assertEqual(history["activities"], [])
        self.assertEqual(history["messages"], [])
        # Exercise a saved, unsent draft larger than the prompt that exposed the UI stall.
        long_draft = "# Inspect subagents\n" + "Review child activity and preserve the complete result.\n" * 160
        saved, _ = self.call_cli("task", "prompt", task_id, "--text", long_draft)
        self.assertEqual(self.assert_success(saved)["savedPrompt"], long_draft)
        reopened, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(reopened)["savedPrompt"], long_draft)
        edited_draft = long_draft + "Edited after reopening."
        edited, _ = self.call_cli("task", "prompt", task_id, "--text", edited_draft)
        self.assertEqual(self.assert_success(edited)["savedPrompt"], edited_draft)
        reopened, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(reopened)["savedPrompt"], edited_draft)
        reopened_again, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(reopened_again)["savedPrompt"], edited_draft)
        self.assertEqual(self.assert_success(reopened_again)["status"], "Backlog")
        history, _ = self.call_cli("conversation", "history", task_id)
        self.assertEqual(self.assert_success(history)["messages"], [])
        prompt = "Work on the persisted prompt while I reopen this task."
        saved, _ = self.call_cli("task", "prompt", task_id, "--text", prompt)
        self.assertEqual(self.assert_success(saved)["savedPrompt"], prompt)
        multiline_prompt = "\n".join(f"Draft line {index}" for index in range(1, 16))
        saved, _ = self.call_cli("task", "prompt", task_id, "--text", multiline_prompt)
        self.assertEqual(self.assert_success(saved)["savedPrompt"], multiline_prompt)
        trailing_newline_prompt = "First line\n"
        saved, _ = self.call_cli("task", "prompt", task_id, "--text", trailing_newline_prompt)
        self.assertEqual(self.assert_success(saved)["savedPrompt"], trailing_newline_prompt)
        reopened, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(reopened)["savedPrompt"], trailing_newline_prompt)
        saved, _ = self.call_cli("task", "prompt", task_id, "--text", prompt)
        self.assertEqual(self.assert_success(saved)["savedPrompt"], prompt)
        persisted = self.complete_fixture_turn(task_id, executable_name="codex-fixture-success", message=prompt)
        self.assertTrue(any(message["role"] == "user" and message["text"] == prompt for message in persisted["messages"]))
        queued_text = "Send this follow-up once the next turn completes."
        queued, _ = self.call_cli("conversation", "queue", task_id, "--message", queued_text)
        queued_record = self.assert_success(queued)
        self.assertEqual(queued_record["taskID"], task_id)
        self.assertEqual(queued_record["threadID"], self.assert_success(self.call_cli("task", "get", task_id)[0])["codexThreadID"])
        queue_read, _ = self.call_cli("conversation", "queue-list", task_id)
        self.assertEqual([item["text"] for item in self.assert_success(queue_read)], [queued_text])
        self.complete_fixture_turn(task_id, executable_name="codex-fixture-success", message="Start the turn that releases the saved follow-up.")
        reloaded_history, _ = self.call_cli(
            "conversation", "history", task_id,
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(self.data_directory / "codex-fixture-success")},
        )
        self.assertEqual([message["text"] for message in self.assert_success(reloaded_history)["messages"] if message["role"] == "user"].count(queued_text), 1)
        queue_read, _ = self.call_cli("conversation", "queue-list", task_id)
        self.assertEqual(self.assert_success(queue_read), [], "A completed queued send should be removed and must not dispatch again after reload.")
        interrupted_followup = "Keep this queued after an interrupted turn."
        queued, _ = self.call_cli("conversation", "queue", task_id, "--message", interrupted_followup)
        queued_record = self.assert_success(queued)
        interrupted_fixture = self.data_directory / "codex-fixture-interrupted"
        shutil.copyfile(fixture, interrupted_fixture)
        interrupted_fixture.chmod(0o755)
        shutil.copyfile(self.data_directory / "codex-fixture-success.history", Path(str(interrupted_fixture) + ".history"))
        interrupted, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Interrupt the active turn.",
            "--answer", "color=Blue", "--answer", "token=fixture-secret", expected_status=1,
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(interrupted_fixture)},
        )
        self.assert_failure(interrupted, "operation_failed")
        queue_read, _ = self.call_cli("conversation", "queue-list", task_id)
        retained = self.assert_success(queue_read)
        self.assertEqual(retained[0]["id"], queued_record["id"])
        self.assertEqual(retained[0]["state"], "needsAction", "An interrupted turn must retain its queued text without silently retrying it.")
        retry_fixture = self.data_directory / "codex-fixture-success"
        shutil.copyfile(fixture, retry_fixture)
        retry_fixture.chmod(0o755)
        shutil.copyfile(Path(str(interrupted_fixture) + ".history"), Path(str(retry_fixture) + ".history"))
        retried, _ = self.call_cli(
            "conversation", "queue-retry", task_id, queued_record["id"],
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(retry_fixture)},
        )
        self.assertTrue(self.assert_success(retried)["retried"])
        queue_read, _ = self.call_cli("conversation", "queue-list", task_id)
        self.assertEqual(self.assert_success(queue_read), [], "An explicit retry that completes should remove the queued item.")
        task, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(task)["savedPrompt"], interrupted_followup)

        title_task = self.create_repo_task("Untitled task", [self.primary])
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-title-success"
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        title_prompt = "Transcript entry " + ("Readable chat content for scrolling. " * 120).rstrip()
        sent, _ = self.call_cli(
            "conversation", "send", title_task["id"], "--message", title_prompt,
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        self.assert_success(sent)
        titled, _ = self.call_cli("task", "get", title_task["id"])
        titled_record = self.assert_success(titled)
        self.assertEqual(titled_record["savedPrompt"], title_prompt)
        self.assertEqual(titled_record["title"], "Generated fixture title")
        generated_title_worktree = titled_record["repositoryWorktrees"][0]
        self.assertEqual(generated_title_worktree["branch"], "generated-fixture-title")
        self.assertFalse(generated_title_worktree["isPending"])
        self.assertTrue(Path(generated_title_worktree["worktreePath"]).is_dir())
        self.assertTrue(self.branch_exists(self.primary, "generated-fixture-title"))
        title_events = [
            json.loads(line)
            for line in (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8").splitlines()
            if json.loads(line).get("taskID") == title_task["id"]
            and json.loads(line).get("event", "").startswith("task.title_")
        ]
        generation_started = next(event for event in title_events if event["event"] == "task.title_generation.started")
        generation_succeeded = next(event for event in title_events if event["event"] == "task.title_generation.succeeded")
        title_applied = next(event for event in title_events if event["event"] == "task.title_apply.succeeded")
        self.assertEqual(generation_started["threadID"], generation_succeeded["threadID"])
        self.assertTrue(generation_started["threadID"])
        self.assertTrue(generation_succeeded["threadID"])
        self.assertEqual(title_applied["titleSource"], "codex")
        self.assertEqual(title_applied["taskID"], title_task["id"])

        failure_executable = self.data_directory / "codex-fixture-title-failure"
        shutil.copyfile(fixture, failure_executable)
        failure_executable.chmod(0o755)
        failure_prompt = "Explain how repository setup works for new contributors"
        failed_title_task = self.create_repo_task("Untitled task", [self.primary])
        sent, _ = self.call_cli(
            "conversation", "send", failed_title_task["id"], "--message", failure_prompt,
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(failure_executable)},
        )
        self.assert_success(sent)
        failed_title, _ = self.call_cli("task", "get", failed_title_task["id"])
        failed_title_record = self.assert_success(failed_title)
        self.assertEqual(failed_title_record["savedPrompt"], failure_prompt)
        self.assertEqual(failed_title_record["title"], failure_prompt)
        fallback_worktree = failed_title_record["repositoryWorktrees"][0]
        fallback_branch = "explain-how-repository-setup-works-for-new-contributors"
        self.assertEqual(fallback_worktree["branch"], fallback_branch)
        self.assertFalse(fallback_worktree["isPending"])
        self.assertTrue(Path(fallback_worktree["worktreePath"]).is_dir())
        self.assertTrue(self.branch_exists(self.primary, fallback_branch))
        self.assertNotEqual(failed_title_record["title"], "Generating title…")
        all_failure_events = [
            json.loads(line)
            for line in (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8").splitlines()
        ]
        failure_task_events = [event for event in all_failure_events if event.get("taskID") == failed_title_task["id"]]
        failure_events = [event for event in failure_task_events if event.get("event", "").startswith("task.title_")]
        generation_failed = next(event for event in failure_events if event["event"] == "task.title_generation.failed")
        rpc_failed = next(event for event in all_failure_events if event.get("event") == "codex.rpc.response.failed" and event.get("errorCode") == "-32042")
        fallback_applied = next(event for event in failure_events if event["event"] == "task.title_apply.succeeded")
        self.assertEqual(generation_failed["phase"], "title-turn")
        self.assertTrue(generation_failed["threadID"])
        self.assertTrue(generation_failed.get("errorDescription"))
        self.assertIn("Fixture rejected task-title generation.", generation_failed["errorDescription"])
        self.assertNotIn(failure_prompt, generation_failed["errorDescription"])
        self.assertEqual(rpc_failed["errorDescription"], "Codex returned an RPC error.")
        self.assertNotIn(failure_prompt, json.dumps(rpc_failed))
        self.assertEqual(fallback_applied["titleSource"], "prompt-fallback")
        title_log = json.dumps(title_events + failure_events)
        self.assertNotIn(title_prompt, title_log)
        self.assertNotIn("Generated fixture title", title_log)
        self.assertNotIn(failure_prompt, title_log)

        pending_task = self.create_task("Untitled task", roots=[self.primary])
        pending_prompt = "Persist this prompt before title generation finishes."
        pending_executable = self.data_directory / "codex-fixture-title-success-wait"
        shutil.copyfile(fixture, pending_executable)
        pending_executable.chmod(0o755)
        pending_send = self.start_cli(
            "conversation", "send", pending_task["id"], "--message", pending_prompt,
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(pending_executable)},
        )
        pending_ready = Path(str(pending_executable) + ".resolve-ready")
        pending_release = Path(str(pending_executable) + ".resolve-continue")
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline and not pending_ready.exists() and pending_send.poll() is None:
                time.sleep(0.02)
            self.assertTrue(pending_ready.exists(), "The title generation fixture should reach its pending state.")
            pending_record, _ = self.call_cli("task", "get", pending_task["id"])
            pending_record = self.assert_success(pending_record)
            self.assertEqual(pending_record["title"], "Generating title…")
            self.assertEqual(pending_record["savedPrompt"], pending_prompt)
            self.assertEqual(pending_record["pendingSubmittedPrompt"], pending_prompt)
            self.assertTrue(pending_record.get("codexThreadID"), "The pending conversation thread should remain attached to the task.")
        finally:
            pending_release.write_text("Release title generation.\n", encoding="utf-8")
        self.finish_cli(pending_send, ["conversation", "send", pending_task["id"], "--message", pending_prompt])
        completed_pending, _ = self.call_cli("task", "get", pending_task["id"])
        self.assertIsNone(self.assert_success(completed_pending).get("pendingSubmittedPrompt"))

        renamed_auto_task = self.create_repo_task("Untitled task", [self.secondary])
        renamed_auto_prompt = "Use the concurrently selected task title for this worktree."
        renamed_auto_title = "Concurrent custom branch title"
        renamed_auto_executable = self.data_directory / "codex-fixture-concurrent-title-success-wait"
        shutil.copyfile(fixture, renamed_auto_executable)
        renamed_auto_executable.chmod(0o755)
        renamed_auto_send = self.start_cli(
            "conversation", "send", renamed_auto_task["id"], "--message", renamed_auto_prompt,
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(renamed_auto_executable)},
        )
        renamed_title_ready = Path(str(renamed_auto_executable) + ".resolve-ready")
        renamed_title_release = Path(str(renamed_auto_executable) + ".resolve-continue")
        try:
            title_ready_deadline = time.monotonic() + 15
            while time.monotonic() < title_ready_deadline and not renamed_title_ready.exists():
                time.sleep(0.02)
            self.assertTrue(renamed_title_ready.exists(), "Title generation should remain pending during the concurrent rename.")
            renamed_response, _ = self.call_cli(
                "task", "rename", renamed_auto_task["id"], "--title", renamed_auto_title
            )
            self.assertEqual(self.assert_success(renamed_response)["title"], renamed_auto_title)
        finally:
            renamed_title_release.write_text("Continue concurrent title generation.\n", encoding="utf-8")
        sent_response, _ = self.finish_cli(
            renamed_auto_send,
            ("conversation", "send", renamed_auto_task["id"], "--message", renamed_auto_prompt),
        )
        self.assert_success(sent_response)
        renamed_auto_record = self.assert_success(self.call_cli("task", "get", renamed_auto_task["id"])[0])
        self.assertEqual(renamed_auto_record["title"], renamed_auto_title)
        self.assertEqual(renamed_auto_record["repositoryWorktrees"][0]["branch"], "concurrent-custom-branch-title")
        self.assertFalse(renamed_auto_record["repositoryWorktrees"][0]["isPending"])

        stale_task = self.create_task("Untitled task", roots=[self.primary])
        stale_prompt = "Restore a stale submitted prompt to the composer."
        saved, _ = self.call_cli(
            "task", "prompt", stale_task["id"], "--text", stale_prompt,
            "--status", "In Progress", "--submitted", "true",
        )
        stale_record = self.assert_success(saved)
        self.assertEqual(stale_record["pendingSubmittedPrompt"], stale_prompt)
        stale_history, _ = self.call_cli("conversation", "history", stale_task["id"])
        self.assertEqual(self.assert_success(stale_history)["messages"], [])
        recovered, _ = self.call_cli("task", "get", stale_task["id"])
        recovered_record = self.assert_success(recovered)
        self.assertEqual(recovered_record["status"], "Waiting Response")
        self.assertIn("restarted", recovered_record["statusMessage"].lower())
        self.assertEqual(recovered_record["savedPrompt"], stale_prompt)
        self.assertIsNone(recovered_record.get("pendingSubmittedPrompt"))

    # case-contract: test_conversation_provider_selection_persists_and_validates | New tasks use the default provider from settings, which starts as Codex and rejects unknown providers, and task create can choose a provider explicitly. A task without a conversation switches providers immediately; provider choice persists across fresh CLI/XPC reads and an app relaunch. Each provider's selected model is global across conversations and persists across provider switches and fresh CLI/XPC reads without reusing the other provider's model. Unknown providers and Done-task switches are rejected, and history has no provider boundary. A Claude task names Claude in the empty conversation, hides Goal mode, and rejects Goal changes through CLI/XPC.
    def test_conversation_provider_selection_persists_and_validates(self):
        settings = self.assert_success(self.call_cli("settings", "get")[0])
        self.assertEqual(settings["defaultProvider"], "codex", "Existing installs keep Codex as the default provider.")
        codex_task = self.create_task("Provider default task")
        self.assertEqual(codex_task["conversationProvider"], "codex")
        provider = self.assert_success(self.call_cli("conversation", "provider", codex_task["id"])[0])
        self.assertEqual(provider, {"provider": "codex", "supportsGoals": True})
        self.assert_success(self.call_cli("conversation", "model", codex_task["id"], "set", "codex-choice")[0])

        unknown_default, _ = self.call_cli("settings", "set-default-provider", "gemini", expected_status=2)
        self.assert_failure(unknown_default, "invalid_argument")
        self.assertIn("Valid providers: codex, claude", unknown_default["error"]["message"])
        changed = self.assert_success(self.call_cli("settings", "set-default-provider", "claude")[0])
        self.assertEqual(changed["defaultProvider"], "claude")
        self.assertEqual(self.assert_success(self.call_cli("settings", "get")[0])["defaultProvider"], "claude")
        claude_task = self.create_task("Provider claude default task")
        self.assertEqual(claude_task["conversationProvider"], "claude")
        explicit, _ = self.call_cli("task", "create", "--title", "Explicit Codex task", "--root", self.primary, "--provider", "codex")
        self.assertEqual(self.assert_success(explicit)["conversationProvider"], "codex")
        unknown_create, _ = self.call_cli("task", "create", "--title", "Unknown provider task", "--root", self.primary, "--provider", "gemini", expected_status=2)
        self.assert_failure(unknown_create, "invalid_argument")

        unknown_switch, _ = self.call_cli("conversation", "provider", codex_task["id"], "set", "gemini", expected_status=2)
        self.assert_failure(unknown_switch, "invalid_argument")
        switched = self.assert_success(self.call_cli("conversation", "provider", codex_task["id"], "set", "claude")[0])
        self.assertEqual(switched["conversationProvider"], "claude", "A task without a conversation switches immediately.")
        self.assertIsNone(self.assert_success(self.call_cli("conversation", "model", codex_task["id"])[0])["modelID"], "Claude must not inherit the Codex model selection.")
        self.assert_success(self.call_cli("conversation", "model", codex_task["id"], "set", "claude-choice")[0])
        self.assertEqual(self.assert_success(self.call_cli("conversation", "provider", codex_task["id"], "set", "codex")[0])["conversationProvider"], "codex")
        self.assertEqual(self.assert_success(self.call_cli("conversation", "model", codex_task["id"])[0])["modelID"], "codex-choice")
        self.assert_success(self.call_cli("conversation", "provider", codex_task["id"], "set", "claude")[0])
        self.assertEqual(self.assert_success(self.call_cli("conversation", "model", codex_task["id"])[0])["modelID"], "claude-choice")
        self.assertIsNone(switched.get("codexThreadID"))
        self.assertIsNone(switched.get("claudeSessionID"))
        fresh = self.assert_success(self.call_cli("task", "get", codex_task["id"])[0])
        self.assertEqual(fresh["conversationProvider"], "claude", "The provider choice persists across fresh CLI/XPC reads.")
        self.assertEqual(
            self.assert_success(self.call_cli("conversation", "provider", codex_task["id"])[0]),
            {"provider": "claude", "supportsGoals": False},
        )
        history = self.assert_success(self.call_cli("conversation", "history", codex_task["id"])[0])
        self.assertEqual(history["messages"], [])
        self.assertEqual(history["providerBoundaries"], [], "Switching before any conversation records no boundary.")
        transcript = self.data_directory / "conversation-transcripts" / f"{codex_task['id']}.json"
        self.assertFalse(transcript.exists(), "No transcript is written before the first turn.")

        goal_set, _ = self.call_cli("conversation", "goal", claude_task["id"], "set", "--text", "Ship it", expected_status=1)
        self.assert_failure(goal_set, "invalid_transition")
        self.assertIn("Goals are available only in Codex conversations", goal_set["error"]["message"])
        goal_get = self.assert_success(self.call_cli("conversation", "goal", claude_task["id"], "get")[0])
        self.assertIsNone(goal_get, "A Claude task reports no Goal.")

        done_task = self.create_task("Provider done task", roots=[self.secondary])
        self.assert_success(self.call_cli("conversation", "provider", done_task["id"], "set", "codex")[0])
        self.complete_fixture_turn(done_task["id"])
        self.assert_success(self.call_cli("task", "move", done_task["id"], "Done")[0])
        done_switch, _ = self.call_cli("conversation", "provider", done_task["id"], "set", "claude", expected_status=2)
        self.assert_failure(done_switch, "invalid_argument")
        self.assertIn("Done tasks are closed", done_switch["error"]["message"])
        self.assertEqual(self.assert_success(self.call_cli("task", "get", done_task["id"])[0])["conversationProvider"], "codex")

    # case-contract: test_claude_answer_stays_final_around_outcome_report | Against the Claude Code protocol fixture, the answer Claude writes before running its StationAI progress and outcome commands and the closing line it adds afterward form one final answer, not commentary, in the streamed final answer, fresh history, and transcript, and the reported outcome moves the task to Review. Text Claude writes before an ordinary tool stays commentary, and a turn without an outcome ends in Waiting Response. The fixture records both private reminder attempts for each unreported turn; fresh history hides reminder prompts and replies completely. Switching to Codex hands off the whole Claude answer, excludes answered-turn commentary and private reminder prompts and replies including their redacted placeholders, and hands off only the last commentary from the turn that recorded no answer. A new Claude conversation with no explicit model pick dispatches to Sonnet and shows Sonnet as the picker default.
    def test_claude_answer_stays_final_around_outcome_report(self):
        story = "BISCUIT-7 waited by the gate every evening. One night the boy finally came home."
        story_answer = story + "\n\nThe story is above."
        claude = self.data_directory / "claude-fixture-story"
        codex = self.data_directory / "codex-fixture-handoff-success"
        for source, executable in [("claude-code-fixture.py", claude), ("codex-app-server-fixture.py", codex)]:
            shutil.copyfile(Path(__file__).resolve().parent / "fixtures" / source, executable)
            executable.chmod(0o755)
        (self.data_directory / ".stationai-claude-fixture-owner").write_text(
            "StationAI test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        (self.data_directory / ".stationai-codex-fixture-owner").write_text(
            "StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        fixtures = {"STATIONAI_E2E_CLAUDE_EXECUTABLE": str(claude), "STATIONAI_E2E_CODEX_EXECUTABLE": str(codex)}
        created, _ = self.call_cli("task", "create", "--title", "Claude answer", "--root", self.primary, "--provider", "claude")
        task_id = self.assert_success(created)["id"]

        sent, events = self.call_cli("conversation", "send", task_id, "--message", "Tell me a very short dog story.", extra_environment=fixtures)
        self.assert_success(sent)
        self.assertEqual([event["payload"]["text"] for event in events if event["type"] == "assistant_final"], [story_answer])
        progress = [event["payload"]["text"] for event in events if event["type"] == "assistant_progress"]
        self.assertFalse(any("BISCUIT-7" in text for text in progress), f"The story must not stream as commentary: {progress}")
        recorded = json.loads(Path(str(claude) + ".history").read_text(encoding="utf-8"))["turns"][-1]
        self.assertIn("--model", recorded["arguments"], "Claude Code should receive an explicit model even when the user hasn't chosen one.")
        model_argument_index = recorded["arguments"].index("--model")
        self.assertEqual(recorded["arguments"][model_argument_index + 1], "sonnet", "StationAI should default new Claude turns to Sonnet.")
        self.assertEqual(len(recorded["reportCommands"]), 2, "The fixture should run StationAI's progress-clear and outcome commands.")
        self.assertTrue(all('"ok":true' in command["output"] for command in recorded["reportCommands"]), recorded["reportCommands"])
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["status"], "Review")

        sent, events = self.call_cli("conversation", "send", task_id, "--message", "Please inspect the workspace.", extra_environment=fixtures)
        self.assert_success(sent)
        self.assertEqual([event["payload"]["text"] for event in events if event["type"] == "assistant_final"], ["Inspection done: the workspace is ready."])
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["status"], "Waiting Response")

        sent, events = self.call_cli("conversation", "send", task_id, "--message", "Start the checks.", extra_environment=fixtures)
        self.assert_success(sent)
        self.assertEqual([event for event in events if event["type"] == "assistant_final"], [], "This turn records only commentary.")

        history = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=fixtures)[0])
        assistant = [(message["phase"], message["text"]) for message in history["messages"] if message["role"] == "assistant"]
        self.assertEqual(assistant, [
            ("final_answer", story_answer),
            ("commentary", "I'll inspect the workspace first."),
            ("final_answer", "Inspection done: the workspace is ready."),
            ("commentary", "Starting the checks."),
            ("commentary", "Checks are running; results will follow."),
        ], "A fresh history read keeps the story as one final answer and the pre-tool text as commentary.")
        self.assertFalse(any("StationAI internal outcome reminder:" in message["text"] for message in history["messages"]))
        self.assertFalse(any("private outcome reminder hidden" in message["text"] for message in history["messages"]))
        self.assertFalse(any("private outcome response hidden" in message["text"] for message in history["messages"]))

        self.assert_success(self.call_cli("conversation", "provider", task_id, "set", "codex")[0])
        sent, _ = self.call_cli("conversation", "send", task_id, "--message", "Continue the story.", extra_environment=fixtures)
        self.assert_success(sent)
        codex_turns = json.loads(Path(str(codex) + ".history").read_text(encoding="utf-8"))["turns"]
        handoff_turn = next(turn for turn in reversed(codex_turns) if turn.get("userMessage", "").endswith("Continue the story."))
        handoff = handoff_turn["userMessage"]
        self.assertIn("<stationai-handoff-context>", handoff)
        self.assertIn(f"Claude: {story_answer}", handoff, "Codex must receive the whole Claude answer.")
        self.assertIn("Claude: Inspection done: the workspace is ready.", handoff)
        self.assertNotIn("I'll inspect the workspace first.", handoff, "Commentary of an answered turn stays with the provider that produced it.")
        self.assertIn("Claude: Checks are running; results will follow.", handoff, "A turn without an answer hands off its last commentary.")
        self.assertNotIn("Starting the checks.", handoff, "Only the unanswered turn's last commentary is handed off.")
        self.assertNotIn("StationAI internal outcome reminder:", handoff, "Private outcome reminders must not cross provider boundaries.")
        self.assertNotIn("[StationAI private outcome reminder hidden]", handoff, "Redacted reminder prompts must not cross provider boundaries.")
        self.assertNotIn("private outcome response hidden", handoff, "Redacted reminder replies must not enter handoff context.")
        self.assertTrue(handoff.endswith("Continue the story."))

    # case-contract: test_claude_resume_recovers_visible_history | After a Claude turn and StationAI restart, if Claude cannot find its native resumed session, the retried fresh session receives the prior visible conversation from StationAI's persisted transcript together with the new prompt. Claude completes the turn, and fresh CLI/XPC history and the visible UI retain both turns. A normal Claude resume continues using the native session without receiving duplicate handoff context.
    def test_claude_resume_recovers_visible_history(self):
        claude = self.data_directory / "claude-fixture-resume-recovery"
        shutil.copyfile(Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py", claude)
        claude.chmod(0o755)
        (self.data_directory / ".stationai-claude-fixture-owner").write_text(
            "StationAI test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        fixtures = {"STATIONAI_E2E_CLAUDE_EXECUTABLE": str(claude)}
        task = self.create_task("Claude session recovery", roots=[self.primary])
        self.assert_success(self.call_cli("conversation", "provider", task["id"], "set", "claude")[0])
        first, _ = self.call_cli("conversation", "send", task["id"], "--message", "Tell me a very short dog story.", extra_environment=fixtures)
        self.assert_success(first)
        second, _ = self.call_cli("conversation", "send", task["id"], "--message", "Please inspect the workspace.", extra_environment=fixtures)
        self.assert_success(second)

        fixture_history_path = Path(str(claude) + ".history")
        normal_resume = next(
            turn for turn in reversed(json.loads(fixture_history_path.read_text(encoding="utf-8"))["turns"])
            if turn.get("userText") == "Please inspect the workspace."
        )
        self.assertTrue(normal_resume["resumed"], normal_resume)
        self.assertNotIn("<stationai-handoff-context>", normal_resume["userText"], "A working native resume must not receive duplicate transcript context.")

        send_started = [
            event for event in self.diagnostic_events()
            if event.get("event") == "conversation.send.started" and event.get("taskID") == task["id"]
        ][-1]
        bridge_pid = int(send_started["clientPID"])
        try:
            os.kill(bridge_pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        service_exit_deadline = time.monotonic() + 5
        while time.monotonic() < service_exit_deadline:
            try:
                os.kill(bridge_pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.02)
        else:
            self.fail("The isolated bridge service should exit before recovery after restart.")
        restarted_task, _ = self.call_cli("task", "get", task["id"])
        self.assertEqual(self.assert_success(restarted_task)["conversationProvider"], "claude")

        # The test owns this fixture executable and its sidecar before arming the failure.
        owner = self.data_directory / ".stationai-claude-fixture-owner"
        self.assertEqual(owner.read_text(encoding="utf-8"), "StationAI test owns this Claude Code protocol fixture (v1).\n")
        Path(str(claude) + ".missing-resume").write_text("StationAI test owns this missing-session trigger.\n", encoding="utf-8")
        recovered, events = self.call_cli(
            "conversation", "send", task["id"], "--message", "What happened earlier?", extra_environment=fixtures
        )
        self.assert_success(recovered)
        self.assertIn("OK.", [event["payload"]["text"] for event in events if event["type"] == "assistant_final"])

        recovered_turn = next(
            turn for turn in reversed(json.loads(fixture_history_path.read_text(encoding="utf-8"))["turns"])
            if "stationai internal outcome reminder:" not in turn.get("userText", "").lower()
        )
        self.assertFalse(recovered_turn["resumed"], "A missing native session should be replaced by a fresh Claude session.")
        prompt = recovered_turn["userText"]
        self.assertIn("<stationai-handoff-context>", prompt)
        self.assertIn("User: Tell me a very short dog story.", prompt)
        self.assertIn("Claude: BISCUIT-7 waited by the gate every evening.", prompt)
        self.assertIn("User: Please inspect the workspace.", prompt)
        self.assertIn("Claude: Inspection done: the workspace is ready.", prompt)
        self.assertTrue(prompt.endswith("What happened earlier?"))

        history = self.assert_success(self.call_cli("conversation", "history", task["id"], extra_environment=fixtures)[0])
        visible = [message["text"] for message in history["messages"]]
        self.assertIn("Tell me a very short dog story.", visible)
        self.assertIn("BISCUIT-7 waited by the gate every evening. One night the boy finally came home.\n\nThe story is above.", visible)
        self.assertIn("What happened earlier?", visible)
        self.assertIn("OK.", visible)

    # case-contract: test_conversation_provider_switch_waits_for_settled_turn_and_records_boundary | After a completed Codex fixture turn, switching providers is rejected while a follow-up is queued or a turn is active, and the provider menu is disabled during the turn. A settled switch to Claude records a boundary after the last Codex reply that persists across fresh reads and an app relaunch, keeps the Codex thread, and keeps earlier replies labeled Codex; switching back before any Claude turn removes the empty boundary, and the next Codex turn completes in the same thread.
    def test_conversation_provider_switch_waits_for_settled_turn_and_records_boundary(self):
        task = self.create_task("Provider switch task")
        self.complete_fixture_turn(task["id"], message="Start with Codex.")
        fixture_environment = {"STATIONAI_E2E_CODEX_EXECUTABLE": str(self.data_directory / "codex-fixture")}
        before = self.assert_success(self.call_cli("conversation", "history", task["id"], extra_environment=fixture_environment)[0])
        codex_thread = self.assert_success(self.call_cli("task", "get", task["id"])[0])["codexThreadID"]
        self.assertTrue(codex_thread)
        self.assertTrue(before["messages"])
        self.assertTrue(all(message.get("provider") == "codex" for message in before["messages"]))

        queued = self.assert_success(self.call_cli("conversation", "queue", task["id"], "--message", "Queued before switching.", extra_environment=fixture_environment)[0])
        blocked_by_queue, _ = self.call_cli("conversation", "provider", task["id"], "set", "claude", expected_status=1, extra_environment=fixture_environment)
        self.assert_failure(blocked_by_queue, "invalid_transition")
        self.assertIn("queued follow-ups", blocked_by_queue["error"]["message"])
        self.assert_success(self.call_cli("conversation", "queue-remove", task["id"], queued["id"], extra_environment=fixture_environment)[0])

        process, executable, active, release = self.start_progress_fixture_turn(task["id"], "codex-fixture-hold-release")
        try:
            blocked_by_turn, _ = self.call_cli("conversation", "provider", task["id"], "set", "claude", expected_status=1, extra_environment=fixture_environment)
            self.assert_failure(blocked_by_turn, "invalid_transition")
            self.assertIn("current turn", blocked_by_turn["error"]["message"])
            self.assertEqual(self.assert_success(self.call_cli("task", "get", task["id"])[0])["conversationProvider"], "codex")
            self.assert_success(self.call_cli("task", "outcome", task["id"], "completed")[0])
        finally:
            release.write_text("Release the active turn.\n", encoding="utf-8")
            stdout, stderr = process.communicate(timeout=30)
        self.assertEqual(process.returncode, 0, f"Held Codex turn failed: {stdout}; {stderr}")

        switched = self.assert_success(self.call_cli("conversation", "provider", task["id"], "set", "claude", extra_environment=fixture_environment)[0])
        self.assertEqual(switched["conversationProvider"], "claude")
        self.assertEqual(switched["codexThreadID"], codex_thread, "Switching keeps the Codex thread for a later return.")
        self.assertIsNone(switched.get("claudeSessionID"), "Claude starts its session on its first turn.")
        history = self.assert_success(self.call_cli("conversation", "history", task["id"], extra_environment=fixture_environment)[0])
        boundaries = history["providerBoundaries"]
        self.assertEqual(len(boundaries), 1, history)
        self.assertEqual(boundaries[0]["provider"], "claude")
        self.assertEqual(boundaries[0]["afterMessageID"], history["messages"][-1]["id"], "The boundary follows the last Codex reply.")
        self.assertEqual(history["messages"][-1]["role"], "assistant")
        self.assertTrue(all(message.get("provider") == "codex" for message in history["messages"]), "Earlier replies stay labeled Codex.")
        orders = [message["timelineOrder"] for message in history["messages"]]
        self.assertEqual(orders, sorted(orders))
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task["id"])[0])["conversationProvider"], "claude")

        returned = self.assert_success(self.call_cli("conversation", "provider", task["id"], "set", "codex", extra_environment=fixture_environment)[0])
        self.assertEqual(returned["conversationProvider"], "codex")
        returned_history = self.assert_success(self.call_cli("conversation", "history", task["id"], extra_environment=fixture_environment)[0])
        self.assertEqual(returned_history["providerBoundaries"], [], "Returning before any Claude turn removes the empty boundary.")
        self.complete_fixture_turn(task["id"], message="Continue with Codex.")
        after = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(after["codexThreadID"], codex_thread, "The next Codex turn resumes the same thread.")
        final_history = self.assert_success(self.call_cli("conversation", "history", task["id"], extra_environment=fixture_environment)[0])
        self.assertEqual(final_history["providerBoundaries"], [])
        self.assertIn("Continue with Codex.", [message["text"] for message in final_history["messages"] if message["role"] == "user"])
        self.assertFalse(
            any("<stationai-handoff-context>" in message["text"] for message in final_history["messages"]),
            "Handoff context never appears in the visible transcript.",
        )
    # case-contract: test_conversation_adds_ordered_text_annotations | Selecting text in assistant and user messages shows a floating Add comment hint above and horizontally centered on the selected lines, including wrapped multiline selections; clicking it opens a compact inline comment field positioned beside the hint, with a clearly visible dark arrow on its light submit control. Added ranges render orange and persist after reopening. The composer shows the pending comment count. Structurally recognized comment context is hidden while similar ordinary text remains visible; comments are sent in insertion order with source ranges alongside ordinary composer text. Multiple comments can be added before one send, comment-only sends are enabled, and cancelling the compact field leaves none to submit. Pending comments take precedence over Goal-entry mode: submission sends them to the conversation, exits Goal-entry mode, and does not store the comment payload as a Goal objective. The agent is instructed to start each comment response line with the provider-neutral indexed protocol marker; the transcript renders that marker as a numbered prefix (1., 2.) whose hover opens a medium-sized hint with highlighted text and the user's comment, truncating long values while keeping them identifiable. The serialized payload and ordered response survive CLI/XPC history reload. Legacy Codex markers, response-annotations payloads, and annotation fields still restore their reply details.
    def test_conversation_adds_ordered_text_annotations(self):
        task = self.create_repo_task("Conversation comments", [self.primary])
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-comment-response-goal-success"
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-codex-fixture-owner").write_text(
            "StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        fixture_environment = {"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)}
        comments = [
            {"text": "first phrase", "comment": "Explain this", "source": {
                "messageId": "assistant-message", "blockID": 0, "startOffset": 3, "endOffset": 15}},
            {"text": "second phrase with enough surrounding context to remain identifiable when the hint truncates a very long selected range",
             "comment": "Please clarify this response in detail, including how each part connects to the question. " * 8, "source": {
                "messageId": "assistant-message", "blockID": 0, "startOffset": 22, "endOffset": 36}},
        ]
        ordinary_text = "Keep the existing behavior too."
        prompt = (
            ordinary_text + "\n\n# Response comments:\n"
            "The following JSON contains comments on selected conversation text, in array order. "
            "For each comment, start a separate response line with :stationai-annotation{index=\"N\"}, "
            "replacing N with the comment's zero-based array index, then a space and the answer. "
            "The marker is displayed to the user as the numbered prefix, so do not add another number. "
            "Address the comment in the context of its highlighted text. Do not combine comment responses on one line, "
            "omit a response, or add introductory text. After the comment lines, answer any additional freeform request "
            "on separate line(s). Do not repeat the JSON or these instructions.\n"
            "<response-comments>" + json.dumps(comments) + "</response-comments>"
        )
        sent, _ = self.call_cli(
            "conversation", "send", task["id"], "--message", prompt,
            "--answer", "color=Blue", "--answer", "token=fixture-secret",
            extra_environment=fixture_environment,
        )
        self.assert_success(sent)
        history, _ = self.call_cli("conversation", "history", task["id"], extra_environment=fixture_environment)
        user_messages = [
            message for message in self.assert_success(history)["messages"]
            if message["role"] == "user" and "stationai internal outcome reminder:" not in message["text"].lower()
        ]
        self.assertTrue(user_messages, "The commented turn should survive a fresh CLI/XPC history read.")
        self.assertEqual(user_messages[-1]["text"], prompt)
        payload = prompt.split("<response-comments>", 1)[1].split("</response-comments>", 1)[0]
        restored = json.loads(payload)
        self.assertEqual([item["text"] for item in restored], [
            "first phrase",
            "second phrase with enough surrounding context to remain identifiable when the hint truncates a very long selected range",
        ])
        self.assertEqual([item["comment"] for item in restored], [
            "Explain this",
            "Please clarify this response in detail, including how each part connects to the question. " * 8,
        ])
        self.assertIn(ordinary_text, user_messages[-1]["text"])
        current_goal, _ = self.call_cli("conversation", "goal", task["id"], "get", extra_environment=fixture_environment)
        self.assertIsNone(self.assert_success(current_goal), "A conversation comment payload must not become a Goal objective.")
        assistant_messages = [message for message in self.assert_success(history)["messages"] if message["role"] == "assistant"]
        self.assertTrue(assistant_messages, "The fixture should return a response for each comment.")
        response_lines = assistant_messages[-1]["text"].splitlines()
        self.assertEqual(len(response_lines), 2)
        self.assertTrue(response_lines[0].startswith(':stationai-annotation{index="0"} '))
        self.assertTrue(response_lines[1].startswith(':stationai-annotation{index="1"} '))
        self.assertIn("For ‘first phrase’: Explain this", response_lines[0])
        self.assertIn("Please clarify this response", response_lines[1])

        legacy_prompt = (
            "# Response annotations:\nThe following JSON contains comments on selected conversation text, in array order.\n"
            "<response-annotations>" + json.dumps([{
                "text": "legacy highlighted words", "annotation": "A detail from older saved history",
                "source": {"messageId": "legacy-source", "blockID": 0, "startOffset": 0, "endOffset": 24},
            }]) + "</response-annotations>"
        )
        legacy_sent, _ = self.call_cli(
            "conversation", "send", task["id"], "--message", legacy_prompt,
            "--answer", "color=Blue", "--answer", "token=fixture-secret",
            extra_environment=fixture_environment,
        )
        self.assert_success(legacy_sent)
        legacy_history, _ = self.call_cli("conversation", "history", task["id"], extra_environment=fixture_environment)
        legacy_assistant = next(
            message for message in reversed(self.assert_success(legacy_history)["messages"])
            if message["role"] == "assistant"
        )
        self.assertIn("legacy highlighted words", legacy_assistant["text"])
        self.assertIn("A detail from older saved history", legacy_assistant["text"])
        self.assertIn(':codex-annotation{index="0"}', legacy_assistant["text"])

        comment_only_prompt = (
            "<stationai-comment-context>\n# Response comments:\n"
            "For each comment, start a separate response line with :stationai-annotation{index=\"N\"}.\n"
            "<response-comments>" + json.dumps(comments[:1]) + "</response-comments>\n"
            "</stationai-comment-context>"
        )
        self.assert_success(self.call_cli(
            "conversation", "send", task["id"], "--message", comment_only_prompt,
            extra_environment=fixture_environment,
        )[0])
        comment_only_history = self.assert_success(self.call_cli(
            "conversation", "history", task["id"], extra_environment=fixture_environment,
        )[0])
        self.assertEqual(
            [item for item in comment_only_history["messages"] if item["role"] == "user"][-1]["text"],
            comment_only_prompt,
        )
        self.assertIn(
            ':stationai-annotation{index="0"}',
            [item for item in comment_only_history["messages"] if item["role"] == "assistant"][-1]["text"],
        )

    # case-contract: test_claude_auto_branch_uses_generated_title_and_fallback | An Untitled Claude task with a pending auto repository branch uses its selected provider to generate the title before worktree creation; the branch and title persist across fresh CLI/XPC reads and the visible task. If Claude title generation returns no title, the prompt becomes the title and branch fallback, and the conversation still starts in that worktree. A fresh `task title` request reproduces the generated title and provider (null when generation yields nothing), and `task reconcile` returns the settled task unchanged.
    def test_claude_auto_branch_uses_generated_title_and_fallback(self):
        source = Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py"
        for suffix, prompt, title, branch in [
            ("title-success", "Explain the selected Claude task.", "Generated Claude title", "generated-claude-title"),
            ("title-failure", "Explain Claude fallback title", "Explain Claude fallback title", "explain-claude-fallback-title"),
        ]:
            executable = self.data_directory / f"claude-fixture-{suffix}"
            shutil.copyfile(source, executable)
            executable.chmod(0o755)
            (self.data_directory / ".stationai-claude-fixture-owner").write_text(
                "StationAI test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
            )
            environment = {"STATIONAI_E2E_CLAUDE_EXECUTABLE": str(executable)}
            task = self.assert_success(self.call_cli(
                "task", "create", "--title", "Untitled task", "--repo", self.primary, "--provider", "claude"
            )[0])
            self.assertEqual(task["repositoryWorktrees"][0]["branch"], "auto")
            self.assertTrue(task["repositoryWorktrees"][0]["isPending"])
            self.assert_success(self.call_cli(
                "conversation", "send", task["id"], "--message", prompt, extra_environment=environment
            )[0])
            fresh = self.assert_success(self.call_cli("task", "get", task["id"])[0])
            self.assertEqual(fresh["conversationProvider"], "claude")
            self.assertEqual(fresh["title"], title)
            record = fresh["repositoryWorktrees"][0]
            self.assertEqual(record["branch"], branch)
            self.assertFalse(record["isPending"])
            self.assertTrue(Path(record["worktreePath"]).is_dir())
            self.assertTrue(self.branch_exists(self.primary, branch))
            self.assertEqual(fresh["savedPrompt"], prompt)
            history = self.assert_success(self.call_cli(
                "conversation", "history", task["id"], extra_environment=environment
            )[0])
            self.assertIn(prompt, [item["text"] for item in history["messages"] if item["role"] == "user"])
            fixture_turns = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))["turns"]
            self.assertTrue(any(turn["userText"].startswith("Write a concise task title") for turn in fixture_turns))
            self.assertEqual(Path(fixture_turns[-1]["cwd"]).resolve(), Path(record["worktreePath"]).resolve())
            generated = self.assert_success(self.call_cli(
                "task", "title", task["id"], "--prompt", prompt, extra_environment=environment
            )[0])
            if suffix == "title-success":
                self.assertEqual(generated, {"title": title, "provider": "claude"})
            else:
                self.assertIsNone(generated, "A provider that returns no title leaves the caller to fall back.")
            reconciled = self.assert_success(self.call_cli(
                "task", "reconcile", task["id"], extra_environment=environment
            )[0])
            self.assertEqual((reconciled["id"], reconciled["status"], reconciled["title"]), (task["id"], fresh["status"], title))

    # case-contract: test_conversation_runs_concurrent_claude_sends_in_parallel | Claude turns for different conversations run at the same time instead of queueing on a shared turn slot. While one task's turn is held active, a second task's send starts in its own Claude process, runs its own tool, and completes with its own user and assistant messages before the held turn is released. Each turn's process uses its own task working directory, each conversation keeps only its own activity rows and measured durations, diagnostics record no queued-slot event and no prompt text, and the second conversation's answer is available while the first turn is still running.
    def test_conversation_runs_concurrent_claude_sends_in_parallel(self):
        source = Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py"
        executable = self.data_directory / "claude-fixture-parallel-sends"
        shutil.copyfile(source, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-claude-fixture-owner").write_text(
            "StationAI test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        environment = {"STATIONAI_E2E_CLAUDE_EXECUTABLE": str(executable)}
        first = self.assert_success(self.call_cli(
            "task", "create", "--title", "Held Claude conversation", "--root", self.primary, "--provider", "claude"
        )[0])
        second = self.assert_success(self.call_cli(
            "task", "create", "--title", "Parallel Claude conversation", "--root", self.secondary, "--provider", "claude"
        )[0])
        first_prompt = "Please hold-claude-turn-for-concurrency."
        second_prompt = "Inspect the workspace while the other conversation is busy."
        first_command = ["conversation", "send", first["id"], "--message", first_prompt]
        second_command = ["conversation", "send", second["id"], "--message", second_prompt]
        ready = Path(str(executable) + ".concurrent-turn-ready")
        release = Path(str(executable) + ".concurrent-turn-release")
        first_process = self.start_cli(*first_command, extra_environment=environment)
        second_process = None
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline and not ready.exists() and first_process.poll() is None:
                time.sleep(0.02)
            self.assertTrue(ready.exists(), "The first Claude fixture turn should become active.")
            pending = second_process = self.start_cli(*second_command, extra_environment=environment)
            second_result, _ = self.finish_cli(pending, second_command)
            second_process = None
            self.assert_success(second_result)
            # The held turn is still running, so the second conversation ran its
            # own Claude process instead of waiting for a shared turn slot.
            self.assertIsNone(first_process.poll(), "The parallel Claude turn must complete while the first turn is still held.")
            release.write_text("Release the first Claude turn.\n", encoding="utf-8")
            first_result, _ = self.finish_cli(first_process, first_command)
            self.assert_success(first_result)
        finally:
            if first_process.poll() is None:
                release.write_text("Release the first Claude turn.\n", encoding="utf-8")
                try:
                    first_process.communicate(timeout=20)
                except subprocess.TimeoutExpired:
                    first_process.kill()
                    first_process.communicate()
            if second_process is not None and second_process.poll() is None:
                second_process.terminate()
                second_process.communicate()

        first_history = self.assert_success(self.call_cli("conversation", "history", first["id"], extra_environment=environment)[0])
        self.assertIn(first_prompt, [message["text"] for message in first_history["messages"] if message["role"] == "user"])
        self.assertIn("OK.", [message["text"] for message in first_history["messages"] if message["role"] == "assistant"])
        second_history = self.assert_success(self.call_cli("conversation", "history", second["id"], extra_environment=environment)[0])
        self.assertIn(second_prompt, [message["text"] for message in second_history["messages"] if message["role"] == "user"])
        self.assertIn(
            "Inspection done: the workspace is ready.",
            [message["text"] for message in second_history["messages"] if message["role"] == "assistant"],
        )

        # Activity rows and their measured durations belong to the conversation
        # that ran them, not to whichever Claude turn finished last.
        parallel_rows = [row for row in second_history["activities"] if row["id"] == "toolu_read"]
        self.assertEqual(len(parallel_rows), 1, second_history["activities"])
        self.assertEqual(parallel_rows[0]["status"], "completed")
        self.assertGreater(parallel_rows[0].get("durationMs", 0), 0, parallel_rows[0])
        self.assertEqual([], [row for row in first_history["activities"] if row["id"] == "toolu_read"])

        turns = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))["turns"]
        working_directories = {
            turn["userText"]: Path(turn["cwd"]).resolve()
            for turn in turns if turn.get("userText") in {first_prompt, second_prompt}
        }
        self.assertEqual(working_directories.get(first_prompt), Path(self.primary).resolve())
        self.assertEqual(working_directories.get(second_prompt), Path(self.secondary).resolve())

        diagnostics = (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8")
        self.assertNotIn("claude.turn.queued", diagnostics, "Parallel Claude turns must not wait on a shared turn slot.")
        self.assertNotIn(second_prompt, diagnostics, "Diagnostics must not include conversation prompt text.")
        first_record = self.assert_success(self.call_cli("task", "get", first["id"])[0])
        second_record = self.assert_success(self.call_cli("task", "get", second["id"])[0])
        fixture_sessions = {turn.get("sessionID") for turn in turns}
        self.assertIn(first_record.get("claudeSessionID"), fixture_sessions, turns)
        self.assertIn(second_record.get("claudeSessionID"), fixture_sessions, turns)

    # case-contract: test_conversation_isolates_failing_claude_turn_from_parallel_send | A failing Claude turn does not disturb a conversation running in parallel. While one task's turn is held and then fails, a second task's send from a separate process completes on its own session and reaches Waiting Response; the failing task keeps its user message, records no final answer, and its provider process exit is the only failure in diagnostics. The UI shows the parallel answer after reopening its task with fresh history.
    def test_conversation_isolates_failing_claude_turn_from_parallel_send(self):
        source = Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py"
        executable = self.data_directory / "claude-fixture-parallel-failure"
        shutil.copyfile(source, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-claude-fixture-owner").write_text(
            "StationAI test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        environment = {"STATIONAI_E2E_CLAUDE_EXECUTABLE": str(executable)}
        first = self.assert_success(self.call_cli(
            "task", "create", "--title", "Failing Claude conversation", "--root", self.primary, "--provider", "claude"
        )[0])
        second = self.assert_success(self.call_cli(
            "task", "create", "--title", "Unaffected Claude conversation", "--root", self.secondary, "--provider", "claude"
        )[0])
        first_prompt = "Please fail-after-hold-claude-turn-for-concurrency."
        second_prompt = "Second Claude turn after failure."
        first_command = ["conversation", "send", first["id"], "--message", first_prompt]
        second_command = ["conversation", "send", second["id"], "--message", second_prompt]
        ready = Path(str(executable) + ".concurrent-turn-ready")
        release = Path(str(executable) + ".concurrent-turn-release")
        first_process = self.start_cli(*first_command, extra_environment=environment)
        second_process = None
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline and not ready.exists() and first_process.poll() is None:
                time.sleep(0.02)
            self.assertTrue(ready.exists(), "The failing Claude turn should reach its held active state.")
            pending = second_process = self.start_cli(*second_command, extra_environment=environment)
            completed, _ = self.finish_cli(pending, second_command)
            second_process = None
            self.assert_success(completed)
            self.assertIsNone(first_process.poll(), "The unaffected conversation must complete while the failing turn is still held.")
            release.write_text("Fail the first Claude turn.\n", encoding="utf-8")
            failed, _ = self.finish_cli(first_process, first_command, expected_status=1)
            self.assertFalse(failed.get("ok"), failed)
            self.assertIn("Claude Code exited with status 1.", failed.get("error", {}).get("message", ""), failed)
        finally:
            if first_process.poll() is None:
                release.write_text("Fail the first Claude turn.\n", encoding="utf-8")
                try:
                    first_process.communicate(timeout=20)
                except subprocess.TimeoutExpired:
                    first_process.kill()
                    first_process.communicate()
            if second_process is not None and second_process.poll() is None:
                second_process.terminate()
                second_process.communicate()

        second_record = self.assert_success(self.call_cli("task", "get", second["id"])[0])
        self.assertEqual(second_record.get("status"), "Waiting Response")
        second_history = self.assert_success(self.call_cli("conversation", "history", second["id"], extra_environment=environment)[0])
        self.assertIn(second_prompt, [message["text"] for message in second_history["messages"] if message["role"] == "user"])
        self.assertIn("OK.", [message["text"] for message in second_history["messages"] if message["role"] == "assistant"])
        first_history = self.assert_success(self.call_cli("conversation", "history", first["id"], extra_environment=environment)[0])
        self.assertIn(first_prompt, [message["text"] for message in first_history["messages"] if message["role"] == "user"])
        self.assertEqual(
            [],
            [message for message in first_history["messages"] if message.get("phase") == "final_answer"],
            "The failing conversation must not record an answer.",
        )

        diagnostics = (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8")
        first_record = self.assert_success(self.call_cli("task", "get", first["id"])[0])
        exits = [
            json.loads(line) for line in diagnostics.splitlines()
            if '"event":"claude.process.exited"' in line and json.loads(line).get("exitStatus") == "1"
        ]
        self.assertTrue(exits, diagnostics)
        self.assertEqual(
            {item.get("activeThreadID") for item in exits},
            {first_record.get("claudeSessionID")},
            "Only the failing conversation's Claude process should exit with a failure.",
        )

    # case-contract: test_claude_stop_leaves_parallel_conversation_running | Stopping one Claude turn pauses only that conversation while a second Claude conversation runs in parallel. The parallel conversation answers and keeps its own activity rows and measured durations while the first turn is still thinking; the stopped task moves to Waiting Response with no failure reason, records no answer, and leaves the parallel task's Waiting Response result untouched. A fresh CLI/XPC read confirms both results.
    def test_claude_stop_leaves_parallel_conversation_running(self):
        source = Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py"
        executable = self.data_directory / "claude-fixture-parallel-stop"
        shutil.copyfile(source, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-claude-fixture-owner").write_text(
            "StationAI test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        environment = {"STATIONAI_E2E_CLAUDE_EXECUTABLE": str(executable)}
        stopped = self.assert_success(self.call_cli(
            "task", "create", "--title", "Stopped Claude conversation", "--root", self.primary, "--provider", "claude"
        )[0])
        running = self.assert_success(self.call_cli(
            "task", "create", "--title", "Running Claude conversation", "--root", self.secondary, "--provider", "claude"
        )[0])
        parallel_prompt = "Inspect the workspace while the other conversation is busy."
        hold_command = ["conversation", "send", stopped["id"], "--message", "Hold until stopped."]
        parallel_command = ["conversation", "send", running["id"], "--message", parallel_prompt]
        ready = Path(str(executable) + ".interrupt-ready")
        received = Path(str(executable) + ".interrupt-received")
        release = Path(str(executable) + ".interrupt-release")
        hold_process = self.start_cli(*hold_command, extra_environment=environment)
        parallel_process = None
        stop_results = {}
        stop_failures = []
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline and not ready.is_file() and hold_process.poll() is None:
                time.sleep(0.02)
            self.assertTrue(ready.is_file(), "The stopped conversation should reach its active thinking state.")
            pending = parallel_process = self.start_cli(*parallel_command, extra_environment=environment)
            parallel_result, _ = self.finish_cli(pending, parallel_command)
            parallel_process = None
            self.assert_success(parallel_result)
            self.assertIsNone(hold_process.poll(), "The parallel conversation must finish while the other turn is still thinking.")

            def stop_turn():
                try:
                    stop_results["response"] = self.call_cli(
                        "conversation", "stop", stopped["id"], timeout=20, extra_environment=environment
                    )[0]
                except Exception as error:  # noqa: BLE001 - surfaced through stop_failures
                    stop_failures.append(error)

            stopper = threading.Thread(target=stop_turn, daemon=True)
            stopper.start()
            interrupt_deadline = time.monotonic() + 10
            while not received.is_file() and time.monotonic() < interrupt_deadline:
                time.sleep(0.02)
            self.assertTrue(received.is_file(), "Claude should receive its native interrupt for the stopped conversation.")
            release.write_text("acknowledge interrupt\n", encoding="utf-8")
            stopper.join(timeout=20)
            self.assertFalse(stopper.is_alive(), "The Claude interrupt acknowledgment should settle.")
            self.assertEqual(stop_failures, [])
            self.assertTrue(self.assert_success(stop_results["response"])["interrupted"])
            interrupted_send, _ = self.finish_cli(hold_process, hold_command, expected_status=1)
            self.assertFalse(interrupted_send.get("ok", True), interrupted_send)
        finally:
            if hold_process.poll() is None:
                release.write_text("acknowledge interrupt\n", encoding="utf-8")
                try:
                    hold_process.communicate(timeout=20)
                except subprocess.TimeoutExpired:
                    hold_process.kill()
                    hold_process.communicate()
            if parallel_process is not None and parallel_process.poll() is None:
                parallel_process.terminate()
                parallel_process.communicate()

        # Only the stopped conversation carries the paused result.
        stopped_record = self.assert_success(self.call_cli("task", "get", stopped["id"])[0])
        self.assertEqual(stopped_record["status"], "Waiting Response")
        self.assertIsNone(stopped_record.get("statusMessage"), "A user-requested stop should not leave a failure reason.")
        running_record = self.assert_success(self.call_cli("task", "get", running["id"])[0])
        self.assertEqual(running_record["status"], "Waiting Response")
        self.assertIsNone(running_record.get("statusMessage"))

        stopped_history = self.assert_success(self.call_cli("conversation", "history", stopped["id"], extra_environment=environment)[0])
        self.assertEqual(
            [],
            [message for message in stopped_history["messages"] if message.get("phase") == "final_answer"],
            "The stopped conversation must not record an answer.",
        )
        running_history = self.assert_success(self.call_cli("conversation", "history", running["id"], extra_environment=environment)[0])
        self.assertIn(parallel_prompt, [message["text"] for message in running_history["messages"] if message["role"] == "user"])
        self.assertIn(
            "Inspection done: the workspace is ready.",
            [message["text"] for message in running_history["messages"] if message["role"] == "assistant"],
        )
        running_rows = [row for row in running_history["activities"] if row["id"] == "toolu_read"]
        self.assertEqual(len(running_rows), 1, running_history["activities"])
        self.assertGreater(running_rows[0].get("durationMs", 0), 0, running_rows[0])
        self.assertEqual([], [row for row in stopped_history["activities"] if row["id"] == "toolu_read"])

    # case-contract: test_conversation_serializes_concurrent_sends | Two concurrent sends for the same task are serialized across the app and CLI/XPC paths against the local Codex app-server fixture; the second waits for the first, both complete on the persisted thread, the task remains In Progress while a send is active, and successful turns without outcome calls finish in Waiting Response.
    def test_conversation_serializes_concurrent_sends(self):
        task = self.create_repo_task("Concurrent conversation sends", [self.primary])
        task_id = task["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-concurrent-serial-success-wait"
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-codex-fixture-owner").write_text(
            "StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )

        first_prompt = "First serialized message."
        second_prompt = "Second serialized message."
        first_command = ["conversation", "send", task_id, "--message", first_prompt]
        second_command = ["conversation", "send", task_id, "--message", second_prompt]
        first_process = self.start_cli(
            *first_command,
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        second_process = None
        release_marker = Path(str(executable) + ".resolve-continue")
        first_ready = Path(str(executable) + ".resolve-ready")
        second_started = Path(str(executable) + ".serial-second-turn-started")
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline and not first_ready.exists() and first_process.poll() is None:
                time.sleep(0.02)
            if not first_ready.exists():
                release_marker.write_text("Release the first serialized turn.\n", encoding="utf-8")
                try:
                    output, error_output = first_process.communicate(timeout=20)
                except subprocess.TimeoutExpired:
                    first_process.kill()
                    output, error_output = first_process.communicate()
                self.fail(
                    "The first fixture send did not reach its pause before starting the second send: "
                    f"exit={first_process.returncode}; stdout={output}; stderr={error_output}"
                )

            time.sleep(0.1)
            steer_message = "Keep the current approach and prioritize the smaller change."
            steered, _ = self.call_cli(
                "conversation", "steer", task_id, "--message", steer_message,
                extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)},
            )
            self.assertTrue(self.assert_success(steered)["accepted"], "Steering should use the active XPC client and turn ID.")

            second_process = self.start_cli(
                *second_command,
                extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)},
            )
            time.sleep(0.25)
            self.assertIsNone(second_process.poll(), "The second send should wait for the conversation-turn reservation held by the first send.")
            self.assertFalse(
                second_started.exists(),
                "The shared app-server fixture must not receive the second turn until the first send releases its reservation.",
            )
            active = self.assert_success(self.call_cli("task", "get", task_id)[0])
            self.assertEqual(active["status"], "In Progress", "A queued send must not mark the task Blocked.")

            release_marker.write_text("Release the first serialized turn.\n", encoding="utf-8")
            first_response, _ = self.finish_cli(first_process, first_command)
            self.assert_success(first_response)
            second_response, _ = self.finish_cli(second_process, second_command)
            self.assert_success(second_response)
        finally:
            if first_process.poll() is None:
                release_marker.write_text("Release the first serialized turn.\n", encoding="utf-8")
                try:
                    first_process.communicate(timeout=20)
                except subprocess.TimeoutExpired:
                    first_process.kill()
                    first_process.communicate()
            if second_process is not None and second_process.poll() is None:
                try:
                    second_process.communicate(timeout=20)
                except subprocess.TimeoutExpired:
                    second_process.kill()
                    second_process.communicate()

        saved_history = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
        self.assertEqual(
            [turn["userMessage"] for turn in saved_history["messages"]
             if "stationai internal outcome reminder:" not in (turn["userMessage"] or "").lower()],
            [first_prompt, second_prompt],
            "Both sequential turns should persist in the same Codex thread history.",
        )
        thread_id = saved_history["threadID"]
        thread_events = [event for event in saved_history["events"] if event["method"].startswith("thread/")]
        self.assertEqual([event["method"] for event in thread_events].count("thread/start"), 1)
        self.assertGreaterEqual([event["method"] for event in thread_events].count("thread/resume"), 1)
        self.assertTrue(all(event["threadID"] == thread_id for event in saved_history["events"]))
        visible_turns = [turn for turn in saved_history["messages"]
                         if "stationai internal outcome reminder:" not in (turn["userMessage"] or "").lower()]
        self.assertTrue(all(turn["threadID"] == thread_id for turn in visible_turns))
        turn_ids = [turn["turnID"] for turn in visible_turns]
        self.assertEqual(len(turn_ids), 2)
        self.assertEqual(len(set(turn_ids)), 2, "Each serialized send should have its own Codex turn ID.")
        self.assertEqual(
            [event["turnID"] for event in saved_history["events"]
             if event["method"] == "turn/start" and "stationai internal outcome reminder:" not in (event.get("userMessage") or "").lower()],
            turn_ids,
        )
        completed = self.assert_success(self.call_cli("task", "get", task_id)[0])
        self.assertEqual(completed["codexThreadID"], thread_id)
        self.assertEqual(completed["status"], "Waiting Response")
        self.assertEqual(len(saved_history.get("steerRequests", [])), 1)
        steer_params = saved_history["steerRequests"][0]
        self.assertEqual(steer_params["threadId"], thread_id)
        self.assertEqual(steer_params["input"], [{"type": "text", "text": steer_message}])
        self.assertTrue(steer_params["expectedTurnId"], "Steering must identify the matching active turn.")

    # case-contract: test_conversation_steers_and_queues_active_turn | When a steer misses its active turn, CLI/XPC and UI accept it into the durable queue for its own turn; opening an empty task waits for the model-aware prompt and omits the generic Start a conversation heading; with no active turn, a missed queued-row steer dispatches synchronously as its own turn and leaves the queue; queued fallback survives process exit or app relaunch and is drained exactly once; a missed regular or queued-row steer arriving during targeted queue dispatch is drained afterward exactly once; a failed targeted turn remains needs-action and does not drain later messages; malformed steer images fail validation; CLI/XPC steering routes image data to a UI-owned active turn and appears in the conversation. Command-Return steers the active turn with attached text and images, then clears the accepted draft and image preview; if the active turn changes before delivery, it clears the draft and queues the complete message for its own turn. Plain Return queues a follow-up; its row Steer uses the active turn ID, appears in the transcript, and removes the item only after acceptance. The obsolete footer Queue and Steer buttons are absent and the active response control is labeled Stop response. Follow-ups persist across reopening, expose per-row Steer, delete, and more actions, and a distinct after-turn follow-up dispatches once after a matching completion and is removed only after successful delivery; removing an unknown queue ID fails without changing the queue.
    def test_conversation_steers_and_queues_active_turn(self):
        task = self.create_repo_task("Active turn message controls", [self.primary])
        task_id = task["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-steer-queue-serial-success-wait"
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-codex-fixture-owner").write_text(
            "StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        Path(str(executable) + ".reject-next-steer").write_text("The expected turn ID is stale.\n", encoding="utf-8")
        first_prompt = "Start the active turn before steering and queueing."
        steering_text = "Keep the current approach and simplify the final change."
        queued_text = "After the current work, verify the saved follow-up."
        send_command = ["conversation", "send", task_id, "--message", first_prompt]
        process = self.start_cli(
            *send_command,
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        ready = Path(str(executable) + ".resolve-ready")
        release = Path(str(executable) + ".resolve-continue")
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline and not ready.exists() and process.poll() is None:
                time.sleep(0.02)
            self.assertTrue(ready.exists(), "The fixture should hold the first turn active for steering and queueing.")
            time.sleep(0.1)
            invalid_image = self.data_directory / "invalid-steer.png"
            invalid_image.write_bytes(b"not an image")
            invalid_steer, _ = self.call_cli(
                "conversation", "steer", task_id, "--message", steering_text, "--image", str(invalid_image),
                expected_status=2,
                extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)},
            )
            self.assertEqual(invalid_steer["error"]["code"], "invalid_argument")
            steer_image = self.data_directory / "steer.png"
            steer_image.write_bytes(bytes.fromhex("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000b49444154789c636000020000050001a5f645400000000049454e44ae426082"))
            missed_steer, _ = self.call_cli(
                "conversation", "steer", task_id, "--message", steering_text, "--image", str(steer_image),
                extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)},
            )
            missed_result = self.assert_success(missed_steer)
            self.assertTrue(missed_result["accepted"])
            self.assertTrue(missed_result["queued"])
            missed_queue, _ = self.call_cli("conversation", "queue-list", task_id)
            missed_item = next(item for item in self.assert_success(missed_queue) if item["text"] == steering_text)
            self.assertEqual(missed_item["state"], "queued", "A stale steer should become an ordinary durable follow-up.")
            self.assertTrue(missed_item["imageDataURLs"][0].startswith("data:image/png;base64,"), "A queued CLI steer should retain its image.")
            steered, _ = self.call_cli(
                "conversation", "steer", task_id, "--message", steering_text, "--image", str(steer_image),
                extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)},
            )
            self.assertTrue(self.assert_success(steered)["accepted"])
            queued, _ = self.call_cli("conversation", "queue", task_id, "--message", queued_text)
            queued_record = self.assert_success(queued)
            persisted, _ = self.call_cli("conversation", "queue-list", task_id)
            persisted_ids = {item["id"] for item in self.assert_success(persisted)}
            self.assertEqual(persisted_ids, {queued_record["id"], missed_item["id"]}, "Fresh XPC reads should preserve both the ordinary follow-up and missed steer.")
            removable, _ = self.call_cli("conversation", "queue", task_id, "--message", "Remove this queued follow-up.")
            removable_record = self.assert_success(removable)
            removed, _ = self.call_cli("conversation", "queue-remove", task_id, removable_record["id"])
            self.assertTrue(self.assert_success(removed)["removed"])
            persisted, _ = self.call_cli("conversation", "queue-list", task_id)
            self.assertEqual({item["id"] for item in self.assert_success(persisted)}, {queued_record["id"], missed_item["id"]})
            steerable, _ = self.call_cli("conversation", "queue", task_id, "--message", "Steer this queued follow-up now.")
            steerable_record = self.assert_success(steerable)
            queued_steer, _ = self.call_cli("conversation", "queue-steer", task_id, steerable_record["id"])
            self.assertTrue(self.assert_success(queued_steer)["accepted"])
            persisted, _ = self.call_cli("conversation", "queue-list", task_id)
            self.assertEqual({item["id"] for item in self.assert_success(persisted)}, {queued_record["id"], missed_item["id"]})
            missed_row_item, _ = self.call_cli("conversation", "queue", task_id, "--message", "Keep this after a missed row steer.")
            missed_row_record = self.assert_success(missed_row_item)
            Path(str(executable) + ".reject-next-steer").write_text("expected active turn id stale-turn but found fixture-turn\n", encoding="utf-8")
            missed_queue_steer, _ = self.call_cli("conversation", "queue-steer", task_id, missed_row_record["id"])
            self.assertTrue(self.assert_success(missed_queue_steer)["accepted"])
            self.assertTrue(self.assert_success(missed_queue_steer)["queued"])
            persisted, _ = self.call_cli("conversation", "queue-list", task_id)
            persisted_messages = self.assert_success(persisted)
            persisted_by_id = {item["id"]: item for item in persisted_messages}
            self.assertEqual(set(persisted_by_id), {queued_record["id"], missed_item["id"], missed_row_record["id"]})
            self.assertEqual(persisted_by_id[missed_row_record["id"]]["state"], "queued", "A missed row steer should return to ordinary queue delivery.")
            missing_remove, _ = self.call_cli(
                "conversation", "queue-remove", task_id, "00000000-0000-0000-0000-000000000000", expected_status=1
            )
            self.assert_failure(missing_remove, "invalid_transition")
            persisted, _ = self.call_cli("conversation", "queue-list", task_id)
            self.assertEqual(
                {item["id"] for item in self.assert_success(persisted)},
                {queued_record["id"], missed_item["id"], missed_row_record["id"]},
                "An unknown queue removal must leave all existing queued messages unchanged.",
            )
        finally:
            release.write_text("Release the active turn.\n", encoding="utf-8")
        self.finish_cli(process, send_command)

        history_response, _ = self.call_cli(
            "conversation", "history", task_id,
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        history = self.assert_success(history_response)
        self.assertEqual([message["text"] for message in history["messages"] if message["role"] == "user"].count(queued_text), 1)
        self.assertEqual([message["text"] for message in history["messages"] if message["role"] == "user"].count("Keep this after a missed row steer."), 1)
        protocol_history = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
        self.assertEqual(len(protocol_history["rejectedSteerRequests"]), 2, "Both missed-turn steer requests should be rejected by Codex and delivered later from the queue.")
        missed_delivery = next(turn for turn in protocol_history["messages"] if turn["userMessage"] == steering_text)
        self.assertTrue(missed_delivery["images"][0].startswith("data:image/png;base64,"), "The missed CLI steer image should reach Codex on its own turn.")
        self.assertEqual(len(protocol_history["steerRequests"]), 2)
        steer = protocol_history["steerRequests"][0]
        self.assertEqual(steer["threadId"], protocol_history["threadID"])
        self.assertEqual(steer["input"][0], {"type": "text", "text": steering_text})
        self.assertEqual(steer["input"][1]["type"], "image")
        self.assertTrue(steer["input"][1]["url"].startswith("data:image/png;base64,"))
        self.assertEqual(steer["expectedTurnId"], protocol_history["messages"][0]["turnID"])
        self.assertEqual(protocol_history["steerRequests"][1]["input"], [{"type": "text", "text": "Steer this queued follow-up now."}])
        self.assertEqual(protocol_history["steerRequests"][1]["expectedTurnId"], protocol_history["messages"][0]["turnID"])
        queue_after_completion, _ = self.call_cli("conversation", "queue-list", task_id)
        self.assertEqual(self.assert_success(queue_after_completion), [], "Successful dispatch must be durable and nonduplicating across reload.")

        targeted_text = "Retry this row as its own turn."
        targeted_row, _ = self.call_cli("conversation", "queue", task_id, "--message", targeted_text)
        targeted_record = self.assert_success(targeted_row)
        Path(str(executable) + ".hold-next-queued-turn").write_text("hold targeted delivery\n", encoding="utf-8")
        targeted_command = ["conversation", "queue-steer", task_id, targeted_record["id"]]
        targeted_process = self.start_cli(
            *targeted_command,
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        targeted_ready = Path(str(executable) + ".queued-turn-ready")
        targeted_release = Path(str(executable) + ".queued-turn-release")
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline and not targeted_ready.exists():
            time.sleep(0.02)
        self.assertTrue(targeted_ready.exists(), "A missed queued-row steer should begin its own targeted turn.")
        overlap_text = "Queue this steer behind the targeted turn."
        Path(str(executable) + ".reject-next-steer").write_text("no active turn to steer\n", encoding="utf-8")
        overlap_steer, _ = self.call_cli(
            "conversation", "steer", task_id, "--message", overlap_text,
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        self.assertTrue(self.assert_success(overlap_steer)["queued"], "A second missed steer should queue while targeted delivery is active.")
        overlap_queue, _ = self.call_cli("conversation", "queue-list", task_id)
        overlap_item = next(item for item in self.assert_success(overlap_queue) if item["text"] == overlap_text)
        self.assertEqual(overlap_item["state"], "queued")
        targeted_release.write_text("Release targeted delivery.\n", encoding="utf-8")
        targeted_result, _ = self.finish_cli(targeted_process, targeted_command)
        self.assertTrue(self.assert_success(targeted_result)["accepted"])
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            current_queue, _ = self.call_cli("conversation", "queue-list", task_id)
            if self.assert_success(current_queue) == []:
                break
            time.sleep(0.05)
        self.assertEqual(self.assert_success(current_queue), [], "A pending full drain should deliver the overlapping steer after targeted dispatch.")
        overlap_history, _ = self.call_cli(
            "conversation", "history", task_id,
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        delivered_texts = [message["text"] for message in self.assert_success(overlap_history)["messages"] if message["role"] == "user"]
        self.assertEqual(delivered_texts.count(targeted_text), 1)
        self.assertEqual(delivered_texts.count(overlap_text), 1)

        targeted_row_text = "Retry another row as its own turn."
        targeted_row, _ = self.call_cli("conversation", "queue", task_id, "--message", targeted_row_text)
        targeted_row_record = self.assert_success(targeted_row)
        Path(str(executable) + ".hold-next-queued-turn").write_text("hold targeted row delivery\n", encoding="utf-8")
        targeted_row_command = ["conversation", "queue-steer", task_id, targeted_row_record["id"]]
        targeted_row_process = self.start_cli(
            *targeted_row_command,
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline and not targeted_ready.exists():
            time.sleep(0.02)
        self.assertTrue(targeted_ready.exists(), "A second targeted row delivery should become active before the overlapping row steer.")
        missed_row_text = "Queue this missed row steer behind targeted dispatch."
        missed_row, _ = self.call_cli("conversation", "queue", task_id, "--message", missed_row_text)
        missed_row_record = self.assert_success(missed_row)
        Path(str(executable) + ".reject-next-steer").write_text("expected active turn id stale-turn but found fixture-turn\n", encoding="utf-8")
        overlapping_row_steer, _ = self.call_cli("conversation", "queue-steer", task_id, missed_row_record["id"])
        overlapping_row_result = self.assert_success(overlapping_row_steer)
        self.assertTrue(overlapping_row_result["accepted"])
        self.assertTrue(overlapping_row_result["queued"], "A missed queued-row steer should stay queued while targeted dispatch is active.")
        targeted_release.write_text("Release targeted row delivery.\n", encoding="utf-8")
        self.finish_cli(targeted_row_process, targeted_row_command)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            current_queue, _ = self.call_cli("conversation", "queue-list", task_id)
            if self.assert_success(current_queue) == []:
                break
            time.sleep(0.05)
        self.assertEqual(self.assert_success(current_queue), [], "A missed queued-row steer should drain after the targeted row turn.")
        final_history, _ = self.call_cli(
            "conversation", "history", task_id,
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        final_delivered = [message["text"] for message in self.assert_success(final_history)["messages"] if message["role"] == "user"]
        self.assertEqual(final_delivered.count(targeted_row_text), 1)
        self.assertEqual(final_delivered.count(missed_row_text), 1)

        immediate_text = "Deliver this missed row immediately as its own turn."
        immediate_row, _ = self.call_cli("conversation", "queue", task_id, "--message", immediate_text)
        immediate_record = self.assert_success(immediate_row)
        immediate_steer, _ = self.call_cli(
            "conversation", "queue-steer", task_id, immediate_record["id"],
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        immediate_result = self.assert_success(immediate_steer)
        self.assertTrue(immediate_result["accepted"])
        self.assertTrue(immediate_result["queued"], "A missed no-active-turn steer should fall back through the ordinary queue.")
        immediate_queue, _ = self.call_cli("conversation", "queue-list", task_id)
        self.assertEqual(self.assert_success(immediate_queue), [], "The synchronous own-turn drain should finish before the request returns.")
        immediate_history, _ = self.call_cli(
            "conversation", "history", task_id,
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        immediate_messages = [message["text"] for message in self.assert_success(immediate_history)["messages"] if message["role"] == "user"]
        self.assertEqual(immediate_messages.count(immediate_text), 1)

        failed_target_text = "This targeted queued turn should need action."
        later_text = "Keep this later message queued after a failure."
        failed_target, _ = self.call_cli("conversation", "queue", task_id, "--message", failed_target_text)
        failed_target_record = self.assert_success(failed_target)
        later_item, _ = self.call_cli("conversation", "queue", task_id, "--message", later_text)
        later_record = self.assert_success(later_item)
        Path(str(executable) + ".fail-next-turn-start").write_text("fail targeted turn start\n", encoding="utf-8")
        failed_steer, _ = self.call_cli("conversation", "queue-steer", task_id, failed_target_record["id"])
        failed_steer_result = self.assert_success(failed_steer)
        self.assertTrue(failed_steer_result["accepted"])
        self.assertTrue(failed_steer_result["queued"])
        failure_queue, _ = self.call_cli("conversation", "queue-list", task_id)
        failure_items = {item["id"]: item for item in self.assert_success(failure_queue)}
        self.assertEqual(failure_items[failed_target_record["id"]]["state"], "needsAction")
        self.assertEqual(failure_items[later_record["id"]]["state"], "queued", "A failed targeted send must not drain later queued messages.")

    # case-contract: test_conversation_sends_image_attachments | Backlog draft images persist through fresh CLI/XPC reads and reopening the conversation, with the preview restored; saving more than 8 draft images fails with invalid_argument and preserves the existing attachment. The conversation composer also accepts images from the picker and paste, compresses large clipboard images to fit the 10 MB payload limit, sends PNG and JPEG data URLs through CLI/XPC and to Codex using the tagged image URL payload, reads Codex history image URLs, and keeps earlier images visible after a later text turn and history refresh. The provider-neutral conversation present-image API is included in agent instructions, validates and persists agent-produced PNG and JPEG files as assistant messages, and reopening the conversation renders each image visibly. Diagnostics record image MIME and encoded size without storing image payloads. Clicking a composer or transcript attachment opens the original image in a large viewer, which can be closed to return to the conversation.
    def test_conversation_sends_image_attachments(self):
        task_id = self.create_task(title="Image conversation") ["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-image-serial-success"
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-codex-fixture-owner").write_text(
            "StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        image = self.data_directory / "tiny.png"
        image.write_bytes(bytes.fromhex("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000b49444154789c636000020000050001a5f645400000000049454e44ae426082"))
        backlog_task = self.create_task(title="Backlog image draft")
        draft_result, _ = self.call_cli("task", "prompt", backlog_task["id"], "--text", "", "--image", str(image))
        saved_draft = self.assert_success(draft_result)
        self.assertEqual(len(saved_draft["draftImageDataURLs"]), 1)
        self.assertTrue(saved_draft["draftImageDataURLs"][0].startswith("data:image/png;base64,"))
        fresh_draft, _ = self.call_cli("task", "get", backlog_task["id"])
        self.assertEqual(self.assert_success(fresh_draft)["draftImageDataURLs"], saved_draft["draftImageDataURLs"])
        excess_draft, _ = self.call_cli(
            "task", "prompt", backlog_task["id"], "--text", "",
            *[argument for _ in range(9) for argument in ("--image", str(image))],
            expected_status=2,
        )
        self.assertEqual(excess_draft.get("error", {}).get("code"), "invalid_argument")
        unchanged_draft, _ = self.call_cli("task", "get", backlog_task["id"])
        self.assertEqual(self.assert_success(unchanged_draft)["draftImageDataURLs"], saved_draft["draftImageDataURLs"])
        result, _ = self.call_cli(
            "conversation", "send", task_id, "--image", str(image),
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        initial_history = self.assert_success(result)
        sent = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
        self.assertEqual(len(sent["images"]), 1)
        self.assertTrue(sent["images"][0].startswith("data:image/png;base64,"))
        self.assertEqual(sent["imageInputs"], [{"type": "image", "url": sent["images"][0]}])
        first_user_message = next(message for message in initial_history["messages"] if message["role"] == "user")
        self.assertEqual(first_user_message["imageDataURLs"], sent["images"], "History should expose inline images through Codex's `url` field.")
        jpeg = self.data_directory / "tiny.jpg"
        subprocess.run(["sips", "-s", "format", "jpeg", str(image), "--out", str(jpeg)], check=True, capture_output=True)
        jpeg_result, _ = self.call_cli(
            "conversation", "send", task_id, "--image", str(jpeg),
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        self.assert_success(jpeg_result)
        sent = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
        self.assertTrue(sent["images"][0].startswith("data:image/jpeg;base64,"))
        self.assertLessEqual(len(base64.b64decode(sent["images"][0].split(",", 1)[1])), 10_000_000)
        text_prompt = "Describe this screenshot."
        mixed, _ = self.call_cli(
            "conversation", "send", task_id, "--message", text_prompt, "--image", str(image),
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        self.assert_success(mixed)
        sent = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
        self.assertEqual(sent["userMessage"], text_prompt)
        self.assertEqual(len(sent["images"]), 1)
        self.assertEqual(sent["imageInputs"], [{"type": "image", "url": sent["images"][0]}])
        followup, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Continue using the earlier image as context.",
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        followed_history = self.assert_success(followup)
        restored_messages = [message for message in followed_history["messages"] if message["role"] == "user"]
        self.assertEqual(len(restored_messages), 4)
        self.assertTrue(all(message["imageDataURLs"] for message in restored_messages[:3]), "History refresh after a later text turn must retain every earlier image.")
        self.assertEqual(restored_messages[2]["text"], text_prompt)
        invalid, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "image", "--image", str(self.data_directory / "missing.png"),
            expected_status=2,
        )
        self.assertNotEqual(invalid.get("error", {}).get("code"), None)
        diagnostics = self.diagnostic_events()
        image_request = next(
            event for event in diagnostics
            if event.get("event") == "bridge.request.succeeded"
            and event.get("command") == "conversation.send"
            and event.get("argument.images.0.mime") == "image/png"
        )
        self.assertGreater(int(image_request["argument.images.0.encodedCharacterCount"]), 0)
        serialized_diagnostics = json.dumps(diagnostics)
        self.assertNotIn("data:image/png;base64,", serialized_diagnostics)
        self.assertNotIn(sent["images"][0], serialized_diagnostics)
        published, _ = self.call_cli(
            "conversation", "present-image", task_id, "--image", str(image), "--caption", "Agent screenshot",
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        published_message = self.assert_success(published)
        self.assertEqual(published_message["role"], "assistant")
        self.assertEqual(published_message["text"], "Agent screenshot")
        self.assertTrue(published_message["imageDataURLs"][0].startswith("data:image/png;base64,"))
        fresh_history, _ = self.call_cli(
            "conversation", "history", task_id,
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        saved_agent_image = next(
            message for message in reversed(self.assert_success(fresh_history)["messages"])
            if message["id"] == published_message["id"]
        )
        self.assertEqual(saved_agent_image["id"], published_message["id"])
        self.assertEqual(saved_agent_image["imageDataURLs"], published_message["imageDataURLs"])
        thread_instructions = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))["threadStartDeveloperInstructions"]
        self.assertIn("conversation present-image", thread_instructions)
        jpeg = self.data_directory / "agent-image.jpg"
        subprocess.run(["sips", "-s", "format", "jpeg", str(image), "--out", str(jpeg)], check=True, capture_output=True)
        published_jpeg, _ = self.call_cli(
            "conversation", "present-image", task_id, "--image", str(jpeg), "--caption", "Agent JPEG screenshot",
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        jpeg_message = self.assert_success(published_jpeg)
        self.assertTrue(jpeg_message["imageDataURLs"][0].startswith("data:image/jpeg;base64,"))
        fresh_jpeg_history, _ = self.call_cli(
            "conversation", "history", task_id,
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        saved_jpeg = next(
            message for message in reversed(self.assert_success(fresh_jpeg_history)["messages"])
            if message["id"] == jpeg_message["id"]
        )
        self.assertEqual(saved_jpeg["imageDataURLs"], jpeg_message["imageDataURLs"])
        invalid_image = self.data_directory / "invalid-agent-image.png"
        invalid_image.write_bytes(b"not an image")
        invalid_publish, _ = self.call_cli(
            "conversation", "present-image", task_id, "--image", str(invalid_image),
            expected_status=2, extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        self.assertEqual(invalid_publish.get("error", {}).get("code"), "invalid_argument")

    # case-contract: test_claude_agent_image_published_during_active_turn | While a Claude Code turn is active in the app process, the agent's CLI/XPC image publication joins that active Claude transcript turn; after the provider finishes, history places the image before the later assistant answer, and reopening the conversation renders the exact published image. This active-turn attribution is Claude-specific: Codex history is composed from ordered timeline entries, so published images are standalone assistant messages verified for persistence and rendering in test_conversation_sends_image_attachments.
    def test_claude_agent_image_published_during_active_turn(self):
        source = Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py"
        executable = self.data_directory / "claude-fixture-active-image"
        shutil.copyfile(source, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-claude-fixture-owner").write_text(
            "StationAI test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        created, _ = self.call_cli("task", "create", "--title", "Claude active image", "--root", self.primary, "--provider", "claude")
        task_id = self.assert_success(created)["id"]
        image = self.data_directory / "active-agent-image.png"
        image.write_bytes(bytes.fromhex("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000b49444154789c636000020000050001a5f645400000000049454e44ae426082"))
        environment = {"STATIONAI_E2E_CLAUDE_EXECUTABLE": str(executable)}
        prompt = "Please publish-image-during-active-turn."
        send = self.start_cli("conversation", "send", task_id, "--message", prompt, extra_environment=environment)
        ready = Path(str(executable) + ".image-turn-ready")
        release = Path(str(executable) + ".image-turn-release")
        try:
            deadline = time.monotonic() + 20
            while not ready.exists() and send.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(ready.exists(), "Claude should hold the active turn before producing its answer.")
            published, _ = self.call_cli(
                "conversation", "present-image", task_id, "--image", str(image), "--caption", "During Claude turn",
                extra_environment=environment,
            )
            image_message = self.assert_success(published)
        finally:
            release.write_text("Release Claude's turn.\n", encoding="utf-8")
        self.finish_cli(send, ("conversation", "send", task_id, "--message", prompt), timeout=30)
        history, _ = self.call_cli("conversation", "history", task_id, extra_environment=environment)
        messages = self.assert_success(history)["messages"]
        image_index = next(index for index, message in enumerate(messages) if message["id"] == image_message["id"])
        answer_index = next(index for index, message in enumerate(messages) if message["text"] == "Claude answer after the image.")
        self.assertLess(image_index, answer_index, "The image should precede Claude's later answer in transcript order.")

    # case-contract: test_codex_agent_image_published_during_active_turn | While a Codex turn is active, CLI/XPC image publication avoids requesting provider history; the assistant image is tied to that turn, appears after its native response and before the next turn in ordered history, and remains visible after reopening the conversation.
    def test_codex_agent_image_published_during_active_turn(self):
        source = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-image-serial-success-wait"
        shutil.copyfile(source, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-codex-fixture-owner").write_text(
            "StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        created, _ = self.call_cli("task", "create", "--title", "Codex active image", "--root", self.primary)
        task_id = self.assert_success(created)["id"]
        environment = {"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)}
        prompt = "Please publish-image-during-active-turn."
        send = self.start_cli("conversation", "send", task_id, "--message", prompt, extra_environment=environment)
        ready = Path(str(executable) + ".resolve-ready")
        resume = Path(str(executable) + ".resolve-continue")
        observe_history = Path(str(executable) + ".observe-history-while-active")
        history_read = Path(str(executable) + ".history-read-while-active")
        try:
            deadline = time.monotonic() + 20
            while not ready.exists() and send.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(ready.exists(), "Codex should hold the active turn before its native response.")
            image = self.data_directory / "active-codex-agent-image.png"
            image.write_bytes(bytes.fromhex("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000b49444154789c636000020000050001a5f645400000000049454e44ae426082"))
            observe_history.touch()
            published, _ = self.call_cli(
                "conversation", "present-image", task_id, "--image", str(image), "--caption", "Generated while Codex was responding",
                extra_environment=environment,
            )
            image_message = self.assert_success(published)
            self.assertEqual(image_message["role"], "assistant")
            self.assertEqual(image_message["text"], "Generated while Codex was responding")
            self.assertTrue(image_message.get("turnID"), "The published image should carry the active Codex turn ID.")
            self.assertFalse(history_read.exists(), "Publishing during a Codex turn must not request its busy provider history.")
        finally:
            observe_history.unlink(missing_ok=True)
            resume.write_text("Release Codex's turn.\n", encoding="utf-8")
        self.finish_cli(send, ("conversation", "send", task_id, "--message", prompt), timeout=30)
        followup_text = "Start a later turn after the generated image."
        followup, _ = self.call_cli(
            "conversation", "send", task_id, "--message", followup_text,
            extra_environment=environment,
        )
        self.assert_success(followup)
        history, _ = self.call_cli("conversation", "history", task_id, extra_environment=environment)
        messages = self.assert_success(history)["messages"]
        image_index = next(index for index, message in enumerate(messages) if message["id"] == image_message["id"])
        answer_index = next(index for index, message in enumerate(messages) if message["text"] == "Answers received: Blue / fixture-secret.")
        followup_index = next(index for index, message in enumerate(messages) if message["role"] == "user" and message["text"] == followup_text)
        self.assertEqual(messages[image_index]["turnID"], messages[answer_index]["turnID"], "The image should share the active Codex response's turn ID.")
        self.assertGreater(image_index, answer_index, "The image should follow the native response in its Codex turn.")
        self.assertLess(image_index, followup_index, "The image should remain before the next Codex turn.")
        self.assertEqual(messages[image_index]["imageDataURLs"], image_message["imageDataURLs"])

    # case-contract: test_conversation_rejects_invalid_image_attachments | Malformed image data is rejected with a visible composer error and an invalid_argument bridge response, without creating conversation history or advancing task status.
    def test_conversation_rejects_invalid_image_attachments(self):
        task_id = self.create_task(title="Invalid image conversation")["id"]
        invalid_image = self.data_directory / "invalid.png"
        invalid_image.write_bytes(b"not an image")
        result, _ = self.call_cli(
            "conversation", "send", task_id, "--image", str(invalid_image), expected_status=2,
        )
        self.assertEqual(result.get("error", {}).get("code"), "invalid_argument")
        task, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(task)["status"], "Backlog")
        history, _ = self.call_cli("conversation", "history", task_id)
        self.assertEqual(self.assert_success(history)["messages"], [])

    # case-contract: test_conversation_shows_mcp_and_dynamic_tool_activity | MCP and dynamic tool lifecycle updates coalesce by stable item ID into distinct visible conversation rows; each call reports its start and measured duration, and completed durations persist through history reload. While a tool call holds the sent turn active, the submitted user message remains visible in the transcript. The latest active process, including a long command, appears outside Working for on one truncated line; older active processes remain inside, and completion moves it inside. The conversation header has no live activity line while responding. The expanded Working for list shows each call's live or completed duration. In-progress, completed, and failed statuses, server/tool identity, and safe result summaries render without duplicate rows, including when later-turn items follow the calls in history. Arguments and raw result text are never exposed.
    def test_conversation_shows_mcp_and_dynamic_tool_activity(self):
        task_id = self.create_task(title="Tool activity")['id']
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-tool-activity"
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-codex-fixture-owner").write_text(
            "StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        env = {
            "STATIONAI_E2E_CODEX_EXECUTABLE": str(executable),
            "STATIONAI_FIXTURE_WORKSPACE": str(self.primary),
        }
        send_command = ("conversation", "send", task_id, "--message", "Show tool activity.")
        process = self.start_cli(*send_command, extra_environment=env, binary_output=True)
        ready = Path(str(executable) + ".tool-ready")
        release_latest = Path(str(executable) + ".tool-release-latest")
        release = Path(str(executable) + ".tool-release")
        captured_lines = []
        stream_buffer = bytearray()
        active_rows = {}
        completed_rows = {}
        expected_tool_ids = {"item_fixture_mcp_call", "item_fixture_dynamic_call", "item_fixture_dynamic_legacy", "item_fixture_active_long_command"}
        try:
            deadline = time.monotonic() + 20
            while (not ready.exists() or not expected_tool_ids.issubset(active_rows)) and time.monotonic() < deadline:
                if process.stdout is not None:
                    readable, _, _ = select.select([process.stdout], [], [], 0.02)
                    if readable:
                        chunk = os.read(process.stdout.fileno(), 65536)
                        stream_buffer.extend(chunk)
                        while b"\n" in stream_buffer:
                            line, _, remainder = stream_buffer.partition(b"\n")
                            stream_buffer = bytearray(remainder)
                            if not line.strip():
                                continue
                            captured_lines.append(line.decode("utf-8"))
                            event = json.loads(line)
                            activity = event.get("payload", {}).get("activity", {})
                            if event.get("type") == "activity" and activity.get("status") == "inProgress":
                                active_rows[activity.get("id")] = activity
                            elif event.get("type") == "activity" and activity.get("status") in {"completed", "failed"}:
                                completed_rows[activity.get("id")] = activity
            self.assertTrue(ready.exists(), "The fixture should hold both tool calls after their start notifications.")
            self.assertTrue(expected_tool_ids.issubset(active_rows), "All expected tool calls should publish their started state.")
            held_history, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
            held_messages = self.assert_success(held_history)["messages"]
            self.assertIn("Show tool activity.", [message["text"] for message in held_messages], "The submitted user message should remain in persisted history while the provider turn is held active.")
            self.assertEqual(active_rows["item_fixture_mcp_call"]["toolKind"], "mcp")
            self.assertEqual(active_rows["item_fixture_dynamic_call"]["toolKind"], "dynamic")
            self.assertEqual(active_rows["item_fixture_dynamic_legacy"]["toolKind"], "dynamic")
            self.assertTrue(active_rows["item_fixture_active_long_command"]["title"].startswith("Running long-command-name"))
            self.assertGreater(len(active_rows["item_fixture_active_long_command"]["title"]), 200)
            self.assertTrue(all(row.get("startedAt") for row in active_rows.values()), "Every active call should report its start time.")
            release_latest.write_text("Finish the newest call first.\n", encoding="utf-8")
            latest_deadline = time.monotonic() + 20
            while "item_fixture_active_long_command" not in completed_rows and time.monotonic() < latest_deadline:
                if process.stdout is not None:
                    readable, _, _ = select.select([process.stdout], [], [], 0.02)
                    if readable:
                        chunk = os.read(process.stdout.fileno(), 65536)
                        stream_buffer.extend(chunk)
                        while b"\n" in stream_buffer:
                            line, _, remainder = stream_buffer.partition(b"\n")
                            stream_buffer = bytearray(remainder)
                            if not line.strip():
                                continue
                            captured_lines.append(line.decode("utf-8"))
                            event = json.loads(line)
                            activity = event.get("payload", {}).get("activity", {})
                            if event.get("type") == "activity" and activity.get("status") in {"completed", "failed"}:
                                completed_rows[activity.get("id")] = activity
            self.assertIn("item_fixture_active_long_command", completed_rows, "The newest command should finish before older active calls.")
            self.assertGreater(completed_rows["item_fixture_active_long_command"].get("durationMs", 0), 0)
            self.assertNotIn("item_fixture_dynamic_call", completed_rows, "Finishing the newest call must leave older calls active.")
            release.write_text("Release tool completions.\n", encoding="utf-8")
            remaining_stdout, remaining_stderr = process.communicate(timeout=60)
            self.assertEqual(process.returncode, 0, f"CLI exit mismatch for {send_command}: {remaining_stderr!r}")
            all_output = "\n".join(captured_lines).encode("utf-8") + b"\n" + remaining_stdout
            response_lines = [line for line in all_output.splitlines() if line.strip()]
            sent = json.loads(response_lines[-1])
            self.assertEqual(sent.get("version"), 1)
            self.assertTrue(sent.get("ok"), sent.get("error"))
        finally:
            if process.poll() is None:
                release_latest.write_text("Release newest call after assertion failure.\n", encoding="utf-8")
                release.write_text("Release tool completions after assertion failure.\n", encoding="utf-8")
                process.communicate(timeout=30)
        result = self.assert_success(sent)
        activities = result["activities"]
        mcp_rows = [row for row in activities if row["id"] == "item_fixture_mcp_call"]
        dynamic_rows = [row for row in activities if row["id"] == "item_fixture_dynamic_call"]
        self.assertEqual(len(mcp_rows), 1)
        self.assertEqual(len(dynamic_rows), 1)
        self.assertEqual(mcp_rows[0]["status"], "completed")
        self.assertEqual(mcp_rows[0]["server"], "fixture-server")
        self.assertEqual(mcp_rows[0]["tool"], "lookup")
        self.assertIn("Returned 1 result item", mcp_rows[0]["detail"])
        self.assertEqual(dynamic_rows[0]["status"], "failed")
        self.assertEqual(dynamic_rows[0]["durationMs"], 37)
        legacy_rows = [row for row in activities if row["id"] == "item_fixture_dynamic_legacy"]
        self.assertEqual(len(legacy_rows), 1)
        self.assertEqual(legacy_rows[0]["status"], "completed")
        self.assertGreater(legacy_rows[0].get("durationMs", 0), 0)
        self.assertGreater(mcp_rows[0].get("durationMs", 0), 0)
        self.assertIn("Returned 1 result item", legacy_rows[0]["detail"])
        serialized = json.dumps(activities)
        self.assertNotIn("RAW_ARGUMENT_SECRET", serialized)
        self.assertNotIn("RAW_RESULT_SECRET", serialized)
        reloaded_response, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        reloaded_rows = self.assert_success(reloaded_response)["activities"]
        reloaded_mcp = [row for row in reloaded_rows if row["id"] == "item_fixture_mcp_call"]
        reloaded_dynamic = [row for row in reloaded_rows if row["id"] == "item_fixture_dynamic_call"]
        reloaded_legacy = [row for row in reloaded_rows if row["id"] == "item_fixture_dynamic_legacy"]
        self.assertEqual(len(reloaded_mcp), 1)
        self.assertEqual(len(reloaded_dynamic), 1)
        self.assertEqual(len(reloaded_legacy), 1)
        self.assertEqual(reloaded_mcp[0]["tool"], "lookup")
        self.assertEqual(reloaded_dynamic[0]["tool"], "summarize")
        self.assertEqual(reloaded_dynamic[0]["durationMs"], 37)
        self.assertGreater(reloaded_legacy[0].get("durationMs", 0), 0)
        self.assertGreater(reloaded_mcp[0].get("durationMs", 0), 0)
        reloaded_serialized = json.dumps(reloaded_rows)
        self.assertNotIn("RAW_ARGUMENT_SECRET", reloaded_serialized)
        self.assertNotIn("RAW_RESULT_SECRET", reloaded_serialized)
        reloaded_result = self.assert_success(reloaded_response)
        self.assertIn("A later turn starts.", [message["text"] for message in reloaded_result["messages"]])

    # case-contract: test_conversation_shows_context_compaction | contextCompaction item/started and item/completed coalesce into one concise timeline event; missing summaries ignore malformed opaque payload fields and never render their data, and the event survives thread history reload with correct prompt/response ordering.
    def test_conversation_shows_context_compaction(self):
        task_id = self.create_task(title="Context compaction")["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-context-compaction"
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-codex-fixture-owner").write_text(
            "StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        env = {"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable), "STATIONAI_FIXTURE_WORKSPACE": str(self.primary)}
        command = ("conversation", "send", task_id, "--message", "Compact the context.")
        process = self.start_cli(*command, extra_environment=env, binary_output=True)
        ready = Path(str(executable) + ".compaction-ready")
        release = Path(str(executable) + ".compaction-release")
        captured, buffer, active = [], bytearray(), []
        try:
            deadline = time.monotonic() + 20
            while (not ready.exists() or not active) and time.monotonic() < deadline:
                if process.stdout is not None:
                    readable, _, _ = select.select([process.stdout], [], [], 0.02)
                    if readable:
                        buffer.extend(os.read(process.stdout.fileno(), 65536))
                        while b"\n" in buffer:
                            line, _, remainder = buffer.partition(b"\n")
                            buffer = bytearray(remainder)
                            if not line.strip():
                                continue
                            captured.append(line.decode("utf-8"))
                            event = json.loads(line)
                            activity = event.get("payload", {}).get("activity", {})
                            if event.get("type") == "activity" and activity.get("isContextCompaction"):
                                active.append(activity)
            self.assertTrue(ready.exists())
            self.assertEqual(len(active), 1)
            self.assertEqual(active[0]["status"], "inProgress")
            release.write_text("Release compaction completion.\n", encoding="utf-8")
            stdout, stderr = process.communicate(timeout=60)
            self.assertEqual(process.returncode, 0, f"CLI exit mismatch for {command}: {stderr!r}")
            sent = json.loads(("\n".join(captured).encode() + b"\n" + stdout).splitlines()[-1])
        finally:
            if process.poll() is None:
                release.write_text("Release compaction after assertion failure.\n", encoding="utf-8")
                process.communicate(timeout=30)
        result = self.assert_success(sent)
        rows = [item for item in result["activities"] if item.get("isContextCompaction")]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["id"], "item_stationai_compaction")
        self.assertEqual(rows[0]["status"], "completed")
        self.assertEqual(rows[0]["detail"], "")
        reloaded_response, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        reloaded = self.assert_success(reloaded_response)
        reloaded_rows = [item for item in reloaded["activities"] if item.get("isContextCompaction")]
        self.assertEqual(len(reloaded_rows), 1)
        self.assertEqual(reloaded_rows[0]["status"], "completed")
        self.assertNotIn("COMPACTION_OPAQUE_SENTINEL", json.dumps(reloaded_rows))
        user = next(item for item in reloaded["messages"] if item.get("role") == "user")
        assistant = next(item for item in reloaded["messages"] if item.get("role") == "assistant")
        self.assertLess(user["timelineOrder"], reloaded_rows[0]["timelineOrder"])
        self.assertLess(reloaded_rows[0]["timelineOrder"], assistant["timelineOrder"])

    # case-contract: test_conversation_loads_newest_messages_before_older_history | Reopening a 120-message conversation immediately presents only the latest user question, pinned to the top of the viewport with its answer below. Scrolling upward loads earlier messages automatically in 40-message batches, including when the latest turn alone is shorter than the viewport, while keeping the anchored message in place and preserving chronological order. No separate control is needed on systems that report scroll position; below macOS 15 the transcript keeps an explicit Load earlier messages control inside that runway instead. A conversation that was empty when it opened establishes no window and keeps the newest 40 messages rendered as they arrive. Reloading history in place reopens on that same latest turn and keeps upward paging working. CLI/XPC history remains complete and ordered across fresh reads and across an in-place provider switch.
    def test_conversation_loads_newest_messages_before_older_history(self):
        task_id = self.create_task(title="Long conversation history")["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-long-history-success"
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-codex-fixture-owner").write_text(
            "StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        env = {"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable), "STATIONAI_FIXTURE_WORKSPACE": str(self.primary)}
        sent, _ = self.call_cli("conversation", "send", task_id, "--message", "Create a long history.", extra_environment=env)
        self.assert_success(sent)
        history_response, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        messages = self.assert_success(history_response)["messages"]
        self.assertEqual(len(messages), 120)
        self.assertEqual(messages[0]["text"], "Long history user 01.")
        self.assertEqual(messages[-1]["text"], "Long history assistant 60.")
        self.assertEqual(
            [message["text"] for message in messages[:4]],
            ["Long history user 01.", "Long history assistant 01.", "Long history user 02.", "Long history assistant 02."],
        )
        fresh_response, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        fresh_messages = self.assert_success(fresh_response)["messages"]
        self.assertEqual([message["text"] for message in fresh_messages], [message["text"] for message in messages])
        # An in-place reload (the provider switch the UI performs without
        # leaving the conversation) must keep the whole transcript available to
        # the window the transcript reopens on.
        switched, _ = self.call_cli("conversation", "provider", task_id, "set", "claude", extra_environment=env)
        self.assertEqual(self.assert_success(switched)["conversationProvider"], "claude")
        reloaded_response, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        reloaded_messages = self.assert_success(reloaded_response)["messages"]
        self.assertEqual([message["text"] for message in reloaded_messages], [message["text"] for message in messages])

    # case-contract: test_conversation_shows_subagent_delegation | During a parent turn, active agents appear as individual named rows outside the collapsed Worked for disclosure, with available path/model/reasoning metadata and started-working wording. When the final answer arrives, all agent rows collapse inside Worked for alongside other Codex activity; expanding it reveals clickable agent rows. The UI fixture pauses after the final answer to verify this before turn completion while Stop response remains available. Completed, interrupted, and unknown states survive history reload and remain inspectable after reopening. The child thread opens as read-only through thread/read, thread/turns/list, and thread/items/list without editable controls or thread/resume, and diagnostics retain safe RPC outcomes while excluding conversation text, command output, and diffs. Multiple Codex message deltas and command-output deltas are summarized per item with counts and byte totals, flushed at turn completion, and excluded from individual notification records; lifecycle notifications remain individually logged, and diagnostics exclude conversation text, command output, and diffs. A fresh `conversation subagent-history` read returns the completed child's stored conversation content.
    def test_conversation_shows_subagent_delegation(self):
        task_id = self.create_task(title="Subagent delegation")["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-subagent"
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-codex-fixture-owner").write_text(
            "StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        env = {
            "STATIONAI_E2E_CODEX_EXECUTABLE": str(executable),
            "STATIONAI_FIXTURE_WORKSPACE": str(self.primary),
        }
        send_command = ("conversation", "send", task_id, "--message", "Delegate this task.")
        process = self.start_cli(*send_command, extra_environment=env, binary_output=True)
        ready = Path(str(executable) + ".subagent-ready")
        release = Path(str(executable) + ".subagent-release")
        captured_lines = []
        stream_buffer = bytearray()
        active_children = {}
        active_updates = []
        try:
            deadline = time.monotonic() + 15
            while (not ready.exists() or len(active_children) < 2) and time.monotonic() < deadline:
                if process.stdout is not None:
                    readable, _, _ = select.select([process.stdout], [], [], 0.02)
                    if readable:
                        chunk = os.read(process.stdout.fileno(), 65536)
                        stream_buffer.extend(chunk)
                        while b"\n" in stream_buffer:
                            line, _, remainder = stream_buffer.partition(b"\n")
                            stream_buffer = bytearray(remainder)
                            if not line.strip():
                                continue
                            captured_lines.append(line.decode("utf-8"))
                            event = json.loads(line)
                            activity = event.get("payload", {}).get("activity", {})
                            child_thread_id = activity.get("childThreadID")
                            if event.get("type") == "activity" and child_thread_id and activity.get("status") == "inProgress":
                                active_children[child_thread_id] = activity
                                active_updates.append(activity)
                time.sleep(0.02)
            self.assertTrue(ready.exists(), "The fixture should expose an active child interval before completion.")
            self.assertEqual(set(active_children), {
                "00000000-0000-0000-0000-000000000002",
                "00000000-0000-0000-0000-000000000003",
            }, "Both child rows should be projected as active XPC events before completion.")
            self.assertIn("gpt-6-sol", active_children["00000000-0000-0000-0000-000000000002"]["detail"])
            self.assertEqual(active_children["00000000-0000-0000-0000-000000000003"]["title"], "Some agent")
            self.assertIn("/agents/some_agent", active_children["00000000-0000-0000-0000-000000000003"]["detail"])
            same_child_updates = [
                activity for activity in active_updates
                if activity.get("childThreadID") == "00000000-0000-0000-0000-000000000002"
            ]
            self.assertEqual(len(same_child_updates), 2, "Started and interacted updates should both target the same active child row.")
            self.assertEqual({activity["id"] for activity in same_child_updates}, {"00000000-0000-0000-0000-000000000002"})
            task_while_active, _ = self.call_cli("task", "get", task_id)
            self.assertEqual(self.assert_success(task_while_active)["status"], "In Progress")
            release.write_text("Release child completion.\n", encoding="utf-8")
            remaining_stdout, remaining_stderr = process.communicate(timeout=60)
            self.assertEqual(process.returncode, 0, f"CLI exit mismatch for {send_command}: {remaining_stderr!r}")
            all_output = "\n".join(captured_lines).encode("utf-8") + b"\n" + remaining_stdout
            response_lines = [line for line in all_output.splitlines() if line.strip()]
            self.assertTrue(response_lines, f"CLI returned no JSON output for {send_command}.")
            sent = json.loads(response_lines[-1])
            self.assertEqual(sent.get("version"), 1)
            self.assertTrue(sent.get("ok"), sent.get("error"))
        finally:
            if process.poll() is None:
                release.write_text("Release child completion after assertion failure.\n", encoding="utf-8")
                process.communicate(timeout=30)
        result = self.assert_success(sent)
        activities = result["activities"]
        subagent = next(activity for activity in activities if activity["title"] == "Task delegated to subagent")
        self.assertEqual(subagent["status"], "completed")
        self.assertIn("Inspect the project structure", subagent["detail"])
        self.assertIn("Inspected the project structure", subagent["detail"])
        children = {activity["childThreadID"]: activity for activity in activities if activity.get("childThreadID")}
        self.assertEqual(set(children), {
            "00000000-0000-0000-0000-000000000002",
            "00000000-0000-0000-0000-000000000003",
            "00000000-0000-0000-0000-000000000004",
        })
        sandbox_review = children["00000000-0000-0000-0000-000000000002"]
        self.assertEqual(sandbox_review["title"], "Sandbox review")
        self.assertEqual(sandbox_review["status"], "completed")
        self.assertIn("/agents/Sandbox review", sandbox_review["detail"])
        self.assertIn("gpt-6-sol", sandbox_review["detail"])
        self.assertIn("high", sandbox_review["detail"])
        docs_review = children["00000000-0000-0000-0000-000000000003"]
        self.assertEqual(docs_review["title"], "Some agent")
        self.assertEqual(docs_review["status"], "interrupted")
        self.assertNotIn("model", docs_review)
        self.assertNotIn("reasoningEffort", docs_review)
        self.assertEqual(children["00000000-0000-0000-0000-000000000004"]["status"], "futureKind")

        diagnostics = self.diagnostic_events()
        delta_summaries = [event for event in diagnostics if event.get("event") == "codex.notification.summary"]
        self.assertTrue(delta_summaries, "Streamed Codex deltas should be summarized rather than logged individually.")
        message_summary = next(event for event in delta_summaries if event.get("method") == "item/agentMessage/delta")
        self.assertGreaterEqual(int(message_summary.get("notificationCount", "0")), 2)
        self.assertGreater(int(message_summary.get("payloadBytes", "0")), 0)
        self.assertEqual(message_summary.get("flushReason"), "turn_completed")
        output_summary = next(event for event in delta_summaries if event.get("method") == "item/commandExecution/outputDelta")
        self.assertEqual(int(output_summary.get("notificationCount", "0")), 2)
        self.assertGreater(int(output_summary.get("payloadBytes", "0")), 0)
        self.assertEqual(output_summary.get("flushReason"), "turn_completed")
        self.assertFalse(any(
            event.get("event") == "codex.notification" and event.get("method") in {
                "item/agentMessage/delta", "item/plan/delta", "item/commandExecution/outputDelta"
            } for event in diagnostics
        ), "High-volume delta notifications should not each occupy a diagnostics record.")
        rpc_start = next(event for event in diagnostics if event.get("event") == "codex.rpc.request.started" and event.get("method") == "turn/start")
        self.assertIn("input", rpc_start.get("parameterNames", ""))
        self.assertTrue(any(
            event.get("event") == "codex.rpc.response.succeeded" and event.get("method") == "turn/start"
            for event in diagnostics
        ))
        command_event = next(
            event for event in diagnostics
            if event.get("event") == "codex.notification"
            and event.get("method") == "item/completed"
            and event.get("itemType") == "commandExecution"
        )
        self.assertEqual(command_event.get("command"), "git status --short")
        self.assertEqual(command_event.get("workingDirectory"), str(self.primary.resolve()))
        self.assertGreater(int(command_event["outputBytes"]), 0)
        file_event = next(
            event for event in diagnostics
            if event.get("event") == "codex.notification"
            and event.get("method") == "item/completed"
            and event.get("itemType") == "fileChange"
        )
        self.assertEqual(file_event.get("changedPathCount"), "1")
        self.assertEqual(file_event.get("changedPaths"), "README.md")
        self.assertEqual(file_event.get("changeKinds"), "update")
        serialized_diagnostics = json.dumps(diagnostics)
        self.assertNotIn("CODEX_OUTPUT_NOT_LOGGED", serialized_diagnostics)
        self.assertNotIn("CODEX_DIFF_NOT_LOGGED", serialized_diagnostics)
        self.assertNotIn("CODEX_STREAMED_OUTPUT_NOT_LOGGED", serialized_diagnostics)
        self.assertNotIn("Delegate this task.", serialized_diagnostics)

        reloaded, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        history = self.assert_success(reloaded)
        self.assertEqual(
            {activity["id"]: activity for activity in history["activities"]},
            {activity["id"]: activity for activity in activities},
        )
        history_children = {activity["childThreadID"]: activity for activity in history["activities"] if activity.get("childThreadID")}
        self.assertEqual(
            {thread_id: activity["status"] for thread_id, activity in history_children.items()},
            {thread_id: activity["status"] for thread_id, activity in children.items()},
        )
        self.assertTrue(any("subagent inspected" in message["text"].lower() for message in history["messages"]))
        inspected = self.assert_success(self.call_cli(
            "conversation", "subagent-history", task_id, "--activity", json.dumps(sandbox_review), extra_environment=env
        )[0])
        self.assertTrue(
            any("found the required profile" in message["text"] for message in inspected["messages"]),
            "A fresh read-only subagent inspection should return the child conversation's stored content.",
        )

    # case-contract: test_plan_mode_renders_markdown_in_conversation | Selecting Plan mode keeps planning active across completed turns and reopening; follow-up instructions start another plan turn, and Start Implementing stays enabled with an empty chat and composer, switches to Code mode, and starts an implementation turn; subsequent composer messages remain Code turns. The plan renders automatically as Markdown with visible spacing, remains selectable and copyable as one complete text view, and CLI events and bridge history preserve the exact plan text and latest implementation handoff. Ordered list items stay on separate lines instead of being merged, and a fenced code block renders as a distinct block with its declared language label and a copy action that places its exact source on the pasteboard. Multiple plan deltas are summarized per item with count and byte totals at turn completion, with no per-delta notification records and no plan text in diagnostics. While the first plan is still streaming in, the question that started it stays pinned near the top of the transcript instead of being auto-scrolled past as the answer grows, consistent with the user message preceding its final answer in CLI/XPC history.
    def test_plan_mode_renders_markdown_in_conversation(self):
        task_id = self.create_task(title="Plan mode Markdown", roots=[self.primary])["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-markdown"
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-codex-fixture-owner").write_text(
            "StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        env = {"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)}
        markdown_reply = "## Implementation plan\n\nStart with the **workspace model**.\n\nA separate paragraph confirms readable spacing between plan sections.\n\n- Implementation detail 01: verify the saved conversation state and rendered result\n- Implementation detail 02: verify the saved conversation state and rendered result\n- Implementation detail 03: verify the saved conversation state and rendered result\n- Implementation detail 04: verify the saved conversation state and rendered result\n- Implementation detail 05: verify the saved conversation state and rendered result\n- Implementation detail 06: verify the saved conversation state and rendered result\n- Implementation detail 07: verify the saved conversation state and rendered result\n- Implementation detail 08: verify the saved conversation state and rendered result\n- Implementation detail 09: verify the saved conversation state and rendered result\n- Implementation detail 10: verify the saved conversation state and rendered result\n- Implementation detail 11: verify the saved conversation state and rendered result\n- Implementation detail 12: verify the saved conversation state and rendered result\n- Implementation detail 13: verify the saved conversation state and rendered result\n- Implementation detail 14: verify the saved conversation state and rendered result\n- Implementation detail 15: verify the saved conversation state and rendered result\n- Implementation detail 16: verify the saved conversation state and rendered result\n- Implementation detail 17: verify the saved conversation state and rendered result\n- Implementation detail 18: verify the saved conversation state and rendered result\n- Implementation detail 19: verify the saved conversation state and rendered result\n- Implementation detail 20: verify the saved conversation state and rendered result\n- Implementation detail 21: verify the saved conversation state and rendered result\n- Implementation detail 22: verify the saved conversation state and rendered result\n- Implementation detail 23: verify the saved conversation state and rendered result\n- Implementation detail 24: verify the saved conversation state and rendered result\n- Implementation detail 25: verify the saved conversation state and rendered result\n- Implementation detail 26: verify the saved conversation state and rendered result\n- Implementation detail 27: verify the saved conversation state and rendered result\n- Implementation detail 28: verify the saved conversation state and rendered result\n- Implementation detail 29: verify the saved conversation state and rendered result\n- Final verification: confirm the latest message is visible after reopening\n\n1. First numbered step: capture the baseline state before changes.\n\n2. Second numbered step: apply the fix and confirm there are no regressions.\n\n```javascript\nconsole.log(\"Hello, world!\");\n```"
        sent, events = self.call_cli(
            "conversation", "send", task_id, "--message", "Plan the task.", "--mode", "plan",
            extra_environment=env,
        )
        deltas = [event["payload"]["text"] for event in events if event["type"] == "text_delta"]
        self.assertEqual("".join(deltas), markdown_reply, "The live plan deltas should stream the full plan.")
        delta_positions = [index for index, event in enumerate(events) if event["type"] == "text_delta"]
        final_positions = [index for index, event in enumerate(events) if event["type"] == "assistant_final"]
        self.assertEqual(len(final_positions), 1, "The plan should produce one final assistant event.")
        self.assertLess(max(delta_positions), final_positions[0], "Plan deltas should arrive before completion.")
        self.assertEqual(
            [event["payload"]["text"] for event in events if event["type"] == "assistant_final"],
            [markdown_reply],
            "The completed plan item should publish one final assistant response.",
        )
        messages = self.assert_success(sent)["messages"]
        self.assertTrue(any(message["role"] == "assistant" and message["text"] == markdown_reply
                            and message["phase"] == "final_answer" for message in messages))
        followup, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Revise the plan to clarify the persistence step.", "--mode", "plan",
            extra_environment=env,
        )
        self.assert_success(followup)
        implementation, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Start implementing the plan.", "--mode", "default",
            extra_environment=env,
        )
        implementation_messages = self.assert_success(implementation)["messages"]
        self.assertEqual(implementation_messages[-2]["text"], "Start implementing the plan.")
        continued, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Continue the implementation.", "--mode", "default",
            extra_environment=env,
        )
        continued_messages = self.assert_success(continued)["messages"]
        self.assertEqual(continued_messages[-2]["text"], "Continue the implementation.")
        fixture_history = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
        turn_modes = [turn["conversationMode"] for turn in fixture_history["turns"]
                      if "stationai internal outcome reminder:" not in (turn["userMessage"] or "").lower()]
        self.assertEqual(turn_modes, ["plan", "plan", "default", "default"], "Follow-up planning remains in Plan mode until implementation starts, and later implementation turns remain in Code mode.")
        history, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        reloaded_messages = self.assert_success(history)["messages"]
        self.assertTrue(any(message["role"] == "assistant" and message["text"] == markdown_reply
                            and message["phase"] == "final_answer" for message in reloaded_messages))
        self.assertEqual(reloaded_messages[-1]["role"], "assistant", "The latest response should be last in bridge history.")
        plan_diagnostics = self.diagnostic_events()
        plan_summary = next(event for event in plan_diagnostics
                            if event.get("event") == "codex.notification.summary"
                            and event.get("method") == "item/plan/delta")
        self.assertGreaterEqual(int(plan_summary.get("notificationCount", "0")), 2)
        self.assertGreater(int(plan_summary.get("payloadBytes", "0")), 0)
        self.assertEqual(plan_summary.get("flushReason"), "turn_completed")
        self.assertFalse(any(event.get("event") == "codex.notification" and event.get("method") == "item/plan/delta"
                             for event in plan_diagnostics))
        self.assertNotIn(markdown_reply, json.dumps(plan_diagnostics))

    # case-contract: test_conversation_mode_rejects_unknown_mode_without_starting_a_turn | The composer keeps the committed model and effort stable while the picker is open, then updates when it is dismissed. Its popover lists provider models and includes an accessible discrete effort slider with Low, Medium, High, and Extra High choices, constrained by model-reported effort support when available; the visible opaque white knob has no focus border, the 6-point track is visibly thick, and the slider responds to dragging and keyboard arrows. The selected model is global across conversations for the active provider, persists through fresh CLI/XPC reads and reopening, and remains isolated between providers; a saved per-conversation model migrates into the global preference on first read; effort persists per conversation. Malformed model IDs and unsupported efforts are rejected without replacing prior choices. The UI opens a second conversation and shows the global model selection; unsupported modes and malformed model IDs are rejected before creating history.
    def test_conversation_mode_rejects_unknown_mode_without_starting_a_turn(self):
        title = "Conversation mode validation"
        task_id = self.create_task(title=title)["id"]
        response, _ = self.call_cli("conversation", "models", task_id)
        models = self.assert_success(response)["models"]
        self.assertTrue(models)
        self.assertTrue(all(model.get("id") and model.get("name") for model in models))
        selected_model_id = models[0]["id"]
        legacy_data = json.dumps({"codex": selected_model_id}).encode("utf-8")
        with sqlite3.connect(self.data_directory / "StationAI-v2.store") as database:
            seeded = database.execute(
                "UPDATE ZBOARDTASK SET ZCONVERSATIONMODELIDSDATA = ? WHERE ZTITLE = ?",
                (legacy_data, title),
            )
            self.assertEqual(seeded.rowcount, 1, "Seed the real SwiftData row with its pre-global provider model.")
        self.assertEqual(
            self.assert_success(self.call_cli("conversation", "model", task_id)[0])["modelID"],
            selected_model_id,
            "The first read should migrate the existing per-conversation model to the global preference.",
        )
        global_model_id = next(model["id"] for model in models if model["id"] != selected_model_id)
        self.assertEqual(self.assert_success(self.call_cli("conversation", "model", task_id, "set", global_model_id)[0])["modelID"], global_model_id)
        self.assertEqual(self.assert_success(self.call_cli("conversation", "model", task_id)[0])["modelID"], global_model_id)
        second_task_id = self.create_task(title="Global model selection")['id']
        self.assertEqual(
            self.assert_success(self.call_cli("conversation", "model", second_task_id)[0])["modelID"],
            global_model_id,
            "A model selected in one conversation should be the global choice in another conversation.",
        )
        invalid_model, _ = self.call_cli("conversation", "model", task_id, "set", "bad model!", expected_status=2)
        self.assert_failure(invalid_model, "invalid_argument")
        self.assertEqual(self.assert_success(self.call_cli("conversation", "model", task_id)[0])["modelID"], global_model_id)
        self.assertEqual(self.assert_success(self.call_cli("conversation", "effort", task_id)[0])["effort"], "medium")
        self.assertEqual(self.assert_success(self.call_cli("conversation", "effort", task_id, "set", "xhigh")[0])["conversationEffort"], "xhigh")
        self.assertEqual(self.assert_success(self.call_cli("conversation", "effort", task_id)[0])["effort"], "xhigh")
        invalid_effort, _ = self.call_cli("conversation", "effort", task_id, "set", "ultra", expected_status=2)
        self.assert_failure(invalid_effort, "invalid_argument")
        self.assertEqual(self.assert_success(self.call_cli("conversation", "effort", task_id)[0])["effort"], "xhigh")

        response, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Hello", "--mode", "unsupported", expected_status=2
        )
        self.assert_failure(response, "invalid_argument")
        self.assertIn("Valid modes: default, plan", response["error"]["message"])
        response, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Hello", "--model", "invalid model!", expected_status=2
        )
        self.assert_failure(response, "invalid_argument")
        self.assertIn("Model ID must contain only", response["error"]["message"])
        history, _ = self.call_cli("conversation", "history", task_id)
        self.assertEqual(self.assert_success(history)["messages"], [])
        self.assertEqual(self.assert_success(history)["activities"], [])


    # case-contract: test_conversation_models_cache_and_refresh | Codex and Claude filtered model lists persist across fresh CLI/XPC requests; an unavailable workspace fails refresh without clearing the previous cache. The visible Claude picker shows the seeded cached option before replacing it with the filtered versioned provider list, and retains an offline cached option when the provider executable is unavailable.
    def test_conversation_models_cache_and_refresh(self):
        codex_fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        codex_executable = self.data_directory / "codex-fixture-model-cache"
        shutil.copyfile(codex_fixture, codex_executable)
        codex_executable.chmod(0o755)
        (self.data_directory / ".stationai-codex-fixture-owner").write_text(
            "StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        codex_environment = {"STATIONAI_E2E_CODEX_EXECUTABLE": str(codex_executable)}
        task_id = self.create_task(title="Codex model cache")["id"]
        response, _ = self.call_cli("conversation", "models", task_id, extra_environment=codex_environment)
        models = self.assert_success(response)["models"]
        cached, _ = self.call_cli("conversation", "models", task_id, "--cached")
        self.assertEqual(self.assert_success(cached)["models"], models, "A fresh XPC request should read the persisted Codex model cache.")

        claude = self.data_directory / "claude-fixture-model-list"
        shutil.copyfile(Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py", claude)
        claude.chmod(0o755)
        (self.data_directory / ".stationai-claude-fixture-owner").write_text(
            "StationAI test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        claude_environment = {"STATIONAI_E2E_CLAUDE_EXECUTABLE": str(claude)}
        claude_task, _ = self.call_cli("task", "create", "--title", "Claude model cache", "--root", self.primary, "--provider", "claude")
        claude_task_id = self.assert_success(claude_task)["id"]
        first_claude_models, _ = self.call_cli("conversation", "models", claude_task_id, extra_environment=claude_environment)
        first_claude_models = self.assert_success(first_claude_models)["models"]
        self.assertEqual([model["id"] for model in first_claude_models], ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-4-6"])
        self.assertNotIn("default", [model["id"] for model in first_claude_models])
        cached_claude_models, _ = self.call_cli("conversation", "models", claude_task_id, "--cached")
        self.assertEqual(self.assert_success(cached_claude_models)["models"], first_claude_models)
        refreshed_claude_models, _ = self.call_cli("conversation", "models", claude_task_id, extra_environment=claude_environment)
        refreshed_claude_models = self.assert_success(refreshed_claude_models)["models"]
        self.assertEqual([model["id"] for model in refreshed_claude_models], ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-4-6"])
        persisted_claude_models, _ = self.call_cli("conversation", "models", claude_task_id, "--cached")
        self.assertEqual(self.assert_success(persisted_claude_models)["models"], refreshed_claude_models)

        unavailable_root = self.data_directory / "claude-model-cache-unavailable-root"
        unavailable_root.mkdir()
        root_owner_marker = unavailable_root / ".stationai-test-owner"
        root_owner_value = "StationAI model cache test owns this workspace root.\n"
        root_owner_marker.write_text(root_owner_value, encoding="utf-8")
        unavailable_task, _ = self.call_cli(
            "task", "create", "--title", "Unavailable Claude model root", "--root", unavailable_root, "--provider", "claude"
        )
        unavailable_task_id = self.assert_success(unavailable_task)["id"]
        initial_unavailable_models, _ = self.call_cli("conversation", "models", unavailable_task_id, extra_environment=claude_environment)
        initial_unavailable_models = self.assert_success(initial_unavailable_models)["models"]
        self.assertEqual(initial_unavailable_models, refreshed_claude_models)
        self.assertEqual(root_owner_marker.read_text(encoding="utf-8"), root_owner_value)
        shutil.rmtree(unavailable_root)
        failed_refresh, _ = self.call_cli("conversation", "models", unavailable_task_id, expected_status=1, extra_environment=claude_environment)
        self.assertFalse(failed_refresh.get("ok"), "An unavailable workspace must fail discovery instead of clearing cached models.")
        retained_after_failure, _ = self.call_cli("conversation", "models", unavailable_task_id, "--cached")
        self.assertEqual(self.assert_success(retained_after_failure)["models"], initial_unavailable_models)

    # case-contract: test_conversation_models_keep_newest_version_per_family | The model picker removes the Default entry, superseded aliases, older versions, and duplicate snapshots, keeping only the newest concrete version in each family. GPT-6 Luna replaces GPT-5.6 Luna, and Claude Opus 5.5 replaces the Opus alias and older snapshots. Alias-only Claude entries are omitted. The shared CLI/XPC list applies the same filtering to Codex and Claude, and the visible picker matches the Codex list. The model popover opens above its composer control.
    def test_conversation_models_keep_newest_version_per_family(self):
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-model-versions"
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-codex-fixture-owner").write_text(
            "StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        environment = {"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)}
        task_id = self.create_task(title="Model versions")["id"]
        models = self.assert_success(self.call_cli("conversation", "models", task_id, extra_environment=environment)[0])["models"]
        self.assertEqual([model["id"] for model in models], ["gpt-6-luna", "gpt-6-sol", "gpt-6-mini"])
        self.assertNotIn("gpt-5.6-luna", [model["id"] for model in models])

        # The same shared filter removes Claude's Default/Opus aliases and collapses dated duplicates.
        claude_fixture = Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py"
        claude_executable = self.data_directory / "claude-fixture-model-versions"
        shutil.copyfile(claude_fixture, claude_executable)
        claude_executable.chmod(0o755)
        (self.data_directory / ".stationai-claude-fixture-owner").write_text(
            "StationAI test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        claude_environment = {"STATIONAI_E2E_CLAUDE_EXECUTABLE": str(claude_executable)}
        created, _ = self.call_cli("task", "create", "--title", "Claude model versions", "--root", self.primary, "--provider", "claude")
        claude_task_id = self.assert_success(created)["id"]
        claude_models = self.assert_success(
            self.call_cli("conversation", "models", claude_task_id, extra_environment=claude_environment)[0]
        )["models"]
        self.assertEqual(
            [model["id"] for model in claude_models],
            ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-4-6"],
        )
        aliases_fixture = self.data_directory / "claude-fixture-model-versions-aliases-only"
        shutil.copyfile(claude_fixture, aliases_fixture)
        aliases_fixture.chmod(0o755)
        aliases_only = self.assert_success(self.call_cli(
            "conversation", "models", claude_task_id,
            extra_environment={"STATIONAI_E2E_CLAUDE_EXECUTABLE": str(aliases_fixture)},
        )[0])["models"]
        self.assertEqual(aliases_only, [], "Claude aliases should not be exposed without a concrete versioned choice.")

    # case-contract: test_conversation_effort_dispatches_to_codex | The selected effort persists through CLI/XPC reads and reaches Codex turn/start collaborationMode.settings.reasoningEffort; a model's advertised effort limit rejects unsupported requests before history is created. The UI selects Extra High and sends a Sol turn, then simulates a legacy transcript with no Codex turn metadata and sends a Luna turn; the old reply remains provider-only and the new reply is attributed to Luna. The latest reply shows its provider timestamp, while a legacy history item without createdAt has no timestamp label.
    def test_conversation_effort_dispatches_to_codex(self):
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-effort-unique-turns-success"
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-codex-fixture-owner").write_text(
            "StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        environment = {"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)}
        task_id = self.create_task(title="Codex effort dispatch")["id"]
        models = self.assert_success(self.call_cli("conversation", "models", task_id, extra_environment=environment)[0])["models"]
        limited_model = next(model for model in models if model["id"] == "gpt-6-mini")
        self.assertEqual(limited_model["supportedEfforts"], ["low", "medium"])
        self.assert_success(self.call_cli("conversation", "effort", task_id, "set", "xhigh")[0])
        unsupported, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Unsupported effort.", "--model", "gpt-6-mini",
            expected_status=2, extra_environment=environment
        )
        self.assert_failure(unsupported, "invalid_argument")
        self.assertIn("not supported by model 'gpt-6-mini'", unsupported["error"]["message"])
        self.assertEqual(self.assert_success(self.call_cli("conversation", "history", task_id)[0])["messages"], [])
        self.assert_success(self.call_cli("conversation", "model", task_id, "set", "gpt-6-sol")[0])
        self.assertEqual(self.assert_success(self.call_cli("conversation", "model", task_id)[0])["modelID"], "gpt-6-sol",
                          "The selected (non-default) model persists for the UI label to read back.")
        self.assert_success(self.call_cli(
            "conversation", "send", task_id, "--message", "Check Codex effort.", "--model", "gpt-6-sol",
            extra_environment=environment
        )[0])
        history = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
        effort_turn = next(turn for turn in reversed(history["turns"]) if turn.get("userMessage", "").endswith("Check Codex effort."))
        self.assertEqual(effort_turn["reasoningEffort"], "xhigh")
        self.assertEqual(self.assert_success(self.call_cli("conversation", "effort", task_id)[0])["effort"], "xhigh")
        self.assertEqual(self.assert_success(self.call_cli("conversation", "model", task_id)[0])["modelID"], "gpt-6-sol",
                          "Sending a turn must not silently fall back to the default model.")
        transcript_path = self.data_directory / "conversation-transcripts" / f"{task_id.upper()}.json"
        transcript = json.loads(transcript_path.read_text(encoding="utf-8"))
        for segment in transcript["segments"]:
            segment["codexTurnIDs"] = []
            segment.pop("codexTurnModelIDs", None)
        transcript_path.write_text(json.dumps(transcript), encoding="utf-8")
        self.assert_success(self.call_cli("conversation", "model", task_id, "set", "gpt-6-luna")[0])
        self.assert_success(self.call_cli("conversation", "send", task_id, "--message", "Check the next model.", "--model", "gpt-6-luna", extra_environment=environment)[0])
        history = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=environment)[0])
        assistants = [message for message in history["messages"] if message["role"] == "assistant"]
        self.assertGreaterEqual(len(assistants), 2)
        self.assertIsNone(assistants[0].get("modelID"), "Legacy replies without stored model attribution must remain provider-only.")
        self.assertIsNone(assistants[0].get("createdAt"), "Legacy provider history without a timestamp must stay timestamp-free.")
        self.assertEqual(assistants[-1]["modelID"], "gpt-6-luna")
        self.assertEqual(assistants[-1]["createdAt"], "2026-10-26T12:34:00Z")

    # case-contract: test_conversation_effort_dispatches_to_claude | Claude's model picker omits Default and aliases, showing Opus 5.5 as the concrete latest choice. Selecting it changes the prompt and reply label to Claude · Opus 5.5, and later model changes preserve the old reply's model attribution. The selected effort persists through CLI/XPC reads and reaches Claude Code as CLAUDE_CODE_EFFORT_LEVEL; the UI selects Extra High and sends a Claude fixture turn whose recorded environment value is xhigh.
    def test_conversation_effort_dispatches_to_claude(self):
        fixture = Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py"
        executable = self.data_directory / "claude-fixture-effort"
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-claude-fixture-owner").write_text(
            "StationAI test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        environment = {"STATIONAI_E2E_CLAUDE_EXECUTABLE": str(executable)}
        created, _ = self.call_cli("task", "create", "--title", "Claude effort dispatch", "--root", self.primary, "--provider", "claude")
        task_id = self.assert_success(created)["id"]
        self.assert_success(self.call_cli("conversation", "model", task_id, "set", "claude-opus-5-5")[0])
        self.assert_success(self.call_cli("conversation", "effort", task_id, "set", "xhigh")[0])
        self.assert_success(self.call_cli("conversation", "send", task_id, "--message", "Check Claude effort.", "--model", "claude-opus-5-5", extra_environment=environment)[0])
        history = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
        effort_turn = next(turn for turn in reversed(history["turns"]) if turn.get("userText") == "Check Claude effort.")
        self.assertEqual(effort_turn["effort"], "xhigh")
        arguments = effort_turn["arguments"]
        self.assertIn("--model", arguments)
        model_argument_index = arguments.index("--model")
        self.assertEqual(arguments[model_argument_index + 1], "claude-opus-5-5")
        self.assertEqual(self.assert_success(self.call_cli("conversation", "effort", task_id)[0])["effort"], "xhigh")
        self.assert_success(self.call_cli("conversation", "model", task_id, "set", "claude-sonnet-5-5")[0])
        visible = self.assert_success(self.call_cli("conversation", "history", task_id)[0])
        assistant = next(message for message in visible["messages"] if message["role"] == "assistant")
        self.assertEqual(assistant["modelID"], "claude-opus-5-5", "Changing the selected model must not rewrite prior turn attribution.")

    # case-contract: test_thread_goal_lifecycle_persists_through_cli_xpc | CLI/XPC Goal set/get/pause/resume/clear persist the objective and lifecycle state across fresh connections and enable the Goals app-server feature; setting the same active Goal preserves its timer generation, clearing then setting another Goal creates a new generation with a fresh baseline, setting a Goal moves the task to In Progress, and invalid blank objectives preserve the current Goal. The UI restores saved Goals; the opt-in live Codex integration confirms native startup, verifies the first Goal retains its elapsed duration, restores a legacy completion without timing metadata, and confirms a second Goal timer begins near zero; renders each achieved summary as a conversation item that visibly moves with scrolling and is anchored to its completing turn, verifies a later user follow-up appears after the prior achievement through turn completion, and preserves both items and their ordering in the read-only Done archive. Native turn activation is owned by the retained GUI runtime.
    def test_thread_goal_lifecycle_persists_through_cli_xpc(self):
        task_id = self.create_task(title="Durable goal", roots=[self.primary])["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-goal"
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-codex-fixture-owner").write_text(
            "StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        env = {
            "CODEX_HOME": str(self.data_directory / "codex-home"),
            "STATIONAI_E2E_CODEX_EXECUTABLE": str(executable),
        }
        (self.data_directory / "codex-home").mkdir()
        goal_text = "Migrate the project and keep the full test suite green."
        result, _ = self.call_cli("conversation", "goal", task_id, "set", "--text", goal_text, extra_environment=env)
        self.assertEqual(self.assert_success(result)["objective"], goal_text)
        launch_arguments = json.loads(Path(str(executable) + ".launch-args").read_text(encoding="utf-8"))
        self.assertIn("features.goals=true", launch_arguments, "CLI/XPC Goal commands must enable Codex's Goals app-server feature.")
        task, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(task)["status"], "In Progress")
        for action, expected in (("get", "active"), ("pause", "paused"), ("resume", "active")):
            response, _ = self.call_cli("conversation", "goal", task_id, action, extra_environment=env)
            self.assertEqual(self.assert_success(response)["status"], expected)
            reread, _ = self.call_cli("conversation", "goal", task_id, "get", extra_environment=env)
            self.assertEqual(self.assert_success(reread)["objective"], goal_text)
        generation_key = f"stationai.codex.goal-generation.{task_id.upper()}"
        generation_before, _ = self.read_default(generation_key)
        same_goal, _ = self.call_cli("conversation", "goal", task_id, "set", "--text", goal_text, extra_environment=env)
        self.assertEqual(self.assert_success(same_goal)["objective"], goal_text)
        generation_after, _ = self.read_default(generation_key)
        self.assertEqual(generation_after, generation_before, "Setting the same active objective should preserve its timer generation.")
        invalid, _ = self.call_cli("conversation", "goal", task_id, "set", "--text", "   ", expected_status=2, extra_environment=env)
        self.assert_failure(invalid, "invalid_argument")
        current, _ = self.call_cli("conversation", "goal", task_id, "get", extra_environment=env)
        active_goal = self.assert_success(current)
        self.assertEqual(active_goal["objective"], goal_text)
        prior_reported_seconds = float(active_goal.get("timeUsedSeconds") or 0)
        cleared, _ = self.call_cli("conversation", "goal", task_id, "clear", extra_environment=env)
        self.assert_success(cleared)
        current, _ = self.call_cli("conversation", "goal", task_id, "get", extra_environment=env)
        self.assertIsNone(self.assert_success(current))
        cleared_generation = generation_after
        replacement_text = "Build the next feature and keep its timer independent."
        replacement, _ = self.call_cli(
            "conversation", "goal", task_id, "set", "--text", replacement_text, extra_environment=env
        )
        replacement_goal = self.assert_success(replacement)
        self.assertEqual(replacement_goal["objective"], replacement_text)
        replacement_generation, _ = self.read_default(generation_key)
        self.assertNotEqual(replacement_generation, cleared_generation, "A Goal set after clear must receive a fresh timer generation.")
        baseline_key = f"stationai.codex.goal-generation-time-baseline.{task_id.upper()}"
        replacement_baseline, _ = self.read_default(baseline_key)
        replacement_reported_seconds = float(replacement_goal.get("timeUsedSeconds") or 0)
        expected_baseline = prior_reported_seconds if replacement_reported_seconds >= prior_reported_seconds else 0
        self.assertAlmostEqual(float(replacement_baseline), expected_baseline, places=3, msg="A new Goal must use only the prior total when Codex reports cumulative time.")

    def read_default(self, key):
        completed = subprocess.run(
            ["/usr/bin/defaults", "read", self.defaults_suite, key],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, f"Could not read isolated preference {key}: {completed.stderr}")
        return completed.stdout.strip(), completed.stderr

    # case-contract: test_pending_question_repair_restores_thread_owner | A misplaced pending question can be repaired through CLI/XPC only into its owning conversation. Repair rejects a wrong owner and a conflicting destination without mutation, backs up both transcripts, preserves request identity and mode, clears only the misplaced source, and is retryable. Fresh history and the visible UI restore the question only on the original task; answering it clears pending state and the safe response survives reopening. Retrying an interrupted repair after the destination question was answered rejects the stale source without resurrecting the question.
    def test_pending_question_repair_restores_thread_owner(self):
        target = self.create_task("Repair original question", roots=[self.primary])["id"]
        source = self.create_task("Repair misplaced question", roots=[self.secondary])["id"]
        stranger = self.create_task("Repair wrong destination", roots=[self.primary])["id"]
        executable = self.data_directory / "codex-fixture-restart-question"
        shutil.copyfile(Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py", executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-codex-fixture-owner").write_text("StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8")
        env = {"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)}
        failed, _ = self.call_cli("conversation", "send", target, "--message", "Ask a restart-safe question.", "--mode", "plan", expected_status=1, extra_environment=env)
        self.assertFalse(failed["ok"])
        stranger_executable = self.data_directory / "codex-fixture-title-success"
        shutil.copyfile(executable, stranger_executable)
        stranger_executable.chmod(0o755)
        self.assert_success(self.call_cli("conversation", "send", stranger, "--message", "Start another real conversation.", extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(stranger_executable)})[0])
        directory = self.data_directory / "conversation-transcripts"
        destination = directory / f"{target.upper()}.json"
        misplaced = directory / f"{source.upper()}.json"
        original = json.loads(destination.read_text())
        request = original.pop("pendingUserInputRequest")
        destination.write_text(json.dumps(original))
        misplaced.write_text(json.dumps({"version": 1, "segments": [], "turns": [], "pendingUserInputRequest": request}))
        before = (destination.read_bytes(), misplaced.read_bytes())
        rejected, _ = self.call_cli("conversation", "repair-user-input", stranger, "--from-task", source, expected_status=1)
        self.assert_failure(rejected, "invalid_transition")
        self.assertEqual(before, (destination.read_bytes(), misplaced.read_bytes()))
        conflict = dict(request, id="a-different-pending-request")
        original["pendingUserInputRequest"] = conflict
        destination.write_text(json.dumps(original))
        conflict_bytes = destination.read_bytes()
        rejected, _ = self.call_cli("conversation", "repair-user-input", target, "--from-task", source, expected_status=1)
        self.assert_failure(rejected, "invalid_transition")
        self.assertEqual(destination.read_bytes(), conflict_bytes)
        original.pop("pendingUserInputRequest")
        destination.write_text(json.dumps(original))
        repaired, _ = self.call_cli("conversation", "repair-user-input", target, "--from-task", source)
        self.assertEqual(self.assert_success(repaired), request)
        self.assertIsNone(json.loads(misplaced.read_text()).get("pendingUserInputRequest"))
        self.assertEqual(json.loads(destination.read_text())["pendingUserInputRequest"], request)
        backups = list((directory / "question-repair-backups").glob("*/*.json"))
        self.assertEqual(len(backups), 2)
        backup_contents = {p.name: json.loads(p.read_text()) for p in backups}
        self.assertEqual(backup_contents[destination.name], original)
        self.assertEqual(backup_contents[misplaced.name]["pendingUserInputRequest"], request)
        again, _ = self.call_cli("conversation", "repair-user-input", target, "--from-task", source)
        self.assertEqual(self.assert_success(again), request)
        fresh, _ = self.call_cli("conversation", "history", target, extra_environment=env)
        self.assertEqual(self.assert_success(fresh)["pendingUserInputRequest"], request)
        answered, _ = self.call_cli("conversation", "answer-user-input", target, request["id"], "--answer", "color=Green", "--answer", "token=fixture-secret", extra_environment=env)
        self.assertTrue(self.assert_success(answered)["accepted"])
        reopened, _ = self.call_cli("conversation", "history", target, extra_environment=env)
        history = self.assert_success(reopened)
        self.assertIsNone(history.get("pendingUserInputRequest"))
        self.assertTrue(any(item["text"] == "[Response to private answer hidden]" for item in history["messages"]))
        self.assertNotIn("fixture-secret", json.dumps(history))
        self.assertNotIn("Continue this conversation by applying", json.dumps(history))
        # Destination published and answered before a crashed repair cleared source.
        misplaced.write_bytes(before[1])
        retry, _ = self.call_cli("conversation", "repair-user-input", target, "--from-task", source, expected_status=1)
        self.assert_failure(retry, "invalid_transition")
        self.assertIsNone(json.loads(destination.read_text()).get("pendingUserInputRequest"))

    # case-contract: test_codex_questions_can_be_answered_over_cli_xpc | MCP tool/requestUserInput structured questions raised in Plan mode remain in the conversation and move the task to Waiting Response while unanswered; leaving and reopening the conversation preserves the pending question, keyed answers resume the provider turn in In Progress, and the answered turn returns to Waiting Response without an explicit completed outcome. A parallel conversation retains its own question and thread; the original conversation receives and answers a second question in its original Plan mode, and completing either conversation preserves the other pending request.
    def test_codex_questions_can_be_answered_over_cli_xpc(self):
        task_id = self.create_task("Codex questions", roots=[self.primary])["id"]
        other_id = self.create_task("Parallel Codex questions", roots=[self.secondary])["id"]
        executable = self.data_directory / "codex-fixture-question-isolation-plan-slow"
        shutil.copyfile(Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py", executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-codex-fixture-owner").write_text("StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8")
        env = {"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)}
        invalid, _ = self.call_cli("conversation", "send", task_id, "--message", "Ask questions.", "--answer", "color= ", expected_status=2)
        self.assert_failure(invalid, "invalid_argument")

        # Standalone CLI connections have distinct XPC service processes. Exercise
        # the GUI's shared-client topology with unchanged production managers,
        # then read the durable result through the real bundled CLI/XPC.
        root = Path(__file__).resolve().parent.parent
        probe = self.data_directory / "codex-question-ownership-probe"
        core = ["BoardTask", "ConversationSubject", "WorkspaceSupport", "WorkspaceChanges", "CodexAppServerClient",
                "ConversationModel", "ClaudeCodeClient", "ConversationTranscriptStore",
                "StandaloneChatStore", "BridgeCore"]
        command = ["xcrun", "--sdk", "macosx", "swiftc", "-parse-as-library", "-swift-version", "5", "-D", "DEBUG", "-Onone"]
        for framework in ("Foundation", "AppKit", "SwiftUI", "SwiftData", "Combine"):
            command.extend(["-framework", framework])
        command.extend(str(root / "StationAI" / "App" / f"{name}.swift") for name in core)
        command.extend([str(root / "StationAI/Bridge/BridgeContract.swift"),
                        str(root / "scripts/test-codex-question-ownership.swift"), "-o", str(probe)])
        compiled = subprocess.run(command, capture_output=True, text=True, timeout=180)
        self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
        environment = os.environ.copy()
        environment.update({"STATIONAI_DATA_DIRECTORY": str(self.data_directory),
                            "STATIONAI_E2E_WORKTREE_DIRECTORY": str(self.worktree_directory),
                            "STATIONAI_E2E_DEFAULTS_SUITE": self.defaults_suite,
                            "STATIONAI_BRIDGE_SERVICE_NAME": arguments.service_name,
                            "CODEX_HOME": str(self.data_directory / "codex-home"), **env})
        checked = subprocess.run([str(probe), str(self.data_directory), str(executable), task_id, other_id],
                                 capture_output=True, text=True, env=environment, timeout=120)
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
        summary = json.loads(checked.stdout.splitlines()[-1])
        self.assertEqual(summary, {"sharedClientQuestionOwnership": True, "originalQuestions": 2, "parallelQuestions": 1})

        def history(owner):
            return self.assert_success(self.call_cli("conversation", "history", owner, extra_environment=env)[0])

        for owner in (task_id, other_id):
            saved = history(owner)
            self.assertIsNone(saved.get("pendingUserInputRequest"))
            self.assertTrue(any("Answers received: Blue / fixture-secret." in message["text"] for message in saved["messages"]))
            self.assertEqual(self.assert_success(self.call_cli("task", "get", owner)[0])["status"], "Waiting Response")
        saved, _ = self.call_cli("task", "prompt", task_id, "--text", "A follow-up draft.")
        self.assertEqual(self.assert_success(saved)["status"], "Waiting Response")
        self.assertEqual(self.assert_success(saved)["savedPrompt"], "A follow-up draft.")

    # case-contract: test_claude_questions_can_be_answered_after_switching_conversations | Claude AskUserQuestion requests are delivered through the control path and move the task to Waiting Response while pending; the UI renders the question inline, preserves it across conversation switching, and sends a later answer to Claude before the turn ends in Waiting Response.
    def test_claude_questions_can_be_answered_after_switching_conversations(self):
        fixture = Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py"
        executable = self.data_directory / "claude-fixture-question"
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-claude-fixture-owner").write_text(
            "StationAI test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        task, _ = self.call_cli(
            "task", "create", "--title", "Claude question", "--root", self.primary, "--provider", "claude"
        )
        task_id = self.assert_success(task)["id"]
        response, events = self.call_cli(
            "conversation", "send", task_id, "--message", "Ask a structured question.", "--answer", "question-1=Blue",
            extra_environment={"STATIONAI_E2E_CLAUDE_EXECUTABLE": str(executable)},
        )
        result = self.assert_success(response)
        user_input = next(event for event in events if event.get("type") == "user_input")
        request = user_input["payload"]["userInputRequest"]
        self.assertEqual(request["questions"][0]["question"], "Which color should I use?")
        self.assertEqual(user_input["payload"].get("taskStatus"), "Waiting Response")
        self.assertTrue(any(
            event.get("type") == "task_status" and event.get("payload", {}).get("taskStatus") == "In Progress"
            for event in events
        ), "Submitting the answer should resume the active Claude turn.")
        self.assertTrue(any(message["text"] == "Answer received: Blue." for message in result["messages"]))
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["status"], "Waiting Response")

    # case-contract: test_claude_outcome_reminder_rejects_user_questions | A successful Claude turn with an unanswered AskUserQuestion stays In Progress without outcome reminders; after the user answers, the next successful turn receives two hidden CLI outcome requests. Questions raised during those reminders are rejected through Claude's control protocol with completed or waiting-response instructions; both the questions and private rejection instructions stay out of the transcript. The task moves to Waiting Response only after both reminders fail to report an outcome.
    def test_claude_outcome_reminder_rejects_user_questions(self):
        fixture = Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py"
        executable = self.data_directory / "claude-fixture-outcome-reminder-question"
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-claude-fixture-owner").write_text(
            "StationAI test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        task, _ = self.call_cli(
            "task", "create", "--title", "Claude reminder question", "--root", self.primary, "--provider", "claude"
        )
        task_id = self.assert_success(task)["id"]
        initial, initial_events = self.call_cli(
            "conversation", "send", task_id, "--message", "Finish while a structured question remains pending.",
            extra_environment={"STATIONAI_E2E_CLAUDE_EXECUTABLE": str(executable)},
        )
        self.assert_success(initial)
        questions = [event for event in initial_events if event.get("type") == "user_input"]
        self.assertEqual(len(questions), 1, "The successful turn should leave its structured question pending.")
        pending, _ = self.call_cli("conversation", "history", task_id,
                                   extra_environment={"STATIONAI_E2E_CLAUDE_EXECUTABLE": str(executable)})
        pending_history = self.assert_success(pending)
        self.assertIsNotNone(pending_history.get("pendingUserInputRequest"))
        self.assertFalse(any("StationAI internal outcome reminder:" in turn.get("userText", "")
                             for turn in json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))["turns"]))
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["status"], "In Progress")
        request = questions[0]["payload"]["userInputRequest"]
        answered, _ = self.call_cli(
            "conversation", "answer-user-input", task_id, request["id"], "--answer", "question-1=Blue",
            extra_environment={"STATIONAI_E2E_CLAUDE_EXECUTABLE": str(executable)},
        )
        self.assert_success(answered)
        answered_history, _ = self.call_cli("conversation", "history", task_id,
                                            extra_environment={"STATIONAI_E2E_CLAUDE_EXECUTABLE": str(executable)})
        self.assertIsNone(self.assert_success(answered_history).get("pendingUserInputRequest"))
        followup, followup_events = self.call_cli(
            "conversation", "send", task_id, "--message", "Continue after answering.",
            extra_environment={"STATIONAI_E2E_CLAUDE_EXECUTABLE": str(executable)},
        )
        self.assertTrue(self.assert_success(followup)["messages"])
        events = initial_events + followup_events
        self.assertEqual(sum(event.get("type") == "user_input" for event in events), 1,
                         "Questions from private Claude reminders must not be emitted as user input.")
        turns = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))["turns"]
        reminders = [turn for turn in turns if "StationAI internal outcome reminder:" in turn.get("userText", "")]
        self.assertEqual(len(reminders), 2, "Claude must receive the second private reminder after the first question is rejected.")
        self.assertTrue(all("explicitly run the StationAI CLI task outcome command" in turn["userText"] for turn in reminders))
        rejections = Path(str(executable) + ".private-reminder-question-rejection").read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(rejections), 2)
        self.assertTrue(all("waiting-response" in message and "completed" in message for message in rejections))
        history, _ = self.call_cli(
            "conversation", "history", task_id,
            extra_environment={"STATIONAI_E2E_CLAUDE_EXECUTABLE": str(executable)},
        )
        safe_history = self.assert_success(history)
        self.assertIsNone(safe_history.get("pendingUserInputRequest"))
        serialized_history = json.dumps(safe_history)
        self.assertNotIn("Which color should I use?", serialized_history)
        self.assertNotIn("This is a private StationAI outcome reminder.", serialized_history,
                         "Claude's private rejection instructions must not enter persisted conversation history.")
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["status"], "Waiting Response")

    # case-contract: test_claude_empty_question_request_is_rejected | Claude AskUserQuestion requests with no questions are rejected through the control protocol, fail the turn, and mark the task Blocked; the UI shows the blocked task and its intervention indicator.
    def test_claude_empty_question_request_is_rejected(self):
        fixture = Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py"
        executable = self.data_directory / "claude-fixture-empty-question"
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-claude-fixture-owner").write_text(
            "StationAI test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        task, _ = self.call_cli(
            "task", "create", "--title", "Empty Claude question", "--root", self.primary, "--provider", "claude"
        )
        task_id = self.assert_success(task)["id"]
        failed, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Ask an empty structured question.",
            expected_status=1,
            extra_environment={"STATIONAI_E2E_CLAUDE_EXECUTABLE": str(executable)},
        )
        self.assertFalse(failed.get("ok", True), failed)
        self.assertIn("question", failed.get("error", {}).get("message", "").lower())
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["status"], "Blocked")

    # case-contract: test_claude_pending_question_recovers_after_provider_process_restarts | Claude's pending AskUserQuestion is persisted and restored from fresh CLI/XPC history after the provider turn ends; the task remains Waiting Response while unanswered, and answering resumes the saved Claude session in In Progress, delivers the answer, hides the private recovery prompt and redacts secret answers from StationAI history, clears pending state, and returns to Waiting Response.
    def test_claude_pending_question_recovers_after_provider_process_restarts(self):
        fixture = Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py"
        executable = self.data_directory / "claude-fixture-restart-question"
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-claude-fixture-owner").write_text(
            "StationAI test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        task, _ = self.call_cli(
            "task", "create", "--title", "Restart-safe Claude question", "--root", self.primary, "--provider", "claude"
        )
        task_id = self.assert_success(task)["id"]
        failed, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Ask a restart-safe structured question.",
            expected_status=1,
            extra_environment={"STATIONAI_E2E_CLAUDE_EXECUTABLE": str(executable)},
        )
        self.assertFalse(failed.get("ok", True), failed)
        restored, _ = self.call_cli("conversation", "history", task_id)
        restored_history = self.assert_success(restored)
        pending = restored_history.get("pendingUserInputRequest")
        self.assertEqual(pending["questions"][0]["question"], "Which color should I use?")
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["status"], "Waiting Response")
        rejected, _ = self.call_cli(
            "conversation", "answer-user-input", task_id, pending["id"], "--answer", "question-1=",
            expected_status=2,
            extra_environment={"STATIONAI_E2E_CLAUDE_EXECUTABLE": str(executable)},
        )
        self.assertFalse(rejected.get("ok", True), rejected)
        still_pending, _ = self.call_cli("conversation", "history", task_id)
        self.assertEqual(self.assert_success(still_pending).get("pendingUserInputRequest"), pending)
        accepted, _ = self.call_cli(
            "conversation", "answer-user-input", task_id, pending["id"], "--answer", "question-1=Green",
            extra_environment={"STATIONAI_E2E_CLAUDE_EXECUTABLE": str(executable)},
        )
        self.assertTrue(self.assert_success(accepted)["accepted"])
        resumed, _ = self.call_cli("conversation", "history", task_id)
        resumed_history = self.assert_success(resumed)
        self.assertTrue(any(message["text"] == "Recovered answer: Green." for message in resumed_history["messages"]))
        self.assertFalse(any("Answer: Green" in message["text"] for message in resumed_history["messages"]))
        self.assertNotIn("Answer: Green", self.assert_success(self.call_cli("task", "get", task_id)[0]).get("savedPrompt", ""))
        self.assertIsNone(resumed_history.get("pendingUserInputRequest"))
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["status"], "Waiting Response")

    # case-contract: test_claude_pending_plan_mode_question_recovers_in_plan_mode | A Claude AskUserQuestion asked during a Plan mode turn persists its mode; after its provider process ends, answering resumes the saved Claude session in Plan mode rather than silently downgrading to Code mode, relaunching the recovery turn with --permission-mode plan.
    def test_claude_pending_plan_mode_question_recovers_in_plan_mode(self):
        fixture = Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py"
        executable = self.data_directory / "claude-fixture-restart-plan-question"
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-claude-fixture-owner").write_text(
            "StationAI test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        task, _ = self.call_cli(
            "task", "create", "--title", "Restart-safe Claude plan question", "--root", self.primary, "--provider", "claude"
        )
        task_id = self.assert_success(task)["id"]
        failed, _ = self.call_cli(
            "conversation", "send", task_id, "--mode", "plan", "--message", "Ask a restart-safe structured question.",
            expected_status=1,
            extra_environment={"STATIONAI_E2E_CLAUDE_EXECUTABLE": str(executable)},
        )
        self.assertFalse(failed.get("ok", True), failed)
        restored, _ = self.call_cli("conversation", "history", task_id)
        pending = self.assert_success(restored).get("pendingUserInputRequest")
        self.assertEqual(pending["mode"], "plan")
        accepted, _ = self.call_cli(
            "conversation", "answer-user-input", task_id, pending["id"], "--answer", "question-1=Green",
            extra_environment={"STATIONAI_E2E_CLAUDE_EXECUTABLE": str(executable)},
        )
        self.assertTrue(self.assert_success(accepted)["accepted"])
        recovery_history = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
        recovery_arguments = recovery_history["turns"][-1]["arguments"]
        self.assertIn("--permission-mode", recovery_arguments)
        self.assertEqual(
            recovery_arguments[recovery_arguments.index("--permission-mode") + 1],
            "plan",
            "The recovered turn must continue in Plan mode, not silently downgrade to Code mode.",
        )
        resumed, _ = self.call_cli("conversation", "history", task_id)
        self.assertIsNone(self.assert_success(resumed).get("pendingUserInputRequest"))

    # case-contract: test_claude_background_agent_keeps_turn_open_until_resolved | A Claude background Agent/Task call renders a live subagent activity that stays in progress through its launch confirmation and intermediate progress, resolves only once its real completion notification arrives, and keeps the turn open until then instead of settling early. A status-only completion update is not shown as an agent result; the summary-bearing notification is persisted as one normal assistant message in the parent conversation, appears in the visible transcript, and survives fresh CLI/XPC history reads and app reopening without duplication. A failed background agent remains inspectable as a failed activity, and its error summary is not added as an assistant result. When a background agent's notification wakes the parent after its result, the turn stays open through that resumed work, including when the last agent finishes while the woken parent is still streaming, and ends only with the parent's next result, keeping its final answer and both agent reports.
    def test_claude_background_agent_keeps_turn_open_until_resolved(self):
        fixture = Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py"
        executable = self.data_directory / "claude-fixture-background-agent"
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-claude-fixture-owner").write_text(
            "StationAI test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        task, _ = self.call_cli(
            "task", "create", "--title", "Claude background agent", "--root", self.primary, "--provider", "claude"
        )
        task_id = self.assert_success(task)["id"]
        env = {"STATIONAI_E2E_CLAUDE_EXECUTABLE": str(executable)}
        command = ("conversation", "send", task_id, "--message", "Launch a background agent for this turn.")
        pause = Path(str(executable) + ".background-summary-pause")
        ready = Path(str(executable) + ".background-summary-ready")
        release = Path(str(executable) + ".background-summary-release")
        pause.write_text("Pause after status-only completion.\n", encoding="utf-8")
        process = self.start_cli(*command, extra_environment=env, binary_output=True)
        try:
            deadline = time.monotonic() + 20
            while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(ready.exists(), "The fixture should pause after the status-only completion update.")
            self.assertIsNone(
                process.poll(),
                "The CLI send must remain active after Claude returns its parent result but before the background summary notification.",
            )
            interim_history = None
            interim_activity = None
            for _ in range(20):
                interim_response, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
                interim_history = self.assert_success(interim_response)
                interim_activity = next(a for a in interim_history["activities"] if a["childThreadID"] == "toolu_background_agent")
                if interim_activity["status"] == "inProgress":
                    break
                time.sleep(0.05)
            self.assertEqual(interim_activity["status"], "inProgress", "A status-only update must leave the agent active.")
            self.assertIsNone(interim_activity.get("backgroundTaskSummary"))
            self.assertFalse(
                any(message.get("phase") == "subagent_report" for message in interim_history["messages"]),
                "Progress detail must not appear as a completed assistant result before Claude sends its summary.",
            )
            release.write_text("Release summary notification.\n", encoding="utf-8")
            stdout, stderr = process.communicate(timeout=60)
            self.assertEqual(process.returncode, 0, f"CLI exit mismatch for {command}: {stderr!r}")
            output_lines = [line for line in stdout.decode("utf-8").splitlines() if line.strip()]
            self.assertTrue(output_lines, "The CLI should return a final result.")
            response = json.loads(output_lines[-1])
            events = [json.loads(line) for line in output_lines[:-1]]
        finally:
            release.write_text("Release summary after assertion failure.\n", encoding="utf-8")
            if process.poll() is None:
                process.communicate(timeout=30)
        result = self.assert_success(response)
        activity_updates = [
            event["payload"]["activity"] for event in events
            if event.get("type") == "activity" and event["payload"]["activity"].get("childThreadID") == "toolu_background_agent"
        ]
        self.assertGreaterEqual(len(activity_updates), 3, activity_updates)
        # The launch confirmation and the live task_progress update must leave the
        # activity running; only a terminal task_updated/task_notification may
        # resolve it, and once resolved it must not revert to inProgress.
        resolved_index = next(i for i, update in enumerate(activity_updates) if update["status"] != "inProgress")
        self.assertGreater(resolved_index, 0, "The launch confirmation must not resolve the activity: " + str(activity_updates))
        self.assertTrue(
            all(update["status"] == "inProgress" for update in activity_updates[:resolved_index]),
            activity_updates,
        )
        self.assertTrue(
            all(update["status"] == "completed" for update in activity_updates[resolved_index:]),
            activity_updates,
        )
        self.assertEqual(activity_updates[-1]["backgroundTaskID"], "bgtask-fixture-1")
        self.assertEqual(activity_updates[-1]["detail"], "Background check finished.")
        terminal_updates = [update for update in activity_updates if update["status"] == "completed"]
        self.assertTrue(terminal_updates, "The summary-bearing notification should resolve the agent.")
        self.assertEqual(terminal_updates[-1].get("backgroundTaskSummary"), "Background check finished.")
        self.assertTrue(any(message["text"] == "STARTED" for message in result["messages"]))
        history = self.assert_success(self.call_cli("conversation", "history", task_id)[0])
        activity = next(a for a in history["activities"] if a["childThreadID"] == "toolu_background_agent")
        self.assertEqual(activity["status"], "completed")
        self.assertEqual(activity["backgroundTaskID"], "bgtask-fixture-1")
        reports = [message for message in history["messages"] if message.get("phase") == "subagent_report"]
        self.assertEqual(len(reports), 1, "The completed background-agent result should be a single parent conversation message.")
        self.assertEqual(reports[0]["role"], "assistant")
        self.assertEqual(reports[0]["provider"], "claude")
        self.assertEqual(reports[0]["text"], "Background check finished.")
        fresh_history = self.assert_success(self.call_cli("conversation", "history", task_id)[0])
        fresh_reports = [message for message in fresh_history["messages"] if message.get("phase") == "subagent_report"]
        self.assertEqual(fresh_reports, reports, "Fresh XPC reads should preserve one stable result message without duplication.")

        failed_task_response, _ = self.call_cli(
            "task", "create", "--title", "Claude failed background agent", "--root", self.primary, "--provider", "claude"
        )
        failed_task_id = self.assert_success(failed_task_response)["id"]
        failed_send, _ = self.call_cli(
            "conversation", "send", failed_task_id, "--message", "Launch a background agent failure case.",
            extra_environment=env,
        )
        self.assert_success(failed_send)
        failed_history = self.assert_success(self.call_cli("conversation", "history", failed_task_id, extra_environment=env)[0])
        failed_activity = next(a for a in failed_history["activities"] if a["childThreadID"] == "toolu_background_agent")
        self.assertEqual(failed_activity["status"], "failed")
        self.assertEqual(failed_activity["backgroundTaskSummary"], "Background check failed.")
        self.assertFalse(
            any(message.get("phase") == "subagent_report" for message in failed_history["messages"]),
            "A failed agent summary must not be presented as a successful assistant result.",
        )

        wake_task_response, _ = self.call_cli(
            "task", "create", "--title", "Claude woken parent", "--root", self.primary, "--provider", "claude"
        )
        wake_task_id = self.assert_success(wake_task_response)["id"]
        wake_command = ("conversation", "send", wake_task_id, "--message", "Launch background agents wake the parent.")
        wake_pause = Path(str(executable) + ".background-wake-pause")
        wake_ready = Path(str(executable) + ".background-wake-ready")
        wake_release = Path(str(executable) + ".background-wake-release")
        wake_pause.write_text("Pause after the last notification arrives mid-work.\n", encoding="utf-8")
        wake_process = self.start_cli(*wake_command, extra_environment=env, binary_output=True)
        try:
            deadline = time.monotonic() + 20
            while not wake_ready.exists() and wake_process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(wake_ready.exists(), "The fixture should pause after the last notification arrives mid-work.")
            # Settling on the stale earlier result would end the send right after
            # this notification; give that regression time to show.
            settle_deadline = time.monotonic() + 2
            while wake_process.poll() is None and time.monotonic() < settle_deadline:
                time.sleep(0.05)
            self.assertIsNone(
                wake_process.poll(),
                "A parent woken by a background notification must keep the turn open until its next result.",
            )
            wake_release.write_text("Release the woken parent's final answer.\n", encoding="utf-8")
            wake_stdout, wake_stderr = wake_process.communicate(timeout=60)
            self.assertEqual(wake_process.returncode, 0, f"CLI exit mismatch for {wake_command}: {wake_stderr!r}")
        finally:
            wake_release.write_text("Release after assertion failure.\n", encoding="utf-8")
            if wake_process.poll() is None:
                wake_process.communicate(timeout=30)
        wake_lines = [line for line in wake_stdout.decode("utf-8").splitlines() if line.strip()]
        wake_result = self.assert_success(json.loads(wake_lines[-1]))
        self.assertTrue(any(message["text"] == "WAKE FINAL" for message in wake_result["messages"]), wake_result["messages"])
        wake_history = self.assert_success(self.call_cli("conversation", "history", wake_task_id, extra_environment=env)[0])
        wake_texts = [message["text"] for message in wake_history["messages"] if message["role"] == "assistant"]
        self.assertIn("WAKE RESUMED", wake_texts)
        self.assertEqual(
            [message for message in wake_history["messages"] if message["role"] == "assistant" and message.get("phase") != "subagent_report"][-1]["text"],
            "WAKE FINAL",
            "The woken parent's final answer should be the turn's last assistant message.",
        )
        wake_reports = sorted(message["text"] for message in wake_history["messages"] if message.get("phase") == "subagent_report")
        self.assertEqual(wake_reports, ["Reviewer A finished.", "Reviewer B finished."])
        self.assertTrue(
            any(activity["id"] == "toolu_wake_read" for activity in wake_history["activities"]),
            "Tool work the woken parent ran should be recorded in the turn.",
        )

    # case-contract: test_claude_private_recovery_failure_fails_closed | If Claude fails while applying an answer after restart and echoes the answer or recovery instructions, StationAI returns a generic error, preserves the pending question for retry while the task stays in Waiting Response, and keeps the prompt out of history, saved task state, and diagnostics.
    def test_claude_private_recovery_failure_fails_closed(self):
        fixture = Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py"
        executable = self.data_directory / "claude-fixture-recovery-failure"
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-claude-fixture-owner").write_text(
            "StationAI test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        env = {"STATIONAI_E2E_CLAUDE_EXECUTABLE": str(executable)}
        task = self.assert_success(self.call_cli(
            "task", "create", "--title", "Claude private recovery failure", "--root", self.primary, "--provider", "claude"
        )[0])
        task_id = task["id"]
        failed, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Ask a restart-safe structured question.",
            expected_status=1, extra_environment=env,
        )
        self.assertFalse(failed.get("ok", True), failed)
        pending = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=env)[0])["pendingUserInputRequest"]
        Path(str(executable) + ".recovery-error").write_text("StationAI owns this Claude fixture marker.\n", encoding="utf-8")
        recovery_failure, _ = self.call_cli(
            "conversation", "answer-user-input", task_id, pending["id"], "--answer", "question-1=Green",
            expected_status=1, extra_environment=env,
        )
        self.assert_failure(recovery_failure, "operation_failed")
        self.assertEqual(recovery_failure["error"]["message"], "The private answer could not be applied. Please answer the question again.")
        self.assertNotIn("Answer: Green", recovery_failure["error"]["message"])
        history = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=env)[0])
        self.assertIsNotNone(history.get("pendingUserInputRequest"), "The failed answer must remain available for retry.")
        self.assertFalse(any("Answer: Green" in message["text"] or "private recovery prompt" in message["text"].lower() for message in history["messages"]))
        task_record = self.assert_success(self.call_cli("task", "get", task_id, extra_environment=env)[0])
        self.assertEqual(task_record["status"], "Waiting Response", "An unanswered question stays available for retry after a failed recovery attempt.")
        self.assertNotIn("Answer: Green", task_record.get("savedPrompt", ""))
        diagnostics = (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8")
        self.assertNotIn("Answer: Green", diagnostics)
        self.assertNotIn("private recovery prompt", diagnostics.lower())

    # case-contract: test_codex_pending_question_recovers_after_provider_process_restarts | Codex's pending structured question persists after its provider process exits and leaves the task in Waiting Response while unanswered; StationAI restores it from fresh CLI/XPC history, keeps provider switching blocked, requires the user to re-enter the secret once, and applies the answers in one recovery turn. The live recovery stream retains safe assistant text while redacting secret echoes; persisted history hides secret recovery responses, provider activities, and file-change diffs. A later non-sensitive Codex turn keeps its own diff and safe response visible in refreshed CLI/UI history while the earlier secret stays absent. In one task, a no-secret recovery response remains visible after a later secret recovery while the secret response is hidden. Secret answers with surrounding whitespace are still redacted when Codex normalizes its echo; the visible UI shows the safe response immediately and after app restart.
    def test_codex_pending_question_recovers_after_provider_process_restarts(self):
        task_id = self.create_task("Restart-safe Codex question", roots=[self.primary])["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-restart-question"
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-codex-fixture-owner").write_text(
            "StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        env = {"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)}
        failed, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Ask a restart-safe structured question.", expected_status=1,
            extra_environment=env,
        )
        self.assertFalse(failed.get("ok", True), failed)
        pending, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        request = self.assert_success(pending).get("pendingUserInputRequest")
        self.assertEqual([item["id"] for item in request["questions"]], ["color", "token"])
        self.assertTrue(request["questions"][1]["isSecret"])
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["status"], "Waiting Response")
        blocked_switch, _ = self.call_cli("conversation", "provider", task_id, "set", "claude", expected_status=1, extra_environment=env)
        self.assert_failure(blocked_switch, "invalid_transition")
        self.assertEqual(self.assert_success(self.call_cli("conversation", "provider", task_id)[0])["provider"], "codex")
        answer_final, recovery_events = self.call_cli(
            "conversation", "answer-user-input", task_id, request["id"],
            "--answer", "color=Green", "--answer", "token= fixture-secret ", extra_environment=env,
        )
        self.assert_success(answer_final)
        self.assertNotIn("fixture-secret", json.dumps(recovery_events), "Live recovery events must not expose secret-bearing activities or diffs.")
        safe_recovery_answer = "Recovered answer: Green; private token [redacted secret answer] was applied."
        self.assertIn(safe_recovery_answer, json.dumps(recovery_events), "The live recovery stream should retain the safe assistant answer after redacting the re-entered secret.")
        provider_history = Path(str(executable) + ".history").read_text(encoding="utf-8")
        self.assertIn("fixture-secret", provider_history, "The freshly re-entered secret must reach the resumed provider turn.")
        completed, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        completed_history = self.assert_success(completed)
        self.assertIsNone(completed_history.get("pendingUserInputRequest"))
        self.assertTrue(any(
            message["role"] == "assistant" and message["text"] == "[Response to private answer hidden]"
            for message in completed_history["messages"]
        ), "Persisted history should hide the assistant response from a secret recovery turn.")
        self.assertTrue(any(
            message["role"] == "user" and message["text"] == "[Private answer sent after restart]"
            for message in completed_history["messages"]
        ))
        self.assertNotIn("fixture-secret", json.dumps(completed_history), "Secret echoes in Codex activities or diffs must stay hidden too.")
        self.assertFalse(any("fixture-secret" in message["text"] for message in completed_history["messages"]))
        self.assertNotIn("fixture-secret", self.assert_success(self.call_cli("task", "get", task_id)[0]).get("savedPrompt", ""))
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["status"], "Waiting Response")

        follow_up, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Follow up after private recovery.", extra_environment=env,
        )
        self.assert_success(follow_up)
        follow_up_history = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=env)[0])
        self.assertTrue(any(
            message["role"] == "assistant" and message["text"] == "Follow-up after private recovery complete."
            for message in follow_up_history["messages"]
        ), "A normal Codex follow-up after recovery must remain visible in refreshed history.")
        self.assertIn("follow-up-visible-diff", follow_up_history["diff"]["unifiedDiff"],
            "A later non-sensitive Codex turn must retain its own file-change diff.")
        self.assertNotIn("fixture-secret", json.dumps(follow_up_history))

    # case-contract: test_codex_secret_recovery_redaction_fails_closed | When Codex recovery and a later thread-resume/history read error echo the full recovery prompt and answers, StationAI preserves the pending question while the task stays in Waiting Response, uses a generic visible error, and redacts private content from returned history, saved task state, diagnostics, and error text across fresh CLI/XPC reads and app restarts.
    def test_codex_secret_recovery_redaction_fails_closed(self):
        task_id = self.create_task("Fail-closed secret recovery", roots=[self.primary])["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-unassociated-restart-question"
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-codex-fixture-owner").write_text(
            "StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        env = {"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)}
        failed, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Ask a restart-safe structured question.",
            expected_status=1, extra_environment=env,
        )
        self.assertFalse(failed.get("ok", True), failed)
        pending, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        request = self.assert_success(pending).get("pendingUserInputRequest")
        self.assertIsNotNone(request)
        Path(str(executable) + ".provider-error-async").write_text(
            "StationAI owns this Codex fixture failure marker.\n", encoding="utf-8"
        )
        recovery_failure, _ = self.call_cli(
            "conversation", "answer-user-input", task_id, request["id"],
            "--answer", "color=Green", "--answer", "token=fixture-secret",
            expected_status=1, extra_environment=env,
        )
        self.assert_failure(recovery_failure, "operation_failed")
        self.assertNotIn("fixture-secret", recovery_failure["error"]["message"])
        self.assertNotIn("Answer: Green", recovery_failure["error"]["message"])

        fresh_history, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        history = self.assert_success(fresh_history)
        self.assertIsNotNone(history.get("pendingUserInputRequest"), "The failed recovery must leave the question available to retry.")
        self.assertTrue(any(
            message["role"] == "user" and message["text"] == "[Private answer sent after restart]"
            for message in history["messages"]
        ))
        self.assertFalse(any("fixture-secret" in message["text"] for message in history["messages"]))
        record = self.assert_success(self.call_cli("task", "get", task_id)[0])
        self.assertEqual(record["status"], "Waiting Response", "An unanswered question stays available for retry after a failed recovery attempt.")
        self.assertNotIn("fixture-secret", record.get("statusMessage", ""))
        self.assertNotIn("fixture-secret", record.get("savedPrompt", ""))
        diagnostics = (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8")
        self.assertNotIn("fixture-secret", diagnostics)
        self.assertNotIn("Answer: Green", diagnostics)
        Path(str(executable) + ".history-error").write_text(
            "StationAI owns this Codex fixture history failure marker.\n", encoding="utf-8"
        )
        history_failure, _ = self.call_cli(
            "conversation", "history", task_id, expected_status=1, extra_environment=env
        )
        self.assert_failure(history_failure, "operation_failed")
        self.assertNotIn("fixture-secret", history_failure["error"]["message"])
        diagnostics = (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8")
        self.assertNotIn("fixture-secret", diagnostics)
        Path(str(executable) + ".history-error").unlink()
        # A resume failure needs a provider that has to load the thread again.
        self.restart_provider(executable)
        Path(str(executable) + ".resume-error").write_text(
            "StationAI owns this Codex fixture resume failure marker.\n", encoding="utf-8"
        )
        resume_failure, _ = self.call_cli(
            "conversation", "history", task_id, expected_status=1, extra_environment=env
        )
        self.assert_failure(resume_failure, "operation_failed")
        self.assertEqual(
            resume_failure["error"]["message"],
            "History for a private recovery conversation could not be loaded.",
        )
        diagnostics = (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8")
        self.assertNotIn("fixture-secret", diagnostics)

    # case-contract: test_codex_empty_question_request_is_rejected | A failed turn preserves its blocked reason and appears in the compact Blocked section above Backlog with a user-intervention indication; retrying clears that section, and the successful retry returns to Waiting Response without an explicit completed outcome.
    def test_codex_empty_question_request_is_rejected(self):
        task_id = self.create_task("Empty Codex questions", roots=[self.primary])["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-empty"
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-codex-fixture-owner").write_text(
            "StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        env = os.environ.copy()
        env.update({
            "STATIONAI_DATA_DIRECTORY": str(self.data_directory),
            "STATIONAI_E2E_WORKTREE_DIRECTORY": str(self.worktree_directory),
            "STATIONAI_E2E_DEFAULTS_SUITE": self.defaults_suite,
            "STATIONAI_BRIDGE_SERVICE_NAME": arguments.service_name,
            "STATIONAI_E2E_CODEX_EXECUTABLE": str(executable),
        })
        completed = subprocess.run(
            [str(arguments.cli), "conversation", "send", task_id, "--message", "Please ask your questions."],
            check=False, capture_output=True, text=True, env=env, timeout=90,
        )
        self.assertEqual(completed.returncode, 1, completed.stdout + completed.stderr)
        lines = [json.loads(line) for line in completed.stdout.splitlines() if line.strip()]
        self.assertTrue(lines and not lines[-1].get("ok"), completed.stdout)
        self.assertIn("question response", lines[-1].get("error", {}).get("message", "").lower())
        task, _ = self.call_cli("task", "get", task_id)
        blocked = self.assert_success(task)
        self.assertEqual(blocked["status"], "Blocked")
        self.assertIn("question response", (blocked.get("statusMessage") or "").lower())
        retry_executable = self.data_directory / "codex-fixture-retry"
        shutil.copyfile(fixture, retry_executable)
        retry_executable.chmod(0o755)
        retry, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Retry this task.",
            "--answer", "color=Blue", "--answer", "token=fixture-secret",
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(retry_executable)},
        )
        self.assertTrue(self.assert_success(retry)["messages"])
        task, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(task)["status"], "Waiting Response")

    # case-contract: test_codex_nonblocking_question_keeps_task_in_progress | Non-blocking structured questions render inline, remain pending after switching to another conversation, and keep the task In Progress through fresh CLI/XPC history reconciliation after provider exit until answered. Free-text questions expose a selectable Other choice, select it when text is entered, keep it exclusive of listed answers, and deliver the free-text answer through CLI/XPC and visible UI. Answering resumes the provider turn without outcome reminders while its own pending question is still being resolved; the resumed turn returns to Waiting Response once the pending question clears, and the recovered secret answer stays redacted everywhere.
    def test_codex_nonblocking_question_keeps_task_in_progress(self):
        task_id = self.create_task("Non-blocking question", roots=[self.primary])["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-nonblocking-restart-question"
        (self.data_directory / ".stationai-codex-fixture-owner").write_text(
            "StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        env = {"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)}
        failed, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Ask non-blocking questions.",
            expected_status=1, extra_environment=env,
        )
        self.assertFalse(failed.get("ok", True), failed)
        self.assertEqual(
            self.assert_success(self.call_cli("task", "get", task_id)[0])["status"], "In Progress",
            "A saved non-blocking question keeps the task In Progress as soon as the provider exits.",
        )
        restored, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        history = self.assert_success(restored)
        request = history.get("pendingUserInputRequest")
        self.assertIsNotNone(request, "The unanswered non-blocking question must survive provider exit.")
        self.assertFalse(request["isBlocking"])
        self.assertTrue(request["questions"][0]["allowsOther"])
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["status"], "In Progress")
        accepted, events = self.call_cli(
            "conversation", "answer-user-input", task_id, request["id"],
            "--answer", "color=Custom approach", "--answer", "token=fixture-secret", extra_environment=env,
        )
        self.assertTrue(self.assert_success(accepted)["accepted"])
        completed, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        completed_history = self.assert_success(completed)
        self.assertIsNone(completed_history.get("pendingUserInputRequest"))
        self.assertTrue(any(
            message["role"] == "user" and message["text"] == "[Private answer sent after restart]"
            for message in completed_history["messages"]
        ))
        self.assertTrue(any(
            message["role"] == "assistant" and message["text"] == "[Response to private answer hidden]"
            for message in completed_history["messages"]
        ))
        self.assertNotIn("fixture-secret", json.dumps(completed_history))
        provider_history = Path(str(executable) + ".history").read_text(encoding="utf-8")
        self.assertIn("Custom approach", provider_history, "The free-text Other answer must reach the recovered Codex turn.")
        task, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(task)["status"], "Waiting Response")
        fixture_turns = json.loads(provider_history)["turns"]
        reminders = [turn for turn in fixture_turns if "StationAI internal outcome reminder:" in turn.get("userMessage", "")]
        self.assertEqual(len(reminders), 0, "A pending question still being resolved during the recovered turn must suppress private outcome reminders.")
        self.assertFalse(any(event.get("type") == "user_input" for event in events), "Questions from private reminders must not be emitted as user input.")

    # case-contract: test_codex_async_questions_render_and_reply_as_followup | Async agentMessage questions retain choices and a free-text prompt in live updates and fresh CLI/XPC history, retain accepted-turn model attribution during an active history reload, stay separate from later assistant text, and receive validated answers through the shared manager during and after an active turn. The UI shows inline answer cards instead of raw bullet text, blocks incomplete answers, preserves answered cards across reopening, and displays both submitted answers and responses.
    def test_codex_async_questions_render_and_reply_as_followup(self):
        task_id = self.create_task("Async Codex question", roots=[self.primary])["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-async-question"
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-codex-fixture-owner").write_text(
            "StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        env = {"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)}
        process = self.start_cli("conversation", "send", task_id, "--message", "Ask an async question.", extra_environment=env)
        ready = Path(str(executable) + ".question-ready")
        deadline = time.monotonic() + 20
        while not ready.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(ready.exists(), "The fixture must hold the first turn open for a real steer.")
        reloaded, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        live_history = self.assert_success(reloaded)
        question = next(message for message in live_history["messages"] if message["id"] == "item_stationai_async_question")
        self.assertEqual(question.get("modelID"), "gpt-6-luna", "Fresh history must read the accepted active turn and its model attribution.")
        invalid, _ = self.call_cli("conversation", "answer-async", task_id, question["id"], "--answer", "Yes, update paired tests and run required verification", expected_status=2, extra_environment=env)
        self.assertEqual(invalid["error"]["code"], "invalid_argument")
        reply = "Test and verify: Yes, update paired tests and run required verification\nAdditional detail: Keep the draft intact."
        answer, _ = self.call_cli("conversation", "answer-async", task_id, question["id"], "--answer", "Yes, update paired tests and run required verification", "--answer", "Keep the draft intact.", extra_environment=env)
        self.assertEqual(self.assert_success(answer), {"text": reply, "queued": False})
        first, events = self.finish_cli(process, "conversation send")
        history = self.assert_success(first)
        question = next(message for message in history["messages"] if message["id"] == question["id"])
        self.assertEqual(question["asyncQuestions"], [
            {"title": "Test and verify", "options": [
                "Yes, update paired tests and run required verification",
                "No, leave tests and verification for later",
            ]},
            {"title": "Additional detail"},
        ])
        self.assertEqual(question["phase"], "final_answer")
        self.assertEqual(next(message for message in history["messages"] if message["id"] == "item_stationai_async_followup")["text"],
                         "I can continue while you decide.")
        live_questions = [event.get("payload", {}).get("asyncQuestions") for event in events
                          if event.get("type") == "assistant_progress" and event.get("payload", {}).get("itemID") == question["id"]]
        self.assertEqual(live_questions, [question["asyncQuestions"]], "The live bridge update must retain structured choices.")

        reloaded, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        reloaded_history = self.assert_success(reloaded)
        reloaded_question = next(message for message in reloaded_history["messages"] if message["id"] == question["id"])
        self.assertEqual(reloaded_question["asyncQuestions"], question["asyncQuestions"])
        self.assertEqual(reloaded_question["text"], question["text"])
        self.assertEqual(reloaded_history["answeredAsyncQuestionIDs"], [question["id"]])
        self.assertTrue(any(message["role"] == "user" and message["text"] == reply for message in reloaded_history["messages"]))
        self.assertTrue(any("Answers received: " + reply in message["text"] for message in reloaded_history["messages"]))
        saved_fixture = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
        self.assertEqual(saved_fixture["messages"][0]["steeredAnswer"], reply)
        duplicate, _ = self.call_cli("conversation", "answer-async", task_id, question["id"],
                                     "--answer", "No, leave tests and verification for later",
                                     "--answer", "Try to answer again.", expected_status=1, extra_environment=env)
        self.assert_failure(duplicate, "invalid_transition")
        later, _ = self.call_cli("conversation", "answer-async", task_id, "item_stationai_async_later_question",
                                 "--answer", "Finish after the turn.", extra_environment=env)
        self.assertEqual(self.assert_success(later)["text"], "One more check: Finish after the turn.")
        completed, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        completed_history = self.assert_success(completed)
        self.assertEqual(set(completed_history["answeredAsyncQuestionIDs"]),
                         {question["id"], "item_stationai_async_later_question"})
        self.assertTrue(any("Answers received: One more check: Finish after the turn." in message["text"]
                            for message in completed_history["messages"]))

    # case-contract: test_codex_async_question_queued_answer_retries | An async question answered after its turn ends stays Pending when the first follow-up fails, rejects duplicate answers across fresh CLI/XPC connections, and becomes Answered only after an explicit queued retry succeeds. The paired UI keeps the card and queue action visible across reopening and then displays the delivered response. A fresh `conversation answered-async` read lists no answered questions while the answer is pending and lists the question once it is delivered.
    def test_codex_async_question_queued_answer_retries(self):
        task_id = self.create_task("Queued async question", roots=[self.primary])["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-async-question-queued"
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-codex-fixture-owner").write_text(
            "StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        env = {"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)}
        first, _ = self.call_cli("conversation", "send", task_id, "--message", "Ask a queued async question.", extra_environment=env)
        question = next(message for message in self.assert_success(first)["messages"] if message["id"] == "item_stationai_async_question")
        Path(str(executable) + ".fail-next-turn-start").touch()
        answer, _ = self.call_cli("conversation", "answer-async", task_id, question["id"],
                                  "--answer", "Yes, update paired tests and run required verification",
                                  "--answer", "Retry this answer.", extra_environment=env)
        self.assertTrue(self.assert_success(answer)["queued"])
        queued, _ = self.call_cli("conversation", "queue-list", task_id, extra_environment=env)
        queued_item = self.assert_success(queued)[0]
        self.assertEqual(queued_item["state"], "needsAction")
        self.assertEqual(queued_item["asyncQuestionItemID"], question["id"])
        pending, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        self.assertEqual(self.assert_success(pending)["answeredAsyncQuestionIDs"], [])
        self.assertEqual(self.assert_success(self.call_cli("conversation", "answered-async", task_id)[0])["itemIDs"], [])
        duplicate, _ = self.call_cli("conversation", "answer-async", task_id, question["id"],
                                     "--answer", "No, leave tests and verification for later",
                                     "--answer", "Duplicate.", expected_status=1, extra_environment=env)
        self.assert_failure(duplicate, "invalid_transition")
        retried, _ = self.call_cli("conversation", "queue-retry", task_id, queued_item["id"], extra_environment=env)
        self.assertTrue(self.assert_success(retried)["retried"])
        delivered, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        delivered_history = self.assert_success(delivered)
        self.assertEqual(delivered_history["answeredAsyncQuestionIDs"], [question["id"]])
        self.assertEqual(self.assert_success(self.call_cli("conversation", "answered-async", task_id)[0])["itemIDs"], [question["id"]])
        expected_reply = ("Test and verify: Yes, update paired tests and run required verification\n"
                          "Additional detail: Retry this answer.")
        self.assertTrue(any(message["text"] == "Answers received: " + expected_reply
                            for message in delivered_history["messages"]))

    # case-contract: test_codex_interrupted_turn_blocks_with_reason_and_can_retry | Turn start persists In Progress; a genuine interrupted outcome remains Blocked with its reason, while restart recovery returns stale In Progress work to Waiting Response with its prompt and conversation available. A saved prompt whose turn never started returns to Waiting Response with its draft intact and can be continued; a turn running when the window quits cleanly or is killed keeps running in the bridge daemon, stays In Progress with its prompt visible after relaunch, finishes, and allows a follow-up. Interrupted outcomes and diagnostics persist across connections; a new prompt can finish in Review. A queued follow-up remains visible as needing action after interruption, survives reopening, and is dispatched only after an explicit retry; the completed retry becomes the task's latest saved prompt.
    def test_codex_interrupted_turn_blocks_with_reason_and_can_retry(self):
        task_id = self.create_task("Interrupted turn", roots=[self.primary])["id"]
        self.complete_fixture_turn(task_id, message="Create the conversation thread before interruption.")
        queued_text = "Follow up after the interrupted turn."
        queued = self.assert_success(self.call_cli("conversation", "queue", task_id, "--message", queued_text)[0])
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-interrupted"
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-codex-fixture-owner").write_text(
            "StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        interrupted, events = self.call_cli(
            "conversation", "send", task_id, "--message", "Start work that will be interrupted.",
            "--answer", "color=Blue", "--answer", "token=fixture-secret",
            expected_status=1,
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        self.assert_failure(interrupted, "operation_failed")
        started = next(event for event in events if event.get("type") == "started")
        self.assertEqual(started.get("payload", {}).get("taskStatus"), "In Progress")
        task, _ = self.call_cli("task", "get", task_id)
        blocked = self.assert_success(task)
        self.assertEqual(blocked["status"], "Blocked")
        self.assertIn("interrupted", blocked["statusMessage"].lower())
        diagnostic_lines = [
            json.loads(line)
            for line in (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8").splitlines()
        ]
        send_failure = next(
            event for event in diagnostic_lines
            if event.get("event") == "conversation.send.failed" and event.get("taskID") == task_id
        )
        self.assertEqual(send_failure["phase"], "codex-turn")
        self.assertEqual(send_failure["storePath"], str(self.data_directory / "StationAI-v2.store"))
        self.complete_fixture_turn(task_id, executable_name="codex-fixture-retry")
        task, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(task)["status"], "Review")
        retained = self.assert_success(self.call_cli("conversation", "queue-list", task_id)[0])
        self.assertEqual([(item["id"], item["state"]) for item in retained], [(queued["id"], "needsAction")])
        retry_executable = self.data_directory / "codex-fixture-retry-success"
        shutil.copyfile(fixture, retry_executable)
        retry_executable.chmod(0o755)
        retried, _ = self.call_cli(
            "conversation", "queue-retry", task_id, queued["id"],
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(retry_executable)},
        )
        self.assertTrue(self.assert_success(retried)["retried"])
        self.assertEqual(self.assert_success(self.call_cli("conversation", "queue-list", task_id)[0]), [])
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["savedPrompt"], queued_text)

        restart_task = self.create_task("Restart recovery", roots=[self.primary])
        restart_prompt = "Restore this submitted prompt after an unexpected restart."
        saved_prompt, _ = self.call_cli(
            "task", "prompt", restart_task["id"], "--text", restart_prompt,
            "--status", "In Progress", "--submitted", "true",
        )
        self.assertEqual(self.assert_success(saved_prompt)["pendingSubmittedPrompt"], restart_prompt)
        restarted_history, _ = self.call_cli("conversation", "history", restart_task["id"])
        self.assertEqual(self.assert_success(restarted_history)["messages"], [])
        restarted_task, _ = self.call_cli("task", "get", restart_task["id"])
        restarted_record = self.assert_success(restarted_task)
        self.assertEqual(restarted_record["status"], "Waiting Response")
        self.assertIn("restarted", restarted_record["statusMessage"].lower())
        self.assertEqual(restarted_record["savedPrompt"], restart_prompt)
        self.assertIsNone(restarted_record.get("pendingSubmittedPrompt"))
        continued_history = self.complete_fixture_turn(
            restart_task["id"], executable_name="codex-fixture-restart-retry",
            message="Continue the saved work after restart.",
        )
        self.assertTrue(any(
            message["role"] == "user" and message["text"] == "Continue the saved work after restart."
            for message in continued_history["messages"]
        ))
        restarted_task, _ = self.call_cli("task", "get", restart_task["id"])
        self.assertEqual(self.assert_success(restarted_task)["status"], "Review")

        threaded_restart = self.create_task("Thread restart recovery", roots=[self.primary])
        thread_executable = "codex-fixture-thread-restart"
        first_thread_history = self.complete_fixture_turn(
            threaded_restart["id"], executable_name=thread_executable,
            message="Save this conversation before restarting.",
        )
        self.assertTrue(any(
            message["role"] == "user" and message["text"] == "Save this conversation before restarting."
            for message in first_thread_history["messages"]
        ))
        threaded_prompt = "Continue the existing conversation after restart."
        saved_thread_prompt, _ = self.call_cli(
            "task", "prompt", threaded_restart["id"], "--text", threaded_prompt,
            "--status", "In Progress", "--submitted", "true",
        )
        self.assertEqual(self.assert_success(saved_thread_prompt)["pendingSubmittedPrompt"], threaded_prompt)
        recovered_thread_history, _ = self.call_cli(
            "conversation", "history", threaded_restart["id"],
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(self.data_directory / thread_executable)},
        )
        recovered_messages = self.assert_success(recovered_thread_history)["messages"]
        self.assertTrue(any(
            message["role"] == "user" and message["text"] == "Save this conversation before restarting."
            for message in recovered_messages
        ), "Restart recovery should preserve earlier messages from the real Codex thread.")
        recovered_thread, _ = self.call_cli("task", "get", threaded_restart["id"])
        recovered_thread_record = self.assert_success(recovered_thread)
        self.assertEqual(recovered_thread_record["status"], "Waiting Response")
        self.assertIn("closed while this turn was running", recovered_thread_record["statusMessage"].lower())
        self.assertIsNone(recovered_thread_record.get("pendingSubmittedPrompt"))
        continued_thread = self.complete_fixture_turn(
            threaded_restart["id"], executable_name=thread_executable,
            message="Continue the existing conversation after restart.",
        )
        self.assertTrue(any(
            message["role"] == "user" and message["text"] == threaded_prompt
            for message in continued_thread["messages"]
        ))
        recovered_thread, _ = self.call_cli("task", "get", threaded_restart["id"])
        self.assertEqual(self.assert_success(recovered_thread)["status"], "Review")

    # case-contract: test_task_workspace_changes_group_staged_and_unstaged_diffs | The task view lists every file changed from the task branch's recorded base in a Changes section below a collapsed Viewed section, including committed branch changes and current staged, unstaged, and untracked edits, and excluding commits unique to the base branch. Marking a file viewed saves its current contents, stages the file in Git, and adds a Viewed entry that keeps showing the reviewed work from the branch base to that snapshot. Work done after that review is listed again under Changes and diffed against the saved snapshot, so one file can appear in both sections at once; a path with no content in the branch base and no current file is zero net change and is hidden entirely, even with a stale viewed snapshot, rather than showing a ghost entry. Selecting text or JSON files opens a calculated side-by-side diff whose header names the baseline used. Viewed snapshots persist across fresh CLI/XPC connections. Files that aren't current Changes entries, including already-viewed and unknown paths, are rejected by the mark-viewed CLI operation, and the UI offers that action only for Changes entries. Uncommitted filenames are green. Diagnostics record inventory and file-read outcomes without logging file contents.
    def test_task_workspace_changes_group_staged_and_unstaged_diffs(self):
        self.prepare_workspace_changes()
        task_id = self.create_task(title="Workspace changes", roots=[self.changes])["id"]

        response, _ = self.call_cli("task", "changes", "list", task_id)
        inventory = self.assert_success(response)
        unviewed = {entry["path"]: entry for entry in inventory["unviewed"]}
        self.assertEqual(set(unviewed), {"deleted.txt", "shared.txt", "staged-deleted.txt", "staged.txt", "syntax.json", "untracked.txt", "working.txt"})
        self.assertEqual(inventory["viewed"], [])
        self.assertEqual(unviewed["deleted.txt"]["status"], "deleted")
        self.assertEqual(unviewed["untracked.txt"]["status"], "untracked")
        self.assertTrue(unviewed["shared.txt"]["isUncommitted"])
        self.assertFalse(unviewed["shared.txt"]["hasViewedSnapshot"], "A never-viewed file has no saved snapshot baseline.")

        shared = self.assert_success(self.changes_diff(task_id, "shared.txt", "unviewed"))
        self.assertEqual(shared["original"], "Shared baseline.\n")
        self.assertEqual(shared["modified"], "Shared working version.\n")
        syntax = self.assert_success(self.changes_diff(task_id, "syntax.json", "unviewed"))
        self.assertEqual(syntax["original"], '{"value":"baseline"}\n')
        self.assertEqual(syntax["modified"], '{"value":"working version"}\n')
        untracked = self.assert_success(self.changes_diff(task_id, "untracked.txt", "unviewed"))
        self.assertEqual(untracked["original"], "")
        self.assertEqual(untracked["modified"], "Untracked file.\n")
        deleted = self.assert_success(self.changes_diff(task_id, "deleted.txt", "unviewed"))
        self.assertEqual(deleted["original"], "Deleted baseline.\n")
        self.assertEqual(deleted["modified"], "")

        marked, _ = self.call_cli("task", "changes", "mark-viewed", task_id, "--repository", str(self.changes), "--path", "shared.txt")
        self.assertEqual(self.assert_success(marked), {"viewed": True})
        inventory = self.assert_success(self.call_cli("task", "changes", "list", task_id)[0])
        self.assertNotIn("shared.txt", [entry["path"] for entry in inventory["unviewed"]])
        viewed = {entry["path"]: entry for entry in inventory["viewed"]}
        self.assertIn("shared.txt", viewed, "A newly viewed file stays visible in Viewed before it changes again.")
        self.assertTrue(viewed["shared.txt"]["hasViewedSnapshot"])
        viewed_diff = self.assert_success(self.changes_diff(task_id, "shared.txt", "viewed"))
        self.assertEqual(viewed_diff["original"], "Shared baseline.\n", "A viewed entry keeps showing the reviewed work from the branch base.")
        self.assertEqual(viewed_diff["modified"], "Shared working version.\n")
        remark, _ = self.call_cli("task", "changes", "mark-viewed", task_id, "--repository", str(self.changes), "--path", "shared.txt", expected_status=3)
        self.assert_failure(remark, "not_found")

        (self.changes / "shared.txt").write_text("Edited after viewing.\n", encoding="utf-8")
        inventory = self.assert_success(self.call_cli("task", "changes", "list", task_id)[0])
        viewed = {entry["path"]: entry for entry in inventory["viewed"]}
        unviewed = {entry["path"]: entry for entry in inventory["unviewed"]}
        self.assertIn("shared.txt", viewed, "A later edit leaves the reviewed work listed under Viewed.")
        self.assertEqual(viewed["shared.txt"]["statusCode"], "M ", "A snapshot row badges its own state, not the live index state.")
        self.assertEqual(unviewed["shared.txt"]["statusCode"], "M ")
        self.assertIn("shared.txt", unviewed, "A later edit is also listed as a change still to review.")
        self.assertTrue(unviewed["shared.txt"]["isUncommitted"])
        self.assertTrue(unviewed["shared.txt"]["hasViewedSnapshot"])
        unchanged_viewed_diff = self.assert_success(self.changes_diff(task_id, "shared.txt", "viewed"))
        self.assertEqual(unchanged_viewed_diff["original"], "Shared baseline.\n", "The viewed diff is unaffected by work done after the review.")
        self.assertEqual(unchanged_viewed_diff["modified"], "Shared working version.\n")
        pending_diff = self.assert_success(self.changes_diff(task_id, "shared.txt", "unviewed"))
        self.assertEqual(pending_diff["original"], "Shared working version.\n", "A re-edited file diffs against its saved viewed snapshot, not the branch base.")
        self.assertEqual(pending_diff["modified"], "Edited after viewing.\n")

        marked_untracked, _ = self.call_cli("task", "changes", "mark-viewed", task_id, "--repository", str(self.changes), "--path", "untracked.txt")
        self.assertEqual(self.assert_success(marked_untracked), {"viewed": True})
        staged_status = self.run_git(self.changes, "status", "--porcelain", "--", "untracked.txt")
        self.assertEqual(staged_status.strip(), "A  untracked.txt", "Marking a file viewed stages its untracked contents.")
        inventory = self.assert_success(self.call_cli("task", "changes", "list", task_id)[0])
        viewed = {entry["path"]: entry for entry in inventory["viewed"]}
        self.assertIn("untracked.txt", viewed)
        self.assertEqual(viewed["untracked.txt"]["status"], "added")
        new_file_viewed_diff = self.assert_success(self.changes_diff(task_id, "untracked.txt", "viewed"))
        self.assertEqual(new_file_viewed_diff["original"], "")
        self.assertEqual(new_file_viewed_diff["modified"], "Untracked file.\n")
        (self.changes / "untracked.txt").write_text("Untracked file, edited after viewing.\n", encoding="utf-8")
        inventory = self.assert_success(self.call_cli("task", "changes", "list", task_id)[0])
        self.assertIn("untracked.txt", [entry["path"] for entry in inventory["viewed"]])
        unviewed = {entry["path"]: entry for entry in inventory["unviewed"]}
        self.assertIn("untracked.txt", unviewed, "Editing a viewed new file lists it as a change still to review.")
        self.assertEqual(unviewed["untracked.txt"]["status"], "modified")
        untracked_diff = self.assert_success(self.changes_diff(task_id, "untracked.txt", "unviewed"))
        self.assertEqual(untracked_diff["original"], "Untracked file.\n")
        self.assertEqual(untracked_diff["modified"], "Untracked file, edited after viewing.\n")

        marked_deleted, _ = self.call_cli("task", "changes", "mark-viewed", task_id, "--repository", str(self.changes), "--path", "deleted.txt")
        self.assertEqual(self.assert_success(marked_deleted), {"viewed": True})
        inventory = self.assert_success(self.call_cli("task", "changes", "list", task_id)[0])
        viewed = {entry["path"]: entry for entry in inventory["viewed"]}
        self.assertEqual(viewed["deleted.txt"]["status"], "deleted")
        deleted_viewed_diff = self.assert_success(self.changes_diff(task_id, "deleted.txt", "viewed"))
        self.assertEqual(deleted_viewed_diff["original"], "Deleted baseline.\n")
        self.assertEqual(deleted_viewed_diff["modified"], "")
        (self.changes / "deleted.txt").write_text("Recreated after viewing.\n", encoding="utf-8")
        inventory = self.assert_success(self.call_cli("task", "changes", "list", task_id)[0])
        recreated = {entry["path"]: entry for entry in inventory["unviewed"]}
        self.assertIn("deleted.txt", recreated, "Recreating a viewed deleted file lists it as a change still to review.")
        self.assertEqual(recreated["deleted.txt"]["status"], "added")
        self.assertEqual(recreated["deleted.txt"]["statusCode"], "A ")
        viewed = {entry["path"]: entry for entry in inventory["viewed"]}
        self.assertEqual(viewed["deleted.txt"]["status"], "deleted", "The reviewed row keeps reporting the deletion it reviewed.")
        self.assertEqual(viewed["deleted.txt"]["statusCode"], "D ")
        recreated_diff = self.assert_success(self.changes_diff(task_id, "deleted.txt", "unviewed"))
        self.assertEqual(recreated_diff["original"], "")
        self.assertEqual(recreated_diff["modified"], "Recreated after viewing.\n")
        self.assert_failure(self.changes_diff(task_id, "stale.txt", "unviewed", expected_status=3), "not_found")
        stale_mark, _ = self.call_cli("task", "changes", "mark-viewed", task_id, "--repository", str(self.changes), "--path", "stale.txt", expected_status=3)
        self.assert_failure(stale_mark, "not_found")

        # A file that never existed in the branch base, created then renamed away by two
        # separate file operations (not `git mv`, which Git would recognize as one rename),
        # nets to zero change once both the deletion and the replacement are reviewed.
        (self.changes / "ephemeral.txt").write_text("Ephemeral content.\n", encoding="utf-8")
        marked_ephemeral, _ = self.call_cli("task", "changes", "mark-viewed", task_id, "--repository", str(self.changes), "--path", "ephemeral.txt")
        self.assertEqual(self.assert_success(marked_ephemeral), {"viewed": True})
        inventory = self.assert_success(self.call_cli("task", "changes", "list", task_id)[0])
        viewed = {entry["path"]: entry for entry in inventory["viewed"]}
        self.assertEqual(viewed["ephemeral.txt"]["status"], "added")
        (self.changes / "ephemeral.txt").unlink()
        inventory = self.assert_success(self.call_cli("task", "changes", "list", task_id)[0])
        unviewed = {entry["path"]: entry for entry in inventory["unviewed"]}
        self.assertEqual(unviewed["ephemeral.txt"]["status"], "deleted", "Deleting a reviewed new file lists the deletion as a change still to review.")
        marked_ephemeral_deleted, _ = self.call_cli("task", "changes", "mark-viewed", task_id, "--repository", str(self.changes), "--path", "ephemeral.txt")
        self.assertEqual(self.assert_success(marked_ephemeral_deleted), {"viewed": True})
        inventory = self.assert_success(self.call_cli("task", "changes", "list", task_id)[0])
        self.assertNotIn("ephemeral.txt", [entry["path"] for entry in inventory["viewed"]], "A reviewed file with no base content and no current file is zero net change, not a ghost entry.")
        self.assertNotIn("ephemeral.txt", [entry["path"] for entry in inventory["unviewed"]])
        (self.changes / "ephemeral.txt").write_text("Reborn content.\n", encoding="utf-8")
        inventory = self.assert_success(self.call_cli("task", "changes", "list", task_id)[0])
        unviewed = {entry["path"]: entry for entry in inventory["unviewed"]}
        self.assertEqual(unviewed["ephemeral.txt"]["status"], "added", "Recreating the file afterward surfaces it as a fresh change to review.")

        diagnostics = self.diagnostic_events()
        self.assertTrue(any(event.get("event") == "workspace.files.inventory.succeeded" and int(event.get("unviewedCount", "0")) > 0 for event in diagnostics))
        self.assertTrue(any(event.get("event") == "workspace.file.read.succeeded" and event.get("group") == "viewed" for event in diagnostics))
        self.assertTrue(any(event.get("event") == "workspace.file.read.failed" and event.get("path") == "stale.txt" for event in diagnostics))
        self.assertNotIn("Shared working version.", json.dumps(diagnostics))

    # case-contract: test_external_git_edits_and_commit_refresh_workspace_changes | A newly created task branch with no branch or worktree changes starts with empty Viewed and Changes sections. External Git commits unique to the task branch and staged, unstaged, or untracked edits update the open task's Changes sidebar automatically; commits unique to the base branch are excluded. Fresh CLI connections report the same per-file inventory.
    def test_external_git_edits_and_commit_refresh_workspace_changes(self):
        repository = self.data_directory / "external-git"
        repository.mkdir()
        (repository / "tracked.txt").write_text("Baseline.\n", encoding="utf-8")
        self.run_git(repository, "init", "--initial-branch=main")
        self.run_git(repository, "config", "user.name", "StationAI Bridge Test")
        self.run_git(repository, "config", "user.email", "stationai-bridge-test@example.invalid")
        self.run_git(repository, "add", "tracked.txt")
        self.run_git(repository, "commit", "-m", "Baseline")
        task_id = self.create_task(title="External Git", roots=[])["id"]
        added, _ = self.call_cli("task", "repository", "add", task_id, "--repo", str(repository))
        task_record = self.assert_success(added)
        record = next(item for item in task_record["repositoryWorktrees"] if item["repositoryPath"] == str(repository))
        self.assertEqual(record["branchFrom"], "main")
        worktree = Path(record["worktreePath"])

        response, _ = self.call_cli("task", "changes", "list", task_id)
        inventory = self.assert_success(response)
        self.assertEqual(inventory["unviewed"], [])
        self.assertEqual(inventory["viewed"], [])

        (worktree / "tracked.txt").write_text("Branch commit.\n", encoding="utf-8")
        self.run_git(worktree, "add", "tracked.txt")
        self.run_git(worktree, "commit", "-m", "Task branch commit")
        (repository / "base-only.txt").write_text("Base-only commit.\n", encoding="utf-8")
        self.run_git(repository, "add", "base-only.txt")
        self.run_git(repository, "commit", "-m", "Base-only commit")

        response, _ = self.call_cli("task", "changes", "list", task_id)
        inventory = self.assert_success(response)
        entries = {entry["path"]: entry for entry in inventory["unviewed"]}
        self.assertEqual(set(entries), {"tracked.txt"})
        self.assertFalse(entries["tracked.txt"]["isUncommitted"])
        self.assertNotIn("base-only.txt", entries)
        branch_diff = self.assert_success(self.changes_diff(task_id, "tracked.txt", "unviewed", repository=worktree))
        self.assertEqual(branch_diff["original"], "Baseline.\n")
        self.assertEqual(branch_diff["modified"], "Branch commit.\n")

        (worktree / "tracked.txt").write_text("Edited externally.\n", encoding="utf-8")
        (worktree / "untracked.txt").write_text("Untracked external file.\n", encoding="utf-8")
        response, _ = self.call_cli("task", "changes", "list", task_id)
        inventory = self.assert_success(response)
        entries = {entry["path"]: entry for entry in inventory["unviewed"]}
        self.assertEqual(set(entries), {"tracked.txt", "untracked.txt"})
        self.assertTrue(entries["tracked.txt"]["isUncommitted"])
        self.assertTrue(entries["untracked.txt"]["isUncommitted"])
        self.run_git(worktree, "add", "tracked.txt", "untracked.txt")
        self.run_git(worktree, "commit", "-m", "Second task branch commit")
        response, _ = self.call_cli("task", "changes", "list", task_id)
        entries = {entry["path"]: entry for entry in self.assert_success(response)["unviewed"]}
        self.assertEqual(set(entries), {"tracked.txt", "untracked.txt"})
        self.assertFalse(entries["tracked.txt"]["isUncommitted"])
        self.assertNotIn("base-only.txt", entries)



class TimedTestResult(unittest.TextTestResult):
    def startTest(self, test):
        self.case_started = time.monotonic()
        super().startTest(test)

    def stopTest(self, test):
        self.stream.writeln(
            f"E2E case={test._testMethodName} elapsed_seconds={time.monotonic() - self.case_started:.3f}"
        )
        super().stopTest(test)


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(StationAIBridgeTests)
    discovered_cases = [test._testMethodName for test in suite]
    contract_cases = [
        contract["id"] for contract in json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))
    ]
    if len(discovered_cases) != len(set(discovered_cases)):
        raise SystemExit("The bridge suite discovered duplicate test case names.")
    missing = sorted(set(contract_cases) - set(discovered_cases))
    extra = sorted(set(discovered_cases) - set(contract_cases))
    if missing or extra or len(discovered_cases) != len(contract_cases):
        details = []
        if missing:
            details.append(f"missing: {', '.join(missing)}")
        if extra:
            details.append(f"unpaired: {', '.join(extra)}")
        raise SystemExit("Runtime CLI cases do not match the shared contract: " + "; ".join(details))
    selected_cases = arguments.selected_cases
    if len(selected_cases) != len(set(selected_cases)):
        raise SystemExit("Focused bridge test case IDs must be unique.")
    unknown_cases = sorted(set(selected_cases) - set(contract_cases))
    if unknown_cases:
        raise SystemExit("Unknown bridge test case IDs: " + ", ".join(unknown_cases))
    if selected_cases:
        selected = set(selected_cases)
        suite = unittest.TestSuite(
            test for test in suite if test._testMethodName in selected
        )
    test_count = len(selected_cases) if selected_cases else len(contract_cases)
    if test_count == 0:
        raise SystemExit("The bridge suite must execute at least one case.")
    result = unittest.TextTestRunner(verbosity=2, resultclass=TimedTestResult).run(suite)
    if not result.wasSuccessful() or result.testsRun != test_count or result.skipped:
        raise SystemExit("Every discovered bridge test must pass without skips.")
    print(
        f"Bridge suite: total={result.testsRun}, passed={result.testsRun - len(result.failures) - len(result.errors)}, "
        f"skipped={len(result.skipped)}, selected={','.join(selected_cases) if selected_cases else 'all'}"
    )
