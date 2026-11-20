import AppKit
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import Network
import XCTest
import SQLite3
import Vision

final class PlayhouseUITests: XCTestCase {
    static var suiteAbortReason: String?
    /// A turn that ends unsettled with nothing running earns exactly one private recovery prompt.
    static let outcomeRecoveryPrompts = 1

    var app: XCUIApplication!
    var fixture: WorkspaceFixture!
    var runDirectory: URL!
    var dataDirectory: URL!
    var preferencesSuiteName: String!
    var codexFixtureHistoriesReset: Set<String> = []
    var appBundle: URL!
    var cliURL: URL!
    var serviceName: String!
    var codexFixtureExecutable: String?
    var claudeFixtureExecutable: String?
    var codexFixtureStateDirectory: URL?
    var launchDefaultParent: String?
    var launchWindowTitle: String?
    var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    override func setUpWithError() throws {
        if let reason = Self.suiteAbortReason {
            throw XCTSkip("Not run because an earlier case hit a global Playhouse startup/focus failure: \(reason)")
        }
        continueAfterFailure = false
        // Every CLI call, app and daemon a case starts copies this process's environment,
        // so task status sounds play at volume 0 instead of through the speakers.
        setenv("PLAYHOUSE_MUTE_SOUNDS", "1", 1)
        // Every case starts on a plain fixture so nothing can reach an installed Codex CLI;
        // cases that need a specific fixture replace it.
        codexFixtureExecutable = isLiveIntegration ? nil : WorkspaceFixture.root.appendingPathComponent("codex-fixture-ui").path
        claudeFixtureExecutable = nil
        codexFixtureStateDirectory = nil
        launchWindowTitle = nil
        fixture = try WorkspaceFixture.load()
        // The provider fixtures are shared by the whole run and keep their thread history
        // beside the executable, under thread and turn ids that repeat across cases; a Codex
        // turn's end replays the history items it never streamed, so an earlier case's
        // answers would land in this case's turn. Each case starts with none, as each
        // CLI case does with its own fixture copy.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: WorkspaceFixture.root.path)) ?? []
        where name.hasSuffix(".history") {
            try? FileManager.default.removeItem(at: WorkspaceFixture.root.appendingPathComponent(name))
        }
        runDirectory = URL(fileURLWithPath: "/tmp/playhouse-ui-test-data", isDirectory: true)
            .appendingPathComponent("PlayhouseUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        try WorkspaceFixture.ownerContents.write(
            to: runDirectory.appendingPathComponent(WorkspaceFixture.ownerMarker),
            atomically: true,
            encoding: .utf8
        )
        dataDirectory = runDirectory.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        appBundle = try Self.findAppBundle()
        // An absolute path keeps the isolated preferences file with this case's
        // data instead of ~/Library/Preferences.
        preferencesSuiteName = dataDirectory.appendingPathComponent("preferences").path
        clearSavedWindowFrames()
        cliURL = appBundle.appendingPathComponent("Contents/MacOS/playhouse-cli")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: cliURL.path), "The app-bundled CLI is missing.")
        // The bridge daemon and CLI ship flat in Contents/MacOS and resolve
        // their identity from the app's own Info.plist via `Bundle.main` (no
        // separate XPC bundle/Info.plist anymore).
        let serviceInfo = appBundle.appendingPathComponent("Contents/Info.plist")
        let plistData = try Data(contentsOf: serviceInfo)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        )
        serviceName = try XCTUnwrap(plist["CFBundleIdentifier"] as? String) + ".bridge"
        addUIInterruptionMonitor(withDescription: "Dismiss macOS crash reports") { alert in
            let ignore = alert.buttons["Ignore"]
            guard ignore.exists else { return false }
            ignore.click()
            return true
        }
        // macOS may ask whether a provider fixture's Python can find devices on local networks;
        // the prompt covers the board until answered.
        addUIInterruptionMonitor(withDescription: "Answer the macOS local network prompt") { alert in
            let allow = alert.buttons["Allow"]
            guard allow.exists, alert.staticTexts.matching(NSPredicate(format: "value CONTAINS[c] 'local network' OR label CONTAINS[c] 'local network'")).firstMatch.exists else { return false }
            allow.click()
            return true
        }
        dismissSystemPrivacyPrompts()
    }

    /// macOS shows privacy prompts (Local Network access, Automation) for processes in the
    /// test VM as UserNotificationCenter windows above the app, where they swallow the
    /// case's clicks and keyboard focus. Playhouse uses neither capability, so a prompt still
    /// open before the case launches it is allowed.
    func dismissSystemPrivacyPrompts() {
        let center = XCUIApplication(bundleIdentifier: "com.apple.UserNotificationCenter")
        guard center.state != .notRunning else { return }
        for _ in 0..<5 {
            let allow = center.buttons["Allow"].firstMatch
            guard allow.exists else { return }
            allow.click()
            _ = waitUntil({ !allow.exists }, timeout: 3)
        }
    }

    override func tearDownWithError() throws {
        // Read before cleanup, report after it: a failure here stops tearDown, which must
        // not leave the app running for the next case. Cleanup still keeps the data
        // directory of a case with violations, for triage.
        let providerViolations = runDirectory != nil && !isLiveIntegration ? providerFixtureViolations() : []
        try cleanUpAfterCase(failing: !providerViolations.isEmpty)
        for violation in providerViolations {
            XCTFail(violation)
        }
    }

    func cleanUpAfterCase(failing pendingFailure: Bool = false) throws {
        let failed = pendingFailure || (testRun?.failureCount ?? 0) > 0
        if failed {
            if let app {
                let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                screenshot.name = "failure-screenshot"
                screenshot.lifetime = .keepAlways
                add(screenshot)
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = "failure-accessibility-hierarchy"
                hierarchy.lifetime = .keepAlways
                add(hierarchy)
            }
        }
        guard runDirectory != nil else { return }
        if let app,
           !terminateAppAndWait(app) {
            XCTFail("Playhouse did not stop before UI test data cleanup; preserving the isolated data directory.")
            return
        }
        // Shared Codex servers and Claude runs outlive the app and its daemon on purpose.
        stopSurvivingAgents()
        clearSavedWindowFrames()
        if failed {
            // Keep the failed case's app data (Diagnostics.jsonl, transcripts,
            // store) for diagnosis; the runner prunes these on its next start.
            let note = XCTAttachment(string: runDirectory.path)
            note.name = "preserved-data-directory"
            note.lifetime = .keepAlways
            add(note)
            return
        }

        let markerURL = runDirectory.appendingPathComponent(WorkspaceFixture.ownerMarker)
        guard let marker = try? String(contentsOf: markerURL, encoding: .utf8),
              marker == WorkspaceFixture.ownerContents else {
            XCTFail("Refusing to remove UI test data without its ownership marker: \(runDirectory.path)")
            return
        }
        let testWorktrees = dataDirectory.appendingPathComponent("task-worktrees", isDirectory: true)
        if FileManager.default.fileExists(atPath: testWorktrees.path) {
            try FileManager.default.removeItem(at: testWorktrees)
            for repository in [fixture.primary, fixture.secondary, fixture.alternate, fixture.changes] {
                try? runGit(repository, "worktree", "prune")
            }
        }
        // The bridge daemon can still be finishing work in the case's worktrees; retry briefly.
        var attempt = 0
        while true {
            do {
                try FileManager.default.removeItem(at: runDirectory)
                break
            } catch {
                attempt += 1
                guard attempt < 10, FileManager.default.fileExists(atPath: runDirectory.path) else { throw error }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }

    // Scheduled tasks fire through ConversationManager.send, the path Send takes for both
    // providers, so the schedule behavior is provider-agnostic and Claude's fixture stands for both.

    // MARK: - Skills

    var skillsHome: URL { dataDirectory.appendingPathComponent("skills-home", isDirectory: true) }
    var skillsCodexHome: URL { dataDirectory.appendingPathComponent("codex-home", isDirectory: true) }

    // MARK: - Rules

    var rulesClaudeConfig: URL { skillsHome.appendingPathComponent(".claude", isDirectory: true) }
    var rulesManaged: URL { skillsHome.appendingPathComponent("managed/ClaudeCode", isDirectory: true) }

    // MARK: - MCP servers

    var mcpClaudeState: URL { skillsHome.appendingPathComponent(".claude.json") }
    var mcpCodexConfig: URL { skillsCodexHome.appendingPathComponent("config.toml") }
    var mcpManaged: URL { rulesManaged.appendingPathComponent("managed-mcp.json") }

    /// The real provider selected for opt-in live UI cases, or nil for the
    /// deterministic fixture suite. The runner writes it to the marker file.
    var liveProvider: String? {
        let environment = ProcessInfo.processInfo.environment
        if let marker = try? String(contentsOfFile: "/tmp/playhouse-live-ui-integration", encoding: .utf8) {
            let provider = marker.trimmingCharacters(in: .whitespacesAndNewlines)
            return provider.isEmpty ? "claude" : provider
        }
        if environment["PLAYHOUSE_RUN_LIVE_INTEGRATION"] == "1" { return environment["PLAYHOUSE_LIVE_PROVIDER"] ?? "claude" }
        if environment["PLAYHOUSE_RUN_CODEX_INTEGRATION"] == "1" { return "codex" }
        return nil
    }

    var isLiveIntegration: Bool { liveProvider != nil }

    /// Live Codex cases use the guest's signed-in Codex home.
    var isLiveCodexIntegration: Bool { liveProvider == "codex" }

    /// Each provider runs the case's fixture, or nothing: without a fixture the
    /// provider reads as not installed, so no default case reaches a real CLI
    /// that happens to be on the machine. Live cases keep the real CLIs.
    var providerExecutableEnvironment: [String: String] {
        var environment: [String: String] = [:]
        if let codexFixtureExecutable { environment["PLAYHOUSE_E2E_CODEX_EXECUTABLE"] = codexFixtureExecutable }
        else if !isLiveIntegration { environment["PLAYHOUSE_E2E_CODEX_EXECUTABLE"] = "none" }
        if let claudeFixtureExecutable { environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"] = claudeFixtureExecutable }
        else if !isLiveIntegration { environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"] = "none" }
        return environment
    }

    // Installed plugins and Add Plugin mode

    var pluginsFolder: URL { dataDirectory.appendingPathComponent("plugins", isDirectory: true) }

    /// The same context plugin the CLI case renders headlessly.
    static let pluginContextSource = """
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

    /// The same workspace probe plugin the CLI case renders headlessly (`PLUGIN_WORKSPACE_SOURCE`).
    static let pluginWorkspaceSource = """
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

    /// The same fetch plugin the CLI case renders headlessly (`PLUGIN_FETCH_SOURCE`).
    static let pluginFetchSource = """
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

    var isPlayhouseFrontmost: Bool {
        guard let expectedBundleID = Bundle(url: appBundle)?.bundleIdentifier else { return false }
        return app.state == .runningForeground &&
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == expectedBundleID
    }

    static var frontmostApplicationDescription: String {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return "none" }
        return "\(frontmost.localizedName ?? "unknown") (\(frontmost.bundleIdentifier ?? "unknown"))"
    }

    /// The board's PR-check cooldown for cases that wait it out (the app defaults to 20 s).
    /// The daemon reuses a shared probe's answer for a few seconds (3 s by default), which
    /// would answer a probe after this short cooldown without asking GitHub; keep that
    /// window shorter than the cooldown, as the app's 20 s cooldown keeps it.
    static let prCheckCooldown: TimeInterval = 3
    static var prCheckCooldownEnvironment: [String: String] {
        ["PLAYHOUSE_E2E_PR_CHECK_COOLDOWN_SECONDS": String(Int(prCheckCooldown)), "PLAYHOUSE_E2E_PR_STATUS_CACHE_SECONDS": "1"]
    }

    /// The file behind `preferencesSuiteName`; the runner reads it directly
    /// because its sandbox keeps it out of the app's preference domains.
    var isolatedPreferencesFile: URL {
        URL(fileURLWithPath: preferencesSuiteName + ".plist")
    }

    var openFolderPanel: XCUIElement {
        app.windows.matching(identifier: "open-panel").firstMatch
    }

    var settingsWindow: XCUIElement {
        app.windows.matching(NSPredicate(format: "title CONTAINS 'Settings'")).firstMatch
    }

    // MARK: - Agents that outlive the daemon

    static let restartMessage = "The agent stopped while Playhouse was restarting. Your conversation is saved; send a follow-up to continue."

    static let fixtureTaskPrompt = "Fixture task description."

    /// Element types whose accessibility value is a number, not text.
    static let numericValueElementTypes: [UInt] = ([
        .scrollBar, .valueIndicator, .slider, .progressIndicator, .activityIndicator, .levelIndicator,
        .ratingIndicator, .checkBox, .radioButton, .switch, .toggle, .stepper, .incrementArrow, .disclosureTriangle, .splitter,
    ] as [XCUIElement.ElementType]).map(\.rawValue)

}
