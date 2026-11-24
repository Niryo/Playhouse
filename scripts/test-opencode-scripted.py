#!/usr/bin/env python3
"""Scripted OpenCode suite: Playhouse drives the real `opencode` binary against a scripted model.

The default suites simulate OpenCode with scripts/fixtures/opencode-serve-fixture.py. This suite
checks the same paths against the OpenCode release installed here, so a change in OpenCode's
server API (`opencode serve`) shows up, while scripts/fixtures/opencode-model-server.py stands in
for the model: no account and no paid tokens. Playhouse's real CLI, daemon and persistence run
each turn, and a turn is carried on by the next daemon after the one that started it is killed.
The token map is rebuilt from the messages OpenCode's server lists, and a plugin agent's JSON
schema run gets its structured answer from OpenCode after one correction. Two tasks on different
folders share one server, which Playhouse starts with no skill, rule or MCP configuration of its
own: each task's model is offered only its own folder's skill, the MCP server in a folder's own
`opencode.json` (scripts/fixtures/opencode-mcp-server.py) reaches the model through Code Mode and
is there again after the server process stops, and a question stays open while that file changes.

The real binary is reached through a wrapper in a folder this run owns, which is how Playhouse
accepts a test's provider executable. The wrapper adds the scripted model provider as an inline
configuration (`OPENCODE_CONFIG_CONTENT`, which Playhouse itself never sets) and points OpenCode's config, data,
state and cache folders into the run's temporary folder, so the user's own OpenCode setup is
never read or written.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

os.environ.pop("PLAYHOUSE_BRIDGE_SOCKET_PATH", None)

OWNER_MARKER = (".playhouse-opencode-fixture-owner", "Playhouse test owns this OpenCode protocol fixture (v1).\n")
WORKTREE_MARKER = "Playhouse live integration suite owns this worktree root.\n"


def require(condition, message):
    if not condition:
        raise AssertionError(message)


WRAPPER = r'''#!/usr/bin/env python3
import json, os, sys
config = json.loads(os.environ.get("OPENCODE_CONFIG_CONTENT") or "{}")
config["provider"] = {"playhouse": {
    "npm": "@ai-sdk/openai-compatible", "name": "Playhouse Scripted",
    "options": {"baseURL": "http://127.0.0.1:%(port)s/v1", "apiKey": "scripted"},
    "models": {"scripted": {"name": "Scripted"}},
}}
config.setdefault("model", "playhouse/scripted")
config["small_model"] = "playhouse/scripted"
# Only the scripted model: OpenCode's own free models load faster, and a turn that started before
# the scripted provider was ready would otherwise reach a real one.
config["enabled_providers"] = ["playhouse"]
os.environ["OPENCODE_CONFIG_CONTENT"] = json.dumps(config)
home = %(home)r
os.environ.update({
    "XDG_CONFIG_HOME": home + "/config", "XDG_DATA_HOME": home + "/data",
    "XDG_STATE_HOME": home + "/state", "XDG_CACHE_HOME": home + "/cache",
    "OPENCODE_DISABLE_MODELS_FETCH": "1", "OPENCODE_DISABLE_AUTOUPDATE": "1",
})
with open(%(log)r, "a") as log:
    log.write(json.dumps({"argv": sys.argv[1:], "cwd": os.getcwd()}) + "\n")
os.execv(%(binary)r, [%(binary)r] + sys.argv[1:])
'''


class Run:
    def __init__(self, cli, binary, fixture):
        self.root = Path(tempfile.mkdtemp(prefix="playhouse-opencode-scripted-"))
        self.cli = cli
        self.first = self.root / "primary"
        self.second = self.root / "secondary"
        shutil.copytree(fixture / "suggested-parent/primary", self.first)
        shutil.copytree(fixture / "suggested-parent/group/secondary", self.second)
        self.data = self.root / "playhouse-data"
        (self.data / "worktrees").mkdir(parents=True)
        (self.data / "worktrees" / ".playhouse-test-owner").write_text(WORKTREE_MARKER, encoding="utf-8")
        self.requests = self.root / "model-requests.jsonl"
        port_file = self.root / "model-port"
        self.server = subprocess.Popen([sys.executable, "-I", str(Path(__file__).resolve().parent / "fixtures" / "opencode-model-server.py"),
                                        str(port_file), str(self.requests)])
        deadline = time.monotonic() + 10
        while not port_file.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        require(port_file.exists(), "The scripted model server did not start.")
        wrapper_folder = self.root / "opencode-bin"
        wrapper_folder.mkdir()
        (wrapper_folder / OWNER_MARKER[0]).write_text(OWNER_MARKER[1], encoding="utf-8")
        self.launches = self.root / "opencode-launches.jsonl"
        self.executable = wrapper_folder / "opencode"
        self.executable.write_text(WRAPPER % {
            "port": port_file.read_text().strip(), "home": str(self.root / "opencode-home"),
            "log": str(self.launches), "binary": str(binary),
        }, encoding="utf-8")
        self.executable.chmod(0o755)
        self.environment = os.environ.copy()
        self.environment.update({
            "PLAYHOUSE_DATA_DIRECTORY": str(self.data),
            "PLAYHOUSE_E2E_WORKTREE_DIRECTORY": str(self.data / "worktrees"),
            "PLAYHOUSE_E2E_DEFAULTS_SUITE": str(self.data / "preferences"),
            "PLAYHOUSE_BRIDGE_SERVICE_NAME": f"com.playhouse.opencode-scripted.{os.getpid()}.bridge",
            "PLAYHOUSE_MUTE_SOUNDS": "1",
            "PLAYHOUSE_E2E_OPENCODE_EXECUTABLE": str(self.executable),
            "PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": "none",
            "PLAYHOUSE_E2E_CODEX_EXECUTABLE": "none",
        })

    def cli_call(self, *command, expected=0, timeout=180):
        completed = subprocess.run([str(self.cli), *map(str, command)], capture_output=True, text=True,
                                   env=self.environment, timeout=timeout, check=False)
        lines = [line for line in completed.stdout.splitlines() if line.strip()]
        require(lines, f"No JSON from {command}: {completed.stderr}")
        response = json.loads(lines[-1])
        require(completed.returncode == expected, f"{command} exited {completed.returncode}: {response}")
        return response.get("result") if response.get("ok") else response

    def wait_for_scripted_model(self, task_id):
        """OpenCode loads the scripted provider a moment after its server starts; a turn waits for it."""
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            if any(m["id"] == "playhouse/scripted" for m in self.cli_call("conversation", "models", task_id)["models"]):
                return
            time.sleep(0.5)
        require(False, "OpenCode offers the scripted model.")

    def model_requests(self):
        if not self.requests.exists():
            return []
        return [json.loads(line)["body"] for line in self.requests.read_text().splitlines() if line.strip()]

    def history(self, task_id):
        return self.cli_call("conversation", "history", task_id)

    def daemon_pid(self):
        return self.cli_call("status")["processID"]

    def opencode_servers(self):
        return [json.loads(p.read_text()) for p in sorted((self.data / "opencode-runs").glob("*.json"))]

    def close(self):
        self.server.terminate()
        subprocess.run([str(self.cli), "daemon", "shutdown"], env=self.environment, capture_output=True, check=False)
        # The OpenCode servers outlive the daemon on purpose; this run stops its own.
        for server in self.opencode_servers():
            pid = (server.get("process") or {}).get("pid")
            if pid:
                try:
                    os.kill(pid, 15)
                except OSError:
                    pass
        if os.environ.get("PLAYHOUSE_OPENCODE_SCRIPTED_KEEP") == "1":
            print(f"Kept {self.root}")
        else:
            shutil.rmtree(self.root, ignore_errors=True)


def answer_starting(history, prefix, after=None):
    """The text of the answer a scenario turn gave. The scripted model reports no task outcome, so
    Playhouse follows each turn with its one outcome nudge, which the model answers too."""
    messages = history["messages"]
    if after:
        messages = messages[max(i for i, m in enumerate(messages) if after in m["text"]):]
    return next((m["text"] for m in messages if m["role"] == "assistant" and m["text"].startswith(prefix)), "")


def scenario_tools_resume_and_models(run):
    task = run.cli_call("task", "create", "--title", "Scripted OpenCode", "--prompt", "Fixture task description.",
                        "--provider", "opencode", "--root", run.first, "--root", run.second)
    run.wait_for_scripted_model(task["id"])
    models = run.cli_call("conversation", "models", task["id"])["models"]
    require(any(m["id"] == "playhouse/scripted" for m in models), f"The scripted model is offered: {models}")
    run.cli_call("conversation", "model", task["id"], "set", "playhouse/scripted")
    run.cli_call("conversation", "send", task["id"], "--message", "[[scenario:write]] Write the notes file.")
    notes = run.first / "notes.txt"
    require(notes.is_file() and "scripted model" in notes.read_text(), "OpenCode's write tool wrote notes.txt in the task's folder.")
    history = run.history(task["id"])
    require(any(a["title"] == "Editing 1 file" and a["status"] == "completed" for a in history["activities"]), f"The edit row: {history['activities']}")
    require(answer_starting(history, "Scripted answer (write)."), f"The final answer: {history['messages']}")
    session = run.cli_call("task", "get", task["id"])["openCodeSessionID"]
    require(session and session.startswith("ses_"), f"The task keeps OpenCode's session ID: {session}")
    system = " ".join(m["content"] if isinstance(m["content"], str) else json.dumps(m["content"])
                      for m in run.model_requests()[-1]["messages"] if m["role"] == "system")
    require(task["id"] in system, "Playhouse's instructions reached OpenCode's system prompt through the session's instruction entry.")
    require(str(run.second) in system or str(run.second.resolve()) in system,
            "The task's second root reached OpenCode's system prompt.")

    run.cli_call("conversation", "send", task["id"], "--message", "[[scenario:bash]] Run the check.")
    history = run.history(task["id"])
    require(any(a["title"] == "Running echo hello-from-scripted" and a["status"] == "completed" for a in history["activities"]),
            f"The shell row: {history['activities']}")
    require("hello-from-scripted" in answer_starting(history, "Scripted answer (bash)."), f"The command's output reached the model: {history['messages']}")
    require(run.cli_call("task", "get", task["id"])["openCodeSessionID"] == session, "The second turn resumed the same session.")
    users = [m for m in run.model_requests()[-1]["messages"] if m["role"] == "user"]
    require(any("Write the notes file." in json.dumps(m) for m in users), "The resumed session still holds the first turn.")
    launches = [json.loads(line) for line in run.launches.read_text().splitlines()]
    served = [entry for entry in launches if entry["argv"][:1] == ["serve"]]
    require(served and all(entry["argv"] in (["serve", "--hostname", "127.0.0.1", "--port", "0"], ["--version"]) for entry in launches),
            f"Playhouse only ever runs `opencode serve` (after checking its version): {launches}")
    require(all(server["port"] and server["process"] for server in run.opencode_servers()), "Each server records its port and process.")
    return "tools, resume and models"


def scenario_question_plan_and_stop(run):
    task = run.cli_call("task", "create", "--title", "Scripted OpenCode questions", "--prompt", "Fixture task description.",
                        "--provider", "opencode", "--root", run.first)
    run.wait_for_scripted_model(task["id"])
    run.cli_call("conversation", "send", task["id"], "--message", "[[scenario:question]] Ask me.", "--answer", "question-1=Blue")
    answer = answer_starting(run.history(task["id"]), "Scripted answer (question).")
    require("Blue" in answer, f"OpenCode's question tool returned the answer Playhouse gave through its form: {answer}")

    def changes():
        return subprocess.run(["git", "-C", str(run.first), "status", "--porcelain"], capture_output=True, text=True).stdout
    before = changes()
    run.cli_call("conversation", "send", task["id"], "--message", "[[scenario:write]] Plan only.", "--mode", "plan")
    require(not (run.first / "notes.txt").exists(), "Plan mode wrote no file in the repository.")
    plan_answer = answer_starting(run.history(task["id"]), "Scripted answer (write).", after="Plan only.")
    require("Plan directory" in plan_answer or "plan" in plan_answer.lower(),
            f"OpenCode's plan agent refused the edit outside its plan folder: {plan_answer}")
    require(changes() == before, "Plan mode changed no repository file.")

    sender = subprocess.Popen([str(run.cli), "conversation", "send", task["id"], "--message", "[[scenario:slow]] Wait."],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=run.environment)
    # The model's first request for this prompt answers with the `sleep 30` call; stop while it runs.
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline and not any("[[scenario:slow]]" in json.dumps(r["messages"][-1:]) for r in run.model_requests()):
        time.sleep(0.2)
    time.sleep(2)
    run.cli_call("conversation", "stop", task["id"])
    sender.communicate(timeout=60)
    status = run.cli_call("task", "get", task["id"])
    require(status["status"] == "Waiting Response" and not status.get("statusMessage"), f"Stop settles the turn: {status}")
    return "question, plan and stop"


def scenario_turn_survives_daemon_restart(run):
    task = run.cli_call("task", "create", "--title", "Scripted OpenCode restart", "--prompt", "Fixture task description.",
                        "--provider", "opencode", "--root", run.first)
    run.wait_for_scripted_model(task["id"])
    run.cli_call("conversation", "send", task["id"], "--message", "Warm up the session.")
    sender = subprocess.Popen([str(run.cli), "conversation", "send", task["id"], "--message", "[[scenario:slow]] Survive a restart."],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=run.environment)
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline and not any("Survive a restart." in json.dumps(r["messages"][-1:]) for r in run.model_requests()):
        time.sleep(0.2)
    session = run.cli_call("task", "get", task["id"])["openCodeSessionID"]
    require(any(session in server["turns"] for server in run.opencode_servers()), "The running turn is recorded on its server.")
    server_pid = next(server["process"]["pid"] for server in run.opencode_servers() if session in server["turns"])
    os.kill(run.daemon_pid(), 9)
    sender.communicate(timeout=60)
    os.kill(server_pid, 0)  # The OpenCode server outlives the daemon that started it.
    run.cli_call("task", "get", task["id"])  # The next daemon starts and follows the turn.
    deadline = time.monotonic() + 90
    answer = ""
    while time.monotonic() < deadline and not answer:
        answer = answer_starting(run.history(task["id"]), "Scripted answer (slow).")
        time.sleep(1)
    require(answer, f"The next daemon recorded the answer OpenCode gave after the restart: {run.history(task['id'])['messages']}")
    texts = [m["text"] for m in run.history(task["id"])["messages"]]
    require(sum(text.startswith("Scripted answer (slow).") for text in texts) == 1, f"The answer is recorded once: {texts}")
    return "turn survives a daemon restart"


def scenario_shared_server_native_discovery(run):
    """One shared server, used the way OpenCode is used directly: each task's folder brings its own
    skills and `opencode.json` MCP servers, which survive a server restart with nothing restored,
    and a question stays open while the folder's config changes."""
    server = Path(__file__).resolve().parent / "fixtures" / "opencode-mcp-server.py"
    (run.first / "opencode.json").write_text(json.dumps({"mcp": {"ocscripted": {
        "type": "local", "command": [sys.executable, "-I", str(server), "ocscripted"]}}}), encoding="utf-8")
    for folder, name in [(run.first, "ocfirstskill"), (run.second, "ocsecondskill")]:
        skill = folder / ".agents" / "skills" / name
        skill.mkdir(parents=True, exist_ok=True)
        (skill / "SKILL.md").write_text(f"---\nname: {name}\ndescription: The {name} skill of this folder\n---\n\nSay {name}.\n", encoding="utf-8")
    task = run.cli_call("task", "create", "--title", "Scripted OpenCode MCP", "--prompt", "Fixture task description.",
                        "--provider", "opencode", "--root", run.first)
    other = run.cli_call("task", "create", "--title", "Scripted OpenCode other", "--prompt", "Fixture task description.",
                         "--provider", "opencode", "--root", run.second)
    run.wait_for_scripted_model(task["id"])
    run.cli_call("conversation", "model", task["id"], "set", "playhouse/scripted")
    run.cli_call("conversation", "model", other["id"], "set", "playhouse/scripted")
    run.cli_call("conversation", "send", task["id"], "--message", "[[scenario:mcp-ocscripted]] Ping the server.")
    answer = answer_starting(run.history(task["id"]), "Scripted answer (mcp-ocscripted).")
    require("pong-from-ocscripted" in answer, f"The model reached the folder's own MCP server through Code Mode: {answer}")
    first_request = json.dumps([r for r in run.model_requests() if "Ping the server." in json.dumps(r["messages"])][0])
    require("ocfirstskill" in first_request and "ocsecondskill" not in first_request, "The first task's model is offered its own folder's skill only.")
    run.cli_call("conversation", "send", other["id"], "--message", "Hello from the other folder.")
    other_request = json.dumps([r for r in run.model_requests() if "Hello from the other folder." in json.dumps(r["messages"])][0])
    require("ocsecondskill" in other_request and "ocfirstskill" not in other_request, "The second task's model is offered its own folder's skill only.")
    servers = run.opencode_servers()
    require(len(servers) == 1, f"Both tasks run on one server: {servers}")

    # The server process stops; the next turn's new server finds the folder's server itself.
    os.kill(servers[0]["process"]["pid"], 9)
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline and any((s.get("process") or {}).get("pid") == servers[0]["process"]["pid"] for s in run.opencode_servers()):
        time.sleep(0.2)
    run.cli_call("conversation", "send", task["id"], "--message", "[[scenario:mcp-ocscripted]] Ping it again.")
    again = answer_starting(run.history(task["id"]), "Scripted answer (mcp-ocscripted).", after="Ping it again.")
    require("pong-from-ocscripted" in again, f"After the server stopped, the same task reaches the server again: {again}")

    # A question stays open while the folder's own opencode.json changes.
    sender = subprocess.Popen([str(run.cli), "conversation", "send", task["id"], "--message", "[[scenario:question]] Ask me."],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=run.environment)
    pending = None
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline and not pending:
        pending = run.history(task["id"]).get("pendingUserInputRequest")
        time.sleep(0.3)
    require(pending, "OpenCode asked its question.")
    config_file = run.first / "opencode.json"
    config = json.loads(config_file.read_text(encoding="utf-8"))
    config["mcp"]["ocscripted-extra"] = {"type": "local", "command": [sys.executable, "-I", str(server), "extra"]}
    staged = config_file.with_suffix(".staged")
    staged.write_text(json.dumps(config), encoding="utf-8")
    os.replace(staged, config_file)
    time.sleep(3)
    run.cli_call("conversation", "answer-user-input", task["id"], pending["id"], "--answer", "question-1=Blue")
    sender.communicate(timeout=90)
    # OpenCode may tell the model about the new MCP server in a message of its own after the answer, so
    # the answer is checked where the model received it: the question tool's result.
    answered = [r for r in run.model_requests() if "Ask me." in json.dumps(r["messages"])
                and any(m.get("role") == "tool" and "Blue" in json.dumps(m.get("content")) for m in r["messages"])]
    require(answered, "The question survived the config change and its answer reached the model.")
    require(answer_starting(run.history(task["id"]), "Scripted answer", after="Ask me."), "The turn finished with OpenCode's answer.")
    return "shared server native discovery and question"


