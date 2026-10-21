#!/usr/bin/env python3

import argparse
import errno
import fcntl
import json
import plistlib
import os
import shutil
import sqlite3
import stat
import subprocess
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

    def start_cli(self, *command, extra_environment=None):
        environment = os.environ.copy()
        environment["STATIONAI_DATA_DIRECTORY"] = str(self.data_directory)
        environment["STATIONAI_E2E_WORKTREE_DIRECTORY"] = str(self.worktree_directory)
        environment["STATIONAI_E2E_DEFAULTS_SUITE"] = self.defaults_suite
        environment["STATIONAI_BRIDGE_SERVICE_NAME"] = arguments.service_name
        environment.update(extra_environment or {})
        return subprocess.Popen(
            [str(self.cli), *map(str, command)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
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
        (self.data_directory / ".stationai-codex-fixture-owner").write_text(
            "StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        response, _ = self.call_cli(
            "conversation", "send", task_id, "--message", message,
            "--answer", "color=Blue", "--answer", "token=fixture-secret",
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        result = self.assert_success(response)
        current, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(current)["status"], "Review")
        return result

    def seed_done_task_pull_request(self, task_id, number=123):
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
        result = subprocess.run(
            [str(executable), str(self.data_directory), task_id, str(number), seeded_url],
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

    # case-contract: test_service_reports_bridge_version | StationAI opens one main board window and the bridge reports API version 1.
    def test_service_reports_bridge_version(self):
        response, _ = self.call_cli("status")
        self.assertEqual(self.assert_success(response), {"bridgeVersion": 1, "service": "StationAI"})

    # case-contract: test_app_override_rejects_incompatible_bundles | Explicit app overrides reject obsolete compatibility metadata, foreign worktree or bridge identities, and nonisolated test data before launching; the current app preserves a saved draft across restart.
    def test_app_override_rejects_incompatible_bundles(self):
        task = self.assert_success(self.call_cli("task", "create", "--title", "Protected store", "--root", self.primary)[0])
        self.assert_success(self.call_cli("task", "prompt", task["id"], "--text", "Protected draft", "--status", "Backlog")[0])
        root = Path(__file__).resolve().parent.parent
        contract = subprocess.run(["python3", str(root / "scripts/check-app-launch-contract.py"), str(self.cli.parent.parent.parent), str(root), str(self.data_directory)], capture_output=True, text=True)
        self.assertEqual(contract.returncode, 0, f"App launch contract check failed: {contract.stdout}\n{contract.stderr}")
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
        self.assertEqual(subprocess.run(
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

    # case-contract: test_task_creation_rejects_invalid_title_roots_and_missing_folder | New Task immediately opens an empty conversation with the repository picker focused; sending stays disabled until a working folder is added. The CLI accepts empty-root tasks and rejects blank titles, missing folders, unavailable roots, and invalid merge targets.
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
        deleted, _ = self.call_cli("task", "delete", empty_task["id"])
        self.assertTrue(self.assert_success(deleted)["deleted"])

        response, _ = self.call_cli(
            "task", "create", "--title", "Missing folder", "--root", self.fixture / "missing",
            expected_status=2,
        )
        self.assert_failure(response, "invalid_argument")

    # case-contract: test_task_creation_persists_ordered_roots_across_fresh_connections | A directly created conversation can add repositories in order, edit pending branch settings, and add a context folder; these settings persist across fresh connections without creating branches or worktrees before the first send. Saving an unsent prompt records task creation, prompt save, and subsequent reads with safe argument metadata, result state, and outcome while excluding prompt text.
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
            and "create(title:repositories:contextFolders:)" in event.get("operation", "")
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

    # case-contract: test_task_store_serializes_cross_process_writes | If another process holds the shared task-store write lock when a Codex turn completes, final status persistence waits and then saves Review status and full history across fresh CLI/XPC reads. Correlated persistence diagnostics include task ID, store path, lock wait, attempts, and retry count; task reads correlate started and completed events by read ID and store path, while failed reads include store file and sidecar state. Reopening the conversation in the UI shows the saved exchange without a store error.
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

    # case-contract: test_task_store_repairs_missing_pending_prompt_column | A real legacy SwiftData task store with old model metadata and no submitted-prompt column waits for the store-write lock while app and CLI/XPC open concurrently, is backed up before migration, and preserves its task and draft after a visible restart; metadata advances and later opens create no additional backup. The store is imported once into the protected filename and the legacy database remains unchanged. Committed WAL-only draft data survives import, and a subsequent edited draft survives restart without reimport.
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
            self.assertEqual(database.execute("SELECT count(*) FROM ZBOARDTASK").fetchone()[0], 1)
            legacy_metadata = plistlib.loads(database.execute("SELECT Z_PLIST FROM Z_METADATA").fetchone()[0])
            legacy_hash = legacy_metadata["NSStoreModelVersionHashes"]["BoardTask"]
            self.assertEqual(legacy_hash.hex(), "24594c3345454e4107a5224f966af3bb539b5a9d91e15480728b1fcf490b6070")

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
            self.assertNotIn("ZPENDINGSUBMITTEDPROMPT", {row[1] for row in backup.execute("PRAGMA table_info(ZBOARDTASK)")})
        listed, _ = self.call_cli("board", "list")
        self.assertEqual([item["id"] for item in self.assert_success(listed)["tasks"]], [task_id])
        self.assertEqual(len(list(self.data_directory.glob("StationAI.store.before-pending-prompt-*.backup"))), 1)
        self.assertEqual(legacy_store.read_bytes(), legacy_bytes)
        with sqlite3.connect(store) as database:
            self.assertIn("ZPENDINGSUBMITTEDPROMPT", {row[1] for row in database.execute("PRAGMA table_info(ZBOARDTASK)")})
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

    # case-contract: test_task_worktree_preparation_serializes_auto_branch_claims | Tasks with the same automatic branch choice remain pending without creating a worktree before conversation start; the opt-in live Codex integration sends both turns concurrently and confirms only one task claims the generated branch.
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

    # case-contract: test_task_done_preserves_worktree_and_branch | Sending the first message derives an auto branch from the generated task title. Moving a reviewed task to Done waits for active per-task operations and persists against refreshed state; it preserves that source branch and worktree without merging into the local target, retains conversation history, and exposes the task in the searchable read-only archive.
    def test_task_done_preserves_worktree_and_branch(self):
        task = self.create_repo_task("Untitled task", [self.primary])
        draft = "Please update the README and add concise setup steps for first time contributors tomorrow."
        self.assertEqual(self.assert_success(self.call_cli("task", "prompt", task["id"], "--text", draft)[0])["savedPrompt"], draft)
        self.assertTrue(task["repositoryWorktrees"][0]["isPending"])
        self.assertEqual(task["repositoryWorktrees"][0]["branch"], "auto")
        self.assertEqual(task["repositoryWorktrees"][0]["worktreePath"], str(self.primary))
        executable = self.data_directory / "codex-fixture"
        self.complete_fixture_turn(task["id"])
        started = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        record = started["repositoryWorktrees"][0]
        self.assertFalse(record["isPending"])
        self.assertEqual(record["branch"], "generated-fixture-title")
        worktree = Path(record["worktreePath"])
        target_head = self.run_git(self.primary, "rev-parse", "main")
        self.assertEqual(self.run_git(worktree, "rev-parse", "HEAD"), target_head)
        current, _ = self.call_cli("task", "get", task["id"])
        self.assertEqual(self.assert_success(current)["status"], "Review")
        (self.primary / "target-only.txt").write_text("Master advanced after this task branch was created.\n", encoding="utf-8")
        self.run_git(self.primary, "add", "target-only.txt")
        self.run_git(self.primary, "commit", "-m", "Advance merge target while task is under review")
        target_head = self.run_git(self.primary, "rev-parse", "main")
        move_lock = TaskOperationLockBarrier(self.data_directory, task["id"])
        move_command = ["task", "move", task["id"], "Done"]
        move_process = self.start_cli(*move_command)
        try:
            time.sleep(0.25)
            self.assertIsNone(move_process.poll(), "Moving a task to Done must wait for an active per-task operation.")
            current, _ = self.call_cli("task", "get", task["id"])
            self.assertEqual(self.assert_success(current)["status"], "Review")
        finally:
            move_lock.release()
        response, _ = self.finish_cli(move_process, move_command)
        self.assertEqual(self.assert_success(response)["status"], "Done")
        self.assertTrue(worktree.exists(), "Moving a task to Done must preserve its worktree.")
        self.assertTrue(self.branch_exists(self.primary, "generated-fixture-title"))
        self.assertEqual(self.run_git(self.primary, "rev-parse", "main"), target_head, "Moving a task to Done must not merge into the local target.")
        self.assertEqual((self.primary / "target-only.txt").read_text(encoding="utf-8"), "Master advanced after this task branch was created.\n")
        self.assertFalse((self.primary / "task-result.txt").exists())
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task["id"])[0])["repositoryWorktrees"][0]["mergeTarget"], "main")
        completed, _ = self.call_cli("task", "get", task["id"])
        self.assertEqual(self.assert_success(completed)["savedPrompt"], "Complete this task.")
        board, _ = self.call_cli("board", "list")
        archived = next(item for item in self.assert_success(board)["tasks"] if item["id"] == task["id"])
        self.assertEqual(archived["status"], "Done")
        history, _ = self.call_cli(
            "conversation", "history", task["id"],
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(self.data_directory / "codex-fixture")},
        )
        messages = self.assert_success(history)["messages"]
        self.assertTrue(any(message["role"] == "assistant" and "Answers received: Blue / fixture-secret." in message["text"] for message in messages))

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

    # case-contract: test_task_pr_create_reports_real_gh_failure | A repository-backed task exposes an active-card PR action and a Done-task archive PR action with distinct hover emphasis and useful help; it preserves the configured merge target, waits for the task operation lock, commits and publishes the branch before GitHub lookup, and reports publication failure without saving a PR link or changing Done status when no usable remote exists.
    def test_task_pr_create_reports_real_gh_failure(self):
        task = self.create_repo_task(
            "PR failure", [self.primary], merge_targets={self.primary: "main"}, materialize=True
        )
        self.assertEqual(task["repositoryWorktrees"][0]["mergeTarget"], "main")
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
        self.assertIn("couldn't publish the task branch", response["error"]["message"])
        current = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        record = current["repositoryWorktrees"][0]
        self.assertEqual(record["mergeTarget"], "main")
        self.assertIsNone(record.get("pullRequestNumber"))
        self.assertIsNone(record.get("pullRequestURL"))
        self.assertEqual(current["status"], "Done")

    # case-contract: test_done_archive_displays_existing_pull_request_link | A Done task's real SwiftData record retains a linked PR number and URL across fresh CLI/XPC reads so the archive renders the PR link with distinct hover emphasis and useful help; an active repository-backed task card renders a saved PR link with the same hover indication.
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

    # case-contract: test_task_status_transitions_and_rejects_unknown_status | With both pairs populated, the board keeps Blocked above Backlog and Waiting Response above In Progress, allows vertical scrolling to reach lower backlog tasks, leaves Review as its own column, hides empty status sections, removes Done from the columns, and rejects manual changes to Codex-owned task status.
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
        self.assertEqual(waiting["status"], "Review")
        self.assertEqual(self.assert_success(self.call_cli("task", "get", blocked_id)[0])["status"], "Blocked")

    # case-contract: test_task_progress_reports_publish_persist_and_clear | The CLI publishes standard and custom progress only during an active task turn, persists each report across fresh CLI/XPC connections, rejects invalid reports, clears explicitly and at turn completion, and the board card shows the built-in icon, label, and detail without changing lifecycle status; each new task thread receives hidden CLI usage instructions that persist with the thread.
    def test_task_progress_reports_publish_persist_and_clear(self):
        task_id = self.create_task("Progress reports", roots=[self.primary])["id"]
        response, _ = self.call_cli("task", "progress", "publish", task_id, "--type", "building", expected_status=1)
        self.assert_failure(response, "invalid_transition")

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

            cleared, _ = self.call_cli("task", "progress", "clear", task_id)
            self.assertIsNone(self.assert_success(cleared).get("progressLabel"))
            final_report, _ = self.call_cli("task", "progress", "publish", task_id, "--type", "testing")
            self.assertEqual(self.assert_success(final_report)["progressLabel"], "Testing")
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
                release_marker.write_text("Release the resumed turn.\n", encoding="utf-8")
                follow_stdout, follow_stderr = follow_up.communicate(timeout=20)
                self.assertEqual(follow_up.returncode, 0, f"Resumed fixture conversation failed: {follow_stdout}; {follow_stderr}")
                follow_response = json.loads([line for line in follow_stdout.splitlines() if line.strip()][-1])
                self.assertTrue(follow_response["ok"], follow_response.get("error"))
            finally:
                if follow_up.poll() is None:
                    release_marker.write_text("Release the resumed turn.\n", encoding="utf-8")
                    follow_up.communicate(timeout=20)
            turn_data = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
            self.assertEqual(turn_data["threadStartCount"], 1)
            self.assertGreaterEqual(turn_data["threadResumeCount"], 1)
            self.assertEqual(len(turn_data["turns"]), 2)
            self.assertTrue(all(turn["developerInstructions"] is None for turn in turn_data["turns"]))
            instructions = turn_data["threadStartDeveloperInstructions"]
            self.assertIn(str(self.cli), instructions)
            self.assertIn("task progress publish", instructions)
            self.assertIn("hidden from the conversation", instructions)
            self.assertIsNone(turn_data["developerInstructions"])
        finally:
            if turn.poll() is None:
                release_marker.write_text("Release the active turn.\n", encoding="utf-8")
                turn.communicate(timeout=20)
            active_marker.unlink(missing_ok=True)
            release_marker.unlink(missing_ok=True)

    # case-contract: test_task_progress_reports_clear_on_failed_turns_and_questions | Progress reports clear when turns fail or are interrupted and when Codex requests user input; the task card removes the report while lifecycle states remain Blocked or Waiting Response, and answering the question resumes the task successfully.
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

        task_id = self.create_task("Progress question", roots=[self.primary])["id"]
        process, executable, active, release = self.start_progress_fixture_turn(
            task_id, "codex-fixture-progress-question",
            answers=["color=Blue", "token=fixture-secret"],
        )
        try:
            report, _ = self.call_cli("task", "progress", "publish", task_id, "--type", "reviewing")
            self.assertEqual(self.assert_success(report)["progressLabel"], "Reviewing")
            release.write_text("Release the active turn.\n", encoding="utf-8")
            stdout, stderr = process.communicate(timeout=20)
            self.assertEqual(process.returncode, 0, f"Answering the fixture question should complete the turn: {stdout}; {stderr}")
            final_response = json.loads([line for line in stdout.splitlines() if line.strip()][-1])
            self.assertTrue(final_response["ok"], final_response.get("error"))
            current, _ = self.call_cli("task", "get", task_id)
            current_record = self.assert_success(current)
            self.assertEqual(current_record["status"], "Review")
            self.assertIsNone(current_record.get("progressLabel"))
        finally:
            if process.poll() is None:
                release.write_text("Release the active turn.\n", encoding="utf-8")
                process.communicate(timeout=20)
            active.unlink(missing_ok=True)
            release.unlink(missing_ok=True)

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

    # case-contract: test_conversation_repository_picker_adds_repository_worktree | Repository suggestions can be filtered and navigated with Up/Down, and Enter selects the highlighted repository; adding it waits for an active conversation turn, then persists a pending auto branch with labeled branch, merge-from, and merge-to values, and no worktree exists before the first send.
    def test_conversation_repository_picker_adds_repository_worktree(self):
        task = self.create_task("Add repository in conversation", [self.primary])
        task_id = task["id"]
        self.assertEqual(task["repositoryWorktrees"], [])
        self.assertEqual(task["workspaceRoots"], [str(self.primary)])
        reservation = ConversationTurnLockBarrier(self.data_directory, task_id)
        add_command = ["task", "repository", "add", task_id, "--repo", self.primary]
        add_process = None
        continue_add_process = False
        try:
            add_process = self.start_cli(*add_command)
            time.sleep(0.25)
            self.assertIsNone(add_process.poll(), "Adding a repository should wait for the active conversation-turn reservation.")
            unchanged, _ = self.call_cli("task", "get", task_id)
            self.assertEqual(self.assert_success(unchanged)["repositoryWorktrees"], [])
            continue_add_process = True
        finally:
            reservation.release()
            if not continue_add_process and add_process is not None and add_process.poll() is None:
                add_process.terminate()
                try:
                    add_process.communicate(timeout=20)
                except subprocess.TimeoutExpired:
                    add_process.kill()
                    add_process.communicate()
        self.assertIsNotNone(add_process)
        response, _ = self.finish_cli(add_process, add_command)
        updated = self.assert_success(response)
        self.assertEqual(len(updated["repositoryWorktrees"]), 1)
        added = updated["repositoryWorktrees"][0]
        self.assertEqual(added["repositoryPath"], str(self.primary))
        self.assertEqual(added["worktreePath"], str(self.primary))
        self.assertTrue(added["isPending"])
        self.assertEqual(added["branch"], "auto")
        self.assertTrue(added["branchFrom"])
        self.assertTrue(added["mergeTarget"])
        self.assertEqual(updated["workspaceRoots"], [str(self.primary)])
        self.assertEqual(updated["contextFolders"], [])
        duplicate, _ = self.call_cli("task", "repository", "add", task_id, "--repo", self.primary, expected_status=2)
        self.assert_failure(duplicate, "invalid_argument")
        invalid, _ = self.call_cli("task", "repository", "add", task_id, "--repo", self.custom, expected_status=1)
        self.assert_failure(invalid, "operation_failed")
        fresh, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(fresh)["repositoryWorktrees"], updated["repositoryWorktrees"])

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

    # case-contract: test_task_repository_removal_preserves_state_on_dirty_worktree | Removing the only pending repository leaves the task with no workspace and preserves the source repository; removing a pending repository preserves other context folders; removing a clean managed worktree waits for an active conversation turn and then succeeds, while a dirty worktree rejects removal and preserves its task record and files.
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

        active = self.create_repo_task("Started repository removal", [self.secondary], roots=[self.custom])
        active_id = active["id"]
        self.complete_fixture_turn(active_id)
        active, _ = self.call_cli("task", "get", active_id)
        record = self.assert_success(active)["repositoryWorktrees"][0]
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
        remove_command = ["task", "repository", "remove", active_id, "--repo", self.secondary]
        remove_process = None
        continue_remove_process = False
        try:
            remove_process = self.start_cli(*remove_command)
            time.sleep(0.25)
            self.assertIsNone(remove_process.poll(), "Repository removal should wait for the active conversation-turn reservation.")
            still_attached, _ = self.call_cli("task", "get", active_id)
            still_attached_record = self.assert_success(still_attached)
            self.assertEqual(len(still_attached_record["repositoryWorktrees"]), 1)
            self.assertTrue(worktree.exists())
            continue_remove_process = True
        finally:
            lock_barrier.release()
            if not continue_remove_process and remove_process is not None and remove_process.poll() is None:
                remove_process.terminate()
                try:
                    remove_process.communicate(timeout=20)
                except subprocess.TimeoutExpired:
                    remove_process.kill()
                    remove_process.communicate()
        self.assertIsNotNone(remove_process)
        removed_active, _ = self.finish_cli(remove_process, remove_command)
        active_result = self.assert_success(removed_active)
        self.assertEqual(active_result["repositoryWorktrees"], [])
        self.assertEqual(active_result["contextFolders"], [str(self.custom)])
        self.assertEqual(active_result["workspaceRoots"], [str(self.custom)])
        self.assertFalse(worktree.exists())
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

    # case-contract: test_default_parent_settings_read_write_clear_and_validation | The default parent can be read, changed, cleared, and an unavailable path is rejected; a fresh CLI read and repository discovery use the persisted parent. In the UI, the conversation picker keeps a Change parent affordance visible after a valid parent is selected, and choosing another folder refreshes suggestions and persists the new parent. Dark and Light appearance choices persist and log successful writes, an external CLI appearance write updates the open Settings picker, and Dark renders the workspace canvas as #1E1E1E in the VS Code Dark+ palette.
    def test_default_parent_settings_read_write_clear_and_validation(self):
        response, _ = self.call_cli("settings", "get")
        self.assertIsNone(self.assert_success(response)["defaultParentFolder"])
        self.assertEqual(self.assert_success(response)["appearance"], "dark")

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

    # case-contract: test_repository_suggestions_skip_nested_repositories_and_symlinks | The CLI returns top-level Git repository suggestions while excluding nested repositories and symlink targets. The conversation picker shows those suggestions, filters by repository name or parent path, and reports no matches for non-repository folders.
    def test_repository_suggestions_skip_nested_repositories_and_symlinks(self):
        response, _ = self.call_cli("workspace", "suggest", "--parent", self.fixture / "suggested-parent")
        repositories = self.assert_success(response)["repositories"]
        self.assertEqual(repositories, sorted([str(self.primary), str(self.secondary), str(self.alternate), str(self.changes)]))
        self.assertNotIn(str(self.nested), repositories)
        self.assertNotIn(str(self.external), repositories)

    # case-contract: test_new_task_remembers_last_selected_repositories | The CLI reads and writes ordered last-selected repositories across fresh XPC connections and applies them to empty tasks through repository batches with ordered roots and default auto/main/main branch settings; a newly saved list applies to a fresh task and remains saved. Invalid repository paths are rejected without changing the saved preference. In the UI, the picker placeholder shows saved repository names in order followed immediately by a Return key indicator; blank Return restores the saved repositories, while typing and arrow selection replaces and persists the list for the next conversation.
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
        self.assertEqual(restored_task["workspaceRoots"], expected_repositories)
        first_repositories = restored_task["repositoryWorktrees"]
        self.assertEqual([item["repositoryPath"] for item in first_repositories], expected_repositories)
        self.assertEqual([item["branch"] for item in first_repositories], ["auto", "auto"])
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
        self.assertEqual(restored_task["workspaceRoots"], [str(self.alternate)])
        second_repositories = restored_task["repositoryWorktrees"]
        self.assertEqual([item["repositoryPath"] for item in second_repositories], [str(self.alternate)])
        self.assertEqual([item["branch"] for item in second_repositories], ["auto"])
        self.assertEqual([item["branchFrom"] for item in second_repositories], ["main"])
        self.assertEqual([item["mergeTarget"] for item in second_repositories], ["main"])
        response, _ = self.call_cli("settings", "get")
        self.assertEqual(self.assert_success(response)["lastSelectedRepositories"], [str(self.alternate)])

        response, _ = self.call_cli("settings", "set-last-repositories", "--repo", self.fixture / "absent", expected_status=2)
        self.assert_failure(response, "invalid_argument")
        response, _ = self.call_cli("settings", "get")
        self.assertEqual(self.assert_success(response)["lastSelectedRepositories"], [str(self.alternate)])

    # case-contract: test_new_task_repository_restore_is_atomic_on_invalid_default | Applying an ordered repository batch with a valid repository followed by an empty Git repository fails without mutation: the CLI reports invalid_argument and fresh reads show no repository attachments or workspace roots; New Task blank Return keeps the picker open, shows an error, attaches neither repository, keeps roots empty, and preserves the saved repository order.
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

    # case-contract: test_new_task_has_empty_conversation_history | The CLI creates an Untitled task with no roots, verifies empty history, and deletes it cleanly. New Task opens one empty conversation with its repository picker focused and no create sheet. Adding folder-only context leaves history empty, and backing out deletes the pending task without confirmation.
    def test_new_task_has_empty_conversation_history(self):
        response, _ = self.call_cli("task", "create", "--title", "Untitled task")
        task_id = self.assert_success(response)["id"]
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

    # case-contract: test_task_prompt_draft_persists_after_back | Creating a repository task leaves its selected branch pending while backing out saves an unsent prompt; reopening restores the draft without creating a branch or worktree, and invalid status changes are rejected without mutation. If the title is renamed while delayed title generation is in flight, the late result is skipped, the renamed title persists, and diagnostics record the skip reason without prompt or title text.
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
    # case-contract: test_conversation_composer_rejects_blank_and_supports_live_turn_controls | Shift+Enter inserts a newline in the composer without sending; multiline prompts persist as typed text and the composer expands beyond five lines before scrolling. Long submitted prompts persist through CLI/XPC, and the UI transcript shows a scrollbar for overflow with scrolling that reveals earlier and later content. Blank drafts cannot be sent or stored, sent prompts persist in conversation history through reload, and backing out immediately after send preserves the submitted prompt as a sent message while title generation is pending. The CLI rejects submitted-prompt saves unless they include nonblank text and In Progress status. The CLI/XPC and UI also recover a submitted prompt that has no Codex thread or active send reservation: the task becomes Blocked, the pending marker clears, and the prompt returns to the composer. Sending to an Untitled auto-branch task derives its branch from the Codex-generated title or from the prompt fallback when title generation fails. During title preparation, CLI/XPC confirms the submitted prompt and conversation thread remain attached to the task, while the UI keeps Pause disabled until the task's conversation client has an interruptible turn. Persistent diagnostics correlate title generation and application outcomes with the task and Codex thread, record failure or skip reasons, and exclude prompt and title text, including text echoed in server errors.
    def test_conversation_composer_rejects_blank_and_supports_live_turn_controls(self):
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
        prompt = "Work on the persisted prompt while I reopen this task."
        saved, _ = self.call_cli("task", "prompt", task_id, "--text", prompt)
        self.assertEqual(self.assert_success(saved)["savedPrompt"], prompt)
        multiline_prompt = "First line\nSecond line"
        saved, _ = self.call_cli("task", "prompt", task_id, "--text", multiline_prompt)
        self.assertEqual(self.assert_success(saved)["savedPrompt"], multiline_prompt)
        saved, _ = self.call_cli("task", "prompt", task_id, "--text", prompt)
        self.assertEqual(self.assert_success(saved)["savedPrompt"], prompt)
        persisted = self.complete_fixture_turn(task_id, message=prompt)
        self.assertTrue(any(message["role"] == "user" and message["text"] == prompt for message in persisted["messages"]))
        task, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(task)["savedPrompt"], prompt)

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
        self.assertEqual(recovered_record["status"], "Blocked")
        self.assertEqual(recovered_record["savedPrompt"], stale_prompt)
        self.assertIsNone(recovered_record.get("pendingSubmittedPrompt"))

    # case-contract: test_conversation_serializes_concurrent_sends | Two concurrent sends for the same task are serialized across the app and CLI/XPC paths against the local Codex app-server fixture; the second waits for the first, both complete on the persisted thread, and the task remains In Progress while a send is active.
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
        self.assertEqual(completed["status"], "Review")

    # case-contract: test_conversation_sends_image_attachments | The conversation composer accepts images from the picker and paste, previews them before sending, sends image-only or text-and-image prompts to Codex using the tagged image URL payload, and displays attached images from reloaded conversation history. Diagnostics record image MIME and encoded size without storing image payloads.
    def test_conversation_sends_image_attachments(self):
        task_id = self.create_task(title="Image conversation") ["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-success"
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-codex-fixture-owner").write_text(
            "StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        image = self.data_directory / "tiny.png"
        image.write_bytes(bytes.fromhex("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000b49444154789c636000020000050001a5f645400000000049454e44ae426082"))
        result, _ = self.call_cli(
            "conversation", "send", task_id, "--image", str(image),
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        self.assert_success(result)
        sent = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
        self.assertEqual(len(sent["images"]), 1)
        self.assertTrue(sent["images"][0].startswith("data:image/png;base64,"))
        self.assertEqual(sent["imageInputs"], [{"type": "image", "url": sent["images"][0]}])
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

    # case-contract: test_conversation_shows_subagent_delegation | When Codex delegates a task to a subagent, the conversation activity shows the delegated task and its completion status during the turn and after history reload. Diagnostics record Codex RPC outcomes and command working directory and file-change paths while excluding conversation text, command output, and diffs.
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
        sent, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Delegate this task.",
            extra_environment=env,
        )
        result = self.assert_success(sent)
        activities = result["activities"]
        subagent = next(activity for activity in activities if activity["title"] == "Task delegated to subagent")
        self.assertEqual(subagent["status"], "completed")
        self.assertIn("Inspect the project structure", subagent["detail"])
        self.assertIn("Inspected the project structure", subagent["detail"])

        diagnostics = self.diagnostic_events()
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
        self.assertNotIn("Delegate this task.", serialized_diagnostics)

        reloaded, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        history = self.assert_success(reloaded)
        self.assertEqual(
            {activity["id"]: activity for activity in history["activities"]},
            {activity["id"]: activity for activity in activities},
        )
        self.assertTrue(any("subagent inspected" in message["text"].lower() for message in history["messages"]))

    # case-contract: test_plan_mode_renders_markdown_in_conversation | Selecting Plan mode sends a planning turn; a completed <proposed_plan> is automatically rendered as Markdown without exposing its wrapper tags, including after reopening, while bridge history preserves the exact source and the reopened conversation shows its latest message.
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
        markdown_reply = "<proposed_plan>\n## Implementation plan\n\nStart with the **workspace model**.\n\n- Implementation detail 01: verify the saved conversation state and rendered result\n- Implementation detail 02: verify the saved conversation state and rendered result\n- Implementation detail 03: verify the saved conversation state and rendered result\n- Implementation detail 04: verify the saved conversation state and rendered result\n- Implementation detail 05: verify the saved conversation state and rendered result\n- Implementation detail 06: verify the saved conversation state and rendered result\n- Implementation detail 07: verify the saved conversation state and rendered result\n- Implementation detail 08: verify the saved conversation state and rendered result\n- Implementation detail 09: verify the saved conversation state and rendered result\n- Implementation detail 10: verify the saved conversation state and rendered result\n- Implementation detail 11: verify the saved conversation state and rendered result\n- Implementation detail 12: verify the saved conversation state and rendered result\n- Implementation detail 13: verify the saved conversation state and rendered result\n- Implementation detail 14: verify the saved conversation state and rendered result\n- Implementation detail 15: verify the saved conversation state and rendered result\n- Implementation detail 16: verify the saved conversation state and rendered result\n- Implementation detail 17: verify the saved conversation state and rendered result\n- Implementation detail 18: verify the saved conversation state and rendered result\n- Implementation detail 19: verify the saved conversation state and rendered result\n- Implementation detail 20: verify the saved conversation state and rendered result\n- Implementation detail 21: verify the saved conversation state and rendered result\n- Implementation detail 22: verify the saved conversation state and rendered result\n- Implementation detail 23: verify the saved conversation state and rendered result\n- Implementation detail 24: verify the saved conversation state and rendered result\n- Implementation detail 25: verify the saved conversation state and rendered result\n- Implementation detail 26: verify the saved conversation state and rendered result\n- Implementation detail 27: verify the saved conversation state and rendered result\n- Implementation detail 28: verify the saved conversation state and rendered result\n- Implementation detail 29: verify the saved conversation state and rendered result\n- Final verification: confirm the latest message is visible after reopening\n</proposed_plan>"
        sent, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Plan the task.", "--mode", "plan",
            extra_environment=env,
        )
        messages = self.assert_success(sent)["messages"]
        self.assertTrue(any(message["role"] == "assistant" and message["text"] == markdown_reply for message in messages))
        history, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        reloaded_messages = self.assert_success(history)["messages"]
        self.assertTrue(any(message["role"] == "assistant" and message["text"] == markdown_reply for message in reloaded_messages))
        self.assertEqual(reloaded_messages[-1]["role"], "assistant", "The latest response should be last in bridge history.")

    # case-contract: test_conversation_mode_rejects_unknown_mode_without_starting_a_turn | The composer shows a Codex-reported model, while unsupported modes and malformed model IDs are rejected before creating history.
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

    # case-contract: test_codex_questions_can_be_answered_over_cli_xpc | Structured questions raised in Plan mode move the task into the conditional Waiting Response board section even when Codex marks the request non-blocking; reopening preserves its status, keyed answers resume In Progress, and successful completion moves it to Review.
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
        self.assertEqual(self.assert_success(task)["status"], "Review")
        saved_draft, _ = self.call_cli("task", "prompt", task_id, "--text", "A follow-up draft.")
        saved_task = self.assert_success(saved_draft)
        self.assertEqual(saved_task["status"], "Review")
        self.assertEqual(saved_task["savedPrompt"], "A follow-up draft.")

    # case-contract: test_codex_empty_question_request_is_rejected | A failed turn preserves its blocked reason and appears in the compact Blocked section above Backlog with a user-intervention indication; retrying clears that section and completes the task into Review.
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
        self.assertEqual(self.assert_success(task)["status"], "Review")

    # case-contract: test_codex_nonblocking_question_keeps_task_in_progress | Non-blocking structured questions remain visible without moving the task out of In Progress, then successful completion moves it to Review.
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
        self.assertEqual(self.assert_success(task)["status"], "Review")

    # case-contract: test_codex_interrupted_turn_blocks_with_reason_and_can_retry | Turn start persists In Progress; reopening while a turn is still active recovers the stale task to Blocked with a reason. Interrupted outcomes persist Blocked across connections, and diagnostics identify the failed turn phase and store path; a new prompt can finish in Review.
    def test_codex_interrupted_turn_blocks_with_reason_and_can_retry(self):
        task_id = self.create_task("Interrupted turn", roots=[self.primary])["id"]
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
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful() or result.testsRun != test_count or result.skipped:
        raise SystemExit("Every discovered bridge test must pass without skips.")
    print(
        f"Bridge suite: total={result.testsRun}, passed={result.testsRun - len(result.failures) - len(result.errors)}, "
        f"skipped={len(result.skipped)}, selected={','.join(selected_cases) if selected_cases else 'all'}"
    )
