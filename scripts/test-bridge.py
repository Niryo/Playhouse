#!/usr/bin/env python3

import argparse
import json
import os
import shutil
import subprocess
import unittest
import uuid
from pathlib import Path


parser = argparse.ArgumentParser()
parser.add_argument("--cli", required=True, type=Path)
parser.add_argument("--fixture-root", required=True, type=Path)
parser.add_argument("--data-root", required=True, type=Path)
parser.add_argument("--service-name", required=True)
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

    def call_cli(self, *command, expected_status=0, timeout=90):
        environment = os.environ.copy()
        environment["STATIONAI_DATA_DIRECTORY"] = str(self.data_directory)
        environment["STATIONAI_E2E_WORKTREE_DIRECTORY"] = str(self.worktree_directory)
        environment["STATIONAI_E2E_DEFAULTS_SUITE"] = self.defaults_suite
        environment["STATIONAI_BRIDGE_SERVICE_NAME"] = arguments.service_name
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

    def create_repo_task(self, title, repositories, branches=None, branch_from=None, roots=None):
        command = ["task", "create", "--title", title]
        for repository in repositories:
            command.extend(["--repo", repository])
        for repository, branch in (branches or {}).items():
            command.extend(["--branch", f"{repository}={branch}"])
        for repository, branch in (branch_from or {}).items():
            command.extend(["--branch-from", f"{repository}={branch}"])
        for root in roots or []:
            command.extend(["--root", root])
        response, _ = self.call_cli(*command)
        return self.assert_success(response)

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
        (self.changes / "deleted.txt").unlink()
        (self.changes / "untracked.txt").write_text("Untracked file.\n", encoding="utf-8")
        self.run_git(self.changes, "rm", "staged-deleted.txt")

    def run_git(self, repository, *arguments):
        completed = subprocess.run(
            ["git", "-C", str(repository), *arguments],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        return completed.stdout

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

    # case-contract: test_task_creation_rejects_invalid_title_roots_and_missing_folder | Blank titles, missing roots, and unavailable roots cannot create a task.
    def test_task_creation_rejects_invalid_title_roots_and_missing_folder(self):
        response, _ = self.call_cli(
            "task", "create", "--title", "   ", "--root", self.primary,
            expected_status=2,
        )
        self.assert_failure(response, "invalid_argument")

        response, _ = self.call_cli(
            "task", "create", "--title", "No roots", expected_status=2
        )
        self.assert_failure(response, "invalid_argument")

        response, _ = self.call_cli(
            "task", "create", "--title", "Missing folder", "--root", self.fixture / "missing",
            expected_status=2,
        )
        self.assert_failure(response, "invalid_argument")

    # case-contract: test_task_creation_persists_ordered_roots_across_fresh_connections | A repository task creates a title-derived worktree and persists its repository, branch, path, and task state across fresh connections.
    def test_task_creation_persists_ordered_roots_across_fresh_connections(self):
        created = self.create_repo_task(
            "Bridge task", [self.primary], branch_from={str(self.primary): "branch-source"}, roots=[self.custom]
        )
        task_id = created["id"]
        self.assertEqual(created["status"], "Backlog")
        self.assertEqual(created["repositoryWorktrees"][0]["repositoryPath"], str(self.primary))
        self.assertEqual(created["repositoryWorktrees"][0]["branch"], "bridge-task")
        self.assertEqual(created["repositoryWorktrees"][0]["branchFrom"], "branch-source")
        self.assertEqual(
            self.run_git(self.primary, "rev-parse", "bridge-task"),
            self.run_git(self.primary, "rev-parse", "branch-source"),
        )
        self.assertNotEqual(
            self.run_git(self.primary, "rev-parse", "bridge-task"),
            self.run_git(self.primary, "rev-parse", "main"),
        )
        self.assertTrue(created["repositoryWorktrees"][0]["worktreePath"].startswith(str(self.worktree_directory)))
        self.assertEqual(created["contextFolders"], [str(self.custom)])
        self.assertEqual(created["workspaceRoots"], [created["repositoryWorktrees"][0]["worktreePath"], str(self.custom)])

        # Each CLI call starts a new process and XPC connection over the same real store.
        response, _ = self.call_cli("task", "get", task_id)
        task = self.assert_success(response)
        self.assertEqual(task["title"], "Bridge task")
        self.assertEqual(task["repositoryWorktrees"], created["repositoryWorktrees"])
        self.assertEqual(task["workspaceRoots"], created["workspaceRoots"])
        response, _ = self.call_cli("board", "list")
        self.assertEqual([task["id"] for task in self.assert_success(response)["tasks"]], [task_id])

    # case-contract: test_task_creation_reuses_existing_branch_worktree | Creating a task for a branch with an existing worktree reuses that exact path.
    def test_task_creation_reuses_existing_branch_worktree(self):
        existing = self.worktree_directory / "external-existing"
        branch = f"already-here-{uuid.uuid4().hex[:8]}"
        self.run_git(self.primary, "worktree", "add", "-b", branch, str(existing), "main")
        task = self.create_repo_task("Reuse branch", [self.primary], branches={str(self.primary): branch})
        self.assertEqual(task["repositoryWorktrees"][0]["worktreePath"], str(existing))
        self.assertFalse(task["repositoryWorktrees"][0]["createdByStationAI"])

    # case-contract: test_task_creation_creates_worktrees_in_multiple_repositories | A task selecting multiple repositories gets one correctly persisted worktree per repository.
    def test_task_creation_creates_worktrees_in_multiple_repositories(self):
        task = self.create_repo_task("Multi repository", [self.secondary, self.primary])
        self.assertEqual([item["repositoryPath"] for item in task["repositoryWorktrees"]], [str(self.secondary), str(self.primary)])
        self.assertEqual([item["branch"] for item in task["repositoryWorktrees"]], ["multi-repository", "multi-repository"])
        self.assertEqual([item["branchFrom"] for item in task["repositoryWorktrees"]], ["main", "main"])
        for repository in [self.secondary, self.primary]:
            self.assertEqual(
                self.run_git(repository, "rev-parse", "multi-repository"),
                self.run_git(repository, "rev-parse", "main"),
            )
        self.assertEqual(task["workspaceRoots"], [item["worktreePath"] for item in task["repositoryWorktrees"]])

    # case-contract: test_task_creation_supports_non_git_folder_only_context | A folder-only task remains usable and persists its context folder without repository worktrees.
    def test_task_creation_supports_non_git_folder_only_context(self):
        task = self.create_task("Folder only", roots=[self.custom])
        self.assertEqual(task["repositoryWorktrees"], [])
        self.assertEqual(task["contextFolders"], [str(self.custom)])
        self.assertEqual(task["workspaceRoots"], [str(self.custom)])

    # case-contract: test_task_creation_rejects_worktree_assigned_to_active_task | A worktree already assigned to another active task is rejected without creating another task.
    def test_task_creation_rejects_worktree_assigned_to_active_task(self):
        first = self.create_repo_task("First owner", [self.primary], branches={str(self.primary): "active-shared"})
        response, _ = self.call_cli(
            "task", "create", "--title", "Second owner", "--repo", self.primary,
            "--branch", f"{self.primary}=active-shared", expected_status=2,
        )
        self.assert_failure(response, "invalid_argument")
        self.assertIn("already assigned", response["error"]["message"])
        self.assertEqual(len(self.assert_success(self.call_cli("task", "list")[0])["tasks"]), 1)
        self.assertTrue(Path(first["repositoryWorktrees"][0]["worktreePath"]).is_dir())

    # case-contract: test_task_done_removes_worktree_and_preserves_branch | Moving a clean task to Done removes its worktree directory and keeps the Git branch.
    def test_task_done_removes_worktree_and_preserves_branch(self):
        task = self.create_repo_task("Done cleanup", [self.primary])
        worktree = Path(task["repositoryWorktrees"][0]["worktreePath"])
        response, _ = self.call_cli("task", "move", task["id"], "Done")
        self.assertEqual(self.assert_success(response)["status"], "Done")
        self.assertFalse(worktree.exists())
        self.assertEqual(self.run_git(self.primary, "show-ref", "--verify", "--quiet", "refs/heads/done-cleanup"), "")

    # case-contract: test_task_done_rejects_dirty_worktree | A task with uncommitted work cannot move to Done and retains its active worktree.
    def test_task_done_rejects_dirty_worktree(self):
        task = self.create_repo_task("Dirty cleanup", [self.primary])
        worktree = Path(task["repositoryWorktrees"][0]["worktreePath"])
        (worktree / "unsaved.txt").write_text("keep me\n", encoding="utf-8")
        response, _ = self.call_cli("task", "move", task["id"], "Done", expected_status=1)
        self.assert_failure(response, "operation_failed")
        self.assertIn("uncommitted changes", response["error"]["message"])
        reread, _ = self.call_cli("task", "get", task["id"])
        self.assertEqual(self.assert_success(reread)["status"], "Backlog")
        self.assertTrue((worktree / "unsaved.txt").is_file())

    # case-contract: test_task_status_transitions_and_rejects_unknown_status | Tasks move through each supported status; invalid status leaves the task unchanged.
    def test_task_status_transitions_and_rejects_unknown_status(self):
        task_id = self.create_task()["id"]
        for status in ["Ready", "In Progress", "Done", "Backlog"]:
            response, _ = self.call_cli("task", "move", task_id, status)
            self.assertEqual(self.assert_success(response)["status"], status)
        response, _ = self.call_cli("task", "move", task_id, "Unknown", expected_status=2)
        self.assert_failure(response, "invalid_argument")
        response, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(response)["status"], "Backlog")

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

    # case-contract: test_task_delete_removes_task_and_later_lookup_is_not_found | Empty tasks and clean worktrees delete without confirmation, dirty worktrees require confirmation, and confirmed deletion removes the managed worktree and task.
    def test_task_delete_removes_task_and_later_lookup_is_not_found(self):
        task = self.create_repo_task("Delete me", [self.primary])
        task_id = task["id"]
        worktree_path = task["repositoryWorktrees"][0]["worktreePath"]
        self.assertTrue(Path(worktree_path).is_dir())
        response, _ = self.call_cli("task", "delete-check", task_id)
        self.assertFalse(self.assert_success(response)["requiresConfirmation"], "An empty task with a clean worktree needs no confirmation.")

        dirty_task = self.create_repo_task("Delete dirty", [self.secondary])
        dirty_task_id = dirty_task["id"]
        dirty_worktree = Path(dirty_task["repositoryWorktrees"][0]["worktreePath"])
        (dirty_worktree / "unsaved-work.txt").write_text("work that needs confirmation\n", encoding="utf-8")
        response, _ = self.call_cli("task", "delete-check", dirty_task_id)
        self.assertTrue(self.assert_success(response)["requiresConfirmation"], "Uncommitted work must require confirmation.")
        dirty_response, _ = self.call_cli("task", "delete", dirty_task_id)
        self.assertTrue(self.assert_success(dirty_response)["deleted"])
        self.assertFalse(dirty_worktree.exists(), "Confirmed deletion must remove the dirty managed worktree.")

        response, _ = self.call_cli("task", "delete", task_id)
        self.assertTrue(self.assert_success(response)["deleted"])
        self.assertFalse(Path(worktree_path).exists(), "Deleting a task must remove its clean managed worktree.")
        response, _ = self.call_cli("task", "get", task_id, expected_status=3)
        self.assert_failure(response, "not_found")
        response, _ = self.call_cli("board", "list")
        self.assertEqual(self.assert_success(response)["tasks"], [])

    # case-contract: test_default_parent_settings_read_write_clear_and_validation | The default parent can be read, changed, cleared, and an unavailable path is rejected.
    def test_default_parent_settings_read_write_clear_and_validation(self):
        response, _ = self.call_cli("settings", "get")
        self.assertIsNone(self.assert_success(response)["defaultParentFolder"])

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

    # case-contract: test_repository_suggestions_skip_nested_repositories_and_symlinks | Suggestions include top-level Git roots and skip nested repositories and symlink targets.
    def test_repository_suggestions_skip_nested_repositories_and_symlinks(self):
        response, _ = self.call_cli("workspace", "suggest", "--parent", self.fixture / "suggested-parent")
        repositories = self.assert_success(response)["repositories"]
        self.assertEqual(repositories, sorted([str(self.primary), str(self.secondary), str(self.alternate), str(self.changes)]))
        self.assertNotIn(str(self.nested), repositories)
        self.assertNotIn(str(self.external), repositories)

    # case-contract: test_task_roots_remain_after_default_parent_is_cleared | Clearing the default parent does not change roots already saved on a task.
    def test_task_roots_remain_after_default_parent_is_cleared(self):
        task_id = self.create_task(title="Persistent task roots")["id"]
        response, _ = self.call_cli("settings", "set-parent", self.fixture / "suggested-parent")
        self.assertEqual(self.assert_success(response)["defaultParentFolder"], str(self.fixture / "suggested-parent"))
        response, _ = self.call_cli("settings", "clear-parent")
        self.assertIsNone(self.assert_success(response)["defaultParentFolder"])
        response, _ = self.call_cli("task", "roots", "get", task_id)
        self.assertEqual(self.assert_success(response)["roots"], [str(self.primary)])

    # case-contract: test_new_task_has_empty_conversation_history | A newly created task shows an empty conversation and has no stored messages or activity.
    def test_new_task_has_empty_conversation_history(self):
        task_id = self.create_task(title="Conversation history")["id"]
        response, _ = self.call_cli("conversation", "history", task_id)
        history = self.assert_success(response)
        self.assertEqual(history["activities"], [])
        self.assertEqual(history["messages"], [])
        self.assertIsNone(history.get("diff"))
    # case-contract: test_conversation_composer_rejects_blank_and_supports_live_turn_controls | Blank drafts cannot be sent or stored; live responses can be paused, continued, and their task activity expanded.
    def test_conversation_composer_rejects_blank_and_supports_live_turn_controls(self):
        task_id = self.create_task(title="Blank conversation send")["id"]
        response, _ = self.call_cli("conversation", "send", task_id, "--message", " ", expected_status=2)
        self.assert_failure(response, "invalid_argument")
        response, _ = self.call_cli("conversation", "history", task_id)
        history = self.assert_success(response)
        self.assertEqual(history["activities"], [])
        self.assertEqual(history["messages"], [])

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

    # case-contract: test_codex_questions_can_be_answered_over_cli_xpc | A CLI/XPC conversation surfaces structured Codex questions, rejects blank answers, accepts keyed option and secret answers, and completes the same turn.
    def test_codex_questions_can_be_answered_over_cli_xpc(self):
        task_id = self.create_task("Codex questions", roots=[self.primary])["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture"
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
            [str(arguments.cli), "conversation", "send", task_id, "--message", "Please ask your questions.",
             "--answer", "color=Blue", "--answer", "token=fixture-secret"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1, env=process_env,
        )
        final = None
        observed_request = None
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
        stderr = process.stderr.read() if process.stderr else ""
        self.assertEqual(process.wait(timeout=30), 0, f"Conversation CLI failed: {final}; {stderr}")
        self.assertIsNotNone(observed_request, "CLI/XPC did not surface Codex's question request.")
        self.assertTrue(final and final.get("ok"), final)
        messages = final["result"]["messages"]
        self.assertTrue(any("Answers received: Blue / fixture-secret." in message["text"] for message in messages))

    # case-contract: test_codex_empty_question_request_is_rejected | An empty Codex question request returns a protocol error and fails the turn without presenting a prompt.
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
    test_count = len(discovered_cases)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful() or result.testsRun != test_count or result.skipped:
        raise SystemExit("Every discovered bridge test must pass without skips.")
    print(f"Bridge suite: total={result.testsRun}, passed={result.testsRun - len(result.failures) - len(result.errors)}, skipped={len(result.skipped)}")
