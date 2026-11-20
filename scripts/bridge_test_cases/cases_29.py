from test_bridge_support import *
from test_bridge_support import __file__


class BridgeTestCases29:
    """Script plugins' background halves: services, mcp.call and agent.run."""

    # One index.js with both halves: the popover shows what the service saved.
    SERVICE_PLUGIN_SOURCE = r"""
function Panel() {
  var props = Playhouse.useProps();
  var state = props.state || {};
  return h(Stack, { spacing: 4 },
    h(Text, { testID: "service-focused" }, "focused " + (state.focused || 0)),
    h(Text, { testID: "service-heard" }, "heard " + (state.heard || []).join(",")),
    h(Text, { testID: "service-active" }, "service " + Playhouse.service.active));
}
Playhouse.service.on("app.focus", async function (event) {
  var state = Playhouse.props.state || {};
  await Playhouse.setState("focused", (state.focused || 0) + 1);
});
// No guard against its own writes: a service never hears those, so this can't loop.
Playhouse.service.on("plugin.stateChanged", async function (event) {
  var heard = (Playhouse.props.state || {}).heard || [];
  await Playhouse.setState("heard", heard.concat([event.payload.pluginID + ":" + event.key]));
});
Playhouse.render(h(Panel));
"""

    # Listens for app.focus in its script but its manifest lists only task moves.
    QUIET_PLUGIN_SOURCE = r"""
Playhouse.service.on("app.focus", function () { return Playhouse.setState("focused", true); });
Playhouse.service.on("task.statusChanged", function (event) { return Playhouse.setState("moved", event.to); });
Playhouse.service.on("plugin.stateChanged", function (event) {
  if (event.key !== "heard") return Playhouse.setState("heard", event.payload.pluginID + ":" + event.key);
});
"""

    # Writes the other plugin's state whenever its own "ball" changes, so two of them would
    # wake each other forever if a chain of events had no end.
    PING_PONG_SOURCE = r"""
Playhouse.service.on("plugin.stateChanged", async function (event) {
  if (event.key !== "ball") return;
  var self = Playhouse.props.plugin.id;
  var hits = ((Playhouse.props.state || {}).hits || 0) + 1;
  await Playhouse.setState("hits", hits);
  await Playhouse.bridge("plugin.state.set", { pluginID: self === "ping-service" ? "pong-service" : "ping-service", key: "ball", value: hits });
});
"""

    HEADLESS_HANDLERS_SOURCE = r"""
Playhouse.service.on("app.focus", async function () {
  var tasks = await Playhouse.bridge("task.list", {});
  await Playhouse.setState("tasks", tasks.tasks.length);
  try { await Playhouse.ui.close(); } catch (error) { await Playhouse.setState("ui", error.code); }
  try { await Playhouse.bridge("plugin.services", {}); } catch (error) { await Playhouse.setState("internal", error.code); }
  try {
    var answer = await Playhouse.mcp.call("mcp__claude_ai_Slack__slack_read_user_profile", { user: "U1" });
    await Playhouse.setState("mcp", answer.content[0].text);
  } catch (error) { await Playhouse.setState("mcp", error.code); }
  try {
    var run = await Playhouse.agent.run({ prompt: "Summarize", context: { kind: "probe" } });
    await Playhouse.setState("run", run.runID);
  } catch (error) { await Playhouse.setState("run", error.code); }
});
Playhouse.service.on("agent.finished", async function (e) {
  await Playhouse.setState("finished", { status: e.status, kind: e.context.kind, title: e.result.title, runID: e.runID, same: e.payload.runID === e.runID });
});
Playhouse.service.on("task.statusChanged", function () { throw new Error("The move handler broke."); });
Playhouse.render(h(Text, { testID: "never" }, "never rendered"));
"""

    POPOVER_CALLS_SOURCE = r"""
function Calls() {
  var result = React.useState("idle");
  function call() {
    Playhouse.mcp.call("mcp__claude_ai_Slack__slack_read_user_profile", {}).then(
      function (answer) { result[1]("mcp " + answer.content[0].text); },
      function (error) { result[1]("mcp " + error.code); });
  }
  function run() {
    Playhouse.agent.run({ prompt: "Go", context: { kind: "ui" } }).then(
      function (answer) { result[1]("run " + answer.runID); },
      function (error) { result[1]("run " + error.code); });
  }
  var off = Playhouse.service.on("app.focus", function () { result[1]("service handler ran in the UI"); });
  return h(Stack, {},
    h(Button, { testID: "call-mcp", onPress: call }, h(Text, {}, "MCP")),
    h(Button, { testID: "call-agent", onPress: run }, h(Text, {}, "Agent")),
    h(Text, { testID: "call-result" }, result[0] + (Playhouse.service.active ? " (service)" : "")));
}
Playhouse.render(h(Calls));
"""

    MCP_SERVICE_SOURCE = r"""
Playhouse.service.on("app.focus", async function () {
  var answer = await Playhouse.mcp.call("mcp__claude_ai_Slack__slack_search_public_and_private", { query: "to:me", channel_types: "im" });
  await Playhouse.setState("people", answer.content.map(function (block) { return block.text; }));
  // Not in the manifest's mcpTools: refused before Claude Code is asked.
  try { await Playhouse.mcp.call("mcp__claude_ai_Slack__slack_read_user_profile", {}); } catch (error) { await Playhouse.setState("denied", error.code); }
});
function People() {
  var people = (Playhouse.useProps().state || {}).people || [];
  return h(Text, { testID: "mcp-people" }, people.length ? people.join(", ") : "nobody yet");
}
Playhouse.render(h(People));
"""

    # The Slack reader's background half on Codex.
    CODEX_MCP_SERVICE_SOURCE = r"""
Playhouse.service.on("app.focus", async function () {
  var answer = await Playhouse.mcp.call("mcp__claude_ai_Slack__slack_search_public_and_private", { query: "to:me" }, { provider: "codex" });
  await Playhouse.setState("people", answer.content.map(function (block) { return block.text; }));
});
function People() {
  var people = (Playhouse.useProps().state || {}).people || [];
  return h(Text, { testID: "mcp-people" }, people.length ? people.join(", ") : "nobody yet");
}
Playhouse.render(h(People));
"""

    # Waits on a slow MCP tool when a task moves, writing before and after it.
    SLOW_SERVICE_SOURCE = r"""
Playhouse.service.on("task.statusChanged", async function (event) {
  await Playhouse.setState("before", event.to);
  await Playhouse.mcp.call("mcp__claude_ai_Slack__slack_read_channel", { channel_id: "D1" });
  await Playhouse.setState("after", event.to);
});
"""

    # Another plugin listening for agent results; it must never hear slack-dms's.
    LISTENER_SOURCE = r"""
Playhouse.service.on("agent.finished", function (e) { return Playhouse.setState("finished", e.runID); });
"""

    AGENT_PLUGIN_SOURCE = r"""
var TASK_SCHEMA = { type: "object", properties: { title: { type: "string" }, prompt: { type: "string" }, nothingNew: { type: "boolean" } }, required: ["title", "prompt", "nothingNew"] };
function onCreate(userId) {
  var jobs = (Playhouse.props.state || {}).jobs || {};
  // The plugin's "provider" setting picks the agent; each has its own model names.
  var provider = (Playhouse.props.state || {}).provider;
  Playhouse.agent.run({ prompt: "Read the DMs of " + userId + " and draft a task.", provider: provider, model: provider === "codex" ? "gpt-5.5" : "opus",
    allowedTools: ["mcp__claude_ai_Slack__slack_read_channel", "mcp__claude_ai_Slack__slack_read_thread"],
    jsonSchema: TASK_SCHEMA, context: { kind: "slack-task", userId: userId } })
    .then(function (r) { var next = Object.assign({}, jobs); next[userId] = r.runID; return Playhouse.setState("jobs", next); });
}
function DMs() {
  var state = Playhouse.useProps().state || {};
  var finished = state.finished;
  return h(Stack, { spacing: 6 },
    h(Button, { style: "bordered", testID: "dm-create-U7", onPress: function () { onCreate("U7"); } }, h(Text, {}, "Create task for Dana")),
    h(Text, { testID: "dm-job" }, (state.jobs || {}).U7 ? "running" : "no job"),
    h(Text, { testID: "dm-finished" }, finished ? finished.status + " " + finished.userId + " " + (finished.error || finished.title || "") : "not finished"));
}
Playhouse.service.on("agent.finished", async function (e) {
  if (e.context.kind !== "slack-task") return;
  var title = null;
  if (e.status === "done" && !e.result.nothingNew) {
    var created = await Playhouse.bridge("task.create", { title: e.result.title, prompt: e.result.prompt, roots: [], repositories: [] });
    title = created.title;
  } else if (e.status !== "done") {
    // A run that didn't finish is put on the board, so the user sees it.
    await Playhouse.bridge("task.create", { title: "Slack task " + e.status + " for " + e.context.userId + (e.error ? ": " + e.error : ""),
      prompt: "Draft the Slack task for " + e.context.userId + " again.", roots: [], repositories: [] });
  }
  var jobs = Object.assign({}, (Playhouse.props.state || {}).jobs || {});
  if (jobs[e.context.userId] === e.runID) delete jobs[e.context.userId];
  await Playhouse.setState("jobs", jobs);
  await Playhouse.setState("finished", { status: e.status, userId: e.context.userId, runID: e.runID, error: e.error, title: title });
});
Playhouse.render(h(DMs));
"""

    def plugin_state(self, plugin_id, environment=None):
        return self.assert_success(self.call_cli("plugin", "state", "--id", plugin_id, extra_environment=environment)[0])["state"]

    def write_service_file(self, source):
        path = self.data_directory / f"service-{uuid.uuid4().hex[:8]}.js"
        path.write_text(source, encoding="utf-8")
        return path

    # case-contract: test_plugin_service_events_targeting_and_state | A plugin.json may list "events" (app events from PluginEvent's names, agent.finished included) for a background half next to any presentation, and a headless plugin is valid with only events; an unknown or repeated event, an mcpTools entry that isn't mcp__<server>__<tool>, or a headless plugin with neither commands nor events is reported in its errors. `plugin service --file` runs the script's Playhouse.service.on handlers headlessly in a fresh service runtime per event, where Playhouse.render does nothing: bridge calls are answered, ui calls are refused as unavailable, plugin.services is refused as invalid_argument, mcp.call and agent.run are unavailable unless --mock answers them (also by tool), agent.finished is injected with a fake result whose fields and context reach the handler beside payload, an unknown event is invalid_argument, and the report lists each event's handler count, the bridge calls, the state written and a throwing handler's error (exit 1). In a mounted UI (plugin render) Playhouse.service.on does nothing and mcp.call or agent.run is unavailable unless mocked. In the daemon, app.focus (from the window's activation or plugin event) wakes only the enabled plugins whose manifest lists it, collapsing quick repeats into one trailing run after the cooldown; a plugin's state change is targeted at it, so its own service hears a change made elsewhere while another plugin's service doesn't, and a service never hears its own writes, so a handler that saves on every change doesn't loop; two services that each write the other's state whenever their own changes stop after a bounded chain of events, each running four times for the eight events a chain may reach, instead of waking each other for as long as the daemon lives; the service writes state that the popover shows from its props, and a disabled plugin's service isn't woken by a focus that still reaches an enabled one.
    def test_plugin_service_events_targeting_and_state(self):
        # Manifest validation.
        self.write_installed_plugin("bad-events", self.QUIET_PLUGIN_SOURCE, placement="composerActions", presentation="headless",
                                    manifest={"events": ["app.focus", "app.focus", "nope"], "mcpTools": ["slack_read"]})
        self.write_installed_plugin("bare-headless", self.QUIET_PLUGIN_SOURCE, placement="composerActions", presentation="headless")
        self.write_installed_plugin("headless-service", self.QUIET_PLUGIN_SOURCE, placement="composerActions", presentation="headless",
                                    manifest={"events": ["task.statusChanged", "agent.finished"], "mcpTools": ["mcp__claude_ai_Slack__slack_read_channel"]})
        listed = {plugin["id"]: plugin for plugin in self.assert_success(self.call_cli("plugin", "refresh")[0])["plugins"]}
        bad = listed["bad-events"]
        self.assertFalse(bad["valid"])
        self.assertTrue(any('Unknown event "nope"' in error for error in bad["errors"]), bad["errors"])
        self.assertTrue(any("app.focus is listed twice" in error for error in bad["errors"]), bad["errors"])
        self.assertTrue(any('"slack_read" in "mcpTools"' in error for error in bad["errors"]), bad["errors"])
        self.assertFalse(listed["bare-headless"]["valid"])
        self.assertTrue(any('an event in "events"' in error for error in listed["bare-headless"]["errors"]), listed["bare-headless"]["errors"])
        service = listed["headless-service"]
        self.assertTrue(service["valid"], service["errors"])
        self.assertEqual((service["events"], service["mcpTools"]), (["task.statusChanged", "agent.finished"], ["mcp__claude_ai_Slack__slack_read_channel"]))

        # Headless runs of a file: real bridge calls, refused ui calls, faked provider calls.
        path = self.write_service_file(self.HEADLESS_HANDLERS_SOURCE)
        finished = json.dumps({"runID": "run-1", "status": "done", "result": {"title": "Reply to Dana"}, "error": None, "context": {"kind": "slack-task", "userId": "U7"}})
        report = self.assert_success(self.call_cli("plugin", "service", "--file", path, "--event", "app.focus", "--event", f"agent.finished:{finished}")[0])
        self.assertEqual(report["errors"], [])
        self.assertEqual([(event["name"], event["handlers"]) for event in report["events"]], [("app.focus", 1), ("agent.finished", 1)])
        calls = {(call["kind"], call["name"]): call for call in report["hostCalls"]}
        self.assertTrue(calls[("bridge", "task.list")]["ok"], "A bridge call reaches the real bridge.")
        self.assertEqual(calls[("ui", "close")]["error"]["code"], "unavailable", "A background half has no window.")
        self.assertEqual(calls[("bridge", "mcp.call")]["error"]["code"], "unavailable", "mcp.call is faked headlessly.")
        self.assertEqual(calls[("bridge", "mcp.call")]["arguments"]["tool"], "mcp__claude_ai_Slack__slack_read_user_profile")
        self.assertEqual(calls[("bridge", "agent.run")]["error"]["code"], "unavailable")
        self.assertEqual(report["state"]["tasks"], 0)
        self.assertEqual((report["state"]["ui"], report["state"]["mcp"], report["state"]["run"]), ("unavailable", "unavailable", "unavailable"))
        self.assertEqual(report["state"]["internal"], "invalid_argument", "Only the daemon delivers events to background halves.")
        self.assertEqual(report["state"]["finished"], {"status": "done", "kind": "slack-task", "title": "Reply to Dana", "runID": "run-1", "same": True},
                         "An injected agent.finished reaches the handler with its fields beside payload.")
        self.assertIn({"key": "mcp", "value": "unavailable"}, report["stateWritten"])
        mocked = self.assert_success(self.call_cli(
            "plugin", "service", "--file", path, "--event", "app.focus",
            "--mock", 'mcp.call:mcp__claude_ai_Slack__slack_read_user_profile={"content":[{"type":"text","text":"Nir"}]}',
            "--mock", 'agent.run={"runID":"run-mocked"}',
        )[0])
        self.assertEqual((mocked["state"]["mcp"], mocked["state"]["run"]), ("Nir", "run-mocked"), "A mock answers by tool or by command.")
        broken, _ = self.call_cli("plugin", "service", "--file", path, "--event", 'task.statusChanged:{"taskID":"t","from":"Backlog","to":"Review"}', expected_status=1)
        self.assertTrue(any("The move handler broke." in error for error in self.assert_success(broken)["errors"]), broken)
        self.assert_failure(self.call_cli("plugin", "service", "--file", path, "--event", "app.nope", expected_status=2)[0], "invalid_argument")

        # A mounted UI: service.on does nothing, provider calls need a mock.
        rendered = self.assert_success(self.render_plugin(self.POPOVER_CALLS_SOURCE, "--event", "call-mcp:onPress", "--event", "@app.focus"))
        self.assertEqual(self.plugin_text(self.plugin_node(rendered["tree"], "call-result")), "mcp unavailable")
        rendered = self.assert_success(self.render_plugin(self.POPOVER_CALLS_SOURCE, "--event", "call-agent:onPress",
                                                          "--mock", 'agent.run={"runID":"run-ui"}'))
        self.assertEqual(self.plugin_text(self.plugin_node(rendered["tree"], "call-result")), "run run-ui")

        # The daemon wakes only the plugins an event is for.
        environment = {"PLAYHOUSE_E2E_PLUGIN_SERVICE_COOLDOWN_SECONDS": "5"}
        self.write_installed_plugin("focus-service", self.SERVICE_PLUGIN_SOURCE, placement="mainSidebar", presentation="popover",
                                    manifest={"events": ["app.focus", "plugin.stateChanged"]})
        self.write_installed_plugin("other-service", self.QUIET_PLUGIN_SOURCE, placement="mainSidebar", presentation="popover",
                                    manifest={"events": ["plugin.stateChanged", "task.statusChanged"]})
        self.write_installed_plugin("focus-control", self.SERVICE_PLUGIN_SOURCE, placement="mainSidebar", presentation="popover",
                                    manifest={"events": ["app.focus"]})
        services = self.assert_success(self.call_cli("plugin", "services")[0])["services"]
        self.assertEqual({entry["pluginID"]: entry["events"] for entry in services}, {
            "focus-service": ["app.focus", "plugin.stateChanged"], "other-service": ["plugin.stateChanged", "task.statusChanged"],
            "focus-control": ["app.focus"],
            "headless-service": ["task.statusChanged", "agent.finished"],
        }, "Only valid, enabled plugins with events have a background half.")
        self.assert_success(self.call_cli("plugin", "event", "app.focus", extra_environment=environment)[0])
        self.wait_for(lambda: self.plugin_state("focus-service").get("focused") == 1, "The focus service saves its state.")
        self.assertNotIn("focused", self.plugin_state("other-service"), "A plugin whose manifest doesn't list app.focus isn't woken by it.")
        self.assertNotIn("focused", self.plugin_state("headless-service"))
        # Quick repeats collapse into one trailing run once the cooldown is over.
        self.assert_success(self.call_cli("plugin", "event", "app.focus", extra_environment=environment)[0])
        self.assert_success(self.call_cli("plugin", "event", "app.focus", extra_environment=environment)[0])
        self.wait_for(lambda: self.plugin_state("focus-service").get("focused") == 2, "The repeats run once after the cooldown.", timeout=15)
        time.sleep(1.5)
        self.assertEqual(self.plugin_state("focus-service")["focused"], 2, "Two focus events in one cooldown run once.")
        # A state change is targeted at its plugin.
        self.assert_success(self.call_cli("plugin", "state", "--id", "focus-service", "--key", "note", "--value", '"hello"')[0])
        self.wait_for(lambda: self.plugin_state("focus-service").get("heard") == ["focus-service:note"], "Its own service hears its state change.")
        time.sleep(1)
        self.assertEqual(self.plugin_state("focus-service")["heard"], ["focus-service:note"], "A service never hears its own writes, so it doesn't loop.")
        self.assertNotIn("heard", self.plugin_state("other-service"), "Another plugin's state change doesn't wake this service.")
        # Two services that keep waking each other stop once their chain of events is long enough.
        for pinger in ("ping-service", "pong-service"):
            self.write_installed_plugin(pinger, self.PING_PONG_SOURCE, placement="composerActions", presentation="headless",
                                        manifest={"events": ["plugin.stateChanged"]})
        self.assert_success(self.call_cli("plugin", "state", "--id", "ping-service", "--key", "ball", "--value", "0")[0])
        hits = lambda: (self.plugin_state("ping-service").get("hits"), self.plugin_state("pong-service").get("hits"))
        self.wait_for(lambda: hits() == (4, 4), "Each service runs four times in the chain.", timeout=30)
        time.sleep(2)
        self.assertEqual(hits(), (4, 4), "The chain ends rather than looping for as long as the daemon lives.")
        rendered = self.assert_success(self.call_cli("plugin", "render", "--plugin", "focus-service")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(rendered["tree"], "service-focused")), "focused 2", "The popover shows what its service saved.")
        self.assertEqual(self.plugin_text(self.plugin_node(rendered["tree"], "service-active")), "service false")
        # A move reaches the plugins that list it, as each one's own event.
        self.assert_success(self.call_cli("plugin", "event", "task.statusChanged", "--payload", json.dumps({"taskID": "t-1", "from": "Backlog", "to": "Review"}))[0])
        self.wait_for(lambda: self.plugin_state("other-service").get("moved") == "Review", "A listed event reaches the service.")
        self.wait_for(lambda: self.plugin_state("headless-service").get("moved") == "Review", "A headless plugin's service hears its events too.")
        # Disabled, a plugin's service isn't woken.
        self.assert_success(self.call_cli("plugin", "disable", "--id", "focus-service")[0])
        self.assertNotIn("focus-service", [entry["pluginID"] for entry in self.assert_success(self.call_cli("plugin", "services")[0])["services"]])
        control = self.plugin_state("focus-control").get("focused", 0)
        time.sleep(5.5)
        self.assert_success(self.call_cli("plugin", "event", "app.focus", extra_environment=environment)[0])
        self.wait_for(lambda: self.plugin_state("focus-control").get("focused", 0) > control, "The same focus reaches an enabled plugin.", timeout=15)
        time.sleep(1)
        self.assertEqual(self.plugin_state("focus-service")["focused"], 2, "A disabled plugin's service isn't woken.")

    # case-contract: test_plugin_mcp_call_warm_session_and_allowlist | mcp.call (CLI mcp call, Playhouse.mcp.call) calls a fully qualified MCP tool through Claude Code's mcp_call control request with result_not_for_model and no model turn, answering the tool's {content, structuredContent, isError}; a burst of calls reuses one warm Claude Code session, which shuts down once idle, so the next call starts another. A tool Claude Code can't reach fails as tool_failed with its message, a tool slower than the call's timeout as timeout, a name that isn't mcp__<server>__<tool> is invalid_argument, a Claude Code that doesn't advertise mcp_call_result_not_for_model_v1 or no Claude Code at all is unavailable, and a plugin whose manifest lists mcpTools is refused any other tool as permission_denied, both from the CLI and from its own Playhouse.mcp.call, which sends its plugin id. An installed plugin's background half calls mcp.call on app.focus in the daemon and saves the result in its state, which its popover shows. A task move doesn't wait for a script handler stuck on a slow tool, which still finishes; a handler past the service timeout is given up on with its runtime and reported in diagnostics.
    def test_plugin_mcp_call_warm_session_and_allowlist(self):
        environment = self.install_claude_fixture("claude-fixture-mcp")
        executable = Path(environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"])
        profile, search = "mcp__claude_ai_Slack__slack_read_user_profile", "mcp__claude_ai_Slack__slack_search_public_and_private"
        Path(f"{executable}.mcp-results").write_text(json.dumps({
            profile: {"content": [{"type": "text", "text": "Nir Yosef"}]},
            search: {"content": [{"type": "text", "text": "Dana"}, {"type": "text", "text": "Omri"}], "structuredContent": {"count": 2}, "isError": False},
        }), encoding="utf-8")
        sessions = lambda: Path(f"{executable}.sessions").read_text(encoding="utf-8").count("initialize") if Path(f"{executable}.sessions").exists() else 0
        first = self.assert_success(self.call_cli("mcp", "call", "--tool", profile, "--arguments", '{"user":"U1"}', extra_environment=environment)[0])
        self.assertEqual(first, {"content": [{"type": "text", "text": "Nir Yosef"}]})
        second = self.assert_success(self.call_cli("mcp", "call", "--tool", search, extra_environment=environment)[0])
        self.assertEqual((second["structuredContent"], second["isError"]), ({"count": 2}, False))
        calls = self.jsonl(f"{executable}.mcp-calls")
        self.assertEqual([(call["tool"], call["arguments"], call["resultNotForModel"]) for call in calls],
                         [(profile, {"user": "U1"}, True), (search, {}, True)], "Each call is an mcp_call request for the model-free result.")
        self.assertEqual(len({call["pid"] for call in calls}), 1, "A burst of calls reuses one warm Claude Code session.")
        self.assertEqual(sessions(), 1, "Claude Code started once for the burst.")
        history = Path(f"{executable}.history")
        self.assertFalse(history.exists() and json.loads(history.read_text(encoding="utf-8")).get("turns"), "No model turn ran.")

        failed = self.call_cli("mcp", "call", "--tool", "mcp__linear__list_issues", extra_environment=environment, expected_status=1)[0]
        self.assert_failure(failed, "tool_failed")
        self.assertIn("MCP server not connected: linear", failed["error"]["message"])
        self.assert_failure(self.call_cli("mcp", "call", "--tool", "slack_read", extra_environment=environment, expected_status=2)[0], "invalid_argument")

        # A plugin's mcpTools catch a tool it didn't mean to call.
        self.write_installed_plugin("slack-reader", self.MCP_SERVICE_SOURCE, placement="mainSidebar", presentation="popover",
                                    manifest={"events": ["app.focus"], "mcpTools": [search]})
        denied = self.call_cli("mcp", "call", "--tool", profile, "--plugin", "slack-reader", extra_environment=environment, expected_status=1)[0]
        self.assert_failure(denied, "permission_denied")
        self.assertIn("mcpTools", denied["error"]["message"])
        self.assert_success(self.call_cli("mcp", "call", "--tool", search, "--plugin", "slack-reader", extra_environment=environment)[0])
        self.write_installed_plugin("slow-service", self.SLOW_SERVICE_SOURCE, placement="composerActions", presentation="headless",
                                    manifest={"events": ["task.statusChanged"]})

        # The background half refreshes on focus through the same warm session.
        self.assert_success(self.call_cli("plugin", "event", "app.focus", extra_environment=environment)[0])
        self.wait_for(lambda: self.plugin_state("slack-reader").get("people") == ["Dana", "Omri"], "The service saves the tool's result.")
        rendered = self.assert_success(self.call_cli("plugin", "render", "--plugin", "slack-reader")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(rendered["tree"], "mcp-people")), "Dana, Omri")
        self.assertEqual(sessions(), 1, "The service's call reused the warm session.")
        self.wait_for(lambda: self.plugin_state("slack-reader").get("denied") == "permission_denied",
                      "Playhouse.mcp.call sends the plugin's id, so its mcpTools refuse an unlisted tool.")

        # Idle, the session shuts down; the next call starts Claude Code again.
        idle = {**environment, "PLAYHOUSE_E2E_MCP_SESSION_IDLE_SECONDS": "1"}
        self.assert_success(self.call_cli("mcp", "call", "--tool", profile, extra_environment=idle)[0])
        pid = self.jsonl(f"{executable}.mcp-calls")[-1]["pid"]
        self.wait_for(lambda: not self.process_is_running(pid), "The idle session's Claude Code exits.", timeout=15)
        self.assert_success(self.call_cli("mcp", "call", "--tool", profile, extra_environment=environment)[0])
        self.assertEqual(sessions(), 2, "After the idle shutdown, a call starts a new session.")

        # A slow tool: mcp.call's timeout, a move that doesn't wait for script handlers, and the handlers' own timeout.
        channel = "mcp__claude_ai_Slack__slack_read_channel"
        Path(f"{executable}.mcp-results").write_text(json.dumps({
            profile: {"content": [{"type": "text", "text": "Nir Yosef"}]}, channel: {"content": [{"type": "text", "text": "hi"}]},
        }), encoding="utf-8")
        Path(f"{executable}.mcp-call-delay").write_text(json.dumps({channel: 4}), encoding="utf-8")
        timed_out = self.call_cli("mcp", "call", "--tool", channel, "--timeout", "1", extra_environment=environment, expected_status=1)[0]
        self.assert_failure(timed_out, "timeout")
        task_id = self.create_task(title="Slow plugin move")["id"]
        started = time.monotonic()
        self.assert_success(self.call_cli("plugin", "event", "task.statusChanged", "--payload",
                                          json.dumps({"taskID": task_id, "from": "In Progress", "to": "Review"}), extra_environment=environment)[0])
        self.assertLess(time.monotonic() - started, 3, "A move waits for the built-ins' reactions, not for script handlers.")
        self.wait_for(lambda: self.plugin_state("slow-service").get("after") == "Review", "The slow handler still finishes.", timeout=30)
        short = {**environment, "PLAYHOUSE_E2E_PLUGIN_SERVICE_TIMEOUT_SECONDS": "1"}
        self.assert_success(self.call_cli("plugin", "event", "task.statusChanged", "--payload",
                                          json.dumps({"taskID": task_id, "from": "Review", "to": "Done"}), extra_environment=short)[0])
        self.wait_for(lambda: self.plugin_state("slow-service").get("before") == "Done", "The handler starts.")
        self.wait_for(lambda: any(event.get("event") == "plugin.service.failed" and "didn't finish within 1 seconds" in event.get("errors", "")
                                  for event in self.diagnostic_events()), "The timed-out handlers are reported in diagnostics.", timeout=15)
        time.sleep(5)
        self.assertEqual(self.plugin_state("slow-service")["after"], "Review", "A handler past its timeout is given up on, with its runtime.")

        # Claude Code that can't call tools directly, or none at all.
        unsupported = self.install_claude_fixture("claude-fixture-no-mcp-call")
        refused = self.call_cli("mcp", "call", "--tool", profile, extra_environment=unsupported, expected_status=1)[0]
        self.assert_failure(refused, "unavailable")
        self.assertIn("can't call MCP tools directly", refused["error"]["message"])
        self.assert_failure(self.call_cli("mcp", "call", "--tool", profile, expected_status=1)[0], "unavailable")

    # case-contract: test_plugin_agent_run_finishes_and_recovers | agent.run (CLI agent run, Playhouse.agent.run from the popover, which fills pluginID from props and passes its model, allowed tools, JSON schema and context) starts a non-persisted Claude Code run in the daemon with the given prompt, model, allowed tools and JSON schema and returns its runID at once; agent runs lists it as running, and nothing is heard while it runs. When it ends, only that plugin's background half hears agent.finished with {runID, status, result, error, context}, never another plugin that listens for agent.finished: done with the schema's structured output as result, which the plugin's handler uses to create a board task, failed with Claude Code's error or after the run timeout, or cancelled after agent cancel (an unknown run is not_found); the run then leaves agent runs. A run cut off by its daemon dying, which it outlives, is reported failed with the error "interrupted" by the next daemon, with its context intact, and its orphaned Claude Code process is stopped; deleting a plugin stops its runs with no event. agent.run is refused for a plugin that doesn't list agent.finished or a missing prompt (invalid_argument), an unknown plugin (not_found) and a disabled plugin (unavailable).
    def test_plugin_agent_run_finishes_and_recovers(self):
        executable = self.install_provider_fixture("claude", "claude-fixture-agent")
        environment = self.restart_service_environment("claude", executable)
        Path(f"{executable}.agent-output").write_text(json.dumps({"title": "Reply to Dana", "prompt": "Answer Dana's question.", "nothingNew": False}), encoding="utf-8")
        hold = Path(f"{executable}.agent-hold")
        self.addCleanup(lambda: hold.unlink(missing_ok=True))
        self.write_installed_plugin("slack-dms", self.AGENT_PLUGIN_SOURCE, placement="mainSidebar", presentation="popover",
                                    manifest={"events": ["agent.finished"]})
        self.write_installed_plugin("deaf-plugin", self.AGENT_PLUGIN_SOURCE, placement="mainSidebar", presentation="popover",
                                    manifest={"events": ["app.focus"]})
        self.write_installed_plugin("listener-plugin", self.LISTENER_SOURCE, placement="composerActions", presentation="headless",
                                    manifest={"events": ["agent.finished"]})
        schema = json.dumps({"type": "object", "properties": {"title": {"type": "string"}}, "required": ["title"]})
        def run(*extra, plugin="slack-dms", user="U7", expected_status=0, environment=environment):
            return self.call_cli("agent", "run", "--plugin", plugin, "--prompt", f"Draft a task for {user}.", "--model", "opus",
                                 "--allowed-tool", "mcp__claude_ai_Slack__slack_read_channel", "--allowed-tool", "mcp__claude_ai_Slack__slack_read_thread",
                                 "--json-schema", schema, "--context", json.dumps({"kind": "slack-task", "userId": user}), *extra,
                                 extra_environment=environment, expected_status=expected_status)[0]
        def finished():
            return self.plugin_state("slack-dms", environment).get("finished")

        self.assert_failure(run(plugin="deaf-plugin", expected_status=2), "invalid_argument")
        self.assert_failure(run(plugin="no-such-plugin", expected_status=3), "not_found")
        self.assert_failure(self.call_cli("agent", "run", "--plugin", "slack-dms", "--prompt", "  ", extra_environment=environment, expected_status=2)[0], "invalid_argument")
        self.assert_success(self.call_cli("plugin", "disable", "--id", "deaf-plugin", extra_environment=environment)[0])
        self.assert_failure(run(plugin="deaf-plugin", expected_status=1), "unavailable")
        # The popover's Playhouse.agent.run fills its plugin id and passes every option.
        pressed = self.assert_success(self.call_cli("plugin", "render", "--plugin", "slack-dms", "--event", "dm-create-U7:onPress",
                                                    "--mock", 'agent.run={"runID":"run-popover"}', extra_environment=environment)[0])
        call = next(call for call in pressed["hostCalls"] if call["name"] == "agent.run")
        self.assertEqual((call["arguments"]["pluginID"], call["arguments"]["model"], call["arguments"]["allowedTools"], call["arguments"]["context"]),
                         ("slack-dms", "opus", ["mcp__claude_ai_Slack__slack_read_channel", "mcp__claude_ai_Slack__slack_read_thread"], {"kind": "slack-task", "userId": "U7"}))
        self.assertEqual(call["arguments"]["jsonSchema"]["required"], ["title", "prompt", "nothingNew"])
        def board_titles():
            return [task["title"] for task in self.assert_success(self.call_cli("task", "list", extra_environment=environment)[0])["tasks"]]

        # A run returns at once and is listed until it ends.
        hold.touch()
        run_id = self.assert_success(run())["runID"]
        runs = self.assert_success(self.call_cli("agent", "runs", extra_environment=environment)[0])["runs"]
        self.assertEqual([(entry["runID"], entry["pluginID"], entry["running"], entry["context"]) for entry in runs],
                         [(run_id, "slack-dms", True, {"kind": "slack-task", "userId": "U7"})])
        self.wait_for(lambda: self.jsonl(f"{executable}.agent-runs"), "The agent started.")
        launched = self.jsonl(f"{executable}.agent-runs")[-1]
        self.assertEqual((launched["model"], launched["allowedTools"], launched["jsonSchema"], launched["persisted"]),
                         ("opus", "mcp__claude_ai_Slack__slack_read_channel,mcp__claude_ai_Slack__slack_read_thread", json.loads(schema), False))
        self.assertEqual(launched["prompt"], "Draft a task for U7.")
        self.assertIsNone(finished(), "Nothing is heard while the agent runs.")
        hold.unlink()
        self.wait_for(lambda: (finished() or {}).get("status") == "done", "The plugin's service hears agent.finished.", timeout=30)
        self.assertEqual(finished(), {"status": "done", "userId": "U7", "runID": run_id, "error": None, "title": "Reply to Dana"})
        self.assertIn("Reply to Dana", board_titles(), "The service created the task from the structured result.")
        self.assertEqual(self.assert_success(self.call_cli("agent", "runs", extra_environment=environment)[0])["runs"], [])

        # A failed run, and a cancelled one.
        Path(f"{executable}.agent-fail").touch()
        failed_id = self.assert_success(run(user="U8"))["runID"]
        self.wait_for(lambda: (finished() or {}).get("runID") == failed_id, "The failed run is reported.", timeout=30)
        self.assertEqual((finished()["status"], finished()["error"]), ("failed", "The fixture agent failed on purpose."))
        self.assertIn("Slack task failed for U8: The fixture agent failed on purpose.", board_titles())
        Path(f"{executable}.agent-fail").unlink()
        hold.touch()
        cancelled_id = self.assert_success(run(user="U9"))["runID"]
        self.assert_failure(self.call_cli("agent", "cancel", "--plugin", "slack-dms", "--run", "agent-run-nope", extra_environment=environment, expected_status=3)[0], "not_found")
        self.assert_success(self.call_cli("agent", "cancel", "--plugin", "slack-dms", "--run", cancelled_id, extra_environment=environment)[0])
        self.wait_for(lambda: (finished() or {}).get("runID") == cancelled_id, "The cancelled run is reported.", timeout=30)
        self.assertEqual(finished()["status"], "cancelled")
        # Past its timeout, a run is stopped and fails.
        timed_id = self.assert_success(run(user="U12", environment={**environment, "PLAYHOUSE_E2E_PLUGIN_AGENT_TIMEOUT_SECONDS": "1"}))["runID"]
        self.wait_for(lambda: (finished() or {}).get("runID") == timed_id, "The timed-out run is reported.", timeout=30)
        self.assertEqual((finished()["status"], finished()["error"]), ("failed", "The agent didn't finish within 1 seconds."))
        self.assertNotIn("finished", self.plugin_state("listener-plugin", environment), "Another plugin listening for agent.finished never hears slack-dms's runs.")

        # Cut off with its daemon, a run is reported interrupted by the next one.
        interrupted_id = self.assert_success(run(user="U10"))["runID"]
        orphan = self.wait_for(lambda: next((entry["pid"] for entry in self.jsonl(f"{executable}.agent-runs") if "U10" in entry["prompt"]), None),
                               "The U10 agent started.")
        self.kill_daemon(environment)
        self.assertTrue(self.process_is_running(orphan), "The agent outlived its daemon.")
        self.assertEqual(self.assert_success(self.call_cli("agent", "runs", extra_environment=environment)[0])["runs"], [])
        # The service reports it on the board (a test store's settings can't be read back across daemons).
        self.wait_for(lambda: "Slack task failed for U10: interrupted" in board_titles(), "The next daemon reports the cut-off run, with its context.", timeout=30)
        self.assertNotIn(interrupted_id, [entry["runID"] for entry in self.assert_success(self.call_cli("agent", "runs", extra_environment=environment)[0])["runs"]])
        self.wait_for(lambda: not self.process_is_running(orphan), "The orphaned agent is stopped.", timeout=10)

        # Deleting the plugin stops its runs, with no event.
        self.assert_success(run(user="U11"))
        last = self.wait_for(lambda: next((entry["pid"] for entry in self.jsonl(f"{executable}.agent-runs") if "U11" in entry["prompt"]), None),
                             "The U11 agent started.")
        self.assert_success(self.call_cli("plugin", "delete", "--id", "slack-dms", extra_environment=environment)[0])
        self.assertEqual(self.assert_success(self.call_cli("agent", "runs", extra_environment=environment)[0])["runs"], [])
        self.wait_for(lambda: not self.process_is_running(last), "The deleted plugin's agent is stopped.", timeout=10)
        time.sleep(1)
        self.assertNotIn("Slack task cancelled for U11: The run was cancelled.", board_titles(), "A deleted plugin hears nothing of its stopped run.")

    # case-contract: test_plugin_mcp_call_codex | mcp.call with provider codex (CLI mcp call --provider codex, Playhouse.mcp.call with {provider: "codex"}) calls the tool through the shared Codex app-server's mcpServer/tool/call on one ephemeral, read-only thread that a burst of calls reuses and that is released (thread/unsubscribe) once idle, with no turn, answering the tool's {content, structuredContent, isError}. A tool Codex can't reach fails as tool_failed with its message, one slower than the call's timeout as timeout, a Codex without mcpServer/tool/call or no Codex at all is unavailable, and a plugin's mcpTools refuse any other tool as permission_denied. A plugin's background half calls it on app.focus and saves the result in its state, which its popover shows.
    def test_plugin_mcp_call_codex(self):
        environment = self.install_codex_fixture("codex-fixture-mcp")
        executable = Path(environment["PLAYHOUSE_E2E_CODEX_EXECUTABLE"])
        profile, search = "mcp__claude_ai_Slack__slack_read_user_profile", "mcp__claude_ai_Slack__slack_search_public_and_private"
        Path(f"{executable}.mcp-results").write_text(json.dumps({
            profile: {"content": [{"type": "text", "text": "Nir Yosef"}]},
            search: {"content": [{"type": "text", "text": "Dana"}, {"type": "text", "text": "Omri"}], "structuredContent": {"count": 2}, "isError": False},
        }), encoding="utf-8")
        first = self.assert_success(self.call_cli("mcp", "call", "--provider", "codex", "--tool", profile, "--arguments", '{"user":"U1"}', extra_environment=environment)[0])
        self.assertEqual(first, {"content": [{"type": "text", "text": "Nir Yosef"}]})
        second = self.assert_success(self.call_cli("mcp", "call", "--provider", "codex", "--tool", search, extra_environment=environment)[0])
        self.assertEqual((second["structuredContent"], second["isError"]), ({"count": 2}, False))
        calls = self.jsonl(f"{executable}.mcp-calls")
        self.assertEqual([(call["server"], call["tool"], call["arguments"]) for call in calls],
                         [("claude_ai_Slack", "slack_read_user_profile", {"user": "U1"}), ("claude_ai_Slack", "slack_search_public_and_private", {})],
                         "Each call is an mcpServer/tool/call with the tool's server and own name.")
        threads = self.jsonl(f"{executable}.ephemeral-threads")
        self.assertEqual(len(threads), 1, "A burst of calls reuses one ephemeral thread.")
        self.assertEqual({call["threadId"] for call in calls}, {threads[0]["threadId"]})
        self.assertEqual(threads[0]["sandbox"], "read-only")
        self.assertFalse(Path(f"{executable}.turn-starts").exists(), "No turn ran.")

        failed = self.call_cli("mcp", "call", "--provider", "codex", "--tool", "mcp__linear__list_issues", extra_environment=environment, expected_status=1)[0]
        self.assert_failure(failed, "tool_failed")
        self.assertIn("MCP server not connected: linear", failed["error"]["message"])
        self.write_installed_plugin("codex-reader", self.CODEX_MCP_SERVICE_SOURCE, placement="mainSidebar", presentation="popover",
                                    manifest={"events": ["app.focus"], "mcpTools": [search]})
        self.assert_failure(self.call_cli("mcp", "call", "--provider", "codex", "--tool", profile, "--plugin", "codex-reader",
                                          extra_environment=environment, expected_status=1)[0], "permission_denied")

        # The background half reads through Codex on focus; its popover shows it.
        self.assert_success(self.call_cli("plugin", "event", "app.focus", extra_environment=environment)[0])
        self.wait_for(lambda: self.plugin_state("codex-reader").get("people") == ["Dana", "Omri"], "The service saves the Codex tool's result.", timeout=30)
        rendered = self.assert_success(self.call_cli("plugin", "render", "--plugin", "codex-reader")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(rendered["tree"], "mcp-people")), "Dana, Omri")
        self.assertEqual(len(self.jsonl(f"{executable}.ephemeral-threads")), 1, "The service's call reused the warm thread.")
        warm = self.jsonl(f"{executable}.ephemeral-threads")[0]["threadId"]
        self.assert_success(self.call_cli("mcp", "call", "--provider", "codex", "--tool", profile,
                                          extra_environment={**environment, "PLAYHOUSE_E2E_MCP_SESSION_IDLE_SECONDS": "1"})[0])
        self.wait_for(lambda: warm in [entry["threadId"] for entry in self.jsonl(f"{executable}.unsubscribed")], "The idle thread is released.", timeout=15)
        self.assert_success(self.call_cli("mcp", "call", "--provider", "codex", "--tool", profile, extra_environment=environment)[0])
        self.assertEqual(len(self.jsonl(f"{executable}.ephemeral-threads")), 2, "After the release, a call starts a new thread.")

        channel = "mcp__claude_ai_Slack__slack_read_channel"
        Path(f"{executable}.mcp-results").write_text(json.dumps({channel: {"content": [{"type": "text", "text": "hi"}]}}), encoding="utf-8")
        Path(f"{executable}.mcp-call-delay").write_text(json.dumps({channel: 4}), encoding="utf-8")
        self.assert_failure(self.call_cli("mcp", "call", "--provider", "codex", "--tool", channel, "--timeout", "1",
                                          extra_environment=environment, expected_status=1)[0], "timeout")

        unsupported = self.install_codex_fixture("codex-fixture-no-mcp-call")
        refused = self.call_cli("mcp", "call", "--provider", "codex", "--tool", profile, extra_environment=unsupported, expected_status=1)[0]
        self.assert_failure(refused, "unavailable")
        self.assertIn("can't call MCP tools directly", refused["error"]["message"])
        self.assert_failure(self.call_cli("mcp", "call", "--provider", "codex", "--tool", profile, expected_status=1)[0], "unavailable")
        self.assert_failure(self.call_cli("mcp", "call", "--provider", "gemini", "--tool", profile, expected_status=2)[0], "invalid_argument")

    # case-contract: test_plugin_agent_run_codex | agent.run with provider codex (CLI agent run --provider codex, Playhouse.agent.run from the popover with the plugin's provider) starts one turn on an ephemeral, read-only Codex thread of the shared app-server with no approvals, the prompt, the model and the JSON schema as outputSchema, and returns its runID at once; agent runs lists it as a running Codex run, and its thread is released (thread/unsubscribe) when the turn ends. When it ends, only that plugin's background half hears agent.finished: done with the final message parsed as the schema's structured output, which the plugin's handler uses to create a board task, failed with Codex's error, when the message isn't JSON for the schema, or after the run timeout, or cancelled after agent cancel, which interrupts the turn. A run cut off by its daemon dying is reported failed with the error "interrupted" by the next daemon, which also interrupts the orphaned turn on the app-server that outlived it. With no Codex installed, agent.run with provider codex is unavailable.
    def test_plugin_agent_run_codex(self):
        executable = self.install_provider_fixture("codex", "codex-fixture-agent")
        environment = self.restart_service_environment("codex", executable)
        output = Path(f"{executable}.agent-output")
        output.write_text(json.dumps({"title": "Reply to Omri", "prompt": "Answer Omri's question.", "nothingNew": False}), encoding="utf-8")
        hold = Path(f"{executable}.agent-hold")
        self.addCleanup(lambda: hold.unlink(missing_ok=True))
        self.write_installed_plugin("slack-dms", self.AGENT_PLUGIN_SOURCE, placement="mainSidebar", presentation="popover",
                                    manifest={"events": ["agent.finished"]})
        self.write_installed_plugin("listener-plugin", self.LISTENER_SOURCE, placement="composerActions", presentation="headless",
                                    manifest={"events": ["agent.finished"]})
        schema = {"type": "object", "properties": {"title": {"type": "string"}}, "required": ["title"]}
        def run(user, extra=None):
            return self.call_cli("agent", "run", "--plugin", "slack-dms", "--provider", "codex", "--prompt", f"Draft a task for {user}.",
                                 "--model", "gpt-5.5", "--json-schema", json.dumps(schema), "--context", json.dumps({"kind": "slack-task", "userId": user}),
                                 extra_environment={**environment, **(extra or {})})[0]
        def finished():
            return self.plugin_state("slack-dms", environment).get("finished")
        def board_titles():
            return [task["title"] for task in self.assert_success(self.call_cli("task", "list", extra_environment=environment)[0])["tasks"]]
        def interrupts():
            path = Path(f"{executable}.methods")
            return path.read_text(encoding="utf-8").splitlines().count("turn/interrupt") if path.exists() else 0

        # The popover's run passes the plugin's provider.
        self.assert_success(self.call_cli("plugin", "state", "--id", "slack-dms", "--key", "provider", "--value", '"codex"', extra_environment=environment)[0])
        pressed = self.assert_success(self.call_cli("plugin", "render", "--plugin", "slack-dms", "--event", "dm-create-U7:onPress",
                                                    "--mock", 'agent.run={"runID":"run-popover"}', extra_environment=environment)[0])
        call = next(call for call in pressed["hostCalls"] if call["name"] == "agent.run")
        self.assertEqual((call["arguments"]["provider"], call["arguments"]["model"], call["arguments"]["pluginID"]), ("codex", "gpt-5.5", "slack-dms"))
        self.assert_success(self.call_cli("plugin", "state", "--id", "slack-dms", "--key", "jobs", "--value", "null", extra_environment=environment)[0])

        hold.touch()
        run_id = self.assert_success(run("U7"))["runID"]
        runs = self.assert_success(self.call_cli("agent", "runs", extra_environment=environment)[0])["runs"]
        self.assertEqual([(entry["runID"], entry["provider"], entry["running"]) for entry in runs], [(run_id, "codex", True)])
        launched = self.wait_for(lambda: next(iter(self.jsonl(f"{executable}.agent-runs")), None), "The Codex turn started.")
        self.assertEqual((launched["model"], launched["outputSchema"], launched["sandbox"], launched["approvalPolicy"]),
                         ("gpt-5.5", schema, "readOnly", "never"))
        self.assertEqual(launched["prompt"], "Draft a task for U7.")
        self.assertTrue(launched["threadId"].startswith("ephemeral-"), "The run has an ephemeral thread of its own.")
        self.assertIsNone(finished(), "Nothing is heard while the agent runs.")
        hold.unlink()
        self.wait_for(lambda: (finished() or {}).get("status") == "done", "The plugin's service hears agent.finished.", timeout=30)
        self.assertEqual(finished(), {"status": "done", "userId": "U7", "runID": run_id, "error": None, "title": "Reply to Omri"})
        self.assertIn("Reply to Omri", board_titles(), "The structured output became the task.")
        self.wait_for(lambda: launched["threadId"] in [entry["threadId"] for entry in self.jsonl(f"{executable}.unsubscribed")],
                      "The finished run's thread is released.")

        Path(f"{executable}.agent-fail").touch()
        failed_id = self.assert_success(run("U8"))["runID"]
        self.wait_for(lambda: (finished() or {}).get("runID") == failed_id, "The failed run is reported.", timeout=30)
        self.assertEqual((finished()["status"], finished()["error"]), ("failed", "The fixture agent failed on purpose."))
        Path(f"{executable}.agent-fail").unlink()
        output.write_text("not json", encoding="utf-8")
        unparsed_id = self.assert_success(run("U9"))["runID"]
        self.wait_for(lambda: (finished() or {}).get("runID") == unparsed_id, "The unparsable answer is reported.", timeout=30)
        self.assertEqual((finished()["status"], finished()["error"]), ("failed", "Codex returned no structured output for the JSON schema."))
        output.write_text(json.dumps({"title": "Reply to Omri", "prompt": "Answer Omri's question.", "nothingNew": False}), encoding="utf-8")

        hold.touch()
        before = interrupts()
        cancelled_id = self.assert_success(run("U10"))["runID"]
        self.assert_success(self.call_cli("agent", "cancel", "--plugin", "slack-dms", "--run", cancelled_id, extra_environment=environment)[0])
        self.wait_for(lambda: (finished() or {}).get("runID") == cancelled_id, "The cancelled run is reported.", timeout=30)
        self.assertEqual(finished()["status"], "cancelled")
        self.assertGreater(interrupts(), before, "Cancelling interrupts the Codex turn.")
        timed_id = self.assert_success(run("U11", {"PLAYHOUSE_E2E_PLUGIN_AGENT_TIMEOUT_SECONDS": "1"}))["runID"]
        self.wait_for(lambda: (finished() or {}).get("runID") == timed_id, "The timed-out run is reported.", timeout=30)
        self.assertEqual((finished()["status"], finished()["error"]), ("failed", "The agent didn't finish within 1 seconds."))
        self.assertNotIn("finished", self.plugin_state("listener-plugin", environment), "Another plugin never hears slack-dms's runs.")

        # Cut off with its daemon; the app-server outlives it, and the next daemon interrupts the orphaned turn.
        before = interrupts()
        interrupted_id = self.assert_success(run("U12"))["runID"]
        self.wait_for(lambda: any("U12" in entry["prompt"] for entry in self.jsonl(f"{executable}.agent-runs")), "The U12 turn started.")
        self.kill_daemon(environment)
        self.assertNotIn(interrupted_id, [entry["runID"] for entry in self.assert_success(self.call_cli("agent", "runs", extra_environment=environment)[0])["runs"]])
        # The service reports it on the board (a test store's settings can't be read back across daemons).
        self.wait_for(lambda: "Slack task failed for U12: interrupted" in board_titles(), "The next daemon reports the cut-off run.", timeout=30)
        self.wait_for(lambda: interrupts() > before, "The next daemon interrupts the orphaned Codex turn.", timeout=15)
        self.assert_failure(self.call_cli("agent", "run", "--plugin", "slack-dms", "--provider", "codex", "--prompt", "Go.",
                                          extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": "none"}, expected_status=1)[0], "unavailable")

    # case-contract: test_markdown_atom_renders_formatted_markdown | The Plugin Catalog lists the Markdown atom, whose page renders Markdown atoms into formatted native text with no plugin error: its skill sample shows its frontmatter as a table of its entries (release-notes) with no raw --- fences, a heading without its # marks that is taller than the body text, a paragraph whose bold, italic and inline code show without their markers, bullet and numbered list items, a quote, a Swift code block card, a table with its cells and the text after a rule; a Markdown whose frontmatter is hide shows only its body, and a Markdown given raw string children renders them as Markdown (a heading without its ## marks). `plugin render` reports a Markdown atom from its text prop or from its string children with no errors and its props as given, while a frontmatter other than table or hide, a mistyped size or selectable, an atom child, or an event the atom doesn't raise is reported in errors with exit 1.
    def test_markdown_atom_renders_formatted_markdown(self):
        page = self.assert_success(self.call_cli("plugin", "render", "--page", "Markdown")[0])
        self.assertEqual(page["errors"], [], "The Markdown catalog page renders without errors.")
        skill = self.plugin_node(page["tree"], "markdown-skill")
        self.assertEqual(skill["type"], "Markdown")
        self.assertEqual((skill["props"]["frontmatter"], skill["props"]["selectable"]), ("table", True))
        self.assertTrue(skill["props"]["text"].startswith("---\nname: release-notes\n"), skill["props"]["text"])
        hidden = self.plugin_node(page["tree"], "markdown-hidden-frontmatter")
        self.assertEqual((hidden["props"]["frontmatter"], hidden["props"]["size"], hidden["props"]["color"]), ("hide", 11, "secondary"))
        children = self.plugin_node(page["tree"], "markdown-children")
        self.assertEqual(children["type"], "Markdown")
        self.assertEqual(self.plugin_text(children), "## From string children\nA Markdown atom also reads its raw strings.",
                         "A Markdown's raw string children are its source.")

        rendered = self.assert_success(self.render_plugin('Playhouse.render(h(Markdown, { text: "# Title\\n**bold** and `code`", size: 14, testID: "doc" }));'))
        self.assertEqual(rendered["errors"], [], "A plugin renders a Markdown atom from its text prop.")
        doc = self.plugin_node(rendered["tree"], "doc")
        self.assertEqual((doc["type"], doc["props"]["text"], doc["props"]["size"]), ("Markdown", "# Title\n**bold** and `code`", 14))
        from_strings = self.assert_success(self.render_plugin('Playhouse.render(h(Markdown, { testID: "doc" }, "- one\\n", "- two"));'))
        self.assertEqual(from_strings["errors"], [], "A plugin renders a Markdown atom from string children.")
        self.assertEqual(self.plugin_text(self.plugin_node(from_strings["tree"], "doc")), "- one\n- two")

        for source, message in [
            ('Playhouse.render(h(Markdown, { frontmatter: "show" }, "x"));', '<Markdown> has an invalid prop: frontmatter: expected "table" or "hide", found "show"'),
            ('Playhouse.render(h(Markdown, { size: "large" }, "x"));', "<Markdown> has an invalid prop: size: expected a number, found a string"),
            ('Playhouse.render(h(Markdown, { selectable: "yes" }, "x"));', "<Markdown> has an invalid prop: selectable: expected a boolean, found a string"),
            ('Playhouse.render(h(Markdown, null, h(Text, null, "x")));', "<Markdown> can't hold <Text>"),
            ('Playhouse.render(h(Markdown, { onLink: function () {} }, "x"));', '<Markdown> has no event "onLink"'),
        ]:
            failed = self.render_plugin(source, expected_status=1)
            self.assertTrue(any(message in error for error in failed["result"]["errors"]), f"{source} reports {message}: {failed['result']['errors']}")