AGENT_LISTENER = """
Playhouse.service.on("agent.finished", function (e) { return Playhouse.setState("finished", { status: e.status, result: e.result, error: e.error }); });
"""


def scenario_token_map_and_structured_agent(run):
    task = run.cli_call("task", "create", "--title", "Scripted OpenCode tokens", "--prompt", "Fixture task description.",
                        "--provider", "opencode", "--root", run.first)
    run.wait_for_scripted_model(task["id"])
    run.cli_call("conversation", "model", task["id"], "set", "playhouse/scripted")
    run.cli_call("conversation", "send", task["id"], "--message", "[[scenario:bash]] Run the check.")
    session = run.cli_call("task", "get", task["id"])["openCodeSessionID"]
    require((run.data / "opencode-request-logs" / f"{session}.jsonl").is_file(), "The turn wrote its session's messages beside the store.")
    requests = [r for r in run.model_requests() if r.get("tools")]
    waste = run.cli_call("task", "token-waste", task["id"])
    main = next((agent for agent in waste["agents"] if agent["id"] == "opencode"), None)
    require(main and main["requests"] == len(requests), f"Each model request OpenCode made is one request of the map: {waste['agents']} vs {len(requests)}")
    page = run.cli_call("task", "raw-input", task["id"], "--scope", "request")
    request = page["request"]
    require(request["note"].startswith("Reconstructed: OpenCode"), f"The request is rebuilt from OpenCode's messages: {request}")
    require(request["itemTokens"] == request["contextTokens"], f"The items add up to the input OpenCode reported: {request}")
    first = requests[0]
    unseen = (len(json.dumps([m for m in first["messages"] if m["role"] == "system"])) + len(json.dumps(first["tools"]))) // 4
    hidden = next(row for row in waste["overhead"] if row["kind"] == "hiddenOverhead")
    require(abs(hidden["tokens"] - unseen) <= unseen * 0.35,
            f"The hidden overhead measures OpenCode's system prompt and tools ({unseen} tokens sent): {hidden}")
    require(any(row["kind"] == "toolResult" and row["label"] == "shell" for row in page["rows"]), f"The shell result is an item: {page['rows']}")

    # A plugin agent asked for JSON gets it from OpenCode, after one correction.
    plugin = run.data / "plugins" / "oc-schema"
    plugin.mkdir(parents=True)
    (plugin / "plugin.json").write_text(json.dumps({"id": "oc-schema", "name": "OC Schema", "icon": "puzzlepiece.extension", "placement": "composerActions",
                                                    "presentation": "headless", "events": ["agent.finished"]}), encoding="utf-8")
    (plugin / "index.js").write_text(AGENT_LISTENER, encoding="utf-8")
    schema = {"type": "object", "properties": {"title": {"type": "string"}, "priority": {"type": "integer"}}, "required": ["title", "priority"]}
    run.cli_call("agent", "run", "--plugin", "oc-schema", "--provider", "opencode", "--model", "playhouse/scripted",
                 "--prompt", "[[scenario:json]] File the task.", "--json-schema", json.dumps(schema), "--cwd", run.first)
    deadline = time.monotonic() + 90
    finished = None
    while time.monotonic() < deadline and not finished:
        finished = (run.cli_call("plugin", "state", "--id", "oc-schema").get("state") or {}).get("finished")
        time.sleep(0.5)
    require(finished and finished["status"] == "done" and finished["result"] == {"title": "Scripted task", "priority": 2},
            f"The corrected answer is the structured result: {finished}")
    asked = [r for r in run.model_requests() if "[[scenario:json]]" in json.dumps(r["messages"])]
    require(any("didn't match the JSON Schema: the answer isn't JSON." in json.dumps(r["messages"][-1:]) for r in asked),
            "Playhouse asked OpenCode once more, in the same session, naming what was wrong.")
    return "token map and structured agent"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--opencode", default=os.environ.get("PLAYHOUSE_OPENCODE_BINARY") or shutil.which("opencode"))
    arguments = parser.parse_args()
    require(arguments.opencode and Path(arguments.opencode).is_file(),
            "Install OpenCode or pass --opencode <path> (PLAYHOUSE_OPENCODE_BINARY).")
    binary = Path(arguments.opencode).resolve()
    version = subprocess.run([str(binary), "--version"], capture_output=True, text=True).stdout.strip()
    app_bundle = Path(os.environ["PLAYHOUSE_APP_PATH"])
    cli = app_bundle / "Contents/MacOS/playhouse-cli"
    fixture = Path(os.environ["PLAYHOUSE_BRIDGE_TEST_FIXTURE_ROOT"])
    print(f"Scripted OpenCode suite against {binary} ({version})", flush=True)
    passed = []
    for scenario in (scenario_tools_resume_and_models, scenario_question_plan_and_stop, scenario_turn_survives_daemon_restart,
                     scenario_token_map_and_structured_agent, scenario_shared_server_native_discovery):
        run = Run(cli, binary, fixture)
        started = time.monotonic()
        try:
            print(f"OpenCode scripted: {scenario.__name__} ...", flush=True)
            passed.append(scenario(run))
            print(f"OpenCode scripted: {scenario.__name__} passed in {time.monotonic() - started:.1f}s", flush=True)
        finally:
            run.close()
    print(f"Scripted OpenCode suite passed ({len(passed)} scenarios): {', '.join(passed)}")


if __name__ == "__main__":
    main()
