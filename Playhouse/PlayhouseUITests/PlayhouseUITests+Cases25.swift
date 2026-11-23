import AppKit
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import Network
import XCTest
import SQLite3
import Vision

extension PlayhouseUITests {
    // case-contract: test_task_token_usage_records_claude_turn_breakdown | A task starts with no recorded tokens, and its Token Stats modal says so plainly with no totals shown. Running a real Claude Code fixture turn parses that turn's reported usage into Playhouse's four buckets, adds them to the task's running totals, and records a per-turn row naming the provider and the tools, skills and MCP servers that ran in it. A second turn adds to the totals and appends its own row rather than replacing the first, and the per-tool rollup counts the turns each tool took part in. Call-level accounting spans the main agent and its subagents: an empty task's `callUsage` reports itself unavailable, and after a turn it reports exact model-call, total-sent, output and final-transcript figures read from the session files (counting each message ID once, ignoring repeated and zero-usage lines, and including the subagent's own file), which a second turn adds to rather than replaces. A Claude turn whose session files cannot be read still counts its calls live from the stream. The task card replaces its old dot with a compact live counter of total sent, which is hidden while that total is still zero, whose tooltip names the sent total, call count and final transcript size, and both the Token Stats context-menu item and a click on the counter itself, a button that highlights on hover, open a modal labelling 'Final transcript size' and 'Total sent (incl. subagents)' beside the call and output counts, the per-tool rollup and the per-turn breakdown. Excluding cache reads (uncached input + cache write + output, subagent included) is 855 per turn, doubling after a second turn, and also reaches the live stream when the session files cannot be read; an empty task reports it unavailable. A task saved before the cache split existed (call usage without the split, plus turn-level buckets) still loads, reports its call counts and total sent, omits the per-call excluding-cache figures, and falls back to the turn buckets minus cache reads (170 for 100 input, 50 output, 400 cache read and 20 cache write); its modal hides the Excluding cache reads headline. The modal also labels 'Excluding cache reads (incl. subagents)' with its main-agent and subagent split.
    func test_task_token_usage_records_claude_turn_breakdown() throws {
        let environment = try installClaudeFixture(named: "claude-fixture-ui-token-usage")
        launchApp(defaultParent: fixture.parent.path)
        let taskID = try XCTUnwrap((try runCLI([
            "task", "create", "--title", "Token usage task", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
        ])["result"] as? [String: Any])?["id"] as? String)
        let card = app.buttons["Token usage task"]
        XCTAssertTrue(card.waitToExist(timeout: 10))
        let counter = element("task-token-usage-counter-\(taskID)")
        XCTAssertFalse(counter.exists, "A task with no recorded tokens should hide its card counter.")
        attachScreenshot(named: "Task card hides its counter before any tokens are recorded")
        let emptySummary = try XCTUnwrap(try runCLI(["task", "token-usage", taskID])["result"] as? [String: Any])
        XCTAssertEqual((emptySummary["callUsage"] as? [String: Any])?["available"] as? Bool, false)
        XCTAssertNil((emptySummary["callUsage"] as? [String: Any])?["totalTokensExcludingCacheReads"])
        XCTAssertEqual(emptySummary["tokensExcludingCacheReads"] as? Int, 0)

        card.rightClick()
        element("token-stats-task-menu-item").click()
        let emptyState = element("token-stats-empty")
        XCTAssertTrue(emptyState.waitToExist(timeout: 10), "Token Stats should say plainly that nothing has been recorded yet.")
        XCTAssertFalse(element("token-stats-total").exists, "An empty task should show no totals.")
        attachScreenshot(named: "Token Stats modal before any turns have run")
        element("close-token-stats-button").click()
        XCTAssertTrue(waitUntil({ !emptyState.exists }, timeout: 5))

        // "Tell me a story." is one of the fixture's few branches that reports a
        // task outcome, ending in exactly one Claude result message; an
        // outcome-less prompt (like "inspect") makes Playhouse send several
        // internal nudge turns in the same session, each contributing its own
        // result and inflating this fixture's flat per-result usage.
        _ = try runCLI(
            ["conversation", "send", taskID, "--message", "Tell me a story."],
            extraEnvironment: environment
        )
        _ = try runCLI(
            ["conversation", "send", taskID, "--message", "Tell me a story."],
            extraEnvironment: environment
        )
        // Two fixture turns, each with two main-agent calls (sending 550 and 650)
        // and two subagent calls (300 and 340): 8 calls, 3,680 sent, final context 650.
        XCTAssertTrue(
            waitUntil({ counter.label == "3.7K tokens sent · 8 calls · 650 final transcript" }, timeout: 15),
            "The counter should report everything sent, subagents included, across both turns."
        )
        attachScreenshot(named: "Task card shows its live token counter beside the time")

        // The counter is a button: its hit area is padded well past the 10pt text,
        // hovering highlights it, and clicking its edge (not the text) opens Token Stats.
        XCTAssertGreaterThanOrEqual(counter.frame.height, 20, "The counter's hit area should be taller than its small text.")
        assertHoverEmphasis(for: counter)
        attachScreenshot(named: "Token counter highlights on hover")
        counter.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.5)).click()

        // The sheet's summary loads asynchronously (`.task`), so its text commits
        // a moment after the element appears; assertText waits on the content.
        // A SwiftUI Text reports its string as the accessibility value, not label.
        let total = element("token-stats-total")
        assertText("token-stats-total", equals: "3,200")
        assertText("token-stats-final-transcript", equals: "650")
        assertText("token-stats-total-sent", equals: "3,680")
        // Per turn, uncached input + cache write + output: 360 main + 495 subagent.
        assertText("token-stats-excluding-cache", equals: "1,710")
        assertText("token-stats-excluding-cache-split", equals: "Excluding cache reads: 720 main agent · 990 subagents")
        assertText("token-stats-total-calls", equals: "8 model calls · 4 main, 4 across 2 subagents")
        assertText("token-stats-output", equals: "Output 170")
        XCTAssertTrue(element("token-stats-tool-Bash").exists, "The rollup should name the tool the turns ran.")
        let turnRows = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "token-stats-turn-"
        ))
        XCTAssertEqual(turnRows.count, 2, "Each recorded turn should have its own row.")
        attachScreenshot(named: "Token Stats modal breaks usage down by tool and by turn")
        element("close-token-stats-button").click()
        XCTAssertTrue(waitUntil({ !total.exists }, timeout: 5), "Token Stats should close again.")

        let summary = try XCTUnwrap(try runCLI(["task", "token-usage", taskID])["result"] as? [String: Any])
        XCTAssertEqual(summary["totalTokens"] as? Int, 3_200)
        XCTAssertEqual((summary["turns"] as? [[String: Any]])?.count, 2)
        let calls = try XCTUnwrap(summary["callUsage"] as? [String: Any])
        XCTAssertEqual(calls["totalCalls"] as? Int, 8)
        XCTAssertEqual(calls["totalSentTokens"] as? Int, 3_680)
        XCTAssertEqual(calls["totalTokensExcludingCacheReads"] as? Int, 1_710)
        XCTAssertEqual(summary["tokensExcludingCacheReads"] as? Int, 1_710)

        // A task saved before the cache split existed: call usage without the split plus turn buckets.
        let legacyTitle = "Legacy token usage task"
        let legacyID = try XCTUnwrap((try runCLI([
            "task", "create", "--title", legacyTitle, "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
        ])["result"] as? [String: Any])?["id"] as? String)
        let legacySnapshots = #"{"claude:legacy":{"provider":"claude","updatedAt":800000000,"main":{"calls":2,"sentTokens":1200,"outputTokens":60,"lastContextTokens":650},"subagents":{"old":{"calls":1,"sentTokens":300,"outputTokens":10,"lastContextTokens":300}}}}"#
        // The app holds its container open, so close it before seeding the store.
        app.terminate()
        XCTAssertTrue(waitUntil({ app.state == .notRunning }, timeout: 10), "The app must close its SwiftData container before seeding the pre-split task.")
        let seed = Process()
        seed.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        seed.arguments = [
            dataDirectory.appendingPathComponent("Playhouse-v2.store").path,
            "UPDATE ZBOARDTASK SET ZCALLUSAGESNAPSHOTSDATA = CAST('\(legacySnapshots)' AS BLOB), ZTOTALINPUTTOKENS = 100, ZTOTALOUTPUTTOKENS = 50, ZTOTALCACHEREADTOKENS = 400, ZTOTALCACHECREATIONTOKENS = 20 WHERE ZTITLE = '\(legacyTitle)'",
        ]
        try seed.run()
        seed.waitUntilExit()
        XCTAssertEqual(seed.terminationStatus, 0, "Seeding the pre-split task should succeed.")
        // A fresh bridge daemon (its own service name, started by the relaunched app) reads the seeded row instead of a cached task.
        let freshDaemon = ["PLAYHOUSE_BRIDGE_SERVICE_NAME": "\(serviceName!).legacy-\(UUID().uuidString.prefix(8))"]
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: freshDaemon)
        let legacySummary = try XCTUnwrap(try runCLI(
            ["task", "token-usage", legacyID], extraEnvironment: freshDaemon
        )["result"] as? [String: Any])
        let legacyCalls = try XCTUnwrap(legacySummary["callUsage"] as? [String: Any])
        XCTAssertEqual(legacyCalls["available"] as? Bool, true)
        XCTAssertEqual(legacyCalls["totalSentTokens"] as? Int, 1_500)
        XCTAssertNil(legacyCalls["totalTokensExcludingCacheReads"], "Without the split there is no per-call figure.")
        XCTAssertEqual(legacySummary["tokensExcludingCacheReads"] as? Int, 170, "The fallback is the turn buckets minus cache reads.")
        let legacyCard = app.buttons[legacyTitle]
        XCTAssertTrue(legacyCard.waitToExist(timeout: 10))
        legacyCard.rightClick()
        element("token-stats-task-menu-item").click()
        assertText("token-stats-total-sent", equals: "1,500")
        XCTAssertFalse(element("token-stats-excluding-cache").exists, "A pre-split task hides the Excluding cache reads headline.")
        attachScreenshot(named: "Token Stats modal for a task saved before the cache split")
        // Done is the modal's default button, so Return closes it.
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitForDisappearance(element("token-stats-total-sent")), "Return pressed Done and closed Token Stats.")
        XCTAssertEqual(calls["finalTranscriptTokens"] as? Int, 650)
        XCTAssertEqual((calls["subagents"] as? [String: Any])?["count"] as? Int, 2)
    }
    // case-contract: test_task_token_usage_records_codex_turn_breakdown | A Codex app-server fixture turn's usage reaches the same per-task totals and per-turn breakdown through Codex's own wire shape, mapping its cached-input bucket onto Playhouse's cache-read bucket and leaving cache-write at zero. The recorded turn row names Codex as its provider, Codex's input count includes its cached tokens, so the input bucket excludes them rather than counting them twice. Per-call usage notifications streamed before the turn ends, including those of a subagent thread that names its parent, reach the same call-level accounting once each (a repeated notification is ignored), and the Token Stats modal shows those Codex totals, call counts and final transcript size in the app. Excluding cache reads, the figure counts each call's uncached input plus cache write plus output, main thread and subagent alike (780), and the modal shows it with its main-agent and subagent split.
    func test_task_token_usage_records_codex_turn_breakdown() throws {
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Codex token usage", roots: [fixture.primary.path])
        let taskID = try taskID(named: "Codex token usage")
        let card = app.buttons["Codex token usage"]
        XCTAssertTrue(card.waitToExist(timeout: 10))

        // A bare send only reports its usage once the terminal `turn/completed`
        // notification arrives, and the default fixture never emits one on its
        // own for an ordinary prompt — it waits for Playhouse to report an
        // outcome while the turn is held, exactly like `complete_fixture_turn`
        // drives it in the CLI/XPC suite. Reproduce that hold/outcome/release
        // dance here so the turn actually completes.
        let executable = dataDirectory.appendingPathComponent("codex-fixture-token-usage")
        try copyFixtureFile(at: WorkspaceFixture.root.appendingPathComponent("codex-fixture-ui"), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data("Playhouse test owns this Codex protocol fixture (v1).\n".utf8)
            .write(to: dataDirectory.appendingPathComponent(".playhouse-codex-fixture-owner"))
        let holdMarker = URL(fileURLWithPath: executable.path + ".hold-release")
        let activeMarker = URL(fileURLWithPath: executable.path + ".turn-active")
        let releaseMarker = URL(fileURLWithPath: executable.path + ".turn-release")
        try Data().write(to: holdMarker)
        try? FileManager.default.removeItem(at: activeMarker)
        try? FileManager.default.removeItem(at: releaseMarker)

        let process = try startCLIProcess(
            ["conversation", "send", taskID, "--message", "Complete this task.", "--answer", "color=Blue", "--answer", "token=fixture-secret"],
            extraEnvironment: ["PLAYHOUSE_E2E_CODEX_EXECUTABLE": executable.path]
        )
        defer {
            if process.process.isRunning {
                try? "Release the active turn.\n".write(to: releaseMarker, atomically: true, encoding: .utf8)
                process.process.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: activeMarker)
            try? FileManager.default.removeItem(at: releaseMarker)
            try? FileManager.default.removeItem(at: holdMarker)
        }
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: activeMarker.path) }, timeout: 10), "The fixture should hold the turn open for a CLI outcome report.")
        let outcome = try runCLI(["task", "outcome", taskID, "completed"])
        XCTAssertEqual((outcome["result"] as? [String: Any])?["outcome"] as? String, "completed")
        try "Release the completed fixture turn.\n".write(to: releaseMarker, atomically: true, encoding: .utf8)
        _ = try finishCLIProcess(process)

        // One Codex fixture turn: 3 calls (two main sending 700 and 900, one subagent
        // sending 300), 1,900 sent, and a final transcript of 900.
        let counter = element("task-token-usage-counter-\(taskID)")
        XCTAssertTrue(
            waitUntil({ counter.exists && counter.label == "1.9K tokens sent · 3 calls · 900 final transcript" }, timeout: 15),
            "A Codex turn's per-call usage, subagent included, should reach the card's counter."
        )

        card.rightClick()
        element("token-stats-task-menu-item").click()
        assertText("token-stats-total", equals: "1,050")
        assertText("token-stats-final-transcript", equals: "900")
        assertText("token-stats-total-sent", equals: "1,900")
        // Codex's input includes cached tokens: main (200+30)+(300+40), subagent 200+10.
        assertText("token-stats-excluding-cache", equals: "780")
        assertText("token-stats-excluding-cache-split", equals: "Excluding cache reads: 570 main agent · 210 subagents")
        assertText("token-stats-total-calls", equals: "3 model calls · 2 main, 1 across 1 subagent")
        attachScreenshot(named: "Token Stats modal shows a Codex turn's usage")
        element("close-token-stats-button").click()

        let summary = try XCTUnwrap(try runCLI(["task", "token-usage", taskID])["result"] as? [String: Any])
        let usage = try XCTUnwrap(summary["usage"] as? [String: Any])
        XCTAssertEqual(usage["cacheReadTokens"] as? Int, 250, "Codex's cached input maps onto the cache-read bucket.")
        XCTAssertEqual(usage["cacheCreationTokens"] as? Int, 0, "Codex reports no cache-write bucket.")
        XCTAssertEqual((summary["turns"] as? [[String: Any]])?.first?["provider"] as? String, "codex")
        XCTAssertEqual(usage["inputTokens"] as? Int, 650, "Codex's input count includes its cached tokens, which are not counted twice.")
        let calls = try XCTUnwrap(summary["callUsage"] as? [String: Any])
        XCTAssertEqual(calls["totalCalls"] as? Int, 3)
        XCTAssertEqual(calls["totalSentTokens"] as? Int, 1_900)
        XCTAssertEqual(calls["totalTokensExcludingCacheReads"] as? Int, 780)
        XCTAssertEqual(summary["tokensExcludingCacheReads"] as? Int, 780)
        XCTAssertEqual(calls["totalOutputTokens"] as? Int, 80)
        XCTAssertEqual(calls["finalTranscriptTokens"] as? Int, 900)
        XCTAssertEqual((calls["subagents"] as? [String: Any])?["calls"] as? Int, 1)
    }
    // case-contract: test_task_token_waste_ranks_claude_items_by_size | A task with no conversation reports its token map unavailable, with no wasters, tools or agents. After a Claude Code fixture turn whose session file logs every request (a shape, blobs, and transcript lines referenced by hash, including a parallel tool call sent as one message), the map reads the main agent and its subagent, and the main agent's final transcript tokens equal its last request's context exactly. The largest item is the MCP tool's 1,000-line log, ranked by the tokens it added, flagged as removed by the compaction, and sharing the tokens of the request it arrived in with its call by characters. The tools rollup ranks that MCP tool first by tokens added, the MCP server rollup counts its defined and called tools and what its definitions cost, the overhead lists the system prompt, each built-in tool definition and the server's definitions as sent with every request, the README read twice is one repeated result, the request that re-sent its context without the prompt cache is the one cache miss, and the compaction is counted. The Token Stats modal shows these in its Wasters, Tools & MCP and Overhead sections.
    func test_task_token_waste_ranks_claude_items_by_size() throws {
        let (taskID, environment) = try runClaudeTokenWasteTurn(title: "Claude token waste")
        _ = try runCLI(["task", "create", "--title", "No conversation yet", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude"])
        XCTAssertTrue(app.buttons["No conversation yet"].waitToExist(timeout: 10))
        openTokenStats(of: "No conversation yet")
        showTokenStatsSection("wasters")
        XCTAssertTrue(element("token-stats-map-unavailable").waitToExist(timeout: 10), "A task with no conversation has nothing to map.")
        XCTAssertFalse(element("token-stats-raw-input-button").isEnabled, "There is no raw input to open yet.")
        attachScreenshot(named: "A task with no conversation has no token map yet")
        element("close-token-stats-button").click()
        XCTAssertTrue(waitForDisappearance(element("token-stats-map-unavailable")))

        openTokenStats(of: "Claude token waste")

        showTokenStatsSection("wasters")
        assertText("token-stats-waster-0-label", equals: "fixturelogs/query_logs")
        XCTAssertTrue(element("token-stats-waster-0-removed").waitToExist(timeout: 5), "The compaction removed the log.")
        assertText("token-stats-waster-0-requests", equals: "×63")
        let tokensPerCopy = try duplicateTokens(taskID: taskID, environment: environment)
        assertText("token-stats-duplicate-0-copies", equals: "2 copies of \(tokensPerCopy)")
        assertText("token-stats-cache-miss-0-request", equals: "Request 34")
        attachScreenshot(named: "Wasters rank the MCP log first, then show the repeated read and the cache miss")

        showTokenStatsSection("tools")
        assertText("token-stats-measured-tool-fixturelogs/query_logs-total", equals: "18,000")
        XCTAssertTrue(element("token-stats-measured-tool-Bash").exists, "Every tool that ran has its own row.")
        assertText("token-stats-server-fixturelogs-total", equals: "18,000")
        attachScreenshot(named: "Tools and MCP servers by the tokens they added")

        showTokenStatsSection("overhead")
        XCTAssertTrue(element(containingAccessibilityText: "MCP server fixturelogs · 2 tool definitions").waitToExist(timeout: 5))
        XCTAssertTrue(element(containingAccessibilityText: "System prompt (part 1)").exists)
        XCTAssertTrue(element("token-stats-agent-claude/fxw").exists, "The subagent's file is its own agent.")
        attachScreenshot(named: "Overhead sent with every request, and each agent")
        element("close-token-stats-button").click()

        let report = try XCTUnwrap(try runCLI(["task", "token-waste", taskID], extraEnvironment: environment)["result"] as? [String: Any])
        let top = try XCTUnwrap((report["wasters"] as? [[String: Any]])?.first)
        XCTAssertEqual(top["label"] as? String, "fixturelogs/query_logs")
        XCTAssertEqual((report["tools"] as? [[String: Any]])?.first?["totalTokens"] as? Int, 18_000)
    }
    // case-contract: test_task_token_waste_ranks_codex_items_by_size | A Codex fixture turn whose thread and subagent have rollout files gives the same map from Codex's own format: a request was sent the instructions plus every item before its own output, the final transcript's tokens equal the last request's input exactly after a compaction replaced the history, Codex's unsaved tool definitions appear as one hidden-overhead item sent with every request, encrypted reasoning is shown by its size, the MCP tool's log is the largest item and was removed by the compaction, the repeated README read and the cache miss are reported, and the subagent's thread is its own agent. With --turn, the turn's map places each request in the turn by the rollout's own timestamps: its five main requests with the compaction, its subagent's one request, the log still the largest item, and a summary listing only that turn with its 6 model calls. The raw input's final transcript lists the hidden overhead, the instructions and the replacement history once each without the removed log, and an item's full text, from a tool output or from the replacement history, reads back exactly as Codex saved it, in chunks, with its call named. The single-request scope rebuilds each Codex request from the rollout and labels it reconstructed: the latest request is the final transcript in order, request 4 flags both README reads and both of their outputs as exact duplicates, each request's items add up to the input Codex reported with its cached share as cache read and no cache write, and the JSON export holds the base instructions and the input items exactly as saved. The Token Stats modal shows the Codex wasters, the hidden overhead and the subagent, showing the log opens its full text, and the raw input's single request reads as reconstructed, with request 4's duplicates flagged.
    func test_task_token_waste_ranks_codex_items_by_size() throws {
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Codex token waste", roots: [fixture.primary.path])
        let taskID = try taskID(named: "Codex token waste")
        XCTAssertTrue(app.buttons["Codex token waste"].waitToExist(timeout: 10))

        // As in the Codex token usage case, the fixture holds the turn open
        // until Playhouse reports its outcome, then completes it.
        let executable = dataDirectory.appendingPathComponent("codex-fixture-token-waste")
        try copyFixtureFile(at: WorkspaceFixture.root.appendingPathComponent("codex-fixture-ui"), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data("Playhouse test owns this Codex protocol fixture (v1).\n".utf8)
            .write(to: dataDirectory.appendingPathComponent(".playhouse-codex-fixture-owner"))
        let holdMarker = URL(fileURLWithPath: executable.path + ".hold-release")
        let activeMarker = URL(fileURLWithPath: executable.path + ".turn-active")
        let releaseMarker = URL(fileURLWithPath: executable.path + ".turn-release")
        try Data().write(to: holdMarker)
        try? FileManager.default.removeItem(at: activeMarker)
        try? FileManager.default.removeItem(at: releaseMarker)
        // The fixture writes its rollout under the Codex home the CLI forwards,
        // which must be the one the window reads its session files from.
        let process = try startCLIProcess(
            ["conversation", "send", taskID, "--message", "Show token waste.", "--answer", "color=Blue", "--answer", "token=fixture-secret"],
            extraEnvironment: [
                "PLAYHOUSE_E2E_CODEX_EXECUTABLE": executable.path,
                "CODEX_HOME": dataDirectory.appendingPathComponent("codex-home").path,
            ]
        )
        defer {
            if process.process.isRunning {
                try? "Release the active turn.\n".write(to: releaseMarker, atomically: true, encoding: .utf8)
                process.process.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: activeMarker)
            try? FileManager.default.removeItem(at: releaseMarker)
            try? FileManager.default.removeItem(at: holdMarker)
        }
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: activeMarker.path) }, timeout: 10), "The fixture should hold the turn open for a CLI outcome report.")
        _ = try runCLI(["task", "outcome", taskID, "completed"])
        try "Release the completed fixture turn.\n".write(to: releaseMarker, atomically: true, encoding: .utf8)
        _ = try finishCLIProcess(process)
        let threadID = try XCTUnwrap((try runCLI(["task", "get", taskID])["result"] as? [String: Any])?["codexThreadID"] as? String)

        openTokenStats(of: "Codex token waste")
        showTokenStatsSection("wasters")
        assertText("token-stats-waster-0-label", equals: "fixturelogs/query_logs")
        XCTAssertTrue(element("token-stats-waster-0-removed").waitToExist(timeout: 5), "The compaction removed the log.")
        assertText("token-stats-cache-miss-0-request", equals: "Request 4")
        attachScreenshot(named: "Codex wasters rank the MCP log first")
        element("token-stats-waster-0-show").click()
        assertText("raw-input-text-label", equals: "fixturelogs/query_logs")
        let firstLine = element("raw-input-text-line-1")
        XCTAssertTrue(firstLine.waitToExist(timeout: 10), "The Codex log's full text opens from its waster row.")
        XCTAssertTrue(
            accessibleLabelOrValue(of: firstLine).contains("2026-11-03T10:00:01Z INFO fixture log line 0001"),
            "The first line is the log exactly as Codex saved it."
        )
        attachScreenshot(named: "Showing the Codex waster opens the log as Codex saved it")
        element("close-raw-input-button").click()
        showTokenStatsSection("overhead")
        XCTAssertTrue(
            element(containingAccessibilityText: "Tool definitions and other context Codex does not save").waitToExist(timeout: 5),
            "Codex's unsaved tool definitions show as one hidden-overhead line."
        )
        XCTAssertTrue(element("token-stats-agent-codex/\(threadID)-subagent").exists, "The subagent thread is its own agent.")
        attachScreenshot(named: "Codex overhead includes the hidden tool definitions and the subagent")

        element("token-stats-raw-input-button").click()
        let requestScope = element("raw-input-scope-request")
        XCTAssertTrue(requestScope.waitToExist(timeout: 10))
        requestScope.click()
        assertText("raw-input-request-number", equals: "Request 5 of 5")
        assertText("raw-input-request-exactness", equals: "Reconstructed")
        XCTAssertTrue(
            accessibleLabelOrValue(of: element("raw-input-request-note")).hasPrefix("Reconstructed: Codex resends the whole history"),
            "The view says how the Codex request was rebuilt."
        )
        assertText("raw-input-request-usage", equals: "Reported input 4,400 (uncached 500 · cache read 3,900) · items add up to 4,400 · 0 repeated")
        element("raw-input-request-previous").click()
        assertText("raw-input-request-number", equals: "Request 4 of 5")
        revealRawInputRow("raw-input-request-row-11")
        assertText("raw-input-request-row-9-repeat", equals: "Duplicate 1 of 2")
        assertText("raw-input-request-row-11-repeat", equals: "Duplicate 2 of 2 · first at #10")
        attachScreenshot(named: "A reconstructed Codex request flags the README read sent twice")
        element("close-raw-input-button").click()
        element("close-token-stats-button").click()

        let report = try XCTUnwrap(try runCLI(["task", "token-waste", taskID])["result"] as? [String: Any])
        let overhead = try XCTUnwrap(report["overhead"] as? [[String: Any]])
        XCTAssertTrue(overhead.contains { $0["kind"] as? String == "hiddenOverhead" && $0["everyRequest"] as? Bool == true })
        XCTAssertEqual((report["agents"] as? [[String: Any]])?.first?["finalTranscriptTokens"] as? Int, 4_400)

        // The turn's own Token Stats place each Codex request in it by the rollout's own timestamps.
        let history = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
        let turnID = try XCTUnwrap((history["messages"] as? [[String: Any]])?.first {
            $0["role"] as? String == "user" && $0["text"] as? String == "Show token waste."
        }?["turnID"] as? String)
        let scoped = try XCTUnwrap(try runCLI(["task", "token-waste", taskID, "--turn", turnID])["result"] as? [String: Any])
        let scopedAgents = try XCTUnwrap(scoped["agents"] as? [[String: Any]])
        XCTAssertEqual(scopedAgents.map { $0["requests"] as? Int }, [5, 1], "The turn made five main requests and its subagent's one.")
        XCTAssertEqual(scopedAgents.map { $0["compactions"] as? Int }, [1, 0])
        XCTAssertEqual((scoped["wasters"] as? [[String: Any]])?.first?["label"] as? String, "fixturelogs/query_logs")
        let turnUsage = try XCTUnwrap(try runCLI(["task", "token-usage", taskID, "--turn", turnID])["result"] as? [String: Any])
        XCTAssertEqual((turnUsage["turns"] as? [[String: Any]])?.map { $0["id"] as? String }, [turnID])
        XCTAssertEqual((turnUsage["callUsage"] as? [String: Any])?["totalCalls"] as? Int, 6)
    }
    // case-contract: test_task_raw_input_pages_final_transcript_without_duplicates | A task with no conversation has no raw input: its page is empty and reading an item's text is not_found. After a Claude Code fixture turn, the raw input lists the final transcript with each item once across pages and without the log a compaction removed; the everything-sent scope adds what was removed, ordering by size lists the largest first, a search finds the log by a word only its full text contains, and a focus item reports its position. An item's full text reads back in chunks that end on a line break and join to the exact text, with the call that produced it named. An unknown agent or item is not_found, and an unknown order or a limit of zero is invalid_argument. In the app, View raw input opens the final transcript, scrolling loads the next page of rows, showing the largest waster opens it in the everything-sent scope with its full text, and scrolling that text reaches its last line.
    func test_task_raw_input_pages_final_transcript_without_duplicates() throws {
        let (taskID, environment) = try runClaudeTokenWasteTurn(title: "Claude raw input")
        let everything = try XCTUnwrap(try runCLI(
            ["task", "raw-input", taskID, "--scope", "all", "--limit", "1000"], extraEnvironment: environment
        )["result"] as? [String: Any])
        let allRows = try XCTUnwrap(everything["rows"] as? [[String: Any]])
        let lastRowID = try XCTUnwrap(allRows.last?["id"] as? Int)
        XCTAssertGreaterThan(allRows.count, 100, "Enough items that the list needs a second page.")

        openTokenStats(of: "Claude raw input")
        let rawInputButton = element("token-stats-raw-input-button")
        XCTAssertTrue(waitUntil({ rawInputButton.exists && rawInputButton.isEnabled }, timeout: 10), "The raw input opens once the map has loaded.")
        rawInputButton.click()
        assertText("raw-input-summary", equals: "10 items · 3,160 tokens")
        XCTAssertTrue(element("raw-input-no-selection").exists)
        attachScreenshot(named: "Raw input opens on the final transcript, each item once")

        element("raw-input-scope-all").click()
        let summary = element("raw-input-summary")
        XCTAssertTrue(
            waitUntil({ self.accessibleLabelOrValue(of: summary).hasPrefix("\(allRows.count) items") }, timeout: 10),
            "Everything sent adds what the compaction removed."
        )
        let loadedRows = element("raw-input-loaded-rows")
        assertText("raw-input-loaded-rows", equals: "100 of \(allRows.count) loaded")
        XCTAssertFalse(element("raw-input-row-\(lastRowID)").exists, "Rows past the first page are not loaded yet.")
        let list = element("raw-input-list")
        let lastRow = element("raw-input-row-\(lastRowID)")
        for _ in 0..<60 {
            guard !lastRow.exists else { break }
            list.scroll(byDeltaX: 0, deltaY: -800)
        }
        XCTAssertTrue(lastRow.waitToExist(timeout: 10), "Scrolling to the end loads the next page of rows.")
        XCTAssertTrue(
            waitUntil({ self.accessibleLabelOrValue(of: loadedRows) == "\(allRows.count) of \(allRows.count) loaded" }, timeout: 10),
            "The second page is fetched only once the list scrolls to its end."
        )
        attachScreenshot(named: "Scrolling the list loads the next page")
        element("close-raw-input-button").click()

        showTokenStatsSection("wasters")
        let show = element("token-stats-waster-0-show")
        XCTAssertTrue(show.waitToExist(timeout: 5))
        show.click()
        assertText("raw-input-text-label", equals: "fixturelogs/query_logs")
        let call = element("raw-input-text-call")
        XCTAssertTrue(call.waitToExist(timeout: 5), "A tool result names the call that produced it.")
        let callText = accessibleLabelOrValue(of: call)
        XCTAssertTrue(callText.contains("fixturelogs/query_logs") && callText.contains("5000"), "The call names the tool and its arguments: \(callText)")
        XCTAssertTrue(element("raw-input-text-line-1").waitToExist(timeout: 5))
        XCTAssertTrue(
            waitUntil({ self.accessibleLabelOrValue(of: summary).hasPrefix("\(allRows.count) items") }, timeout: 10),
            "A removed waster opens in the everything-sent scope."
        )
        attachScreenshot(named: "Showing the largest waster opens its full text")
        let logLength = WasteFixture.logLength
        let loadedText = element("raw-input-text-loaded")
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: loadedText).hasSuffix("of \(logLength) characters loaded") }, timeout: 10))
        XCTAssertFalse(
            accessibleLabelOrValue(of: loadedText).hasPrefix("\(logLength) of"),
            "Only the first chunk of the log is loaded before the text scrolls."
        )
        let text = element("raw-input-text")
        let lastLine = element("raw-input-text-line-1000")
        for _ in 0..<80 {
            guard !lastLine.exists else { break }
            text.scroll(byDeltaX: 0, deltaY: -1500)
        }
        XCTAssertTrue(lastLine.waitToExist(timeout: 10), "Scrolling the text loads its later chunks up to the last line.")
        assertText("raw-input-text-loaded", equals: "\(logLength) of \(logLength) characters loaded")
        attachScreenshot(named: "Scrolling the log reaches its last line")
        element("close-raw-input-button").click()
        element("close-token-stats-button").click()
    }
    // case-contract: test_task_raw_input_single_request_lists_resumed_instruction_copies_in_order | After a Claude Code fixture session that resumes once its AGENTS.md changed, the raw input's single-request scope lists every item one request sent, in order and with nothing merged, and shows the latest request by default. A request after the resume carries both instruction copies in order, which differ and so are not flagged, while the date reminder sent twice word for word is flagged as a duplicate; a request before the resume carries one copy and no duplicates, and a search keeps each row's position. Each request reports Claude's input with its cache-read and cache-write split, and its items' sizes add up to that input. The request is labelled exact; its text export gives every item's full text under a header naming any duplicate, and its JSON export is the request body with the logged parameters, cache markers, system prompt, tools and messages verbatim, an earlier request's messages being a prefix of a later one's. A request number past the last is not_found, and zero or an unknown export format is invalid_argument. In the app, choosing Single request shows the latest request with its usage, both instruction copies unflagged and the repeated date reminder flagged, stepping back to a request before the resume shows one copy and no flags, Latest returns to the last request, and Copy all copies the whole request as JSON.
    func test_task_raw_input_single_request_lists_resumed_instruction_copies_in_order() throws {
        var environment = try installClaudeFixture(named: "claude-fixture-ui-instruction-resume")
        let claudeConfig = dataDirectory.appendingPathComponent("claude-config").path
        environment["CLAUDE_CONFIG_DIR"] = claudeConfig
        environment["PLAYHOUSE_E2E_CLAUDE_CONFIG_DIR"] = claudeConfig
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: environment)
        let title = "Claude instruction resume"
        let taskID = try XCTUnwrap((try runCLI([
            "task", "create", "--title", title, "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
        ])["result"] as? [String: Any])?["id"] as? String)
        XCTAssertTrue(app.buttons[title].waitToExist(timeout: 10))
        _ = try runCLI(["conversation", "send", taskID, "--message", "Show instruction resume."], extraEnvironment: environment)

        openTokenStats(of: title)
        let rawInputButton = element("token-stats-raw-input-button")
        XCTAssertTrue(waitUntil({ rawInputButton.exists && rawInputButton.isEnabled }, timeout: 10), "The raw input opens once the map has loaded.")
        rawInputButton.click()
        let requestScope = element("raw-input-scope-request")
        XCTAssertTrue(requestScope.waitToExist(timeout: 10), "The raw input offers a single-request scope.")
        requestScope.click()
        assertText("raw-input-request-number", equals: "Request 5 of 5")
        assertText("raw-input-summary", equals: "16 items · 9,100 tokens")
        assertText("raw-input-request-exactness", equals: "Exact")
        assertText(
            "raw-input-request-usage",
            equals: "Reported input 9,100 (uncached 2 · cache read 9,000 · cache write 98) · items add up to 9,100 · 2 repeated · source sdk"
        )
        XCTAssertFalse(element("raw-input-request-next").isEnabled, "The latest request is the last one.")
        XCTAssertFalse(element("raw-input-request-latest").isEnabled)
        XCTAssertTrue(element("raw-input-request-time").exists, "The request shows when it was sent.")
        XCTAssertTrue(element("raw-input-request-row-3").exists)
        XCTAssertFalse(element("raw-input-request-row-3-repeat").exists, "The two AGENTS.md copies differ, so neither is flagged.")
        assertText("raw-input-request-row-4-repeat", equals: "Duplicate 1 of 2")
        revealRawInputRow("raw-input-request-row-13")
        XCTAssertTrue(element("raw-input-request-row-11").exists)
        XCTAssertFalse(element("raw-input-request-row-11-repeat").exists)
        assertText("raw-input-request-row-12-repeat", equals: "Duplicate 2 of 2 · first at #5")
        XCTAssertTrue(element("raw-input-request-row-13").exists)
        XCTAssertFalse(element("raw-input-request-row-13-repeat").exists, "The resumed prompt itself is not a repeat.")
        attachScreenshot(named: "The latest request lists both AGENTS.md copies in order and flags the date reminder sent twice")

        element("raw-input-request-row-11").click()
        let secondLine = element("raw-input-text-line-2")
        XCTAssertTrue(secondLine.waitToExist(timeout: 10), "Selecting the second copy opens its full text.")
        XCTAssertTrue(
            accessibleLabelOrValue(of: secondLine).contains("Instruction files were re-read when this session started"),
            "The second copy is the instructions re-read on resume."
        )
        attachScreenshot(named: "The re-read AGENTS.md copy, selected in the request")

        let previous = element("raw-input-request-previous")
        previous.click()
        assertText("raw-input-request-number", equals: "Request 4 of 5")
        previous.click()
        assertText("raw-input-request-number", equals: "Request 3 of 5")
        assertText("raw-input-summary", equals: "10 items · 4,400 tokens")
        XCTAssertTrue(element("raw-input-request-row-3").waitToExist(timeout: 5), "The first copy was already sent.")
        XCTAssertFalse(element("raw-input-request-row-3-repeat").exists, "Before the resume the instructions were sent once.")
        XCTAssertFalse(element("raw-input-request-row-11").exists, "Request 3 sent only ten items.")
        XCTAssertTrue(accessibleLabelOrValue(of: element("raw-input-request-usage")).contains("items add up to 4,400 · 0 repeated"))
        attachScreenshot(named: "A request before the resume carries one AGENTS.md copy and no repeats")

        element("raw-input-request-latest").click()
        assertText("raw-input-request-number", equals: "Request 5 of 5")
        element("raw-input-export-format-json").click()
        NSPasteboard.general.clearContents()
        element("raw-input-request-copy-button").click()
        assertText("raw-input-request-export-status", equals: "Copied request 5 as JSON: 16 items")
        let copied = try XCTUnwrap(NSPasteboard.general.string(forType: .string), "Copy all puts the request on the pasteboard.")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(copied.utf8)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 9, "The whole request, every message it sent.")
        let resumed = try XCTUnwrap((messages[6]["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertTrue(resumed.contains("Instruction files were re-read"))
        let original = try XCTUnwrap((messages[0]["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertTrue(original.contains("Codebase and user instructions are shown below"))
        XCTAssertEqual(body["model"] as? String, "claude-fixture")
        attachScreenshot(named: "Copy all copies the whole request as JSON")
        element("close-raw-input-button").click()
        element("close-token-stats-button").click()

        let page = try XCTUnwrap(try runCLI(
            ["task", "raw-input", taskID, "--scope", "request", "--request", "3"], extraEnvironment: environment
        )["result"] as? [String: Any])
        XCTAssertEqual((page["request"] as? [String: Any])?["repeatedItems"] as? Int, 0)
    }
    // case-contract: test_claude_native_auto_compaction_and_warm_idle | Claude task launches never set CLAUDE_CODE_AUTO_COMPACT_WINDOW or any other value that shrinks or disables Claude Code's native auto-compaction, whether Playhouse's compaction triggers are on or off, and the settings no longer have a threshold: a threshold saved by an earlier build is ignored and settings load with their other values, the CLI rejects --threshold and saved settings stay unchanged. For an In Progress Claude task whose fixture session has 180,000 context tokens and has been idle 51 minutes, a scheduler tick runs one warm-idle /compact before the cache expires, records its trigger and before/after sizes in token usage, and a second tick does not compact again. Maintenance API token usage contributes to the task total. The conversation labels the maintenance activity as automatic without adding an empty assistant turn. Claude Code's own auto-compaction at its native window emits a provider auto-compaction boundary visible in the conversation and labelled Provider auto-compaction in Token Stats. The settings window shows and saves the enabled toggle, idle wait and minimum context with no threshold field, and its invalid-value alert leaves the saved value unchanged; negative and malformed integers are rejected without changing saved settings. Idle checks skip Done and Backlog tasks, contexts below the minimum, pending user-input requests, an active Claude turn, and an outstanding background task; eligible In Progress, Waiting Response, and Review tasks compact.
    func test_claude_native_auto_compaction_and_warm_idle() throws {
        var environment = try installClaudeFixture(named: "claude-fixture-ui-auto-compaction")
        environment["CLAUDE_CONFIG_DIR"] = dataDirectory.appendingPathComponent("claude-config").path
        environment["PLAYHOUSE_E2E_CLAUDE_FIXTURE_REPORT_OUTCOME"] = "1"
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: environment)
        // Earlier builds saved a threshold; it must not break or leak into the loaded settings.
        let legacyThreshold = Process()
        legacyThreshold.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        legacyThreshold.arguments = ["write", preferencesSuiteName, "autoCompactionThresholdTokens", "-int", "100000"]
        try legacyThreshold.run()
        legacyThreshold.waitUntilExit()
        XCTAssertEqual(legacyThreshold.terminationStatus, 0, "The earlier build's threshold should be saved before settings load.")
        let legacySettings = try XCTUnwrap(((try runCLI(["settings", "get"])["result"] as? [String: Any])?["autoCompaction"] as? [String: Any]))
        XCTAssertEqual(legacySettings as NSDictionary, ["enabled": true, "idleMinutes": 50, "minimumTokens": 150000] as NSDictionary,
                       "A saved threshold from an earlier build is ignored.")
        let creation = try runCLI([
            "task", "create", "--title", "Warm compaction", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
        ])
        let taskID = try XCTUnwrap((creation["result"] as? [String: Any])?["id"] as? String)
        XCTAssertTrue(app.buttons["Warm compaction"].waitToExist(timeout: 10))
        _ = try runCLI(["conversation", "send", taskID, "--message", "Hello."], extraEnvironment: environment)
        let fixtureHistory = dataDirectory.appendingPathComponent("claude-fixture-ui-auto-compaction.history")
        let firstTurn = try XCTUnwrap(((try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureHistory)) as? [String: Any])?["turns"] as? [[String: Any]])?.first)
        XCTAssertTrue(firstTurn["autoCompactWindow"] == nil || firstTurn["autoCompactWindow"] is NSNull,
                      "Claude Code must keep its native auto-compact window.")
        XCTAssertEqual((firstTurn["autoCompactOverrides"] as? [String: Any])?.isEmpty, true,
                       "Nothing at launch may shrink or disable Claude Code's native auto-compaction.")
        let rejectedThreshold = try runCLI(["settings", "set-auto-compaction", "--threshold", "200000"], expectedStatus: 2)
        XCTAssertEqual((rejectedThreshold["error"] as? [String: Any])?["code"] as? String, "invalid_argument")
        let savedSettings = try XCTUnwrap((try runCLI(["settings", "get"])["result"] as? [String: Any])?["autoCompaction"] as? [String: Any])
        XCTAssertNil(savedSettings["thresholdTokens"], "The settings no longer have a threshold.")
        XCTAssertEqual(savedSettings["idleMinutes"] as? Int, 50)
        _ = try runCLI([
            "conversation", "send", taskID, "--message", "fill context to 180000 tokens 51 minutes ago",
        ], extraEnvironment: environment)
        _ = try runCLI(["task", "prompt", taskID, "--text", "Fixture task description.", "--status", "In Progress"])
        XCTAssertEqual((try runCLI(["task", "get", taskID])["result"] as? [String: Any])?["status"] as? String, "In Progress")
        let beforeUsage = try XCTUnwrap((try runCLI(["task", "token-usage", taskID])["result"] as? [String: Any])?["totalTokens"] as? Int)
        _ = try runCLI(["schedule", "tick"], extraEnvironment: environment)
        let usageResponse = try runCLI(["task", "token-usage", taskID])
        let usage = try XCTUnwrap(usageResponse["result"] as? [String: Any])
        XCTAssertEqual((usage["totalTokens"] as? Int ?? 0) - beforeUsage, 180060)
        let compactions = try XCTUnwrap(usage["contextCompactions"] as? [[String: Any]])
        XCTAssertEqual(compactions.count, 1)
        XCTAssertEqual(compactions.first?["trigger"] as? String, "warm-idle")
        XCTAssertEqual(compactions.first?["preTokens"] as? Int, 180000)
        XCTAssertEqual(compactions.first?["postTokens"] as? Int, 6000)
        let conversation = try runCLI(["conversation", "history", taskID])
        let history = try XCTUnwrap((conversation["result"] as? [String: Any])?["messages"] as? [[String: Any]])
        XCTAssertFalse(history.contains { ($0["role"] as? String) == "assistant" && (($0["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) },
                        "A maintenance compaction must not leave an empty assistant turn.")
        _ = try runCLI(["schedule", "tick"], extraEnvironment: environment)
        let repeatedResponse = try runCLI(["task", "token-usage", taskID])
        let repeatedUsage = try XCTUnwrap(repeatedResponse["result"] as? [String: Any])
        XCTAssertEqual((repeatedUsage["contextCompactions"] as? [[String: Any]])?.count, 1)

        openTask(named: "Warm compaction")
        let automaticActivity = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "context-compaction-row-", "Context compacted automatically"
        )).firstMatch
        XCTAssertTrue(automaticActivity.waitToExist(timeout: 10), "The maintenance turn should have a labelled timeline activity.")
        attachScreenshot(named: "Warm idle compaction is labelled in the conversation")
        attachElementScreenshot(automaticActivity, named: "Automatic compaction timeline row")

        returnToBoard()
        element("task-token-usage-counter-\(taskID)").click()
        let compactionStat = app.staticTexts["token-stats-compaction-0"]
        XCTAssertTrue(compactionStat.waitToExist(timeout: 10), "Token Stats should expose the warm-idle trigger and context sizes.")
        XCTAssertTrue(accessibleLabelOrValue(of: compactionStat).contains("Idle, before the cache expired"))
        attachScreenshot(named: "Token Stats lists the warm-idle compaction")
        attachElementScreenshot(compactionStat, named: "Token Stats shows the warm-idle compaction trigger")
        element("close-token-stats-button").click()

        app.typeKey(",", modifierFlags: .command)
        let preferences = settingsWindow
        XCTAssertTrue(preferences.waitToExist(timeout: 10))
        for identifier in ["auto-compaction-enabled-toggle", "auto-compaction-idle-minutes-field", "auto-compaction-minimum-field"] {
            XCTAssertTrue(preferences.descendants(matching: .any).matching(identifier: identifier).firstMatch.waitToExist(timeout: 5), "Settings should show \(identifier).")
        }
        XCTAssertFalse(preferences.descendants(matching: .any).matching(identifier: "auto-compaction-threshold-field").firstMatch.exists,
                       "Settings must not offer a compaction threshold; each provider's native auto-compaction decides.")
        let triggersToggle = preferences.descendants(matching: .any).matching(identifier: "auto-compaction-enabled-toggle").firstMatch
        XCTAssertEqual((triggersToggle.value as? NSNumber)?.intValue, 1)
        XCTAssertTrue(accessibleLabelOrValue(of: triggersToggle).contains("Playhouse compaction triggers")
            || preferences.staticTexts["Playhouse compaction triggers"].exists,
                      "The toggle should name only Playhouse's own compaction triggers.")
        let idleMinutesField = preferences.descendants(matching: .any).matching(identifier: "auto-compaction-idle-minutes-field").firstMatch
        XCTAssertEqual(idleMinutesField.value as? String, "50")
        let minimumContextField = preferences.descendants(matching: .any).matching(identifier: "auto-compaction-minimum-field").firstMatch
        XCTAssertEqual(minimumContextField.value as? String, "150,000")
        let nativeExplanation = preferences.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@", "always auto-compact a full context themselves"
        )).firstMatch
        XCTAssertTrue(nativeExplanation.exists, "Settings should explain that native provider auto-compaction stays on.")
        let settingsScroll = preferences.scrollViews.firstMatch
        XCTAssertTrue(scrollFullyIntoView(minimumContextField, in: settingsScroll), "The compaction settings should be visible before their screenshot.")
        XCTAssertTrue(nativeExplanation.isHittable, "The native auto-compaction explanation should be on screen for its screenshot.")
        attachScreenshot(named: "Context compaction settings without a threshold")
        attachElementScreenshot(nativeExplanation, named: "Native auto-compaction stays on explanation")
        app.typeKey("w", modifierFlags: .command)
        try runCLI(["settings", "set-auto-compaction", "--enabled", "false"])
        let disabledTask = try XCTUnwrap((try runCLI([
            "task", "create", "--title", "Compaction disabled", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
        ])["result"] as? [String: Any])?["id"] as? String)
        _ = try runCLI(["conversation", "send", disabledTask, "--message", "Hello."], extraEnvironment: environment)
        let disabledHistory = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureHistory)) as? [String: Any])?["turns"] as? [[String: Any]])
        let disabledAutoCompactWindow = disabledHistory.last?["autoCompactWindow"]
        XCTAssertTrue(
            disabledAutoCompactWindow == nil || disabledAutoCompactWindow is NSNull,
            "Disabling Playhouse's triggers must not set Claude's auto-compact window."
        )
        XCTAssertEqual((disabledHistory.last?["autoCompactOverrides"] as? [String: Any])?.isEmpty, true,
                       "Disabling Playhouse's triggers must not turn off Claude Code's native auto-compaction.")

        try runCLI(["settings", "set-auto-compaction", "--enabled", "true"])
        let nativeTask = try XCTUnwrap((try runCLI([
            "task", "create", "--title", "Native compaction", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
        ])["result"] as? [String: Any])?["id"] as? String)
        _ = try runCLI(["conversation", "send", nativeTask, "--message", "Hello."], extraEnvironment: environment)
        _ = try runCLI(["conversation", "send", nativeTask, "--message", "fill context to 210000 tokens"], extraEnvironment: environment)
        let nativeUsage = try XCTUnwrap((try runCLI(["task", "token-usage", nativeTask])["result"] as? [String: Any])?["contextCompactions"] as? [[String: Any]])
        XCTAssertEqual(nativeUsage.last?["trigger"] as? String, "threshold")
        XCTAssertEqual(nativeUsage.last?["preTokens"] as? Int, 210000)
        openTask(named: "Native compaction")
        let nativeRow = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "context-compaction-row-", "Context compacted automatically"
        )).firstMatch
        XCTAssertTrue(nativeRow.waitToExist(timeout: 10), "Claude Code's native auto-compaction boundary should be visible as automatic compaction.")
        XCTAssertTrue(nativeRow.label.contains("Provider auto-compaction"), "The row should credit the provider's own auto-compaction: \(nativeRow.label)")
        attachScreenshot(named: "Claude native auto-compaction in the conversation")
        attachElementScreenshot(nativeRow, named: "Claude native auto-compaction row")
        returnToBoard()
        element("task-token-usage-counter-\(nativeTask)").click()
        let nativeStat = app.staticTexts["token-stats-compaction-0"]
        XCTAssertTrue(nativeStat.waitToExist(timeout: 10))
        XCTAssertTrue(pluginText(nativeStat).contains("Provider auto-compaction"), "Token Stats labels the provider's own auto-compaction.")
        attachScreenshot(named: "Token Stats records provider auto-compaction")
        attachElementScreenshot(nativeStat, named: "Token Stats shows provider auto-compaction")
        element("close-token-stats-button").click()

        app.typeKey(",", modifierFlags: .command)
        let settings = settingsWindow
        let enabled = settings.descendants(matching: .any).matching(identifier: "auto-compaction-enabled-toggle").firstMatch
        enabled.click()
        XCTAssertTrue(waitUntil({
            (((try? self.runCLI(["settings", "get"])["result"] as? [String: Any])?["autoCompaction"] as? [String: Any])?["enabled"] as? Bool) == false
        }, timeout: 10), "The visible toggle should disable automatic compaction in persisted settings.")
        enabled.click()
        let idleField = settings.descendants(matching: .any).matching(identifier: "auto-compaction-idle-minutes-field").firstMatch
        idleField.click(); idleField.typeKey("a", modifierFlags: .command); idleField.typeText("49\r")
        let minimumField = settings.descendants(matching: .any).matching(identifier: "auto-compaction-minimum-field").firstMatch
        minimumField.click(); minimumField.typeKey("a", modifierFlags: .command); minimumField.typeText("160000\r")
        XCTAssertTrue(waitUntil({
            guard let saved = try? self.runCLI(["settings", "get"])["result"] as? [String: Any],
                  let compaction = saved["autoCompaction"] as? [String: Any] else { return false }
            return compaction["idleMinutes"] as? Int == 49 && compaction["minimumTokens"] as? Int == 160000 && compaction["enabled"] as? Bool == true
        }, timeout: 10), "The visible idle and minimum fields should persist through the shared settings manager.")
        try runCLI(["settings", "set-auto-compaction", "--idle-minutes", "50", "--minimum", "150000"])
        let invalidIdle = settings.descendants(matching: .any).matching(identifier: "auto-compaction-idle-minutes-field").firstMatch
        invalidIdle.click(); invalidIdle.typeKey("a", modifierFlags: .command); invalidIdle.typeText("60\r")
        let settingsError = app.sheets.firstMatch
        XCTAssertTrue(settingsError.waitToExist(timeout: 5), "The settings form should report a rejected idle wait.")
        XCTAssertTrue(
            settingsError.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Couldn't save")).firstMatch.exists,
            "The validation sheet should identify the failed context compaction setting."
        )
        let savedAfterRejection = try XCTUnwrap(try runCLI(["settings", "get"])["result"] as? [String: Any])
        XCTAssertEqual((savedAfterRejection["autoCompaction"] as? [String: Any])?["idleMinutes"] as? Int, 50,
                       "A rejected visible value must leave persisted settings unchanged.")
        attachScreenshot(named: "Context compaction setting validation alert")
        attachElementScreenshot(settingsError, named: "Invalid context compaction setting shows a save error")
        settingsError.buttons["OK"].click()
        for (identifier, invalid, key, expected) in [
            ("auto-compaction-minimum-field", "-100000", "minimumTokens", 150000),
            ("auto-compaction-minimum-field", "200000x", "minimumTokens", 150000),
            ("auto-compaction-idle-minutes-field", "5.5", "idleMinutes", 50),
        ] {
            let field = settings.descendants(matching: .any).matching(identifier: identifier).firstMatch
            field.click(); field.typeKey("a", modifierFlags: .command); field.typeText(invalid + "\r")
            XCTAssertTrue(app.sheets.firstMatch.waitToExist(timeout: 5), "Malformed integer must show validation.")
            app.sheets.firstMatch.buttons["OK"].click()
            let saved = try XCTUnwrap((try runCLI(["settings", "get"])["result"] as? [String: Any])?["autoCompaction"] as? [String: Any])
            XCTAssertEqual(saved[key] as? Int, expected)
        }
        app.typeKey("w", modifierFlags: .command)

        func makeIdleTask(_ title: String, root: String = "") throws -> String {
            var args = ["task", "create", "--title", title, "--prompt", "Fixture task description.", "--provider", "claude"]
            if !root.isEmpty { args += ["--root", root] }
            return try XCTUnwrap((try runCLI(args)["result"] as? [String: Any])?["id"] as? String)
        }
        let backlogTask = try makeIdleTask("Backlog compaction", root: fixture.primary.path)
        _ = try runCLI(["conversation", "send", backlogTask, "--message", "Hello."], extraEnvironment: environment)
        _ = try runCLI(["conversation", "send", backlogTask, "--message", "fill context to 180000 tokens 51 minutes ago"], extraEnvironment: environment)
        _ = try runCLI(["task", "prompt", backlogTask, "--text", "Saved in Backlog", "--status", "Backlog"])
        _ = try runCLI(["schedule", "tick"], extraEnvironment: environment)
        XCTAssertEqual((try runCLI(["task", "get", backlogTask])["result"] as? [String: Any])?["status"] as? String, "Backlog")
        XCTAssertTrue(((try runCLI(["task", "token-usage", backlogTask])["result"] as? [String: Any])?["contextCompactions"] as? [[String: Any]])?.isEmpty == true)

        let pendingTask = try makeIdleTask("Pending question compaction", root: fixture.primary.path)
        _ = try runCLI(["conversation", "send", pendingTask, "--message", "finish while a structured question remains pending; fill context to 180000 tokens 51 minutes ago"], extraEnvironment: environment)
        let pendingHistory = try runCLI(["conversation", "history", pendingTask], extraEnvironment: environment)
        XCTAssertNotNil((pendingHistory["result"] as? [String: Any])?["pendingUserInputRequest"], "The fixture must leave a real user-input request pending before the idle tick.")
        _ = try runCLI(["schedule", "tick"], extraEnvironment: environment)
        let pendingAfterTick = try runCLI(["conversation", "history", pendingTask], extraEnvironment: environment)
        XCTAssertNotNil((pendingAfterTick["result"] as? [String: Any])?["pendingUserInputRequest"], "The idle tick must preserve the pending user-input request.")
        XCTAssertTrue(((try runCLI(["task", "token-usage", pendingTask])["result"] as? [String: Any])?["contextCompactions"] as? [[String: Any]])?.isEmpty == true)

        let waitingTask = try makeIdleTask("Waiting response compaction", root: fixture.primary.path)
        _ = try runCLI(["conversation", "send", waitingTask, "--message", "Hello."], extraEnvironment: environment)
        _ = try runCLI(["conversation", "send", waitingTask, "--message", "fill context to 180000 tokens 51 minutes ago"], extraEnvironment: environment)
        XCTAssertEqual((try runCLI(["task", "get", waitingTask])["result"] as? [String: Any])?["status"] as? String, "Waiting Response")
        _ = try runCLI(["schedule", "tick"], extraEnvironment: environment)
        XCTAssertEqual((((try runCLI(["task", "token-usage", waitingTask])["result"] as? [String: Any])?["contextCompactions"] as? [[String: Any]])?.first)?["trigger"] as? String, "warm-idle")

        let reviewTask = try makeIdleTask("Review compaction", root: fixture.custom.path)
        _ = try runCLI(["conversation", "send", reviewTask, "--message", "Hello."], extraEnvironment: environment)
        _ = try runCLI(["conversation", "send", reviewTask, "--message", "fill context to 180000 tokens 51 minutes ago"], extraEnvironment: environment)
        _ = try runCLI(["task", "move", reviewTask, "Review"])
        XCTAssertEqual((try runCLI(["task", "get", reviewTask])["result"] as? [String: Any])?["status"] as? String, "Review")
        _ = try runCLI(["schedule", "tick"], extraEnvironment: environment)
        XCTAssertEqual((((try runCLI(["task", "token-usage", reviewTask])["result"] as? [String: Any])?["contextCompactions"] as? [[String: Any]])?.first)?["trigger"] as? String, "warm-idle")

        let smallTask = try makeIdleTask("Small context compaction", root: fixture.primary.path)
        _ = try runCLI(["conversation", "send", smallTask, "--message", "Hello."], extraEnvironment: environment)
        _ = try runCLI(["conversation", "send", smallTask, "--message", "fill context to 100000 tokens 51 minutes ago"], extraEnvironment: environment)
        _ = try runCLI(["schedule", "tick"], extraEnvironment: environment)
        XCTAssertTrue(((try runCLI(["task", "token-usage", smallTask])["result"] as? [String: Any])?["contextCompactions"] as? [[String: Any]])?.isEmpty == true)

        let doneTask = try makeIdleTask("Done compaction", root: fixture.custom.path)
        _ = try runCLI(["conversation", "send", doneTask, "--message", "Hello."], extraEnvironment: environment)
        _ = try runCLI(["conversation", "send", doneTask, "--message", "fill context to 180000 tokens 51 minutes ago"], extraEnvironment: environment)
        _ = try runCLI(["task", "move", doneTask, "Review"])
        _ = try runCLI(["task", "move", doneTask, "Done"])
        _ = try runCLI(["schedule", "tick"], extraEnvironment: environment)
        XCTAssertEqual((try runCLI(["task", "get", doneTask])["result"] as? [String: Any])?["status"] as? String, "Done")
        XCTAssertTrue(((try runCLI(["task", "token-usage", doneTask])["result"] as? [String: Any])?["contextCompactions"] as? [[String: Any]])?.isEmpty == true)

        let backgroundTask = try makeIdleTask("Background task compaction", root: fixture.primary.path)
        _ = try runCLI(["conversation", "send", backgroundTask, "--message", "Hello."], extraEnvironment: environment)
        let executable = URL(fileURLWithPath: environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"]!)
        let backgroundReady = URL(fileURLWithPath: executable.path + ".compaction-background-ready")
        let backgroundRelease = URL(fileURLWithPath: executable.path + ".compaction-background-release")
        try? FileManager.default.removeItem(at: backgroundReady)
        try? FileManager.default.removeItem(at: backgroundRelease)
        let backgroundFinished = DispatchSemaphore(value: 0)
        let errorLock = NSLock()
        var backgroundError: Error?
        DispatchQueue.global().async {
            do {
                _ = try self.runCLI(["conversation", "send", backgroundTask, "--message", "hold background task for compaction; fill context to 180000 tokens 51 minutes ago"], extraEnvironment: environment)
            } catch { errorLock.lock(); backgroundError = error; errorLock.unlock() }
            backgroundFinished.signal()
        }
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: backgroundReady.path) }, timeout: 15), "Claude should report the outstanding background task before the scheduler tick.")
        _ = try runCLI(["schedule", "tick"], extraEnvironment: environment)
        XCTAssertTrue(((try runCLI(["task", "token-usage", backgroundTask])["result"] as? [String: Any])?["contextCompactions"] as? [[String: Any]])?.isEmpty == true)
        try Data().write(to: backgroundRelease)
        XCTAssertEqual(backgroundFinished.wait(timeout: .now() + 45), .success)
        errorLock.lock(); let finishedBackgroundError = backgroundError; errorLock.unlock()
        XCTAssertNil(finishedBackgroundError)

        let busyTask = try makeIdleTask("Busy compaction", root: fixture.primary.path)
        _ = try runCLI(["conversation", "send", busyTask, "--message", "Hello."], extraEnvironment: environment)
        _ = try runCLI(["conversation", "send", busyTask, "--message", "fill context to 180000 tokens 51 minutes ago"], extraEnvironment: environment)
        let readyURL = URL(fileURLWithPath: executable.path + ".concurrent-turn-ready")
        let releaseURL = URL(fileURLWithPath: executable.path + ".concurrent-turn-release")
        try? FileManager.default.removeItem(at: readyURL)
        try? FileManager.default.removeItem(at: releaseURL)
        let turnFinished = DispatchSemaphore(value: 0)
        var turnError: Error?
        DispatchQueue.global().async {
            do {
                _ = try self.runCLI(["conversation", "send", busyTask, "--message", "hold-claude-turn-for-concurrency"], extraEnvironment: environment)
            } catch {
                errorLock.lock(); turnError = error; errorLock.unlock()
            }
            turnFinished.signal()
        }
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: readyURL.path) }, timeout: 15), "The Claude provider turn should be active before scheduler evaluation.")
        _ = try runCLI(["schedule", "tick"], extraEnvironment: environment)
        XCTAssertTrue(((try runCLI(["task", "token-usage", busyTask])["result"] as? [String: Any])?["contextCompactions"] as? [[String: Any]])?.isEmpty == true)
        try Data().write(to: releaseURL)
        XCTAssertEqual(turnFinished.wait(timeout: .now() + 45), .success, "The held provider turn should settle after release.")
        errorLock.lock(); let heldTurnError = turnError; errorLock.unlock()
        XCTAssertNil(heldTurnError, "The held provider turn should finish successfully.")
    }
}
