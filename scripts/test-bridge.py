#!/usr/bin/env python3

import argparse
import json
import os
import shutil
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
parser.add_argument("--case", action="append", default=[], dest="selected_cases")
arguments = parser.parse_args()
CONTRACT_PATH = Path(__file__).resolve().parent.parent / "StationAI/BridgeTests/BridgeTestContracts.json"


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
        cls.nested = cls.primary / "nested"
        cls.external = cls.fixture / "outside-parent" / "linked-outside"
        for path in [cls.primary, cls.secondary, cls.alternate, cls.custom, cls.nested, cls.external]:
            if not path.is_dir():
                raise RuntimeError(f"Missing expected Git repository fixture: {path}")

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

    def assert_success(self, response):
        self.assertTrue(response.get("ok"), response.get("error"))
        return response.get("result")

    def assert_failure(self, response, code):
        self.assertFalse(response.get("ok"))
        self.assertEqual(response.get("error", {}).get("code"), code)

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

    # case-contract: test_service_reports_bridge_version | The real app window opens and the bridge reports StationAI API version 1.
    def test_service_reports_bridge_version(self):
        response, _ = self.call_cli("status")
        self.assertEqual(self.assert_success(response), {"bridgeVersion": 1, "service": "StationAI"})

    # case-contract: test_task_creation_rejects_invalid_title_roots_and_missing_folder | Blank titles, missing roots, unavailable roots, and nonexistent merge targets cannot create a task.
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

        response, _ = self.call_cli(
            "task", "create", "--title", "Missing folder", "--root", self.fixture / "missing",
            expected_status=2,
        )
        self.assert_failure(response, "invalid_argument")

    # case-contract: test_task_creation_persists_ordered_roots_across_fresh_connections | Creating a repository task persists its selected branch settings as pending, shows auto when no branch is chosen, and creates no Git branch or worktree until the first conversation send.
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

        # Each CLI call starts a new process and XPC connection over the same real store.
        response, _ = self.call_cli("task", "get", task_id)
        task = self.assert_success(response)
        self.assertEqual(task["title"], title)
        self.assertEqual(task["repositoryWorktrees"], created["repositoryWorktrees"])
        self.assertEqual(task["workspaceRoots"], created["workspaceRoots"])
        response, _ = self.call_cli("board", "list")
        self.assertEqual([task["id"] for task in self.assert_success(response)["tasks"]], [task_id])

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

    # case-contract: test_task_creation_creates_worktrees_in_multiple_repositories | Selecting multiple repositories persists pending auto branch records without creating branches or worktrees before the task starts.
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

    # case-contract: test_task_creation_rejects_worktree_assigned_to_active_task | A worktree already assigned to another active task is rejected without creating another task.
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

    # case-contract: test_task_done_preserves_worktree_and_branch | Moving a reviewed task to Done preserves its source branch and worktree without merging into the local target, while retaining conversation history and exposing the task in the searchable read-only archive.
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
        self.assertEqual(record["branch"], "please-update-the-readme-and-add-concise-setup")
        worktree = Path(record["worktreePath"])
        target_head = self.run_git(self.primary, "rev-parse", "main")
        self.assertEqual(self.run_git(worktree, "rev-parse", "HEAD"), target_head)
        current, _ = self.call_cli("task", "get", task["id"])
        self.assertEqual(self.assert_success(current)["status"], "Review")
        (self.primary / "target-only.txt").write_text("Master advanced after this task branch was created.\n", encoding="utf-8")
        self.run_git(self.primary, "add", "target-only.txt")
        self.run_git(self.primary, "commit", "-m", "Advance merge target while task is under review")
        target_head = self.run_git(self.primary, "rev-parse", "main")
        response, _ = self.call_cli("task", "move", task["id"], "Done")
        self.assertEqual(self.assert_success(response)["status"], "Done")
        self.assertTrue(worktree.exists(), "Moving a task to Done must preserve its worktree.")
        self.assertTrue(self.branch_exists(self.primary, "please-update-the-readme-and-add-concise-setup"))
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

    # case-contract: test_task_pr_create_reports_real_gh_failure | A repository-backed Done task exposes a PR action in the archive; when the real gh CLI cannot create one for a local repository without a usable GitHub remote, it reports the failure, persists no partial PR link, and preserves Done status.
    def test_task_pr_create_reports_real_gh_failure(self):
        task = self.create_repo_task("PR failure", [self.primary], materialize=True)
        completed, _ = self.call_cli("task", "move", task["id"], "Done")
        self.assertEqual(self.assert_success(completed)["status"], "Done")

        response, _ = self.call_cli("task", "pr", "create", task["id"], expected_status=1)
        self.assert_failure(response, "operation_failed")
        self.assertIn("GitHub CLI", response["error"]["message"])
        current = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        record = current["repositoryWorktrees"][0]
        self.assertIsNone(record.get("pullRequestNumber"))
        self.assertIsNone(record.get("pullRequestURL"))
        self.assertEqual(current["status"], "Done")

    # case-contract: test_done_archive_displays_existing_pull_request_link | A Done task's real SwiftData record can retain a linked PR number and URL across fresh CLI/XPC reads so the archive can render the existing PR link.
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
        (dirty_path / "keep-dirty.txt").write_text("Keep this worktree.\n", encoding="utf-8")
        (self.data_directory / "task-lifecycle-v2-reset").unlink()

        listed, _ = self.call_cli("task", "list")
        self.assertEqual(self.assert_success(listed)["tasks"], [])
        self.assertFalse(clean_path.exists())
        self.assertTrue((dirty_path / "keep-dirty.txt").is_file())
        self.assertEqual(self.run_git(self.primary, "show-ref", "--verify", "--quiet", f"refs/heads/{clean_record['branch']}"), "")
        self.assertEqual(self.run_git(self.secondary, "show-ref", "--verify", "--quiet", f"refs/heads/{dirty_record['branch']}"), "")
        notice = json.loads((self.data_directory / "task-lifecycle-v2-notice.json").read_text(encoding="utf-8"))
        self.assertEqual(notice, [str(dirty_path)])

    # case-contract: test_task_status_transitions_and_rejects_unknown_status | The board keeps stacked Blocked/Backlog and conditional Waiting Response/In Progress sections fully visible, leaves Review as its own column, removes Done from the columns, hides empty status sections, and preserves Codex-owned task status behavior.
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

    # case-contract: test_task_progress_reports_publish_persist_and_clear | The CLI publishes standard and custom progress only during an active task turn, persists each report across fresh CLI/XPC connections, rejects invalid reports, clears explicitly and at turn completion, and the board card shows the built-in icon, label, and detail without changing lifecycle status; each turn receives hidden CLI usage instructions.
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
            turn_data = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
            instructions = turn_data["developerInstructions"]
            self.assertIn(str(self.cli), instructions)
            self.assertIn("task progress publish", instructions)
            self.assertIn("hidden from the conversation", instructions)
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

    # case-contract: test_task_rename_persists_and_rejects_blank_title | A rename persists; rejecting a blank rename preserves the last valid title.
    def test_task_rename_persists_and_rejects_blank_title(self):
        task_id = self.create_task()["id"]
        response, _ = self.call_cli("task", "rename", task_id, "--title", "Renamed through XPC")
        self.assertEqual(self.assert_success(response)["title"], "Renamed through XPC")
        response, _ = self.call_cli("task", "rename", task_id, "--title", " ", expected_status=2)
        self.assert_failure(response, "invalid_argument")
        response, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(response)["title"], "Renamed through XPC")

    # case-contract: test_task_roots_set_get_order_deduplication_and_validation | Root editing preserves order, removes duplicates, and rejects an empty list.
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
        response, _ = self.call_cli("task", "roots", "set", task_id, expected_status=2)
        self.assert_failure(response, "invalid_argument")
        response, _ = self.call_cli("task", "roots", "get", task_id)
        self.assertEqual(self.assert_success(response)["roots"], expected_roots)

    # case-contract: test_conversation_repository_picker_adds_repository_worktree | Repository suggestions can be filtered and navigated with Up/Down, and Enter selects the highlighted repository; adding it persists a pending auto branch with labeled read-only branch, merge-from, and merge-to values, and no worktree exists before the first send.
    def test_conversation_repository_picker_adds_repository_worktree(self):
        task = self.create_task("Add repository in conversation", [self.primary])
        task_id = task["id"]
        self.assertEqual(task["repositoryWorktrees"], [])
        self.assertEqual(task["workspaceRoots"], [str(self.primary)])
        response, _ = self.call_cli("task", "repository", "add", task_id, "--repo", self.primary)
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
    # case-contract: test_task_delete_removes_task_and_later_lookup_is_not_found | The task context menu offers deletion. Pending repository tasks delete without confirmation and preserve the source repository; clean started worktrees can be deleted; dirty started worktrees require confirmation, and canceling preserves the task and worktree. CLI delete-check derives the confirmation requirement from saved task and worktree state without resuming the Codex thread; confirmed deletion removes the managed worktree. Diagnostics identify the conversation failure phase and the persistent log captures a real deletion failure's task, thread, process, phase, and underlying error details without task titles or conversation text; the failed task and worktree remain available for retry.
    def test_task_delete_removes_task_and_later_lookup_is_not_found(self):
        pending = self.create_repo_task("Pending delete", [self.primary])
        pending_id = pending["id"]
        pending_path = pending["repositoryWorktrees"][0]["worktreePath"]
        self.assertTrue(pending["repositoryWorktrees"][0]["isPending"])
        self.assertEqual(pending_path, str(self.primary))
        response, _ = self.call_cli("task", "delete-check", pending_id)
        self.assertFalse(self.assert_success(response)["requiresConfirmation"])
        response, _ = self.call_cli("task", "delete", pending_id)
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
        serialized_diagnostics = json.dumps(diagnostic_lines)
        self.assertNotIn(failure_title, serialized_diagnostics)
        self.assertNotIn(failure_prompt, serialized_diagnostics)
        self.assertTrue(broken_worktree.exists(), "A failed worktree removal must leave its worktree available for recovery.")
        preserved, _ = self.call_cli("task", "get", broken_id)
        self.assertEqual(self.assert_success(preserved)["id"], broken_id)
        moved_repository.rename(broken_repository)
        response, _ = self.call_cli("task", "delete", broken_id)
        self.assertTrue(self.assert_success(response)["deleted"])
        self.assertFalse(broken_worktree.exists())

        response, _ = self.call_cli("board", "list")
        self.assertEqual(self.assert_success(response)["tasks"], [])

    # case-contract: test_default_parent_settings_read_write_clear_and_validation | The default parent can be read, changed, cleared, and an unavailable path is rejected; the ordered last-used repository list persists across fresh CLI/XPC connections and rejects unavailable repositories; Dark and Light appearance choices persist, and Dark renders the workspace canvas as #1E1E1E in the VS Code Dark+ palette.
    def test_default_parent_settings_read_write_clear_and_validation(self):
        response, _ = self.call_cli("settings", "get")
        self.assertIsNone(self.assert_success(response)["defaultParentFolder"])
        self.assertEqual(self.assert_success(response)["appearance"], "dark")

        response, _ = self.call_cli("settings", "set-appearance", "light")
        self.assertEqual(self.assert_success(response)["appearance"], "light")
        response, _ = self.call_cli("settings", "set-appearance", "dark")
        self.assertEqual(self.assert_success(response)["appearance"], "dark")

        response, _ = self.call_cli("settings", "set-parent", self.fixture / "suggested-parent")
        self.assertEqual(self.assert_success(response)["defaultParentFolder"], str(self.fixture / "suggested-parent"))
        response, _ = self.call_cli("settings", "get")
        self.assertEqual(self.assert_success(response)["defaultParentFolder"], str(self.fixture / "suggested-parent"))
        response, _ = self.call_cli("settings", "set-parent", self.fixture / "absent", expected_status=2)
        self.assert_failure(response, "invalid_argument")
        response, _ = self.call_cli("settings", "get")
        self.assertEqual(self.assert_success(response)["defaultParentFolder"], str(self.fixture / "suggested-parent"))
        response, _ = self.call_cli("settings", "clear-parent")
        self.assertIsNone(self.assert_success(response)["defaultParentFolder"])

        response, _ = self.call_cli("settings", "set-last-repositories", "--repo", self.secondary, "--repo", self.primary, "--repo", self.secondary)
        self.assertEqual(self.assert_success(response)["lastSelectedRepositories"], [str(self.secondary), str(self.primary)])
        response, _ = self.call_cli("settings", "get")
        self.assertEqual(self.assert_success(response)["lastSelectedRepositories"], [str(self.secondary), str(self.primary)])
        response, _ = self.call_cli("settings", "set-last-repositories", "--repo", self.fixture / "absent", expected_status=2)
        self.assert_failure(response, "invalid_argument")
        response, _ = self.call_cli("settings", "get")
        self.assertEqual(self.assert_success(response)["lastSelectedRepositories"], [str(self.secondary), str(self.primary)])

    # case-contract: test_repository_suggestions_skip_nested_repositories_and_symlinks | Suggestions include top-level Git roots and skip nested repositories and symlink targets; the picker placeholder shows saved repositories with a Return arrow, and blank Return reuses them in order with auto/default/default branch fields even after a task used custom branch details, while typing and arrow-key selection overrides that default and persists after task creation.
    def test_repository_suggestions_skip_nested_repositories_and_symlinks(self):
        response, _ = self.call_cli("workspace", "suggest", "--parent", self.fixture / "suggested-parent")
        repositories = self.assert_success(response)["repositories"]
        self.assertEqual(repositories, sorted([str(self.primary), str(self.secondary), str(self.alternate), str(self.changes)]))
        self.assertNotIn(str(self.nested), repositories)
        self.assertNotIn(str(self.external), repositories)
        response, _ = self.call_cli(
            "settings", "set-last-repositories", "--repo", self.secondary, "--repo", self.primary
        )
        self.assertEqual(self.assert_success(response)["lastSelectedRepositories"], [str(self.secondary), str(self.primary)])
        response, _ = self.call_cli("settings", "get")
        self.assertEqual(self.assert_success(response)["lastSelectedRepositories"], [str(self.secondary), str(self.primary)])


        response, _ = self.call_cli("settings", "set-last-repositories", "--repo", self.secondary, "--repo", self.primary)
        self.assertEqual(self.assert_success(response)["lastSelectedRepositories"], [str(self.secondary), str(self.primary)])
        response, _ = self.call_cli("settings", "get")
        self.assertEqual(self.assert_success(response)["lastSelectedRepositories"], [str(self.secondary), str(self.primary)])

    # case-contract: test_task_roots_remain_after_default_parent_is_cleared | Clearing the default parent does not change roots already saved on a task.
    def test_task_roots_remain_after_default_parent_is_cleared(self):
        task_id = self.create_task(title="Persistent task roots")["id"]
        response, _ = self.call_cli("settings", "set-parent", self.fixture / "suggested-parent")
        self.assertEqual(self.assert_success(response)["defaultParentFolder"], str(self.fixture / "suggested-parent"))
        response, _ = self.call_cli("settings", "clear-parent")
        self.assertIsNone(self.assert_success(response)["defaultParentFolder"])
        response, _ = self.call_cli("task", "roots", "get", task_id)
        self.assertEqual(self.assert_success(response)["roots"], [str(self.primary)])

    # case-contract: test_new_task_has_empty_conversation_history | Creating a task opens its empty conversation with the repository picker search focused and shows Untitled task until a first prompt starts title generation; the task has no stored messages or activity, and backing out immediately deletes it without a confirmation.
    def test_new_task_has_empty_conversation_history(self):
        response, _ = self.call_cli("task", "create", "--title", "Untitled task")
        task_id = self.assert_success(response)["id"]
        response, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(response)["title"], "Untitled task")
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
    # case-contract: test_conversation_composer_rejects_blank_and_supports_live_turn_controls | Shift+Enter inserts a newline in the composer without sending; multiline prompts persist as typed text, blank drafts cannot be sent or stored, sent prompts persist in conversation history through reload, and sending to an Untitled task persists either the Codex-generated title or a prompt-based fallback when title generation fails. Persistent diagnostics correlate title generation and application outcomes with the task and Codex thread, record failure or skip reasons, and exclude prompt and title text.
    def test_conversation_composer_rejects_blank_and_supports_live_turn_controls(self):
        task_id = self.create_task(title="Blank conversation send", roots=[self.primary])["id"]
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

        title_task = self.create_task("Untitled task", [self.primary])
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-title-success"
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        title_prompt = "Explain the workspace layout briefly."
        sent, _ = self.call_cli(
            "conversation", "send", title_task["id"], "--message", title_prompt,
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        self.assert_success(sent)
        titled, _ = self.call_cli("task", "get", title_task["id"])
        titled_record = self.assert_success(titled)
        self.assertEqual(titled_record["savedPrompt"], title_prompt)
        self.assertEqual(titled_record["title"], "Generated fixture title")
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
        failed_title_task = self.create_task("Untitled task", [self.primary])
        sent, _ = self.call_cli(
            "conversation", "send", failed_title_task["id"], "--message", failure_prompt,
            extra_environment={"STATIONAI_E2E_CODEX_EXECUTABLE": str(failure_executable)},
        )
        self.assert_success(sent)
        failed_title, _ = self.call_cli("task", "get", failed_title_task["id"])
        failed_title_record = self.assert_success(failed_title)
        self.assertEqual(failed_title_record["savedPrompt"], failure_prompt)
        self.assertEqual(failed_title_record["title"], failure_prompt)
        self.assertNotEqual(failed_title_record["title"], "Generating title…")
        failure_events = [
            json.loads(line)
            for line in (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8").splitlines()
            if json.loads(line).get("taskID") == failed_title_task["id"]
            and json.loads(line).get("event", "").startswith("task.title_")
        ]
        generation_failed = next(event for event in failure_events if event["event"] == "task.title_generation.failed")
        fallback_applied = next(event for event in failure_events if event["event"] == "task.title_apply.succeeded")
        self.assertEqual(generation_failed["phase"], "title-turn")
        self.assertTrue(generation_failed["threadID"])
        self.assertTrue(generation_failed.get("errorDescription"))
        self.assertIn("Fixture rejected task-title generation.", generation_failed["errorDescription"])
        self.assertEqual(fallback_applied["titleSource"], "prompt-fallback")
        title_log = json.dumps(title_events + failure_events)
        self.assertNotIn(title_prompt, title_log)
        self.assertNotIn("Generated fixture title", title_log)
        self.assertNotIn(failure_prompt, title_log)

    # case-contract: test_conversation_sends_image_attachments | The conversation composer accepts images from the picker and paste, previews them before sending, sends image-only or text-and-image prompts to Codex using the tagged image URL payload, and displays attached images from reloaded conversation history.
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

    # case-contract: test_conversation_shows_subagent_delegation | When Codex delegates a task to a subagent, the conversation activity shows the delegated task and its completion status during the turn and after history reload.
    def test_conversation_shows_subagent_delegation(self):
        task_id = self.create_task(title="Subagent delegation")["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-subagent"
        shutil.copyfile(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".stationai-codex-fixture-owner").write_text(
            "StationAI test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        env = {"STATIONAI_E2E_CODEX_EXECUTABLE": str(executable)}
        sent, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Delegate this task.",
            extra_environment=env,
        )
        result = self.assert_success(sent)
        activities = result["activities"]
        self.assertEqual(len(activities), 1)
        self.assertEqual(activities[0]["title"], "Task delegated to subagent")
        self.assertEqual(activities[0]["status"], "completed")
        self.assertIn("Inspect the project structure", activities[0]["detail"])
        self.assertIn("Inspected the project structure", activities[0]["detail"])

        reloaded, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        history = self.assert_success(reloaded)
        self.assertEqual(history["activities"], activities)
        self.assertTrue(any("subagent inspected" in message["text"].lower() for message in history["messages"]))

    # case-contract: test_plan_mode_renders_markdown_in_conversation | Selecting Plan mode sends a planning turn; a completed <proposed_plan> is automatically rendered as Markdown without exposing its wrapper tags, including after reopening, while bridge history preserves the exact source.
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
        markdown_reply = "<proposed_plan>\n## Implementation plan\n\nStart with the **workspace model**.\n\n- Add structured conversation rendering\n- Verify history after reopening\n</proposed_plan>"
        sent, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Plan the task.", "--mode", "plan",
            extra_environment=env,
        )
        messages = self.assert_success(sent)["messages"]
        self.assertTrue(any(message["role"] == "assistant" and message["text"] == markdown_reply for message in messages))
        history, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        self.assertTrue(any(message["role"] == "assistant" and message["text"] == markdown_reply for message in self.assert_success(history)["messages"]))

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
        self.assertEqual(send_failure["storePath"], str(self.data_directory / "StationAI.store"))
        self.complete_fixture_turn(task_id, executable_name="codex-fixture-retry")
        task, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(task)["status"], "Review")

    # case-contract: test_task_workspace_changes_group_staged_and_unstaged_diffs | The task view separates staged and working Git changes, and selecting text or JSON files opens a calculated, highlighted side-by-side diff over the conversation.
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
