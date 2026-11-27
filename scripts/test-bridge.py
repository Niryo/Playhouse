#!/usr/bin/env python3

import argparse
import base64
import datetime
import errno
import fcntl
import hashlib
import json
import re
import plistlib
import queue
import os
import select
import signal
import shutil
import shlex
import sqlite3
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.request
import uuid
import zlib
from pathlib import Path

# A CLI run inside a Playhouse conversation inherits the host app's bridge
# socket; every harness subprocess must reach the daemon derived from this
# run's service name instead.
os.environ.pop("PLAYHOUSE_BRIDGE_SOCKET_PATH", None)
# Every CLI call and every daemon it starts inherits this, so task status
# sounds play at volume 0 instead of through the host's speakers.
os.environ["PLAYHOUSE_MUTE_SOUNDS"] = "1"

parser = argparse.ArgumentParser()
parser.add_argument("--cli", required=True, type=Path)
parser.add_argument("--fixture-root", required=True, type=Path)
parser.add_argument("--data-root", required=True, type=Path)
parser.add_argument("--service-name", required=True)
parser.add_argument("--case", action="append", default=[], dest="selected_cases")
arguments = parser.parse_args()
CONTRACT_PATH = Path(__file__).resolve().parent.parent / "Playhouse/BridgeTests/BridgeTestContracts.json"
# A turn that ends unsettled with nothing running earns exactly one private recovery prompt.
OUTCOME_RECOVERY_PROMPTS = 1


















import test_bridge_support as _test_bridge_support
_test_bridge_support.arguments = arguments
from test_bridge_support import *
from bridge_test_cases.helpers_01 import BridgeTestHelpers01
from bridge_test_cases.helpers_02 import BridgeTestHelpers02
from bridge_test_cases.cases_01 import BridgeTestCases01
from bridge_test_cases.cases_02 import BridgeTestCases02
from bridge_test_cases.cases_03 import BridgeTestCases03
from bridge_test_cases.cases_04 import BridgeTestCases04
from bridge_test_cases.cases_05 import BridgeTestCases05
from bridge_test_cases.cases_06 import BridgeTestCases06
from bridge_test_cases.cases_07 import BridgeTestCases07
from bridge_test_cases.cases_08 import BridgeTestCases08
from bridge_test_cases.cases_09 import BridgeTestCases09
from bridge_test_cases.cases_10 import BridgeTestCases10
from bridge_test_cases.cases_11 import BridgeTestCases11
from bridge_test_cases.cases_12 import BridgeTestCases12
from bridge_test_cases.cases_13 import BridgeTestCases13
from bridge_test_cases.cases_14 import BridgeTestCases14
from bridge_test_cases.cases_15 import BridgeTestCases15
from bridge_test_cases.cases_16 import BridgeTestCases16
from bridge_test_cases.cases_17 import BridgeTestCases17
from bridge_test_cases.cases_18 import BridgeTestCases18
from bridge_test_cases.cases_19 import BridgeTestCases19
from bridge_test_cases.cases_20 import BridgeTestCases20
from bridge_test_cases.cases_21 import BridgeTestCases21
from bridge_test_cases.cases_22 import BridgeTestCases22
from bridge_test_cases.cases_23 import BridgeTestCases23
from bridge_test_cases.cases_24 import BridgeTestCases24
from bridge_test_cases.cases_25 import BridgeTestCases25
from bridge_test_cases.cases_26 import BridgeTestCases26
from bridge_test_cases.cases_27 import BridgeTestCases27
from bridge_test_cases.cases_28 import BridgeTestCases28
from bridge_test_cases.cases_29 import BridgeTestCases29
from bridge_test_cases.cases_30 import BridgeTestCases30
from bridge_test_cases.cases_31 import BridgeTestCases31

# The variable each provider's fixture executable is passed in.
PROVIDER_EXECUTABLE_VARIABLES = {
    "codex": "PLAYHOUSE_E2E_CODEX_EXECUTABLE",
    "claude": "PLAYHOUSE_E2E_CLAUDE_EXECUTABLE",
    "opencode": "PLAYHOUSE_E2E_OPENCODE_EXECUTABLE",
}

