from test_bridge_support import *
from test_bridge_support import __file__

class BridgeTestCases23:
    # case-contract: test_codex_stop_during_turn_launch_stops_before_agent_starts | A Stop that arrives while Codex is still starting the thread moves the task out of In Progress at once, before Codex answers. Nothing of the message is sent: the send ends with turn_stopped, no turn starts, the prompt returns to the draft with no failure reason, and the task returns to the status it had before the send. A steer sent for that message before the Stop is stopped with it: it ends with turn_stopped, is not queued and never runs as a turn of its own. A follow-up queued during that launch stays in the queue, marked as needing the user's action, and does not run. A Stop that arrives after turn/start was sent but before Codex acknowledged the turn also leaves In Progress at once, and Codex's turn/interrupt follows as soon as the turn has its ID, leaving the task in Waiting Response. In the window Stop is enabled as soon as the message is sent, and clicking it replaces Stop at once while the provider is still held; the stopped steer's bubble leaves the transcript and its text returns to the composer with the stopped message, without an error.
    def test_codex_stop_during_turn_launch_stops_before_agent_starts(self):
        task = self.create_task("Codex stop during launch", provider="codex")
        executable = self.install_provider_fixture("codex", "codex-fixture-launch-hold-interrupt")
        environment = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)}
        prior_status = self.assert_success(self.call_cli("task", "get", task["id"])[0])["status"]
        prompt = "Hold until stopped."

        # Stopped while the thread is starting: nothing was sent yet.
        self.launch_marker(executable, "thread-start-pause").write_text("hold\n", encoding="utf-8")
        send = self.start_background_cli("conversation", "send", task["id"], "--message", prompt, expected_status=1, environment=environment)
        self.wait_for(self.launch_marker(executable, "thread-start-ready").is_file, "Codex should be held while starting the thread.")
        steer_text = "Steer the message that is about to be stopped."
        steer = self.start_background_cli("conversation", "steer", task["id"], "--message", steer_text, expected_status=1, environment=environment)
        follow_up_text = "Run this follow-up after the stopped message."
        follow_up = self.assert_success(self.call_cli("conversation", "queue", task["id"], "--message", follow_up_text)[0])
        time.sleep(0.5)
        self.assertTrue(steer["thread"].is_alive(), "A steer sent during the launch waits for the turn.")
        stop = self.start_background_cli("conversation", "stop", task["id"], environment=environment)
        self.wait_for(
            lambda: self.assert_success(self.call_cli("task", "get", task["id"])[0])["status"] != "In Progress",
            "Stop should move the task out of In Progress while Codex is still starting.", timeout=5,
        )
        self.launch_marker(executable, "thread-start-pause").unlink()
        self.launch_marker(executable, "thread-start-release").write_text("release\n", encoding="utf-8")
        self.assertTrue(self.assert_success(self.finish_background_cli(stop))["interrupted"], "Stopping a launching turn counts as an interruption.")
        self.assertEqual(self.finish_background_cli(send)["error"]["code"], "turn_stopped")
        self.assertEqual(self.finish_background_cli(steer)["error"]["code"], "turn_stopped", "A steer for a stopped message is stopped with it.")
        kept = self.assert_success(self.call_cli("conversation", "queue-list", task["id"])[0])
        self.assertEqual(
            [(item["id"], item["text"], item["state"]) for item in kept], [(follow_up["id"], follow_up_text, "needsAction")],
            "The stopped steer must not be queued, and the queued follow-up waits for the user instead of running.",
        )
        self.assert_success(self.call_cli("conversation", "queue-remove", task["id"], follow_up["id"])[0])
        self.assertEqual(self.assert_success(self.call_cli("conversation", "queue-list", task["id"])[0]), [])
        returned = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(returned["status"], prior_status, "A message stopped before it was sent leaves the task where it was.")
        self.assertTrue(returned["hasUnsentDraft"], "The stopped message returns to the draft.")
        self.assertTrue(returned["savedPrompt"].startswith(prompt), "The draft should hold the stopped message again.")
        self.assertIsNone(returned.get("pendingSubmittedPrompt"))
        self.assertIsNone(returned.get("statusMessage"), "A user's stop leaves no failure reason.")
        self.assertFalse(self.launch_marker(executable, "interrupt-ready").exists(), "No Codex turn may start for a message stopped before it was sent.")

        # Stopped after turn/start was sent, before Codex acknowledged the turn.
        self.launch_marker(executable, "turn-start-pause").write_text("hold\n", encoding="utf-8")
        send = self.start_background_cli("conversation", "send", task["id"], "--message", prompt, expected_status=1, environment=environment)
        self.wait_for(self.launch_marker(executable, "turn-start-ready").is_file, "Codex should hold its turn/start answer.")
        stop = self.start_background_cli("conversation", "stop", task["id"], environment=environment)
        self.wait_for(
            lambda: self.assert_success(self.call_cli("task", "get", task["id"])[0])["status"] == "Waiting Response",
            "Stop should move the task to Waiting Response before Codex acknowledges the turn.", timeout=5,
        )
        self.assertFalse(self.launch_marker(executable, "interrupt-received").exists(), "Codex cannot be interrupted before the turn has an ID.")
        self.launch_marker(executable, "turn-start-release").write_text("release\n", encoding="utf-8")
        self.wait_for(self.launch_marker(executable, "interrupt-received").is_file, "The interrupt should follow as soon as the turn has its ID.")
        self.launch_marker(executable, "interrupt-release").write_text("acknowledge interrupt\n", encoding="utf-8")
        self.assertTrue(self.assert_success(self.finish_background_cli(stop))["interrupted"])
        self.finish_background_cli(send)
        stopped = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(stopped["status"], "Waiting Response")
        self.assertIsNone(stopped.get("statusMessage"))

    # case-contract: test_claude_stop_during_turn_launch_interrupts_once_started | A Stop that arrives while Claude Code is still starting the session moves the task to Waiting Response at once, before the session answers. The control interrupt follows as soon as the turn has started, the send settles as stopped without a failure reason, and the task stays in Waiting Response. In the window Stop is enabled as soon as the message is sent, and clicking it replaces Stop with Continue at once while the session is still starting.
    def test_claude_stop_during_turn_launch_interrupts_once_started(self):
        task = self.create_task("Claude stop during launch", provider="claude")
        executable = self.install_provider_fixture("claude", "claude-fixture-launch-stop")
        environment = {"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)}
        self.launch_marker(executable, "launch-pause").write_text("hold\n", encoding="utf-8")
        send = self.start_background_cli("conversation", "send", task["id"], "--message", "Hold until stopped.", expected_status=1, environment=environment)
        self.wait_for(self.launch_marker(executable, "launch-ready").is_file, "Claude Code should be held while starting the session.")
        stop = self.start_background_cli("conversation", "stop", task["id"], environment=environment)
        self.wait_for(
            lambda: self.assert_success(self.call_cli("task", "get", task["id"])[0])["status"] == "Waiting Response",
            "Stop should move the task to Waiting Response while Claude Code is still starting.", timeout=5,
        )
        self.assertFalse(self.launch_marker(executable, "interrupt-received").exists(), "A session that has not started cannot be interrupted yet.")
        self.launch_marker(executable, "launch-release").write_text("release\n", encoding="utf-8")
        self.wait_for(self.launch_marker(executable, "interrupt-received").is_file, "The interrupt should follow as soon as the turn has started.")
        self.launch_marker(executable, "interrupt-release").write_text("acknowledge interrupt\n", encoding="utf-8")
        self.assertTrue(self.assert_success(self.finish_background_cli(stop))["interrupted"])
        self.finish_background_cli(send)
        stopped = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(stopped["status"], "Waiting Response")
        self.assertIsNone(stopped.get("statusMessage"), "A user's stop leaves no failure reason.")

    # case-contract: test_codex_steer_during_turn_launch_reaches_started_turn | A steer sent while Codex is still starting the thread waits for the turn instead of missing it: once the turn has its ID the steer reaches that turn through turn/steer and is not queued for a turn of its own. A follow-up can be queued during the same launch, before Codex has named the conversation; steered, it reaches that turn the same way and leaves the queue. One left in the queue runs once as a turn of its own after that turn ends. In the window the steer's bubble joins the transcript and the composer clears at once, a follow-up typed with Return joins the queue at once without an error, and its row gives way to its bubble at once when steered, while Codex is still held and has not received either.
    def test_codex_steer_during_turn_launch_reaches_started_turn(self):
        task = self.create_repo_task("Codex steer during launch", [self.primary])
        executable = self.install_provider_fixture("codex", "codex-fixture-launch-steer-serial-success-wait")
        environment = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)}
        steer_text = "Steer the turn that is still starting."
        self.launch_marker(executable, "thread-start-pause").write_text("hold\n", encoding="utf-8")
        send = self.start_background_cli("conversation", "send", task["id"], "--message", "Start a turn slowly.", environment=environment)
        self.wait_for(self.launch_marker(executable, "thread-start-ready").is_file, "Codex should be held while starting the thread.")
        steer = self.start_background_cli("conversation", "steer", task["id"], "--message", steer_text, environment=environment)
        row_text = "Steer this queued follow-up into the starting turn."
        row = self.assert_success(self.call_cli("conversation", "queue", task["id"], "--message", row_text)[0])
        row_steer = self.start_background_cli("conversation", "queue-steer", task["id"], row["id"], environment=environment)
        later_text = "Run this follow-up after the starting turn."
        later = self.assert_success(self.call_cli("conversation", "queue", task["id"], "--message", later_text)[0])
        time.sleep(0.5)
        self.assertTrue(steer["thread"].is_alive(), "A steer sent during the launch waits for the turn instead of missing it.")
        self.assertTrue(row_steer["thread"].is_alive(), "A queued follow-up steered during the launch waits for the turn too.")
        self.assertFalse(self.launch_marker(executable, "resolve-ready").exists(), "Codex has not started the turn, so it cannot have either steer yet.")
        self.launch_marker(executable, "thread-start-release").write_text("release\n", encoding="utf-8")
        steered = self.assert_success(self.finish_background_cli(steer))
        self.assertTrue(steered["accepted"])
        self.assertFalse(steered["queued"], "The steer should reach the launching turn, not a turn of its own.")
        row_steered = self.assert_success(self.finish_background_cli(row_steer))
        self.assertTrue(row_steered["accepted"])
        self.assertFalse(row_steered["queued"], "The steered follow-up should reach the launching turn, not a turn of its own.")
        self.assertEqual(
            [item["id"] for item in self.assert_success(self.call_cli("conversation", "queue-list", task["id"])[0])], [later["id"]],
            "Only the follow-up that was not steered stays queued.",
        )
        self.wait_for(self.launch_marker(executable, "resolve-ready").is_file, "The steered turn should be active.")
        self.launch_marker(executable, "resolve-continue").write_text("Release the active turn.\n", encoding="utf-8")
        self.assert_success(self.finish_background_cli(send))
        protocol_history = json.loads(self.launch_marker(executable, "history").read_text(encoding="utf-8"))
        self.assertCountEqual(
            [request["input"] for request in protocol_history["steerRequests"]],
            [[{"type": "text", "text": steer_text}], [{"type": "text", "text": row_text}]],
            "Codex should have received both steers through turn/steer.",
        )
        for request in protocol_history["steerRequests"]:
            self.assertEqual(request["expectedTurnId"], protocol_history["messages"][0]["turnID"])
        turn_prompts = [turn["userMessage"] for turn in protocol_history["messages"]]
        self.assertNotIn(steer_text, turn_prompts, "The steer must not have started a turn of its own.")
        self.assertNotIn(row_text, turn_prompts, "The steered follow-up must not have started a turn of its own.")
        self.assertEqual(turn_prompts.count(later_text), 1, "The follow-up left in the queue runs once as a turn of its own.")
        self.assertEqual(turn_prompts.index(later_text), 1, "It runs right after the turn that was starting.")
        self.assertEqual(self.assert_success(self.call_cli("conversation", "queue-list", task["id"])[0]), [], "A delivered follow-up leaves the queue.")

    # case-contract: test_codex_stop_reaches_message_waiting_behind_stopping_turn | A message sent while the task's earlier turn is still being stopped waits for that turn, and a Stop that arrives while it waits stops it too. That Stop answers at once without asking Codex to interrupt a second time; once the earlier turn is over the waiting send ends with turn_stopped, no second turn starts, and the task stays in Waiting Response with no failure reason. In the window Continue replaces Stop at once, the stopped Continue's message leaves the transcript without an error, and Continue stays available for the turn that was stopped first. The stopped message is saved neither as a draft nor as a prompt still being sent.
    def test_codex_stop_reaches_message_waiting_behind_stopping_turn(self):
        task = self.create_task("Codex stop while a message waits", provider="codex")
        executable = self.install_provider_fixture("codex", "codex-fixture-waiting-hold-interrupt")
        environment = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)}

        def events(name):
            return [event for event in self.diagnostic_events()
                    if event.get("event") == name and str(event.get("taskID", "")).lower() == task["id"].lower()]

        first = self.start_background_cli("conversation", "send", task["id"], "--message", "Hold until stopped.", expected_status=1, environment=environment)
        self.wait_for(self.launch_marker(executable, "interrupt-ready").is_file, "The first turn should be running.")
        first_stop = self.start_background_cli("conversation", "stop", task["id"], environment=environment)
        self.wait_for(self.launch_marker(executable, "interrupt-received").is_file, "Codex should hold its answer to the first Stop.")
        waiting_text = "Continue with the same request from where you left off."
        waiting = self.start_background_cli(
            "conversation", "send", task["id"], "--message", waiting_text,
            expected_status=1, environment=environment,
        )
        self.wait_for(lambda: len(events("conversation.send.accepted")) == 2, "The second message should be accepted while the first turn is still being stopped.")
        started = time.monotonic()
        second_stop = self.assert_success(self.call_cli("conversation", "stop", task["id"], timeout=10, extra_environment=environment)[0])
        self.assertTrue(second_stop["interrupted"], "Stopping a message that waits for its turn counts as an interruption.")
        self.assertLess(time.monotonic() - started, 5, "The Stop answers without waiting for the turn that is still being stopped.")
        self.assertTrue(first_stop["thread"].is_alive(), "Codex still holds its answer to the first Stop.")
        self.assertTrue(waiting["thread"].is_alive(), "The stopped message still waits for the earlier turn to end.")
        self.assertEqual(
            self.assert_success(self.call_cli("task", "get", task["id"])[0])["status"], "Waiting Response",
            "The task leaves In Progress as soon as the waiting message is stopped.",
        )
        self.launch_marker(executable, "interrupt-release").write_text("acknowledge interrupt\n", encoding="utf-8")
        self.assertTrue(self.assert_success(self.finish_background_cli(first_stop))["interrupted"])
        self.finish_background_cli(first)
        self.assertEqual(self.finish_background_cli(waiting)["error"]["code"], "turn_stopped")
        stopped = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(stopped["status"], "Waiting Response")
        self.assertIsNone(stopped.get("statusMessage"), "A user's stop leaves no failure reason.")
        self.assertEqual(
            (stopped.get("savedPrompt"), stopped["hasUnsentDraft"]), (task.get("savedPrompt"), task["hasUnsentDraft"]),
            "A stopped message is not saved as a draft: the task's own draft is as it was.",
        )
        self.assertNotEqual(stopped.get("savedPrompt"), waiting_text)
        self.assertIsNone(stopped.get("pendingSubmittedPrompt"), "A stopped message is not a prompt still being sent.")
        self.assertFalse(self.launch_marker(executable, "interrupt-ready").exists(), "Codex must not be running a second turn.")
        self.assertEqual(
            len(self.launch_marker(executable, "held-turns").read_text(encoding="utf-8").splitlines()), 1,
            "Codex should have received one turn only.",
        )

    # case-contract: test_claude_steer_during_turn_launch_reaches_started_turn | A steer sent while Claude Code is still starting the session waits for the turn instead of missing it: once the turn has started the steer reaches it as a next-priority message, the turn answers it, and it is not queued for a turn of its own. In the window the steer's bubble joins the transcript and the composer clears at once, while the session is still starting and has not received it.
    def test_claude_steer_during_turn_launch_reaches_started_turn(self):
        task = self.create_task("Claude steer during launch", provider="claude")
        executable = self.install_provider_fixture("claude", "claude-fixture-launch-steer")
        environment = {"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)}
        steer_text = "Steer the session that is still starting."
        self.launch_marker(executable, "launch-pause").write_text("hold\n", encoding="utf-8")
        send = self.start_background_cli("conversation", "send", task["id"], "--message", "Hold for a steer.", environment=environment)
        self.wait_for(self.launch_marker(executable, "launch-ready").is_file, "Claude Code should be held while starting the session.")
        steer = self.start_background_cli("conversation", "steer", task["id"], "--message", steer_text, environment=environment)
        time.sleep(0.5)
        self.assertTrue(steer["thread"].is_alive(), "A steer sent during the launch waits for the turn instead of missing it.")
        self.launch_marker(executable, "launch-release").write_text("release\n", encoding="utf-8")
        steered = self.assert_success(self.finish_background_cli(steer))
        self.assertTrue(steered["accepted"])
        self.assertFalse(steered["queued"], "The steer should reach the launching turn, not a turn of its own.")
        self.assert_success(self.finish_background_cli(send))
        self.assertEqual(self.assert_success(self.call_cli("conversation", "queue-list", task["id"])[0]), [])
        history = self.assert_success(self.call_cli("conversation", "history", task["id"], extra_environment=environment)[0])
        texts = [message["text"] for message in history["messages"]]
        self.assertEqual(texts.count(steer_text), 1, f"The steer should appear once in the turn it steered: {texts}")
        self.assertIn(f"STEERED: {steer_text}", texts, "Claude Code should have answered the steer inside the launched turn.")

    # case-contract: test_long_command_activity_title_is_previewed | A tool call whose command is long keeps its whole command: the streamed activity and fresh CLI/XPC history carry its title as Running followed by every line of a heredoc or every character of a long single-line command, and a short command's title is recorded unchanged. While the heredoc still runs, its live command row shows only the title's first line ending in an ellipsis, with no expand control. In the transcript's Worked for list a long title shows its first line, cut to 160 characters and ending in an ellipsis, with an expand control whose accessibility label names expanding the activity title; expanding reveals all of the command and collapsing restores the preview, while the row's accessibility label keeps the full title. A short command's row shows its whole title with no control, and reopening the task shows the long title collapsed again. The preview is Playhouse-owned presentation in the activity row both providers share, and both build a command's title as Running followed by the whole command, so Claude is the representative provider.
    def test_long_command_activity_title_is_previewed(self):
        environment = self.install_claude_fixture("claude-fixture-long-command")
        task_id = self.create_task("Long command title", provider="claude")["id"]
        # Matches LONG_HEREDOC_COMMAND and SHORT_COMMAND in scripts/fixtures/claude-code-fixture.py.
        long_command = "cat > /tmp/playhouse-fixture-release-notes.md <<'NOTES'\n" + "\n".join(
            [f"Release note line {index:03d}: this change keeps a long command readable without laying all of it out." for index in range(1, 121)]
            + ["NOTES"]
        )
        long_title, short_title = "Running " + long_command, "Running echo release notes checked"
        # Matches LONG_SINGLE_LINE_COMMAND: one line past the 160-character preview.
        single_line_title = "Running echo " + " ".join(f"release-note-{index:03d}" for index in range(1, 41))
        expected = {"toolu_long_heredoc": long_title, "toolu_long_single_line": single_line_title, "toolu_short_command": short_title}
        sent, events = self.call_cli("conversation", "send", task_id, "--message", "Write the release notes with one long heredoc.",
                                     extra_environment=environment)
        self.assert_success(sent)
        streamed = {}
        for event in events:
            activity = event.get("payload", {}).get("activity", {})
            if event["type"] == "activity" and activity.get("id") in expected:
                streamed.setdefault(activity["id"], set()).add(activity["title"])
        self.assertEqual(streamed, {tool_id: {title} for tool_id, title in expected.items()},
                         "Every streamed update of each command carries its whole title.")
        self.assertEqual(self.wait_for_task_status(task_id, {"Review"})["status"], "Review")
        # A fresh read is the reload a reopened transcript applies, and what expanding the row shows.
        history = self.assert_success(self.call_cli("conversation", "history", task_id)[0])
        titles = {row["id"]: row["title"] for row in history["activities"]}
        self.assertEqual(titles.get("toolu_long_heredoc"), long_title, "Only the row's presentation is shortened: history keeps the whole command.")
        self.assertEqual(len(titles["toolu_long_heredoc"].splitlines()), 122, "All 120 heredoc lines and both delimiters stay in history.")
        self.assertGreater(len(long_title), 10_000, "The command is long enough that a full layout of it is what the preview avoids.")
        self.assertEqual(titles.get("toolu_short_command"), short_title, "A short command is recorded unchanged.")
        self.assertEqual(titles.get("toolu_long_single_line"), single_line_title, "A long single-line command keeps every character in history.")
        self.assertNotIn("\n", single_line_title)
        self.assertGreater(len(single_line_title), 160, "The single-line command runs past the row's preview.")

    def launch_marker(self, executable, suffix):
        return Path(f"{executable}.{suffix}")

    def start_background_cli(self, *command, expected_status=0, environment=None):
        """Runs a CLI call that blocks on the provider while the case drives the fixture."""
        call = {}

        def run():
            try:
                call["response"] = self.call_cli(*command, expected_status=expected_status, timeout=60, extra_environment=environment)[0]
            except Exception as error:
                call["failure"] = error

        call["thread"] = threading.Thread(target=run, daemon=True)
        call["thread"].start()
        return call

    def finish_background_cli(self, call):
        call["thread"].join(timeout=60)
        self.assertFalse(call["thread"].is_alive(), "The CLI call should settle.")
        self.assertIsNone(call.get("failure"), f"The CLI call failed: {call.get('failure')}")
        return call["response"]
    TASK_CARD_PLUGIN_SOURCE = """
function Card() {
  var props = Playhouse.useProps();
  var log = React.useState([]);
  var probes = React.useState(0);
  React.useEffect(function () {
    var note = function (entry) { log[1](function (entries) { return entries.concat([entry]); }); };
    var probe = Playhouse.throttle(function (reason) {
      probes[1](function (count) { return count + 1; });
      note("probe " + reason);
    }, 20);
    var offMove = Playhouse.on("task.statusChanged", function (event) { note(event.from + " to " + event.to); probe("move"); });
    var offFocus = Playhouse.on("app.focus", function () { probe("focus"); });
    var offState = Playhouse.on("plugin.stateChanged", function (event) { note("state " + event.key); offMove(); });
    return function () { offMove(); offFocus(); offState(); };
  }, []);
  return h(Stack, { axis: "h", spacing: 4 },
    h(Text, { size: 10, testID: "card-status" }, props.task ? props.task.status : "no task"),
    h(Text, { size: 10, testID: "card-probes" }, "probes " + probes[0]),
    h(Text, { size: 10, testID: "card-log" }, log[0].join(", ")));
}
Playhouse.render(h(Card));
"""
    TASK_CARD_BUTTON_SOURCE = """
function CardButton() {
  var props = Playhouse.useProps();
  var result = React.useState("idle");
  var id = props.task ? props.task.id : "none";
  function act(testID, label, call) {
    return h(Button, { testID: testID, style: "bordered", onPress: function () {
      call().then(function () { result[1](label + ": ok"); }, function (error) { result[1](label + ": " + error.code); });
    } }, h(Text, { size: 11 }, label));
  }
  return h(Stack, { spacing: 6, align: "leading" },
    h(Text, { testID: "button-task" }, props.task ? props.task.title : "no task"),
    h(Text, { size: 11, testID: "button-result" }, result[0]),
    act("button-alert", "alert", function () { return Playhouse.ui.alert("Card plugin alert", "Raised from the task card."); }),
    act("button-compose", "composer", function () { return Playhouse.ui.composer.setDraft("from the card"); }),
    act("button-resolve", "resolveConflicts", function () { return Playhouse.ui.resolveConflicts(id); }),
    act("button-move", "moveTask", function () { return Playhouse.ui.moveTask(id, "Review"); }));
}
Playhouse.render(h(CardButton));
"""
    # case-contract: test_plugin_task_card_placement_events_and_throttle | A plugin installed at the taskItem placement (inline or as a button) is valid and runs with its card's task as `props.task`. Playhouse.on delivers app events to a plugin's listeners: task.statusChanged with {taskID, from, to} when its task moves between columns, app.focus when the app comes to the front, and plugin.stateChanged with {pluginID, key, value} when a saved value changes; `plugin render --event @<name>[:json]` reports how many listeners heard each, and the function Playhouse.on returns stops listening. Playhouse.throttle(fn, seconds) runs the first call at once and collapses the calls made within its cooldown into one trailing call with the latest arguments when the cooldown ends. `plugin event <name> [--payload <json>]` hands an app event to the built-in plugins' services; an unknown name is invalid_argument and a payload that is not a JSON object is a usage error. In the window, an installed task card plugin renders on every card, a Backlog card included (which has no built-in pull request controls yet), in the bottom row beside the built-in mode pill once the task has started, shows its task's status, hears the task move to Review and probes through its throttle, and probes through it again when the app comes back to the front (the window's app.focus), repeated focuses within its cooldown collapsing into at most two probes; a task card plugin with a button opens a popover showing its card's task. Only a task card's plugin may call ui.moveTask (which moves its task as dragging the card does), ui.resolveConflicts (which in the window opens its task and sends the conflict instruction) and ui.alert (which shows the board's alert); from the conversation sidebar or the board's sidebar they are unavailable, and so is the composer from a task card, the same in `plugin render`, which records each call in hostCalls, and in the window. The Plugins menu lists the card's built-ins, and disabling the built-in Pull request mode removes the card's mode pill while installed task card plugins stay, until it is enabled again. A turn's move of its task, on Codex and on Claude, is published to the services from the provider's own callbacks, and no move is dropped.
    def test_plugin_task_card_placement_events_and_throttle(self):
        task_id = "C0FFEE00-0000-4000-8000-0000000000AA"
        move = json.dumps({"taskID": task_id, "from": "In Progress", "to": "Review"})
        rendered = self.assert_success(self.render_plugin(
            self.TASK_CARD_PLUGIN_SOURCE,
            "--event", f"@task.statusChanged:{move}",
            "--event", "@app.focus",
            "--event", "@app.focus",
        ))
        self.assertEqual(rendered["errors"], [])
        self.assertEqual([(event["name"], event["listeners"]) for event in rendered["emitted"]],
                         [("task.statusChanged", 1), ("app.focus", 1), ("app.focus", 1)], "Each event reaches the plugin's one listener.")
        self.assertEqual(self.plugin_text(self.plugin_node(rendered["tree"], "card-log")), "In Progress to Review, probe move",
                         "The move's payload reaches the listener, and the first probe runs at once.")
        self.assertEqual(self.plugin_text(self.plugin_node(rendered["tree"], "card-probes")), "probes 1",
                         "Focus events within the cooldown don't probe again yet.")
        steps = [commit["step"] for commit in rendered["commits"]]
        self.assertIn("@task.statusChanged", steps, "The listener's update commits under its event.")

        # The cooldown ends: the collapsed focus calls run once, then the next waits again.
        cooled = self.assert_success(self.render_plugin(
            self.TASK_CARD_PLUGIN_SOURCE,
            "--event", f"@task.statusChanged:{move}",
            "--event", "@app.focus",
            "--event", "@app.focus",
            "--event", "@app.focus",
            "--event", "+20",
            "--event", "@app.focus",
            "--event", "+5",
        ))
        self.assertEqual(cooled["errors"], [])
        self.assertEqual(self.plugin_text(self.plugin_node(cooled["tree"], "card-log")), "In Progress to Review, probe move, probe focus",
                         "Three focus events in the cooldown collapse into one trailing probe.")
        self.assertEqual(self.plugin_text(self.plugin_node(cooled["tree"], "card-probes")), "probes 2",
                         "A focus right after the trailing probe waits for the next cooldown.")
        later = self.assert_success(self.render_plugin(
            self.TASK_CARD_PLUGIN_SOURCE, "--event", "@app.focus", "--event", "@app.focus", "--event", "+20", "--event", "+20",
        ))
        self.assertEqual(self.plugin_text(self.plugin_node(later["tree"], "card-probes")), "probes 2", "Once the cooldown ends, the trailing call runs; nothing more is left.")

        # The function Playhouse.on returns stops listening.
        state = json.dumps({"pluginID": "card-probe", "key": "seen", "value": True})
        stopped = self.assert_success(self.render_plugin(
            self.TASK_CARD_PLUGIN_SOURCE, "--event", f"@plugin.stateChanged:{state}", "--event", f"@task.statusChanged:{move}",
        ))
        self.assertEqual([(event["name"], event["listeners"]) for event in stopped["emitted"]], [("plugin.stateChanged", 1), ("task.statusChanged", 0)])
        self.assertEqual(self.plugin_text(self.plugin_node(stopped["tree"], "card-log")), "state seen")
        self.assert_failure(self.render_plugin(self.TASK_CARD_PLUGIN_SOURCE, "--event", "@app.focus:[1]", expected_status=2), "invalid_argument")

        # Installed at the task card, it runs with its card's task.
        self.write_installed_plugin("card-probe", self.TASK_CARD_PLUGIN_SOURCE, placement="taskItem", presentation="inline")
        self.write_installed_plugin("card-button", self.TASK_CARD_BUTTON_SOURCE, placement="taskItem", presentation="popover")
        refreshed = {plugin["id"]: plugin for plugin in self.assert_success(self.call_cli("plugin", "refresh")[0])["plugins"]}
        for plugin_id, presentation in (("card-probe", "inline"), ("card-button", "popover")):
            self.assertEqual((refreshed[plugin_id]["placement"], refreshed[plugin_id]["presentation"], refreshed[plugin_id]["valid"]),
                             ("taskItem", presentation, True), refreshed[plugin_id]["errors"])
        task = self.create_task(title="Task card plugin task")
        on_card = self.assert_success(self.call_cli("plugin", "render", "--plugin", "card-probe", "--task", task["id"])[0])
        self.assertEqual(on_card["errors"], [])
        self.assertEqual(self.plugin_text(self.plugin_node(on_card["tree"], "card-status")), "Backlog", "The card's task is the plugin's props.task.")
        from_button = self.assert_success(self.call_cli("plugin", "render", "--plugin", "card-button", "--task", task["id"])[0])
        self.assertEqual(self.plugin_text(self.plugin_node(from_button["tree"], "button-task")), "Task card plugin task",
                         "A task card plugin opened from its button gets its card's task too.")

        # Only a task card's plugin moves its task, resolves its conflicts or raises an alert, as the
        # board answers those; a task card has no composer. Both hosts refuse by the same rules.
        def press(plugin_id, button, with_task=True):
            options = ["--task", task["id"]] if with_task else []
            pressed = self.assert_success(self.call_cli("plugin", "render", "--plugin", plugin_id, *options, "--event", f"{button}:onPress")[0])
            return self.plugin_text(self.plugin_node(pressed["tree"], "button-result")), pressed["hostCalls"][-1]
        for button, name, arguments in (("button-move", "moveTask", {"taskID": task["id"], "status": "Review"}),
                                         ("button-resolve", "resolveConflicts", {"taskID": task["id"]}),
                                         ("button-alert", "alert", {"title": "Card plugin alert", "message": "Raised from the task card."})):
            text, call = press("card-button", button)
            self.assertEqual(text, f"{name}: ok")
            self.assertEqual((call["kind"], call["name"], call["ok"], call["arguments"]), ("ui", name, True, arguments), "plugin render records the call.")
        text, call = press("card-button", "button-compose")
        self.assertEqual((text, call["error"]["code"]), ("composer: unavailable", "unavailable"), "A task card has no composer.")
        self.write_installed_plugin("sidebar-button", self.TASK_CARD_BUTTON_SOURCE, placement="conversationSidebar", presentation="popover")
        self.write_installed_plugin("board-button", self.TASK_CARD_BUTTON_SOURCE, placement="mainSidebar", presentation="popover")
        self.assert_success(self.call_cli("plugin", "refresh")[0])
        for plugin_id, with_task in (("sidebar-button", True), ("board-button", False)):
            for button, name in (("button-move", "moveTask"), ("button-resolve", "resolveConflicts"), ("button-alert", "alert")):
                text, call = press(plugin_id, button, with_task)
                self.assertEqual((text, call["error"]["code"]), (f"{name}: unavailable", "unavailable"), f"{name} is the task card's alone, not {plugin_id}'s.")
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task["id"])[0])["status"], "Backlog", "plugin render records a move; it doesn't make one.")

        # The card's controls are built-in plugins that can be disabled and enabled again.
        self.assert_success(self.call_cli("plugin", "disable", "--id", "pull-request-mode")[0])
        listed = {plugin["id"]: plugin for plugin in self.assert_success(self.call_cli("plugin", "list")[0])["plugins"]}
        self.assertEqual((listed["pull-request-mode"]["enabled"], listed["card-probe"]["enabled"]), (False, True))
        self.assert_success(self.call_cli("plugin", "enable", "--id", "pull-request-mode")[0])
        listed = {plugin["id"]: plugin for plugin in self.assert_success(self.call_cli("plugin", "list")[0])["plugins"]}
        self.assertTrue(listed["pull-request-mode"]["enabled"])

        # `plugin event` hands an app event to the built-in plugins' services.
        delivered = self.assert_success(self.call_cli("plugin", "event", "app.focus")[0])
        self.assertEqual(delivered["name"], "app.focus")
        self.assertGreaterEqual(delivered["delivered"], 1, "The pull request mode plugin's service hears it.")
        moved = json.dumps({"taskID": task["id"], "from": "Backlog", "to": "In Progress"})
        self.assertEqual(self.assert_success(self.call_cli("plugin", "event", "task.statusChanged", "--payload", moved)[0])["name"], "task.statusChanged")
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task["id"])[0])["status"], "Backlog", "An event reports a move; it doesn't make one.")
        unknown = self.call_cli("plugin", "event", "task.exploded", expected_status=2)[0]
        self.assert_failure(unknown, "invalid_argument")
        self.assertIn("task.statusChanged", unknown["error"]["message"], "The error lists the events there are.")
        self.assert_failure(self.call_cli("plugin", "event", "app.focus", "--payload", "[1]", expected_status=2)[0], "invalid_argument")

        # A turn's end moves its task on whichever provider ran it, from the provider's
        # own callbacks; each move still reaches the services, none dropped.
        def published(task_id, to):
            return [event for event in self.diagnostic_events() if event.get("event") == "plugin.event.published"
                    and event.get("name") == "task.statusChanged" and event.get("taskID") == task_id and event.get("to") == to]
        codex_task = self.create_task(title="Task card Codex move")
        self.complete_fixture_turn(codex_task["id"])
        self.assertTrue(published(codex_task["id"], "Review"), "A Codex turn reaching Review is published to the services.")
        claude_task = self.create_task(title="Task card Claude move", provider="claude")
        self.assert_success(self.call_cli(
            "conversation", "send", claude_task["id"], "--message", "Tell me a story.",
            extra_environment=self.install_claude_fixture("claude-fixture-card-move"),
        )[0])
        self.wait_for_task_status(claude_task["id"], {"Review"})
        self.assertTrue(published(claude_task["id"], "Review"), "A Claude turn reaching Review is published to the services.")
        self.assertEqual([event for event in self.diagnostic_events() if event.get("event") == "plugin.event.dropped"], [],
                         "No move is dropped for want of its request.")
