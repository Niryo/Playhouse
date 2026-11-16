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
    // case-contract: test_claude_cold_resume_and_model_switch_compaction | A Claude session with more than the minimum context is compacted before the next real prompt after its cache has been idle for over 60 minutes, and again before a model switch. The cold-resume and model-switch triggers are persisted with context sizes, each `/compact` fixture turn precedes the real prompt, the visible maintenance rows precede their corresponding prompts, and a model switch runs `/compact` with the old model before the requested model starts. When the cache is expired and automatic compaction is disabled, the first resumed response with near-zero cache reads and a large cache write records one cache miss, visible in Token Stats. If Claude reports a compaction failure, the failed maintenance row is recorded, the event is marked unsuccessful, and the user's prompt still runs and appears in history. Failed attempts are labelled as failures in the conversation and Token Stats. Stopping during compaction prevents the submitted work from starting.
    func test_claude_cold_resume_and_model_switch_compaction() throws {
        var environment = try installClaudeFixture(named: "claude-fixture-ui-resume-compaction")
        environment["CLAUDE_CONFIG_DIR"] = dataDirectory.appendingPathComponent("claude-config").path
        environment["PLAYHOUSE_E2E_CLAUDE_FIXTURE_REPORT_OUTCOME"] = "1"
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: environment)
        let historyURL = URL(fileURLWithPath: environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"]!).appendingPathExtension("history")

        let coldTask = try XCTUnwrap((try runCLI([
            "task", "create", "--title", "Cold resume", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
        ])["result"] as? [String: Any])?["id"] as? String)
        XCTAssertTrue(app.buttons["Cold resume"].waitToExist(timeout: 10))
        _ = try runCLI(["conversation", "send", coldTask, "--message", "Hello."], extraEnvironment: environment)
        _ = try runCLI(["conversation", "send", coldTask, "--message", "fill context to 180000 tokens 61 minutes ago"], extraEnvironment: environment)
        _ = try runCLI(["conversation", "send", coldTask, "--message", "Resume after cache expiry."], extraEnvironment: environment)
        let coldUsage = try XCTUnwrap((try runCLI(["task", "token-usage", coldTask])["result"] as? [String: Any])?["contextCompactions"] as? [[String: Any]])
        XCTAssertEqual(coldUsage.last?["trigger"] as? String, "cold-resume")
        let coldHistory = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(contentsOf: historyURL)) as? [String: Any])?["turns"] as? [[String: Any]])
        let coldPromptIndex = try XCTUnwrap(coldHistory.firstIndex { ($0["userText"] as? String) == "Resume after cache expiry." })
        XCTAssertEqual(coldHistory[coldPromptIndex - 1]["userText"] as? String, "/compact")
        openTask(named: "Cold resume")
        let coldRow = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "context-compaction-row-", "Context compacted automatically"
        )).firstMatch
        XCTAssertTrue(scrollTranscriptUntilExists(coldRow), "The cold-resume compaction row should be present in the conversation.")
        XCTAssertTrue(coldRow.isHittable, "The compaction row must be visible before its screenshot.")
        let coldVisibleHistory = try XCTUnwrap(try runCLI(["conversation", "history", coldTask])["result"] as? [String: Any])
        let resumedPrompt = try XCTUnwrap((coldVisibleHistory["messages"] as? [[String: Any]])?.first {
            $0["role"] as? String == "user" && $0["text"] as? String == "Resume after cache expiry."
        })
        let resumedPromptRow = app.descendants(matching: .any).matching(identifier: "user-message-\(try XCTUnwrap(resumedPrompt["id"] as? String))").firstMatch
        XCTAssertTrue(scrollTranscriptUntilExists(resumedPromptRow), "The resumed prompt should be visible beside its compaction row.")
        XCTAssertTrue(coldRow.isHittable, "The cold-resume row must remain visible beside the prompt.")
        XCTAssertTrue(resumedPromptRow.isHittable, "The resumed prompt must be visible beside its compaction row.")
        XCTAssertLessThan(coldRow.frame.minY, resumedPromptRow.frame.minY, "The visible cold-resume compaction row must precede the resumed prompt.")
        attachScreenshot(named: "Cold-resume compaction appears in the conversation")
        attachElementScreenshot(coldRow, named: "Cold-resume compaction timeline row")

        let switchTask = try XCTUnwrap((try runCLI([
            "task", "create", "--title", "Model switch", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
        ])["result"] as? [String: Any])?["id"] as? String)
        _ = try runCLI(["conversation", "send", switchTask, "--message", "Hello.", "--model", "claude-haiku-4-5"], extraEnvironment: environment)
        _ = try runCLI(["conversation", "send", switchTask, "--message", "fill context to 180000 tokens", "--model", "claude-haiku-4-5"], extraEnvironment: environment)
        _ = try runCLI(["conversation", "send", switchTask, "--message", "Switch models now.", "--model", "claude-sonnet-4-6"], extraEnvironment: environment)
        let switchUsage = try XCTUnwrap((try runCLI(["task", "token-usage", switchTask])["result"] as? [String: Any])?["contextCompactions"] as? [[String: Any]])
        XCTAssertEqual(switchUsage.last?["trigger"] as? String, "model-switch")
        let switchHistory = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(contentsOf: historyURL)) as? [String: Any])?["turns"] as? [[String: Any]])
        let promptIndex = try XCTUnwrap(switchHistory.firstIndex { ($0["userText"] as? String) == "Switch models now." })
        let compact = switchHistory[promptIndex - 1]
        XCTAssertEqual(compact["userText"] as? String, "/compact")
        let compactArgs = try XCTUnwrap(compact["arguments"] as? [String])
        XCTAssertEqual(compactArgs[compactArgs.firstIndex(of: "--model")! + 1], "claude-haiku-4-5")
        let promptArgs = try XCTUnwrap(switchHistory[promptIndex]["arguments"] as? [String])
        XCTAssertEqual(promptArgs[promptArgs.firstIndex(of: "--model")! + 1], "claude-sonnet-4-6")
        openTask(named: "Model switch")
        let switchRow = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "context-compaction-row-", "Context compacted automatically"
        )).firstMatch
        XCTAssertTrue(scrollTranscriptUntilExists(switchRow), "The model-switch compaction row should be present in the conversation.")
        XCTAssertTrue(switchRow.isHittable, "The compaction row must be visible before its screenshot.")
        let switchVisibleHistory = try XCTUnwrap(try runCLI(["conversation", "history", switchTask])["result"] as? [String: Any])
        let switchedPrompt = try XCTUnwrap((switchVisibleHistory["messages"] as? [[String: Any]])?.first {
            $0["role"] as? String == "user" && $0["text"] as? String == "Switch models now."
        })
        let switchedPromptRow = app.descendants(matching: .any).matching(identifier: "user-message-\(try XCTUnwrap(switchedPrompt["id"] as? String))").firstMatch
        XCTAssertTrue(scrollTranscriptUntilExists(switchedPromptRow), "The model-switch prompt should be visible beside its compaction row.")
        XCTAssertTrue(switchRow.isHittable, "The model-switch row must remain visible beside the prompt.")
        XCTAssertTrue(switchedPromptRow.isHittable, "The model-switch prompt must be visible beside its compaction row.")
        XCTAssertLessThan(switchRow.frame.minY, switchedPromptRow.frame.minY, "The visible model-switch compaction row must precede its prompt.")
        attachScreenshot(named: "Model-switch compaction row in conversation")
        attachElementScreenshot(switchRow, named: "Model-switch compaction timeline row")

        try runCLI(["settings", "set-auto-compaction", "--enabled", "false"])
        let cacheEnvironment = environment.merging(["PLAYHOUSE_E2E_CLAUDE_FIXTURE_CACHE_MISS": "1"]) { _, new in new }
        let cacheTask = try XCTUnwrap((try runCLI([
            "task", "create", "--title", "Resume cache miss", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
        ])["result"] as? [String: Any])?["id"] as? String)
        _ = try runCLI(["conversation", "send", cacheTask, "--message", "Hello."], extraEnvironment: cacheEnvironment)
        _ = try runCLI(["conversation", "send", cacheTask, "--message", "fill context to 180000 tokens 61 minutes ago"], extraEnvironment: cacheEnvironment)
        _ = try runCLI(["conversation", "send", cacheTask, "--message", "Resume with a cold cache."], extraEnvironment: cacheEnvironment)
        let cacheUsage = try XCTUnwrap((try runCLI(["task", "token-usage", cacheTask])["result"] as? [String: Any]))
        let cacheMisses = try XCTUnwrap(cacheUsage["promptCacheMisses"] as? [[String: Any]])
        XCTAssertEqual(cacheMisses.count, 1)
        XCTAssertEqual(cacheMisses.first?["cacheReadTokens"] as? Int, 0)
        XCTAssertEqual(cacheMisses.first?["cacheWriteTokens"] as? Int, 250000)
        openTask(named: "Resume cache miss")
        returnToBoard()
        element("task-token-usage-counter-\(cacheTask)").click()
        let cacheMissStat = app.staticTexts["token-stats-resume-cache-miss-0"]
        XCTAssertTrue(cacheMissStat.waitToExist(timeout: 10), "Token Stats should expose the cold-resume cache miss.")
        let cacheMissStatText = pluginText(cacheMissStat).localizedLowercase
        XCTAssertTrue(cacheMissStatText.contains("resume cache miss"))
        XCTAssertTrue(cacheMissStatText.contains("cache read 0 tokens"))
        XCTAssertTrue(cacheMissStatText.contains("250,000"), "The full rewritten-token count should remain accessible.")
        attachScreenshot(named: "Token Stats records a resume cache miss")
        attachElementScreenshot(cacheMissStat, named: "Token Stats shows a resumed cache miss")
        element("close-token-stats-button").click()

        try runCLI(["settings", "set-auto-compaction", "--enabled", "true"])
        let executable = URL(fileURLWithPath: environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"]!)
        let failureMarker = URL(fileURLWithPath: executable.path + ".compact-fail")
        try Data().write(to: failureMarker)
        let failureTask = try XCTUnwrap((try runCLI([
            "task", "create", "--title", "Failed Claude compaction", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
        ])["result"] as? [String: Any])?["id"] as? String)
        _ = try runCLI(["conversation", "send", failureTask, "--message", "Hello."], extraEnvironment: environment)
        _ = try runCLI(["conversation", "send", failureTask, "--message", "fill context to 180000 tokens 61 minutes ago"], extraEnvironment: environment)
        _ = try runCLI(["conversation", "send", failureTask, "--message", "Continue after failed compaction."], extraEnvironment: environment)
        try? FileManager.default.removeItem(at: failureMarker)
        let failedEvents = try XCTUnwrap((try runCLI(["task", "token-usage", failureTask])["result"] as? [String: Any])?["contextCompactions"] as? [[String: Any]])
        XCTAssertEqual(failedEvents.last?["trigger"] as? String, "cold-resume")
        XCTAssertEqual(failedEvents.last?["succeeded"] as? Bool, false)
        let failedHistory = try XCTUnwrap((try runCLI(["conversation", "history", failureTask])["result"] as? [String: Any]))
        let failedRow = try XCTUnwrap((failedHistory["activities"] as? [[String: Any]])?.first { $0["isContextCompaction"] as? Bool == true })
        XCTAssertEqual(failedRow["status"] as? String, "failed")
        XCTAssertTrue((failedHistory["messages"] as? [[String: Any]] ?? []).contains { $0["text"] as? String == "Continue after failed compaction." })
        openTask(named: "Failed Claude compaction")
        let failedCompactionRow = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "context-compaction-row-", "Automatic context compaction failed"
        )).firstMatch
        XCTAssertTrue(scrollTranscriptUntilExists(failedCompactionRow), "The failed compaction row should be present in the conversation.")
        XCTAssertTrue(failedCompactionRow.isHittable, "The compaction row must be visible before its screenshot.")
        attachScreenshot(named: "Failed Claude compaction row in conversation")
        attachElementScreenshot(failedCompactionRow, named: "Failed automatic compaction timeline row")
        returnToBoard()
        element("task-token-usage-counter-\(failureTask)").click()
        let failedStat = app.staticTexts["token-stats-compaction-0"]
        XCTAssertTrue(failedStat.waitToExist(timeout: 10))
        XCTAssertTrue(pluginText(failedStat).contains("Compaction failed"))
        attachElementScreenshot(failedStat, named: "Token Stats identifies a failed compaction")
        element("close-token-stats-button").click()

        _ = try runCLI(["conversation", "send", failureTask, "--message", "fill context to 180000 tokens 61 minutes ago"], extraEnvironment: environment)
        let hold = URL(fileURLWithPath: executable.path + ".compact-hold")
        let ready = URL(fileURLWithPath: executable.path + ".compact-ready")
        try Data().write(to: hold)
        defer { try? FileManager.default.removeItem(at: hold) }
        let stoppedSend = try startCLIProcess(["conversation", "send", failureTask, "--message", "Must not run after Stop."], extraEnvironment: environment)
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: ready.path) }, timeout: 15))
        _ = try runCLI(["conversation", "stop", failureTask], extraEnvironment: environment)
        _ = try finishCLIProcess(stoppedSend, expectedStatus: 1)
        let stoppedHistory = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(contentsOf: historyURL)) as? [String: Any])?["turns"] as? [[String: Any]])
        XCTAssertFalse(stoppedHistory.contains { $0["userText"] as? String == "Must not run after Stop." })
        XCTAssertEqual((try runCLI(["task", "get", failureTask])["result"] as? [String: Any])?["status"] as? String, "Waiting Response")

    }
    // case-contract: test_codex_context_compaction_threshold_and_model_switch | With a configured 100,000-token threshold and 150,000-token minimum, a Codex task reporting 120,000 context tokens calls thread/compact/start before its next prompt, records one successful automatic threshold event with a labelled activity, and adds no empty assistant turn. After a same-model turn records 220,000 context tokens, switching models compacts through the RPC first, records the old model and model-switch trigger, and waits for the matching successful terminal notification before turn/start. A failure after the initial acknowledgment is recorded as unsuccessful while the prompt still runs. If the app-server rejects compaction, Playhouse records a failed activity and event but continues the prompt. Codex uses reported context and model changes; its path does not depend on Claude's prompt-cache TTL or warm-idle scheduler.
    func test_codex_context_compaction_threshold_and_model_switch() throws {
        let executable = dataDirectory.appendingPathComponent("codex-fixture-ui-auto-threshold")
        try copyFixtureFile(at: WorkspaceFixture.root.appendingPathComponent("codex-fixture-ui"), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data("Playhouse test owns this Codex protocol fixture (v1).\n".utf8)
            .write(to: dataDirectory.appendingPathComponent(".playhouse-codex-fixture-owner"))
        codexFixtureExecutable = executable.path
        let environment = ["PLAYHOUSE_E2E_CODEX_EXECUTABLE": executable.path, "PLAYHOUSE_E2E_CODEX_CONTEXT_TOKENS": "120000"]
        let contextTokensFile = URL(fileURLWithPath: executable.path + ".context-tokens")
        try Data("120000".utf8).write(to: contextTokensFile)
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: environment)
        _ = try runCLI(["settings", "set-auto-compaction", "--threshold", "100000", "--minimum", "150000"])
        let taskID = try XCTUnwrap((try runCLI([
            "task", "create", "--title", "Codex threshold compaction", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "codex",
        ])["result"] as? [String: Any])?["id"] as? String)
        XCTAssertTrue(app.buttons["Codex threshold compaction"].waitToExist(timeout: 10))
        _ = try runCLI(["conversation", "send", taskID, "--message", "First Codex turn.", "--model", "gpt-6-sol"], extraEnvironment: environment)
        _ = try runCLI(["conversation", "send", taskID, "--message", "Continue after the context threshold.", "--model", "gpt-6-sol"], extraEnvironment: environment)
        let compactions = try XCTUnwrap((try runCLI(["task", "token-usage", taskID])["result"] as? [String: Any])?["contextCompactions"] as? [[String: Any]])
        XCTAssertEqual(compactions.count, 1)
        XCTAssertEqual(compactions.first?["provider"] as? String, "codex")
        XCTAssertEqual(compactions.first?["trigger"] as? String, "threshold")
        XCTAssertEqual(compactions.first?["preTokens"] as? Int, 120000)
        let thresholdHistory = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
        let thresholdMessages = try XCTUnwrap(thresholdHistory["messages"] as? [[String: Any]])
        XCTAssertFalse(thresholdMessages.contains {
            ($0["role"] as? String) == "assistant" && (($0["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }, "Codex compaction must not add an empty assistant message.")
        let thresholdOrder = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: executable.path + ".history"))) as? [String: Any]
        XCTAssertEqual((thresholdOrder?["rpcOrder"] as? [[String: String]] ?? []).map { $0["method"] ?? "" },
                       ["turn/start", "thread/compact/start", "compaction/completed", "turn/start"],
                       "Codex compaction must finish before the next turn starts.")
        openTask(named: "Codex threshold compaction")
        let row = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "context-compaction-row-", "Context compacted automatically"
        )).firstMatch
        XCTAssertTrue(scrollTranscriptUntilExists(row), "The Codex threshold compaction row should be present in the conversation.")
        XCTAssertTrue(row.isHittable, "The compaction row must be visible before its screenshot.")
        XCTAssertTrue(row.label.contains("threshold"))
        let thresholdPrompt = try XCTUnwrap(thresholdMessages.first {
            $0["role"] as? String == "user" && $0["text"] as? String == "Continue after the context threshold."
        })
        let thresholdPromptRow = app.descendants(matching: .any).matching(identifier: "user-message-\(try XCTUnwrap(thresholdPrompt["id"] as? String))").firstMatch
        XCTAssertTrue(scrollTranscriptUntilExists(thresholdPromptRow), "The Codex prompt should be visible beside its compaction row.")
        XCTAssertTrue(row.isHittable, "The Codex compaction row must remain visible beside the prompt.")
        XCTAssertTrue(thresholdPromptRow.isHittable, "The Codex prompt must be visible beside its compaction row.")
        XCTAssertLessThan(row.frame.minY, thresholdPromptRow.frame.minY, "The visible Codex compaction row must precede the prompt.")
        attachScreenshot(named: "Codex threshold compaction appears in the conversation")
        attachElementScreenshot(row, named: "Codex automatic threshold compaction row")
        returnToBoard()
        element("task-token-usage-counter-\(taskID)").click()
        let stat = app.staticTexts["token-stats-compaction-0"]
        XCTAssertTrue(stat.waitToExist(timeout: 10))
        XCTAssertTrue(accessibleLabelOrValue(of: stat).contains("threshold"))
        attachScreenshot(named: "Token Stats lists Codex threshold compaction")
        attachElementScreenshot(stat, named: "Codex threshold trigger in Token Stats")
        element("close-token-stats-button").click()

        try Data("220000".utf8).write(to: contextTokensFile)
        _ = try runCLI(["settings", "set-auto-compaction", "--threshold", "300000", "--minimum", "150000"])
        _ = try runCLI(["conversation", "send", taskID, "--message", "Grow context before switching models.", "--model", "gpt-6-sol"], extraEnvironment: environment)
        let firstHistory = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: executable.path + ".history"))) as? [String: Any]
        let switchOrderCount = (firstHistory?["rpcOrder"] as? [[String: Any]])?.count ?? 0
        _ = try runCLI(["conversation", "send", taskID, "--message", "Switch to Luna.", "--model", "gpt-6-luna"], extraEnvironment: environment)
        let switchEvents = try XCTUnwrap((try runCLI(["task", "token-usage", taskID])["result"] as? [String: Any])?["contextCompactions"] as? [[String: Any]])
        XCTAssertEqual(switchEvents.last?["trigger"] as? String, "model-switch")
        XCTAssertEqual(switchEvents.last?["model"] as? String, "gpt-6-sol")
        XCTAssertEqual(switchEvents.last?["preTokens"] as? Int, 220000)
        let history = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: executable.path + ".history"))) as? [String: Any]
        let methods = (history?["rpcOrder"] as? [[String: String]] ?? []).map { $0["method"] ?? "" }
        XCTAssertEqual(Array(methods.dropFirst(switchOrderCount)), ["thread/compact/start", "compaction/completed", "turn/start"])
        openTask(named: "Codex threshold compaction")
        let switchRow = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "context-compaction-row-", "Model switch"
        )).firstMatch
        XCTAssertTrue(scrollTranscriptUntilExists(switchRow), "The model-switch compaction row should be present in the conversation.")
        XCTAssertTrue(switchRow.isHittable, "The compaction row must be visible before its screenshot.")
        let switchConversationHistory = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
        let switchPrompt = try XCTUnwrap((switchConversationHistory["messages"] as? [[String: Any]])?.first {
            $0["role"] as? String == "user" && $0["text"] as? String == "Switch to Luna."
        })
        let switchPromptRow = app.descendants(matching: .any).matching(identifier: "user-message-\(try XCTUnwrap(switchPrompt["id"] as? String))").firstMatch
        XCTAssertTrue(scrollTranscriptUntilExists(switchPromptRow), "The Codex model-switch prompt should be visible beside its compaction row.")
        XCTAssertTrue(switchRow.isHittable, "The Codex model-switch row must remain visible beside the prompt.")
        XCTAssertTrue(switchPromptRow.isHittable, "The Codex model-switch prompt must be visible beside its compaction row.")
        XCTAssertLessThan(switchRow.frame.minY, switchPromptRow.frame.minY, "The visible Codex model-switch row must precede its prompt.")
        attachScreenshot(named: "Codex model-switch compaction row in conversation")
        attachElementScreenshot(switchRow, named: "Codex model-switch compaction row")

        let failureMarker = URL(fileURLWithPath: executable.path + ".compact-fail")
        try Data().write(to: failureMarker)
        let failureOrderCount = methods.count
        _ = try runCLI(["conversation", "send", taskID, "--message", "Continue after failed compaction.", "--model", "gpt-6-sol"], extraEnvironment: environment)
        try? FileManager.default.removeItem(at: failureMarker)
        let failureEvents = try XCTUnwrap((try runCLI(["task", "token-usage", taskID])["result"] as? [String: Any])?["contextCompactions"] as? [[String: Any]])
        XCTAssertEqual(failureEvents.last?["succeeded"] as? Bool, false)
        let failureHistory = try XCTUnwrap((try runCLI(["conversation", "history", taskID])["result"] as? [String: Any]))
        let failureActivity = try XCTUnwrap((failureHistory["activities"] as? [[String: Any]])?.first {
            $0["title"] as? String == "Automatic context compaction failed" && $0["status"] as? String == "failed"
        })
        XCTAssertEqual(failureActivity["status"] as? String, "failed")
        XCTAssertTrue((failureHistory["messages"] as? [[String: Any]] ?? []).contains { $0["text"] as? String == "Continue after failed compaction." })
        let failureOrder = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: executable.path + ".history"))) as? [String: Any]
        XCTAssertEqual(Array(((failureOrder?["rpcOrder"] as? [[String: String]]) ?? []).map { $0["method"] ?? "" }.dropFirst(failureOrderCount)),
                       ["thread/compact/start", "turn/start"])
        openTask(named: "Codex threshold compaction")
        let failureRow = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "context-compaction-row-", "Automatic context compaction failed"
        )).firstMatch
        XCTAssertTrue(scrollTranscriptUntilExists(failureRow), "The failed Codex compaction row should be present in the conversation.")
        XCTAssertTrue(failureRow.isHittable, "The compaction row must be visible before its screenshot.")
        attachScreenshot(named: "Codex failed compaction row in conversation")
        attachElementScreenshot(failureRow, named: "Codex compaction failure timeline row")
        let terminalFailure = URL(fileURLWithPath: executable.path + ".compact-terminal-fail")
        try Data().write(to: terminalFailure)
        defer { try? FileManager.default.removeItem(at: terminalFailure) }
        _ = try runCLI(["conversation", "send", taskID, "--message", "Continue after asynchronous failure.", "--model", "gpt-6-luna"], extraEnvironment: environment)
        let terminalEvents = try XCTUnwrap((try runCLI(["task", "token-usage", taskID])["result"] as? [String: Any])?["contextCompactions"] as? [[String: Any]])
        XCTAssertEqual(terminalEvents.count, failureEvents.count + 1)
        XCTAssertEqual(terminalEvents.last?["succeeded"] as? Bool, false)
        let terminalHistory = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
        XCTAssertTrue((terminalHistory["messages"] as? [[String: Any]] ?? []).contains { $0["text"] as? String == "Continue after asynchronous failure." })

    }
    // case-contract: test_claude_compaction_shows_one_row | A Claude compaction is one conversation row. A threshold compaction whose start Claude Code reports twice under different ids before its boundary leaves exactly one completed compaction row in the latest turn's history, with no row still in progress. A compaction that starts before the daemon is killed and ends after it, so its boundary reaches a daemon that never saw the row reported for its start, shows one in-progress row while the turn runs, before and after the restart, then one completed row with its context sizes as soon as the boundary arrives while the turn is still running, and records one compaction event. A long turn that compacts twice shows each compaction where it happened: the first after the text and tool call written before it and before the summary message Claude Code continues from, the second between the messages written after the first and its own summary, never stacked after the turn's last message. Compaction rows stored without the message they follow are placed the same way, by when each compaction finished.
    func test_claude_compaction_shows_one_row() throws {
        func compactionRows(_ taskID: String, environment: [String: String] = [:]) throws -> [[String: Any]] {
            let history = try XCTUnwrap(try runCLI(["conversation", "history", taskID], extraEnvironment: environment)["result"] as? [String: Any])
            return (history["activities"] as? [[String: Any]] ?? []).filter { $0["isContextCompaction"] as? Bool == true }
        }

        var thresholdEnvironment = try installClaudeFixture(named: "claude-fixture-ui-compaction-rows")
        thresholdEnvironment["CLAUDE_CONFIG_DIR"] = dataDirectory.appendingPathComponent("claude-config").path
        let executable = WorkspaceFixture.root.appendingPathComponent("claude-fixture-reattach").path
        claudeFixtureExecutable = executable
        clearReattachMarkers(executable)
        let environment = restartServiceEnvironment()
        let thresholdTask = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Repeated compaction start", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
        ])["result"] as? [String: Any])
        let thresholdTaskID = try XCTUnwrap(thresholdTask["id"] as? String)
        _ = try runCLI(["conversation", "send", thresholdTaskID, "--message", "Hello."], extraEnvironment: thresholdEnvironment)
        _ = try runCLI(["conversation", "send", thresholdTaskID, "--message", "fill context to 210000 tokens"], extraEnvironment: thresholdEnvironment)
        let thresholdRows = try compactionRows(thresholdTaskID)
        XCTAssertEqual(thresholdRows.map { $0["status"] as? String }, ["completed"], "The latest turn's compaction is one row: \(thresholdRows)")
        let thresholdDetails = thresholdRows.first?["compaction"] as? [String: Any]
        XCTAssertEqual(thresholdDetails?["preTokens"] as? Int, 210000)
        XCTAssertEqual(thresholdDetails?["postTokens"] as? Int, 6000)
        let thresholdUsage = try XCTUnwrap(try runCLI(["task", "token-usage", thresholdTaskID])["result"] as? [String: Any])
        XCTAssertEqual((thresholdUsage["contextCompactions"] as? [[String: Any]])?.count, 1)

        // A long turn that compacts twice keeps each row where it happened, not stacked after its last message.
        // The second task's rows are stored the way rows recorded before they kept the message they follow were.
        var longTurns: [(title: String, firstRowID: String, secondRowID: String, answer: String)] = []
        for title in ["Compaction mid turn", "Stored compaction mid turn"] {
            let longTask = try XCTUnwrap(try runCLI([
                "task", "create", "--title", title, "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
            ])["result"] as? [String: Any])
            let longTaskID = try XCTUnwrap(longTask["id"] as? String)
            _ = try runCLI(["conversation", "send", longTaskID, "--message", "compact twice mid turn"], extraEnvironment: thresholdEnvironment)
            let longRows = try compactionRows(longTaskID)
            XCTAssertEqual(longRows.map { $0["status"] as? String }, ["completed", "completed"], "Each compaction of the turn is one row: \(longRows)")
            func longRowID(preTokens: Int) throws -> String {
                try XCTUnwrap(longRows.first { ($0["compaction"] as? [String: Any])?["preTokens"] as? Int == preTokens }?["id"] as? String)
            }
            let longHistory = try XCTUnwrap(try runCLI(["conversation", "history", longTaskID])["result"] as? [String: Any])
            let answer = try XCTUnwrap((longHistory["messages"] as? [[String: Any]] ?? []).last {
                $0["role"] as? String == "assistant" && $0["phase"] as? String == "final_answer"
            }?["text"] as? String, "The turn ends with an answer.")
            longTurns.append((title, try longRowID(preTokens: 170000), try longRowID(preTokens: 168000), answer))
        }
        let storedTaskID = try XCTUnwrap(try conversationRows(
            "SELECT DISTINCT task_id FROM conversation_activities WHERE id = '\(longTurns[1].firstRowID)'"
        ).first?.first ?? nil)
        var strippedRows = 0
        for row in try conversationRows("SELECT turn_id, id, payload FROM conversation_activities WHERE task_id = '\(storedTaskID)'") {
            guard let turnID = row[0], let rowID = row[1], let payload = row[2],
                  var activity = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                  activity["isContextCompaction"] as? Bool == true else { continue }
            XCTAssertNotNil(activity.removeValue(forKey: "afterMessageID"), "A new compaction row records the message it follows.")
            let stripped = String(decoding: try JSONSerialization.data(withJSONObject: activity), as: UTF8.self)
            strippedRows += 1
            try conversationExecute("""
                UPDATE conversation_activities SET payload = '\(stripped.replacingOccurrences(of: "'", with: "''"))'
                WHERE task_id = '\(storedTaskID)' AND turn_id = '\(turnID)' AND id = '\(rowID)'
                """)
        }
        XCTAssertEqual(strippedRows, 2)

        let task = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Compaction across a restart", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(task["id"] as? String)
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: environment)
        let visibleRows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "context-compaction-row-"))
        let spinningRows = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "context-compaction-row-", "In progress"
        ))
        openTask(named: "Repeated compaction start")
        XCTAssertTrue(visibleRows.firstMatch.waitToExist(timeout: 10), "The threshold compaction is shown in the conversation.")
        XCTAssertEqual(visibleRows.count, 1, "The latest turn's compaction is drawn once.")
        XCTAssertEqual(spinningRows.count, 0, "No compaction row is left in progress.")
        attachScreenshot(named: "compaction-rows-1-threshold-compaction-once")
        attachElementScreenshot(visibleRows.firstMatch, named: "compaction-rows-1-threshold-row")

        returnToBoard()
        for (index, longTurn) in longTurns.enumerated() {
            openTask(named: longTurn.title)
            let firstRow = app.descendants(matching: .any)["context-compaction-row-\(longTurn.firstRowID)"]
            let secondRow = app.descendants(matching: .any)["context-compaction-row-\(longTurn.secondRowID)"]
            let firstSummary = app.groups.matching(NSPredicate(format: "label CONTAINS %@", "Continued after the first compaction.")).firstMatch
            let secondSummary = app.groups.matching(NSPredicate(format: "label CONTAINS %@", "Continued after the second compaction.")).firstMatch
            XCTAssertTrue(secondSummary.waitToExist(timeout: 10), "\(longTurn.title): the turn's messages after its compactions are shown.")
            XCTAssertTrue(firstRow.waitToExist(timeout: 5) && secondRow.exists, "\(longTurn.title): both compactions of the turn are shown.")
            XCTAssertEqual(visibleRows.count, 2, "\(longTurn.title): each compaction of the turn is drawn once.")
            XCTAssertLessThan(transcriptMessage("compact twice mid turn").frame.minY, firstRow.frame.minY, "\(longTurn.title): the first compaction follows the prompt.")
            XCTAssertLessThan(firstRow.frame.minY, firstSummary.frame.minY, "\(longTurn.title): the first compaction comes before the message it was summarized into.")
            XCTAssertLessThan(firstSummary.frame.minY, secondRow.frame.minY, "\(longTurn.title): the second compaction follows the messages written after the first one.")
            XCTAssertLessThan(secondRow.frame.minY, secondSummary.frame.minY, "\(longTurn.title): the second compaction comes before the message it was summarized into.")
            // The text and tool calls written before each compaction are the finished turn's progress, folded
            // into its activity disclosure; the history order the CLI asserts places each row after them.
            XCTAssertTrue(transcriptMessage(longTurn.answer).waitToExist(timeout: 5), "\(longTurn.title): the turn's answer is shown.")
            XCTAssertLessThan(secondSummary.frame.minY, transcriptMessage(longTurn.answer).frame.minY,
                              "\(longTurn.title): the turn's answer follows its compactions instead of the compactions stacking after it.")
            attachScreenshot(named: index == 0 ? "compaction-rows-2-compactions-in-turn-order" : "compaction-rows-2-stored-compactions-in-turn-order")
            returnToBoard()
        }
        openTask(named: "Compaction across a restart")
        touch(executable + ".reattach-compact")
        sendFromComposer("Compact across a restart.")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: executable + ".reattach-ready") }, timeout: 20))
        XCTAssertTrue(spinningRows.firstMatch.waitToExist(timeout: 15), "The compaction start shows a compacting row.")
        XCTAssertTrue(waitUntil({ ((try? compactionRows(taskID, environment: environment)) ?? []).map { $0["status"] as? String } == ["inProgress"] }, timeout: 15),
                      "The compaction start is recorded once before the restart.")
        XCTAssertEqual(visibleRows.count, 1, "The running compaction is drawn once.")
        attachScreenshot(named: "compaction-rows-3-compacting-before-restart")
        attachElementScreenshot(spinningRows.firstMatch, named: "compaction-rows-3-compacting-row")

        try killDaemon(environment: environment)
        // The window reconnects; the fresh daemon follows the still compacting turn.
        XCTAssertTrue(waitForStatus(taskID, "In Progress", environment: environment))
        XCTAssertEqual(try compactionRows(taskID, environment: environment).map { $0["status"] as? String }, ["inProgress"],
                       "While the turn runs, its compaction is one in-progress row.")
        XCTAssertTrue(spinningRows.firstMatch.waitToExist(timeout: 10), "The reconnected window still shows the compacting row.")
        XCTAssertEqual(visibleRows.count, 1, "The reconnected window draws the running compaction once.")
        XCTAssertEqual(spinningRows.count, 1)
        // Only the next daemon reads the boundary; the turn keeps running after it.
        touch(executable + ".reattach-compact-end")
        // The turn holds until its release, so only the streamed boundary can end the row here.
        XCTAssertTrue(waitUntil({ spinningRows.count == 0 }, timeout: 20), "The boundary ends the live compacting row.")
        let running = try XCTUnwrap(try runCLI(["task", "get", taskID], extraEnvironment: environment)["result"] as? [String: Any])
        XCTAssertEqual(running["status"] as? String, "In Progress", "The turn is still running after the boundary.")
        XCTAssertEqual(visibleRows.count, 1, "The live window shows the compaction as one row after its boundary.")
        attachScreenshot(named: "compaction-rows-4-completed-while-running")
        attachElementScreenshot(visibleRows.firstMatch, named: "compaction-rows-4-completed-row")
        touch(executable + ".reattach-release")
        XCTAssertTrue(transcriptMessage("After restart.").waitToExist(timeout: 20), "The window streams the end of the reattached turn.")
        XCTAssertEqual(visibleRows.count, 1, "The finished turn still shows the compaction once.")
        XCTAssertEqual(spinningRows.count, 0)
        let rows = try compactionRows(taskID, environment: environment)
        XCTAssertEqual(rows.map { $0["status"] as? String }, ["completed"], "No compaction row is left spinning: \(rows)")
        let details = rows.first?["compaction"] as? [String: Any]
        XCTAssertEqual(details?["preTokens"] as? Int, 190000)
        XCTAssertEqual(details?["postTokens"] as? Int, 6000)
        let usage = try XCTUnwrap(try runCLI(["task", "token-usage", taskID], extraEnvironment: environment)["result"] as? [String: Any])
        XCTAssertEqual((usage["contextCompactions"] as? [[String: Any]])?.count, 1, "The compaction is recorded once.")
    }
    // case-contract: test_claude_long_automatic_notice_is_compact | A Claude Code synthetic notice longer than the automatic message preview stays whole: the streamed steered message and fresh CLI/XPC history carry every line of it under the Claude Code notice marker, between the turn's answer and Claude's reply, and a short notice is recorded unchanged too. In the transcript the long notice renders as an automatic message from Claude Code collapsed to an eight-line preview ending in an ellipsis, with a Show more control whose accessibility label names expanding the automatic message; expanding the streamed notice while its turn still runs reveals all of its text and survives the reload that gives it its history id and the reload after a later turn, and collapsing restores the preview. A short notice shows in full with no control or preview, the user's own prompts never get one, the bubble's accessibility label keeps the full text, and reopening the task shows the long notice collapsed again. The preview is Playhouse-owned presentation shared by every automatic message whatever the provider, and only Claude Code injects a synthetic message inside a turn, so Claude is the representative provider.
    func test_claude_long_automatic_notice_is_compact() throws {
        let environment = try installClaudeFixture(named: "claude-fixture-ui-long-notice")
        let executable = dataDirectory.appendingPathComponent("claude-fixture-ui-long-notice")
        let task = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Long handoff notice", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(task["id"] as? String)
        let longPrompt = "Hand off with a long Claude Code notice."
        let shortPrompt = "Hand off with a short Claude Code notice."
        let shortNotice = "[Your previous response had no visible output. Please continue and produce a user-visible response.]"
        func historyMessageID(_ predicate: ([String: Any]) -> Bool) throws -> String {
            let history = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
            return try XCTUnwrap((history["messages"] as? [[String: Any]] ?? []).last(where: predicate)?["id"] as? String)
        }
        func sendTurn(_ prompt: String, count: Int) {
            sendFromComposer(prompt)
            XCTAssertTrue(waitUntil({
                self.fixtureTurnCount(executable, containing: prompt) == count && self.noTurnIsRunning()
            }, timeout: 30), "The turn \(prompt) should finish.")
        }

        // A short notice, loaded from history: whole, with no preview and no control.
        _ = try runCLI(["conversation", "send", taskID, "--message", shortPrompt], extraEnvironment: environment)
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Long handoff notice")
        let toggles = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "automatic-message-toggle-"))
        try assertAutomaticMessageBubble(taskID: taskID, containing: shortNotice, sender: "Claude Code")
        let shortID = try historyMessageID { ($0["text"] as? String ?? "").contains(shortNotice) }
        XCTAssertTrue(waitUntil({ !self.element("automatic-message-preview-\(shortID)").exists }, timeout: 5),
                      "A notice that fits the preview shows in full, with no misleading ellipsis.")
        XCTAssertFalse(element("automatic-message-toggle-\(shortID)").exists, "A short notice has no expand control.")

        // A long notice, streamed into the open task while its turn still runs: collapsed to its preview.
        let hold = executable.path + ".handoff-notice"
        touch(hold + "-pause")
        sendFromComposer(longPrompt)
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: hold + "-ready") }, timeout: 20), "The fixture holds the turn after the notice.")
        let streamedToggle = toggles.firstMatch
        let streamedPreview = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "automatic-message-preview-")).firstMatch
        XCTAssertTrue(streamedToggle.waitToExist(timeout: 10), "The streamed long notice offers an expand control.")
        XCTAssertTrue(streamedPreview.exists, "The streamed long notice starts collapsed to its preview.")
        XCTAssertEqual(streamedToggle.label, "Expand automatic message to show all text")
        XCTAssertEqual(streamedToggle.value as? String, "collapsed")
        // Eight 16-point lines with their spacing, never the notice's 25 lines.
        XCTAssertGreaterThan(streamedPreview.frame.height, 120, "The preview shows several lines: \(streamedPreview.frame)")
        XCTAssertLessThan(streamedPreview.frame.height, 240, "The preview stops at eight lines: \(streamedPreview.frame)")
        attachScreenshot(named: "long-notice-1-collapsed-while-streaming")
        let streamedToggleID = streamedToggle.identifier
        streamedToggle.click()
        XCTAssertTrue(waitUntil({ !streamedPreview.exists && (streamedToggle.value as? String) == "expanded" }, timeout: 5),
                      "Expanding the streamed notice shows all of it.")
        attachScreenshot(named: "long-notice-2-expanded-while-streaming")

        // Releasing the turn ends it; the reload gives the notice its history id and keeps it expanded.
        touch(hold + "-release")
        XCTAssertTrue(waitUntil({
            self.fixtureTurnCount(executable, containing: longPrompt) == 1 && self.noTurnIsRunning()
        }, timeout: 30), "The long notice turn should finish.")
        for suffix in ["-pause", "-ready", "-release"] { try? FileManager.default.removeItem(atPath: hold + suffix) }
        let longBubble = try assertAutomaticMessageBubble(taskID: taskID, containing: "Handoff context ends here.", sender: "Claude Code")
        let longID = try historyMessageID { ($0["text"] as? String ?? "").contains("Handoff context ends here.") }
        XCTAssertTrue(longBubble.label.contains("Handoff context line 01:") && longBubble.label.contains("Handoff context ends here."),
                      "The bubble's accessibility label keeps the whole notice: \(longBubble.label)")
        XCTAssertFalse(transcriptContains("Claude Code automatic notice:"), "The notice's marker line is never shown.")
        let preview = element("automatic-message-preview-\(longID)")
        let toggle = element("automatic-message-toggle-\(longID)")
        XCTAssertTrue(toggle.waitToExist(timeout: 10), "The reloaded notice keeps its control.")
        XCTAssertNotEqual(streamedToggleID, "automatic-message-toggle-\(longID)", "The notice was expanded under its streamed id, before history gave it its own.")
        XCTAssertEqual(toggle.value as? String, "expanded", "Expanding the streamed notice survives the turn's reload.")
        XCTAssertEqual(toggle.label, "Collapse automatic message")
        XCTAssertFalse(preview.exists)
        let expandedHeight = longBubble.frame.height
        attachElementScreenshot(longBubble, named: "long-notice-3-expanded-bubble")

        toggle.click()
        XCTAssertTrue(waitUntil({ preview.exists && (toggle.value as? String) == "collapsed" }, timeout: 5), "Collapsing restores the preview.")
        XCTAssertEqual(toggle.label, "Expand automatic message to show all text")
        XCTAssertLessThan(longBubble.frame.height, expandedHeight - 250, "The collapsed notice hides most of its lines.")
        XCTAssertLessThan(preview.frame.height, 240, "The preview stops at eight lines: \(preview.frame)")
        attachElementScreenshot(longBubble, named: "long-notice-4-collapsed-bubble")
        toggle.click()
        XCTAssertTrue(waitUntil({ !preview.exists && (toggle.value as? String) == "expanded" }, timeout: 5))

        // A later turn reloads the transcript; the reader's expansion survives it.
        sendTurn(shortPrompt, count: 2)
        let latestPromptID = try historyMessageID { ($0["role"] as? String) == "user" && ($0["text"] as? String) == shortPrompt }
        XCTAssertTrue(element("user-message-\(latestPromptID)").waitToExist(timeout: 10), "The user's prompt renders as their own bubble.")
        XCTAssertTrue(toggle.waitToExist(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "expanded", "The expanded notice stays expanded across the reload.")
        XCTAssertFalse(preview.exists)
        XCTAssertEqual(toggles.count, 1, "Only the long notice has a control; prompts and short notices never do.")
        attachScreenshot(named: "long-notice-5-expanded-after-later-turn")

        // Reopening the task, left expanded, starts the notice collapsed again. The reopened
        // transcript lands on the latest turn, so scroll back up to the notice.
        returnToBoard()
        openTask(named: "Long handoff notice")
        XCTAssertTrue(scrollTranscriptUntilExists(preview), "A reopened task shows the long notice collapsed.")
        XCTAssertTrue(toggle.waitToExist(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "collapsed")
        attachScreenshot(named: "long-notice-6-collapsed-after-reopen")
    }
    // case-contract: test_long_command_activity_title_is_previewed | A tool call whose command is long keeps its whole command: the streamed activity and fresh CLI/XPC history carry its title as Running followed by every line of a heredoc or every character of a long single-line command, and a short command's title is recorded unchanged. While the heredoc still runs, its live command row shows only the title's first line ending in an ellipsis, with no expand control. In the transcript's Worked for list a long title shows its first line, cut to 160 characters and ending in an ellipsis, with an expand control whose accessibility label names expanding the activity title; expanding reveals all of the command and collapsing restores the preview, while the row's accessibility label keeps the full title. A short command's row shows its whole title with no control, and reopening the task shows the long title collapsed again. The preview is Playhouse-owned presentation in the activity row both providers share, and both build a command's title as Running followed by the whole command, so Claude is the representative provider.
    func test_long_command_activity_title_is_previewed() throws {
        _ = try installClaudeFixture(named: "claude-fixture-ui-long-command")
        let executable = dataDirectory.appendingPathComponent("claude-fixture-ui-long-command")
        _ = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Long command title", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
        ])["result"] as? [String: Any])
        let prompt = "Write the release notes with one long heredoc."
        // Matches LONG_HEREDOC_COMMAND's first line and LONG_SINGLE_LINE_COMMAND in scripts/fixtures/claude-code-fixture.py.
        let heredocPreview = "Running cat > /tmp/playhouse-fixture-release-notes.md <<'NOTES'…"
        let lastLine = "Release note line 120: this change keeps a long command readable without laying all of it out."
        let singleLineTitle = "Running echo " + (1...40).map { String(format: "release-note-%03d", $0) }.joined(separator: " ")
        let singleLinePreview = String(singleLineTitle.prefix(160)).trimmingCharacters(in: .whitespaces) + "…"
        func text(of element: XCUIElement) -> String {
            [element.label, element.value as? String ?? ""].joined(separator: " ")
        }
        func openWorkedFor() {
            let disclosure = element("codex-activity-disclosure")
            XCTAssertTrue(disclosure.waitToExist(timeout: 20), "The finished turn offers its Worked for list.")
            if disclosure.value as? String != "Expanded, down chevron" { disclosure.click() }
            XCTAssertTrue(waitUntil({ disclosure.value as? String == "Expanded, down chevron" }, timeout: 10), "Worked for opens.")
        }

        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Long command title")
        let longRow = element("codex-activity-row-toolu_long_heredoc")
        let longTitle = element("codex-activity-title-toolu_long_heredoc")
        let toggle = element("codex-activity-title-toggle-toolu_long_heredoc")

        // While the heredoc runs it is the live command row, which shows only its preview.
        let hold = executable.path + ".long-command"
        touch(hold + "-pause")
        sendFromComposer(prompt)
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: hold + "-ready") }, timeout: 20), "The fixture holds the turn while the heredoc runs.")
        XCTAssertTrue(longTitle.waitToExist(timeout: 10), "The running heredoc shows as the live command row.")
        XCTAssertTrue(text(of: longTitle).contains(heredocPreview), "The live row shows the command's first line with an ellipsis: \(text(of: longTitle))")
        XCTAssertFalse(text(of: longTitle).contains("Release note line"), "The live row shows none of the heredoc's body.")
        XCTAssertFalse(toggle.exists, "The live command row has no expand control.")
        XCTAssertTrue(longRow.label.contains(lastLine), "The live row's accessibility label keeps the whole command.")
        attachScreenshot(named: "long-command-1-live-row-preview")
        attachElementScreenshot(longRow, named: "long-command-1-live-row-closeup")
        touch(hold + "-release")
        XCTAssertTrue(waitUntil({
            self.fixtureTurnCount(executable, containing: prompt) == 1 && self.noTurnIsRunning()
        }, timeout: 30), "The turn should finish once released.")
        for suffix in ["-pause", "-ready", "-release"] { try? FileManager.default.removeItem(atPath: hold + suffix) }

        openWorkedFor()
        XCTAssertTrue(scrollTranscriptUntilExists(longTitle), "The long command's row is listed under Worked for.")
        XCTAssertTrue(toggle.waitToExist(timeout: 5), "A long title offers an expand control.")
        XCTAssertTrue(text(of: longTitle).contains(heredocPreview), "The collapsed title is the command's first line ending in an ellipsis: \(text(of: longTitle))")
        XCTAssertFalse(text(of: longTitle).contains("Release note line"), "The collapsed title shows none of the heredoc's body.")
        XCTAssertEqual(toggle.label, "Expand activity title to show all text")
        XCTAssertEqual(toggle.value as? String, "collapsed")
        XCTAssertTrue(longRow.label.contains(lastLine), "The row's accessibility label keeps the whole command.")
        let collapsedHeight = longRow.frame.height
        XCTAssertLessThan(collapsedHeight, 120, "The collapsed row stays a few lines tall: \(longRow.frame)")

        // A long single-line command is cut at 160 characters.
        let singleTitle = element("codex-activity-title-toolu_long_single_line")
        let singleToggle = element("codex-activity-title-toggle-toolu_long_single_line")
        XCTAssertTrue(singleTitle.waitToExist(timeout: 5), "The single-line command's row is listed under Worked for.")
        XCTAssertTrue(text(of: singleTitle).contains(singleLinePreview), "The title is cut to its first 160 characters: \(text(of: singleTitle))")
        XCTAssertFalse(text(of: singleTitle).contains("release-note-040"), "The collapsed title stops before the line's end.")
        XCTAssertTrue(singleToggle.exists, "A long single-line title offers an expand control.")

        // A short command's row shows its whole title, with no control.
        let shortRow = element("codex-activity-row-toolu_short_command")
        let shortTitle = element("codex-activity-title-toolu_short_command")
        XCTAssertTrue(shortTitle.waitToExist(timeout: 5), "The short command's row is listed under Worked for.")
        XCTAssertTrue(text(of: shortTitle).contains("Running echo release notes checked"))
        XCTAssertFalse(text(of: shortTitle).contains("…"), "A title that fits shows without an ellipsis.")
        XCTAssertFalse(element("codex-activity-title-toggle-toolu_short_command").exists, "A short title has no expand control.")
        attachScreenshot(named: "long-command-2-collapsed-previews")
        attachElementScreenshot(longRow, named: "long-command-2-collapsed-heredoc-row")
        attachElementScreenshot(shortRow, named: "long-command-2-short-row-without-control")

        singleToggle.click()
        XCTAssertTrue(waitUntil({ (singleToggle.value as? String) == "expanded" && text(of: singleTitle).contains("release-note-040") }, timeout: 5),
                      "Expanding the single-line title reveals the end of the line.")
        singleToggle.click()
        XCTAssertTrue(waitUntil({ (singleToggle.value as? String) == "collapsed" && text(of: singleTitle).contains(singleLinePreview) }, timeout: 5))

        toggle.click()
        XCTAssertTrue(waitUntil({ (toggle.value as? String) == "expanded" && text(of: longTitle).contains(lastLine) }, timeout: 5),
                      "Expanding reveals every line of the command.")
        XCTAssertEqual(toggle.label, "Collapse activity title")
        XCTAssertFalse(text(of: longTitle).contains("…"), "The expanded title has no ellipsis.")
        XCTAssertGreaterThan(longRow.frame.height, collapsedHeight + 500, "The expanded row shows the heredoc's lines: \(longRow.frame)")
        bringIntoTranscriptViewport(toggle, scrollView: element("conversation-scroll-view"))
        attachScreenshot(named: "long-command-3-expanded")
        attachElementScreenshot(toggle, named: "long-command-3-collapse-control")

        toggle.click()
        XCTAssertTrue(waitUntil({ (toggle.value as? String) == "collapsed" && text(of: longTitle).contains(heredocPreview) }, timeout: 5),
                      "Collapsing restores the preview.")
        XCTAssertEqual(toggle.label, "Expand activity title to show all text")
        XCTAssertLessThan(longRow.frame.height, collapsedHeight + 2, "The collapsed row returns to its preview height.")

        // Reopening the task, left expanded, starts the title collapsed again.
        toggle.click()
        XCTAssertTrue(waitUntil({ (toggle.value as? String) == "expanded" }, timeout: 5))
        returnToBoard()
        openTask(named: "Long command title")
        openWorkedFor()
        XCTAssertTrue(scrollTranscriptUntilExists(longTitle), "The reopened task lists the long command again.")
        XCTAssertTrue(toggle.waitToExist(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "collapsed", "A reopened task shows the long title collapsed.")
        XCTAssertTrue(text(of: longTitle).contains(heredocPreview))
        attachScreenshot(named: "long-command-4-collapsed-after-reopen")
        attachElementScreenshot(longRow, named: "long-command-4-collapsed-row-after-reopen")
    }

    // case-contract: test_settings_token_usage_color_max_round_trip | The token usage color maximum defaults to twenty million, round-trips through the CLI/XPC settings commands, and rejects a non-positive value as invalid_argument without changing the stored setting. The settings window shows the stored maximum and saves an edited one, and a task card's token counter re-colors when the maximum changes so the same usage reads hotter against a smaller ceiling.
    func test_settings_token_usage_color_max_round_trip() throws {
        let environment = try installClaudeFixture(named: "claude-fixture-ui-token-max")
        launchApp(defaultParent: fixture.parent.path)
        let taskID = try XCTUnwrap((try runCLI([
            "task", "create", "--title", "Counter heat task", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
        ])["result"] as? [String: Any])?["id"] as? String)
        XCTAssertTrue(app.buttons["Counter heat task"].waitToExist(timeout: 10))
        // "Tell me a story." reports a task outcome, so it ends in exactly one
        // Claude result message instead of the several internal nudge turns an
        // outcome-less prompt would trigger in the same session.
        _ = try runCLI(
            ["conversation", "send", taskID, "--message", "Tell me a story."],
            extraEnvironment: environment
        )
        let counter = element("task-token-usage-counter-\(taskID)")
        // One fixture turn sends 1,840 tokens over four calls (two of them a subagent's).
        XCTAssertTrue(waitUntil({ counter.exists && counter.label == "1.8K tokens sent · 4 calls · 650 final transcript" }, timeout: 15))

        XCTAssertEqual(
            (try runCLI(["settings", "get"])["result"] as? [String: Any])?["tokenUsageColorMax"] as? Int, 20_000_000,
            "The counter's scale tops out at twenty million tokens by default."
        )
        XCTAssertTrue(waitUntil({ self.isGreenDominant(counter) }, timeout: 10), "1,840 tokens of twenty million should still read as cool green.")
        attachScreenshot(named: "Token counter reads green against the default twenty-million ceiling")

        app.typeKey(",", modifierFlags: .command)
        let preferences = settingsWindow
        XCTAssertTrue(preferences.waitToExist(timeout: 10), "Workspace Settings did not open.")
        let maxField = preferences.descendants(matching: .any)
            .matching(identifier: "token-usage-color-max-field").firstMatch
        XCTAssertTrue(maxField.waitToExist(timeout: 5), "Settings should expose the token usage maximum.")
        XCTAssertEqual(maxField.value as? String, "20,000,000", "The field should show the stored maximum.")
        attachScreenshot(named: "Workspace Settings exposes the token usage color maximum")
        maxField.click()
        maxField.typeKey("a", modifierFlags: .command)
        maxField.typeText("1600\r")
        XCTAssertTrue(waitUntil({
            ((try? self.runCLI(["settings", "get"])["result"] as? [String: Any])?["tokenUsageColorMax"] as? Int) == 1_600
        }, timeout: 10), "An edited maximum should save through the same settings manager the CLI reads.")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitUntil({ !preferences.exists }, timeout: 5))

        XCTAssertTrue(waitUntil({ self.isRedDominant(counter) }, timeout: 10), "The same usage should read hot once it reaches the ceiling.")
        attachScreenshot(named: "Token counter turns red once the ceiling drops to the task's own usage")

        assertCLIError(
            try runCLI(["settings", "set-token-usage-color-max", "0"], expectedStatus: 2),
            code: "invalid_argument"
        )
        XCTAssertEqual(
            (try runCLI(["settings", "get"])["result"] as? [String: Any])?["tokenUsageColorMax"] as? Int, 1_600,
            "A rejected maximum should leave the stored one alone."
        )
    }
    // case-contract: test_task_cpu_usage_reports_claude_process_tree_load | A newly created Claude task reports cpu-usage as not running before any turn starts. While a real Claude Code fixture turn burns CPU in a real child process, two successive `task cpu-usage` reads establish a baseline and then a plausible non-zero percentage for the task's process tree, the task card's CPU bar reads cool green against the default multi-core ceiling and hot red once the ceiling is lowered to match that load, and the reading returns to not-running once the turn completes.
    func test_task_cpu_usage_reports_claude_process_tree_load() throws {
        var environment = try installClaudeFixture(named: "claude-fixture-ui-cpu-usage")
        environment["PLAYHOUSE_E2E_CLAUDE_FIXTURE_BURN_CPU"] = "1"
        environment["PLAYHOUSE_E2E_CLAUDE_FIXTURE_BURN_CPU_SECONDS"] = "25"
        launchApp(defaultParent: fixture.parent.path)
        let taskID = try XCTUnwrap((try runCLI([
            "task", "create", "--title", "Claude CPU usage", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
        ])["result"] as? [String: Any])?["id"] as? String)
        XCTAssertTrue(app.buttons["Claude CPU usage"].waitToExist(timeout: 10))

        let bar = element("task-cpu-usage-bar-\(taskID)")
        let card = element("task-card-\(taskID)")
        XCTAssertFalse(bar.exists, "A task with no turn yet should show no CPU bar.")

        let process = try startCLIProcess(
            ["conversation", "send", taskID, "--message", "Tell me a story."],
            extraEnvironment: environment
        )
        defer {
            if process.process.isRunning {
                process.process.terminate()
                process.process.waitUntilExit()
            }
        }

        XCTAssertTrue(waitUntil({
            (try? self.runCLI(["task", "get", taskID])["result"] as? [String: Any])?["claudeSessionID"] != nil
        }, timeout: 10), "The Claude fixture turn should start a session while it burns CPU.")

        XCTAssertTrue(bar.waitToExist(timeout: 10), "A busy Claude task should show its left-edge CPU bar.")
        attachScreenshot(named: "Task card shows a busy Claude task's CPU bar")
        // Against the default, core-count-scaled ceiling, one burning core is a
        // small fraction of the total, so the bar should still read cool green
        // — this is what the gradient-reveal fill must get right at low usage.
        // Sampled off the stable card (not the thin, continuously-animating bar
        // sub-view) restricted to its left edge, since the bar's own element
        // identity can transiently drop out of the accessibility tree between
        // an existence check and a screenshot fetch mid-animation.
        XCTAssertTrue(waitUntil({ self.isGreenDominant(card, leftEdgeFraction: 0.06) }, timeout: 10), "One burning core against the default multi-core ceiling should still read cool green.")
        attachScreenshot(named: "CPU bar reads green against the default multi-core ceiling")

        // A low ceiling guarantees the same load now reads clearly hot,
        // regardless of how many cores this machine has.
        _ = try runCLI(["settings", "set-cpu-usage-color-max", "50"])
        XCTAssertTrue(waitUntil({ self.isRedDominant(card, leftEdgeFraction: 0.06) }, timeout: 10), "A single burning core should read hot against a 50% ceiling.")
        attachScreenshot(named: "CPU bar reads hot once usage reaches the lowered ceiling")

        _ = try finishCLIProcess(process)
        XCTAssertTrue(waitUntil({ !bar.exists }, timeout: 15), "The bar should disappear once the turn completes.")
    }
    // case-contract: test_task_cpu_usage_attributes_codex_load_by_worktree | Two Codex tasks rooted in different repository folders share one real fixture app-server. Before any turn each reports cpu-usage as not running. While task A's turn runs a real CPU-burning child process in A's folder and task B's concurrent turn runs an idle child in B's folder, both children belong to the same app-server process; once a baseline is sampled, `task cpu-usage` attributes a plausible non-zero percentage to A and a near-zero one to B, and the task cards show A's CPU bar reading hot against a lowered ceiling beside B's visible but empty bar. Both readings return to not-running once the turns complete.
    func test_task_cpu_usage_attributes_codex_load_by_worktree() throws {
        let executable = dataDirectory.appendingPathComponent("codex-fixture-cpu-attribution")
        try copyFixtureFile(at: WorkspaceFixture.root.appendingPathComponent("codex-fixture-ui"), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data("Playhouse test owns this Codex protocol fixture (v1).\n".utf8)
            .write(to: dataDirectory.appendingPathComponent(".playhouse-codex-fixture-owner"))
        let environment = ["PLAYHOUSE_E2E_CODEX_EXECUTABLE": executable.path]
        launchApp(defaultParent: fixture.parent.path)
        let busyID = try XCTUnwrap((try runCLI([
            "task", "create", "--title", "Codex busy worktree", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "codex",
        ])["result"] as? [String: Any])?["id"] as? String)
        let idleID = try XCTUnwrap((try runCLI([
            "task", "create", "--title", "Codex idle worktree", "--prompt", "Fixture task description.", "--root", fixture.secondary.path, "--provider", "codex",
        ])["result"] as? [String: Any])?["id"] as? String)
        XCTAssertTrue(app.buttons["Codex busy worktree"].waitToExist(timeout: 10))
        XCTAssertTrue(app.buttons["Codex idle worktree"].waitToExist(timeout: 10))

        let busyBar = element("task-cpu-usage-bar-\(busyID)")
        let idleBar = element("task-cpu-usage-bar-\(idleID)")
        let busyCard = element("task-card-\(busyID)")
        let idleCard = element("task-card-\(idleID)")
        for taskID in [busyID, idleID] {
            let before = try XCTUnwrap(try runCLI(["task", "cpu-usage", taskID])["result"] as? [String: Any])
            XCTAssertTrue(before["cpuPercent"] == nil || before["cpuPercent"] is NSNull, "A Codex task with no turn yet has nothing to sample.")
            XCTAssertEqual(before["reason"] as? String, "not_running")
        }
        XCTAssertFalse(busyBar.exists, "A Codex task with no turn yet should show no CPU bar.")
        XCTAssertFalse(idleBar.exists, "A Codex task with no turn yet should show no CPU bar.")

        let busy = try startCLIProcess(["conversation", "send", busyID, "--message", "Please burn cpu for 25 seconds."], extraEnvironment: environment)
        let idle = try startCLIProcess(["conversation", "send", idleID, "--message", "Please idle cpu for 25 seconds."], extraEnvironment: environment)
        defer {
            for running in [busy, idle] where running.process.isRunning {
                running.process.terminate()
                running.process.waitUntilExit()
            }
            // A failed assertion must not leave the daemon-side burn running into later cases.
            if let burner = cpuAttributionChild(executable: executable, kind: "burn") {
                kill(burner.pid, SIGTERM)
            }
        }

        var children: [String: (pid: Int32, parentPID: Int32, workingDirectory: String)] = [:]
        XCTAssertTrue(waitUntil({
            children = [:]
            for kind in ["burn", "idle"] {
                if let child = self.cpuAttributionChild(executable: executable, kind: kind) { children[kind] = child }
            }
            return children.count == 2
        }, timeout: 15), "Both tasks' turns should be running their command children.")
        XCTAssertEqual(children["burn"]?.parentPID, children["idle"]?.parentPID, "Both tasks' commands should run under one shared app-server.")
        XCTAssertEqual(children["burn"].map { URL(fileURLWithPath: $0.workingDirectory).resolvingSymlinksInPath().path },
                       fixture.primary.resolvingSymlinksInPath().path, "The busy command runs in its task's folder.")
        XCTAssertEqual(children["idle"].map { URL(fileURLWithPath: $0.workingDirectory).resolvingSymlinksInPath().path },
                       fixture.secondary.resolvingSymlinksInPath().path, "The idle command runs in its task's folder.")

        XCTAssertTrue(busyBar.waitToExist(timeout: 15), "The busy Codex task should show its left-edge CPU bar.")
        XCTAssertTrue(idleBar.waitToExist(timeout: 15), "A running Codex task with an idle command still shows its (empty) CPU bar.")
        attachScreenshot(named: "Busy and idle Codex task cards both show a CPU bar")

        var readings: [String: [String: Any]] = [:]
        XCTAssertTrue(waitUntil({
            for taskID in [busyID, idleID] {
                readings[taskID] = (try? self.runCLI(["task", "cpu-usage", taskID]))?["result"] as? [String: Any]
            }
            return [busyID, idleID].allSatisfy { readings[$0]?["cpuPercent"] is Double }
        }, timeout: 10), "Both running Codex tasks should be sampled: \(readings)")
        Thread.sleep(forTimeInterval: 1)
        let busyReading = try XCTUnwrap(try runCLI(["task", "cpu-usage", busyID])["result"] as? [String: Any])
        let idleReading = try XCTUnwrap(try runCLI(["task", "cpu-usage", idleID])["result"] as? [String: Any])
        let busyPercent = try XCTUnwrap(busyReading["cpuPercent"] as? Double, "\(busyReading)")
        let idlePercent = try XCTUnwrap(idleReading["cpuPercent"] as? Double, "A running Codex task with an idle command still reports a value: \(idleReading)")
        XCTAssertGreaterThan(busyPercent, 20, "The busy-looping command's CPU should be attributed to its own task.")
        XCTAssertLessThan(busyPercent, Double(ProcessInfo.processInfo.activeProcessorCount * 100 + 50), "One busy loop can't exceed every core.")
        XCTAssertLessThan(idlePercent, 5, "The other task's busy command must not leak into the idle task's reading.")
        // The bars' own labels carry the streamed reading: the idle card's
        // bar is present but empty, the busy card's is not.
        XCTAssertTrue(waitUntil({ idleBar.exists && idleBar.label == "CPU 0%" }, timeout: 10), "The idle Codex task's bar should read 0%, got \(idleBar.label)")
        XCTAssertTrue(waitUntil({
            busyBar.exists && busyBar.label.hasPrefix("CPU ") && busyBar.label != "CPU 0%"
        }, timeout: 10), "The busy Codex task's bar should report its load, got \(busyBar.label)")

        // A ceiling below one busy core makes the busy task's bar read
        // clearly hot while the idle task's bar stays empty. Sampled off each
        // stable card's left edge, as in the Claude case.
        _ = try runCLI(["settings", "set-cpu-usage-color-max", "50"])
        XCTAssertTrue(waitUntil({ self.isRedDominant(busyCard, leftEdgeFraction: 0.06) }, timeout: 10), "The busy Codex task should read hot against a 50% ceiling.")
        XCTAssertTrue(idleBar.exists, "The idle Codex task keeps its bar while its turn runs.")
        XCTAssertFalse(isRedDominant(idleCard, leftEdgeFraction: 0.06), "The idle Codex task's bar should stay empty, not inherit the busy task's load.")
        attachScreenshot(named: "Busy Codex task's bar reads hot beside the idle task's empty bar")

        _ = try finishCLIProcess(busy)
        _ = try finishCLIProcess(idle)
        XCTAssertTrue(waitUntil({ !busyBar.exists && !idleBar.exists }, timeout: 15), "Both bars should disappear once the turns complete.")
        for taskID in [busyID, idleID] {
            let finished = try XCTUnwrap(try runCLI(["task", "cpu-usage", taskID])["result"] as? [String: Any])
            XCTAssertTrue(finished["cpuPercent"] == nil || finished["cpuPercent"] is NSNull, "A finished Codex turn is no longer running.")
            XCTAssertEqual(finished["reason"] as? String, "not_running")
        }
        attachScreenshot(named: "Both Codex task cards drop their CPU bars once the turns finish")
    }
    // case-contract: test_skills_catalog_lists_repo_global_and_builtin_skills | The Skills page, opened from the composer's Skills button that replaced the paperclip, is a full page that slides in from the side over the task and fills the window, and its back button returns to the conversation. Opened from the standalone chat sidebar, it likewise covers the whole window rather than only the sidebar, and closing it keeps the chat open. It lists the task's repository skills per repository (from each worktree's .agents/skills and .claude/skills, keyed by the source repository), the user's global skills (~/.agents/skills, Claude's skills folder, and Codex's legacy skills folder), and built-in skills (Codex's bundled .system skills, claude.ai-synced skills, and Claude Code's built-ins read from a provider session). Each user skill is shown as usable by both Claude and Codex; a skill linked into both layouts is one Linked entry, two different skills with the same name in one repository are flagged as a conflict, a SKILL.md without valid frontmatter is flagged invalid and usable by neither provider, a repository without skills shows an empty state, and built-ins name only the provider they ship with. Reading a skill returns its SKILL.md, and an unknown skill is not_found.
    func test_skills_catalog_lists_repo_global_and_builtin_skills() throws {
        let repository = try makeSkillRepository("skills-catalog-repo", skills: [
            ".agents/skills/repo-agents/SKILL.md": skillManifest("repo-agents", "Agents layout repository skill"),
            ".claude/skills/repo-claude/SKILL.md": skillManifest("repo-claude", "Claude layout repository skill"),
            ".agents/skills/repo-shared/SKILL.md": skillManifest("repo-shared", "Shared into both layouts by a link"),
            ".agents/skills/repo-dup/SKILL.md": skillManifest("repo-dup", "The agents copy"),
            ".claude/skills/repo-dup/SKILL.md": skillManifest("repo-dup", "A different Claude copy"),
            ".agents/skills/repo-broken/SKILL.md": "This skill has no frontmatter.\n",
        ], links: [".claude/skills/repo-shared": "../../.agents/skills/repo-shared"])
        let empty = try makeSkillRepository("skills-empty-repo", skills: [:])
        try writeSkill(in: skillsHome.appendingPathComponent(".agents/skills"), "global-agents", "Global agents skill")
        try writeSkill(in: skillsHome.appendingPathComponent(".claude/skills"), "global-claude", "Global Claude skill")
        try writeSkill(in: skillsCodexHome.appendingPathComponent("skills"), "codex-legacy", "Codex legacy user skill")
        try writeSkill(in: skillsCodexHome.appendingPathComponent("skills/.system"), "codex-system-skill", "Bundled with Codex")
        try writeSkill(in: skillsHome.appendingPathComponent(".claude/skills/synced/bucket-one"), "synced-skill", "Synced from claude.ai")
        _ = try installSkillsClaudeFixture("claude-fixture-skills-catalog")
        launchApp(defaultParent: fixture.parent.path)
        let task = try createSkillsTask("Skills catalog", repositories: [repository, empty])
        let taskID = try XCTUnwrap(task["id"] as? String)
        openTask(named: "Skills catalog")
        XCTAssertFalse(element("attach-chat-image-button").exists, "The Skills button replaces the composer's paperclip.")
        openSkillsPage()
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(waitUntil({
            let page = self.element("skills-page").frame
            return abs(page.minX - window.minX) < 2 && abs(page.maxX - window.maxX) < 2 && abs(page.maxY - window.maxY) < 2
        }, timeout: 5), "The Skills page settles as a full page spanning the window's width down to its bottom edge, not an inset modal.")
        XCTAssertGreaterThan(element("skills-page").frame.height, window.height * 0.85, "The Skills page fills the window.")

        XCTAssertTrue(element("skills-repo-section-skills-catalog-repo").waitToExist(timeout: 10))
        XCTAssertTrue(element("skills-repo-section-skills-empty-repo").exists)
        XCTAssertTrue(element("skills-empty-skills-empty-repo").exists, "A repository without skills shows an empty state.")
        for name in ["repo-agents", "repo-claude", "repo-shared"] {
            XCTAssertTrue(element("skill-row-\(name)").waitToExist(timeout: 5), "\(name) should be listed.")
            XCTAssertTrue(element("skill-provider-\(name)-claude").exists, "\(name) should be usable by Claude.")
            XCTAssertTrue(element("skill-provider-\(name)-codex").exists, "\(name) should be usable by Codex.")
        }
        XCTAssertEqual(accessibleLabelOrValue(of: element("skill-description-repo-agents")), "Agents layout repository skill")
        XCTAssertTrue(element("skill-linked-repo-shared").exists, "A skill linked into both layouts is one Linked entry.")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "skill-row-repo-shared").count, 1,
                       "A skill in both layouts is listed once.")
        XCTAssertFalse(element("skill-linked-repo-agents").exists)
        XCTAssertTrue(element("skill-conflict-repo-dup").exists, "Two different skills with one name are a conflict.")
        XCTAssertTrue(element("skill-invalid-repo-broken").exists, "A SKILL.md without frontmatter is invalid.")
        XCTAssertFalse(element("skill-provider-repo-broken-claude").exists || element("skill-provider-repo-broken-codex").exists,
                       "An invalid skill is usable by neither provider.")
        attachScreenshot(named: "Skills page Repo tab lists each repository's skills")
        let search = element("skills-search")
        typeIntoField(search, text: "layout repository")
        XCTAssertTrue(waitUntil({ !self.element("skill-row-repo-shared").exists }, timeout: 5), "Search hides skills that don't match.")
        XCTAssertTrue(element("skill-row-repo-agents").exists && element("skill-row-repo-claude").exists, "Search keeps skills whose description matches.")
        search.typeKey("a", modifierFlags: .command)
        search.typeText("no-skill-matches-this")
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("skills-empty-skills-catalog-repo")) == "No matching skills." }, timeout: 5),
                      "A search with no match shows its empty state.")
        attachScreenshot(named: "Skills search with no matching skill")
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(element("skill-row-repo-shared").waitToExist(timeout: 5), "Clearing the search shows every skill again.")

        selectSkillsTab("Global")
        for name in ["global-agents", "global-claude", "codex-legacy"] {
            XCTAssertTrue(element("skill-row-\(name)").waitToExist(timeout: 5), "\(name) should be a global skill.")
            XCTAssertTrue(element("skill-provider-\(name)-claude").exists && element("skill-provider-\(name)-codex").exists)
        }
        XCTAssertFalse(element("skill-row-synced-skill").exists, "claude.ai's synced skills are built-in, not global.")
        attachScreenshot(named: "Skills page Global tab")

        selectSkillsTab("Built-in")
        XCTAssertTrue(element("skill-row-codex-system-skill").waitToExist(timeout: 5))
        XCTAssertTrue(element("skill-provider-codex-system-skill-codex").exists)
        XCTAssertFalse(element("skill-provider-codex-system-skill-claude").exists, "A built-in names only the provider it ships with.")
        XCTAssertTrue(element("skill-provider-synced-skill-claude").exists)
        XCTAssertTrue(element("skill-row-simplify").waitToExist(timeout: 20), "Claude Code's built-ins load from its own session.")
        XCTAssertTrue(element("skill-provider-simplify-claude").exists)
        attachScreenshot(named: "Skills page Built-in tab")

        let catalog = try skillCatalog(taskID: taskID, includeBundled: true)
        let sections = try XCTUnwrap(catalog["repositories"] as? [[String: Any]])
        XCTAssertEqual(sections.map { $0["name"] as? String }, ["skills-catalog-repo", "skills-empty-repo"])
        XCTAssertEqual(sections[0]["repositoryPath"] as? String, repository.path, "Repository skills are keyed by the source repository.")
        XCTAssertNotEqual(realPath(sections[0]["rootPath"] as? String ?? ""), realPath(repository.path), "Skills are read from the task worktree.")
        let repoSkills = skillsByName(sections[0]["skills"])
        XCTAssertEqual(repoSkills["repo-dup"]?["conflict"] as? Bool, true)
        XCTAssertEqual(repoSkills["repo-shared"]?["availableOutsidePlayhouse"] as? Bool, true)
        XCTAssertEqual(repoSkills["repo-broken"]?["providers"] as? [String], [])
        XCTAssertEqual(skillsByName(catalog["builtin"])["simplify"]?["providers"] as? [String], ["claude"])
        let detail = try XCTUnwrap(try runCLI(["skills", "get", "--task", taskID, "--skill", "repo:\(repository.path)#repo-agents"])["result"] as? [String: Any])
        XCTAssertEqual(detail["content"] as? String, skillManifest("repo-agents", "Agents layout repository skill"))
        assertCLIError(try runCLI(["skills", "get", "--task", taskID, "--skill", "global:no-such-skill"], expectedStatus: 3), code: "not_found")

        element("skills-back-button").click()
        XCTAssertTrue(waitUntil({ !self.element("skills-page").exists }, timeout: 5), "Back returns to the conversation.")
        XCTAssertTrue(element("message-composer").waitToExist(timeout: 5))

        // From the standalone chat sidebar, the page covers the whole window, not just the sidebar.
        returnToBoard()
        element("chat-sidebar-button").click()
        XCTAssertTrue(element("chat-sidebar").waitToExist(timeout: 10))
        XCTAssertTrue(element("chat-sidebar-resize-handle").waitToExist(timeout: 5))
        // Opening the chat grows the window to fit the sidebar beside the board; let that settle first.
        var chatWindow = app.windows.firstMatch.frame
        XCTAssertTrue(waitUntil({
            Thread.sleep(forTimeInterval: 0.3)
            let settled = self.app.windows.firstMatch.frame
            defer { chatWindow = settled }
            return settled == chatWindow
        }, timeout: 10), "The window should settle after the chat opens.")
        // The visible board beside the sidebar, which the page must actually draw over rather than be clipped from.
        let screen = try XCTUnwrap(NSScreen.main?.frame, "Could not read the screen's size.")
        let sidebarEdge = element("chat-sidebar").frame.maxX
        let boardStripe = CGRect(x: sidebarEdge + 20, y: chatWindow.minY + chatWindow.height * 0.3,
                                 width: min(chatWindow.maxX, screen.width) - sidebarEdge - 40, height: chatWindow.height * 0.5)
        XCTAssertGreaterThan(boardStripe.width, 40, "Part of the board should be visible beside the chat sidebar.")
        XCTAssertGreaterThan(boardStripe.minX, sidebarEdge, "The sampled board lies right of the chat sidebar.")
        func boardStripeImage() throws -> NSImage {
            let image = XCUIScreen.main.screenshot().image
            let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil), "Could not read the screen's pixels.")
            let scale = CGFloat(cgImage.width) / screen.width
            let region = CGRect(x: boardStripe.minX * scale, y: boardStripe.minY * scale,
                                width: boardStripe.width * scale, height: boardStripe.height * scale).integral
            return NSImage(cgImage: try XCTUnwrap(cgImage.cropping(to: region)), size: boardStripe.size)
        }
        let boardBefore = try boardStripeImage()
        openSkillsPage()
        XCTAssertTrue(waitUntil({
            let page = self.element("skills-page").frame
            return abs(page.minX - chatWindow.minX) < 2 && abs(page.maxX - chatWindow.maxX) < 2 && abs(page.maxY - chatWindow.maxY) < 2
        }, timeout: 5), "The chat's Skills page spans the whole window, not only the chat sidebar.")
        XCTAssertGreaterThan(element("skills-page").frame.height, chatWindow.height * 0.85, "The chat's Skills page fills the window.")
        XCTAssertTrue(waitUntil({ !self.element("chat-sidebar-resize-handle").exists }, timeout: 5),
                      "The sidebar's resize edge hides while the page covers the window.")
        let changedBoardPixels = try XCTUnwrap(changedPixelCount(before: boardBefore, after: try boardStripeImage(), step: 4, threshold: 0.08),
                                               "Could not compare the board's pixels.")
        XCTAssertGreaterThan(changedBoardPixels, 20, "The page is drawn over the board beside the sidebar, not clipped to the sidebar.")
        attachScreenshot(named: "Skills page opened from the standalone chat covers the window")
        element("skills-back-button").click()
        XCTAssertTrue(waitUntil({ !self.element("skills-page").exists }, timeout: 5), "Back returns to the chat.")
        XCTAssertTrue(element("chat-sidebar").exists, "Closing the page keeps the chat sidebar open.")
        XCTAssertTrue(element("chat-sidebar-resize-handle").waitToExist(timeout: 5), "The sidebar's resize edge returns with the page closed.")
    }
    // case-contract: test_skills_create_update_move_and_delete_on_disk | Creating a skill writes SKILL.md with name and description frontmatter into the open Agent Skills layout, ~/.agents/skills for a global skill or the chosen task worktree's .agents/skills for a repository skill; invalid names, a missing description, a duplicate name, and the built-in scope are rejected with nothing written. Editing saves the new SKILL.md exactly as written, keeping frontmatter Playhouse does not parse, and rejects a renamed or description-less frontmatter while keeping the file. Clicking a skill row opens the editor modal straight on its whole SKILL.md, frontmatter included, with no structured header form, and its Preview tab shows that Markdown rendered with the frontmatter as a table; saving there writes the edited file, a description-less edit is rejected in the editor while keeping the file, and after the editor closes the page still answers clicks. A structured CLI edit rewrites the header (reading a YAML list as one field), removes an emptied field, keeps frontmatter Playhouse does not edit, and rejects an unknown field or an empty description while keeping the file. Clicking a built-in skill with a folder opens it read-only, without Save. New Skill asks only for a name, a description, and instructions it can preview, and a header field given to the CLI's create is written into the new SKILL.md. Moving a skill between a repository and the global gallery moves its folder and rejects a move onto an existing name. Deleting removes the folder from disk, built-in skills are read-only, and every change is visible to a fresh CLI process and on the Skills page.
    func test_skills_create_update_move_and_delete_on_disk() throws {
        let repository = try makeSkillRepository("skills-manage-repo", skills: [:])
        // The Skills page reads Claude Code's built-ins from a provider session.
        _ = try installSkillsClaudeFixture("claude-fixture-skills-manage")
        try writeSkill(in: skillsCodexHome.appendingPathComponent("skills/.system"), "codex-system-skill", "Bundled with Codex")
        launchApp(defaultParent: fixture.parent.path)
        let task = try createSkillsTask("Skills manage", repositories: [repository])
        let taskID = try XCTUnwrap(task["id"] as? String)
        let worktree = URL(fileURLWithPath: try XCTUnwrap((task["repositoryWorktrees"] as? [[String: Any]])?.first?["worktreePath"] as? String))
        let globalFolder = skillsHome.appendingPathComponent(".agents/skills")
        openTask(named: "Skills manage")
        openSkillsPage()

        element("new-skill-button").click()
        let name = element("new-skill-name")
        XCTAssertTrue(name.waitToExist(timeout: 5), "New Skill should open its sheet.")
        typeIntoField(name, text: "Release Notes")
        typeIntoField(element("new-skill-description"), text: "Draft release notes")
        element("new-skill-create").click()
        XCTAssertTrue(element("new-skill-error").waitToExist(timeout: 5), "An invalid name shows an error in the sheet.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: globalFolder.path), "A rejected skill writes nothing.")
        attachScreenshot(named: "New Skill sheet rejects an invalid name")
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("release-notes")
        typeIntoField(element("new-skill-body"), text: "Summarize merged changes.")
        element("new-skill-create").click()
        XCTAssertTrue(waitUntil({ !self.element("new-skill-name").exists }, timeout: 10), "Creating closes the sheet.")
        XCTAssertTrue(element("skill-row-release-notes").waitToExist(timeout: 10), "The new skill shows on the Global tab.")
        let manifest = globalFolder.appendingPathComponent("release-notes/SKILL.md")
        XCTAssertEqual(try String(contentsOf: manifest, encoding: .utf8),
                       "---\nname: release-notes\ndescription: \"Draft release notes\"\n---\n\nSummarize merged changes.\n")
        assertCLIError(try runCLI(["skills", "create", "--task", taskID, "--scope", "global", "--name", "release-notes", "--description", "Again"], expectedStatus: 1), code: "already_exists")
        assertCLIError(try runCLI(["skills", "create", "--task", taskID, "--scope", "global", "--name", "release-notes"], expectedStatus: 2), code: "invalid_argument")
        assertCLIError(try runCLI(["skills", "create", "--task", taskID, "--scope", "builtin", "--name", "other", "--description", "Built-in"], expectedStatus: 2), code: "invalid_argument")

        let row = element("skill-row-release-notes")
        row.click()
        let editor = element("skill-editor")
        XCTAssertTrue(element("skill-editor-panel").waitToExist(timeout: 5), "Clicking a skill opens its editor modal.")
        XCTAssertEqual(accessibleLabelOrValue(of: element("skill-editor-name")), "release-notes", "The editor is titled with the skill's name.")
        let created = "---\nname: release-notes\ndescription: \"Draft release notes\"\n---\n\nSummarize merged changes.\n"
        XCTAssertEqual(editor.value as? String, created, "The editor opens the whole SKILL.md, frontmatter included.")
        for structured in ["skill-editor-description", "skill-editor-field-license", "skill-editor-field-compatibility", "skill-editor-field-allowed-tools"] {
            XCTAssertFalse(element(structured).exists, "The editor has no structured header field \(structured).")
        }
        attachScreenshot(named: "The skill editor opens SKILL.md for editing")
        selectSkillsTab("Preview", picker: "skill-editor-tab-picker")
        let preview = element("skill-editor-preview")
        XCTAssertTrue(preview.waitToExist(timeout: 5), "The Preview tab shows the Markdown rendered.")
        XCTAssertFalse(editor.exists, "The Preview tab replaces the text editor.")
        XCTAssertTrue(element("skill-editor-preview-frontmatter").staticTexts["release-notes"].exists, "The preview shows the frontmatter as a table of its entries.")
        XCTAssertTrue(preview.staticTexts["Summarize merged changes."].exists, "The preview renders the instructions.")
        XCTAssertFalse(preview.staticTexts["---"].exists, "The preview does not show the raw frontmatter fences.")
        attachScreenshot(named: "The skill editor's Preview tab renders the Markdown")
        selectSkillsTab("Edit", picker: "skill-editor-tab-picker")
        XCTAssertTrue(editor.waitToExist(timeout: 5))
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("---\nname: release-notes\n---\n\nNo description.\n")
        element("skill-editor-save").click()
        XCTAssertTrue(element("skill-editor-error").waitToExist(timeout: 5), "A description-less SKILL.md is rejected in the editor.")
        attachScreenshot(named: "The skill editor rejects a SKILL.md without a description")
        XCTAssertEqual(try String(contentsOf: manifest, encoding: .utf8), created, "A rejected edit keeps the file.")

        // Cancel discards the edit, and the page still answers clicks once the editor is gone.
        element("skill-editor-cancel").click()
        XCTAssertTrue(waitUntil({ !self.element("skill-editor-panel").exists }, timeout: 5), "Cancel closes the editor.")
        selectSkillsTab("Repo")
        XCTAssertTrue(element("skills-empty-skills-manage-repo").waitToExist(timeout: 5), "After the editor closes, a click on the Repo tab still switches tabs.")
        selectSkillsTab("Global")
        XCTAssertTrue(row.waitToExist(timeout: 5), "A click on the Global tab switches back.")
        XCTAssertEqual(try String(contentsOf: manifest, encoding: .utf8), created, "Cancel discards the edit.")
        XCTAssertTrue(openPanel("skill-editor-panel", with: row), "A click on the skill row opens the editor again after it was closed.")
        XCTAssertEqual(editor.value as? String, created, "The reopened editor shows the file, not the discarded edit.")
        let edited = "---\nname: release-notes\ndescription: Draft concise release notes\nmetadata:\n  owner: docs\n---\n\n# Release notes\n\n- Group changes by area.\n"
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText(edited)
        selectSkillsTab("Preview", picker: "skill-editor-tab-picker")
        XCTAssertTrue(waitUntil({ self.element("skill-editor-preview").staticTexts["Release notes"].exists }, timeout: 5), "The preview renders a heading.")
        XCTAssertTrue(element("skill-editor-preview").staticTexts["Group changes by area."].exists, "The preview renders a list item.")
        attachScreenshot(named: "Previewing an edited skill before saving")
        element("skill-editor-save").click()
        XCTAssertTrue(waitUntil({ !self.element("skill-editor-panel").exists }, timeout: 10), "Saving closes the editor.")
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("skill-description-release-notes")) == "Draft concise release notes" }, timeout: 10))
        XCTAssertEqual(try String(contentsOf: manifest, encoding: .utf8), edited, "Saving writes the file exactly as edited, keeping frontmatter Playhouse does not parse.")
        let renamed = dataDirectory.appendingPathComponent("skill-edit-renamed.md")
        try skillManifest("other-name", "Renamed").write(to: renamed, atomically: true, encoding: .utf8)
        assertCLIError(try runCLI(["skills", "update", "--task", taskID, "--skill", "global:release-notes", "--content-file", renamed.path], expectedStatus: 2), code: "invalid_argument")
        XCTAssertEqual(try String(contentsOf: manifest, encoding: .utf8), edited, "A rejected edit keeps the file.")

        // The CLI's structured edit still reads and rewrites the header fields.
        try "---\nname: release-notes\ndescription: Draft concise release notes\nallowed-tools:\n  - Read\n  - Bash\nmetadata:\n  owner: docs\n---\n\nGroup changes by area.\n"
            .write(to: manifest, atomically: true, encoding: .utf8)
        let parsed = try XCTUnwrap(try runCLI(["skills", "get", "--task", taskID, "--skill", "global:release-notes"])["result"] as? [String: Any])
        XCTAssertEqual((parsed["manifest"] as? [String: Any])?["fields"] as? [String: String], ["allowed-tools": "Read, Bash"], "A YAML list reads as one field.")
        _ = try runCLI(["skills", "update", "--task", taskID, "--skill", "global:release-notes", "--description", "Draft release notes by area",
                        "--field", "license=MIT", "--field", "allowed-tools=", "--body", "List each change under its area."])
        XCTAssertEqual(try String(contentsOf: manifest, encoding: .utf8),
                       "---\nname: release-notes\ndescription: \"Draft release notes by area\"\nlicense: \"MIT\"\nmetadata:\n  owner: docs\n---\n\nList each change under its area.\n",
                       "A structured edit rewrites the header, removes an emptied field, and keeps unknown keys.")
        assertCLIError(try runCLI(["skills", "update", "--task", taskID, "--skill", "global:release-notes", "--field", "model=opus"], expectedStatus: 2), code: "invalid_argument")
        assertCLIError(try runCLI(["skills", "update", "--task", taskID, "--skill", "global:release-notes", "--description", "  "], expectedStatus: 2), code: "invalid_argument")
        XCTAssertTrue(try String(contentsOf: manifest, encoding: .utf8).contains("List each change under its area."), "A rejected structured edit keeps the file.")
        _ = try runCLI(["skills", "create", "--task", taskID, "--scope", "global", "--name", "fielded", "--description", "Has header fields",
                        "--field", "compatibility=Needs git", "--body", "Steps."])
        XCTAssertEqual(try String(contentsOf: globalFolder.appendingPathComponent("fielded/SKILL.md"), encoding: .utf8),
                       "---\nname: fielded\ndescription: \"Has header fields\"\ncompatibility: \"Needs git\"\n---\n\nSteps.\n",
                       "A header field given to the CLI's create is written into SKILL.md.")
        _ = try runCLI(["skills", "delete", "--task", taskID, "--skill", "global:fielded"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: globalFolder.appendingPathComponent("fielded").path))
        row.click()
        XCTAssertTrue(waitUntil({ (self.element("skill-editor").value as? String)?.contains("license: \"MIT\"") == true }, timeout: 5),
                      "The editor shows a CLI edit as it is on disk.")
        // The editor is still sliding in; a click on Cancel's mid-animation frame misses it.
        XCTAssertTrue(waitForStableFrame(element("skill-editor-cancel")), "The editor should settle before Cancel is clicked.")
        element("skill-editor-cancel").click()
        XCTAssertTrue(waitUntil({ !self.element("skill-editor-panel").exists }, timeout: 5), "Cancel closes the reopened editor.")

        element("new-skill-button").click()
        XCTAssertTrue(element("new-skill-name").waitToExist(timeout: 5))
        typeIntoField(element("new-skill-name"), text: "repo-new")
        typeIntoField(element("new-skill-description"), text: "Repository only")
        XCTAssertFalse(element("new-skill-field-compatibility").exists || element("new-skill-field-license").exists,
                       "New Skill has no structured header fields.")
        typeIntoField(element("new-skill-body"), text: "## Steps\n\n1. Check the repository.")
        selectSkillsTab("Preview", picker: "new-skill-tab-picker")
        XCTAssertTrue(waitUntil({ self.element("new-skill-preview").staticTexts["Steps"].exists }, timeout: 5), "New Skill previews its instructions as Markdown.")
        attachScreenshot(named: "New Skill asks for a name, a description, and instructions")
        let destination = element("new-skill-scope")
        destination.click()
        let repositoryOption = app.menuItems["skills-manage-repo"]
        XCTAssertTrue(repositoryOption.waitToExist(timeout: 5), "Save to should offer the task's repository.")
        repositoryOption.click()
        element("new-skill-create").click()
        XCTAssertTrue(waitUntil({ !self.element("new-skill-name").exists }, timeout: 10))
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.appendingPathComponent(".agents/skills/repo-new/SKILL.md").path),
                      "A repository skill is written into the chosen task worktree.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.appendingPathComponent(".agents").path), "The source checkout is left alone.")
        XCTAssertEqual(try String(contentsOf: worktree.appendingPathComponent(".agents/skills/repo-new/SKILL.md"), encoding: .utf8),
                       "---\nname: repo-new\ndescription: \"Repository only\"\n---\n\n## Steps\n\n1. Check the repository.\n",
                       "New Skill writes the name, description, and instructions into SKILL.md.")
        selectSkillsTab("Repo")
        XCTAssertTrue(element("skill-row-repo-new").waitToExist(timeout: 10))
        clickSkillMenuItem(skill: "repo-new", item: "skill-move-global-repo-new", title: "Move to Global")
        XCTAssertTrue(waitUntil({ !self.element("skill-row-repo-new").exists }, timeout: 10), "A moved skill leaves the Repo tab.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: globalFolder.appendingPathComponent("repo-new/SKILL.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.appendingPathComponent(".agents/skills/repo-new").path))
        assertCLIError(try runCLI(["skills", "move", "--task", taskID, "--skill", "global:repo-new", "--scope", "global"], expectedStatus: 2), code: "invalid_argument")
        selectSkillsTab("Global")
        clickSkillMenuItem(skill: "repo-new", item: "skill-move-repo-repo-new-skills-manage-repo", title: "Move to skills-manage-repo")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: worktree.appendingPathComponent(".agents/skills/repo-new/SKILL.md").path) }, timeout: 10),
                      "A global skill moves into the chosen worktree.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: globalFolder.appendingPathComponent("repo-new").path))
        selectSkillsTab("Repo")
        clickSkillMenuItem(skill: "repo-new", item: "skill-move-global-repo-new", title: "Move to Global")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: globalFolder.appendingPathComponent("repo-new/SKILL.md").path) }, timeout: 10))
        try writeSkill(in: worktree.appendingPathComponent(".claude/skills"), "release-notes", "A repository skill with the same name")
        assertCLIError(try runCLI(["skills", "move", "--task", taskID, "--skill", "global:release-notes", "--scope", "repo", "--root", repository.path], expectedStatus: 1), code: "already_exists")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path), "A rejected move leaves the skill in place.")

        selectSkillsTab("Global")
        XCTAssertTrue(element("skill-row-repo-new").waitToExist(timeout: 10))
        clickSkillMenuItem(skill: "repo-new", item: "skill-delete-repo-new", title: "Delete…")
        XCTAssertTrue(waitUntil({ self.element("confirm-delete-skill").exists || self.app.buttons["Delete"].exists }, timeout: 5))
        attachScreenshot(named: "Delete skill confirmation")
        clickDialogButton("confirm-delete-skill", title: "Delete")
        XCTAssertTrue(waitUntil({ !self.element("skill-row-repo-new").exists }, timeout: 10), "A deleted skill leaves the page.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: globalFolder.appendingPathComponent("repo-new").path), "Deleting removes the folder from disk.")
        attachScreenshot(named: "Global tab after deleting a skill")
        let fresh = try skillCatalog(taskID: taskID)
        XCTAssertEqual(skillsByName(fresh["global"]).keys.sorted(), ["release-notes"])
        XCTAssertEqual(skillsByName(fresh["global"])["release-notes"]?["description"] as? String, "Draft release notes by area")

        selectSkillsTab("Built-in")
        XCTAssertTrue(element("skill-row-codex-system-skill").waitToExist(timeout: 10))
        element("skill-actions-codex-system-skill").click()
        XCTAssertTrue(app.menuItems["Reveal in Finder"].waitToExist(timeout: 5), "The built-in's actions menu should open.")
        for title in ["Edit…", "Delete…", "Move to Global"] {
            XCTAssertFalse(app.menuItems[title].exists, "A built-in skill is read-only, so its menu has no \(title).")
        }
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(openPanel("skill-editor-panel", with: element("skill-row-codex-system-skill")), "Clicking a built-in skill shows it.")
        let builtinText = element("skill-editor").value as? String
        XCTAssertTrue(builtinText?.contains("Bundled with Codex") == true, "A built-in skill shows its SKILL.md.")
        element("skill-editor").click()
        element("skill-editor").typeText("typed")
        XCTAssertEqual(element("skill-editor").value as? String, builtinText, "A built-in skill's SKILL.md cannot be edited.")
        XCTAssertFalse(element("skill-editor-save").exists, "A built-in skill cannot be saved.")
        attachScreenshot(named: "A built-in skill opens read-only")
        element("skill-editor-cancel").click()
        XCTAssertTrue(waitUntil({ !self.element("skill-editor-panel").exists }, timeout: 5))
        assertCLIError(try runCLI(["skills", "delete", "--task", taskID, "--skill", "builtin:codex:codex-system-skill"], expectedStatus: 2), code: "invalid_argument")
        XCTAssertTrue(FileManager.default.fileExists(atPath: skillsCodexHome.appendingPathComponent("skills/.system/codex-system-skill").path))
    }
}