class PlayhouseBridgeTests(BridgeTestCases01, BridgeTestCases02, BridgeTestCases03, BridgeTestCases04, BridgeTestCases05, BridgeTestCases06, BridgeTestCases07, BridgeTestCases08, BridgeTestCases09, BridgeTestCases10, BridgeTestCases11, BridgeTestCases12, BridgeTestCases13, BridgeTestCases14, BridgeTestCases15, BridgeTestCases16, BridgeTestCases17, BridgeTestCases18, BridgeTestCases19, BridgeTestCases20, BridgeTestCases21, BridgeTestCases22, BridgeTestCases23, BridgeTestCases24, BridgeTestCases25, BridgeTestCases26, BridgeTestCases27, BridgeTestCases28, BridgeTestCases29, BridgeTestCases30, BridgeTestCases31, BridgeTestHelpers01, BridgeTestHelpers02, unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cli = arguments.cli.absolute()
        cls.fixture = arguments.fixture_root.absolute()
        marker = cls.fixture / ".playhouse-bridge-fixture"
        if not marker.is_file() or marker.read_text(encoding="utf-8") != "Playhouse bridge tests own this deterministic fixture (v1).\n":
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
        # The app's default task worktree root inside its data directory; CLI
        # calls send no override, so they exercise that default.
        self.worktree_directory = self.data_directory / "task-worktrees"
        self.worktree_directory.mkdir()
        (self.worktree_directory / ".playhouse-test-owner").write_text("Playhouse bridge test owns this worktree root.\n", encoding="utf-8")
        # An absolute path keeps the isolated preferences file in this case's
        # data directory instead of ~/Library/Preferences.
        self.defaults_suite = str(self.data_directory / "preferences")
        # The store migration cases start from a data directory holding only a SwiftData store.
        if self._testMethodName not in ("test_task_store_migrates_legacy_swiftdata_store", "test_task_store_migrates_current_swiftdata_store"):
            self.assert_success(self.call_cli("settings", "set-parent", self.fixture / "suggested-parent")[0])

    def tearDown(self):
        self.stop_surviving_agents()
        marker = self.worktree_directory / ".playhouse-test-owner"
        if marker.is_file() and marker.read_text(encoding="utf-8") == "Playhouse bridge test owns this worktree root.\n":
            shutil.rmtree(self.worktree_directory)
            for repository in [self.primary, self.secondary, self.alternate, self.changes]:
                subprocess.run(["git", "-C", str(repository), "worktree", "prune"], check=False, capture_output=True)
        else:
            self.fail(f"Refusing to remove worktree fixture without its ownership marker: {self.worktree_directory}")








    def call_cli(self, *command, expected_status=0, timeout=90, extra_environment=None, cli=None):
        environment = os.environ.copy()
        environment["PLAYHOUSE_DATA_DIRECTORY"] = str(self.data_directory)
        environment["PLAYHOUSE_E2E_DEFAULTS_SUITE"] = self.defaults_suite
        environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"] = arguments.service_name
        environment["CODEX_HOME"] = str(self.data_directory / "codex-home")
        # The CLI forwards CLAUDE_CONFIG_DIR; a test sets its own rather than inherit the host's.
        environment.pop("CLAUDE_CONFIG_DIR", None)
        # A provider without the case's fixture reads as not installed, never as the host's own CLI.
        environment["PLAYHOUSE_E2E_CODEX_EXECUTABLE"] = "none"
        environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"] = "none"
        environment["PLAYHOUSE_E2E_OPENCODE_EXECUTABLE"] = "none"
        environment.update(extra_environment or {})
        completed = subprocess.run(
            [str(cli or self.cli), *map(str, command)],
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

    def start_cli(self, *command, extra_environment=None, binary_output=False, cli=None):
        environment = os.environ.copy()
        environment["PLAYHOUSE_DATA_DIRECTORY"] = str(self.data_directory)
        environment["PLAYHOUSE_E2E_DEFAULTS_SUITE"] = self.defaults_suite
        environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"] = arguments.service_name
        environment["CODEX_HOME"] = str(self.data_directory / "codex-home")
        # The CLI forwards CLAUDE_CONFIG_DIR; a test sets its own rather than inherit the host's.
        environment.pop("CLAUDE_CONFIG_DIR", None)
        # A provider without the case's fixture reads as not installed, never as the host's own CLI.
        environment["PLAYHOUSE_E2E_CODEX_EXECUTABLE"] = "none"
        environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"] = "none"
        environment["PLAYHOUSE_E2E_OPENCODE_EXECUTABLE"] = "none"
        environment.update(extra_environment or {})
        return subprocess.Popen(
            [str(cli or self.cli), *map(str, command)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=not binary_output,
            bufsize=0 if binary_output else -1,
            env=environment,
        )







        # The window keeps the turn's activity section open for exactly as long as
        # the daemon reports the turn active, which the runtime reads above assert.
        # The fold itself is SwiftUI state with no CLI-observable surface, so the
        # paired UI case asserts it directly once the daemon state above holds.










    def restart_service_environment(self, provider, executable, **extra):
        """A private bridge service, so a case can kill its daemon without touching the suite's."""
        environment = {
            "PLAYHOUSE_BRIDGE_SERVICE_NAME": f"{arguments.service_name}.restart-{uuid.uuid4().hex[:8]}",
            PROVIDER_EXECUTABLE_VARIABLES[provider]: str(executable),
        }
        environment.update(extra)
        return environment





































    def start_progress_fixture_turn(self, task_id, fixture_name, answers=()):
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / fixture_name
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        copy_file(fixture, executable)
        executable.chmod(0o755)
        environment = os.environ.copy()
        environment.update({
            "PLAYHOUSE_DATA_DIRECTORY": str(self.data_directory),
            "PLAYHOUSE_E2E_WORKTREE_DIRECTORY": str(self.worktree_directory),
            "PLAYHOUSE_E2E_DEFAULTS_SUITE": self.defaults_suite,
            "PLAYHOUSE_BRIDGE_SERVICE_NAME": arguments.service_name,
            "PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable),
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


    def run_git(self, repository, *arguments):
        completed = subprocess.run(
            ["git", "-C", str(repository), *arguments],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, f"{completed.stderr}\n{completed.stdout}")
        return completed.stdout





















































    # The pasteboard, checkmark, and 'Title copied' label clauses are verified only by the paired UI case; this case covers the persisted-title round trip.
























































































































    # Skills






    def create_skills_task(self, title, repositories, provider=None):
        """A task whose repositories already have their managed worktrees."""
        command = ["task", "create", "--title", title, "--prompt", "Fixture task description."]
        if provider:
            command += ["--provider", provider]
        task_id = self.assert_success(self.call_cli(*command)[0])["id"]
        arguments = [argument for repository in repositories for argument in ("--repo", repository)]
        task = self.assert_success(self.call_cli("task", "repository", "add-batch", task_id, *arguments)[0])
        self.assertTrue(all(not record["isPending"] for record in task["repositoryWorktrees"]))
        return task

    def skill_catalog(self, *arguments, task_id=None, extra_environment=None):
        command = ["skills", "list", *arguments]
        if task_id:
            command += ["--task", task_id]
        return self.assert_success(self.call_cli(*command, extra_environment=extra_environment)[0])












    # Rules














    # MCP servers





















    # Plugins: React in JavaScriptCore rendered into native atoms

    TASK_ITEM_ID = "C0FFEE00-0000-4000-8000-000000000001"
















    # Scheduled tasks. Firing goes through ConversationManager.send, the same path the
    # composer's Send and `conversation send` use for both providers, so the schedule
    # behavior is provider-agnostic and Claude's fixture represents both.





    # Installed plugins and Add Plugin mode



    # A sidebar plugin reading the workspace context and calling the workspace host calls.
    PLUGIN_WORKSPACE_SOURCE = """
function Probe() {
  var props = Playhouse.useProps();
  var workspace = props.workspace || {};
  var state = React.useState("idle");
  function report(promise, label) {
    promise.then(function () { state[1](label + ": ok"); }, function (error) { state[1](label + ": " + error.code); });
  }
  function openFirst() {
    if (!props.task) { report(Playhouse.ui.openDiff({ repository: "none", path: "none.txt", group: "unviewed" }), "openDiff"); return; }
    Playhouse.bridge("task.changes.list", { taskID: props.task.id }).then(function (inventory) {
      var entry = inventory.unviewed[0] || { repository: "none", path: "none.txt", group: "unviewed" };
      report(Playhouse.ui.openDiff(entry), "openDiff");
    });
  }
  return h(Stack, { spacing: 4, align: "leading", group: true, testID: "probe" },
    h(Text, { testID: "probe-revision" }, workspace.revision === undefined ? "no workspace" : "revision " + workspace.revision),
    h(Text, { testID: "probe-open" }, workspace.openDiff ? "open " + workspace.openDiff.path : "no diff"),
    h(Text, { testID: "probe-rail" }, props.sidebar ? (props.sidebar.collapsed ? "rail" : "expanded") : "no sidebar"),
    h(Text, { testID: "probe-status" }, state[0]),
    h(Text, { testID: "probe-state" }, "saved " + ((props.state || {}).clicks || 0)),
    h(Button, { testID: "probe-refresh", onPress: function () { report(Playhouse.ui.refreshWorkspace(), "refresh"); } }, h(Text, null, "Refresh")),
    h(Button, { testID: "probe-open-diff", onPress: openFirst }, h(Text, null, "Open first diff")),
    h(Button, { testID: "probe-save", onPress: function () { report(Playhouse.setState("clicks", ((props.state || {}).clicks || 0) + 1), "save"); } }, h(Text, null, "Save")));
}
Playhouse.render(h(Probe));
"""

    # TaskThreadDeveloperInstructions.pluginChangeRule: the editor's setup choices are a starting point.
    PLUGIN_CHANGE_RULE = "When the user asks to change the plugin's name, icon, placement or presentation, update plugin.json to match and keep the plugin ID and folder"
    PLUGIN_CONTEXT_SOURCE = """
function Context() {
  var props = Playhouse.useProps();
  var state = React.useState("idle");
  function report(promise, label) {
    promise.then(function () { state[1](label + ": ok"); }, function (error) { state[1](label + ": " + error.code); });
  }
  var task = props.task;
  var composer = props.composer;
  return h(Stack, { spacing: 6, align: "leading" },
    h(Text, { testID: "plugin-placement" }, props.plugin.placement),
    h(Text, { testID: "plugin-version" }, String(props.plugin.version)),
    h(Text, { testID: "plugin-task" }, task ? task.title : "no task"),
    h(Text, { testID: "plugin-repositories" }, props.repositories ? props.repositories.map(function (r) { return r.repositoryPath.split("/").pop(); }).join(",") : "no repositories"),
    h(Text, { testID: "plugin-draft" }, composer ? composer.draft : "no composer"),
    h(Text, { testID: "plugin-selection" }, composer ? composer.selection.text : "no selection"),
    h(Text, { testID: "plugin-status" }, state[0]),
    h(Button, { testID: "plugin-rename", onPress: function () {
      Playhouse.bridge("task.rename", { taskID: task.id, title: "Renamed by plugin" })
        .then(function (result) { state[1]("renamed: " + result.title); });
    } }, h(Text, null, "Rename")),
    h(Button, { testID: "plugin-missing", onPress: function () {
      Playhouse.bridge("task.get", { taskID: "00000000-0000-4000-8000-00000000dead" })
        .then(function () { state[1]("found"); }, function (error) { state[1]("error: " + error.code); });
    } }, h(Text, null, "Missing")),
    h(Button, { testID: "plugin-upper", onPress: function () {
      Playhouse.ui.composer.replaceSelection(composer.selection.text.toUpperCase());
    } }, h(Text, null, "Uppercase")),
    h(Button, { testID: "plugin-count", onPress: function () {
      Playhouse.bridge("task.list", {}).then(function (result) { state[1]("tasks: " + result.tasks.length); }, function (error) { state[1]("count: " + error.code + " " + error.message); });
    } }, h(Text, null, "Count")),
    h(Button, { testID: "plugin-set-draft", onPress: function () { report(Playhouse.ui.composer.setDraft("fresh draft"), "setDraft"); } }, h(Text, null, "Set draft")),
    h(Button, { testID: "plugin-insert", onPress: function () { report(Playhouse.ui.composer.insertText("!"), "insert"); } }, h(Text, null, "Insert")),
    h(Button, { testID: "plugin-focus", onPress: function () { report(Playhouse.ui.composer.focus(), "focus"); } }, h(Text, null, "Focus")),
    h(Button, { testID: "plugin-recursive", onPress: function () { report(Playhouse.bridge("plugin.render", { page: "Text" }), "render"); } }, h(Text, null, "Render")),
    h(Button, { testID: "plugin-open", onPress: function () {
      Playhouse.bridge("task.list", {}).then(function (result) { return Playhouse.ui.openTask(result.tasks[0].id); });
    } }, h(Text, null, "Open")),
    h(Button, { testID: "plugin-close", onPress: function () { Playhouse.ui.close(); } }, h(Text, null, "Close")));
}
Playhouse.render(h(Context));
"""







    # The Image atom case's picture: 16 x 8, red on the left, blue on the right (also served by plugin-fetch-server.py).
    IMAGE_ATOM_PNG = "iVBORw0KGgoAAAANSUhEUgAAABAAAAAICAIAAAB/FOjAAAAAGElEQVR42mN46uGLFdkl38WKGEY10EIDAHRHvgHbOOZdAAAAAElFTkSuQmCC"
    # The UI case's pluginImageSource is the same script.
    PLUGIN_IMAGE_SOURCE = """
function Avatars() {
  var copies = React.useState(1);
  var avatars = [];
  for (var index = 1; index <= copies[0]; index++) {
    avatars.push(h(Image, { key: index, url: BASE + "/avatar.png", size: 48, circle: true, label: "Avatar " + index, testID: "image-remote-" + index }));
  }
  return h(Stack, { spacing: 12, align: "leading", group: true, testID: "image-plugin" },
    h(Stack, { axis: "h", spacing: 12 }, avatars),
    h(Button, { style: "bordered", testID: "image-add-copy", onPress: function () { copies[1](copies[0] + 1); } }, h(Text, null, "Add a copy")),
    h(Text, { size: 11, testID: "image-copies" }, "Copies: ", String(copies[0])),
    h(Image, { url: FILE, width: 64, height: 32, cornerRadius: 8, label: "Picture from disk", testID: "image-file" }),
    h(Image, { url: BASE + "/avatar.png", size: 24, testID: "image-decorative" }),
    h(Stack, { axis: "h", spacing: 12 },
      h(Image, { url: BASE + "/not-an-image.png", size: 48, placeholder: "person.crop.circle", label: "Not a picture", testID: "image-broken" }),
      h(Image, { url: CLOSED + "/avatar.png", size: 48, placeholder: "person.crop.circle", label: "Unreachable picture", testID: "image-refused" })));
}
Playhouse.render(h(Avatars));
"""
    # The UI case's pluginFetchSource is the same script.
    PLUGIN_FETCH_SOURCE = """
function Fetcher() {
  var greeting = React.useState("loading");
  var status = React.useState("idle");
  React.useEffect(function () {
    fetch(BASE + "/greeting").then(function (response) { return response.json(); })
      .then(function (body) { greeting[1](body.message); }, function (error) { greeting[1]("error: " + error.code); });
  }, []);
  function report(promise) {
    promise.then(function (text) { status[1](text); }, function (error) { status[1]("error: " + error.code); });
  }
  return h(Stack, { spacing: 6 },
    h(Text, { testID: "fetch-greeting" }, greeting[0]),
    h(Text, { testID: "fetch-status" }, status[0]),
    h(Button, { testID: "fetch-get", onPress: function () {
      report(fetch(BASE + "/greeting").then(function (r) {
        return r.json().then(function (body) { return r.status + " " + r.headers.get("X-Fixture") + " " + body.message; });
      }));
    } }, h(Text, null, "Get")),
    h(Button, { testID: "fetch-post", onPress: function () {
      report(fetch(BASE + "/echo", { method: "POST", headers: { "X-Token": "secret", "Content-Type": "application/json" }, body: JSON.stringify({ n: 1 }) })
        .then(function (r) { return r.json(); })
        .then(function (echo) { return echo.method + " " + echo.token + " " + echo.body; }));
    } }, h(Text, null, "Post")),
    h(Button, { testID: "fetch-missing", onPress: function () {
      report(fetch(BASE + "/missing").then(function (r) {
        return r.text().then(function (text) { return r.status + " " + r.ok + " " + text; });
      }));
    } }, h(Text, null, "Missing")),
    h(Button, { testID: "fetch-redirect", onPress: function () {
      report(fetch(BASE + "/redirect").then(function (r) { return r.redirected + " " + r.url.split("/").pop() + " " + r.status; }));
    } }, h(Text, null, "Redirect")),
    h(Button, { testID: "fetch-bare", onPress: function () {
      report(fetch(BASE).then(function (r) { return r.redirected + " " + r.status; }));
    } }, h(Text, null, "Bare")),
    h(Button, { testID: "fetch-refused", onPress: function () {
      report(fetch(CLOSED + "/greeting").then(function () { return "reached"; }));
    } }, h(Text, null, "Refused")),
    h(Button, { testID: "fetch-file", onPress: function () {
      report(fetch("file:///etc/hosts").then(function () { return "read"; }));
    } }, h(Text, null, "File")));
}
Playhouse.render(h(Fetcher));
"""








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
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(PlayhouseBridgeTests)
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
