from test_bridge_support import *
from test_bridge_support import __file__

class BridgeTestCases17:
    # case-contract: test_task_token_usage_records_codex_turn_breakdown | A Codex app-server fixture turn's usage reaches the same per-task totals and per-turn breakdown through Codex's own wire shape, mapping its cached-input bucket onto Playhouse's cache-read bucket and leaving cache-write at zero. The recorded turn row names Codex as its provider, Codex's input count includes its cached tokens, so the input bucket excludes them rather than counting them twice. Per-call usage notifications streamed before the turn ends, including those of a subagent thread that names its parent, reach the same call-level accounting once each (a repeated notification is ignored), and the Token Stats modal shows those Codex totals, call counts and final transcript size in the app. Excluding cache reads, the figure counts each call's uncached input plus cache write plus output, main thread and subagent alike (780), and the modal shows it with its main-agent and subagent split.
    def test_task_token_usage_records_codex_turn_breakdown(self):
        # Matches TURN_USAGE in scripts/fixtures/codex-app-server-fixture.py.
        # The fixture reports 900 input tokens of which 250 were cached; Codex's input
        # count includes the cached part, so the input bucket keeps only the other 650.
        expected_turn_usage = {
            "inputTokens": 650, "outputTokens": 150, "cacheReadTokens": 250, "cacheCreationTokens": 0,
        }
        turn_total = sum(expected_turn_usage.values())
        task_id = self.create_task(title="Codex token usage", roots=[self.primary])["id"]
        self.complete_fixture_turn(task_id, executable_name="codex-fixture-token-usage")

        summary = self.assert_success(self.call_cli("task", "token-usage", task_id)[0])
        self.assertEqual(
            summary["usage"], expected_turn_usage,
            "Codex's cached-input bucket should map onto cache read, with no cache-write bucket.",
        )
        self.assertEqual(summary["totalTokens"], turn_total)
        self.assertEqual(len(summary["turns"]), 1)
        self.assertEqual(summary["turns"][0]["provider"], "codex")
        self.assertEqual(summary["turns"][0]["totalTokens"], turn_total)
        # The fixture streams two main-thread calls sending 700 and 900 (the second notification
        # repeated) and one subagent call sending 300, so a repeat must not add a call.
        calls = summary["callUsage"]
        self.assertTrue(calls["available"])
        self.assertEqual(
            {key: calls[key] for key in ("totalCalls", "totalSentTokens", "totalOutputTokens", "finalTranscriptTokens")},
            {"totalCalls": 3, "totalSentTokens": 1900, "totalOutputTokens": 80, "finalTranscriptTokens": 900},
        )
        # Codex input includes cached tokens: main calls (700-500)+30 and (900-600)+40, subagent (300-100)+10.
        self.assertEqual(calls["subagents"], {
            "count": 1, "calls": 1, "sentTokens": 300, "outputTokens": 10, "tokensExcludingCacheReads": 210,
        })
        self.assertEqual(calls["mainAgent"]["tokensExcludingCacheReads"], 570)
        self.assertEqual(
            calls["totalTokensExcludingCacheReads"], 780,
            "Excluding cache reads sums uncached input + cache write + output over the main thread and its subagent.",
        )
        self.assertEqual(summary["tokensExcludingCacheReads"], 780)
    # case-contract: test_task_token_waste_ranks_claude_items_by_size | A task with no conversation reports its token map unavailable, with no wasters, tools or agents. After a Claude Code fixture turn whose session file logs every request (a shape, blobs, and transcript lines referenced by hash, including a parallel tool call sent as one message), the map reads the main agent and its subagent, and the main agent's final transcript tokens equal its last request's context exactly. The largest item is the MCP tool's 1,000-line log, ranked by the tokens it added, flagged as removed by the compaction, and sharing the tokens of the request it arrived in with its call by characters. The tools rollup ranks that MCP tool first by tokens added, the MCP server rollup counts its defined and called tools and what its definitions cost, the overhead lists the system prompt, each built-in tool definition and the server's definitions as sent with every request, the README read twice is one repeated result, the request that re-sent its context without the prompt cache is the one cache miss, and the compaction is counted. The Token Stats modal shows these in its Wasters, Tools & MCP and Overhead sections.
    def test_task_token_waste_ranks_claude_items_by_size(self):
        empty_id = self.create_task(title="No conversation yet", provider="claude")["id"]
        empty = self.assert_success(self.call_cli("task", "token-waste", empty_id)[0])
        self.assertFalse(empty["available"], "A task with no conversation has nothing to map.")
        self.assertEqual((empty["wasters"], empty["tools"], empty["agents"]), ([], [], []))

        task_id, environment = self.run_claude_token_waste_turn("Claude token waste")
        report = self.assert_success(self.call_cli("task", "token-waste", task_id, extra_environment=environment)[0])
        self.assertTrue(report["available"])
        agents = {agent["id"]: agent for agent in report["agents"]}
        self.assertEqual(list(agents), ["claude", "claude/fxw"], "The main agent comes first, then each subagent file.")
        # The fixture's main agent makes 66 requests and ends on a 3,160-token context.
        self.assertEqual(
            {key: agents["claude"][key] for key in ("requests", "finalTranscriptTokens", "compactions")},
            {"requests": 66, "finalTranscriptTokens": 3160, "compactions": 1},
        )
        self.assertEqual(agents["claude/fxw"]["finalTranscriptTokens"], 1000)
        # The usage summary sums the same session files by message ID; the two readers must agree.
        call_usage = self.assert_success(self.call_cli("task", "token-usage", task_id, extra_environment=environment)[0])["callUsage"]
        self.assertEqual(call_usage["mainAgent"]["sentTokens"], agents["claude"]["sentTokens"])
        self.assertEqual(call_usage["mainAgent"]["finalTranscriptTokens"], agents["claude"]["finalTranscriptTokens"])

        wasters = report["wasters"]
        top = wasters[0]
        self.assertEqual(
            (top["label"], top["kind"], top["agent"], top["inFinalTranscript"]),
            ("fixturelogs/query_logs", "toolResult", "claude", False),
            "The MCP tool's log is the largest item, and the compaction removed it.",
        )
        self.assertEqual(top["requests"], 63, "Three requests before the 60 filler rounds carried the log.")
        self.assertEqual(top["rentTokens"], top["tokens"] * 63)
        self.assertEqual([item["tokens"] for item in wasters], sorted((item["tokens"] for item in wasters), reverse=True))
        # The log and its call arrived together, adding 18,000 tokens split by characters.
        rows = self.assert_success(self.call_cli(
            "task", "raw-input", task_id, "--scope", "all", "--limit", "1000", extra_environment=environment,
        )[0])["rows"]
        log = next(row for row in rows if row["id"] == top["item"])
        call = next(row for row in rows if row["kind"] == "toolCall" and row["label"] == "fixturelogs/query_logs")
        self.assertEqual(top["tokens"], 18000 - 18000 * call["textLength"] // (call["textLength"] + log["textLength"]))
        self.assertEqual(call["tokens"] + top["tokens"], 18000)

        tools = report["tools"]
        self.assertEqual([tool["id"] for tool in tools][:3], ["fixturelogs/query_logs", "Bash", "Read"])
        self.assertEqual(
            {key: tools[0][key] for key in ("server", "calls", "totalTokens", "resultTokens", "largestResultTokens")},
            {"server": "fixturelogs", "calls": 1, "totalTokens": 18000, "resultTokens": top["tokens"], "largestResultTokens": top["tokens"]},
        )
        self.assertEqual(tools[1]["calls"], 62, "Sixty filler rounds (the first runs two tools) and the outcome report.")
        self.assertEqual(tools[2]["calls"], 3, "README.md is read twice by the main agent and once by the subagent.")
        server = report["servers"][0]
        self.assertEqual((server["id"], server["tools"], server["calls"], server["totalTokens"]), ("fixturelogs", 2, 1, 18000))
        self.assertGreater(server["definitionTokens"], 0, "Both tool definitions cost tokens on every request.")

        overhead = {entry["label"]: entry for entry in report["overhead"]}
        for label in ("System prompt (part 1)", "Tool definition: Bash", "Tool definition: Read", "MCP server fixturelogs · 2 tool definitions"):
            self.assertIn(label, overhead)
            self.assertTrue(overhead[label]["everyRequest"], f"{label} is sent with every request.")
            self.assertEqual(overhead[label]["requests"], 66)
        repeats = [entry for entry in report["duplicates"] if entry["agent"] == "claude"]
        self.assertEqual([(entry["label"], entry["copies"]) for entry in repeats], [("Read", 2)])
        self.assertEqual(repeats[0]["wastedTokens"], repeats[0]["tokensPerCopy"])
        self.assertEqual(
            [(miss["agent"], miss["request"]) for miss in report["cacheMisses"]], [("claude", 34)],
            "Only the request that skipped the cache re-sent its context; adding the log is new content, not a miss.",
        )
    # case-contract: test_task_token_waste_ranks_codex_items_by_size | A Codex fixture turn whose thread and subagent have rollout files gives the same map from Codex's own format: a request was sent the instructions plus every item before its own output, the final transcript's tokens equal the last request's input exactly after a compaction replaced the history, Codex's unsaved tool definitions appear as one hidden-overhead item sent with every request, encrypted reasoning is shown by its size, the MCP tool's log is the largest item and was removed by the compaction, the repeated README read and the cache miss are reported, and the subagent's thread is its own agent. The raw input's final transcript lists the hidden overhead, the instructions and the replacement history once each without the removed log, and an item's full text, from a tool output or from the replacement history, reads back exactly as Codex saved it, in chunks, with its call named. The single-request scope rebuilds each Codex request from the rollout and labels it reconstructed: the latest request is the final transcript in order, request 4 flags both README reads and both of their outputs as exact duplicates, each request's items add up to the input Codex reported with its cached share as cache read and no cache write, and the JSON export holds the base instructions and the input items exactly as saved. The Token Stats modal shows the Codex wasters, the hidden overhead and the subagent, showing the log opens its full text, and the raw input's single request reads as reconstructed, with request 4's duplicates flagged.
    def test_task_token_waste_ranks_codex_items_by_size(self):
        task_id = self.create_task(title="Codex token waste", roots=[self.primary])["id"]
        self.complete_fixture_turn(task_id, executable_name="codex-fixture-token-waste", message="Show token waste.")
        thread_id = self.assert_success(self.call_cli("task", "get", task_id)[0])["codexThreadID"]
        report = self.assert_success(self.call_cli("task", "token-waste", task_id)[0])
        self.assertTrue(report["available"])
        agents = {agent["id"]: agent for agent in report["agents"]}
        self.assertEqual(list(agents), ["codex", f"codex/{thread_id}-subagent"])
        self.assertEqual(
            {key: agents["codex"][key] for key in ("requests", "finalTranscriptTokens", "compactions")},
            {"requests": 5, "finalTranscriptTokens": 4400, "compactions": 1},
            "The final transcript is what the last request was sent, after the compaction.",
        )
        self.assertEqual(agents[f"codex/{thread_id}-subagent"]["finalTranscriptTokens"], 300)

        top = report["wasters"][0]
        self.assertEqual(
            (top["label"], top["kind"], top["inFinalTranscript"], top["requests"]),
            ("fixturelogs/query_logs", "toolResult", False, 3),
        )
        overhead = {entry["kind"]: entry for entry in report["overhead"]}
        hidden = overhead["hiddenOverhead"]
        self.assertEqual(hidden["label"], "Tool definitions and other context Codex does not save")
        self.assertTrue(hidden["everyRequest"])
        self.assertEqual(hidden["requests"], 5)
        self.assertTrue(0 < hidden["tokens"] < 4000, "The first request's cost beyond its visible items.")
        self.assertEqual(overhead["systemPrompt"]["label"], "Codex base instructions")
        tools = {tool["id"]: tool for tool in report["tools"]}
        self.assertEqual(report["tools"][0]["id"], "fixturelogs/query_logs")
        self.assertEqual((tools["fixturelogs/query_logs"]["server"], tools["exec"]["calls"]), ("fixturelogs", 2))
        self.assertEqual([(entry["label"], entry["copies"]) for entry in report["duplicates"]], [("exec", 2)])
        self.assertEqual([(miss["agent"], miss["request"]) for miss in report["cacheMisses"]], [("codex", 4)])

        rows = self.assert_success(self.call_cli("task", "raw-input", task_id, "--scope", "all", "--limit", "1000")[0])["rows"]
        reasoning = next(row for row in rows if row["kind"] == "thinking")
        self.assertEqual(reasoning["preview"], "[encrypted reasoning: 305 characters]")
        self.assertEqual(rows[0]["kind"], "hiddenOverhead", "The hidden overhead leads everything sent.")

        # The final transcript: hidden overhead, base instructions, then the
        # compaction's replacement history and the message after it, each once.
        final = self.assert_success(self.call_cli("task", "raw-input", task_id, "--limit", "1000")[0])
        self.assertEqual(final["totalTokens"], 4400)
        self.assertEqual(
            [(row["kind"], row["label"]) for row in final["rows"]],
            [("hiddenOverhead", "Tool definitions and other context Codex does not save"),
             ("systemPrompt", "Codex base instructions"), ("userText", "User message"),
             ("other", "Compaction summary"), ("userText", "User message")],
        )
        self.assertNotIn(top["item"], [row["id"] for row in final["rows"]], "The compaction removed the log.")

        def full_text(item):
            chunks, offset = [], 0
            while True:
                chunk = self.assert_success(self.call_cli(
                    "task", "raw-input-text", task_id, "--item", str(item), "--offset", str(offset),
                )[0])
                chunks.append(chunk["text"])
                if chunk.get("nextOffset") is None:
                    return "".join(chunks), len(chunks), chunk
                offset = chunk["nextOffset"]

        log_text, log_chunks, log_chunk = full_text(top["item"])
        expected_log = "".join(
            f"2026-11-03T10:{index // 60 % 60:02d}:{index % 60:02d}Z INFO fixture log line {index:04d} "
            f"{'NEEDLE-42 ' if index == 900 else ''}request ok path=/api/orc/builds/{index:04d}\n"
            for index in range(1, 1001)
        )
        self.assertEqual(log_text, expected_log, "A Codex tool output reads back exactly as Codex saved it.")
        self.assertGreater(log_chunks, 1)
        self.assertTrue(log_chunk["call"].startswith("fixturelogs/query_logs"))
        self.assertIn("5000", log_chunk["call"])
        replaced_prompt = final["rows"][2]["id"]
        self.assertEqual(full_text(replaced_prompt)[0], "Show token waste.", "An item of the replacement history reads back exactly.")
        self.assertEqual(full_text(final["rows"][1]["id"])[0], "You are the Codex fixture. " * 80)

        # One request at a time, rebuilt from the rollout: Codex resends the
        # whole history, so a request is everything saved before its output.
        def single(*options, expected_status=0):
            response, _ = self.call_cli("task", "raw-input", task_id, "--scope", "request", "--limit", "1000", *options,
                                        expected_status=expected_status)
            return response

        latest = self.assert_success(single())
        request = latest["request"]
        self.assertEqual(
            {key: request.get(key) for key in ("number", "count", "latest", "exact", "contextTokens", "itemTokens",
                                                "inputTokens", "cacheReadTokens", "cacheWriteTokens")},
            {"number": 5, "count": 5, "latest": 5, "exact": False, "contextTokens": 4400, "itemTokens": 4400,
             "inputTokens": 500, "cacheReadTokens": 3900, "cacheWriteTokens": None},
            "Codex reports no cache writes; its cached input is the cache-read share.",
        )
        self.assertTrue(request["note"].startswith("Reconstructed: Codex resends the whole history"))
        self.assertEqual([row["id"] for row in latest["rows"]], [row["id"] for row in final["rows"]],
                         "The latest request is the final transcript, in order.")
        repeated = self.assert_success(single("--request", "4"))
        self.assertEqual((repeated["request"]["items"], repeated["request"]["itemTokens"], repeated["request"]["contextTokens"]), (12, 19600, 19600))
        self.assertEqual(
            [(row["position"], row["label"], row["repeated"]["copy"]) for row in repeated["rows"] if row.get("repeated")],
            [(8, "exec", 1), (9, "exec", 1), (10, "exec", 2), (11, "exec", 2)],
            "Both README reads and both of their outputs were sent in request 4.",
        )
        first_request = self.assert_success(single("--request", "1"))["request"]
        self.assertEqual((first_request["items"], first_request["itemTokens"], first_request["contextTokens"], first_request["repeatedItems"]),
                         (5, 4000, 4000, 0))
        body = json.loads(self.assert_success(self.call_cli(
            "task", "raw-input-export", task_id, "--request", "1", "--format", "json",
        )[0])["text"])
        self.assertEqual(body["instructions"], "You are the Codex fixture. " * 80)
        self.assertEqual(body["input"], [
            {"type": "message", "role": "developer", "content": [{"type": "input_text", "text": "<permissions instructions>\nThe fixture may run any command.\n</permissions instructions>"}]},
            {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "# AGENTS.md instructions for the fixture\nKeep answers short."}]},
            {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "Show token waste."}]},
        ], "The input items exactly as Codex saved them; the unsaved tool definitions are left out.")
        self.assert_failure(single("--request", "6", expected_status=3), "not_found")
    # case-contract: test_task_raw_input_pages_final_transcript_without_duplicates | A task with no conversation has no raw input: its page is empty and reading an item's text is not_found. After a Claude Code fixture turn, the raw input lists the final transcript with each item once across pages and without the log a compaction removed; the everything-sent scope adds what was removed, ordering by size lists the largest first, a search finds the log by a word only its full text contains, and a focus item reports its position. An item's full text reads back in chunks that end on a line break and join to the exact text, with the call that produced it named. An unknown agent or item is not_found, and an unknown order or a limit of zero is invalid_argument. In the app, View raw input opens the final transcript, scrolling loads the next page of rows, showing the largest waster opens it in the everything-sent scope with its full text, and scrolling that text reaches its last line.
    def test_task_raw_input_pages_final_transcript_without_duplicates(self):
        empty_id = self.create_task(title="No raw input yet", provider="claude")["id"]
        empty = self.assert_success(self.call_cli("task", "raw-input", empty_id)[0])
        self.assertEqual((empty["total"], empty["rows"], empty["agents"], empty.get("agent")), (0, [], [], None))
        response, _ = self.call_cli("task", "raw-input-text", empty_id, "--item", "0", expected_status=3)
        self.assert_failure(response, "not_found")

        task_id, environment = self.run_claude_token_waste_turn("Claude raw input")

        def raw_input(*options, expected_status=0):
            response, _ = self.call_cli("task", "raw-input", task_id, *options, extra_environment=environment, expected_status=expected_status)
            return response

        first = self.assert_success(raw_input("--limit", "4"))
        self.assertEqual((first["agent"], first["scope"], first["order"]), ("claude", "final", "transcript"))
        # Shape (system prompt and four tools), the prompt's two blocks, the
        # compaction summary, and the last call and result.
        self.assertEqual((first["total"], first["totalTokens"]), (10, 3160))
        final_ids = []
        for offset in range(0, first["total"], 4):
            page = self.assert_success(raw_input("--offset", str(offset), "--limit", "4"))
            self.assertEqual(page["offset"], offset)
            final_ids += [row["id"] for row in page["rows"]]
            self.assertTrue(all(row["inFinalTranscript"] for row in page["rows"]))
        self.assertEqual(len(final_ids), 10)
        self.assertEqual(len(set(final_ids)), 10, "Each item appears once across pages.")
        self.assertEqual(
            [row["kind"] for row in first["rows"]], ["systemPrompt", "toolDefinition", "toolDefinition", "toolDefinition"],
        )

        everything = self.assert_success(raw_input("--scope", "all", "--limit", "1000"))
        all_ids = [row["id"] for row in everything["rows"]]
        self.assertEqual(len(all_ids), everything["total"])
        self.assertEqual(len(set(all_ids)), len(all_ids), "Everything sent still lists each item once.")
        self.assertGreater(everything["total"], 100, "Enough items to need a second page in the app.")
        log = next(row for row in everything["rows"] if row["label"] == "fixturelogs/query_logs" and row["kind"] == "toolResult")
        self.assertNotIn(log["id"], final_ids, "The compaction removed the log from the final transcript.")
        self.assertEqual(
            sorted(row["id"] for row in everything["rows"] if row["inFinalTranscript"]), sorted(final_ids),
        )

        largest = self.assert_success(raw_input("--scope", "all", "--order", "size", "--limit", "5"))
        self.assertEqual(largest["rows"][0]["id"], log["id"])
        self.assertEqual([row["tokens"] for row in largest["rows"]], sorted((row["tokens"] for row in largest["rows"]), reverse=True))
        self.assertNotIn("NEEDLE-42", log["preview"], "The search word sits deep in the log, past its preview.")
        found = self.assert_success(raw_input("--scope", "all", "--query", "NEEDLE-42"))
        self.assertEqual([row["id"] for row in found["rows"]], [log["id"]])
        focused = self.assert_success(raw_input("--scope", "all", "--limit", "1", "--focus", str(log["id"])))
        self.assertEqual(focused["focusPosition"], all_ids.index(log["id"]))

        chunks = []
        offset = 0
        while True:
            chunk = self.assert_success(self.call_cli(
                "task", "raw-input-text", task_id, "--item", str(log["id"]), "--offset", str(offset),
                extra_environment=environment,
            )[0])
            self.assertEqual(chunk["offset"], offset)
            chunks.append(chunk["text"])
            # The last chunk has no next offset, so the key is absent.
            if chunk.get("nextOffset") is None:
                break
            self.assertTrue(chunk["text"].endswith("\n"), "A chunk that is not the last ends on a line break.")
            offset = chunk["nextOffset"]
        self.assertGreater(len(chunks), 1, "A 1,000-line log reads back in more than one chunk.")
        text = "".join(chunks)
        self.assertEqual(len(text), chunk["totalLength"])
        lines = text.splitlines()
        self.assertEqual(len(lines), 1000)
        self.assertIn("NEEDLE-42", lines[899])
        self.assertTrue(lines[-1].endswith("/api/orc/builds/1000"))
        self.assertTrue(chunk["call"].startswith("fixturelogs/query_logs"), "A tool result names the call that produced it.")
        self.assertIn("5000", chunk["call"])

        self.assert_failure(raw_input("--agent", "nope", expected_status=3), "not_found")
        self.assert_failure(raw_input("--order", "bogus", expected_status=2), "invalid_argument")
        self.assert_failure(raw_input("--limit", "0", expected_status=2), "invalid_argument")
        response, _ = self.call_cli(
            "task", "raw-input-text", task_id, "--item", "99999", extra_environment=environment, expected_status=3,
        )
        self.assert_failure(response, "not_found")
    # case-contract: test_task_raw_input_single_request_lists_resumed_instruction_copies_in_order | After a Claude Code fixture session that resumes once its AGENTS.md changed, the raw input's single-request scope lists every item one request sent, in order and with nothing merged, and shows the latest request by default. A request after the resume carries both instruction copies in order, which differ and so are not flagged, while the date reminder sent twice word for word is flagged as a duplicate; a request before the resume carries one copy and no duplicates, and a search keeps each row's position. Each request reports Claude's input with its cache-read and cache-write split, and its items' sizes add up to that input. The request is labelled exact; its text export gives every item's full text under a header naming any duplicate, and its JSON export is the request body with the logged parameters, cache markers, system prompt, tools and messages verbatim, an earlier request's messages being a prefix of a later one's. A request number past the last is not_found, and zero or an unknown export format is invalid_argument. In the app, choosing Single request shows the latest request with its usage, both instruction copies unflagged and the repeated date reminder flagged, stepping back to a request before the resume shows one copy and no flags, Latest returns to the last request, and Copy all copies the whole request as JSON.
    def test_task_raw_input_single_request_lists_resumed_instruction_copies_in_order(self):
        environment = self.install_claude_fixture("claude-fixture-instruction-resume")
        environment["CLAUDE_CONFIG_DIR"] = str(self.data_directory / "claude-config")
        task_id = self.create_task(title="Claude instruction resume", provider="claude")["id"]
        self.assert_success(self.call_cli(
            "conversation", "send", task_id, "--message", "Show instruction resume.", extra_environment=environment,
        )[0])

        def single(*options, expected_status=0):
            response, _ = self.call_cli(
                "task", "raw-input", task_id, "--scope", "request", "--limit", "1000", *options,
                extra_environment=environment, expected_status=expected_status,
            )
            return response

        def export(*options, expected_status=0):
            response, _ = self.call_cli(
                "task", "raw-input-export", task_id, *options, extra_environment=environment, expected_status=expected_status,
            )
            return response

        latest = self.assert_success(single())
        request = latest["request"]
        self.assertEqual(
            {key: request[key] for key in ("number", "count", "latest", "items", "repeatedItems", "exact")},
            {"number": 5, "count": 5, "latest": 5, "items": 16, "repeatedItems": 2, "exact": True},
            "The latest request is shown by default, with every item it sent.",
        )
        self.assertEqual(
            {key: request.get(key) for key in ("contextTokens", "inputTokens", "cacheReadTokens", "cacheWriteTokens", "outputTokens")},
            {"contextTokens": 9100, "inputTokens": 2, "cacheReadTokens": 9000, "cacheWriteTokens": 98, "outputTokens": 5},
            "Claude's own usage for that request, with its cache split.",
        )
        self.assertEqual(request["itemTokens"], 9100, "The items' sizes add up to the input Claude reported.")
        self.assertTrue(request["note"].startswith("Exact: rebuilt from Claude Code's request log"))
        self.assertIn("add up to the input the provider reported", request["tokenNote"])
        rows = latest["rows"]
        self.assertEqual([row["position"] for row in rows], list(range(16)), "Every item in the order it was sent, none merged.")
        self.assertEqual(
            [row["kind"] for row in rows],
            ["systemPrompt", "toolDefinition", "toolDefinition",
             "systemReminder", "systemReminder", "userText", "toolCall", "toolResult", "toolCall", "toolResult", "assistantText",
             "systemReminder", "systemReminder", "userText", "toolCall", "toolResult"],
        )
        first_copy, second_copy = rows[3], rows[11]
        self.assertTrue(first_copy["preview"].startswith("<system-reminder> Codebase and user instructions are shown below."))
        self.assertTrue(second_copy["preview"].startswith("<system-reminder> Instruction files were re-read"))
        self.assertNotEqual(first_copy["id"], second_copy["id"], "Two copies of AGENTS.md, not one item listed twice.")
        for row in (first_copy, second_copy):
            self.assertNotIn("repeated", row, "Two different texts are not flagged, however alike.")
        for copy, row in enumerate((rows[4], rows[12]), start=1):
            self.assertEqual(row["repeated"], {"first": 4, "copy": copy, "copies": 2})
        self.assertEqual([row["position"] for row in rows if row.get("repeated")], [4, 12])
        self.assertEqual(sum(row["tokens"] for row in rows), 9100)

        before = self.assert_success(single("--request", "3"))
        self.assertEqual((before["request"]["number"], before["request"]["items"], before["request"]["repeatedItems"]), (3, 10, 0))
        self.assertEqual(before["request"]["itemTokens"], before["request"]["contextTokens"])
        copies = [row for row in before["rows"] if "Contents of /fixture/repo/AGENTS.md" in row["preview"]]
        self.assertEqual([(row["position"], row["id"]) for row in copies], [(3, first_copy["id"])], "Before the resume only the first copy was sent.")
        self.assertEqual(
            [row["position"] for row in rows if "Contents of /fixture/repo/AGENTS.md" in row["preview"]], [3, 11],
            "After the resume both copies were sent, in order.",
        )
        self.assertFalse(any(row.get("repeated") for row in before["rows"]))
        for number, context in ((1, 4000), (2, 4300), (4, 9000)):
            summary = self.assert_success(single("--request", str(number), "--limit", "1"))["request"]
            self.assertEqual((summary["contextTokens"], summary["itemTokens"]), (context, context), f"Request {number} adds up.")
        found = self.assert_success(single("--query", "Also run the checks"))
        self.assertEqual([row["position"] for row in found["rows"]], [11], "A search keeps each row's position.")

        def full_text(item):
            return self.assert_success(self.call_cli(
                "task", "raw-input-text", task_id, "--item", str(item), "--length", "1000000", extra_environment=environment,
            )[0])["text"]

        body_export = self.assert_success(export("--format", "json"))
        self.assertEqual((body_export["request"], body_export["format"], body_export["exact"], body_export["items"]), (5, "json", True, 16))
        body = json.loads(body_export["text"])
        self.assertEqual((body["model"], body["max_tokens"]), ("claude-fixture", 1000), "The logged request parameters.")
        self.assertEqual(body["system"], [{"type": "text", "text": "You are the Claude Code fixture. " * 20, "cache_control": {"type": "ephemeral"}}])
        self.assertEqual([tool["name"] for tool in body["tools"]], ["Bash", "Read"])
        messages = body["messages"]
        self.assertEqual([message["role"] for message in messages], ["user", "assistant", "user", "assistant", "user", "assistant", "user", "assistant", "user"])
        self.assertEqual(messages[0]["content"][0]["text"], full_text(first_copy["id"]))
        self.assertEqual(messages[0]["content"][2], {"type": "text", "text": "Start the fixture work."})
        self.assertEqual(messages[5]["content"], [{"type": "text", "text": "First turn done."}])
        self.assertEqual(messages[6]["content"][0]["text"], full_text(second_copy["id"]))
        self.assertEqual(messages[6]["content"][1], messages[0]["content"][1], "The date reminder was sent twice word for word.")
        self.assertEqual(messages[7]["content"][0]["input"], {"command": "echo resumed"})
        self.assertEqual(messages[8]["content"][0]["tool_use_id"], "toolu_resume_bash2")
        earlier = json.loads(self.assert_success(export("--format", "json", "--request", "3"))["text"])
        self.assertEqual(len(earlier["messages"]), 5)
        self.assertEqual(earlier["messages"], messages[:5], "An earlier request is a prefix of the later one.")

        readable = self.assert_success(export("--request", "5"))
        self.assertEqual(readable["format"], "text")
        text = readable["text"]
        self.assertTrue(text.startswith("Request 5 of 5 · Claude main agent"))
        self.assertIn("Reported input: 9100 tokens (uncached 2 · cache read 9000 · cache write 98)", text)
        self.assertEqual(text.count("\n===== #"), 16, "One header per item sent.")
        for position, repeat in ((4, "duplicate 1 of 2"), (12, "duplicate 2 of 2")):
            row = rows[position]
            self.assertIn(f"\n===== #{position + 1} · {row['kind']} · {row['label']} · {row['tokens']} tokens · {repeat} =====\n", text)
        self.assertIn(full_text(second_copy["id"]), text, "Each item's full text, verbatim.")
        self.assertLess(text.index(full_text(first_copy["id"])), text.index(full_text(second_copy["id"])), "The copies stay in the order sent.")

        self.assert_failure(single("--request", "6", expected_status=3), "not_found")
        self.assert_failure(single("--request", "0", expected_status=2), "invalid_argument")
        self.assert_failure(export("--request", "9", expected_status=3), "not_found")
        self.assert_failure(export("--format", "yaml", expected_status=2), "invalid_argument")
    # case-contract: test_claude_auto_compaction_threshold_and_warm_idle | Claude task launches pass the configured token threshold to Claude Code, disabling automatic compaction removes the threshold environment value, and settings changes persist with invalid values rejected. For an In Progress Claude task whose fixture session has 180,000 context tokens and has been idle 51 minutes, a scheduler tick runs one warm-idle /compact before the cache expires, records its trigger and before/after sizes in token usage, and a second tick does not compact again. Maintenance API token usage contributes to the task total. The conversation labels the maintenance activity as automatic without adding an empty assistant turn. Crossing 200,000 tokens emits a threshold compaction boundary visible in the conversation and Token Stats. The settings window shows and saves the enabled toggle, threshold, idle wait and minimum context, and its invalid-threshold alert leaves the saved value unchanged; negative and malformed integers are rejected without changing saved settings. Idle checks skip Done and Backlog tasks, contexts below the minimum, pending user-input requests, an active Claude turn, and an outstanding background task; eligible In Progress, Waiting Response, and Review tasks compact.
    def test_claude_auto_compaction_threshold_and_warm_idle(self):
        settings = self.assert_success(self.call_cli("settings", "get")[0])["autoCompaction"]
        self.assertEqual(settings, {"enabled": True, "thresholdTokens": 200000, "idleMinutes": 50, "minimumTokens": 150000})
        environment = self.install_claude_fixture("claude-fixture-auto-compaction")
        environment["CLAUDE_CONFIG_DIR"] = str(self.data_directory / "claude-config")
        environment["PLAYHOUSE_E2E_CLAUDE_FIXTURE_REPORT_OUTCOME"] = "1"
        updated = self.assert_success(self.call_cli(
            "settings", "set-auto-compaction", "--threshold", "200000", "--idle-minutes", "50", "--minimum", "150000"
        )[0])
        self.assertEqual(updated["autoCompaction"]["thresholdTokens"], 200000)
        self.assert_failure(self.call_cli("settings", "set-auto-compaction", "--threshold", "-100000", expected_status=2)[0], "invalid_argument")
        self.assertEqual(self.assert_success(self.call_cli("settings", "get")[0])["autoCompaction"]["thresholdTokens"], 200000)
        task_id = self.assert_success(self.call_cli(
            "task", "create", "--title", "Warm compaction", "--prompt", "Fixture task description.",
            "--root", str(self.primary), "--provider", "claude"
        )[0])["id"]
        self.assert_success(self.call_cli("conversation", "send", task_id, "--message", "Hello.", extra_environment=environment)[0])
        fixture = Path(environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"])
        history_path = Path(str(fixture) + ".history")
        history = json.loads(history_path.read_text(encoding="utf-8"))["turns"]
        self.assertEqual(history[-1]["autoCompactWindow"], "200000", "Claude receives the configured token threshold.")

        self.assert_success(self.call_cli(
            "conversation", "send", task_id, "--message", "fill context to 180000 tokens 51 minutes ago",
            extra_environment=environment
        )[0])
        self.assert_success(self.call_cli(
            "task", "prompt", task_id, "--text", "Fixture task description.", "--status", "In Progress"
        )[0])
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["status"], "In Progress")
        before_usage = self.assert_success(self.call_cli("task", "token-usage", task_id)[0])["totalTokens"]
        self.assert_success(self.call_cli("schedule", "tick", extra_environment=environment)[0])
        summary = self.assert_success(self.call_cli("task", "token-usage", task_id)[0])
        self.assertEqual(summary["totalTokens"] - before_usage, 180060, "Compaction API usage is included in task totals.")
        events = summary["contextCompactions"]
        self.assertEqual(len(events), 1, "The idle tick compacts exactly once.")
        self.assertEqual(events[0]["trigger"], "warm-idle")
        self.assertEqual(events[0]["preTokens"], 180000)
        self.assertEqual(events[0]["postTokens"], 6000)
        self.assertTrue(events[0]["succeeded"])
        self.assertEqual(len(self.assert_success(self.call_cli("task", "token-usage", task_id)[0])["contextCompactions"]), 1)
        history = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=environment)[0])
        self.assertFalse(any(message.get("role") == "assistant" and not message.get("text", "").strip() for message in history["messages"]),
                         "A maintenance compaction must not leave an empty assistant turn.")

        small_task = self.assert_success(self.call_cli(
            "task", "create", "--title", "Small context", "--prompt", "Fixture task description.", "--root", str(self.primary), "--provider", "claude"
        )[0])["id"]
        self.assert_success(self.call_cli("conversation", "send", small_task, "--message", "Hello.", extra_environment=environment)[0])
        self.assert_success(self.call_cli("conversation", "send", small_task, "--message", "fill context to 100000 tokens 51 minutes ago", extra_environment=environment)[0])
        self.assert_success(self.call_cli("schedule", "tick", extra_environment=environment)[0])
        self.assertEqual(self.assert_success(self.call_cli("task", "token-usage", small_task)[0])["contextCompactions"], [], "A context below the minimum must be skipped.")

        backlog_task = self.assert_success(self.call_cli(
            "task", "create", "--title", "Backlog compaction", "--prompt", "Fixture task description.", "--root", str(self.primary), "--provider", "claude"
        )[0])["id"]
        self.assert_success(self.call_cli("conversation", "send", backlog_task, "--message", "Hello.", extra_environment=environment)[0])
        self.assert_success(self.call_cli("conversation", "send", backlog_task, "--message", "fill context to 180000 tokens 51 minutes ago", extra_environment=environment)[0])
        self.assert_success(self.call_cli("task", "prompt", backlog_task, "--text", "Saved in Backlog", "--status", "Backlog")[0])
        self.assert_success(self.call_cli("schedule", "tick", extra_environment=environment)[0])
        self.assertEqual(self.assert_success(self.call_cli("task", "get", backlog_task)[0])["status"], "Backlog")
        self.assertEqual(self.assert_success(self.call_cli("task", "token-usage", backlog_task)[0])["contextCompactions"], [], "Backlog tasks must never pay for idle maintenance.")

        done_task = self.assert_success(self.call_cli(
            "task", "create", "--title", "Done compaction", "--prompt", "Fixture task description.", "--root", str(self.custom), "--provider", "claude"
        )[0])["id"]
        self.assert_success(self.call_cli("conversation", "send", done_task, "--message", "Hello.", extra_environment=environment)[0])
        self.assert_success(self.call_cli("conversation", "send", done_task, "--message", "fill context to 180000 tokens 51 minutes ago", extra_environment=environment)[0])
        self.assert_success(self.call_cli("task", "move", done_task, "Review")[0])
        self.assert_success(self.call_cli("task", "move", done_task, "Done")[0])
        self.assert_success(self.call_cli("schedule", "tick", extra_environment=environment)[0])
        self.assertEqual(self.assert_success(self.call_cli("task", "get", done_task)[0])["status"], "Done")
        self.assertEqual(self.assert_success(self.call_cli("task", "token-usage", done_task)[0])["contextCompactions"], [], "Done tasks must never pay for idle maintenance.")

        pending_task = self.assert_success(self.call_cli(
            "task", "create", "--title", "Pending question compaction", "--prompt", "Fixture task description.", "--root", str(self.primary), "--provider", "claude"
        )[0])["id"]
        self.assert_success(self.call_cli("conversation", "send", pending_task, "--message", "finish while a structured question remains pending; fill context to 180000 tokens 51 minutes ago", extra_environment=environment)[0])
        pending_history = self.assert_success(self.call_cli("conversation", "history", pending_task, extra_environment=environment)[0])
        self.assertIsNotNone(pending_history.get("pendingUserInputRequest"), "The fixture must leave a real user-input request pending before the idle tick.")
        self.assert_success(self.call_cli("schedule", "tick", extra_environment=environment)[0])
        pending_after_tick = self.assert_success(self.call_cli("conversation", "history", pending_task, extra_environment=environment)[0])
        self.assertIsNotNone(pending_after_tick.get("pendingUserInputRequest"), "The idle tick must preserve the pending user-input request.")
        self.assertEqual(self.assert_success(self.call_cli("task", "token-usage", pending_task)[0])["contextCompactions"], [], "A pending user-input request must block idle compaction.")

        waiting_task = self.assert_success(self.call_cli(
            "task", "create", "--title", "Waiting response compaction", "--prompt", "Fixture task description.", "--root", str(self.primary), "--provider", "claude"
        )[0])["id"]
        self.assert_success(self.call_cli("conversation", "send", waiting_task, "--message", "Hello.", extra_environment=environment)[0])
        self.assert_success(self.call_cli("conversation", "send", waiting_task, "--message", "fill context to 180000 tokens 51 minutes ago", extra_environment=environment)[0])
        self.assertEqual(self.assert_success(self.call_cli("task", "get", waiting_task)[0])["status"], "Waiting Response")
        self.assert_success(self.call_cli("schedule", "tick", extra_environment=environment)[0])
        self.assertEqual(self.assert_success(self.call_cli("task", "token-usage", waiting_task)[0])["contextCompactions"][0]["trigger"], "warm-idle")

        review_task = self.assert_success(self.call_cli(
            "task", "create", "--title", "Review compaction", "--prompt", "Fixture task description.", "--root", str(self.custom), "--provider", "claude"
        )[0])["id"]
        self.assert_success(self.call_cli("conversation", "send", review_task, "--message", "Hello.", extra_environment=environment)[0])
        self.assert_success(self.call_cli("conversation", "send", review_task, "--message", "fill context to 180000 tokens 51 minutes ago", extra_environment=environment)[0])
        self.assert_success(self.call_cli("task", "move", review_task, "Review")[0])
        self.assertEqual(self.assert_success(self.call_cli("task", "get", review_task)[0])["status"], "Review")
        self.assert_success(self.call_cli("schedule", "tick", extra_environment=environment)[0])
        self.assertEqual(self.assert_success(self.call_cli("task", "token-usage", review_task)[0])["contextCompactions"][0]["trigger"], "warm-idle")

        busy_task = self.assert_success(self.call_cli(
            "task", "create", "--title", "Busy compaction", "--prompt", "Fixture task description.", "--root", str(self.primary), "--provider", "claude"
        )[0])["id"]
        self.assert_success(self.call_cli("conversation", "send", busy_task, "--message", "Hello.", extra_environment=environment)[0])
        self.assert_success(self.call_cli("conversation", "send", busy_task, "--message", "fill context to 180000 tokens 51 minutes ago", extra_environment=environment)[0])
        ready = Path(str(environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"]) + ".concurrent-turn-ready")
        release = Path(str(environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"]) + ".concurrent-turn-release")
        ready.unlink(missing_ok=True)
        release.unlink(missing_ok=True)
        send_result = {}
        sender = threading.Thread(target=lambda: send_result.setdefault("response", self.call_cli(
            "conversation", "send", busy_task, "--message", "hold-claude-turn-for-concurrency", timeout=45,
            extra_environment=environment,
        )), daemon=True)
        sender.start()
        self.wait_for(ready.exists, "The Claude turn should remain active while the scheduler runs.")
        self.assert_success(self.call_cli("schedule", "tick", extra_environment=environment)[0])
        self.assertEqual(self.assert_success(self.call_cli("task", "token-usage", busy_task)[0])["contextCompactions"], [],
                         "An active Claude turn must block idle compaction.")
        release.touch()
        sender.join(timeout=45)
        self.assertFalse(sender.is_alive(), "The held provider turn should settle after release.")
        self.assert_success(send_result["response"][0])

        background_task = self.assert_success(self.call_cli(
            "task", "create", "--title", "Background task compaction", "--prompt", "Fixture task description.", "--root", str(self.primary), "--provider", "claude"
        )[0])["id"]
        self.assert_success(self.call_cli("conversation", "send", background_task, "--message", "Hello.", extra_environment=environment)[0])
        background_ready = Path(str(environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"]) + ".compaction-background-ready")
        background_release = Path(str(environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"]) + ".compaction-background-release")
        background_ready.unlink(missing_ok=True)
        background_release.unlink(missing_ok=True)
        background_result = {}
        background_sender = threading.Thread(target=lambda: background_result.setdefault("response", self.call_cli(
            "conversation", "send", background_task, "--message", "hold background task for compaction; fill context to 180000 tokens 51 minutes ago",
            timeout=45, extra_environment=environment,
        )), daemon=True)
        background_sender.start()
        self.wait_for(background_ready.exists, "The provider should report a running background task before the scheduler tick.")
        self.assert_success(self.call_cli("schedule", "tick", extra_environment=environment)[0])
        self.assertEqual(self.assert_success(self.call_cli("task", "token-usage", background_task)[0])["contextCompactions"], [],
                         "An outstanding provider background task must block idle compaction.")
        background_release.touch()
        background_sender.join(timeout=45)
        self.assertFalse(background_sender.is_alive(), "The background task turn should settle after release.")
        self.assert_success(background_result["response"][0])

        threshold_task = self.assert_success(self.call_cli(
            "task", "create", "--title", "Threshold compaction", "--prompt", "Fixture task description.",
            "--root", str(self.primary), "--provider", "claude"
        )[0])["id"]
        self.assert_success(self.call_cli("conversation", "send", threshold_task, "--message", "Hello.", extra_environment=environment)[0])
        self.assert_success(self.call_cli("conversation", "send", threshold_task, "--message", "fill context to 210000 tokens", extra_environment=environment)[0])
        threshold_events = self.assert_success(self.call_cli("task", "token-usage", threshold_task)[0])["contextCompactions"]
        self.assertEqual(threshold_events[-1]["trigger"], "threshold", "Crossing the configured window emits an automatic compaction boundary.")
        self.assertEqual((threshold_events[-1]["preTokens"], threshold_events[-1]["postTokens"]), (210000, 6000))

        self.assert_success(self.call_cli("settings", "set-auto-compaction", "--enabled", "false")[0])
        disabled = self.assert_success(self.call_cli("settings", "get")[0])["autoCompaction"]
        self.assertFalse(disabled["enabled"])
        self.assert_failure(self.call_cli("settings", "set-auto-compaction", "--idle-minutes", "60", expected_status=2)[0], "invalid_argument")
        self.assertEqual(self.assert_success(self.call_cli("settings", "get")[0])["autoCompaction"], disabled)
        disabled_task = self.assert_success(self.call_cli(
            "task", "create", "--title", "Compaction disabled", "--prompt", "Fixture task description.",
            "--root", str(self.primary), "--provider", "claude"
        )[0])["id"]
        self.assert_success(self.call_cli("conversation", "send", disabled_task, "--message", "Hello.", extra_environment=environment)[0])
        history = json.loads(history_path.read_text(encoding="utf-8"))["turns"]
        self.assertIsNone(history[-1]["autoCompactWindow"], "Disabled settings leave Claude's built-in auto-compaction alone.")
    # case-contract: test_claude_cold_resume_and_model_switch_compaction | A Claude session with more than the minimum context is compacted before the next real prompt after its cache has been idle for over 60 minutes, and again before a model switch. The cold-resume and model-switch triggers are persisted with context sizes, each `/compact` fixture turn precedes the real prompt, the visible maintenance rows precede their corresponding prompts, and a model switch runs `/compact` with the old model before the requested model starts. When the cache is expired and automatic compaction is disabled, the first resumed response with near-zero cache reads and a large cache write records one cache miss, visible in Token Stats. If Claude reports a compaction failure, the failed maintenance row is recorded, the event is marked unsuccessful, and the user's prompt still runs and appears in history. Failed attempts are labelled as failures in the conversation and Token Stats. Stopping during compaction prevents the submitted work from starting.
    def test_claude_cold_resume_and_model_switch_compaction(self):
        environment = self.install_claude_fixture("claude-fixture-resume-compaction")
        environment["CLAUDE_CONFIG_DIR"] = str(self.data_directory / "claude-config")
        environment["PLAYHOUSE_E2E_CLAUDE_FIXTURE_REPORT_OUTCOME"] = "1"
        fixture = Path(environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"])
        history_path = Path(str(fixture) + ".history")

        cold_task = self.assert_success(self.call_cli(
            "task", "create", "--title", "Cold resume", "--prompt", "Fixture task description.",
            "--root", str(self.primary), "--provider", "claude"
        )[0])["id"]
        self.assert_success(self.call_cli("conversation", "send", cold_task, "--message", "Hello.", extra_environment=environment)[0])
        self.assert_success(self.call_cli("conversation", "send", cold_task, "--message", "fill context to 180000 tokens 61 minutes ago", extra_environment=environment)[0])
        self.assert_success(self.call_cli("conversation", "send", cold_task, "--message", "Resume after cache expiry.", extra_environment=environment)[0])
        cold_events = self.assert_success(self.call_cli("task", "token-usage", cold_task)[0])["contextCompactions"]
        self.assertEqual(cold_events[-1]["trigger"], "cold-resume")
        self.assertTrue(cold_events[-1]["succeeded"])
        history = json.loads(history_path.read_text(encoding="utf-8"))["turns"]
        cold_prompt_index = next(i for i, turn in enumerate(history) if turn.get("userText") == "Resume after cache expiry.")
        self.assertEqual(history[cold_prompt_index - 1].get("userText"), "/compact", "Cold compaction must run before the resumed prompt.")

        switch_task = self.assert_success(self.call_cli(
            "task", "create", "--title", "Model switch", "--prompt", "Fixture task description.",
            "--root", str(self.primary), "--provider", "claude"
        )[0])["id"]
        self.assert_success(self.call_cli("conversation", "send", switch_task, "--message", "Hello.", "--model", "claude-haiku-4-5", extra_environment=environment)[0])
        self.assert_success(self.call_cli("conversation", "send", switch_task, "--message", "fill context to 180000 tokens", "--model", "claude-haiku-4-5", extra_environment=environment)[0])
        self.assert_success(self.call_cli("conversation", "send", switch_task, "--message", "Switch models now.", "--model", "claude-sonnet-4-6", extra_environment=environment)[0])
        switch_events = self.assert_success(self.call_cli("task", "token-usage", switch_task)[0])["contextCompactions"]
        self.assertEqual(switch_events[-1]["trigger"], "model-switch")
        history = json.loads(history_path.read_text(encoding="utf-8"))["turns"]
        prompt_index = next(i for i, turn in enumerate(history) if turn.get("userText") == "Switch models now.")
        compact_turn = history[prompt_index - 1]
        self.assertEqual(compact_turn.get("userText"), "/compact")
        self.assertEqual(compact_turn["arguments"][compact_turn["arguments"].index("--model") + 1], "claude-haiku-4-5")
        self.assertEqual(history[prompt_index]["arguments"][history[prompt_index]["arguments"].index("--model") + 1], "claude-sonnet-4-6")

        cache_environment = dict(environment, PLAYHOUSE_E2E_CLAUDE_FIXTURE_CACHE_MISS="1")
        self.assert_success(self.call_cli("settings", "set-auto-compaction", "--enabled", "false")[0])
        cache_task = self.assert_success(self.call_cli(
            "task", "create", "--title", "Resume cache miss", "--prompt", "Fixture task description.",
            "--root", str(self.primary), "--provider", "claude"
        )[0])["id"]
        self.assert_success(self.call_cli("conversation", "send", cache_task, "--message", "Hello.", extra_environment=environment)[0])
        self.assert_success(self.call_cli("conversation", "send", cache_task, "--message", "fill context to 180000 tokens 61 minutes ago", extra_environment=environment)[0])
        self.assert_success(self.call_cli("conversation", "send", cache_task, "--message", "Resume with a cold cache.", extra_environment=cache_environment)[0])
        misses = self.assert_success(self.call_cli("task", "token-usage", cache_task)[0])["promptCacheMisses"]
        self.assertEqual(len(misses), 1)
        self.assertEqual((misses[0]["cacheReadTokens"], misses[0]["cacheWriteTokens"]), (0, 250000))

        self.assert_success(self.call_cli("settings", "set-auto-compaction", "--enabled", "true")[0])
        failure_marker = Path(str(fixture) + ".compact-fail")
        failure_marker.touch()
        failure_task = self.assert_success(self.call_cli(
            "task", "create", "--title", "Failed Claude compaction", "--prompt", "Fixture task description.",
            "--root", str(self.primary), "--provider", "claude"
        )[0])["id"]
        self.assert_success(self.call_cli("conversation", "send", failure_task, "--message", "Hello.", extra_environment=environment)[0])
        self.assert_success(self.call_cli("conversation", "send", failure_task, "--message", "fill context to 180000 tokens 61 minutes ago", extra_environment=environment)[0])
        self.assert_success(self.call_cli("conversation", "send", failure_task, "--message", "Continue after failed compaction.", extra_environment=environment)[0])
        failure_events = self.assert_success(self.call_cli("task", "token-usage", failure_task)[0])["contextCompactions"]
        self.assertEqual(failure_events[-1]["trigger"], "cold-resume")
        self.assertFalse(failure_events[-1]["succeeded"])
        failure_history = self.assert_success(self.call_cli("conversation", "history", failure_task, extra_environment=environment)[0])
        failure_rows = [activity for activity in failure_history["activities"] if activity.get("isContextCompaction")]
        self.assertEqual(len(failure_rows), 1)
        self.assertEqual(failure_rows[0]["status"], "failed")
        self.assertEqual(failure_rows[0]["title"], "Automatic context compaction failed")
        self.assertIn("Continue after failed compaction.", [message["text"] for message in failure_history["messages"]])
        failure_marker.unlink()


        # Stop while maintenance is running must also stop the submitted prompt.
        self.assert_success(self.call_cli("conversation", "send", failure_task, "--message", "fill context to 180000 tokens 61 minutes ago", extra_environment=environment)[0])
        hold = Path(str(fixture) + ".compact-hold")
        ready = Path(str(fixture) + ".compact-ready")
        hold.touch()
        results = []
        sender = threading.Thread(target=lambda: results.append(self.call_cli(
            "conversation", "send", failure_task, "--message", "Must not run after Stop.",
            expected_status=1, timeout=45, extra_environment=environment,
        )), daemon=True)
        sender.start()
        try:
            self.wait_for(ready.exists, "Compaction should be active before Stop.")
            self.assert_success(self.call_cli("conversation", "stop", failure_task, extra_environment=environment)[0])
            sender.join(timeout=30)
            self.assertFalse(sender.is_alive())
            provider_history = json.loads(history_path.read_text(encoding="utf-8"))["turns"]
            self.assertFalse(any(turn.get("userText") == "Must not run after Stop." for turn in provider_history))
            self.assertEqual(self.assert_success(self.call_cli("task", "get", failure_task)[0])["status"], "Waiting Response")
        finally:
            hold.unlink(missing_ok=True)
            ready.unlink(missing_ok=True)
    # case-contract: test_claude_compaction_shows_one_row | A Claude compaction is one conversation row. A threshold compaction whose start Claude Code reports twice under different ids before its boundary leaves exactly one completed compaction row in the latest turn's history, with no row still in progress. A compaction that starts before the daemon is killed and ends after it, so its boundary reaches a daemon that never saw the row reported for its start, shows one in-progress row while the turn runs, before and after the restart, then one completed row with its context sizes as soon as the boundary arrives while the turn is still running, and records one compaction event. A long turn that compacts twice shows each compaction where it happened: the first after the text and tool call written before it and before the summary message Claude Code continues from, the second between the messages written after the first and its own summary, never stacked after the turn's last message. Compaction rows stored without the message they follow are placed the same way, by when each compaction finished.
    def test_claude_compaction_shows_one_row(self):
        def compaction_rows(task_id, environment):
            history = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=environment)[0])
            return [activity for activity in history["activities"] if activity.get("isContextCompaction")]

        environment = self.install_claude_fixture("claude-fixture-compaction-rows")
        environment["CLAUDE_CONFIG_DIR"] = str(self.data_directory / "claude-config")
        threshold_task = self.assert_success(self.call_cli(
            "task", "create", "--title", "Repeated compaction start", "--prompt", "Fixture task description.",
            "--root", str(self.primary), "--provider", "claude"
        )[0])["id"]
        self.assert_success(self.call_cli("conversation", "send", threshold_task, "--message", "Hello.", extra_environment=environment)[0])
        self.assert_success(self.call_cli(
            "conversation", "send", threshold_task, "--message", "fill context to 210000 tokens", extra_environment=environment
        )[0])
        rows = compaction_rows(threshold_task, environment)
        self.assertEqual(len(rows), 1, f"The latest turn's compaction is one row, not one per reported start or copy: {rows}")
        self.assertEqual(rows[0]["status"], "completed")
        self.assertEqual((rows[0]["compaction"]["preTokens"], rows[0]["compaction"]["postTokens"]), (210000, 6000))
        self.assertEqual(len(self.assert_success(self.call_cli("task", "token-usage", threshold_task)[0])["contextCompactions"]), 1)

        # A long turn that compacts twice keeps each row where it happened, not stacked after its last message.
        def assert_compactions_in_turn_order(task_id):
            history = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=environment)[0])
            turn_id = next(message["turnID"] for message in history["messages"] if message["text"] == "compact twice mid turn")
            timeline = sorted(
                [(message["timelineOrder"], message["text"]) for message in history["messages"] if message.get("turnID") == turn_id]
                + [(row["timelineOrder"], f"compaction {row['compaction']['preTokens']}") for row in history["activities"]
                   if row.get("isContextCompaction") and row.get("turnID") == turn_id]
            )
            entries = [entry for _, entry in timeline]
            self.assertEqual(len(entries), len(set(order for order, _ in timeline)), f"Every row has its own place: {timeline}")
            self.assertEqual(entries[:3], [
                "compact twice mid turn", "Reading the build log before the first compaction.", "compaction 170000",
            ], f"The first compaction follows the text written before it: {timeline}")
            self.assertIn("Continued after the first compaction.", entries[3])
            self.assertEqual(entries[4:6], ["Checking the log again between compactions.", "compaction 168000"],
                             f"The second compaction sits between the messages it came between: {timeline}")
            self.assertIn("Continued after the second compaction.", entries[6])
            self.assertGreater(len(entries), 7, f"The turn's answer follows its last compaction: {timeline}")
            self.assertEqual([row["status"] for row in compaction_rows(task_id, environment)], ["completed", "completed"])

        long_tasks = []
        for title in ("Compaction mid turn", "Stored compaction mid turn"):
            long_tasks.append(self.assert_success(self.call_cli(
                "task", "create", "--title", title, "--prompt", "Fixture task description.",
                "--root", str(self.primary), "--provider", "claude"
            )[0])["id"])
            self.assert_success(self.call_cli(
                "conversation", "send", long_tasks[-1], "--message", "compact twice mid turn", extra_environment=environment
            )[0])
        assert_compactions_in_turn_order(long_tasks[0])
        # Rows stored before compactions recorded the message they follow are placed by when each compaction finished.
        with sqlite3.connect(self.conversation_database(), timeout=30) as connection:
            stored = connection.execute(
                "SELECT turn_id, id, payload FROM conversation_activities WHERE task_id = ?", (long_tasks[1].upper(),)
            ).fetchall()
            stripped = 0
            for turn_id, row_id, payload in stored:
                activity = json.loads(payload)
                if activity.get("isContextCompaction"):
                    self.assertIsNotNone(activity.pop("afterMessageID", None), "A new compaction row records the message it follows.")
                    connection.execute(
                        "UPDATE conversation_activities SET payload = ? WHERE task_id = ? AND turn_id = ? AND id = ?",
                        (json.dumps(activity), long_tasks[1].upper(), turn_id, row_id),
                    )
                    stripped += 1
        self.assertEqual(stripped, 2)
        assert_compactions_in_turn_order(long_tasks[1])

        executable = self.install_provider_fixture("claude", "claude-fixture-reattach-compaction")
        restart_environment = self.restart_service_environment("claude", executable)
        task = self.create_task("Compaction across a restart", provider="claude")
        Path(str(executable) + ".reattach-compact").touch()
        ready = Path(str(executable) + ".reattach-ready")
        sender = threading.Thread(target=lambda: self.call_cli(
            "conversation", "send", task["id"], "--message", "Compact across a restart.",
            expected_status=69, timeout=60, extra_environment=restart_environment), daemon=True)
        sender.start()
        self.wait_for(ready.is_file, "The turn should be compacting before the daemon dies.")
        self.wait_for(lambda: [row["status"] for row in compaction_rows(task["id"], restart_environment)] == ["inProgress"],
                      "The compaction start is recorded once before the restart.")
        self.kill_daemon(restart_environment)
        sender.join(timeout=20)
        # The watch starts the next daemon, which follows the still compacting turn.
        watcher = self.start_cli("conversation", "watch", task["id"], extra_environment=restart_environment)
        self.wait_for(lambda: self.task_for(task["id"], restart_environment)["status"] == "In Progress",
                      "The next daemon follows the compacting turn.")
        self.assertEqual([row["status"] for row in compaction_rows(task["id"], restart_environment)], ["inProgress"],
                         "While the turn runs, its compaction is one in-progress row.")
        # Only the next daemon reads the boundary; the turn keeps running after it.
        Path(str(executable) + ".reattach-compact-end").touch()
        self.wait_for(lambda: [row["status"] for row in compaction_rows(task["id"], restart_environment)] == ["completed"],
                      "The boundary ends the compaction's one row while the turn still runs, leaving none spinning.")
        self.assertEqual(self.task_for(task["id"], restart_environment)["status"], "In Progress")
        Path(str(executable) + ".reattach-release").touch()
        self.assertTrue(self.assert_success(self.finish_cli(watcher, "conversation watch", timeout=60)[0])["watched"])
        rows = compaction_rows(task["id"], restart_environment)
        self.assertEqual([row["status"] for row in rows], ["completed"],
                         f"The finished turn keeps the compaction's one completed row: {rows}")
        self.assertEqual((rows[0]["compaction"]["preTokens"], rows[0]["compaction"]["postTokens"]), (190000, 6000))
        events = self.assert_success(self.call_cli("task", "token-usage", task["id"], extra_environment=restart_environment)[0])["contextCompactions"]
        self.assertEqual(len(events), 1, "The compaction is recorded once.")
    # case-contract: test_settings_token_usage_color_max_round_trip | The token usage color maximum defaults to twenty million, round-trips through the CLI/XPC settings commands, and rejects a non-positive value as invalid_argument without changing the stored setting. The settings window shows the stored maximum and saves an edited one, and a task card's token counter re-colors when the maximum changes so the same usage reads hotter against a smaller ceiling.
    def test_settings_token_usage_color_max_round_trip(self):
        settings = self.assert_success(self.call_cli("settings", "get")[0])
        self.assertEqual(settings["tokenUsageColorMax"], 20_000_000, "The counter's scale tops out at twenty million tokens by default.")

        updated = self.assert_success(self.call_cli("settings", "set-token-usage-color-max", "2400")[0])
        self.assertEqual(updated["tokenUsageColorMax"], 2400)
        self.assertEqual(
            self.assert_success(self.call_cli("settings", "get")[0])["tokenUsageColorMax"], 2400,
            "The edited maximum should survive a fresh read.",
        )

        response, _ = self.call_cli("settings", "set-token-usage-color-max", "0", expected_status=2)
        self.assert_failure(response, "invalid_argument")
        self.assertEqual(
            self.assert_success(self.call_cli("settings", "get")[0])["tokenUsageColorMax"], 2400,
            "A rejected maximum should leave the stored one alone.",
        )
    # case-contract: test_task_cpu_usage_reports_claude_process_tree_load | A newly created Claude task reports cpu-usage as not running before any turn starts. While a real Claude Code fixture turn burns CPU in a real child process, two successive `task cpu-usage` reads establish a baseline and then a plausible non-zero percentage for the task's process tree, the task card's CPU bar reads cool green against the default multi-core ceiling and hot red once the ceiling is lowered to match that load, and the reading returns to not-running once the turn completes.
    def test_task_cpu_usage_reports_claude_process_tree_load(self):
        environment = self.install_claude_fixture("claude-fixture-cpu-usage")
        environment["PLAYHOUSE_E2E_CLAUDE_FIXTURE_BURN_CPU"] = "1"
        environment["PLAYHOUSE_E2E_CLAUDE_FIXTURE_BURN_CPU_SECONDS"] = "6"
        task_id = self.assert_success(self.call_cli(
            "task", "create", "--title", "Claude CPU usage", "--prompt", "Fixture task description.", "--root", self.primary, "--provider", "claude"
        )[0])["id"]

        idle = self.assert_success(self.call_cli("task", "cpu-usage", task_id)[0])
        self.assertIsNone(idle["cpuPercent"], "A task with no turn yet has nothing to sample.")
        self.assertEqual(idle["reason"], "not_running")

        send_failures = []

        def send_turn():
            try:
                self.call_cli(
                    "conversation", "send", task_id, "--message", "Tell me a story.",
                    timeout=30, extra_environment=environment,
                )
            except Exception as error:
                send_failures.append(error)

        sender = threading.Thread(target=send_turn, daemon=True)
        sender.start()
        deadline = time.monotonic() + 10
        session_id = None
        while time.monotonic() < deadline:
            active = self.assert_success(self.call_cli("task", "get", task_id)[0])
            session_id = active.get("claudeSessionID")
            if session_id:
                break
            time.sleep(0.1)
        self.assertTrue(session_id, "The Claude fixture turn should start a session while it burns CPU.")

        # The Claude process doesn't necessarily become sample-able in the same
        # instant its session ID is persisted, so it can take a read or two
        # before a read establishes a baseline (reported as not-running, same
        # as a genuinely idle task, since there is nothing yet to diff
        # against) that the next read can turn into a measured percentage;
        # poll instead of assuming a fixed pair of reads lines up with that.
        established_baseline = False
        second = None
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            reading = self.assert_success(self.call_cli("task", "cpu-usage", task_id)[0])
            if reading["cpuPercent"] is not None:
                second = reading
                break
            established_baseline = True
            time.sleep(0.3)
        self.assertTrue(established_baseline, "At least one earlier read should have sampled the process tree first.")
        self.assertIsNotNone(second, "A busy process tree should eventually report a measured percentage.")
        self.assertGreater(second["cpuPercent"], 0, "A CPU-burning child process should register non-zero usage.")

        sender.join(timeout=20)
        self.assertFalse(sender.is_alive(), "The Claude fixture turn should complete.")
        self.assertFalse(send_failures, f"The Claude turn should succeed: {send_failures}")

        finished = self.assert_success(self.call_cli("task", "cpu-usage", task_id)[0])
        self.assertIsNone(finished["cpuPercent"], "A finished turn is no longer running.")
        self.assertEqual(finished["reason"], "not_running")
