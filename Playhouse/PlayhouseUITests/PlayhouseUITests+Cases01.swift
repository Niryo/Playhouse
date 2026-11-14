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
    // case-contract: test_service_reports_bridge_version | Playhouse opens one main board window titled with its worktree label, displays the transparent theater logo in the board header, keeps a fixed standard-width (216-point) Kanban sidebar, 8% wider than its previous 200-point width and left of the columns while they scroll, and places its Scheduled Tasks button inside the sidebar below the full logo header. The Dock AppIcon uses the same foreground artwork on a solid #2C2F36 background, and the bridge reports API version 1.
    func test_service_reports_bridge_version() throws {
        launchApp(defaultParent: fixture.parent.path)
        XCTAssertEqual(app.windows.count, 1, "Playhouse should open one board window on launch.")
        XCTAssertTrue(element("board-title").waitToExist(timeout: 15), "The Playhouse window did not open.")
        let logo = app.images["Playhouse logo"]
        XCTAssertTrue(logo.waitToExist(timeout: 5), "The board header should display the transparent theater logo.")
        let sidebar = element(withAccessibilityLabel: "Kanban sidebar")
        let scheduledTasksButton = element("scheduled-tasks-button")
        XCTAssertTrue(sidebar.waitToExist(timeout: 5), "The Kanban sidebar should be visible.")
        XCTAssertEqual(sidebar.frame.width, 216, accuracy: 2, "The Kanban sidebar should be 10% narrower than the previous 240-point width.")
        XCTAssertTrue(scheduledTasksButton.isHittable, "The Scheduled Tasks button should be hittable.")
        XCTAssertTrue(sidebar.frame.contains(scheduledTasksButton.frame), "The Scheduled Tasks button should be inside the sidebar.")
        XCTAssertGreaterThanOrEqual(
            sidebar.frame.minY,
            element(containingAccessibilityText: "Kanban header").frame.maxY,
            "The sidebar should begin below the full logo header."
        )
        let sidebarFrame = sidebar.frame
        let backlogColumn = element("column-backlog")
        XCTAssertLessThan(sidebarFrame.maxX, backlogColumn.frame.minX, "The sidebar should stay left of the board columns.")
        let backlogColumnStartX = backlogColumn.frame.minX
        element("board-columns-scroll-view").swipeLeft()
        XCTAssertLessThan(backlogColumn.frame.minX, backlogColumnStartX, "The board columns should scroll horizontally.")
        XCTAssertEqual(sidebar.frame, sidebarFrame, "Scrolling the board columns should not move the sidebar.")
        assertPlayhouseLogoArtwork(logo)
        let headerLogoURL = repositoryRoot.appendingPathComponent("Playhouse/Assets.xcassets/PlayhouseLogo.imageset/PlayhouseLogo.png")
        let headerLogoBitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: headerLogoURL)), "The in-app logo image should load.")
        let transparentCorner = try XCTUnwrap(headerLogoBitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(transparentCorner.alphaComponent, 0.05, "The in-app logo should retain transparency.")
        let appIconURL = repositoryRoot.appendingPathComponent("Playhouse/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
        // The icon file has no color profile, so compare its stored values
        // rather than a conversion that depends on the machine's display.
        let appIcon = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: appIconURL)), "The Dock AppIcon asset should load.")
        func assertIconPixel(_ x: CGFloat, _ y: CGFloat, _ expected: (Int, Int, Int), accuracy: Int) {
            var pixel = [Int](repeating: 0, count: 4)
            appIcon.getPixel(&pixel, atX: Int(CGFloat(appIcon.pixelsWide) * x), y: Int(CGFloat(appIcon.pixelsHigh) * y))
            XCTAssertEqual(pixel[0], expected.0, accuracy: accuracy, "AppIcon red at (\(x), \(y))")
            XCTAssertEqual(pixel[1], expected.1, accuracy: accuracy, "AppIcon green at (\(x), \(y))")
            XCTAssertEqual(pixel[2], expected.2, accuracy: accuracy, "AppIcon blue at (\(x), \(y))")
        }
        assertIconPixel(0.22, 0.54, (70, 177, 235), accuracy: 20)
        assertIconPixel(0.76, 0.54, (149, 41, 121), accuracy: 20)
        assertIconPixel(0.49, 0.40, (250, 178, 117), accuracy: 24)
        assertIconPixel(0.22, 0.82, (176, 53, 169), accuracy: 24)
        assertIconPixel(0.76, 0.82, (240, 82, 121), accuracy: 20)
        assertIconPixel(0.02, 0.02, (44, 47, 54), accuracy: 5)
        XCTAssertEqual(app.windows.firstMatch.title, "Playhouse — Playhouse UI Test Worktree")
        relaunchApp()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 15), "The board should reopen after relaunch.")
        XCTAssertTrue(element(withAccessibilityLabel: "Kanban sidebar").exists, "The sidebar should remain visible after relaunch.")
        XCTAssertEqual(app.windows.firstMatch.title, "Playhouse — Playhouse UI Test Worktree")
        let response = try runCLI(["status"])
        XCTAssertEqual(response["ok"] as? Bool, true)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["service"] as? String, "Playhouse")
        XCTAssertEqual(result["bridgeVersion"] as? Int, 1)
        let daemonPID = try XCTUnwrap(result["processID"] as? Int, "The bridge should report the daemon process that answered.")
        XCTAssertGreaterThan(daemonPID, 0)
        XCTAssertEqual(kill(pid_t(daemonPID), 0), 0, "The reported daemon process should be running.")
        attachScreenshot(named: "Playhouse board opened with a healthy bridge")
        attachElementScreenshot(sidebar, named: "Kanban sidebar at 216 points")
    }
    // case-contract: test_agents_info_usage_recovers_when_account_reads_fail | When either provider account metadata read fails, a usage refresh still reads that provider usage and retains its last known account. Codex and Claude usage changes reach the CLI and open Agents info section, and after both account reads recover another refresh updates both usage values and retains the correct accounts.
    func test_agents_info_usage_recovers_when_account_reads_fail() throws {
        let codex = try makeCodexFixture(emptyQuestions: false)
        codexFixtureExecutable = codex.path
        let claude = dataDirectory.appendingPathComponent("claude-fixture-usage-failure")
        try copyFixtureFile(at: WorkspaceFixture.root.appendingPathComponent("claude-fixture-ui"), to: claude)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        try "Playhouse test owns this Claude Code protocol fixture (v1).\n".write(to: dataDirectory.appendingPathComponent(".playhouse-claude-fixture-owner"), atomically: true, encoding: .utf8)
        claudeFixtureExecutable = claude.path
        launchApp(defaultParent: fixture.parent.path)
        func text(_ id: String) -> String { let item = element(id); return item.exists ? accessibleLabelOrValue(of: item) : "" }
        XCTAssertTrue(element("agents-info-codex-window-primary").waitToExist(timeout: 30))
        XCTAssertTrue(element("agents-info-claude-account").waitToExist(timeout: 30))
        let codexError = URL(fileURLWithPath: codex.path + ".account-read-error")
        let claudeError = URL(fileURLWithPath: claude.path + ".auth-status-error")
        let codexAccount = URL(fileURLWithPath: codex.path + ".account")
        let claudeUsage = URL(fileURLWithPath: claude.path + ".usage")
        defer { for url in [codexError, claudeError, codexAccount, claudeUsage] { try? FileManager.default.removeItem(at: url) } }
        func values(_ codexPercent: Int, _ claudePercent: Int) throws {
            try JSONSerialization.data(withJSONObject: ["loggedIn": true, "email": "codex-fixture@example.com", "used": [codexPercent, 62]]).write(to: codexAccount, options: .atomic)
            try JSONSerialization.data(withJSONObject: ["rate_limits_available": true, "rate_limits": ["five_hour": ["utilization": claudePercent, "resets_at": "2099-01-01T00:00:00Z"]]]).write(to: claudeUsage, options: .atomic)
        }
        try Data().write(to: codexError); try Data().write(to: claudeError)
        try values(47, 24)
        _ = try runCLI(["usage", "get", "--refresh"])
        XCTAssertTrue(waitUntil({ text("agents-info-codex-window-primary").contains("47%") && text("agents-info-claude-window-five_hour").contains("24%") }, timeout: 40))
        XCTAssertEqual(text("agents-info-codex-account"), "codex-fixture@example.com Plus")
        XCTAssertEqual(text("agents-info-claude-account"), "claude-fixture@example.com Max")
        attachScreenshot(named: "Usage updated while account reads fail")
        for provider in ["codex", "claude"] {
            let capture = XCTAttachment(screenshot: element("agents-info-\(provider)").screenshot())
            capture.name = "\(provider) usage while account read fails"; capture.lifetime = .keepAlways; add(capture)
        }
        try FileManager.default.removeItem(at: codexError); try FileManager.default.removeItem(at: claudeError)
        try values(54, 31)
        try JSONSerialization.data(withJSONObject: ["loggedIn": true, "email": "codex-recovered@example.com", "used": [54, 62]]).write(to: codexAccount, options: .atomic)
        try JSONSerialization.data(withJSONObject: ["loggedIn": true, "authMethod": "claude.ai", "email": "claude-recovered@example.com", "subscriptionType": "max"]).write(to: URL(fileURLWithPath: claude.path + ".auth-state"), options: .atomic)
        _ = try runCLI(["usage", "get", "--refresh"])
        XCTAssertTrue(waitUntil({ text("agents-info-codex-window-primary").contains("54%") && text("agents-info-claude-window-five_hour").contains("31%") }, timeout: 40))
        XCTAssertEqual(text("agents-info-codex-account"), "codex-recovered@example.com Plus")
        XCTAssertEqual(text("agents-info-claude-account"), "claude-recovered@example.com Max")
        attachScreenshot(named: "Usage after account reads recover")
        for provider in ["codex", "claude"] {
            let capture = XCTAttachment(screenshot: element("agents-info-\(provider)").screenshot())
            capture.name = "\(provider) usage after account recovery"; capture.lifetime = .keepAlways; add(capture)
        }
    }
    // case-contract: test_agents_info_shows_provider_usage_and_accounts | The Agents info section reads Claude and Codex plan usage and accounts through the bridge. A refresh reads both providers: Codex's account, plan, both rolling windows (5h and weekly) with percent used and reset times, and its credits balance come from the app-server, while Claude's usage is read with Claude Code's get_usage control request, which has none for this account yet, so Claude starts with a signed-in account and no usage. While a usage watch remains open, it periodically refreshes both providers; Codex and Claude usage changed without a push reaches the watch and appears in the open window, and the Codex snapshot persists. A Claude turn's rate_limit_event then fills Claude's 5h and weekly windows and its warning status from the stream, a usage watch already open receives that change as a pushed update without asking again, a fresh read returns the same values, and the last-known snapshot is persisted to disk. A later event whose window reset time has already passed reads back as reset (empty, no reset time) and lifts the limit status without any provider call. Because Claude Code streams rate_limit_event only when a limit's status changes, and a usage-based plan's event has no utilization, every finished Claude turn reads the plan's usage again through get_usage (skipping the local transcript scan) without a refresh: the read replaces the windows with the plan's current ones, keeps get_usage percents as percents, shows a usage-based plan's monthly extra usage as a Spend limit row with the reset time from the stream's overage event, and is persisted; a refresh reads it too, a reply without plan usage keeps the last known rows, a reached spend limit reads as the limit reached, and a usage request that is never answered times out, keeping the last known rows, so later reads work again. Switching the Codex account signs out, clears the cached usage, starts a new login that returns its sign-in URL, and shows the new account's account and usage after the login completes; switching the Claude account does the same through the CLI and drops the old account's usage. A signed-out provider reports loggedIn false with no account or usage, a login restores it, and an unknown provider is rejected as invalid_argument. In the visible UI the Agents info section sits at the bottom of the left sidebar, below the Scheduled Tasks button and inside it, titled Agents info, with a separate compact Claude block and Codex block, each showing its account and plan together on the row beneath the provider name, its window rows with percentages and reset times, and a switch-account button; Codex's credits show in its block and Claude's warning status shows as Near limit. After a Claude turn whose usage read reports the plan's spend, the open window shows Claude's Spend limit row with its percent and reset time and the updated 5h row without a relaunch. A signed-out provider shows a Log in button instead of usage, which starts the login and brings usage back, and switching the account signs out and in without asking when no task for that provider is running. The section is open by default and its title is a button that minimizes it: the agent blocks go away and the title moves down to rest at the bottom of the sidebar, and expanding brings them back; the choice is remembered, so a section minimized before a relaunch is still minimized afterwards. Every read reports whether each CLI is installed from the same executable lookup Playhouse launches it with; an agent whose CLI is not installed has no block, and with neither installed the section is not shown. While a task for a provider is running, its switch-account button first asks for confirmation naming how many of its tasks are running, and cancelling keeps the account.
    func test_agents_info_shows_provider_usage_and_accounts() throws {
        let codexExecutable = try makeCodexFixture(emptyQuestions: false)
        let codexAccount = URL(fileURLWithPath: codexExecutable.path + ".account")
        try? FileManager.default.removeItem(at: codexAccount)
        defer { try? FileManager.default.removeItem(at: codexAccount) }
        codexFixtureExecutable = codexExecutable.path
        let claudeExecutable = dataDirectory.appendingPathComponent("claude-fixture-agents-info")
        try copyFixtureFile(at: WorkspaceFixture.root.appendingPathComponent("claude-fixture-ui"), to: claudeExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claudeExecutable.path)
        try "Playhouse test owns this Claude Code protocol fixture (v1).\n".write(
            to: dataDirectory.appendingPathComponent(".playhouse-claude-fixture-owner"), atomically: true, encoding: .utf8
        )
        claudeFixtureExecutable = claudeExecutable.path
        launchApp(defaultParent: fixture.parent.path)

        func text(_ identifier: String) -> String {
            let match = element(identifier)
            return match.exists ? accessibleLabelOrValue(of: match) : ""
        }

        // The section sits at the bottom of the sidebar, below the Scheduled Tasks button, with one block per agent.
        let sidebar = element(withAccessibilityLabel: "Kanban sidebar")
        let section = element("agents-info")
        XCTAssertTrue(section.waitToExist(timeout: 30), "Agents info should appear once an agent CLI is installed.")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label =[c] %@ OR value =[c] %@", "Agents info", "Agents info")).firstMatch.exists, "The section should be titled Agents info.")
        XCTAssertTrue(sidebar.frame.contains(section.frame), "Agents info should be inside the left sidebar.")
        XCTAssertLessThanOrEqual(element("scheduled-tasks-button").frame.maxY, section.frame.minY, "Agents info should sit below the Scheduled Tasks button.")
        XCTAssertLessThan(sidebar.frame.maxY - section.frame.maxY, 40, "Agents info should be pinned at the bottom of the sidebar.")
        let claudeBlock = element("agents-info-claude")
        let codexBlock = element("agents-info-codex")
        XCTAssertTrue(claudeBlock.exists && codexBlock.exists, "Claude and Codex should each have their own block.")
        XCTAssertLessThanOrEqual(claudeBlock.frame.maxY, codexBlock.frame.minY, "The blocks should be separate, Claude above Codex.")
        XCTAssertLessThan(section.frame.height, 330, "The section should stay a compact sidebar footer.")
        let toggle = element("agents-info-toggle")
        XCTAssertEqual(toggle.value as? String, "Expanded", "The section should be open by default.")
        let expandedTitleMinY = toggle.frame.minY

        // Codex shows its account, both windows, and credits from the app-server; Claude has no usage until a task runs.
        XCTAssertTrue(element("agents-info-codex-window-secondary").waitToExist(timeout: 30), "Codex usage should show soon after launch.")
        XCTAssertEqual(text("agents-info-codex-account"), "codex-fixture@example.com Plus", "The account and plan should share the row below the provider name.")
        let codexName = element("agents-info-codex").staticTexts["Codex"]
        XCTAssertGreaterThanOrEqual(element("agents-info-codex-account").frame.minY, codexName.frame.maxY, "Codex account and plan should be below the provider name.")
        let primary = text("agents-info-codex-window-primary")
        XCTAssertTrue(primary.contains("5h") && primary.contains("30%") && primary.contains("Resets in"), "Codex's 5h window should show its percent and reset time: \(primary)")
        let secondary = text("agents-info-codex-window-secondary")
        XCTAssertTrue(secondary.contains("Weekly") && secondary.contains("62%"), "Codex's weekly window should show its percent: \(secondary)")
        XCTAssertEqual(text("agents-info-codex-credits"), "Credits: 12.50")
        XCTAssertEqual(text("agents-info-claude-account"), "claude-fixture@example.com Max", "The account and plan should share the row below the provider name.")
        let claudeName = element("agents-info-claude").staticTexts["Claude"]
        XCTAssertGreaterThanOrEqual(element("agents-info-claude-account").frame.minY, claudeName.frame.maxY, "Claude account and plan should be below the provider name.")
        XCTAssertEqual(text("agents-info-claude-empty"), "No data yet", "Claude should say it has no data yet.")
        XCTAssertTrue(element("agents-info-switch-claude").exists && element("agents-info-switch-codex").exists, "Each agent should offer a switch-account button.")
        attachScreenshot(named: "Agents info with Codex usage and Claude awaiting data")

        func attachCodexBlock(_ name: String) {
            let attachment = XCTAttachment(screenshot: codexBlock.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        attachCodexBlock("Codex usage before external change")
        let periodicClaudeUsage = URL(fileURLWithPath: claudeExecutable.path + ".usage")
        try JSONSerialization.data(withJSONObject: ["rate_limits_available": true, "rate_limits": [
            "five_hour": ["utilization": 24, "resets_at": "2099-01-01T00:00:00Z"],
        ]]).write(to: periodicClaudeUsage, options: .atomic)
        // An external Codex client can consume usage without sending this server a push.
        try JSONSerialization.data(withJSONObject: ["loggedIn": true, "email": "codex-fixture@example.com", "used": [47, 68]])
            .write(to: codexAccount, options: .atomic)
        XCTAssertTrue(waitUntil({ text("agents-info-codex-window-primary").contains("47%") }, timeout: 45), "An open window should refresh Codex usage changed elsewhere.")
        XCTAssertTrue(text("agents-info-codex-window-secondary").contains("68%"))
        attachScreenshot(named: "Agents info after external Codex usage changes")
        attachCodexBlock("Codex usage after external change")
        XCTAssertTrue(waitUntil({ text("agents-info-claude-window-five_hour").contains("24%") }, timeout: 45), "The periodic refresh should also read externally changed Claude usage.")
        attachScreenshot(named: "Agents info after external Claude usage changes")
        let claudeAttachment = XCTAttachment(screenshot: claudeBlock.screenshot())
        claudeAttachment.name = "Claude usage after external change"
        claudeAttachment.lifetime = .keepAlways
        add(claudeAttachment)
        try FileManager.default.removeItem(at: periodicClaudeUsage)

        // A Claude turn's rate-limit event reaches the open window without a relaunch.
        let created = try XCTUnwrap(try runCLI(["task", "create", "--title", "Claude usage UI", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude"])["result"] as? [String: Any])
        let claudeTaskID = try XCTUnwrap(created["id"] as? String)
        let eventURL = URL(fileURLWithPath: claudeExecutable.path + ".rate-limit-event")
        func claudeTurn(_ info: [String: Any]) throws {
            let event = try JSONSerialization.data(withJSONObject: ["type": "rate_limit_event", "rate_limit_info": info])
            try event.write(to: eventURL)
            _ = try runCLI(["conversation", "send", claudeTaskID, "--message", "Say hello."])
        }
        let now = Int(Date().timeIntervalSince1970)
        try claudeTurn([
            "status": "allowed_warning", "rateLimitType": "five_hour", "utilization": 0.83, "resetsAt": now + 3600,
            "unifiedWindows": [
                "five_hour": ["utilization": 0.83, "resetsAt": now + 3600],
                "seven_day": ["utilization": 0.41, "resetsAt": now + 3 * 86400],
            ],
        ])
        XCTAssertTrue(waitUntil({ text("agents-info-claude-window-five_hour").contains("83%") }, timeout: 40), "Claude's 5h usage should update from its rate-limit event.")
        XCTAssertTrue(text("agents-info-claude-window-seven_day").contains("41%"), "Claude's weekly usage should update too.")
        XCTAssertEqual(text("agents-info-claude-status"), "Near limit", "A warning status should show on the block.")
        XCTAssertFalse(element("agents-info-claude-empty").exists)
        attachScreenshot(named: "Agents info with Claude usage near its limit")

        // A window past its reset time reads as reset, and the limit lifts with it.
        try claudeTurn(["status": "rejected", "rateLimitType": "five_hour", "utilization": 1.0, "resetsAt": now - 10])
        XCTAssertTrue(waitUntil({ text("agents-info-claude-window-five_hour").contains("Reset") && text("agents-info-claude-window-five_hour").contains("0%") }, timeout: 40), "A window past its reset time should show as reset.")
        XCTAssertFalse(element("agents-info-claude-status").exists, "The limit state should lift once its window has reset.")
        XCTAssertTrue(text("agents-info-claude-window-seven_day").contains("41%"))

        // Claude Code streams an event only when a limit's status changes, and a usage-based plan's event has no
        // percent, so every finished turn reads the plan's usage through get_usage and the open window follows it.
        let usageURL = URL(fileURLWithPath: claudeExecutable.path + ".usage")
        defer { try? FileManager.default.removeItem(at: usageURL) }
        func iso(_ seconds: Int) -> String { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(seconds))) }
        try JSONSerialization.data(withJSONObject: ["rate_limits_available": true, "rate_limits": [
            "five_hour": ["utilization": 12.0, "resets_at": iso(now + 7200)],
            "seven_day": ["utilization": 0.5, "resets_at": iso(now + 5 * 86400)],
            "extra_usage": ["is_enabled": true, "utilization": 51.7, "spend_limit_reached": false],
        ]]).write(to: usageURL)
        try claudeTurn(["status": "allowed", "rateLimitType": "overage", "resetsAt": now + 20 * 86400, "isUsingOverage": false])
        XCTAssertTrue(waitUntil({ text("agents-info-claude-window-overage").contains("52%") }, timeout: 40), "A finished turn should read Claude's spend from get_usage.")
        let spend = text("agents-info-claude-window-overage")
        XCTAssertTrue(spend.contains("Spend limit") && spend.contains("Resets in"), "The spend row should be labelled and keep the stream's monthly reset: \(spend)")
        let fiveHour = text("agents-info-claude-window-five_hour")
        XCTAssertTrue(fiveHour.contains("12%") && fiveHour.contains("Resets in"), "The read should replace the reset 5h window with the current one: \(fiveHour)")
        let weekly = text("agents-info-claude-window-seven_day")
        XCTAssertTrue(weekly.contains("1%") && !weekly.contains("41%") && !weekly.contains("50%"), "get_usage's 0.5 is a percent, shown rounded as 1%: \(weekly)")
        XCTAssertFalse(element("agents-info-claude-empty").exists)
        attachScreenshot(named: "Agents info with Claude usage read after a turn")
        // The account switched to below has no usage of its own.
        try FileManager.default.removeItem(at: usageURL)

        // While a Codex task runs, switching asks first, and cancelling keeps the account.
        let holdMarker = URL(fileURLWithPath: codexExecutable.path + ".hold-release")
        let turnActive = URL(fileURLWithPath: codexExecutable.path + ".turn-active")
        let turnRelease = URL(fileURLWithPath: codexExecutable.path + ".turn-release")
        for marker in [turnActive, turnRelease] { try? FileManager.default.removeItem(at: marker) }
        try Data("hold\n".utf8).write(to: holdMarker)
        defer { try? FileManager.default.removeItem(at: holdMarker) }
        try createTaskFixture(title: "Running Codex task", roots: [fixture.primary.path])
        let runningTaskID = try taskID(named: "Running Codex task")
        openTask(named: "Running Codex task")
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 15), "The task should open its composer.")
        composer.click()
        composer.typeText("Hold this turn.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: turnActive.path) }, timeout: 30), "The Codex turn should be running.")
        element("back-to-board-button").click()
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: runningTaskID)?["status"] as? String) == "In Progress" }, timeout: 10))
        // The confirmation counts the board's own tasks, so wait until the board shows it running.
        XCTAssertTrue(element("column-in-progress").buttons["task-card-\(runningTaskID.uppercased())"].waitToExist(timeout: 10), "The board should show the Codex task running.")
        let codexAccountBeforeCancel = try Data(contentsOf: codexAccount)
        element("agents-info-switch-codex").click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitToExist(timeout: 10), "Switching with a running Codex task should ask for confirmation.")
        XCTAssertTrue(sheet.buttons["Switch Account"].exists)
        XCTAssertTrue(sheet.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "1 Codex task is running", "1 Codex task is running")).firstMatch.exists, "The confirmation should name the running task.")
        attachScreenshot(named: "Switching the Codex account asks first while a Codex task runs")
        sheet.buttons["Cancel"].click()
        XCTAssertTrue(waitForDisappearance(sheet))
        // A switch would sign out through the fixture, which records the change in its account file.
        XCTAssertFalse(waitUntil({
            (try? Data(contentsOf: codexAccount)) != codexAccountBeforeCancel || text("agents-info-codex-account") != "codex-fixture@example.com Plus"
        }, timeout: 5), "Cancelling must not sign the account out.")
        try? FileManager.default.removeItem(at: holdMarker)
        try Data("release\n".utf8).write(to: turnRelease)
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: runningTaskID)?["status"] as? String) != "In Progress" }, timeout: 60), "The held turn should finish.")

        // With nothing running, switching signs out and in again, and the new account's usage replaces the old.
        element("agents-info-switch-codex").click()
        XCTAssertTrue(waitUntil({ text("agents-info-codex-account") == "codex-second@example.com Plus" }, timeout: 40), "The switched Codex account should show.")
        XCTAssertTrue(waitUntil({ text("agents-info-codex-window-primary").contains("7%") }, timeout: 20), "The new account's usage should replace the old.")
        XCTAssertFalse(app.sheets.firstMatch.exists, "Switching with nothing running needs no confirmation.")
        attachScreenshot(named: "Agents info after switching the Codex account")
        element("agents-info-switch-claude").click()
        XCTAssertTrue(waitUntil({ text("agents-info-claude-account").hasPrefix("claude-second@example.com") }, timeout: 40), "The switched Claude account should show.")
        XCTAssertTrue(element("agents-info-claude-empty").waitToExist(timeout: 10), "The old Claude account's usage must not carry over.")

        // A signed-out agent shows Log in instead of usage; logging in brings its usage back.
        try JSONSerialization.data(withJSONObject: ["loggedIn": false, "email": NSNull(), "used": [0, 0]]).write(to: codexAccount)
        try JSONSerialization.data(withJSONObject: ["loggedIn": false]).write(to: URL(fileURLWithPath: claudeExecutable.path + ".auth-state"))
        XCTAssertTrue(terminateAppAndWait(app), "Playhouse must stop before the signed-out relaunch.")
        launchAppWithOpen()
        waitForBoardOrAbortSuite()
        XCTAssertTrue(element("agents-info-login-codex").waitToExist(timeout: 40), "A signed-out Codex should offer Log in.")
        XCTAssertTrue(element("agents-info-login-claude").exists, "A signed-out Claude should offer Log in.")
        XCTAssertFalse(element("agents-info-codex-window-primary").exists, "A signed-out agent shows no usage.")
        attachScreenshot(named: "Agents info with both agents signed out")
        element("agents-info-login-claude").click()
        XCTAssertTrue(waitUntil({ text("agents-info-claude-account").hasPrefix("claude-second@example.com") }, timeout: 40), "Logging in to Claude should restore its account.")
        XCTAssertFalse(element("agents-info-login-claude").exists)
        element("agents-info-login-codex").click()
        XCTAssertTrue(waitUntil({ text("agents-info-codex-account") == "codex-second@example.com Plus" }, timeout: 40), "Logging in to Codex should restore its account.")
        XCTAssertTrue(waitUntil({ text("agents-info-codex-window-primary").contains("7%") }, timeout: 20), "Logging in should bring Codex usage back.")
        attachScreenshot(named: "Agents info after logging in again")

        // Minimizing hides the blocks and rests the title at the bottom of the sidebar; the choice is sticky.
        toggle.click()
        XCTAssertTrue(waitUntil({ !self.element("agents-info-claude").exists && !self.element("agents-info-codex").exists }, timeout: 10), "Minimizing should hide the agent blocks.")
        XCTAssertEqual(toggle.value as? String, "Collapsed")
        XCTAssertGreaterThan(toggle.frame.minY, expandedTitleMinY, "The title should move down as the section collapses.")
        XCTAssertLessThan(sidebar.frame.maxY - toggle.frame.maxY, 40, "The minimized title should rest at the bottom of the sidebar.")
        attachScreenshot(named: "Agents info minimized at the bottom of the sidebar")
        XCTAssertTrue(terminateAppAndWait(app), "Playhouse must stop before the minimized relaunch.")
        launchAppWithOpen()
        waitForBoardOrAbortSuite()
        XCTAssertTrue(toggle.waitToExist(timeout: 40), "The minimized title should still show after a relaunch.")
        XCTAssertEqual(toggle.value as? String, "Collapsed", "A minimized section should stay minimized after a relaunch.")
        XCTAssertFalse(element("agents-info-claude").exists || element("agents-info-codex").exists)
        attachScreenshot(named: "Agents info still minimized after relaunch")
        toggle.click()
        XCTAssertTrue(element("agents-info-claude").waitToExist(timeout: 10), "Expanding should bring the agent blocks back.")
        XCTAssertEqual(toggle.value as? String, "Expanded")

        // An agent whose CLI is not installed has no block; with neither installed the section is gone.
        // Without a fixture the harness passes `none`, so the real CLIs on the machine are never found.
        claudeFixtureExecutable = nil
        XCTAssertTrue(terminateAppAndWait(app), "Playhouse must stop before the Codex-only relaunch.")
        launchAppWithOpen()
        waitForBoardOrAbortSuite()
        XCTAssertTrue(element("agents-info-codex").waitToExist(timeout: 40), "Codex, still installed, keeps its block.")
        XCTAssertFalse(element("agents-info-claude").exists, "Claude, not installed, should have no block.")
        attachScreenshot(named: "Agents info with only Codex installed")
        codexFixtureExecutable = nil
        XCTAssertTrue(terminateAppAndWait(app), "Playhouse must stop before the no-agents relaunch.")
        launchAppWithOpen()
        waitForBoardOrAbortSuite()
        let bare = try XCTUnwrap(try runCLI(["usage", "get"])["result"] as? [String: Any])
        let installed = (bare["providers"] as? [[String: Any]] ?? []).map { $0["installed"] as? Bool }
        XCTAssertEqual(installed, [false, false], "Neither CLI is installed without the fixtures.")
        XCTAssertFalse(waitUntil({ self.element("agents-info").exists }, timeout: 15), "With neither CLI installed the section should not show.")
        XCTAssertTrue(element(withAccessibilityLabel: "Kanban sidebar").exists)
        attachScreenshot(named: "Sidebar without Agents info when no agent CLI is installed")
    }
    // case-contract: test_app_override_rejects_incompatible_bundles | Explicit app overrides reject obsolete compatibility metadata, foreign worktree or bridge identities, test IDs that do not match the current worktree, and nonisolated test data before launching; the current app preserves a saved draft across restart.
    func test_app_override_rejects_incompatible_bundles() throws {
        let root = repositoryRoot.path
        // Saving the untitled draft starts a title-generation turn; without a
        // fixture that turn runs the installed Codex CLI, whose sign-in retries
        // keep writing diagnostics while the launch-contract check compares them.
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)
        openNewTaskConversation()
        chooseRepositorySuggestion("primary")
        saveNewTaskPromptAndReturnToBoard("Protected store", prompt: "Protected draft")
        XCTAssertTrue(terminateAppAndWait(app))
        // The bridge daemon outlives the window; let work it already accepted finish
        // logging before the check snapshots diagnostics.
        let diagnosticsURL = dataDirectory.appendingPathComponent("Diagnostics.jsonl")
        func diagnosticsSize() -> Int { ((try? FileManager.default.attributesOfItem(atPath: diagnosticsURL.path))?[.size] as? Int) ?? -1 }
        var settledSize = diagnosticsSize()
        var settledSince = Date()
        XCTAssertTrue(waitUntil({
            let size = diagnosticsSize()
            if size != settledSize { settledSize = size; settledSince = Date() }
            return Date().timeIntervalSince(settledSince) >= 3
        }, timeout: 20), "Bridge diagnostics should settle after the window quits.")
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        check.arguments = ["python3", root + "/scripts/check-app-launch-contract.py", appBundle.path, root, dataDirectory.path]
        let directGitPaths = [
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/Applications/Xcode_26.5.app/Contents/Developer/usr/bin/git"
        ]
        let directGit = try XCTUnwrap(directGitPaths.first { FileManager.default.isExecutableFile(atPath: $0) })
        var checkEnvironment = ProcessInfo.processInfo.environment
        checkEnvironment["PATH"] = URL(fileURLWithPath: directGit).deletingLastPathComponent().path + ":" + (checkEnvironment["PATH"] ?? "")
        check.environment = checkEnvironment
        let output = Pipe()
        check.standardOutput = output
        check.standardError = output
        try check.run()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        check.waitUntilExit()
        XCTAssertEqual(check.terminationStatus, 0, text)
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Protected store")
        XCTAssertEqual(element("message-composer").value as? String, "Protected draft")
    }
    // case-contract: test_worktree_app_profiles_isolate_identity_and_store | The primary and linked source worktrees resolve to stable, distinct app and XPC identities, build paths, data stores, logs, and managed worktree roots, each worktree root inside its data directory. The run.sh launch resolver replaces a PLAYHOUSE_DATA_DIRECTORY inherited from another Playhouse app's profile directory with the launching worktree's own and rejects any other foreign data directory, and run.sh drops PLAYHOUSE_BRIDGE_SERVICE_NAME and PLAYHOUSE_BRIDGE_SOCKET_PATH inherited from another Playhouse app, saying so, while keeping the launching worktree's own bridge. run.sh keeps this worktree's running app open during its build and stops this worktree's app and bridge daemon only once, after the build and right before it opens the app, so a daemon started from the previous build during the build cannot serve the new app. A saved conversation remains visible after an app restart.
    func test_worktree_app_profiles_isolate_identity_and_store() throws {
        let script = repositoryRoot.appendingPathComponent("scripts/app-profile.sh")
        func profileScriptEnvironment() throws -> [String: String] {
            let directGitPaths = [
                "/opt/homebrew/bin/git",
                "/usr/local/bin/git",
                "/Library/Developer/CommandLineTools/usr/bin/git",
                "/Applications/Xcode.app/Contents/Developer/usr/bin/git"
            ]
            let directGitPath = try XCTUnwrap(
                directGitPaths.first { FileManager.default.isExecutableFile(atPath: $0) },
                "UI tests need a direct Git executable."
            )
            var environment = ProcessInfo.processInfo.environment
            let gitDirectory = URL(fileURLWithPath: directGitPath).deletingLastPathComponent().path
            environment["PATH"] = "\(gitDirectory):\(environment["PATH"] ?? "/usr/bin:/bin")"
            return environment
        }
        func profile(for worktree: URL) throws -> [String: String] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path, worktree.path]
            process.environment = try profileScriptEnvironment()
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            XCTAssertEqual(process.terminationStatus, 0, "Failed to resolve the worktree app profile: \(String(data: data, encoding: .utf8) ?? "")")
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        }

        let primary = try profile(for: fixture.primary)
        let linked = try profile(for: fixture.existingWorktree)
        XCTAssertEqual(primary["bundleID"], "com.playhouse.app")
        XCTAssertEqual(linked["kind"], "linked")
        XCTAssertEqual(linked, try profile(for: fixture.existingWorktree))
        for key in ["bundleID", "bridgeID", "derivedData", "dataDirectory", "logFile", "worktreeRoot"] {
            XCTAssertNotEqual(primary[key], linked[key], "Separate source worktrees must isolate \(key).")
        }
        for appProfile in [primary, linked] {
            XCTAssertEqual(appProfile["worktreeRoot"], appProfile["dataDirectory"].map {
                URL(fileURLWithPath: $0).appendingPathComponent("task-worktrees").path
            }, "Task worktrees must live inside the profile's data directory.")
        }
        XCTAssertEqual(linked["bridgeID"], linked["bundleID"].map { $0 + ".bridge" })
        XCTAssertEqual(linked["dataDirectory"], linked["key"].map {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Playhouse/Worktrees/\($0)").path
        })
        // scripts/run.sh launches with this resolver's directory. A value inherited
        // from another Playhouse app's agent session gives way to the profile's own.
        func launchDirectory(for worktree: URL, inherited: String?) throws -> (status: Int32, output: String, error: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [
                "-c", "source \"$1\"; playhouse_load_app_profile \"$2\"; playhouse_resolve_launch_data_directory",
                "launch-check", script.path, worktree.path
            ]
            var environment = try profileScriptEnvironment()
            environment["PLAYHOUSE_DATA_DIRECTORY"] = inherited
            process.environment = environment
            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error
            try process.run()
            process.waitUntilExit()
            return (
                process.terminationStatus,
                String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            )
        }
        let primaryDirectory = try XCTUnwrap(primary["dataDirectory"])
        let linkedDirectory = try XCTUnwrap(linked["dataDirectory"])
        let otherLinkedDirectory = URL(fileURLWithPath: linkedDirectory).deletingLastPathComponent()
            .appendingPathComponent("w0123456789abcdef").path
        let acceptedLaunches: [(URL, String, String?, Bool)] = [
            (fixture.existingWorktree, linkedDirectory, nil, false),
            (fixture.existingWorktree, linkedDirectory, linkedDirectory, false),
            (fixture.existingWorktree, linkedDirectory, primaryDirectory, true),
            (fixture.existingWorktree, linkedDirectory, primaryDirectory + "/", true),
            (fixture.existingWorktree, linkedDirectory, otherLinkedDirectory, true),
            (fixture.primary, primaryDirectory, linkedDirectory, true)
        ]
        for (worktree, expected, inherited, ignored) in acceptedLaunches {
            let result = try launchDirectory(for: worktree, inherited: inherited)
            XCTAssertEqual(result.status, 0, result.error)
            XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), expected, "Inherited \(inherited ?? "nil")")
            XCTAssertEqual(result.error.contains("inherited from another Playhouse app"), ignored, result.error)
        }
        let notAProfile = URL(fileURLWithPath: linkedDirectory).deletingLastPathComponent()
            .appendingPathComponent("not-a-profile").path
        for (worktree, inherited) in [
            (fixture.existingWorktree, dataDirectory.path),
            (fixture.existingWorktree, notAProfile),
            (fixture.primary, dataDirectory.path)
        ] {
            let result = try launchDirectory(for: worktree, inherited: inherited)
            XCTAssertEqual(result.status, 2, result.output)
            XCTAssertEqual(result.output, "")
            XCTAssertTrue(result.error.contains("PLAYHOUSE_DATA_DIRECTORY points elsewhere"), result.error)
        }
        // `open -n` hands the app run.sh's whole environment, so run.sh drops a
        // bridge daemon override inherited from another Playhouse app.
        func clearedBridge(service: String?, socket: String?) throws -> (status: Int32, output: String, error: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [
                "-c", "source \"$1\"; playhouse_load_app_profile \"$2\"; playhouse_clear_inherited_bridge_overrides; printf \"%s|%s\" \"${PLAYHOUSE_BRIDGE_SERVICE_NAME:-}\" \"${PLAYHOUSE_BRIDGE_SOCKET_PATH:-}\"",
                "bridge-check", script.path, fixture.existingWorktree.path
            ]
            var environment = try profileScriptEnvironment()
            environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"] = service
            environment["PLAYHOUSE_BRIDGE_SOCKET_PATH"] = socket
            process.environment = environment
            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error
            try process.run()
            process.waitUntilExit()
            return (
                process.terminationStatus,
                String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            )
        }
        let ownBridge = try XCTUnwrap(linked["bridgeID"])
        let bridgeCases: [(String?, String?, String, Bool)] = [
            (try XCTUnwrap(primary["bridgeID"]), "/tmp/parent-bridge.sock", "|", true),
            (nil, "/tmp/parent-bridge.sock", "|", true),
            (ownBridge, "/tmp/own-bridge.sock", "\(ownBridge)|/tmp/own-bridge.sock", false),
            (nil, nil, "|", false)
        ]
        for (service, socket, expected, ignored) in bridgeCases {
            let result = try clearedBridge(service: service, socket: socket)
            XCTAssertEqual(result.status, 0, result.error)
            XCTAssertEqual(result.output, expected, "Inherited \(service ?? "nil") / \(socket ?? "nil")")
            XCTAssertEqual(result.error.contains("inherited from another Playhouse app"), ignored, result.error)
        }
        let runScript = try String(contentsOf: script.deletingLastPathComponent().appendingPathComponent("run.sh"), encoding: .utf8)
        XCTAssertTrue(runScript.contains("playhouse_clear_inherited_bridge_overrides\nopen -n"),
                      "run.sh must clear inherited bridge overrides right before it opens the app.")
        XCTAssertTrue(runScript.contains("terminate_running_playhouse \"now that the new build is ready\"\nplayhouse_clear_inherited_bridge_overrides\nopen -n"),
                      "run.sh must stop a daemon started from the previous build right before it opens the app.")
        let buildIndex = try XCTUnwrap(runScript.range(of: "xcodebuild build")).lowerBound
        let relaunchStopIndex = try XCTUnwrap(runScript.range(of: "terminate_running_playhouse \"now that the new build is ready\"")).lowerBound
        XCTAssertLessThan(buildIndex, relaunchStopIndex, "run.sh must stop the previous build's processes after xcodebuild finishes.")
        XCTAssertEqual(runScript.components(separatedBy: "\nterminate_running_playhouse ").count - 1, 1,
                       "run.sh must keep the running app open during the build and stop it only once, after the build.")
        let launchedIdentifier = try XCTUnwrap(Bundle(url: appBundle)?.bundleIdentifier)
        let sourceProfile = try profile(for: repositoryRoot)
        XCTAssertTrue(launchedIdentifier.hasPrefix(try XCTUnwrap(sourceProfile["bundleID"]) + ".e2e."), "The test app must use the actual source checkout's identity, not a repository fixture's identity.")
        XCTAssertEqual(serviceName, launchedIdentifier + ".bridge")
        XCTAssertNotEqual(dataDirectory.path, primary["dataDirectory"])
        XCTAssertNotEqual(dataDirectory.path, linked["dataDirectory"])

        launchApp(defaultParent: fixture.parent.path)
        openNewTaskConversation()
        chooseRepositorySuggestion("primary")
        saveNewTaskPromptAndReturnToBoard("Worktree profile", prompt: "Keep this draft after restart.")
        XCTAssertEqual(try taskRecord(named: "Worktree profile")?["status"] as? String, "Backlog")
        relaunchApp()
        openTask(named: "Worktree profile")
        XCTAssertEqual(element("message-composer").value as? String, "Keep this draft after restart.")
        let store = dataDirectory.appendingPathComponent("Playhouse-v2.store")
        let log = dataDirectory.appendingPathComponent("Diagnostics.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.path))
        let diagnostics = try String(contentsOf: log, encoding: .utf8).split(whereSeparator: \.isNewline).compactMap {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        let loggedStorePaths = diagnostics.compactMap { $0["storePath"] as? String }
        XCTAssertTrue(loggedStorePaths.contains(store.path), "The test app's XPC log must name its isolated store.")
        let primaryDataDirectory = try XCTUnwrap(primary["dataDirectory"])
        XCTAssertFalse(loggedStorePaths.contains(where: { $0.hasPrefix(primaryDataDirectory) }), "The test app's log must not route to the primary store.")
    }
    // case-contract: test_task_creation_rejects_invalid_title_roots_and_missing_folder | New Task opens with the repository picker closed and composer focused; no selected repository is valid and shows no red missing-folder warning when the required repository root is configured. A standalone conversation can be sent without repository roots, while GUI and CLI reject sends if the configured repository root is missing. The UI and CLI accept standalone sends after the root is configured. The CLI accepts empty-root tasks and rejects blank titles, missing folders, unavailable roots, and invalid merge targets.
    func test_task_creation_rejects_invalid_title_roots_and_missing_folder() throws {
        codexFixtureExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-success").path
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: try XCTUnwrap(codexFixtureExecutable)))
        launchApp(defaultParent: nil)
        openNewTaskConversation()
        let standaloneTaskID = try taskID(named: "Untitled task")
        _ = try runCLI(["task", "rename", standaloneTaskID, "--title", "Standalone conversation"])
        XCTAssertTrue(element("empty-conversation").waitToExist(timeout: 10))
        XCTAssertEqual(repositoryTitle().value as? String, "No repository selected")
        let repositorySearch = element("conversation-repository-search")
        XCTAssertFalse(repositorySearch.exists, "New Task should keep the repository picker closed by default.")
        let composer = element("message-composer")
        XCTAssertTrue(composer.waitToExist(timeout: 10), "The chat composer should be visible.")
        XCTAssertTrue(element("repository-root-required-notice").exists, "An unset repository root should show the setup notice.")
        XCTAssertFalse(element("no-working-folders-error").exists, "A standalone conversation should not warn that a repository is missing.")
        composer.typeText("A standalone question that needs no repository context.")
        XCTAssertFalse(element("send-message-button").isEnabled, "Sending must stay disabled until the repository root is configured.")
        element("set-conversation-repository-root-button").click()
        try chooseFolder(in: openFolderPanel, folder: fixture.parent, confirmationButton: "Use This Folder")
        XCTAssertFalse(element("repository-root-required-notice").exists)
        XCTAssertFalse(element("conversation-repository-search").exists, "Setting the root should leave the picker closed.")
        XCTAssertTrue(element("send-message-button").isEnabled, "A configured root should permit standalone work without selecting a repository.")
        let standalonePrompt = "A standalone question that needs no repository context."
        element("send-message-button").click()
        let submittedPrompt = app.textViews.matching(NSPredicate(format: "value == %@", standalonePrompt)).firstMatch
        XCTAssertTrue(submittedPrompt.waitToExist(timeout: 10), "The UI should submit a standalone conversation after the root is configured.")
        let mainHistoryURL = URL(fileURLWithPath: try XCTUnwrap(codexFixtureExecutable) + ".history")
        // The fixture writes its history once the thread starts, which can trail the prompt showing in the transcript.
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: mainHistoryURL.path) }, timeout: 10), "The standalone send should reach the provider.")
        let mainHistory = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: mainHistoryURL)) as? [String: Any])
        let instructions = try XCTUnwrap(mainHistory["threadStartDeveloperInstructions"] as? String)
        XCTAssertTrue(instructions.contains("read-only inspection of returned source paths"))
        XCTAssertTrue(instructions.contains("Add a repository to this task only when you intend to create or commit changes in it"))
        XCTAssertTrue(instructions.contains("Do not interrupt the user or ask them to confirm the selection merely because the task appears unrelated."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(codexFixtureExecutable) + ".assessment.history"), "A new conversation should not launch a separate repository assessment.")

        assertCLIError(
            try runCLI(["task", "create", "--title", "   ", "--prompt", "Fixture task description.", "--root", fixture.primary.path], expectedStatus: 2),
            code: "invalid_argument"
        )
        let emptyRootTask = try XCTUnwrap(
            try runCLI(["task", "create", "--title", "No roots", "--prompt", "Fixture task description."])["result"] as? [String: Any]
        )
        XCTAssertEqual(emptyRootTask["workspaceRoots"] as? [String], [])
        XCTAssertTrue(try XCTUnwrap(emptyRootTask["repositoryWorktrees"] as? [[String: Any]]).isEmpty)
        let emptyRootTaskID = try XCTUnwrap(emptyRootTask["id"] as? String)
        _ = try runCLI(["settings", "clear-parent"])
        assertCLIError(
            try runCLI(["conversation", "send", emptyRootTaskID, "--message", "Standalone request"], expectedStatus: 1),
            code: "settings_required"
        )
        _ = try runCLI(["settings", "set-parent", fixture.parent.path])
        assertCLIError(
            try runCLI(
                ["task", "create", "--title", "Missing folder", "--prompt", "Fixture task description.", "--root", fixture.missing.path],
                expectedStatus: 2
            ),
            code: "invalid_argument"
        )
        assertCLIError(
            try runCLI([
                "task", "create", "--title", "Bad merge target", "--prompt", "Fixture task description.", "--repo", fixture.primary.path,
                "--merge-target", "\(fixture.primary.path)=not-a-local-branch"
            ], expectedStatus: 2),
            code: "invalid_argument"
        )
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10))
        let tasksAfterStandaloneSend = try tasksFromBoardList()
        XCTAssertEqual(tasksAfterStandaloneSend.count, 2, "The board should contain the standalone UI conversation and the separate CLI task.")
        XCTAssertTrue(tasksAfterStandaloneSend.contains { $0["id"] as? String == emptyRootTaskID })
        relaunchApp()
        openTask(named: "No roots")
        let reopenedComposer = element("chat-composer")
        XCTAssertTrue(reopenedComposer.waitToExist(timeout: 10), "The reopened task should show its chat composer.")
        XCTAssertFalse(element("no-working-folders-error").exists, "An empty-root standalone task should not show a red missing-folder warning.")
        let deletedEmptyRootTask = try XCTUnwrap(
            try runCLI(["task", "delete", emptyRootTaskID])["result"] as? [String: Any]
        )
        XCTAssertEqual(deletedEmptyRootTask["deleted"] as? Bool, true)
        attachScreenshot(named: "Standalone task has no missing-folder warning")
    }
    // case-contract: test_task_creation_persists_ordered_roots_across_fresh_connections | A directly created conversation can add repositories in order, edit pending branch settings, and add a context folder; these settings persist across fresh connections without creating branches or worktrees before the first send. The conversation shows the additional context folder without repeating repository worktrees in a Working in summary. Saving an unsent prompt records task creation, prompt save, and subsequent reads with safe argument metadata, result state, and outcome while excluding prompt text.
    func test_task_creation_persists_ordered_roots_across_fresh_connections() throws {
        launchApp(defaultParent: fixture.parent.path)
        openNewTaskConversation()
        chooseRepositorySuggestion("secondary")
        chooseRepositorySuggestion("primary")
        setConversationRepositoryField("secondary", field: "branch", value: "ordered-roots")
        setConversationRepositoryField("primary", field: "branch", value: "ordered-roots")
        setConversationRepositoryField("secondary", field: "branch-from", value: "branch-source")
        setConversationRepositoryField("primary", field: "branch-from", value: "branch-source")
        setConversationRepositoryField("primary", field: "merge-target", value: "branch-source")
        let prompt = "PROMPT_TEXT_NOT_IN_DIAGNOSTICS_\(UUID().uuidString)"
        saveNewTaskPromptAndReturnToBoard("Ordered roots", prompt: prompt)
        openTask(named: "Ordered roots")
        let task = try XCTUnwrap(taskRecord(named: "Ordered roots"))
        let records = try XCTUnwrap(task["repositoryWorktrees"] as? [[String: Any]])
        let expectedRoots = try XCTUnwrap(task["workspaceRoots"] as? [String])
        XCTAssertEqual(records.map { $0["repositoryPath"] as? String }, [fixture.secondary.path, fixture.primary.path])
        XCTAssertEqual(records.map { $0["branch"] as? String }, ["ordered-roots", "ordered-roots"])
        XCTAssertEqual(records.map { $0["branchFrom"] as? String }, ["branch-source", "branch-source"])
        XCTAssertEqual(records.map { $0["mergeTarget"] as? String }, ["main", "branch-source"])
        XCTAssertEqual(records.map { $0["isPending"] as? Bool }, [true, true])
        XCTAssertEqual(records.map { $0["worktreePath"] as? String }, [fixture.secondary.path, fixture.primary.path])
        XCTAssertEqual(expectedRoots, [fixture.secondary.path, fixture.primary.path])
        for repository in [fixture.secondary, fixture.primary] {
            XCTAssertEqual(try runGitOutput(repository, "branch", "--list", "ordered-roots").trimmingCharacters(in: .whitespacesAndNewlines), "")
        }
        assertOrderedRoots(expectedRoots)
        XCTAssertEqual(task["status"] as? String, "Backlog")
        let freshRead = try runCLI(["task", "get", try taskID(named: "Ordered roots")])
        let freshTask = try XCTUnwrap(freshRead["result"] as? [String: Any])
        XCTAssertEqual(freshTask["id"] as? String, task["id"] as? String)
        XCTAssertEqual(freshTask["title"] as? String, task["title"] as? String)
        XCTAssertEqual(freshTask["status"] as? String, task["status"] as? String)
        XCTAssertEqual(freshTask["workspaceRoots"] as? [String], expectedRoots)
        let freshRecords = try XCTUnwrap(freshTask["repositoryWorktrees"] as? [[String: Any]])
        XCTAssertEqual(freshRecords.map { $0["repositoryPath"] as? String }, records.map { $0["repositoryPath"] as? String })
        XCTAssertEqual(freshRecords.map { $0["branch"] as? String }, records.map { $0["branch"] as? String })
        XCTAssertEqual(freshRecords.map { $0["worktreePath"] as? String }, records.map { $0["worktreePath"] as? String })

        let events = try diagnosticEvents()
        let serializedDiagnostics = String(data: try JSONSerialization.data(withJSONObject: events), encoding: .utf8) ?? ""
        XCTAssertFalse(serializedDiagnostics.contains(prompt), "Diagnostics must retain prompt metadata without storing the prompt text.")
        let createdTaskID = try XCTUnwrap(task["id"] as? String)
        let taskCreate = try XCTUnwrap(events.first {
            $0["event"] as? String == "task.create.succeeded" && $0["taskID"] as? String == createdTaskID
        })
        XCTAssertEqual(taskCreate["status"] as? String, "Backlog")
        XCTAssertTrue(events.contains {
            $0["event"] as? String == "persistence.write.succeeded"
                && $0["taskID"] as? String == createdTaskID
        })
        XCTAssertEqual(events.filter {
            $0["event"] as? String == "workspace.repository.add.succeeded"
                && $0["taskID"] as? String == createdTaskID
        }.count, 2)
        // An unsent prompt is saved as the composer's draft, not as a submitted prompt.
        let promptSave = try XCTUnwrap(events.first {
            $0["event"] as? String == "task.draft.write.succeeded" && $0["taskID"] as? String == createdTaskID
        })
        XCTAssertEqual(promptSave["status"] as? String, "Backlog")
        XCTAssertTrue(events.contains {
            $0["event"] as? String == "task.draft.write.started" && $0["taskID"] as? String == createdTaskID
                && $0["promptByteCount"] as? String == String(prompt.utf8.count)
        }, "The draft write should record the prompt's size without its text.")
        XCTAssertFalse(events.contains {
            $0["event"] as? String == "task.prompt.write.started" && $0["taskID"] as? String == createdTaskID
                && $0["submitted"] as? String == "true"
        }, "Saving an unsent prompt must not submit it.")
        XCTAssertTrue(events.contains {
            $0["event"] as? String == "persistence.read.succeeded"
                && $0["operation"] as? String == "BoardTaskManager.requireTask"
                && $0["taskID"] as? String == task["id"] as? String
        }, "The log should record a successful task read with its ID.")
        XCTAssertTrue(events.contains {
            $0["event"] as? String == "bridge.request.succeeded" && $0["command"] as? String == "board.list"
        }, "The log should record the board read outcome.")

        app.buttons["back-to-board-button"].click()
        relaunchApp()
        openTask(named: "Ordered roots")
        assertOrderedRoots(expectedRoots)
        attachScreenshot(named: "Ordered roots persist across UI and XPC reopen")
    }
    // case-contract: test_task_creation_reuses_existing_branch_worktree | A selected existing branch remains pending until task start, then reuses its exact existing worktree path.
    func test_task_creation_reuses_existing_branch_worktree() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)
        openNewTaskConversation()
        chooseRepositorySuggestion("primary")
        setConversationRepositoryField("primary", field: "branch", value: "ui-existing-worktree")
        saveNewTaskPromptAndReturnToBoard("Reuse existing")
        let task = try XCTUnwrap(taskRecord(named: "Reuse existing"))
        let records = try XCTUnwrap(task["repositoryWorktrees"] as? [[String: Any]])
        XCTAssertEqual(records.first?["isPending"] as? Bool, true)
        XCTAssertEqual(records.first?["worktreePath"] as? String, fixture.primary.path)
        openTask(named: "Reuse existing")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Reuse existing")
        let started = try XCTUnwrap((taskRecord(named: "Reuse existing")?["repositoryWorktrees"] as? [[String: Any]])?.first)
        XCTAssertEqual(started["isPending"] as? Bool, false)
        XCTAssertEqual(started["worktreePath"] as? String, fixture.existingWorktree.path)
        XCTAssertEqual(started["createdByPlayhouse"] as? Bool, false)
        attachScreenshot(named: "Task start reuses the existing branch worktree")
    }
    // case-contract: test_task_creation_creates_worktrees_in_multiple_repositories | The conversation picker can add multiple repositories; unset branch settings display defaults and persist pending auto records resolved to local main without creating branches or worktrees before the first send.
    func test_task_creation_creates_worktrees_in_multiple_repositories() throws {
        let branchToken = String(UUID().uuidString.prefix(8)).lowercased()
        let taskTitle = "Multi repository UI \(branchToken)"
        let generatedBranch = "multi-repository-ui-\(branchToken)"
        launchApp(defaultParent: fixture.parent.path)
        openNewTaskConversation()
        chooseRepositorySuggestion("secondary")
        chooseRepositorySuggestion("primary")
        let pendingTask = try XCTUnwrap(tasksFromBoardList().first)
        let pendingRecords = try XCTUnwrap(pendingTask["repositoryWorktrees"] as? [[String: Any]])
        XCTAssertEqual(pendingRecords.map { $0["branch"] as? String }, ["auto", "auto"])
        saveNewTaskPromptAndReturnToBoard(taskTitle)
        let task = try XCTUnwrap(taskRecord(named: taskTitle))
        let records = try XCTUnwrap(task["repositoryWorktrees"] as? [[String: Any]])
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map { $0["repositoryPath"] as? String }, [fixture.secondary.path, fixture.primary.path])
        XCTAssertEqual(records.map { $0["branch"] as? String }, ["auto", "auto"])
        XCTAssertEqual(records.map { $0["isPending"] as? Bool }, [true, true])
        XCTAssertEqual(records.map { $0["worktreePath"] as? String }, [fixture.secondary.path, fixture.primary.path])
        XCTAssertEqual(records.map { $0["branchFrom"] as? String }, ["main", "main"])
        for repository in [fixture.secondary, fixture.primary] {
            XCTAssertEqual(try runGitOutput(repository, "branch", "--list", generatedBranch).trimmingCharacters(in: .whitespacesAndNewlines), "")
        }
        assertTaskVisible(taskTitle, inColumn: "Backlog")
        openTask(named: taskTitle)
        XCTAssertTrue(element("task-view-title").waitToExist(timeout: 10))
        XCTAssertTrue(element("conversation-repository-badge-secondary").exists)
        XCTAssertTrue(element("conversation-repository-badge-primary").exists)
        attachScreenshot(named: "A task has a separate worktree for each selected repository")
    }
    // case-contract: test_task_creation_supports_non_git_folder_only_context | A folder-only task persists its context without Git worktrees and reaches Done after a successful turn without attempting a merge.
    func test_task_creation_supports_non_git_folder_only_context() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)
        openNewTaskConversation()
        closeConversationRepositoryPicker()
        saveNewTaskPromptAndReturnToBoard("Folder-only UI")
        let taskID = try taskID(named: "Folder-only UI")
        let roots = try runCLI(["task", "roots", "set", taskID, "--root", fixture.custom.path])
        let rootsRecord = try XCTUnwrap(roots["result"] as? [String: Any])
        XCTAssertEqual(((rootsRecord["repositoryWorktrees"] as? [[String: Any]]) ?? []).count, 0)
        XCTAssertEqual(rootsRecord["contextFolders"] as? [String], [fixture.custom.path])
        XCTAssertEqual(rootsRecord["workspaceRoots"] as? [String], [fixture.custom.path])
        assertTaskVisible("Folder-only UI", inColumn: "Backlog")
        openTask(named: "Folder-only UI")
        assertOrderedRoots([fixture.custom.path])
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Folder-only UI")
        element("back-to-board-button").click()
        moveTaskToDone("Folder-only UI")
        try assertTaskArchived("Folder-only UI")
        XCTAssertEqual(try taskRecord(named: "Folder-only UI")?["status"] as? String, "Done")
        XCTAssertEqual((try taskRecord(named: "Folder-only UI")?["repositoryWorktrees"] as? [[String: Any]])?.count, 0)
    }
}
