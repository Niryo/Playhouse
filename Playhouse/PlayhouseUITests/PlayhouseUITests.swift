import AppKit
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import Network
import XCTest
import SQLite3
import Vision

/// Parks the app's Git calls for one repository until released, through the `git`
/// wrapper scripts/test-ui.sh stages from scripts/fixtures/git-hold.sh (the case puts
/// `GitHoldBarrier.directory` first on the app's PATH). Unlike `GitConfigReadBarrier`
/// it doesn't depend on a blocked Git seeing FIFO end-of-file.

/// A pipe read while its process runs. A held turn streams every event to its CLI, and a nudge shown in
/// the conversation streams its own, so an unread pipe fills and blocks the CLI before it can exit.

/// The plugin fetch case's local HTTP server, inside the test process: the sandboxed
/// runner can't start `python3` in the VM, but it may listen on loopback. It answers
/// the routes of `scripts/fixtures/plugin-fetch-server.py` that the UI case reaches.

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

    /// Opens `title`'s conversation after its first turn, selects all of the reply's text and
    /// returns the task ID, the reply's text element and the side chat bubble that opened on it.

    /// Sends `message` from the open side chat bubble and returns the answer element at `index`.

    /// Sends a held fixture turn from the window, reopens the conversation so it
    /// no longer reads that turn's stream, and checks that the turn's progress
    /// still reaches it before the turn ends.

    /// Scrolls the transcript as far down as the wheel goes and checks that its bottom is real
    /// content. A newest turn that fits the viewport keeps its question pinned near the top, which
    /// fails if the room below the turn is too small; a taller one ends at its last row, which
    /// fails on blank overscroll below a turn whose question has scrolled away.

    /// Runs a tool-call turn and a later turn from the composer, then checks that the earlier
    /// turn shows each call inline, after the message written before it, with IN and OUT blocks.

    /// Expands the latest turn's Worked for summary when it is collapsed.

    /// Sends an ordinary turn from the composer, then checks that the earlier nudged
    /// turn's work stays visible, its call now renders inline, and the nudge Playhouse sent stays shown.

    // Scheduled tasks fire through ConversationManager.send, the path Send takes for both
    // providers, so the schedule behavior is provider-agnostic and Claude's fixture stands for both.

    /// Dismisses an open schedule hint with Escape (its Done button is disabled while the title is empty), then
    /// returns from the task conversation to the Scheduled Tasks page, which is hidden while a task is open.

    /// The fixture log's size as the app formats it; the log is built the same
    /// way as WASTE_LOG in scripts/fixtures/claude-code-fixture.py.

    /// Runs one Claude fixture turn whose session file logs every request (see
    /// write_waste_session in scripts/fixtures/claude-code-fixture.py), with the
    /// app reading the same Claude config directory the turn wrote to.

    /// `section` is the section's identifier suffix: wasters, tools, overhead or overview.

    /// Rows of the raw input list are drawn lazily; scrolls the list until one is on screen.

    /// The pid, parent pid and working directory a running CPU-attribution
    /// fixture child recorded for itself. The sandboxed UI runner can't list
    /// the daemon's descendants with `ps`, so the child reports them.

    // MARK: - Skills

    var skillsHome: URL { dataDirectory.appendingPathComponent("skills-home", isDirectory: true) }
    var skillsCodexHome: URL { dataDirectory.appendingPathComponent("codex-home", isDirectory: true) }

    /// A committed repository in this case's data directory, so a task worktree
    /// checks its skills out without touching the shared fixture.

    /// A task whose repositories already have their managed worktrees.

    /// The store folder Playhouse keeps a repository's private skills in.

    // MARK: - Rules

    var rulesClaudeConfig: URL { skillsHome.appendingPathComponent(".claude", isDirectory: true) }
    var rulesManaged: URL { skillsHome.appendingPathComponent("managed/ClaudeCode", isDirectory: true) }

    /// Every rule in the catalog by ID, across repositories, global and managed.

    /// Opens a rule's actions menu, waiting out a closing panel's animation and
    /// clicking again if the first click landed while it was still on screen.

    // MARK: - MCP servers

    var mcpClaudeState: URL { skillsHome.appendingPathComponent(".claude.json") }
    var mcpCodexConfig: URL { skillsCodexHome.appendingPathComponent("config.toml") }
    var mcpManaged: URL { rulesManaged.appendingPathComponent("managed-mcp.json") }

    /// Every server in the catalog by ID, across repositories, global and managed.

    /// Opens a server's actions menu, waiting out a closing panel's animation.

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

    /// Points a live case's task at the selected real provider.

    /// Commits, props and event values cross as JavaScript values, not JSON
    /// strings, but keep JSON.stringify's rules. Mirrors the CLI case's check.

    // Installed plugins and Add Plugin mode

    var pluginsFolder: URL { dataDirectory.appendingPathComponent("plugins", isDirectory: true) }

    /// Writes a plugin folder the way an authoring agent does: plugin.json and index.js.

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

    /// Starts the fetch fixture server for this case and returns its base URL and a closed port's.

    /// A Plugin Catalog sidebar row, scrolled into view: the sidebar lists more
    /// atoms and examples than fit, and a row scrolled away has no frame to click.
    /// The sidebar is the scroll view holding the atom rows.

    /// A rendered Text atom's string: SwiftUI exposes it as the value or, for some elements, the label.

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

    /// PATH that resolves `git` to the staged hold wrapper first; see `GitHoldBarrier`.

    /// Clicks a text field once it has settled, confirms it took keyboard focus
    /// (retrying the click once), then types. A click that lands while the
    /// form is still scrolling into place can leave the field unfocused, and
    /// typeText then fails with "Neither element nor any descendant has
    /// keyboard focus".

    /// Selects a question option once the form has settled. The question form
    /// arrives with a transcript reload that scrolls it; a click issued the
    /// moment the title exists can land before the option is in place, leaving
    /// nothing selected and a Submit click that does nothing.

    /// The same, for an option named by its accessibility identifier, where
    /// several questions in one form offer the same label.

    /// Scrolls the conversation until `target` lies inside its visible area. The transcript
    /// follows its newest content, so a layout change below a question form (a queued
    /// follow-up bar, a live activity row) can push the form's first options above the
    /// viewport, where a click lands on the header instead. True once it is fully visible.

    /// Waits until `target`'s frame has stopped changing for 0.4 s. A click sent the instant a
    /// control appears can land where the control was a frame earlier.

    /// Opens a slide-up panel (skills, rules, MCP) with one click on `control`
    /// and waits for it to finish sliding in, so the next click lands on a
    /// control that has stopped moving. One click must be enough, including
    /// right after another panel closed: a closed panel's overlay must not catch
    /// clicks, even while its scrim is still fading out.

    /// The composer saves the task (which shows its chips) before it writes the remembered
    /// repositories, so a chip appearing does not mean the setting is saved yet. Waits for the
    /// saved value instead of reading it once.

    /// The file behind `preferencesSuiteName`; the runner reads it directly
    /// because its sandbox keeps it out of the app's preference domains.
    var isolatedPreferencesFile: URL {
        URL(fileURLWithPath: preferencesSuiteName + ".plist")
    }

    /// The stored draft state of a task, for failure messages.

    /// Leaves the open task for the board. Right after a turn ends the back
    /// button can be re-rendered and swallow a click, so wait for it to be
    /// hittable and confirm the board actually appeared.

    /// The history, pending question and unsent draft land after the task view
    /// appears; reading or scrolling the transcript before then sees an empty task.

    /// Scrolls the board's columns sideways until `target` lies fully inside the
    /// visible board. With the persistent sidebar, a narrow screen (the UI VM's is
    /// 1024 points) clips the Review column's trailing edge, where a card's PR
    /// controls sit: they stay in the hierarchy but take no hover or click.

    /// Opens a board card through its title. The card's center can sit on one
    /// of its own controls (the token counter button opens Token stats), so a
    /// plain card.click() may open that control instead of the task.

    /// Starts a full-screen capture that fires while a following blocking gesture is still
    /// in progress, so a mid-drag state can be attached once the gesture returns.

    /// The Done drawer shows only a thin sliver beside the columns while nothing is dragged,
    /// just left of the board's vertical scroller, which keeps the window edge.

    /// Installs the Claude Code protocol fixture for this case and returns the
    /// environment a CLI-driven turn needs. Must run before `launchApp` so the
    /// app's own turns use it too.

    /// The usage dot is one flat hue, so the dominant channel says where on the
    /// green-to-red heatmap it currently sits. `leftEdgeFraction` restricts the
    /// sample to a left-hand slice of `element`'s screenshot — used to read the
    /// CPU bar's color off the stable task card instead of the thin animated
    /// bar sub-view itself, whose identity can transiently drop out of the
    /// accessibility tree between an existence check and a screenshot fetch.

    /// The activity section renders open while a turn runs and collapses once it
    /// settles, so a test that needs the details open must expand only when the
    /// disclosure is actually collapsed; clicking blindly can close it instead.
    /// Reports whether the section ended up open, so a caller can assert that its
    /// own check really inspected an open section. The chevron is the anchor, not
    /// the details container: when every activity in flight renders outside the
    /// section, an open section has no children and does not resolve.

    /// An agent row's metadata line, read from the row's button beside its icon.

    /// Playhouse's own prompts render as muted automatic messages: the history entry that holds `text`
    /// is shown under the `playhouse-message-` identifier with its label, never as the user's bubble.

    /// The transcript's last row: the newest message, which can be the reply to a status nudge
    /// sent after the turn the test is watching.

    /// The transcript element a history message renders as.

    /// History without the status nudges Playhouse sent and the agent's replies to them.

    /// Whether a transcript message shows this text, as a message group's label
    /// or as a text view's value.

    /// Refreshes a standalone chat through its visible navigation controls. The board's
    /// Chat button moves off-screen while the 460-point sidebar and 980-point board coexist.

    /// Waits for transcript text, scrolling down on each miss: the lazy transcript
    /// only exposes rows near the viewport.

    /// Runs `body` against the app's SQLite conversation store, which the app
    /// and its bridge daemon share in WAL mode.

    /// Rows of a query against the conversation store, as text columns.

    /// The task's stored conversation state, or nil before anything is recorded.

    /// Scrolls `scrollView` until `element` sits fully inside it, or, for an element taller than
    /// the scroll view, until its top edge is at the scroll view's top. Custom accessibility
    /// elements, such as one paragraph of a reply's shared text, are not scrolled into view by a
    /// click.

    /// Opening a conversation renders only its newest turn, and older batches load as the
    /// reader scrolls up. Scrolls up as a reader would until every message is rendered, so
    /// an earlier turn can be asserted. The scroll view reports "Showing latest N of M".

    /// Settled turns render lazily, so a row of an earlier turn exists only while it is near the
    /// viewport. Scrolls the transcript up, then back down, as a reader looking for it would,
    /// until `target` exists, then brings it into the viewport. A row found well outside the
    /// viewport may be one that renders only until it is measured and then becomes a box, so
    /// callers that go on to read it need it in view, where it stays rendered.

    /// Scrolls until `target`'s top lies inside the conversation's viewport, then waits for the
    /// transcript to settle the rows around it.

    /// Settled turns render lazily, so a check over the whole revealed transcript has to look at
    /// it a viewport at a time. Scrolls the conversation to its top, then down to its bottom in
    /// steps shorter than the viewport, checking `found` at every step, and reports whether it
    /// held at any step and whether the scan covered the whole transcript. The scroller's value
    /// reports the position, 0 at the top and 1 at the bottom.

    /// Whether `found` holds anywhere in the transcript, scanning it a viewport at a time.

    /// Asserts that `found` holds nowhere in the transcript. The scan must have covered it
    /// from its top to its bottom, so a scan cut short cannot pass as an absence.

    /// A user message in the transcript, which is exposed as a labeled group.

    /// The effort a model-effort slider reports. Its accessibility value is the
    /// step index; efforts are offered in the same order for every model.

    var openFolderPanel: XCUIElement {
        app.windows.matching(identifier: "open-panel").firstMatch
    }

    var settingsWindow: XCUIElement {
        app.windows.matching(NSPredicate(format: "title CONTAINS 'Settings'")).firstMatch
    }

    // MARK: - Agents that outlive the daemon

    /// The shared Codex servers and Claude runs this case's data folder recorded, with their
    /// manifests' paths.

    /// The process a manifest recorded, while it still runs as that process (same start time).

    /// A private bridge service, so a case can kill its daemon without touching the UI runner's.

    /// Opens the chat sidebar on a private service whose chat turns run in the restart fixture.

    /// Sends a chat message from the sidebar composer and waits for the restart fixture to hold its turn.

    /// Has the restart fixture's held chat turn run its real close-turn (a new titled page when
    /// `newTitle` is set) and waits for it; the turn itself keeps running.

    /// One ordinary chat turn that runs close-turn (opening a new page titled `newTitle` when
    /// set) and is filed by the daemon that sent it. Returns the text the provider received.

    /// Puts a filed chat page back in the state an earlier build left after losing its turn:
    /// no message on the page and no close-turn record naming it.

    /// Command-Return steers the running turn with the composer's text.

    static let restartMessage = "The agent stopped while Playhouse was restarting. Your conversation is saved; send a follow-up to continue."

    /// The daemon's process ID, or nil while nothing answers on that service.
    /// Unlike `runCLI`, a failed connection isn't a test failure here.
    /// Every daemon process that wrote to this service's socket log (each logs on start).

    /// How many turns a provider fixture has received whose prompt contains `text`, not
    /// counting page classifier calls. The Claude fixture records `userText`, Codex `userMessage`.

    /// No provider turn is running. The send button can't tell: it is disabled whenever the
    /// composer is empty.

    /// The suite must never reach an installed Codex, Claude or GitHub CLI: every provider or
    /// `gh` process a case starts, from the app or from the daemon on its behalf, is one of its
    /// own fixtures. A task left in PR mode reaches `gh` on its way to Review.

    /// Recreates a standalone chat stored as a hidden board task and returns its ID.

    /// An open pill's option once its slide-in has finished, so a click lands on it.

    /// Opens a task card's PR mode pill, chooses `mode`, and waits for it to fold back onto it.

    static let fixtureTaskPrompt = "Fixture task description."

    /// The final response plus every streamed event line printed before it.

    /// The chat sidebar's separators for pages titled `title`, top to bottom.

    /// Whether the chat sidebar shows a message containing `text` below the separator of the
    /// newest page titled `title`, so an identical message of an earlier page can't stand in for it.

    /// Opens the side chat bubble for the current selection and returns it. A selection shows only
    /// the Side chat hint, above the selected text; the bubble opens once the hint is clicked, and
    /// the hint goes away. With `selection`, the hint must sit above that text and the bubble must
    /// be attached to it: overlapping it horizontally and just above or below it. The bubble is
    /// never smaller than its compact size nor bigger than its grown one.

    /// Whether a screenshot of `element` has a pixel within a small tolerance of an sRGB color.
    /// The expected color is converted into the screenshot's own color space (the Tart VM's
    /// display profile) and compared with raw pixels; converting each pixel to sRGB instead
    /// shifts it by more than the tolerance.

    /// The digits the shell printed between `marker` and a `;` in a terminal's text, latest first.
    /// Row breaks are ignored, since the shell's line editor can leave output on a row that
    /// continues the wrapped command. The echoed command holds `%s` there, never digits, and
    /// the `;` keeps a following prompt from running into the number.

    /// The diff header's report of which Monaco load rendered the open diff, and of which
    /// file it rendered, once the editor has finished presenting it.

    /// The diff text Monaco has actually rendered, which lands after the editor applies it.

    /// Hovers the control until its native tooltip becomes visible outside it. Retries with
    /// several XCUI hover moves inside it, because AppKit starts the tooltip delay from a move
    /// inside the control.

    /// The tooltip counts as shown only when its own text is on screen: as a help tag in the
    /// accessibility tree, or read off the screen. The control shows only "PR", so the help text
    /// cannot come from anywhere but the tooltip; a changed-pixels check would pass on any update.

    /// Hovers the control with the same real mouse movement as `assertNativeHelpText` and asserts
    /// that no tooltip containing `text` ever appears.

    /// Counts pixels matching `matches`, sampling every `step` pixels; 0 when the image cannot be read.

    /// The horizontal span, in points, of the pixels that differ from the image's corner (its background).

    /// Sampled pixels whose summed RGB change exceeds `threshold`; nil when either image is unreadable or the sizes differ.

    /// Checks the user bubble by comparing its colors with each other rather than with exact
    /// values, because an element screenshot's color conversion shifts absolute gray levels.
    /// The fill is the dominant neutral gray and is lighter than the transcript background (read
    /// from the bottom-left timestamp row). The text is much lighter, the left and right edges
    /// carry a lighter stroke, and no blue accent remains.

    /// Clicks a few points into the first characters of highlighted text, selecting nothing; the
    /// bubble reopens once the double-click interval passes, so callers wait for it. The text is
    /// scrolled into view first: after a send the transcript follows the newest turn, and a click
    /// on text above the viewport would land on whatever covers that point.

    /// Element types whose accessibility value is a number, not text.
    static let numericValueElementTypes: [UInt] = ([
        .scrollBar, .valueIndicator, .slider, .progressIndicator, .activityIndicator, .levelIndicator,
        .ratingIndicator, .checkBox, .radioButton, .switch, .toggle, .stepper, .incrementArrow, .disclosureTriangle, .splitter,
    ] as [XCUIElement.ElementType]).map(\.rawValue)

    /// Matches an element whose label, text value, or (optionally) title contains `text`.
    /// `value CONTAINS` raises inside the app on a numeric value, such as the board's
    /// horizontal scroll bar, and that aborts the whole query until it times out, so a
    /// value is compared only on element types whose value is text.

    /// Empty for an element that does not exist (yet), so it can be polled:
    /// reading `label` of a missing element fails the test on the spot.

    /// How purple a board column's own surface reads: the mean of blue and red
    /// over green, sampled along a strip just inside its top edge, above its
    /// header and inside its padding, so only the column's fill shows there. The
    /// strip must lie within `container` (the scroll area showing the column), so
    /// a clipped column never samples whatever is drawn beyond it.

    /// A scroll view's vertical scroller. Its frame is reported whether or not it is drawn.

    /// Luminance samples across `region` (screen points) of a screen capture, in reading order, so
    /// two captures of the same unscrolled region compare pixel for pixel.

    /// The largest per-pixel luminance change between two samplings of the same region.

    /// Asserts that `scrollView`'s scroller stays hidden while the pointer is over `elsewhere`,
    /// shows at a subdued opacity for as long as the pointer rests over `scrollView`, and hides
    /// again once the pointer returns to `elsewhere`. Each sampling waits out AppKit's own fade
    /// after a scroll, so a scroller that only flashed reads as hidden. Returns the change that
    /// revealing the scroller made, which sizes a subdued scroller for later comparisons.

    /// Attaches the app as it looks now. On macOS a capture is always the whole screen, where the
    /// app's window is a small part of a large desktop; unless `fullScreen` asks for the desktop,
    /// the image is cut down to the app's windows and popovers at the screen's own pixel density,
    /// so text in a showcase screenshot stays readable.

    /// Attaches `element` alone, at native pixel density, for UI that is small within its window.

    /// `screenshot` cropped to the union of the app's windows and popovers (such as the side chat
    /// bubble, which can reach past its window), with a small margin, or nil when it can't tell.

}
