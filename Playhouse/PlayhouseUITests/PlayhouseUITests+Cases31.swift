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
    // case-contract: test_plugin_done_archive_renders_from_atoms_like_native | The Plugin Catalog's Done Archive page shows the board's Done archive composed in JavaScript from atoms above the native SwiftUI archive the board presents, built from the same atoms and sample model, each opened by the board header's archive button (the bordered Button atom with the archivebox icon, labelled Done tasks) into a 340-point SidePanel over the trailing edge of a 560 by 460 point stand-in for the board, open at first. Both show the Done tasks title and its close button, the search field with its Search tasks and conversations placeholder, and a list of five rows, each a button opening its task with the done checkmark, its title and its date, beside its pull request actions: a #227 link, a PR button beside a #228 link, a PRs button, a disabled busy PR button showing a spinner, and nothing for a task without repositories, each at the same size in both and with the board archive's identifiers (done-archive-task, done-archive-create-pr, done-archive-pr-link, done-archive-search, and done-archive-list valued 5 tasks loaded). The JavaScript tree uses only atoms (SidePanel, Stack, Text, Icon, Button, Link, Spinner, Spacer, Divider, TextField, Scroll), its search a plain TextField on a rounded Stack. The list's end is in view, so its onEndReached runs on both sides (End reached). Typing in the JavaScript search runs onChange (Last: search followed by the text), narrows the rows to the matching title and shows the clear button, which clears the search and brings every row back; a search that matches nothing shows No matching tasks instead of the list. A PR button runs its handler with its task (Last: create pr followed by the title), a row runs open (Last: open followed by the title) and slides the panel away, the archive button opens it again (Last: toggle open), and the close button closes it (Last: close), while the native archive keeps its own state. The list raises no onPress, so pressing it is refused as invalid_argument.
    func test_plugin_done_archive_renders_from_atoms_like_native() throws {
        launchApp(defaultParent: fixture.parent.path)
        clickPluginsMenuItem("Plugin Catalog")
        let example = catalogSidebarRow("plugin-catalog-done-archive")
        XCTAssertTrue(example.waitToExist(timeout: 15), "Plugins ▸ Plugin Catalog lists the Done Archive example.")
        example.click()
        let jsSide = element("plugin-catalog-js-done-archive")
        let nativeSide = element("plugin-catalog-native-done-archive")
        XCTAssertTrue(jsSide.waitToExist(timeout: 10), "The page shows the JavaScript archive.")
        XCTAssertTrue(nativeSide.waitToExist(timeout: 10), "The page shows the native archive.")
        XCTAssertFalse(element("plugin-error").exists, "The JavaScript archive renders without errors.")

        // The board window behind the catalog has the same identifiers, so every
        // lookup is scoped to its catalog column.
        func js(_ identifier: String) -> XCUIElement {
            jsSide.descendants(matching: .any).matching(identifier: identifier).firstMatch
        }
        func native(_ identifier: String) -> XCUIElement {
            nativeSide.descendants(matching: .any).matching(identifier: identifier).firstMatch
        }
        // The side panel's controls are reachable: each must be hittable before it is clicked.
        func press(_ control: XCUIElement) {
            XCTAssertTrue(control.waitToExist(timeout: 5), "\(control) exists.")
            XCTAssertTrue(waitUntil({ control.isHittable }, timeout: 5), "\(control) is hittable, so assistive clients reach it.")
            control.click()
        }
        func assertSameSize(_ identifier: String) {
            let jsElement = js(identifier), nativeElement = native("native-\(identifier)")
            XCTAssertTrue(jsElement.waitToExist(timeout: 10), "The JavaScript archive has \(identifier).")
            XCTAssertTrue(nativeElement.waitToExist(timeout: 10), "The native archive has \(identifier).")
            XCTAssertEqual(jsElement.frame.width, nativeElement.frame.width, accuracy: 1, "\(identifier) has the same width in both.")
            XCTAssertEqual(jsElement.frame.height, nativeElement.frame.height, accuracy: 1, "\(identifier) has the same height in both.")
        }
        let ids = (1...5).map { "4F3A2C10-0000-4000-8000-00000000000\($0)" }
        let titles = ["Fix Skills page tab row layout", "Purple tint for the Waiting Response column", "Update the clean-mac AMI and monitoring",
                      "Investigate and fix a task error", "Plan the next release notes"]
        for side in [jsSide, nativeSide] {
            let prefix = side == jsSide ? "" : "native-"
            let panel = side.descendants(matching: .any).matching(identifier: "\(prefix)done-archive-panel").firstMatch
            let board = side.descendants(matching: .any).matching(identifier: "\(prefix)done-archive-board").firstMatch
            XCTAssertTrue(panel.waitToExist(timeout: 10), "The archive starts open in its side panel.")
            XCTAssertEqual(board.frame.width, 560, accuracy: 1)
            XCTAssertEqual(board.frame.height, 460, accuracy: 1)
            XCTAssertTrue(waitUntil({ abs(panel.frame.maxX - board.frame.maxX) < 1 }, timeout: 5), "The panel rests along the board's trailing edge.")
            XCTAssertEqual(panel.frame.width, 340, accuracy: 1, "The archive's side panel is 340 points wide.")
            XCTAssertEqual(panel.frame.height, board.frame.height, accuracy: 1, "The side panel is as tall as the board.")
            let button = side.descendants(matching: .any).matching(identifier: "\(prefix)done-archive-button").firstMatch
            XCTAssertEqual(button.label, "Done tasks", "The archive button is labelled Done tasks.")
        }
        for identifier in ["done-archive-button", "done-archive-panel", "done-archive-title", "close-done-archive-button", "done-archive-search", "done-archive-list",
                           "done-archive-pr-link-\(ids[0])-227", "done-archive-create-pr-\(ids[1])", "done-archive-pr-link-\(ids[1])-228",
                           "done-archive-create-pr-\(ids[2])", "done-archive-create-pr-\(ids[3])"] + ids.map({ "done-archive-task-\($0)" }) {
            assertSameSize(identifier)
        }
        XCTAssertEqual(pluginText(js("done-archive-title")), "Done tasks")
        XCTAssertEqual(js("done-archive-search").placeholderValue, "Search tasks and conversations")
        XCTAssertEqual(js("done-archive-list").value as? String, "5 tasks loaded")
        XCTAssertEqual(native("native-done-archive-list").value as? String, "5 tasks loaded")
        // A row's button may expose its texts as children or join them into its own label.
        func shows(_ row: XCUIElement, _ text: String) -> Bool {
            row.staticTexts[text].exists || accessibleLabelOrValue(of: row).contains(text)
        }
        for (id, title) in zip(ids, titles) {
            XCTAssertTrue(shows(js("done-archive-task-\(id)"), title), "The JavaScript row shows \(title).")
            XCTAssertTrue(shows(native("native-done-archive-task-\(id)"), title), "The native row shows \(title).")
        }
        XCTAssertTrue(shows(js("done-archive-task-\(ids[0])"), "10 November 2026"), "A row shows its task's date.")
        XCTAssertTrue(shows(native("native-done-archive-task-\(ids[0])"), "10 November 2026"))
        XCTAssertFalse(js("done-archive-create-pr-\(ids[3])").isEnabled, "The busy PR button is disabled.")
        XCTAssertFalse(native("native-done-archive-create-pr-\(ids[3])").isEnabled)
        XCTAssertFalse(js("done-archive-create-pr-\(ids[4])").exists, "A task without repositories has no pull request actions.")
        XCTAssertFalse(js("clear-archive-search-button").exists, "An empty search has no clear button.")
        XCTAssertTrue(waitUntil({ self.pluginText(js("js-end-reached")) == "End reached" }, timeout: 5), "The JavaScript list's end is in view, so onEndReached ran.")
        XCTAssertTrue(waitUntil({ self.pluginText(native("native-end-reached")) == "End reached" }, timeout: 5), "The native list's end is in view too.")
        attachScreenshot(named: "Done archive: JavaScript above native")

        // Searching narrows the rows; clearing brings them back.
        let search = js("done-archive-search")
        press(search)
        search.typeText("release")
        XCTAssertTrue(waitUntil({ self.pluginText(js("js-last-action")) == "Last: search release" }, timeout: 5), "Typing runs onChange.")
        XCTAssertTrue(waitUntil({ !js("done-archive-task-\(ids[0])").exists && js("done-archive-task-\(ids[4])").exists }, timeout: 5), "The search narrows the rows.")
        XCTAssertTrue(native("native-done-archive-task-\(ids[0])").exists, "The native archive keeps its own search.")
        XCTAssertTrue(js("clear-archive-search-button").exists, "A search shows the clear button.")
        attachScreenshot(named: "Done archive: search narrows the JavaScript rows")
        press(js("clear-archive-search-button"))
        XCTAssertTrue(waitUntil({ js("done-archive-task-\(ids[0])").exists && (js("done-archive-search").value as? String ?? "").isEmpty }, timeout: 5), "Clear brings every row back.")
        press(search)
        search.typeText("nothing-matches")
        XCTAssertTrue(js("done-archive-empty-state").waitToExist(timeout: 5), "A search with no matches shows the empty state.")
        XCTAssertEqual(pluginText(js("done-archive-empty-state")), "No matching tasks")
        XCTAssertFalse(js("done-archive-list").exists, "No list while nothing matches.")
        attachScreenshot(named: "Done archive: no matching tasks")
        press(js("clear-archive-search-button"))
        XCTAssertTrue(js("done-archive-list").waitToExist(timeout: 5))

        // Each control runs its own side's handler.
        press(js("done-archive-create-pr-\(ids[1])"))
        XCTAssertTrue(waitUntil({ self.pluginText(js("js-last-action")) == "Last: create pr \(titles[1])" }, timeout: 5), "A PR button runs its handler with its task.")
        press(js("done-archive-task-\(ids[0])"))
        XCTAssertTrue(waitUntil({ self.pluginText(js("js-last-action")) == "Last: open \(titles[0])" }, timeout: 5), "A row runs open with its task.")
        XCTAssertTrue(waitUntil({ !js("done-archive-panel").exists }, timeout: 5), "Opening a task slides the panel away.")
        XCTAssertTrue(native("native-done-archive-panel").exists, "The native archive stays open.")
        attachScreenshot(named: "Done archive: JavaScript panel closed after opening a task")
        js("done-archive-button").click()
        XCTAssertTrue(js("done-archive-panel").waitToExist(timeout: 5), "The archive button opens it again.")
        XCTAssertEqual(pluginText(js("js-last-action")), "Last: toggle open")
        press(js("close-done-archive-button"))
        XCTAssertTrue(waitUntil({ !js("done-archive-panel").exists && self.pluginText(js("js-last-action")) == "Last: close" }, timeout: 5), "The close button closes it.")
        XCTAssertEqual(pluginText(native("native-last-action")), "Last: none", "The native archive keeps its own state.")
    }
    // case-contract: test_plugin_token_stats_renders_from_atoms_like_native | The Plugin Catalog's Token Stats page shows the Token Stats modal composed in JavaScript from atoms above the native SwiftUI modal the board presents, built from the same atoms and sample data, each opened by the task item's token counter (the same overhanging Button atom, labelled with its description and hinted Open Token Stats). Both show the title and the task's title, the View raw input… button, a section bar of Overview, Wasters, Tools & MCP and Overhead with Overview selected, the call headlines (Final transcript size, Total sent (incl. subagents), Excluding cache reads (incl. subagents)), the main-agent and subagent split, the call and output lines, the total, the four buckets, the per-tool rollup and the per-turn rows, each at the same size in both, and the JavaScript tree uses only atoms (Panel, Stack, Text, Label, Button, Spacer, ChoiceBar, Divider, Scroll, Meter) with the board modal's identifiers. Choosing Wasters in the JavaScript section bar runs onChange with its value (Last: section wasters) and shows the largest items, each with a 72-point share bar, its kind, the removed-by-compaction flag, its request count and a small Show button, then the repeated result and the cache miss, while the native modal stays on Overview until its own bar moves it, after which both show the same rows at the same size. Show runs its JavaScript handler with the item's raw input target (Last: raw input claude #14) and View raw input… with the final transcript (Last: raw input final transcript), without re-rendering any row. Tools & MCP lists each tool's bar, calls and total and the MCP server, and Overhead lists what every request carries and each agent. The overview scrolls within at most 320 points and each map section within a fixed 420. Done closes the JavaScript modal (Last: done) and leaves the native one open, and the counter opens it again (Last: open). The section bar raises no onPress, so pressing it is refused as invalid_argument.
    func test_plugin_token_stats_renders_from_atoms_like_native() throws {
        launchApp(defaultParent: fixture.parent.path)
        clickPluginsMenuItem("Plugin Catalog")
        let example = catalogSidebarRow("plugin-catalog-token-stats")
        XCTAssertTrue(example.waitToExist(timeout: 15), "Plugins ▸ Plugin Catalog lists the Token Stats example.")
        example.click()
        let jsSide = element("plugin-catalog-js-token-stats")
        let nativeSide = element("plugin-catalog-native-token-stats")
        XCTAssertTrue(jsSide.waitToExist(timeout: 10), "The page shows the JavaScript Token Stats modal.")
        XCTAssertTrue(nativeSide.waitToExist(timeout: 10), "The page shows the native Token Stats modal.")
        XCTAssertFalse(element("plugin-error").exists, "The JavaScript modal renders without errors.")

        func js(_ identifier: String) -> XCUIElement {
            jsSide.descendants(matching: .any).matching(identifier: identifier).firstMatch
        }
        func native(_ identifier: String) -> XCUIElement {
            nativeSide.descendants(matching: .any).matching(identifier: identifier).firstMatch
        }
        func pair(_ suffix: String) -> (js: XCUIElement, native: XCUIElement) {
            (js("token-stats\(suffix)"), native("native-token-stats\(suffix)"))
        }
        func assertSameSize(_ js: XCUIElement, _ native: XCUIElement, _ name: String) {
            XCTAssertTrue(js.waitToExist(timeout: 10), "The JavaScript modal has \(name).")
            XCTAssertTrue(native.waitToExist(timeout: 10), "The native modal has \(name).")
            XCTAssertEqual(js.frame.width, native.frame.width, accuracy: 1, "\(name) has the same width in both.")
            XCTAssertEqual(js.frame.height, native.frame.height, accuracy: 1, "\(name) has the same height in both.")
        }
        func assertSameSize(_ suffix: String) {
            let (js, native) = pair(suffix)
            assertSameSize(js, native, "token-stats\(suffix)")
        }
        // The modals are 720 points wide, so the native one sits below the
        // JavaScript one and the catalog page scrolls to reach either.
        let page = app.scrollViews.containing(.any, identifier: "plugin-catalog-js-token-stats").firstMatch
        @discardableResult func reveal(_ element: XCUIElement) -> XCUIElement {
            XCTAssertTrue(element.waitToExist(timeout: 10), "\(element) should exist before scrolling to it.")
            for _ in 0..<15 where !element.isHittable {
                page.scroll(byDeltaX: 0, deltaY: element.frame.midY > page.frame.midY ? -250 : 250)
            }
            XCTAssertTrue(element.isHittable, "\(element) should be on screen after scrolling the catalog page.")
            return element
        }
        let commit = jsSide.descendants(matching: .any).matching(identifier: "plugin-last-commit").firstMatch
        let lastAction = js("js-last-action")

        // The task item's token counter opens the modal: the same Button atom as on the card.
        let jsCounter = js("token-stats-counter"), nativeCounter = native("native-token-stats-counter")
        assertSameSize(jsCounter, nativeCounter, "the token counter")
        XCTAssertEqual(jsCounter.label, "3.7K tokens sent · 8 calls · 650 final transcript", "The counter is labelled with its description.")
        XCTAssertEqual(jsCounter.label, nativeCounter.label)
        XCTAssertGreaterThanOrEqual(jsCounter.frame.height, 20, "The counter's hit area is taller than its small text.")
        assertHoverEmphasis(for: jsCounter)

        // The catalog frames each modal in a Panel; SwiftUI merges the modal's
        // root container into it, so the frame carries the modal's size.
        for suffix in ["-modal", "-title", "-task-title", "-raw-input-button", "-sections", "-section-overview", "-section-wasters", "-section-tools",
                       "-section-overhead", "-final-transcript", "-total-sent", "-excluding-cache", "-excluding-cache-split", "-total-calls",
                       "-output", "-total", "-overview", "-tool-Bash", "-tool-Read", "-turn-turn-1", "-turn-turn-2"] {
            assertSameSize(suffix)
        }
        assertSameSize(js("close-token-stats-button"), native("close-native-token-stats-button"), "Done")
        for (suffix, text) in [("-title", "Token stats"), ("-task-title", "Refactor the login flow"), ("-final-transcript", "650"), ("-total-sent", "3,680"),
                               ("-excluding-cache", "1,710"), ("-excluding-cache-split", "Excluding cache reads: 720 main agent · 990 subagents"),
                               ("-total-calls", "8 model calls · 4 main, 4 across 2 subagents"), ("-output", "Output 170"), ("-total", "3,200")] {
            XCTAssertEqual(pluginText(pair(suffix).js), text, "token-stats\(suffix) reads \(text).")
            XCTAssertEqual(pluginText(pair(suffix).native), text, "native-token-stats\(suffix) reads \(text).")
        }
        XCTAssertTrue(pair("-section-overview").js.isSelected, "Token Stats opens on its Overview section.")
        XCTAssertFalse(pair("-section-wasters").js.isSelected)
        XCTAssertTrue(pair("-raw-input-button").js.isEnabled, "The sample has a token map, so its raw input opens.")
        XCTAssertLessThanOrEqual(pair("-modal").js.frame.maxY, pair("-modal").native.frame.minY, "The JavaScript modal sits above the native one.")
        XCTAssertEqual(pair("-modal").js.frame.width, 720, accuracy: 1, "The modal is 720 points wide, as on the board.")
        for side in [pair("-overview").js, pair("-overview").native] {
            XCTAssertGreaterThan(side.frame.height, 80, "The overview's rollups show in its scroll view.")
            XCTAssertLessThanOrEqual(side.frame.height, 321, "The overview scrolls within at most 320 points.")
        }
        attachScreenshot(named: "Token Stats: JavaScript above native, both on Overview")

        // Each side keeps its own section; the ChoiceBar is controlled.
        reveal(pair("-section-wasters").js).click()
        XCTAssertTrue(js("token-stats-waster-0").waitToExist(timeout: 5), "Choosing Wasters shows the largest items.")
        XCTAssertFalse(pair("-total").js.exists, "Wasters replaces the overview.")
        XCTAssertTrue(waitUntil({ self.pluginText(lastAction) == "Last: section wasters" }, timeout: 5), "The section bar ran onChange with its value.")
        XCTAssertTrue(waitUntil({ pair("-section-wasters").js.isSelected && !pair("-section-overview").js.isSelected }, timeout: 5))
        XCTAssertTrue(pair("-total").native.exists, "The native modal stays on Overview.")
        XCTAssertTrue(pair("-section-overview").native.isSelected)
        XCTAssertEqual(pluginText(js("token-stats-waster-0-label")), "fixturelogs/query_logs")
        XCTAssertEqual(pluginText(js("token-stats-waster-0-removed")), "removed by compaction")
        XCTAssertEqual(pluginText(js("token-stats-waster-0-requests")), "×63")
        XCTAssertEqual(pluginText(js("token-stats-waster-0-tokens")), "18,000")
        XCTAssertFalse(js("token-stats-waster-1-removed").exists, "An item still in the final transcript isn't flagged.")
        XCTAssertEqual(pluginText(js("token-stats-duplicate-0-copies")), "2 copies of 2,400")
        XCTAssertEqual(pluginText(js("token-stats-cache-miss-0-request")), "Request 34")
        attachScreenshot(named: "Token Stats: JavaScript on Wasters, native still on Overview")
        reveal(pair("-section-wasters").native).click()
        XCTAssertTrue(native("native-token-stats-waster-0").waitToExist(timeout: 5), "The native section bar moves its own modal.")
        for side in [pair("-map").js, pair("-map").native] {
            XCTAssertEqual(side.frame.height, 420, accuracy: 1, "Each map section scrolls within a fixed 420 points.")
        }
        for suffix in ["-map", "-waster-0", "-waster-1", "-waster-2", "-waster-0-label", "-waster-0-removed", "-waster-0-requests", "-waster-0-tokens",
                       "-waster-0-show", "-duplicate-0", "-cache-miss-0"] {
            assertSameSize(suffix)
        }
        attachScreenshot(named: "Token Stats: both on Wasters")

        // Show and View raw input… run their JavaScript handlers with their targets.
        reveal(js("token-stats-waster-0-show")).click()
        XCTAssertTrue(waitUntil({ self.pluginText(lastAction) == "Last: raw input claude #14" }, timeout: 5), "Show passes the item's raw input target.")
        XCTAssertTrue(waitUntil({ self.pluginText(commit).hasPrefix("Commit 3: text → node ") }, timeout: 5),
                      "Show changed only the readout: \(pluginText(commit))")
        reveal(pair("-raw-input-button").js).click()
        XCTAssertTrue(waitUntil({ self.pluginText(lastAction) == "Last: raw input final transcript" }, timeout: 5), "View raw input… opens the final transcript.")

        reveal(pair("-section-tools").js).click()
        XCTAssertTrue(js("token-stats-measured-tool-Bash").waitToExist(timeout: 5), "Tools & MCP lists each tool.")
        reveal(pair("-section-tools").native).click()
        for suffix in ["-measured-tool-fixturelogs/query_logs", "-measured-tool-Read", "-measured-tool-Bash", "-measured-tool-Read-calls", "-server-fixturelogs"] {
            assertSameSize(suffix)
        }
        XCTAssertEqual(pluginText(js("token-stats-measured-tool-fixturelogs/query_logs-total")), "18,000")
        XCTAssertEqual(pluginText(js("token-stats-server-fixturelogs-detail")), "2 tools · 1 calls · definitions 1,200")
        reveal(pair("-section-tools").js)
        attachScreenshot(named: "Token Stats: Tools & MCP")

        reveal(pair("-section-overhead").js).click()
        XCTAssertTrue(js("token-stats-overhead-0").waitToExist(timeout: 5), "Overhead lists what every request carries.")
        reveal(pair("-section-overhead").native).click()
        for suffix in ["-overhead-0", "-overhead-1", "-overhead-2", "-agent-claude", "-agent-claude/fxw"] {
            assertSameSize(suffix)
        }
        XCTAssertEqual(pluginText(js("token-stats-overhead-0-requests")), "× every request")
        XCTAssertEqual(pluginText(js("token-stats-agent-claude/fxw-sent")), "31,200")
        reveal(pair("-section-overhead").js)
        attachScreenshot(named: "Token Stats: Overhead and agents")

        // Done closes the JavaScript modal; the counter opens it again.
        reveal(js("close-token-stats-button")).click()
        XCTAssertTrue(waitUntil({ !pair("-modal").js.exists }, timeout: 5), "Done closed the JavaScript modal.")
        XCTAssertTrue(waitUntil({ self.pluginText(lastAction) == "Last: done" }, timeout: 5))
        XCTAssertTrue(pair("-modal").native.exists, "The native modal stays open.")
        attachScreenshot(named: "Token Stats: JavaScript modal closed by Done, native open")
        reveal(jsCounter).click()
        XCTAssertTrue(pair("-modal").js.waitToExist(timeout: 5), "The counter opened the modal again.")
        XCTAssertTrue(waitUntil({ self.pluginText(lastAction) == "Last: open" }, timeout: 5))
        XCTAssertEqual(pluginText(native("native-last-action")), "Last: section overhead", "The native modal keeps its own state.")
        attachScreenshot(named: "Token Stats: the counter reopened the JavaScript modal")
    }
    // case-contract: test_plugin_add_mode_toggles_and_shows_placeholders | Add Plugin mode is off by default; the Plugins menu's Add Plugin Mode item and `plugin mode --on` turn it on, `plugin mode` reports the saved state to a fresh CLI process, `--off` turns it off, and any other option is refused as invalid_argument. While it is on, a bar across the top of the window explains the mode and its Close button turns it off; the board's sidebar shows a labeled Add here button below Scheduled Tasks; an open task shows its sidebar expanded even when the sidebar was collapsed, with a labeled Add here button as the sidebar's first section, above Changes, an Add here icon beside the Terminal button and an Add here icon beside the composer's Skills button; and the standalone chat shows only the composer's Add here icon. Turning the mode off from the CLI removes every placeholder live and returns the sidebar to its saved collapsed state.
    func test_plugin_add_mode_toggles_and_shows_placeholders() throws {
        launchApp(defaultParent: fixture.parent.path)
        _ = try runCLI(["task", "create", "--title", "Plugin mode task", "--prompt", "Fixture task description.", "--root", fixture.primary.path])
        let scheduled = element("scheduled-tasks-button")
        XCTAssertTrue(scheduled.waitToExist(timeout: 15))
        XCTAssertFalse(try pluginMode(), "Add Plugin mode starts off.")
        XCTAssertFalse(element("plugin-mode-banner").exists)
        XCTAssertFalse(element("plugin-add-here-mainSidebar").exists, "No placeholder shows while the mode is off.")

        clickPluginsMenuItem("Add Plugin Mode")
        XCTAssertTrue(element("plugin-mode-banner").waitToExist(timeout: 10), "The mode's bar appears across the top of the window.")
        XCTAssertTrue(pluginText(element("plugin-mode-banner-text")).contains("Add here"))
        XCTAssertTrue(try pluginMode(), "The menu item turns the mode on for the CLI too.")
        let boardPlaceholder = element("plugin-add-here-mainSidebar")
        XCTAssertTrue(boardPlaceholder.waitToExist(timeout: 5), "The board's sidebar shows its placeholder.")
        XCTAssertEqual(boardPlaceholder.label, "Add here")
        XCTAssertGreaterThan(boardPlaceholder.frame.width, 120, "The sidebar placeholder is a labeled button as wide as the sidebar.")
        XCTAssertGreaterThanOrEqual(boardPlaceholder.frame.minY, scheduled.frame.maxY - 1, "The placeholder sits below Scheduled Tasks.")
        XCTAssertLessThan(abs(boardPlaceholder.frame.minX - scheduled.frame.minX), 2, "The placeholder lines up with Scheduled Tasks.")
        attachScreenshot(named: "Add Plugin mode on the board: the bar and the sidebar's Add here")

        element("plugin-mode-close").click()
        XCTAssertTrue(waitForDisappearance(element("plugin-mode-banner")), "Close leaves the mode.")
        XCTAssertTrue(waitForDisappearance(boardPlaceholder))
        XCTAssertFalse(try pluginMode())

        // A collapsed task sidebar shows expanded while the mode is on, without changing the saved state.
        openTask(named: "Plugin mode task")
        let hideSidebar = element("hide-task-sidebar-button")
        XCTAssertTrue(waitUntil({ hideSidebar.isHittable }, timeout: 10))
        hideSidebar.click()
        XCTAssertTrue(element("task-sidebar-collapsed").waitToExist(timeout: 5))
        _ = try runCLI(["plugin", "mode", "--on"])
        XCTAssertTrue(element("task-sidebar").waitToExist(timeout: 10), "Add Plugin mode shows the sidebar expanded.")
        XCTAssertFalse(element("task-sidebar-collapsed").exists)
        let sidebarPlaceholder = element("plugin-add-here-conversationSidebar")
        let toolbarPlaceholder = element("plugin-add-here-conversationToolbar")
        let composerPlaceholder = element("plugin-add-here-composerActions")
        for placeholder in [sidebarPlaceholder, toolbarPlaceholder, composerPlaceholder] {
            XCTAssertTrue(placeholder.waitToExist(timeout: 10), "\(placeholder) shows in the open task.")
            XCTAssertEqual(placeholder.label, "Add here")
        }
        XCTAssertGreaterThan(sidebarPlaceholder.frame.width, 120, "The sidebar placeholder is a labeled button.")
        XCTAssertLessThan(toolbarPlaceholder.frame.width, 40, "The toolbar placeholder is only an icon.")
        XCTAssertLessThan(composerPlaceholder.frame.width, 40, "The composer placeholder is only an icon.")
        XCTAssertTrue(element("plugin-mode-banner").exists)
        let terminal = element("toggle-terminal-button")
        XCTAssertLessThanOrEqual(toolbarPlaceholder.frame.maxX, terminal.frame.minX + 1, "The toolbar placeholder sits beside the Terminal button.")
        XCTAssertLessThan(abs(toolbarPlaceholder.frame.midY - terminal.frame.midY), 4, "It shares the Terminal button's row.")
        let skills = element("open-skills-button")
        XCTAssertGreaterThanOrEqual(composerPlaceholder.frame.minX, skills.frame.maxX - 1, "The composer placeholder sits beside the Skills button.")
        XCTAssertLessThan(abs(composerPlaceholder.frame.midY - skills.frame.midY), 4, "It shares the Skills button's row.")
        XCTAssertGreaterThan(sidebarPlaceholder.frame.minY, element("hide-task-sidebar-button").frame.maxY, "The sidebar placeholder is a section below the header.")
        XCTAssertLessThan(sidebarPlaceholder.frame.maxY, terminal.frame.minY, "It sits above the command row.")
        let changesTitle = element("workspace-changes-title")
        XCTAssertTrue(changesTitle.waitToExist(timeout: 5))
        XCTAssertLessThanOrEqual(sidebarPlaceholder.frame.maxY, changesTitle.frame.minY + 1, "The sidebar placeholder is the first section, above Changes.")
        attachScreenshot(named: "Add Plugin mode in a task: sidebar, toolbar and composer placeholders")

        _ = try runCLI(["plugin", "mode", "--off"])
        for placeholder in [sidebarPlaceholder, toolbarPlaceholder, composerPlaceholder] {
            XCTAssertTrue(waitForDisappearance(placeholder, timeout: 10), "Turning the mode off from the CLI removes \(placeholder).")
        }
        XCTAssertTrue(element("task-sidebar-collapsed").waitToExist(timeout: 5), "The sidebar returns to its saved collapsed state.")
        XCTAssertFalse(element("plugin-mode-banner").exists)
        attachScreenshot(named: "Add Plugin mode off: the sidebar collapsed again")
        element("show-task-sidebar-button").click()
        XCTAssertTrue(element("task-sidebar").waitToExist(timeout: 5))

        // The standalone chat has only the composer's placement.
        returnToBoard()
        _ = try runCLI(["plugin", "mode", "--on"])
        // The mode's bar slides in above the board, moving the header down; click once it rests.
        XCTAssertTrue(element("plugin-mode-banner").waitToExist(timeout: 10))
        let chatButton = element("chat-sidebar-button")
        XCTAssertTrue(waitForStableFrame(chatButton), "The Chat button stops moving once the bar is in.")
        chatButton.click()
        let chat = element("chat-sidebar")
        XCTAssertTrue(chat.waitToExist(timeout: 10))
        XCTAssertTrue(chat.descendants(matching: .any)["plugin-add-here-composerActions"].waitToExist(timeout: 10), "The chat's composer shows its placeholder.")
        XCTAssertFalse(chat.descendants(matching: .any)["plugin-add-here-conversationSidebar"].exists, "The chat has no task sidebar.")
        XCTAssertFalse(chat.descendants(matching: .any)["plugin-add-here-conversationToolbar"].exists)
        attachScreenshot(named: "Add Plugin mode in the standalone chat: only the composer's Add here")
        // Opening the chat grows the window past a small screen's trailing edge, where the bar's
        // Close button then sits; Close is covered on the board above, so leave from the CLI.
        _ = try runCLI(["plugin", "mode", "--off"])
        XCTAssertTrue(waitForDisappearance(chat.descendants(matching: .any)["plugin-add-here-composerActions"]))
    }
    // case-contract: test_plugin_authoring_task_starts_with_placement_and_skill | Plugin authoring starts with centered name and presentation setup, then opens a standalone conversation beside a live preview without a board card or task header. The editor header shows “Plugin editor” beside its back button. The Plugins menu reopens the same conversation and preview, including unsaved drafts and history. Name, presentation, placement and plugin identity persist; invalid setup is rejected. Claude and Codex receive plugin instructions and the bundled skill without installing files in the user’s home.
    func test_plugin_authoring_task_starts_with_placement_and_skill() throws {
        let environment = try installClaudeFixture(named: "claude-fixture-plugin-author")
        let historyURL = URL(fileURLWithPath: try XCTUnwrap(environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"]) + ".history")
        func turns() -> [[String: Any]] {
            guard let data = try? Data(contentsOf: historyURL),
                  let history = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            return (history["turns"] as? [[String: Any]] ?? []).filter { ($0["userText"] as? String)?.isEmpty == false }
        }
        launchApp(defaultParent: fixture.parent.path)
        _ = try runCLI(["settings", "set-default-provider", "claude"])
        _ = try runCLI(["task", "create", "--title", "Plugin source task", "--prompt", "Fixture task description.", "--root", fixture.primary.path])
        let tasksBefore = try boardTaskRecords().count
        _ = try runCLI(["settings", "clear-parent"])
        assertCLIError(try runCLI(["plugin", "author", "--placement", "titleBar"], expectedStatus: 2), code: "invalid_argument")
        XCTAssertEqual(try boardTaskRecords().count, tasksBefore, "A refused placement opens no task.")

        // From the board's sidebar, setup is centered until both choices are made.
        _ = try runCLI(["plugin", "mode", "--on"])
        let boardPlaceholder = element("plugin-add-here-mainSidebar")
        XCTAssertTrue(boardPlaceholder.waitToExist(timeout: 15))
        boardPlaceholder.click()
        XCTAssertTrue(element("plugin-creation-name").waitToExist(timeout: 10))
        XCTAssertFalse(element("plugin-creation-preview").exists)
        XCTAssertFalse(element("message-composer").exists)
        XCTAssertEqual(element("plugin-creation-name").frame.midX, app.windows.firstMatch.frame.midX, accuracy: 35)
        XCTAssertFalse(element("plugin-creation-continue").isEnabled)
        attachScreenshot(named: "Plugin creation name")
        element("plugin-creation-name").click()
        element("plugin-creation-name").typeText("Timer")
        element("plugin-creation-continue").click()
        XCTAssertTrue(element("plugin-creation-presentation").waitToExist(timeout: 5))
        XCTAssertFalse(element("plugin-creation-preview").exists)
        XCTAssertFalse(element("message-composer").exists)
        app.radioButtons["Modal"].click()
        attachScreenshot(named: "Plugin creation presentation")
        element("plugin-creation-start").click()
        XCTAssertTrue(element("plugin-creation-preview").waitToExist(timeout: 15))
        let editorTitle = app.staticTexts["Plugin editor"]
        let editorBackButton = element("back-to-board-button")
        XCTAssertTrue(editorTitle.waitToExist(timeout: 10), "The editor title appears.")
        XCTAssertGreaterThan(editorTitle.frame.minX, editorBackButton.frame.maxX, "The title sits to the right of the back button.")
        XCTAssertEqual(editorTitle.frame.midY, editorBackButton.frame.midY, accuracy: 8, "The title shares the back button's header row.")
        attachAppWindowScreenshot(named: "Plugin editor full app")
        XCTAssertFalse(try pluginMode())
        func sessions() throws -> [[String: Any]] {
            try XCTUnwrap((try runCLI(["plugin", "sessions"])["result"] as? [String: Any])?["sessions"] as? [[String: Any]])
        }
        let boardTask = try XCTUnwrap(try sessions().first { $0["title"] as? String == "Timer" })
        XCTAssertEqual(try boardTaskRecords().count, tasksBefore, "Creating a plugin adds no board card.")
        XCTAssertFalse(element("task-view-title").exists, "The editor has no regular task header.")
        XCTAssertFalse(element("task-status-message").exists)
        XCTAssertFalse(element("add-conversation-repository-button").exists)
        XCTAssertFalse(element("task-header-status").exists, "The editor has no task status in its header.")
        let pluginID = try XCTUnwrap(boardTask["authoredPluginID"] as? String)
        XCTAssertEqual(boardTask["pluginPlacement"] as? String, "mainSidebar")
        XCTAssertTrue(waitUntil({ turns().contains { ($0["userText"] as? String ?? "").contains(pluginID) && ($0["userText"] as? String ?? "").contains("presentation modal") } }, timeout: 20))
        attachScreenshot(named: "Plugin creation empty preview")
        element("back-to-board-button").click()
        let draftMenu = app.menuBars.menuBarItems["Plugins"]
        draftMenu.click()
        XCTAssertTrue(draftMenu.menuItems["Edit Timer…"].waitToExist(timeout: 10))
        draftMenu.menuItems["Edit Timer…"].click()
        XCTAssertTrue(element("plugin-creation-preview").waitToExist(timeout: 10), "A draft can be reopened before its plugin folder exists.")
        XCTAssertGreaterThan(element("message-composer").frame.width, 0)
        XCTAssertGreaterThan(element("plugin-creation-preview").frame.width, 0)
        XCTAssertLessThanOrEqual(element("message-composer").frame.maxX, element("plugin-creation-preview").frame.minX + 2)
        func sendPreviewTurn(_ value: String) throws {
            let payload = try JSONSerialization.data(withJSONObject: ["folder": pluginsFolder.appendingPathComponent(pluginID).path, "text": value])
            let message = "plugin-preview-fixture " + (try XCTUnwrap(String(data: payload, encoding: .utf8)))
            element("message-composer").click()
            element("message-composer").typeText(message)
            XCTAssertTrue(waitUntil({ self.element("send-message-button").isEnabled }, timeout: 20))
            element("send-message-button").click()
            XCTAssertTrue(waitUntil({ turns().contains { $0["userText"] as? String == message } }, timeout: 20))
            XCTAssertTrue(app.staticTexts["Plugin preview updated: " + value].waitToExist(timeout: 20))
            XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("plugin-creation-preview").descendants(matching: .any)["preview-content"]) == value }, timeout: 20))
        }
        try sendPreviewTurn("First preview")
        attachScreenshot(named: "Plugin creation live preview")
        try sendPreviewTurn("Updated preview")
        element("message-composer").click()
        element("message-composer").typeText("A saved draft")
        element("back-to-board-button").click()
        let menu = app.menuBars.menuBarItems["Plugins"]
        menu.click()
        let edit = menu.menuItems["Edit Timer…"]
        XCTAssertTrue(edit.waitToExist(timeout: 10))
        edit.click()
        XCTAssertTrue(element("plugin-creation-preview").waitToExist(timeout: 10))
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("plugin-creation-preview").descendants(matching: .any)["preview-content"]) == "Updated preview" }, timeout: 10))
        XCTAssertTrue(waitUntil({ (self.element("message-composer").value as? String ?? "").contains("A saved draft") }, timeout: 10))
        XCTAssertTrue(app.staticTexts["Plugin preview updated: Updated preview"].waitToExist(timeout: 10))
        attachScreenshot(named: "Reopened plugin editor")
        _ = try runCLI(["settings", "set-parent", fixture.parent.path])

        // The same setup opens from a conversation's composer.
        element("back-to-board-button").click()
        openTask(named: "Plugin source task")
        _ = try runCLI(["plugin", "mode", "--on"])
        let composerPlaceholder = element("plugin-add-here-composerActions")
        XCTAssertTrue(composerPlaceholder.waitToExist(timeout: 10))
        composerPlaceholder.click()
        XCTAssertTrue(element("plugin-creation-name").waitToExist(timeout: 10))
        element("plugin-creation-name").click()
        element("plugin-creation-name").typeText("Composer plugin")
        element("plugin-creation-continue").click()
        element("plugin-creation-start").click()
        XCTAssertTrue(element("plugin-creation-preview").waitToExist(timeout: 15))
        let composerTask = try XCTUnwrap(try sessions().first { $0["title"] as? String == "Composer plugin" })
        XCTAssertEqual(composerTask["pluginPlacement"] as? String, "composerActions")
        let composerPluginID = try XCTUnwrap(composerTask["authoredPluginID"] as? String)
        try writeInstalledPlugin(composerPluginID, source: Self.pluginContextSource, placement: "composerActions", name: "Composer plugin")
        let preview = element("plugin-creation-preview")
        let previewComposer = element("plugin-preview-composer")
        XCTAssertTrue(previewComposer.waitToExist(timeout: 15))
        previewComposer.click()
        previewComposer.typeText("draft")
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: preview.descendants(matching: .any)["plugin-draft"]) == "draft" }, timeout: 10))
        preview.descendants(matching: .any)["plugin-set-draft"].click()
        XCTAssertTrue(waitUntil({ (previewComposer.value as? String) == "fresh draft" }, timeout: 10))
        previewComposer.click()
        previewComposer.typeKey("a", modifierFlags: .command)
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: preview.descendants(matching: .any)["plugin-selection"]) == "fresh draft" }, timeout: 10))
        preview.descendants(matching: .any)["plugin-upper"].click()
        XCTAssertTrue(waitUntil({ (previewComposer.value as? String) == "FRESH DRAFT" }, timeout: 10))
        previewComposer.click()
        previewComposer.typeKey(.leftArrow, modifierFlags: .command)
        for _ in 0..<5 { previewComposer.typeKey(.rightArrow, modifierFlags: .shift) }
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: preview.descendants(matching: .any)["plugin-selection"]) == "FRESH" }, timeout: 10))
        preview.descendants(matching: .any)["plugin-insert"].click()
        XCTAssertTrue(waitUntil({ (previewComposer.value as? String) == "FRESH! DRAFT" }, timeout: 10))
        element("message-composer").click()
        element("message-composer").typeText("other")
        XCTAssertTrue((element("message-composer").value as? String ?? "").contains("other"))
        preview.descendants(matching: .any)["plugin-focus"].click()
        app.typeText("?")
        XCTAssertTrue(waitUntil({ (previewComposer.value as? String)?.contains("?") == true }, timeout: 10))

        // Editing an installed plugin creates its first editor session.
        element("back-to-board-button").click()
        try writeInstalledPlugin("installed-editor", source: Self.pluginContextSource, placement: "mainSidebar", name: "Installed editor")
        _ = try runCLI(["plugin", "refresh"])
        let installedMenu = app.menuBars.menuBarItems["Plugins"]
        installedMenu.click()
        XCTAssertTrue(installedMenu.menuItems["Edit Installed editor…"].waitToExist(timeout: 10))
        installedMenu.menuItems["Edit Installed editor…"].click()
        XCTAssertTrue(element("plugin-creation-preview").waitToExist(timeout: 10))
        XCTAssertTrue(try sessions().contains { $0["authoredPluginID"] as? String == "installed-editor" })
        element("back-to-board-button").click()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: pluginsFolder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: pluginsFolder.path) }
        installedMenu.click()
        installedMenu.menuItems["Delete Installed editor…"].click()
        XCTAssertTrue(app.dialogs.buttons["Delete"].waitToExist(timeout: 5))
        app.dialogs.buttons["Delete"].click()
        XCTAssertTrue(app.dialogs.buttons["OK"].waitToExist(timeout: 10), "A failed folder removal reports an error.")
        app.dialogs.buttons["OK"].click()
        XCTAssertTrue(try sessions().contains { $0["authoredPluginID"] as? String == "installed-editor" })
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: pluginsFolder.path)
        installedMenu.click()
        installedMenu.menuItems["Delete Installed editor…"].click()
        app.dialogs.buttons["Delete"].click()
        XCTAssertTrue(waitUntil({ (try? sessions().contains { $0["authoredPluginID"] as? String == "installed-editor" }) == false }, timeout: 10))

        // A pre-existing task-backed editor keeps its session, draft and preview when migrated.
        let legacyResponse = try runCLI(["task", "create", "--title", "New plugin: Legacy editor", "--prompt", "Legacy description", "--provider", "claude"])
        let legacy = try XCTUnwrap(legacyResponse["result"] as? [String: Any])
        let legacyID = try XCTUnwrap(legacy["id"] as? String)
        _ = try runCLI(["conversation", "send", legacyID, "--message", "Remember this legacy conversation"], extraEnvironment: environment)
        _ = try runCLI(["task", "draft", legacyID, "--text", "Legacy unsent draft"])
        try writeInstalledPlugin("legacy-editor", source: Self.pluginContextSource, placement: "mainSidebar", name: "Legacy editor")
        try seedLegacyPluginTask(taskID: legacyID, pluginID: "legacy-editor")
        _ = try runCLI(["plugin", "refresh"])
        installedMenu.click()
        XCTAssertTrue(installedMenu.menuItems["Edit Legacy editor…"].waitToExist(timeout: 10))
        installedMenu.menuItems["Edit Legacy editor…"].click()
        XCTAssertTrue(element("plugin-creation-preview").waitToExist(timeout: 10))
        XCTAssertTrue(waitUntil({ (self.element("message-composer").value as? String ?? "").contains("Legacy unsent draft") }, timeout: 10))
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("plugin-creation-preview").descendants(matching: .any)["plugin-placement"]) == "mainSidebar" }, timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Remember this legacy conversation")).firstMatch.waitToExist(timeout: 10))
        XCTAssertFalse(try boardTaskRecords().contains { $0["id"] as? String == legacyID })
        attachScreenshot(named: "Migrated plugin editor")

        element("back-to-board-button").click()
        let legacyDeleteResponse = try runCLI(["task", "create", "--title", "New plugin: Delete legacy", "--prompt", "Legacy description"])
        let legacyDeleteID = try XCTUnwrap((legacyDeleteResponse["result"] as? [String: Any])?["id"] as? String)
        try writeInstalledPlugin("legacy-delete", source: Self.pluginContextSource, placement: "mainSidebar", name: "Delete legacy")
        try seedLegacyPluginTask(taskID: legacyDeleteID, pluginID: "legacy-delete")
        _ = try runCLI(["plugin", "refresh"])
        installedMenu.click()
        XCTAssertTrue(installedMenu.menuItems["Delete Delete legacy…"].waitToExist(timeout: 10))
        installedMenu.menuItems["Delete Delete legacy…"].click()
        app.dialogs.buttons["Delete"].click()
        XCTAssertTrue(waitUntil({ (try? self.boardTaskRecords().contains { $0["id"] as? String == legacyDeleteID }) == false }, timeout: 10))

    }
    // case-contract: test_plugin_editor_reattaches_after_daemon_restart | A plugin editor follows a running Claude turn after a daemon restart, restores its answer once alongside the preview, and settles without a task outcome nudge. Claude represents the shared reattachment settlement used by both providers.
    func test_plugin_editor_reattaches_after_daemon_restart() throws {
        let environment = try installClaudeFixture(named: "claude-fixture-reattach-plugin")
        let executable = try XCTUnwrap(environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"])
        launchApp(defaultParent: fixture.parent.path)
        _ = try runCLI(["settings", "set-default-provider", "claude"])
        _ = try runCLI(["plugin", "author", "--placement", "mainSidebar", "--name", "Restart plugin", "--presentation", "modal", "--provider", "claude"], extraEnvironment: environment)
        let menu = app.menuBars.menuBarItems["Plugins"]
        XCTAssertTrue(waitUntil({ menu.click(); let found = menu.menuItems["Edit Restart plugin…"].exists; if !found { self.app.typeKey(.escape, modifierFlags: []) }; return found }, timeout: 15))
        menu.menuItems["Edit Restart plugin…"].click()
        XCTAssertTrue(element("plugin-creation-preview").waitToExist(timeout: 10))
        let composer = element("message-composer")
        composer.click()
        composer.typeKey("a", modifierFlags: .command)
        composer.typeKey(.delete, modifierFlags: [])
        touch(executable + ".reattach-hold-nudge")
        startRestartChatTurn(executable, "Continue this plugin after restart.")
        try killDaemon(environment: environment)
        touch(executable + ".reattach-release-quiet")
        XCTAssertTrue(app.staticTexts["After restart."].waitToExist(timeout: 30))
        XCTAssertTrue(waitUntil({ !self.element("pause-response-button").exists }, timeout: 30))
        XCTAssertEqual(app.staticTexts.matching(identifier: "After restart.").count, 1, "The recovered answer is shown once.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: executable + ".reattach-hold-nudge"), "The editor did not request a task outcome.")
        XCTAssertTrue(element("plugin-creation-preview").exists)
        XCTAssertTrue(waitUntil({ !self.element("codex-chat-error").exists }, timeout: 15), "A successful reconnect clears the transient bridge error.")
        composer.click()
        composer.typeText("Continue working")
        XCTAssertTrue((composer.value as? String ?? "").contains("Continue working"), "The composer accepts the next request.")
        attachScreenshot(named: "Plugin editor after daemon restart")
    }
    // case-contract: test_plugin_install_refresh_and_delete | Each plugin is a folder in the data directory's plugins folder holding plugin.json (id, name, icon, placement, presentation) and its script. `plugin list` reports none at first; after plugins are written, `plugin refresh` validates every folder, bumps the plugins revision, and reports the valid plugin beside invalid ones with their errors (an unknown placement or presentation, a manifest id that does not match its folder, a missing manifest or script, and a script that throws or uses an unknown atom when rendered once with sample context), which a fresh `plugin list` reports the same way without bumping the revision. After a refresh the window shows the valid plugin's button at its placement and the Plugins menu lists every plugin with its placement, an invalid one with its first error. Deleting a plugin from the Plugins menu after confirming, or with `plugin delete --id`, removes its folder, its button and its menu entry; an unknown id is not_found and an id that is not a plugin folder name is invalid_argument.
    func test_plugin_install_refresh_and_delete() throws {
        launchApp(defaultParent: fixture.parent.path)
        XCTAssertTrue(element("scheduled-tasks-button").waitToExist(timeout: 15))
        XCTAssertEqual(try installedPluginIDs(), [])
        let hello = #"Playhouse.render(h(Text, { testID: "hello" }, "Hello from a plugin"));"#
        try writeInstalledPlugin("hello-board", source: hello, placement: "mainSidebar", presentation: "page", name: "Hello Board", icon: "hand.wave")
        try writeInstalledPlugin("throws", source: #"throw new Error("Plugin exploded");"#)
        try writeInstalledPlugin("bad-placement", source: hello, placement: "titleBar")
        XCTAssertFalse(element("plugin-entry-hello-board").exists, "A plugin shows only after a refresh.")

        let refreshed = try XCTUnwrap(try runCLI(["plugin", "refresh"])["result"] as? [String: Any])
        XCTAssertEqual(refreshed["revision"] as? Int, 1)
        let entry = element("plugin-entry-hello-board")
        XCTAssertTrue(entry.waitToExist(timeout: 10), "After a refresh the valid plugin's button shows at its placement.")
        XCTAssertEqual(entry.label, "Hello Board")
        XCTAssertGreaterThanOrEqual(entry.frame.minY, element("scheduled-tasks-button").frame.maxY - 1, "Its button sits below Scheduled Tasks.")
        XCTAssertFalse(element("plugin-entry-throws").exists, "An invalid plugin shows no button.")
        attachScreenshot(named: "An installed plugin's button in the board's sidebar")

        let menu = app.menuBars.menuBarItems["Plugins"]
        menu.click()
        let helloItem = menu.menuItems["Hello Board — Main sidebar"]
        XCTAssertTrue(helloItem.waitToExist(timeout: 5), "The Plugins menu lists the installed plugin with its placement.")
        XCTAssertTrue(menu.menuItems["Throws — Chat input actions"].exists, "The Plugins menu lists an invalid plugin too.")
        XCTAssertTrue(menu.menuItems["Bad Placement — titleBar"].exists)
        XCTAssertTrue(menu.menuItems.matching(NSPredicate(format: "title CONTAINS %@", "Plugin exploded")).firstMatch.exists,
                      "An invalid plugin shows its first error.")
        XCTAssertEqual(menu.menuItems.matching(NSPredicate(format: "title CONTAINS %@", "Unknown placement")).count, 1,
                       "Only the invalid plugins show an error, each its own.")
        XCTAssertFalse(helloItem.isEnabled, "A plugin's row is a label, not a command.")
        attachScreenshot(named: "The Plugins menu lists installed plugins with their placement")
        menu.menuItems["Delete Hello Board…"].click()
        let confirm = app.dialogs.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitToExist(timeout: 5), "Deleting from the Plugins menu asks for confirmation.")
        XCTAssertTrue(app.dialogs.staticTexts["Delete the plugin Hello Board?"].exists, "The confirmation names the plugin.")
        attachScreenshot(named: "Deleting a plugin asks for confirmation")
        confirm.click()
        XCTAssertTrue(waitForDisappearance(entry, timeout: 10), "Deleting removes the plugin's button.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pluginsFolder.appendingPathComponent("hello-board").path), "Deleting removes its folder.")
        XCTAssertFalse(try installedPluginIDs().contains("hello-board"))

        _ = try runCLI(["plugin", "delete", "--id", "throws"])
        menu.click()
        XCTAssertTrue(menu.menuItems["Bad Placement — titleBar"].waitToExist(timeout: 5))
        XCTAssertTrue(waitUntil({ !menu.menuItems["Delete Throws…"].exists && !menu.menuItems["Delete Hello Board…"].exists }, timeout: 10),
                      "The menu drops deleted plugins.")
        attachScreenshot(named: "The Plugins menu after deleting plugins")
        app.typeKey(.escape, modifierFlags: [])
        assertCLIError(try runCLI(["plugin", "delete", "--id", "throws"], expectedStatus: 3), code: "not_found")
        assertCLIError(try runCLI(["plugin", "delete", "--id", "../plugins"], expectedStatus: 2), code: "invalid_argument")
    }
    // case-contract: test_plugin_surfaces_receive_context_and_host_access | An installed plugin receives its placement's context in Playhouse.props: the plugin and the appearance everywhere, the task with its repositories and context folders in the conversation placements, and the composer's draft and selected text in the composer placement, while the board's sidebar gets no task. `plugin render --plugin <id> --task <id>` renders it headlessly with that real context. Playhouse.bridge runs any bridge command but plugin render against the real store (a rename is seen by a fresh CLI process) and rejects a failing one with its code; Playhouse.ui close, openTask and the composer's setDraft, insertText, replaceSelection and focus are recorded headlessly; a composer call from the board's sidebar and a plugin render call are refused the same way in both hosts; and --task without --plugin or an unknown plugin is refused. In the window a page plugin from the board's sidebar covers the board, reads the real board, and its openTask opens that task without sending anything; a composer popover plugin opens anchored to its button showing the draft and the selected text, and its replaceSelection replaces the selected text in the composer; a sidebar plugin from the conversation sidebar slides in at the trailing edge showing the task's title and repository, inserts text after the selection, replaces the draft, renames the task, and closes with its close button; and a modal plugin beside the Terminal button opens as a sheet with the task's context and closes itself with Playhouse.ui.close. Every presentation starts with the app's standard modal header (the plugin's icon, its name and a close button) above the plugin's atoms, which bring no padding of their own yet sit inside the presentation's inset, as does the header: 24 points in a page or sheet, 20 in a sidebar, and 16 in a popover, whose header title is smaller than a sheet's.
    func test_plugin_surfaces_receive_context_and_host_access() throws {
        /// Each presentation starts with the standard header and pads the plugin's atoms by its own inset.
        func assertSurfaceChrome(_ surface: XCUIElement, name: String, inset: CGFloat, underTitleBar: Bool = false, headerFrame: XCUIElement? = nil, headerChromeTop: CGFloat = 0, _ presentation: String) -> XCUIElement {
            let title = surface.descendants(matching: .any)["plugin-surface-title"]
            let placement = surface.descendants(matching: .any)["plugin-placement"]
            XCTAssertEqual(pluginText(title), name, "The \(presentation) surface's header shows the plugin's name.")
            XCTAssertTrue(surface.descendants(matching: .any)["plugin-surface-close"].exists, "The \(presentation) surface's header has its close button.")
            XCTAssertEqual(placement.frame.minX - surface.frame.minX, inset, accuracy: 1.5, "A \(presentation) pads the plugin's atoms \(inset) points: \(placement.frame) in \(surface.frame)")
            let safeAreaTop = underTitleBar ? CGFloat(32) : 0
            let headerTop = title.frame.minY - (headerFrame?.frame.minY ?? surface.frame.minY)
            XCTAssertEqual(headerTop, inset + safeAreaTop + headerChromeTop, accuracy: 2, "A \(presentation) insets its header \(inset) points after its \(safeAreaTop)-point safe area and \(headerChromeTop)-point native chrome: title \(title.frame), surface \(surface.frame), reference \(headerFrame?.frame as Any)")
            XCTAssertGreaterThan(placement.frame.minY, title.frame.maxY, "The \(presentation) surface's atoms start below its header.")
            return title
        }
        try writeInstalledPlugin("context-composer", source: Self.pluginContextSource, placement: "composerActions", presentation: "popover", name: "Context Composer", icon: "textformat")
        try writeInstalledPlugin("context-sidebar", source: Self.pluginContextSource, placement: "conversationSidebar", presentation: "sidebar", name: "Context Sidebar", icon: "sidebar.right")
        try writeInstalledPlugin("context-board", source: Self.pluginContextSource, placement: "mainSidebar", presentation: "page", name: "Context Board", icon: "rectangle.stack")
        try writeInstalledPlugin("context-toolbar", source: Self.pluginContextSource, placement: "conversationToolbar", presentation: "modal", name: "Context Toolbar", icon: "wrench")
        launchApp(defaultParent: fixture.parent.path)
        let plugins = try XCTUnwrap((try runCLI(["plugin", "refresh"])["result"] as? [String: Any])?["plugins"] as? [[String: Any]])
        XCTAssertTrue(plugins.allSatisfy { $0["valid"] as? Bool == true }, "\(plugins)")
        let task = try XCTUnwrap(try runCLI(["task", "create", "--title", "Plugin context task", "--prompt", "Fixture task description.", "--repo", fixture.primary.path])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(task["id"] as? String)
        let window = app.windows.firstMatch

        // A page plugin from the board's sidebar: no task, real bridge access, the shared refusals, and openTask.
        let boardEntry = element("plugin-entry-context-board")
        XCTAssertTrue(boardEntry.waitToExist(timeout: 15))
        boardEntry.click()
        let page = element("plugin-surface-context-board")
        XCTAssertTrue(page.waitToExist(timeout: 10), "The page plugin opens.")
        XCTAssertTrue(waitForStableFrame(page), "The page finishes sliding in before it is clicked.")
        XCTAssertGreaterThan(page.frame.width, window.frame.width - 4, "The page covers the board from edge to edge.")
        XCTAssertGreaterThan(page.frame.height, window.frame.height / 2, "The page covers the board's height.")
        XCTAssertEqual(pluginText(page.descendants(matching: .any)["plugin-task"]), "no task", "The board's sidebar hands the plugin no task.")
        page.descendants(matching: .any)["plugin-count"].click()
        XCTAssertTrue(waitUntil({ self.pluginText(page.descendants(matching: .any)["plugin-status"]) == "tasks: 1" }, timeout: 10),
                      "Playhouse.bridge reads the real board.")
        _ = assertSurfaceChrome(page, name: "Context Board", inset: 24, underTitleBar: true, "page")
        attachScreenshot(named: "A page plugin from the board's sidebar, after a bridge call")
        page.descendants(matching: .any)["plugin-focus"].click()
        XCTAssertTrue(waitUntil({ self.pluginText(page.descendants(matching: .any)["plugin-status"]) == "focus: unavailable" }, timeout: 10),
                      "The board's sidebar has no composer.")
        page.descendants(matching: .any)["plugin-recursive"].click()
        XCTAssertTrue(waitUntil({ self.pluginText(page.descendants(matching: .any)["plugin-status"]) == "render: invalid_argument" }, timeout: 10),
                      "A plugin can't render plugins.")
        page.descendants(matching: .any)["plugin-open"].click()
        XCTAssertTrue(waitForDisappearance(page, timeout: 10), "openTask closes the page.")
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("task-view-title")) == "Plugin context task" }, timeout: 15),
                      "openTask opens the task.")
        let composer = element("message-composer")
        XCTAssertTrue(composer.waitToExist(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'user-message-'")).firstMatch.exists,
                       "openTask sends nothing.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Backlog", "The opened task did not start.")

        // A popover plugin beside the composer's Skills button sees the draft and the selection.
        composer.click()
        composer.typeText("make this loud")
        for _ in 0..<4 { composer.typeKey(.leftArrow, modifierFlags: [.shift]) }
        let composerEntry = element("plugin-entry-context-composer")
        XCTAssertTrue(composerEntry.waitToExist(timeout: 5))
        XCTAssertGreaterThanOrEqual(composerEntry.frame.minX, element("open-skills-button").frame.maxX - 1, "Its button sits beside the Skills button.")
        composerEntry.click()
        let popover = app.popovers.descendants(matching: .any)["plugin-surface-context-composer"]
        XCTAssertTrue(popover.waitToExist(timeout: 10), "The plugin opens in a popover.")
        XCTAssertTrue(waitForStableFrame(popover), "The popover finishes opening before it is clicked.")
        let popoverFrame = app.popovers.firstMatch.frame
        XCTAssertTrue(popoverFrame.minX <= composerEntry.frame.midX && composerEntry.frame.midX <= popoverFrame.maxX,
                      "The popover is anchored over its button: \(popoverFrame) vs \(composerEntry.frame).")
        XCTAssertLessThan(min(abs(popoverFrame.minY - composerEntry.frame.maxY), abs(composerEntry.frame.minY - popoverFrame.maxY)), 30,
                          "The popover's arrow edge meets its button.")
        XCTAssertEqual(pluginText(popover.descendants(matching: .any)["plugin-placement"]), "composerActions")
        XCTAssertEqual(pluginText(popover.descendants(matching: .any)["plugin-task"]), "Plugin context task")
        XCTAssertTrue(waitUntil({ self.pluginText(popover.descendants(matching: .any)["plugin-draft"]) == "make this loud" }, timeout: 5), "The plugin sees the draft.")
        XCTAssertEqual(pluginText(popover.descendants(matching: .any)["plugin-selection"]), "loud", "The plugin sees the selected text.")
        let popoverTitle = assertSurfaceChrome(popover, name: "Context Composer", inset: 16, headerFrame: app.popovers.firstMatch, headerChromeTop: 13, "popover")
        XCTAssertLessThan(popoverTitle.frame.height, 21, "A popover's header uses the smaller 15-point title: \(popoverTitle.frame)")
        let popoverHeaderHeight = popoverTitle.frame.height
        attachScreenshot(named: "A composer plugin's popover showing the draft and the selected text")
        attachElementScreenshot(popover, named: "A popover plugin's compact header over its padded atoms")
        popover.descendants(matching: .any)["plugin-upper"].click()
        XCTAssertTrue(waitUntil({ (composer.value as? String) == "make this LOUD" }, timeout: 10), "replaceSelection replaces the selected text in the composer.")
        attachScreenshot(named: "The composer after the plugin replaced the selection")
        // The composer took the keyboard back, so the plugin closes its own popover.
        popover.descendants(matching: .any)["plugin-close"].click()
        XCTAssertTrue(waitForDisappearance(popover, timeout: 5), "Playhouse.ui.close dismisses the popover.")

        // A sidebar plugin from the conversation sidebar: the task's context and composer edits.
        let sidebarEntry = element("plugin-entry-context-sidebar")
        XCTAssertTrue(sidebarEntry.waitToExist(timeout: 5))
        XCTAssertEqual(sidebarEntry.label, "Context Sidebar")
        XCTAssertGreaterThan(sidebarEntry.frame.width, 120, "A sidebar placement's button is labeled.")
        sidebarEntry.click()
        let panel = element("plugin-surface-context-sidebar")
        XCTAssertTrue(panel.waitToExist(timeout: 10), "The sidebar plugin slides in.")
        XCTAssertTrue(waitForStableFrame(panel), "The panel finishes sliding in before it is clicked.")
        XCTAssertTrue(waitUntil({ abs(panel.frame.maxX - window.frame.maxX) < 4 }, timeout: 5), "It sits against the window's trailing edge.")
        XCTAssertLessThan(abs(panel.frame.width - 360), 4, "It is a 360-point panel, not a page or a sheet.")
        XCTAssertTrue(app.sheets.count == 0 && app.popovers.count == 0)
        XCTAssertEqual(pluginText(panel.descendants(matching: .any)["plugin-task"]), "Plugin context task")
        XCTAssertEqual(pluginText(panel.descendants(matching: .any)["plugin-repositories"]), fixture.primary.lastPathComponent)
        XCTAssertEqual(pluginText(panel.descendants(matching: .any)["plugin-draft"]), "no composer", "Only the composer placement gets the draft.")
            _ = assertSurfaceChrome(panel, name: "Context Sidebar", inset: 20, underTitleBar: true, "sidebar")
        panel.descendants(matching: .any)["plugin-insert"].click()
        XCTAssertTrue(waitUntil({ (composer.value as? String) == "make this LOUD!" }, timeout: 10), "insertText inserts after the selection.")
        panel.descendants(matching: .any)["plugin-set-draft"].click()
        XCTAssertTrue(waitUntil({ (composer.value as? String) == "fresh draft" }, timeout: 10), "setDraft replaces the draft.")
        XCTAssertEqual(pluginText(panel.descendants(matching: .any)["plugin-status"]), "setDraft: ok")
        panel.descendants(matching: .any)["plugin-rename"].click()
        XCTAssertTrue(waitUntil({ self.pluginText(panel.descendants(matching: .any)["plugin-status"]) == "renamed: Renamed by plugin" }, timeout: 10))
        XCTAssertEqual(try taskRecord(id: taskID)?["title"] as? String, "Renamed by plugin", "The plugin's bridge call renamed the task in the store.")
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("task-view-title")) == "Renamed by plugin" }, timeout: 10),
                      "The open task shows the new title.")
        attachScreenshot(named: "A sidebar plugin with the task's context, after editing the draft and renaming the task")
        attachElementScreenshot(panel, named: "A sidebar plugin's inset header and padded atoms")
        panel.descendants(matching: .any)["plugin-surface-close"].click()
        XCTAssertTrue(waitForDisappearance(panel, timeout: 5), "The sidebar closes with its close button.")

        // A modal plugin beside the Terminal button opens as a sheet and closes itself.
        let toolbarEntry = element("plugin-entry-context-toolbar")
        let terminal = element("toggle-terminal-button")
        XCTAssertTrue(toolbarEntry.waitToExist(timeout: 5))
        XCTAssertLessThanOrEqual(toolbarEntry.frame.maxX, terminal.frame.minX + 1, "Its icon sits beside the Terminal button.")
        XCTAssertLessThan(abs(toolbarEntry.frame.midY - terminal.frame.midY), 4)
        XCTAssertLessThan(toolbarEntry.frame.width, 40, "A toolbar entry is only an icon.")
        toolbarEntry.click()
        let sheet = app.sheets.descendants(matching: .any)["plugin-surface-context-toolbar"]
        XCTAssertTrue(sheet.waitToExist(timeout: 10), "The modal plugin opens as a sheet.")
        XCTAssertTrue(waitForStableFrame(sheet), "The sheet finishes opening before it is clicked.")
        XCTAssertEqual(pluginText(sheet.descendants(matching: .any)["plugin-task"]), "Renamed by plugin", "The toolbar placement gets the task.")
        XCTAssertEqual(pluginText(sheet.descendants(matching: .any)["plugin-draft"]), "no composer")
        // The surface starts with the app's standard modal header and pads the plugin's atoms, which bring no padding of their own.
        let surfaceTitle = sheet.descendants(matching: .any)["plugin-surface-title"]
        let surfaceClose = sheet.descendants(matching: .any)["plugin-surface-close"]
        let placement = sheet.descendants(matching: .any)["plugin-placement"]
        XCTAssertEqual(pluginText(surfaceTitle), "Context Toolbar", "The header shows the plugin's name.")
        XCTAssertGreaterThan(surfaceTitle.frame.height, popoverHeaderHeight, "A sheet's header uses the full 19-point title, larger than a popover's.")
        let sheetWindow = app.sheets.firstMatch
        XCTAssertEqual(surfaceTitle.frame.minY - sheetWindow.frame.minY, 24, accuracy: 2, "The header is inset 24 points from the sheet's top: \(surfaceTitle.frame) in \(sheetWindow.frame)")
        XCTAssertGreaterThan(surfaceTitle.frame.minX - sheet.frame.minX, 24 + 16, "The plugin's icon sits before its name, inside the inset.")
        XCTAssertEqual(sheet.frame.maxX - surfaceClose.frame.maxX, 24, accuracy: 8, "The close button sits at the trailing inset: \(surfaceClose.frame)")
        XCTAssertEqual(placement.frame.minX - sheet.frame.minX, 24, accuracy: 1.5, "The plugin's atoms are inset 24 points: \(placement.frame) in \(sheet.frame)")
        XCTAssertGreaterThan(placement.frame.minY, surfaceTitle.frame.maxY + 8, "The plugin's atoms start below the header.")
        attachScreenshot(named: "A modal plugin from the sidebar toolbar")
        attachElementScreenshot(sheet, named: "A modal plugin's standard header over its padded atoms")
        sheet.descendants(matching: .any)["plugin-close"].click()
        XCTAssertTrue(waitForDisappearance(sheet, timeout: 5), "Playhouse.ui.close dismisses the sheet.")
        XCTAssertEqual(app.sheets.count, 0)
    }
    // case-contract: test_plugin_fetch_reaches_the_network | Plugins have a fetch(url, options) global that makes HTTP and HTTPS requests from every placement, answered by the same core in the window and in `plugin render`; the cases reach a local fixture server instead of the internet. A fetch on mount shows the server's greeting; a GET resolves with its status, a response header read case-insensitively and a JSON body; a POST sends its method, headers and text body, which the server receives; a 404 resolves with ok false and its text body; a redirect is followed and reported as redirected with the final URL, while a URL with no path is not; a refused connection rejects with network_error; and a non-http URL such as file:// rejects with invalid_argument without any request. `plugin render` records each fetch in hostCalls as net.fetch with its arguments and result, and `plugin refresh` keeps a plugin that fetches on mount valid. In the window a page plugin from the board's sidebar shows the fetched greeting and each button's result.
    func test_plugin_fetch_reaches_the_network() throws {
        let server = try startPluginFetchServer()
        let source = "var BASE = \"\(server.base)\";\nvar CLOSED = \"\(server.closed)\";\n" + Self.pluginFetchSource
        try writeInstalledPlugin("fetcher", source: source, placement: "mainSidebar", presentation: "page", name: "Fetcher", icon: "network")
        launchApp(defaultParent: fixture.parent.path)
        let plugins = try XCTUnwrap((try runCLI(["plugin", "refresh"])["result"] as? [String: Any])?["plugins"] as? [[String: Any]])
        XCTAssertEqual(plugins.map { $0["valid"] as? Bool }, [true], "A plugin that fetches on mount stays valid: \(plugins)")

        let entry = element("plugin-entry-fetcher")
        XCTAssertTrue(entry.waitToExist(timeout: 15))
        entry.click()
        let page = element("plugin-surface-fetcher")
        XCTAssertTrue(page.waitToExist(timeout: 10), "The fetch plugin opens.")
        XCTAssertTrue(waitForStableFrame(page), "The page finishes sliding in before it is clicked.")
        let greeting = page.descendants(matching: .any)["fetch-greeting"]
        XCTAssertTrue(waitUntil({ self.pluginText(greeting) == "hello from the fixture" }, timeout: 15),
                      "The plugin's fetch on mount reaches the server from the window.")
        let status = page.descendants(matching: .any)["fetch-status"]
        func press(_ testID: String, expecting expected: String, _ message: String) {
            page.descendants(matching: .any)[testID].click()
            XCTAssertTrue(waitUntil({ self.pluginText(status) == expected }, timeout: 15), "\(message) Status: \(pluginText(status))")
        }
        press("fetch-get", expecting: "200 playhouse hello from the fixture", "A GET resolves with its status, a header and a JSON body.")
        attachScreenshot(named: "A plugin page showing what it fetched from the network")
        press("fetch-post", expecting: #"POST secret {"n":1}"#, "A POST sends its method, header and body to the server.")
        attachScreenshot(named: "The plugin's POST, echoed back by the server")
        press("fetch-missing", expecting: "404 false nothing here", "A 404 resolves with ok false and its text.")
        press("fetch-redirect", expecting: "true greeting 200", "A redirect is followed.")
        press("fetch-bare", expecting: "false 404", "A URL with no path is not reported as redirected.")
        press("fetch-refused", expecting: "error: network_error", "A refused connection rejects with network_error.")
        attachScreenshot(named: "A plugin's fetch to a closed port rejected with network_error")
        press("fetch-file", expecting: "error: invalid_argument", "A file URL is refused.")
        attachScreenshot(named: "A plugin's fetch refused for a file URL")
    }
}
