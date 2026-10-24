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

    def create_task(self, title="Bridge task", roots=None):
        if roots is None:
            roots = [self.primary]
        command = ["task", "create", "--title", title]
        for root in roots:
            command.extend(["--root", root])
        response, _ = self.call_cli(*command)
        return self.assert_success(response)

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

    def seed_done_task_pull_request(self, task_id, number=123, repository_index=0):
        repository_root = Path(__file__).resolve().parent.parent
        executable = self.data_directory / "seed-task-pr-link"
        subprocess.run(
            [
                "xcrun", "swiftc", "-module-name", "StationAI",
                str(repository_root / "StationAI" / "App" / "BoardTask.swift"),
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

    def changes_diff(self, task_id, path, group, expected_status=0):
        response, _ = self.call_cli(
            "task", "changes", "diff", task_id,
            "--repository", self.changes,
            "--path", path,
            "--group", group,
            expected_status=expected_status,
        )
        return response

    # case-contract: test_service_reports_bridge_version | StationAI opens one main board window titled with its worktree label, shows the Playhouse logo on a solid #2C2F36 background, uses the same artwork for the Dock AppIcon, and the bridge reports API version 1.
    def test_service_reports_bridge_version(self):
        response, _ = self.call_cli("status")
        self.assertEqual(self.assert_success(response), {"bridgeVersion": 1, "service": "StationAI"})
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
        app_info = plistlib.loads((self.cli.parent.parent / "Info.plist").read_bytes())
        service_info = plistlib.loads((self.cli.parent.parent / "XPCServices/StationAIBridge.xpc/Contents/Info.plist").read_bytes())
        self.assertEqual(service_info["CFBundleIdentifier"], app_info["CFBundleIdentifier"] + ".bridge")
        self.assertEqual(service_info["StationAIApplicationBundleIdentifier"], app_info["CFBundleIdentifier"])
        self.assertEqual(arguments.service_name, service_info["CFBundleIdentifier"])

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

    # case-contract: test_task_done_preserves_worktree_and_branch | Sending the first message derives an auto branch from the generated task title, with a prompt fallback when title generation fails. Every linked PR must be merged before the task can move to Done. App focus checks each linked PR no more than once per 10 seconds; rapid focus changes are suppressed. An unmerged PR keeps its link and suppresses the completion button. PR links and the green completion button have hit targets of at least 30×30 points. After all PRs merge, a later focus check replaces their links with a green completion button, whose click waits for the task lock, rechecks merge state, and moves the task to Done. Completion preserves the source branch and worktree without merging into the local target, retains conversation history, and exposes the task in the searchable read-only archive; the CLI searches matching local Codex JSONL session files, including current input_text and output_text message content, without loading conversation histories, while the visible archive searches both user input_text and assistant output_text, loads the newest 40 first, and reveals older tasks as the user scrolls.
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
        gh.write_text(
            "#!/bin/sh\n"
            "if [ \"$1\" != pr ] || [ \"$2\" != view ] || { [ \"$3\" != 123 ] && [ \"$3\" != 456 ]; } || [ \"$4\" != --json ] || [ \"$5\" != mergedAt ]; then\n"
            "  echo 'Unexpected gh fixture command' >&2\n"
            "  exit 2\n"
            "fi\n"
            f"printf '%s\\n' \"$3\" >> '{gh_calls}'\n"
            f"if [ \"$(awk -F= -v number=\"$3\" '$1 == number {{ print $2 }}' '{gh_state}')\" = merged ]; then\n"
            "  printf '{\"mergedAt\":\"2026-10-22T00:00:00Z\"}\\n'\n"
            "else\n"
            "  printf '{\"mergedAt\":null}\\n'\n"
            "fi\n",
            encoding="utf-8",
        )
        gh.chmod(0o755)
        gh_environment = {"PATH": f"{gh_directory}:{os.environ.get('PATH', '')}"}
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

    # case-contract: test_review_pr_conflicts_probe_and_verify | Separate Review task cards probe their linked pull requests concurrently on app focus, with refreshes limited to one per 10 seconds. A conflicting PR or a mergeable PR whose remote head is not pushed locally retains the imported conflict action with its indicator artwork beside its PR link; the UI renders the artwork inside the action, keeps it beside the PR link, and gives both controls hit targets of at least 30×30 points. Clicking the conflict action sends the corrected request in the task conversation. CLI and UI use the same GitHub mergeability and head checks, retry once when resolution remains unconfirmed, and clear the action only after GitHub confirms the pushed head.
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
        self.assertTrue(any(
            event.get("type") == "task_status" and event.get("payload", {}).get("taskStatus") == "In Progress"
            for event in question_events
        ), "Answering the question should resume the task into In Progress.")
        waiting = self.assert_success(self.call_cli("task", "get", waiting_id)[0])
        self.assertEqual(waiting["status"], "Waiting Response")
        self.assertEqual(self.assert_success(self.call_cli("task", "get", blocked_id)[0])["status"], "Blocked")

    # case-contract: test_task_progress_reports_publish_persist_and_clear | The CLI publishes standard and custom progress only during an active task turn, persists each report across fresh CLI/XPC connections, rejects invalid reports, and clears explicitly. During an active turn the CLI accepts completed and waiting-response outcomes, rejects invalid or inactive outcomes, and persists the selected status; provider processes started from the CLI/XPC service or the app's composer inherit that app's bridge service name and store directory, and an outcome reported with exactly that inherited environment reaches the task; without an outcome call, a successful turn ends in Waiting Response. The board shows progress details and places completed tasks in Review and waiting or omitted outcomes in Waiting Response. New threads receive hidden progress and outcome instructions at thread start, and existing threads receive them on resume; turn requests do not repeat the instructions. Those instructions require updates at phase changes, around substantial tools, and at least every 30 seconds during long work. Only an explicit completed outcome reaches Review. When a final answer ends with the outcome command written as text instead of run, the final answer, fresh history, and transcript hide that command, and it counts as the turn's outcome only when it names this task.
    def test_task_progress_reports_publish_persist_and_clear(self):
        task_id = self.create_task("Progress reports", roots=[self.primary])["id"]
        response, _ = self.call_cli("task", "progress", "publish", task_id, "--type", "building", expected_status=1)
        self.assert_failure(response, "invalid_transition")
        inactive_outcome, _ = self.call_cli("task", "outcome", task_id, "completed", expected_status=1)
        self.assert_failure(inactive_outcome, "invalid_transition")

        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-hold-release"
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
            deadline = time.monotonic() + 10
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
                release_marker.write_text("Release the no-outcome turn.\n", encoding="utf-8")
                omitted_stdout, omitted_stderr = omitted_follow_up.communicate(timeout=20)
                self.assertEqual(omitted_follow_up.returncode, 0, f"No-outcome fixture conversation failed: {omitted_stdout}; {omitted_stderr}")
                omitted_record, _ = self.call_cli("task", "get", task_id)
                self.assertEqual(self.assert_success(omitted_record)["status"], "Waiting Response")
            finally:
                if omitted_follow_up.poll() is None:
                    release_marker.write_text("Release the no-outcome turn.\n", encoding="utf-8")
                    omitted_follow_up.communicate(timeout=20)
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
                    release_marker.write_text("Release the echoed-outcome turn.\n", encoding="utf-8")
                    echoed_stdout, echoed_stderr = echoed_turn.communicate(timeout=20)
                    self.assertEqual(echoed_turn.returncode, 0, f"Echoed-outcome fixture conversation failed: {echoed_stdout}; {echoed_stderr}")
                    echoed_events = [json.loads(line) for line in echoed_stdout.splitlines() if line.strip()]
                    finals = [event["payload"]["text"] for event in echoed_events if event.get("type") == "assistant_final"]
                    self.assertEqual(finals, ["Fixture answer with an echoed outcome."], "The streamed final answer must hide the echoed outcome command.")
                    echoed_record, _ = self.call_cli("task", "get", task_id)
                    self.assertEqual(self.assert_success(echoed_record)["status"], expected_status)
                    echoed_history = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)})[0])
                    self.assertEqual(echoed_history["messages"][-1]["text"], "Fixture answer with an echoed outcome.")
                    self.assertFalse(any("task outcome" in message["text"] for message in echoed_history["messages"]), "A fresh history read must hide the echoed outcome command.")
                finally:
                    if echoed_turn.poll() is None:
                        release_marker.write_text("Release the echoed-outcome turn.\n", encoding="utf-8")
                        echoed_turn.communicate(timeout=20)
            turn_data = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
            self.assertEqual(turn_data["threadStartCount"], 1)
            self.assertGreaterEqual(turn_data["threadResumeCount"], 1)
            self.assertEqual(len(turn_data["turns"]), 5)
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

    # case-contract: test_task_progress_reports_clear_on_failed_turns_and_questions | Progress reports clear when turns fail or are interrupted and when Codex requests user input; a staged completed outcome is discarded if its turn fails, leaving the task Blocked. The task card removes the report while lifecycle states remain Blocked or Waiting Response. A generic blocking question appears in a confirmation sheet; the answer reaches Codex and the task resumes while its turn is active. A late UI answer callback preserves Waiting Response after the active-turn marker clears, verified after the helper records its skipped transition. First-thread instructions distinguish source repository paths from active task worktree paths, allow read-only inspection without attaching a repo, and reserve repository add APIs for changes that need a worktree.
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
            resume_deadline = time.monotonic() + 10
            while not any(event.get("event") == "task.lifecycle_status.user_input_resumed" and event.get("taskID") == task_id for event in self.diagnostic_events()) and time.monotonic() < resume_deadline:
                time.sleep(0.02)
            self.assertTrue(any(event.get("event") == "task.lifecycle_status.user_input_resumed" and event.get("taskID") == task_id for event in self.diagnostic_events()), "The supplied answer should complete the active-turn status transition.")
            current, _ = self.call_cli("task", "get", task_id)
            self.assertEqual(self.assert_success(current)["status"], "In Progress", "An accepted answer should resume the active turn before completion.")
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

    # case-contract: test_default_parent_settings_read_write_clear_and_validation | The default parent can be read, changed, cleared, and an unavailable path is rejected; a fresh CLI read and repository discovery use the persisted parent. Dark and Light appearance choices persist, the removed PR conflict preference is absent from CLI/XPC and Settings, and appearance changes update the open Settings picker.
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

    # case-contract: test_task_roots_remain_after_default_parent_is_cleared | Clearing the default parent does not change roots already saved on a task.
    def test_task_roots_remain_after_default_parent_is_cleared(self):
        task_id = self.create_task(title="Persistent task roots")["id"]
        response, _ = self.call_cli("settings", "set-parent", self.fixture / "suggested-parent")
        self.assertEqual(self.assert_success(response)["defaultParentFolder"], str(self.fixture / "suggested-parent"))
        response, _ = self.call_cli("settings", "clear-parent")
        self.assertIsNone(self.assert_success(response)["defaultParentFolder"])
        response, _ = self.call_cli("task", "roots", "get", task_id)
        self.assertEqual(self.assert_success(response)["roots"], [str(self.primary)])

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
    # case-contract: test_conversation_composer_rejects_blank_and_supports_live_turn_controls | Shift+Enter inserts a newline at the caret without sending and Return submits; multiline drafts persist, expand to the editor limit, remain scrollable and editable across reopening, and submitted prompts persist in history. Blank drafts cannot be sent or stored. Sending requires a configured repository root, while a task with no selected repository can still be sent as standalone. If a submitted prompt has no Codex thread or active send reservation after restart, the task returns to Waiting Response, clears its pending marker, preserves the draft, and returns it to the composer. Sending to an Untitled auto-branch task derives its branch from the generated title or prompt fallback before preparing the worktree and starting the conversation. Pause remains disabled until the turn is interruptible. Diagnostics correlate title generation with the task and thread while excluding prompt and title text. Queued follow-ups persist with task and thread identity, dispatch after a completed turn, and remain visible for explicit retry after interruption. During an active turn, Return queues a follow-up and queued rows offer Steer. The obsolete footer Queue and Steer buttons are absent.
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

    # case-contract: test_conversation_provider_selection_persists_and_validates | New tasks use the default provider from settings, which starts as Codex and rejects unknown providers, and task create can choose a provider explicitly. A task without a conversation switches providers immediately; the choice persists across fresh CLI/XPC reads and an app relaunch, unknown providers and Done-task switches are rejected, and history has no provider boundary. A Claude task names Claude in the empty conversation, hides Goal mode, and rejects Goal changes through CLI/XPC.
    def test_conversation_provider_selection_persists_and_validates(self):
        settings = self.assert_success(self.call_cli("settings", "get")[0])
        self.assertEqual(settings["defaultProvider"], "codex", "Existing installs keep Codex as the default provider.")
        codex_task = self.create_task("Provider default task")
        self.assertEqual(codex_task["conversationProvider"], "codex")
        provider = self.assert_success(self.call_cli("conversation", "provider", codex_task["id"])[0])
        self.assertEqual(provider, {"provider": "codex", "supportsGoals": True})

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

    # case-contract: test_claude_answer_stays_final_around_outcome_report | Against the Claude Code protocol fixture, the answer Claude writes before running its StationAI progress and outcome commands and the closing line it adds afterward form one final answer, not commentary, in the streamed final answer, fresh history, and transcript, and the reported outcome moves the task to Review. Text Claude writes before an ordinary tool stays commentary, and a turn without an outcome ends in Waiting Response. After switching to Codex, the first Codex prompt hands off the whole Claude answer and excludes the commentary of answered turns, while a turn that recorded only commentary hands off its last commentary instead.
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

        self.assert_success(self.call_cli("conversation", "provider", task_id, "set", "codex")[0])
        sent, _ = self.call_cli("conversation", "send", task_id, "--message", "Continue the story.", extra_environment=fixtures)
        self.assert_success(sent)
        handoff = json.loads(Path(str(codex) + ".history").read_text(encoding="utf-8"))["turns"][-1]["userMessage"]
        self.assertIn("<stationai-handoff-context>", handoff)
        self.assertIn(f"Claude: {story_answer}", handoff, "Codex must receive the whole Claude answer.")
        self.assertIn("Claude: Inspection done: the workspace is ready.", handoff)
        self.assertNotIn("I'll inspect the workspace first.", handoff, "Commentary of an answered turn stays with the provider that produced it.")
        self.assertIn("Claude: Checks are running; results will follow.", handoff, "A turn without an answer hands off its last commentary.")
        self.assertNotIn("Starting the checks.", handoff, "Only the unanswered turn's last commentary is handed off.")
        self.assertTrue(handoff.endswith("Continue the story."))

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
        user_messages = [message for message in self.assert_success(history)["messages"] if message["role"] == "user"]
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

    # case-contract: test_claude_auto_branch_uses_generated_title_and_fallback | An Untitled Claude task with a pending auto repository branch uses its selected provider to generate the title before worktree creation; the branch and title persist across fresh CLI/XPC reads and the visible task. If Claude title generation returns no title, the prompt becomes the title and branch fallback, and the conversation still starts in that worktree.
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
            [turn["userMessage"] for turn in saved_history["messages"]],
            [first_prompt, second_prompt],
            "Both sequential turns should persist in the same Codex thread history.",
        )
        thread_id = saved_history["threadID"]
        thread_events = [event for event in saved_history["events"] if event["method"].startswith("thread/")]
        self.assertEqual([event["method"] for event in thread_events].count("thread/start"), 1)
        self.assertGreaterEqual([event["method"] for event in thread_events].count("thread/resume"), 1)
        self.assertTrue(all(event["threadID"] == thread_id for event in saved_history["events"]))
        self.assertTrue(all(turn["threadID"] == thread_id for turn in saved_history["messages"]))
        turn_ids = [turn["turnID"] for turn in saved_history["messages"]]
        self.assertEqual(len(turn_ids), 2)
        self.assertEqual(len(set(turn_ids)), 2, "Each serialized send should have its own Codex turn ID.")
        self.assertEqual(
            [event["turnID"] for event in saved_history["events"] if event["method"] == "turn/start"],
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

    # case-contract: test_conversation_sends_image_attachments | Backlog draft images persist through fresh CLI/XPC reads and reopening the conversation, with the preview restored; saving more than 8 draft images fails with invalid_argument and preserves the existing attachment. The conversation composer also accepts images from the picker and paste, compresses large clipboard images to fit the 10 MB payload limit, sends PNG and JPEG data URLs through CLI/XPC and to Codex using the tagged image URL payload, reads Codex history image URLs, and keeps earlier images visible after a later text turn and history refresh. Diagnostics record image MIME and encoded size without storing image payloads.
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

    # case-contract: test_conversation_shows_mcp_and_dynamic_tool_activity | MCP and dynamic tool lifecycle updates coalesce by stable item ID into distinct visible conversation rows; each call reports its start and measured duration, and completed durations persist through history reload. The conversation header shows only the newest active call; when it completes, the indicator falls back to the next still-active call. The expanded Working for list shows each call's live or completed duration. In-progress, completed, and failed statuses, server/tool identity, and safe result summaries render without duplicate rows, including when later-turn items follow the calls in history. Arguments and raw result text are never exposed.
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
        expected_tool_ids = {"item_fixture_mcp_call", "item_fixture_dynamic_call", "item_fixture_dynamic_legacy"}
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
            self.assertEqual(active_rows["item_fixture_mcp_call"]["toolKind"], "mcp")
            self.assertEqual(active_rows["item_fixture_dynamic_call"]["toolKind"], "dynamic")
            self.assertEqual(active_rows["item_fixture_dynamic_legacy"]["toolKind"], "dynamic")
            self.assertTrue(all(row.get("startedAt") for row in active_rows.values()), "Every active call should report its start time.")
            release_latest.write_text("Finish the newest call first.\n", encoding="utf-8")
            latest_deadline = time.monotonic() + 20
            while "item_fixture_dynamic_legacy" not in completed_rows and time.monotonic() < latest_deadline:
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
            self.assertIn("item_fixture_dynamic_legacy", completed_rows, "The newest call should finish before older active calls.")
            self.assertGreater(completed_rows["item_fixture_dynamic_legacy"].get("durationMs", 0), 0)
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

    # case-contract: test_conversation_shows_subagent_delegation | During a parent turn, active agents appear as individual named rows outside the collapsed Worked for disclosure, with available path/model/reasoning metadata and started-working wording. When the final answer arrives, all agent rows collapse inside Worked for alongside other Codex activity; expanding it reveals clickable agent rows. The UI fixture pauses after the final answer to verify this before turn completion while Stop response remains available. Completed, interrupted, and unknown states survive history reload and remain inspectable after reopening. The child thread opens as read-only through thread/read, thread/turns/list, and thread/items/list without editable controls or thread/resume, and diagnostics retain safe RPC outcomes while excluding conversation text, command output, and diffs. Multiple Codex message deltas and command-output deltas are summarized per item with counts and byte totals, flushed at turn completion, and excluded from individual notification records; lifecycle notifications remain individually logged, and diagnostics exclude conversation text, command output, and diffs.
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

    # case-contract: test_plan_mode_renders_markdown_in_conversation | Selecting Plan mode keeps planning active across completed turns and reopening; follow-up instructions start another plan turn, and Start Implementing stays enabled with an empty chat and composer, switches to Code mode, and starts an implementation turn; subsequent composer messages remain Code turns. The plan renders automatically as Markdown with visible spacing, remains selectable and copyable as one complete text view, and CLI events and bridge history preserve the exact plan text and latest implementation handoff. Multiple plan deltas are summarized per item with count and byte totals at turn completion, with no per-delta notification records and no plan text in diagnostics.
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
        markdown_reply = "## Implementation plan\n\nStart with the **workspace model**.\n\nA separate paragraph confirms readable spacing between plan sections.\n\n- Implementation detail 01: verify the saved conversation state and rendered result\n- Implementation detail 02: verify the saved conversation state and rendered result\n- Implementation detail 03: verify the saved conversation state and rendered result\n- Implementation detail 04: verify the saved conversation state and rendered result\n- Implementation detail 05: verify the saved conversation state and rendered result\n- Implementation detail 06: verify the saved conversation state and rendered result\n- Implementation detail 07: verify the saved conversation state and rendered result\n- Implementation detail 08: verify the saved conversation state and rendered result\n- Implementation detail 09: verify the saved conversation state and rendered result\n- Implementation detail 10: verify the saved conversation state and rendered result\n- Implementation detail 11: verify the saved conversation state and rendered result\n- Implementation detail 12: verify the saved conversation state and rendered result\n- Implementation detail 13: verify the saved conversation state and rendered result\n- Implementation detail 14: verify the saved conversation state and rendered result\n- Implementation detail 15: verify the saved conversation state and rendered result\n- Implementation detail 16: verify the saved conversation state and rendered result\n- Implementation detail 17: verify the saved conversation state and rendered result\n- Implementation detail 18: verify the saved conversation state and rendered result\n- Implementation detail 19: verify the saved conversation state and rendered result\n- Implementation detail 20: verify the saved conversation state and rendered result\n- Implementation detail 21: verify the saved conversation state and rendered result\n- Implementation detail 22: verify the saved conversation state and rendered result\n- Implementation detail 23: verify the saved conversation state and rendered result\n- Implementation detail 24: verify the saved conversation state and rendered result\n- Implementation detail 25: verify the saved conversation state and rendered result\n- Implementation detail 26: verify the saved conversation state and rendered result\n- Implementation detail 27: verify the saved conversation state and rendered result\n- Implementation detail 28: verify the saved conversation state and rendered result\n- Implementation detail 29: verify the saved conversation state and rendered result\n- Final verification: confirm the latest message is visible after reopening"
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
        turn_modes = [turn["conversationMode"] for turn in fixture_history["turns"]]
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

    # case-contract: test_conversation_mode_rejects_unknown_mode_without_starting_a_turn | The composer and empty-state prompt show the selected Codex-reported model and update when the user changes it, while unsupported modes and malformed model IDs are rejected before creating history.
    def test_conversation_mode_rejects_unknown_mode_without_starting_a_turn(self):
        task_id = self.create_task(title="Conversation mode validation")["id"]
        response, _ = self.call_cli("conversation", "models", task_id)
        models = self.assert_success(response)["models"]
        self.assertTrue(models)
        self.assertTrue(all(model.get("id") and model.get("name") for model in models))
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

    # case-contract: test_codex_questions_can_be_answered_over_cli_xpc | MCP tool/requestUserInput structured questions raised in Plan mode use the existing question path, move the task into the conditional Waiting Response board section even when Codex marks the request non-blocking; reopening preserves its status, keyed answers resume In Progress, and the answered turn returns to Waiting Response without an explicit completed outcome.
    def test_codex_questions_can_be_answered_over_cli_xpc(self):
        task_id = self.create_task("Codex questions", roots=[self.primary])["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-plan-slow"
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-codex-fixture-owner").write_text(
            "StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        env_overrides = {"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)}
        invalid, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Please ask your questions.",
            "--answer", "color= ", expected_status=2,
        )
        self.assert_failure(invalid, "invalid_argument")
        process_env = os.environ.copy()
        process_env.update({
            "STATIONAI_DATA_DIRECTORY": str(self.data_directory),
            "STATIONAI_E2E_WORKTREE_DIRECTORY": str(self.worktree_directory),
            "STATIONAI_E2E_DEFAULTS_SUITE": self.defaults_suite,
            "STATIONAI_BRIDGE_SERVICE_NAME": arguments.service_name,
            **env_overrides,
        })
        process = subprocess.Popen(
            [str(arguments.cli), "conversation", "send", task_id, "--message", "Please ask your questions.", "--mode", "plan",
             "--answer", "color=Blue", "--answer", "token=fixture-secret"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1, env=process_env,
        )
        final = None
        observed_request = None
        resumed_status_observed = False
        assert process.stdout is not None
        for line in process.stdout:
            if not line.strip():
                continue
            event = json.loads(line)
            if "type" not in event:
                final = event
                continue
            if event.get("type") == "user_input":
                observed_request = event.get("payload", {}).get("userInputRequest")
                self.assertEqual([question["id"] for question in observed_request["questions"]], ["color", "token"])
                self.assertTrue(observed_request["isBlocking"])
                self.assertEqual(event.get("payload", {}).get("taskStatus"), "Waiting Response")
            if event.get("type") == "task_status" and event.get("payload", {}).get("taskStatus") == "In Progress":
                resumed_status_observed = True
        stderr = process.stderr.read() if process.stderr else ""
        self.assertEqual(process.wait(timeout=30), 0, f"Conversation CLI failed: {final}; {stderr}")
        self.assertIsNotNone(observed_request, "CLI/XPC did not surface Codex's question request.")
        self.assertTrue(resumed_status_observed, "Submitting answers should emit In Progress before the turn finishes.")
        self.assertTrue(final and final.get("ok"), final)
        messages = final["result"]["messages"]
        self.assertTrue(any("Answers received: Blue / fixture-secret." in message["text"] for message in messages))
        task, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(task)["status"], "Waiting Response")
        saved_draft, _ = self.call_cli("task", "prompt", task_id, "--text", "A follow-up draft.")
        saved_task = self.assert_success(saved_draft)
        self.assertEqual(saved_task["status"], "Waiting Response")
        self.assertEqual(saved_task["savedPrompt"], "A follow-up draft.")

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

    # case-contract: test_codex_nonblocking_question_keeps_task_in_progress | Non-blocking structured questions remain visible without moving the task out of In Progress, then the answered turn returns to Waiting Response without an explicit completed outcome.
    def test_codex_nonblocking_question_keeps_task_in_progress(self):
        task_id = self.create_task("Non-blocking question", roots=[self.primary])["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-nonblocking-slow"
        (self.data_directory / ".stationai-codex-fixture-owner").write_text(
            "StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        env = os.environ.copy()
        env.update({
            "STATIONAI_DATA_DIRECTORY": str(self.data_directory),
            "STATIONAI_E2E_WORKTREE_DIRECTORY": str(self.worktree_directory),
            "STATIONAI_E2E_DEFAULTS_SUITE": self.defaults_suite,
            "STATIONAI_BRIDGE_SERVICE_NAME": arguments.service_name,
            "STATIONAI_E2E_CODEX_EXECUTABLE": str(executable),
        })
        process = subprocess.Popen(
            [str(arguments.cli), "conversation", "send", task_id, "--message", "Ask non-blocking questions.",
             "--answer", "color=Blue", "--answer", "token=fixture-secret"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1, env=env,
        )
        events = []
        assert process.stdout is not None
        for line in process.stdout:
            if line.strip(): events.append(json.loads(line))
        stderr = process.stderr.read() if process.stderr else ""
        self.assertEqual(process.wait(timeout=30), 0, f"Conversation CLI failed: {events[-1:]}; {stderr}")
        user_input_events = [event for event in events if event.get("type") == "user_input"]
        self.assertTrue(user_input_events, f"The Codex fixture did not request user input: {events}; {stderr}")
        request = user_input_events[0]["payload"]["userInputRequest"]
        self.assertFalse(request["isBlocking"])
        self.assertEqual(user_input_events[0]["payload"].get("taskStatus"), "In Progress")
        result = next(event for event in reversed(events) if "ok" in event)
        self.assertTrue(result["ok"], result)
        task, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(task)["status"], "Waiting Response")

    # case-contract: test_codex_async_questions_render_and_reply_as_followup | Async agentMessage questions retain choices and a free-text prompt in live updates and fresh CLI/XPC history, stay separate from later assistant text, and receive validated answers through the shared manager during and after an active turn. The UI shows inline answer cards instead of raw bullet text, blocks incomplete answers, preserves answered cards across reopening, and displays both submitted answers and responses.
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

    # case-contract: test_codex_async_question_queued_answer_retries | An async question answered after its turn ends stays Pending when the first follow-up fails, rejects duplicate answers across fresh CLI/XPC connections, and becomes Answered only after an explicit queued retry succeeds. The paired UI keeps the card and queue action visible across reopening and then displays the delivered response.
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
        duplicate, _ = self.call_cli("conversation", "answer-async", task_id, question["id"],
                                     "--answer", "No, leave tests and verification for later",
                                     "--answer", "Duplicate.", expected_status=1, extra_environment=env)
        self.assert_failure(duplicate, "invalid_transition")
        retried, _ = self.call_cli("conversation", "queue-retry", task_id, queued_item["id"], extra_environment=env)
        self.assertTrue(self.assert_success(retried)["retried"])
        delivered, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        delivered_history = self.assert_success(delivered)
        self.assertEqual(delivered_history["answeredAsyncQuestionIDs"], [question["id"]])
        expected_reply = ("Test and verify: Yes, update paired tests and run required verification\n"
                          "Additional detail: Retry this answer.")
        self.assertTrue(any(message["text"] == "Answers received: " + expected_reply
                            for message in delivered_history["messages"]))

    # case-contract: test_codex_interrupted_turn_blocks_with_reason_and_can_retry | Turn start persists In Progress; a genuine interrupted outcome remains Blocked with its reason, while restart recovery returns stale In Progress work to Waiting Response with its prompt and conversation available. A saved prompt whose turn never started returns to Waiting Response with its draft intact and can be continued; clean and unexpected relaunch preserve the prompt and conversation and allow a follow-up. Interrupted outcomes and diagnostics persist across connections; a new prompt can finish in Review. A queued follow-up remains visible as needing action after interruption, survives reopening, and is dispatched only after an explicit retry; the completed retry becomes the task's latest saved prompt.
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
        self.assertIn("restarted", recovered_thread_record["statusMessage"].lower())
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

    # case-contract: test_task_workspace_changes_group_staged_and_unstaged_diffs | The task view separates staged and working Git changes, and selecting text or JSON files opens a calculated, highlighted side-by-side diff over the conversation. Diagnostics record inventory and file-read outcomes with paths and byte counts, without logging file contents.
    def test_task_workspace_changes_group_staged_and_unstaged_diffs(self):
        self.prepare_workspace_changes()
        task_id = self.create_task(title="Workspace changes", roots=[self.changes])["id"]

        response, _ = self.call_cli("task", "changes", "list", task_id)
        inventory = self.assert_success(response)
        staged = {entry["path"]: entry for entry in inventory["staged"]}
        working = {entry["path"]: entry for entry in inventory["working"]}
        self.assertEqual(set(staged), {"shared.txt", "staged-deleted.txt", "staged.txt"})
        self.assertEqual(set(working), {"deleted.txt", "shared.txt", "syntax.json", "untracked.txt", "working.txt"})
        self.assertEqual(staged["staged-deleted.txt"]["status"], "deleted")
        self.assertEqual(working["deleted.txt"]["status"], "deleted")
        self.assertEqual(working["untracked.txt"]["status"], "untracked")

        staged_shared = self.assert_success(self.changes_diff(task_id, "shared.txt", "staged"))
        self.assertEqual(staged_shared["original"], "Shared baseline.\n")
        self.assertEqual(staged_shared["modified"], "Shared index version.\n")
        self.assertNotEqual(staged_shared["original"], staged_shared["modified"])
        self.assertTrue(staged_shared["isText"])

        working_shared = self.assert_success(self.changes_diff(task_id, "shared.txt", "working"))
        self.assertEqual(working_shared["original"], "Shared index version.\n")
        self.assertEqual(working_shared["modified"], "Shared working version.\n")

        syntax = self.assert_success(self.changes_diff(task_id, "syntax.json", "working"))
        self.assertEqual(syntax["original"], '{"value":"baseline"}\n')
        self.assertEqual(syntax["modified"], '{"value":"working version"}\n')
        self.assertTrue(syntax["isText"])

        untracked = self.assert_success(self.changes_diff(task_id, "untracked.txt", "working"))
        self.assertEqual(untracked["original"], "")
        self.assertEqual(untracked["modified"], "Untracked file.\n")

        deleted = self.assert_success(self.changes_diff(task_id, "deleted.txt", "working"))
        self.assertEqual(deleted["original"], "Deleted baseline.\n")
        self.assertEqual(deleted["modified"], "")

        staged_deleted = self.assert_success(self.changes_diff(task_id, "staged-deleted.txt", "staged"))
        self.assertEqual(staged_deleted["original"], "Staged deletion baseline.\n")
        self.assertEqual(staged_deleted["modified"], "")

        self.assert_failure(self.changes_diff(task_id, "stale.txt", "working", expected_status=3), "not_found")
        diagnostics = self.diagnostic_events()
        self.assertTrue(any(
            event.get("event") == "workspace.files.inventory.succeeded"
            and int(event.get("stagedCount", "0")) == 3
            and int(event.get("workingCount", "0")) == 5
            for event in diagnostics
        ))
        staged_read = next(
            event for event in diagnostics
            if event.get("event") == "workspace.file.read.succeeded"
            and event.get("path") == "shared.txt"
            and event.get("group") == "staged"
        )
        self.assertGreater(int(staged_read["originalBytes"]), 0)
        self.assertGreater(int(staged_read["modifiedBytes"]), 0)
        self.assertTrue(any(
            event.get("event") == "workspace.file.read.failed" and event.get("path") == "stale.txt"
            for event in diagnostics
        ))
        serialized_diagnostics = json.dumps(diagnostics)
        self.assertNotIn("Shared index version.", serialized_diagnostics)

    # case-contract: test_external_git_edits_and_commit_refresh_workspace_changes | External file edits and Git commits update the open task's changes sidebar automatically, and fresh CLI connections report the same Git status.
    def test_external_git_edits_and_commit_refresh_workspace_changes(self):
        repository = self.data_directory / "external-git"
        repository.mkdir()
        (repository / "tracked.txt").write_text("Baseline.\n", encoding="utf-8")
        self.run_git(repository, "init", "--initial-branch=main")
        self.run_git(repository, "config", "user.name", "StationAI Bridge Test")
        self.run_git(repository, "config", "user.email", "stationai-bridge-test@example.invalid")
        self.run_git(repository, "add", "tracked.txt")
        self.run_git(repository, "commit", "-m", "Baseline")
        task_id = self.create_task(title="External Git", roots=[repository])["id"]

        response, _ = self.call_cli("task", "changes", "list", task_id)
        self.assertEqual(self.assert_success(response), {"staged": [], "working": []})

        (repository / "tracked.txt").write_text("Edited externally.\n", encoding="utf-8")
        response, _ = self.call_cli("task", "changes", "list", task_id)
        inventory = self.assert_success(response)
        self.assertEqual(inventory["staged"], [])
        self.assertEqual([entry["path"] for entry in inventory["working"]], ["tracked.txt"])

        self.run_git(repository, "add", "tracked.txt")
        response, _ = self.call_cli("task", "changes", "list", task_id)
        inventory = self.assert_success(response)
        self.assertEqual([entry["path"] for entry in inventory["staged"]], ["tracked.txt"])
        self.assertEqual(inventory["working"], [])

        self.run_git(repository, "commit", "-m", "External commit")
        response, _ = self.call_cli("task", "changes", "list", task_id)
        self.assertEqual(self.assert_success(response), {"staged": [], "working": []})
        response, _ = self.call_cli(
            "task", "changes", "diff", task_id,
            "--repository", repository, "--path", "tracked.txt", "--group", "staged",
            expected_status=3,
        )
        self.assert_failure(response, "not_found")



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
