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
    // case-contract: test_plugin_done_archive_renders_from_atoms_like_native | The Plugin Catalog's Done Archive page shows the board's Done archive composed in JavaScript from atoms above the native SwiftUI archive the board presents, built from the same atoms and sample model, each opened by the board header's archive button (the bordered Button atom with the archivebox icon, labelled Done tasks) into a 340-point SidePanel over the trailing edge of a 560 by 460 point stand-in for the board, open at first. Both show the Done tasks title and its close button, the search field with its Search tasks and conversations placeholder, and a list of five rows, each a button opening its task with the done checkmark, its title and its date, beside its pull request actions: a #227 link valued merged (its PR's state, which also ends its help), a PR button beside a #228 link, a PRs button, a disabled busy PR button showing a spinner, and nothing for a task without repositories, each at the same size in both and with the board archive's identifiers (done-archive-task, done-archive-create-pr, done-archive-pr-link, done-archive-search, and done-archive-list valued 5 tasks loaded). The JavaScript tree uses only atoms (SidePanel, Stack, Text, Icon, Button, Link, Spinner, Spacer, Divider, TextField, Scroll), its search a plain TextField on a rounded Stack. The list's end is in view, so its onEndReached runs on both sides (End reached). Typing in the JavaScript search runs onChange (Last: search followed by the text), narrows the rows to the matching title and shows the clear button, which clears the search and brings every row back; a search that matches nothing shows No matching tasks instead of the list. A PR button runs its handler with its task (Last: create pr followed by the title), a row runs open (Last: open followed by the title) and slides the panel away, the archive button opens it again (Last: toggle open), and the close button closes it (Last: close), while the native archive keeps its own state. The list raises no onPress, so pressing it is refused as invalid_argument.
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
        XCTAssertEqual(js("done-archive-pr-link-\(ids[0])-227").value as? String, "merged", "A PR link's value is its PR's state.")
        XCTAssertEqual(native("native-done-archive-pr-link-\(ids[0])-227").value as? String, "merged")
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
    // case-contract: test_plugin_token_stats_renders_from_atoms_like_native | The Plugin Catalog's Token Stats page shows the Token Stats modal composed in JavaScript from atoms above the native SwiftUI modal the board presents, built from the same atoms and sample data, each opened by the task item's token counter (the same overhanging Button atom, labelled with its description and hinted Open Token Stats). Both show the title and the task's title, the View raw input… button, a section bar of Overview, Wasters, Tools & MCP and Overhead with Overview selected, the call headlines (Final transcript size, Total sent (incl. subagents), Excluding cache reads (incl. subagents)), the main-agent and subagent split, the call and output lines, the total, the four buckets, the context compaction and resume cache miss lines, the per-tool rollup and the per-turn rows, each at the same size in both, and the JavaScript tree uses only atoms (Panel, Stack, Text, Label, Button, Spacer, ChoiceBar, Divider, Scroll, Meter) with the board modal's identifiers. Choosing Wasters in the JavaScript section bar runs onChange with its value (Last: section wasters) and shows the largest items, each with a 72-point share bar, its kind, the removed-by-compaction flag, its request count and a small Show button, then the repeated result and the cache miss, while the native modal stays on Overview until its own bar moves it, after which both show the same rows at the same size. Show runs its JavaScript handler with the item's raw input target (Last: raw input claude #14) and View raw input… with the final transcript (Last: raw input final transcript), without re-rendering any row. Tools & MCP lists each tool's bar, calls and total and the MCP server, and Overhead lists what every request carries and each agent. The overview scrolls within at most 320 points and each map section within a fixed 420. Done closes the JavaScript modal (Last: done) and leaves the native one open, and the counter opens it again (Last: open). The section bar raises no onPress, so pressing it is refused as invalid_argument.
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
                       "-output", "-total", "-compaction-0", "-resume-cache-miss-0", "-overview", "-tool-Bash", "-tool-Read", "-turn-turn-1", "-turn-turn-2"] {
            assertSameSize(suffix)
        }
        assertSameSize(js("close-token-stats-button"), native("close-native-token-stats-button"), "Done")
        for (suffix, text) in [("-title", "Token stats"), ("-task-title", "Refactor the login flow"), ("-final-transcript", "650"), ("-total-sent", "3,680"),
                               ("-excluding-cache", "1,710"), ("-excluding-cache-split", "Excluding cache reads: 720 main agent · 990 subagents"),
                               ("-total-calls", "8 model calls · 4 main, 4 across 2 subagents"), ("-output", "Output 170"), ("-total", "3,200"),
                               ("-compaction-0", "Requested with /compact · 2,900 → 900 tokens"),
                               ("-resume-cache-miss-0", "Resume cache miss · Cache read 0 tokens · cache rewritten with 390 tokens")] {
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
    // case-contract: test_plugin_add_mode_toggles_and_shows_placeholders | Add Plugin mode is off by default; the Plugins menu's Add Plugin Mode item and `plugin mode --on` turn it on, `plugin mode` reports the saved state to a fresh CLI process, `--off` turns it off, and any other option is refused as invalid_argument. While it is on, a bar across the top of the window explains the mode and its Close button turns it off; the board's sidebar shows a labeled Add here button below Scheduled Tasks and each task card's bottom row shows an Add here icon, which Close removes; an open task shows its sidebar expanded even when the sidebar was collapsed, with a labeled Add here button as the sidebar's first section, above Changes, an Add here icon before the sidebar's Skills and Terminal buttons and an Add here icon at the start of the composer's toolbar, which has no Skills button in a task; and the standalone chat shows only the composer's Add here icon. Turning the mode off from the CLI removes every placeholder live and returns the sidebar to its saved collapsed state.
    func test_plugin_add_mode_toggles_and_shows_placeholders() throws {
        launchApp(defaultParent: fixture.parent.path)
        _ = try runCLI(["task", "create", "--title", "Plugin mode task", "--prompt", "Fixture task description.", "--root", fixture.primary.path])
        let scheduled = element("plugin-entry-scheduled-tasks")
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
        let modeTaskID = try taskID(named: "Plugin mode task")
        let cardPlaceholder = element("task-card-plugins-\(modeTaskID)").descendants(matching: .any)["plugin-add-here-taskItem"]
        XCTAssertTrue(cardPlaceholder.waitToExist(timeout: 5), "Each task card's bottom row shows its placeholder.")
        XCTAssertEqual(cardPlaceholder.label, "Add here")
        XCTAssertLessThan(cardPlaceholder.frame.width, 40, "The task card placeholder is only an icon.")
        attachScreenshot(named: "Add Plugin mode on the board: the bar and the sidebar's Add here")
        attachElementScreenshot(element("task-card-\(modeTaskID)"), named: "Add Plugin mode: the task card's Add here")

        element("plugin-mode-close").click()
        XCTAssertTrue(waitForDisappearance(element("plugin-mode-banner")), "Close leaves the mode.")
        XCTAssertTrue(waitForDisappearance(boardPlaceholder))
        XCTAssertTrue(waitForDisappearance(cardPlaceholder), "Leaving the mode removes the task card's placeholder.")
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
        XCTAssertLessThanOrEqual(toolbarPlaceholder.frame.maxX, element("open-skills-button").frame.minX + 1, "It sits before the Skills button too.")
        XCTAssertLessThan(abs(toolbarPlaceholder.frame.midY - terminal.frame.midY), 4, "It shares the Terminal button's row.")
        // A task keeps its Skills button in the sidebar, so the composer's toolbar puts the
        // placeholder right after its attach button.
        let planButton = element("conversation-plan-button")
        XCTAssertLessThanOrEqual(element("composer-attach-button").frame.maxX, composerPlaceholder.frame.minX + 1, "The composer placeholder follows the attach button.")
        XCTAssertLessThanOrEqual(composerPlaceholder.frame.maxX, planButton.frame.minX + 1, "The composer placeholder sits before the Plan button.")
        XCTAssertLessThan(abs(composerPlaceholder.frame.midY - planButton.frame.midY), 4, "It shares the Plan button's row.")
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
    // case-contract: test_plugin_draft_versions_and_restore | Plugin edits persist as an isolated draft, saving publishes a new version and preserves history, discard restores the saved preview, and restoring an older version publishes it as a new revision. A draft with no unpublished changes can't be published: `plugin save` refuses it as invalid_argument and adds no version, and `plugin versions` reports `hasChanges`. In the editor, Publish is disabled and Discard changes is hidden until the draft differs from the published plugin, and both return to that state after publishing or discarding.
    func test_plugin_draft_versions_and_restore() throws {
        try writeInstalledPlugin("versioned", source: Self.pluginContextSource, placement: "mainSidebar", name: "Versioned")
        launchApp(defaultParent: fixture.parent.path)
        _ = try runCLI(["plugin", "refresh"])
        clickInstalledPluginAction("Edit…", pluginRow: "Versioned — Main sidebar")
        XCTAssertTrue(element("plugin-creation-preview").waitToExist(timeout: 15))
        let publish = app.buttons["Publish"]
        let discard = app.buttons["Discard changes"]
        func expectPublishable(_ publishable: Bool, _ message: String) {
            XCTAssertTrue(waitUntil({ publish.exists && publish.isEnabled == publishable && discard.exists == publishable }, timeout: 10), message)
        }
        // An unchanged draft can't be published and has nothing to discard.
        expectPublishable(false, "Publish is disabled and Discard changes hidden while the draft matches the plugin.")
        attachAppWindowScreenshot(named: "Plugin editor without changes: Publish disabled, no Discard changes")
        attachElementScreenshot(element("plugin-creation-preview"), named: "Plugin controls without changes")
        let draft = pluginsFolder.appendingPathComponent(".drafts/plugins/versioned/index.js")
        let original = try String(contentsOf: draft, encoding: .utf8)
        let changed = original.replacingOccurrences(of: "props.plugin.placement", with: "\"draft change\"")
        try changed.write(to: draft, atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("plugin-creation-preview").descendants(matching: .any)["plugin-placement"]) == "draft change" }, timeout: 10))
        XCTAssertEqual(try String(contentsOf: pluginsFolder.appendingPathComponent("versioned/index.js"), encoding: .utf8), original)
        expectPublishable(true, "A changed draft can be published or discarded.")
        attachAppWindowScreenshot(named: "Plugin draft preview")
        let toolbarCapture = XCTAttachment(screenshot: element("plugin-creation-preview").screenshot())
        toolbarCapture.name = "Plugin draft controls"
        toolbarCapture.lifetime = .keepAlways
        add(toolbarCapture)
        element("back-to-board-button").click()
        XCTAssertTrue(app.sheets.buttons["OK"].waitToExist(timeout: 5))
        attachAppWindowScreenshot(named: "Plugin draft saved notice")
        app.sheets.buttons["OK"].click()
        clickInstalledPluginAction("Edit…", pluginRow: "Versioned — Main sidebar")
        XCTAssertTrue(element("plugin-creation-preview").waitToExist(timeout: 10))
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("plugin-creation-preview").descendants(matching: .any)["plugin-placement"]) == "draft change" }, timeout: 10))
        expectPublishable(true, "The reopened draft still has changes.")
        publish.click()
        XCTAssertTrue(app.staticTexts["Version 1"].waitToExist(timeout: 10))
        XCTAssertTrue(waitUntil({ ((try? String(contentsOf: self.pluginsFolder.appendingPathComponent("versioned/index.js"), encoding: .utf8)) == changed) }, timeout: 10))
        expectPublishable(false, "After publishing, there is nothing left to publish or discard.")
        attachAppWindowScreenshot(named: "Plugin published: Publish disabled again")
        attachElementScreenshot(element("plugin-creation-preview"), named: "Plugin controls after publishing")
        app.typeKey("s", modifierFlags: .command)
        XCTAssertFalse(app.sheets.firstMatch.waitToExist(timeout: 2), "Command-S on a disabled Publish does nothing.")
        XCTAssertTrue(app.staticTexts["Version 1"].exists, "Command-S without changes publishes nothing.")
        let unchanged = try XCTUnwrap(try runCLI(["plugin", "versions", "--id", "versioned"])["result"] as? [String: Any])
        XCTAssertEqual(unchanged["versions"] as? [Int], [0])
        XCTAssertEqual(unchanged["hasChanges"] as? Bool, false)
        try original.write(to: draft, atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("plugin-creation-preview").descendants(matching: .any)["plugin-placement"]) == "mainSidebar" }, timeout: 10))
        expectPublishable(true, "Editing the published plugin shows Discard changes again.")
        discard.click()
        XCTAssertTrue(app.sheets.staticTexts["The preview will be reset to the published plugin."].waitToExist(timeout: 5), "A saved plugin's discard only resets its draft.")
        app.sheets.buttons["Discard"].click()
        XCTAssertTrue(waitUntil({ (try? String(contentsOf: draft, encoding: .utf8)) == changed }, timeout: 10))
        expectPublishable(false, "Discarding leaves no unpublished changes.")
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("plugin-creation-preview").descendants(matching: .any)["plugin-placement"]) == "draft change" }, timeout: 10))
        try "invalid javascript !".write(to: draft, atomically: true, encoding: .utf8)
        expectPublishable(true, "An invalid draft is still a change.")
        publish.click()
        XCTAssertTrue(app.sheets.buttons["OK"].waitToExist(timeout: 10))
        attachAppWindowScreenshot(named: "Plugin invalid draft error")
        app.sheets.buttons["OK"].click()
        discard.click()
        app.sheets.buttons["Discard"].click()
        XCTAssertTrue(waitUntil({ (try? String(contentsOf: draft, encoding: .utf8)) == changed }, timeout: 10))
        let unsaved = original.replacingOccurrences(of: "props.plugin.placement", with: "\"unsaved draft\"")
        try unsaved.write(to: draft, atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("plugin-creation-preview").descendants(matching: .any)["plugin-placement"]) == "unsaved draft" }, timeout: 10))
        app.menuButtons["Restore version"].click()
        let oldVersion = app.menuItems["Version 0"]
        XCTAssertTrue(oldVersion.waitToExist(timeout: 5))
        let historyCapture = XCTAttachment(screenshot: oldVersion.screenshot())
        historyCapture.name = "Plugin version history item"
        historyCapture.lifetime = .keepAlways
        add(historyCapture)
        oldVersion.click()
        XCTAssertTrue(waitUntil({ (try? String(contentsOf: self.pluginsFolder.appendingPathComponent("versioned/index.js"), encoding: .utf8)) == original }, timeout: 10))
        XCTAssertEqual(try String(contentsOf: draft, encoding: .utf8), unsaved, "Restore preserves the dirty draft.")
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("plugin-creation-preview").descendants(matching: .any)["plugin-placement"]) == "unsaved draft" }, timeout: 10))
        expectPublishable(true, "The draft kept through a restore still differs from the restored plugin.")
        discard.click()
        app.sheets.buttons["Discard"].click()
        XCTAssertTrue(app.staticTexts["Version 2"].waitToExist(timeout: 10))
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("plugin-creation-preview").descendants(matching: .any)["plugin-placement"]) == "mainSidebar" }, timeout: 10))
        attachAppWindowScreenshot(named: "Plugin restored version")
        try changed.write(to: draft, atomically: true, encoding: .utf8)
        let draftDirectory = draft.deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: draftDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: draftDirectory.path) }
        expectPublishable(true, "The changed draft can be published.")
        publish.click()
        XCTAssertTrue(app.sheets.staticTexts["The plugin was published, but the draft could not be refreshed. Your existing draft was preserved."].waitToExist(timeout: 10))
        attachAppWindowScreenshot(named: "Plugin published with draft refresh warning")
        XCTAssertEqual(try String(contentsOf: draft, encoding: .utf8), changed)
        let publishedManifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: pluginsFolder.appendingPathComponent("versioned/plugin.json"))) as? [String: Any])
        XCTAssertEqual(publishedManifest["version"] as? Int, 3)
        app.sheets.buttons["OK"].click()
    }

    // case-contract: test_plugin_unsaved_discard_removes_plugin_and_menu_lists_it | A plugin that was never saved is discarded entirely: `plugin discard --id` on a new authoring session, before any prompt and after a turn wrote its draft, removes its draft folder and its editor conversation, so `plugin sessions` no longer lists it, `plugin edit --id` is not_found, and the plugins revision is bumped; `plugin delete --id` removes an unsaved plugin the same way. Discarding or deleting an unknown id is not_found, a saved plugin's discard still only resets its draft and keeps its editor, and when its draft can't be removed an unsaved plugin keeps its editor conversation for a retry. In the window, the Plugins menu lists each unsaved plugin as its own submenu labeled with its name, placement and (Unsaved), offering Edit and Delete, with no Edit item at the menu's root. Discard changes in an unsaved plugin's editor, shown even before it has a draft, asks to discard the plugin, then closes the editor and removes the plugin from the menu; Delete in its submenu, after confirming, removes another one the same way.
    func test_plugin_unsaved_discard_removes_plugin_and_menu_lists_it() throws {
        launchApp(defaultParent: fixture.parent.path)
        func sessions() throws -> [String] {
            let entries = try XCTUnwrap((try runCLI(["plugin", "sessions"])["result"] as? [String: Any])?["sessions"] as? [[String: Any]])
            return entries.compactMap { $0["authoredPluginID"] as? String }
        }
        let drafts = pluginsFolder.appendingPathComponent(".drafts/plugins")
        _ = try runCLI(["plugin", "mode", "--on"])
        let placeholder = element("plugin-add-here-mainSidebar")
        XCTAssertTrue(placeholder.waitToExist(timeout: 15))
        placeholder.click()
        XCTAssertTrue(element("plugin-creation-name").waitToExist(timeout: 10))
        element("plugin-creation-name").click()
        element("plugin-creation-name").typeText("Blamos")
        element("plugin-creation-continue").click()
        XCTAssertTrue(element("plugin-creation-start").waitToExist(timeout: 5))
        element("plugin-creation-start").click()
        XCTAssertTrue(element("plugin-creation-preview").waitToExist(timeout: 15))
        let blamosID = try XCTUnwrap(try sessions().first)

        // The unsaved plugin is its own submenu, never a root Edit item.
        let menu = app.menuBars.menuBarItems["Plugins"]
        menu.click()
        let row = menu.menuItems["Blamos — Main sidebar (Unsaved)"]
        XCTAssertTrue(row.waitToExist(timeout: 10), "The unsaved plugin has its own row in the Plugins menu.")
        XCTAssertFalse(menu.menuItems["Edit Blamos…"].exists, "No Edit item sits at the menu's root.")
        XCTAssertFalse(menu.menus.firstMatch.children(matching: .menuItem)["Edit…"].exists, "Edit is only inside a plugin's submenu.")
        XCTAssertTrue(waitForStableFrame(row))
        row.hover()
        let editItem = row.descendants(matching: .menuItem)["Edit…"]
        XCTAssertTrue(waitUntil({ editItem.isHittable }, timeout: 5), "The submenu offers Edit.")
        XCTAssertTrue(row.descendants(matching: .menuItem)["Delete…"].isHittable, "The submenu offers Delete.")
        let menuCapture = XCTAttachment(screenshot: menu.menus.firstMatch.screenshot())
        menuCapture.name = "Plugins menu lists the unsaved plugin"
        menuCapture.lifetime = .keepAlways
        add(menuCapture)
        let submenuCapture = XCTAttachment(screenshot: row.menus.firstMatch.screenshot())
        submenuCapture.name = "Unsaved plugin submenu"
        submenuCapture.lifetime = .keepAlways
        add(submenuCapture)
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        // Closed menu-bar items stay in the accessibility tree, so wait for the menu to stop taking hits instead.
        // The pointer is parked in the editor so it cannot leave a menu bar title tracking.
        element("plugin-creation-preview").hover()
        XCTAssertTrue(waitUntil({ !menu.menus.firstMatch.isHittable && self.app.buttons["Discard changes"].isHittable }, timeout: 5), "The menu closes.")

        // Discarding an unsaved plugin removes its draft and conversation and closes its editor.
        let blamosDraft = drafts.appendingPathComponent(blamosID)
        try FileManager.default.createDirectory(at: blamosDraft, withIntermediateDirectories: true)
        try "draft".write(to: blamosDraft.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blamosDraft.appendingPathComponent("index.js").path))
        app.buttons["Discard changes"].click()
        XCTAssertTrue(app.sheets.staticTexts["Discard plugin?"].waitToExist(timeout: 5))
        XCTAssertTrue(app.sheets.staticTexts["Discard plugin?"].isHittable, "No menu covers the confirmation.")
        XCTAssertTrue(app.sheets.staticTexts["This plugin was never saved. Its draft and this conversation will be deleted."].exists)
        attachAppWindowScreenshot(named: "Discard unsaved plugin confirmation")
        app.sheets.buttons["Discard"].click()
        XCTAssertTrue(waitUntil({ !self.element("plugin-creation-preview").exists }, timeout: 10), "The editor closes.")
        XCTAssertTrue(waitUntil({ (try? sessions())?.contains(blamosID) == false }, timeout: 10), "Its editor conversation is deleted.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: blamosDraft.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pluginsFolder.appendingPathComponent(blamosID).path))
        attachAppWindowScreenshot(named: "Editor closed after discarding")
        menu.click()
        XCTAssertTrue(menu.menuItems["Reload Plugins"].waitToExist(timeout: 10))
        XCTAssertFalse(menu.menuItems["Blamos — Main sidebar (Unsaved)"].exists, "The discarded plugin leaves the menu.")
        app.typeKey(.escape, modifierFlags: [])

        // Delete in an unsaved plugin's submenu removes it the same way.
        let second = try XCTUnwrap((try runCLI(["plugin", "author", "--placement", "mainSidebar", "--name", "Second", "--presentation", "popover"])["result"] as? [String: Any])?["task"] as? [String: Any])
        let secondID = try XCTUnwrap(second["authoredPluginID"] as? String)
        try FileManager.default.createDirectory(at: drafts.appendingPathComponent(secondID), withIntermediateDirectories: true)
        try "draft".write(to: drafts.appendingPathComponent(secondID).appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        clickInstalledPluginAction("Delete…", pluginRow: "Second — Main sidebar (Unsaved)")
        XCTAssertTrue(app.dialogs.staticTexts["It was never saved. Its draft and editor conversation are removed."].waitToExist(timeout: 5))
        app.dialogs.buttons["Delete"].click()
        XCTAssertTrue(waitUntil({ (try? sessions())?.contains(secondID) == false }, timeout: 10))
        XCTAssertFalse(FileManager.default.fileExists(atPath: drafts.appendingPathComponent(secondID).path))
        menu.click()
        XCTAssertTrue(menu.menuItems["Reload Plugins"].waitToExist(timeout: 10))
        XCTAssertFalse(menu.menuItems["Second — Main sidebar (Unsaved)"].exists, "The deleted plugin leaves the menu.")
        app.typeKey(.escape, modifierFlags: [])
    }

    // case-contract: test_plugin_authoring_task_starts_with_placement_and_skill | Plugin authoring starts with centered name and presentation setup, then opens a standalone conversation beside a live preview with an empty composer, guidance to describe the plugin, the chosen name, placement and presentation with a note that the user can ask to change any of them, no repository title, no provider turn, and no board card or task header. The editor header shows “Plugin editor” beside its back button. The user can choose a model and write an unsent description; the Plugins menu reopens the same conversation and preview with its draft and history. Name, presentation, placement and generated plugin identity persist in provider instructions, which let the user change any of those choices, even the name; a changed name, placement and presentation names the unsaved draft's editor and is published under the same plugin ID on save; invalid setup is rejected. Claude and Codex receive the setup and bundled skill without installing files in the user’s home.
    func test_plugin_authoring_task_starts_with_placement_and_skill() throws {
        let environment = try installClaudeFixture(named: "claude-fixture-plugin-author")
        let codexExecutable = dataDirectory.appendingPathComponent("codex-fixture-plugin-author-success")
        try copyFixtureFile(at: WorkspaceFixture.root.appendingPathComponent("codex-fixture-success"), to: codexExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexExecutable.path)
        try Data("Playhouse test owns this Codex protocol fixture (v1).\n".utf8).write(to: dataDirectory.appendingPathComponent(".playhouse-codex-fixture-owner"))
        codexFixtureExecutable = codexExecutable.path
        let codexEnvironment = ["PLAYHOUSE_E2E_CODEX_EXECUTABLE": codexExecutable.path]
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
        let editorTitleCapture = XCTAttachment(screenshot: editorTitle.screenshot())
        editorTitleCapture.name = "Plugin editor title"
        editorTitleCapture.lifetime = .keepAlways
        add(editorTitleCapture)
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
        XCTAssertFalse(element("empty-conversation-repository-title").exists, "The plugin editor has no repository title.")
        XCTAssertEqual(accessibleLabelOrValue(of: element("model-prompt")), "Describe your plugin in the prompt below.")
        XCTAssertEqual(accessibleLabelOrValue(of: element("plugin-detail-name")), "Name: Timer", "The empty state shows the chosen name.")
        XCTAssertEqual(accessibleLabelOrValue(of: element("plugin-detail-placement")), "Placement: Main sidebar", "The empty state shows the chosen placement.")
        XCTAssertEqual(accessibleLabelOrValue(of: element("plugin-detail-presentation")), "Opens as: Modal", "The empty state shows how the plugin opens.")
        XCTAssertTrue(element("plugin-details-change-hint").exists, "The empty state says any detail can change by asking.")
        XCTAssertTrue(accessibleLabelOrValue(of: element("plugin-details-change-hint")).contains("even the name"))
        let pluginDetailsCapture = XCTAttachment(screenshot: element("plugin-details").screenshot())
        pluginDetailsCapture.name = "Plugin editor chosen details"
        pluginDetailsCapture.lifetime = .keepAlways
        add(pluginDetailsCapture)
        XCTAssertTrue((element("message-composer").value as? String ?? "").isEmpty, "The user starts with an empty composer.")
        XCTAssertFalse(element("send-message-button").isEnabled, "Nothing is sent before the user describes the plugin.")
        attachScreenshot(named: "Plugin editor empty state")
        let authoringDraft = "A countdown timer with a start button."
        element("message-composer").click()
        element("message-composer").typeText(authoringDraft)
        XCTAssertTrue(element("send-message-button").isEnabled, "The user can send when ready.")
        let modelPicker = element("model-picker-menu")
        XCTAssertTrue(modelPicker.exists, "The user can choose a model before sending.")
        modelPicker.click()
        let opusOption = app.buttons["model-option-claude-opus-5-5"]
        XCTAssertTrue(opusOption.waitToExist(timeout: 10), "The model picker offers a different Claude model.")
        opusOption.click()
        modelPicker.click() // Dismissing the picker commits the staged selection.
        XCTAssertTrue(waitUntil({ self.element("model-picker-menu").label.contains("Opus 5.5") }, timeout: 5), "The selected model changes before the first turn.")
        XCTAssertEqual(element("message-composer").value as? String, authoringDraft, "Changing models preserves the unsent authoring draft.")
        XCTAssertTrue(turns().isEmpty, "Creating the plugin does not start a provider turn.")
        attachScreenshot(named: "Plugin authoring draft ready to review with selected model")
        element("back-to-board-button").click()
        clickInstalledPluginAction("Edit…", pluginRow: "Timer — Main sidebar (Unsaved)")
        XCTAssertTrue(element("plugin-creation-preview").waitToExist(timeout: 10), "A draft can be reopened before its plugin folder exists.")
        XCTAssertTrue(waitUntil({ (self.element("message-composer").value as? String) == authoringDraft }, timeout: 10), "The user’s authoring draft survives reopening unsent.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ turns().contains { $0["userText"] as? String == authoringDraft } }, timeout: 20), "The user’s description reaches the provider after Send.")
        let firstTurn = try XCTUnwrap(turns().first { $0["userText"] as? String == authoringDraft })
        let arguments = try XCTUnwrap(firstTurn["arguments"] as? [String])
        let instructionsIndex = try XCTUnwrap(arguments.firstIndex(of: "--append-system-prompt"))
        let instructions = arguments[instructionsIndex + 1]
        XCTAssertTrue(instructions.contains("The chosen plugin name is Timer."))
        XCTAssertTrue(instructions.contains("The chosen presentation is modal."))
        XCTAssertTrue(instructions.contains(Self.pluginChangeRule), "The agent may change every setup choice, even the name, on request.")
        XCTAssertTrue(instructions.contains(pluginID))
        XCTAssertGreaterThan(element("message-composer").frame.width, 0)
        XCTAssertGreaterThan(element("plugin-creation-preview").frame.width, 0)
        XCTAssertLessThanOrEqual(element("message-composer").frame.maxX, element("plugin-creation-preview").frame.minX + 2)
        func sendPreviewTurn(_ value: String) throws {
            let payload = try JSONSerialization.data(withJSONObject: ["folder": pluginsFolder.appendingPathComponent(".drafts/plugins").appendingPathComponent(pluginID).path, "text": value])
            let message = "plugin-preview-fixture " + (try XCTUnwrap(String(data: payload, encoding: .utf8)))
            element("message-composer").click()
            element("message-composer").typeKey("a", modifierFlags: .command)
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
        XCTAssertTrue(app.sheets.staticTexts["Your changes are saved as a draft. You can return and continue editing later."].waitToExist(timeout: 5))
        app.sheets.buttons["OK"].click()
        clickInstalledPluginAction("Edit…", pluginRow: "Timer — Main sidebar (Unsaved)")
        XCTAssertTrue(element("plugin-creation-preview").waitToExist(timeout: 10))
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("plugin-creation-preview").descendants(matching: .any)["preview-content"]) == "Updated preview" }, timeout: 10))
        XCTAssertTrue(waitUntil({ (self.element("message-composer").value as? String ?? "").contains("A saved draft") }, timeout: 10))
        XCTAssertTrue(app.staticTexts["Plugin preview updated: Updated preview"].waitToExist(timeout: 10))
        attachScreenshot(named: "Reopened plugin editor")
        _ = try runCLI(["settings", "set-parent", fixture.parent.path])

        // The same setup opens from a conversation's composer.
        element("back-to-board-button").click()
        if app.sheets.buttons["OK"].waitToExist(timeout: 2) { app.sheets.buttons["OK"].click() }
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
        _ = try runCLI(["plugin", "discard", "--id", composerPluginID])
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

        // Every setup choice can change later, even the name: the draft's manifest names its editor and wins on save.
        element("back-to-board-button").click()
        let renamedAuthor = try runCLI(["plugin", "author", "--placement", "mainSidebar", "--name", "Countdown", "--presentation", "modal"])
        let renamedPluginID = try XCTUnwrap(((renamedAuthor["result"] as? [String: Any])?["task"] as? [String: Any])?["authoredPluginID"] as? String)
        let renamedDraft = pluginsFolder.appendingPathComponent(".drafts/plugins").appendingPathComponent(renamedPluginID)
        try FileManager.default.createDirectory(at: renamedDraft, withIntermediateDirectories: true)
        let renamedManifest: [String: Any] = ["id": renamedPluginID, "name": "Stopwatch", "icon": "stopwatch", "placement": "conversationToolbar", "presentation": "sidebar"]
        try JSONSerialization.data(withJSONObject: renamedManifest).write(to: renamedDraft.appendingPathComponent("plugin.json"))
        try Self.pluginContextSource.write(to: renamedDraft.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        _ = try runCLI(["plugin", "refresh"])
        let pluginsMenu = app.menuBars.menuBarItems["Plugins"]
        XCTAssertTrue(waitUntil({
            pluginsMenu.click()
            let found = pluginsMenu.menuItems["Stopwatch — Conversation sidebar toolbar (Unsaved)"].exists
            if found { self.attachMenuScreenshot(pluginsMenu, named: "Renamed unsaved plugin draft in Plugins menu") }
            self.app.typeKey(.escape, modifierFlags: [])
            return found
        }, timeout: 15), "An unsaved draft's editor is listed under the name the agent changed it to.")
        _ = try runCLI(["plugin", "save", "--id", renamedPluginID])
        XCTAssertTrue(waitUntil({
            pluginsMenu.click()
            let found = pluginsMenu.menuItems["Stopwatch — Conversation sidebar toolbar"].exists
            if found { self.attachMenuScreenshot(pluginsMenu, named: "Renamed plugin published with its new placement") }
            self.app.typeKey(.escape, modifierFlags: [])
            return found
        }, timeout: 15), "Saving publishes the changed name and placement.")
        let publishedPlugins = try XCTUnwrap((try runCLI(["plugin", "list"])["result"] as? [String: Any])?["plugins"] as? [[String: Any]])
        let published = try XCTUnwrap(publishedPlugins.first { $0["id"] as? String == renamedPluginID })
        XCTAssertEqual(published["presentation"] as? String, "sidebar", "Saving publishes the changed presentation.")

        // Editing an installed plugin creates its first editor session.
        try writeInstalledPlugin("installed-editor", source: Self.pluginContextSource, placement: "mainSidebar", name: "Installed editor")
        _ = try runCLI(["plugin", "refresh"])
        clickInstalledPluginAction("Edit…", pluginRow: "Installed editor — Main sidebar")
        XCTAssertTrue(element("plugin-creation-preview").waitToExist(timeout: 10))
        XCTAssertTrue(try sessions().contains { $0["authoredPluginID"] as? String == "installed-editor" })
        element("back-to-board-button").click()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: pluginsFolder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: pluginsFolder.path) }
        clickInstalledPluginAction("Delete…", pluginRow: "Installed editor — Main sidebar")
        XCTAssertTrue(app.dialogs.buttons["Delete"].waitToExist(timeout: 5))
        app.dialogs.buttons["Delete"].click()
        XCTAssertTrue(app.dialogs.buttons["OK"].waitToExist(timeout: 10), "A failed folder removal reports an error.")
        app.dialogs.buttons["OK"].click()
        XCTAssertTrue(try sessions().contains { $0["authoredPluginID"] as? String == "installed-editor" })
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: pluginsFolder.path)
        clickInstalledPluginAction("Delete…", pluginRow: "Installed editor — Main sidebar")
        app.dialogs.buttons["Delete"].click()
        XCTAssertTrue(waitUntil({ (try? sessions().contains { $0["authoredPluginID"] as? String == "installed-editor" }) == false }, timeout: 10))

        // A migrated Codex editor resumes its original thread with the isolated draft path.
        let codexTaskResult = try runCLI(["task", "create", "--title", "New plugin: Codex legacy", "--prompt", "Legacy description", "--provider", "codex"])
        let codexTask = try XCTUnwrap(codexTaskResult["result"] as? [String: Any])
        let codexID = try XCTUnwrap(codexTask["id"] as? String)
        _ = try runCLI(["conversation", "send", codexID, "--message", "Before migration"], extraEnvironment: codexEnvironment)
        try writeInstalledPlugin("legacy-codex", source: Self.pluginContextSource, placement: "mainSidebar", name: "Codex legacy")
        try seedLegacyPluginTask(taskID: codexID, pluginID: "legacy-codex")
        _ = try runCLI(["plugin", "refresh"])
        clickInstalledPluginAction("Edit…", pluginRow: "Codex legacy — Main sidebar")
        XCTAssertTrue(element("plugin-creation-preview").waitToExist(timeout: 10))
        let stopCodex = Process()
        stopCodex.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        stopCodex.arguments = ["-f", codexExecutable.path]
        try stopCodex.run()
        stopCodex.waitUntilExit()
        _ = try runCLI(["conversation", "send", codexID, "--message", "After migration"], extraEnvironment: codexEnvironment)
        let codexHistory = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: codexExecutable.path + ".history"))) as? [String: Any])
        let resumedInstructions = try XCTUnwrap((codexHistory["threadResumeDeveloperInstructions"] as? [String])?.last)
        XCTAssertTrue(resumedInstructions.contains(pluginsFolder.appendingPathComponent(".drafts/plugins").path))
        XCTAssertTrue(resumedInstructions.contains("legacy-codex"))
        XCTAssertTrue(element("plugin-creation-preview").exists)
        attachScreenshot(named: "Migrated Codex plugin editor")
        element("back-to-board-button").click()

        // A pre-existing task-backed editor keeps its session, draft and preview when migrated.
        let legacyResponse = try runCLI(["task", "create", "--title", "New plugin: Legacy editor", "--prompt", "Legacy description", "--provider", "claude"])
        let legacy = try XCTUnwrap(legacyResponse["result"] as? [String: Any])
        let legacyID = try XCTUnwrap(legacy["id"] as? String)
        _ = try runCLI(["conversation", "send", legacyID, "--message", "Remember this legacy conversation"], extraEnvironment: environment)
        _ = try runCLI(["task", "draft", legacyID, "--text", "Legacy unsent draft"])
        try writeInstalledPlugin("legacy-editor", source: Self.pluginContextSource, placement: "mainSidebar", name: "Legacy editor")
        try seedLegacyPluginTask(taskID: legacyID, pluginID: "legacy-editor")
        _ = try runCLI(["plugin", "refresh"])
        clickInstalledPluginAction("Edit…", pluginRow: "Legacy editor — Main sidebar")
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
        clickInstalledPluginAction("Delete…", pluginRow: "Delete legacy — Main sidebar")
        app.dialogs.buttons["Delete"].click()
        XCTAssertTrue(waitUntil({ (try? self.boardTaskRecords().contains { $0["id"] as? String == legacyDeleteID }) == false }, timeout: 10))

    }
    /// Menus dropped from the menu bar are outside the window crop of `attachScreenshot(named:)`.
    func attachMenuScreenshot(_ menuBarItem: XCUIElement, named name: String) {
        let capture = XCTAttachment(screenshot: menuBarItem.menus.firstMatch.screenshot())
        capture.name = name
        capture.lifetime = .keepAlways
        add(capture)
    }

    /// `TaskThreadDeveloperInstructions.pluginChangeRule`: the editor's setup choices are a starting point.
    static let pluginChangeRule = "When the user asks to change the plugin's name, icon, placement or presentation, update plugin.json to match and keep the plugin ID and folder"

    // case-contract: test_plugin_authoring_codex_instructions_resume | A Codex plugin editor sends the user’s description with the chosen name, presentation, placement, generated plugin identity and permission to change any of those choices in thread instructions, automatically supplies the bundled plugin skill, and restores the same setup when the thread resumes on a fresh app-server. The composer starts empty and no turn starts until the user sends.
    func test_plugin_authoring_codex_instructions_resume() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: true).path
        let historyURL = URL(fileURLWithPath: try XCTUnwrap(codexFixtureExecutable) + ".history")
        let daemonEnvironment = ["PLAYHOUSE_BRIDGE_SERVICE_NAME": "\(serviceName!).plugin-codex-\(UUID().uuidString.prefix(8))"]
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: daemonEnvironment)
        let created = try runCLI(["plugin", "author", "--placement", "mainSidebar", "--name", "Codex timer", "--presentation", "modal", "--provider", "codex"], extraEnvironment: daemonEnvironment)
        let task = try XCTUnwrap((created["result"] as? [String: Any])?["task"] as? [String: Any])
        let pluginID = try XCTUnwrap(task["authoredPluginID"] as? String)
        func history() -> [String: Any] {
            guard let data = try? Data(contentsOf: historyURL) else { return [:] }
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        clickInstalledPluginAction("Edit…", pluginRow: "Codex timer — Main sidebar (Unsaved)")
        XCTAssertTrue(element("plugin-creation-preview").waitToExist(timeout: 10))
        let composer = element("message-composer")
        XCTAssertTrue((composer.value as? String ?? "").isEmpty)
        XCTAssertTrue(history().isEmpty, "Creating the editor starts no provider turn.")
        composer.click()
        composer.typeText("Build a countdown timer.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ history()["userMessage"] as? String == "Build a countdown timer." }, timeout: 20))
        let instructions = try XCTUnwrap(history()["threadStartDeveloperInstructions"] as? String)
        XCTAssertTrue(instructions.contains("plugin render"), "Codex validates the persistent draft without publishing it.")
        for text in ["The chosen plugin name is Codex timer.", "The chosen presentation is modal.", "Main sidebar placement (`mainSidebar`)", Self.pluginChangeRule, pluginID] {
            XCTAssertTrue(instructions.contains(text), "Codex receives \(text) in thread instructions.")
        }
        let turns = try XCTUnwrap(history()["turns"] as? [[String: Any]])
        let first = try XCTUnwrap(turns.first { $0["userMessage"] as? String == "Build a countdown timer." })
        let skills = try XCTUnwrap(first["skillInputs"] as? [[String: Any]])
        XCTAssertTrue(skills.contains { $0["name"] as? String == "playhouse-plugin" })
        XCTAssertTrue(waitUntil({
            guard let result = try? self.runCLI(["plugin", "edit", "--id", pluginID], extraEnvironment: daemonEnvironment),
                  let payload = result["result"] as? [String: Any],
                  let task = payload["task"] as? [String: Any],
                  let status = task["status"] as? String else { return false }
            return status != "In Progress"
        }, timeout: 30), "The first turn settles before resuming.")
        let daemonPID = try XCTUnwrap((try runCLI(["status"], extraEnvironment: daemonEnvironment)["result"] as? [String: Any])?["processID"] as? Int)
        XCTAssertEqual(kill(pid_t(daemonPID), SIGKILL), 0)
        XCTAssertTrue(waitUntil({ kill(pid_t(daemonPID), 0) != 0 }, timeout: 10))
        composer.click()
        composer.typeText("Make it blue.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ history()["userMessage"] as? String == "Make it blue." }, timeout: 20))
        let resumed = try XCTUnwrap((history()["threadResumeDeveloperInstructions"] as? [String])?.last)
        for text in ["The chosen plugin name is Codex timer.", "The chosen presentation is modal.", "Main sidebar placement (`mainSidebar`)", Self.pluginChangeRule, pluginID] {
            XCTAssertTrue(resumed.contains(text), "Resumed Codex instructions retain \(text).")
        }
    }

    // case-contract: test_plugin_editor_reattaches_after_daemon_restart | A plugin editor follows a running Claude turn after a daemon restart, restores its answer once alongside the preview, and settles without a task outcome nudge. Claude represents the shared reattachment settlement used by both providers.
    func test_plugin_editor_reattaches_after_daemon_restart() throws {
        let environment = try installClaudeFixture(named: "claude-fixture-reattach-plugin")
        let executable = try XCTUnwrap(environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"])
        launchApp(defaultParent: fixture.parent.path)
        _ = try runCLI(["settings", "set-default-provider", "claude"])
        _ = try runCLI(["plugin", "author", "--placement", "mainSidebar", "--name", "Restart plugin", "--presentation", "modal", "--provider", "claude"], extraEnvironment: environment)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pluginsFolder.appendingPathComponent(".drafts/plugins").path), "The working folder exists before reopening the editor or sending.")
        let menu = app.menuBars.menuBarItems["Plugins"]
        XCTAssertTrue(waitUntil({ menu.click(); let found = menu.menuItems["Restart plugin — Main sidebar (Unsaved)"].exists; self.app.typeKey(.escape, modifierFlags: []); return found }, timeout: 15))
        clickInstalledPluginAction("Edit…", pluginRow: "Restart plugin — Main sidebar (Unsaved)")
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
    // case-contract: test_plugin_enable_disable_and_builtins | `plugin list` reports the built-in Changes plugin first (builtIn, valid and enabled, at the conversation sidebar with the inline presentation), then the task card's built-in Pull request mode and Pull requests plugins (inline at the taskItem placement), the board sidebar's built-in Agents info (a section at the mainSidebarBottom placement) and its built-in Scheduled Tasks (a popover at the mainSidebar placement), and the composer's built-in Built-in Commands (headless at the composerActions placement, with its / commands), before the installed plugins. A built-in can't be deleted, edited or rendered headlessly (invalid_argument), and an installed folder with a built-in's id is invalid. An inline plugin is valid only at the conversation sidebar or on the task card. `plugin disable --id` and `plugin enable --id` work on built-in and installed plugins, bump the plugins revision and persist across fresh CLI reads. A `plugin refresh` with nothing changed still bumps the revision and lists identical plugins, and in the window it leaves an open plugin submenu open. A disabled plugin is listed with enabled false, is not run when plugins are refreshed, and `plugin render` refuses it as unavailable until it is enabled again. An unknown id is not_found, a malformed or missing one invalid_argument, and a deleted plugin installed again starts enabled with no saved state. An inline conversation sidebar plugin receives `workspace` (its revision and the open diff) and `sidebar` (whether it is on the rail) props, and its Playhouse.ui.refreshWorkspace and openDiff calls are recorded headlessly, while the board's sidebar refuses them as unavailable. In the window, the Plugins menu has a Built-in Plugins section whose Changes submenu offers Disable but no Edit or Delete, and which labels Built-in Commands Headless (slash commands only), its submenu also offering Disable but no Edit or Delete. Disabling Changes removes the task sidebar's Changes section and labels it Disabled, and enabling it brings the section back. An installed plugin's submenu offers Disable beside Edit and Delete, and disabling it removes its button until it is enabled again. An installed inline plugin renders in place in the task sidebar with no entry button: its refreshWorkspace raises the workspace revision, its openDiff opens the window's diff view for a real change and the open diff reaches its props, and on the hidden sidebar's rail it reads that it is on the rail. Each plugin keeps its own saved values: `plugin state --id` reads them and `plugin state --id --key --value <json>` stores one (null removes it) and bumps the plugins revision; `plugin list` reports each plugin's `state`, which an installed plugin gets as `props.state` and stores with Playhouse.setState (recorded headlessly), and the built-in Changes keeps its state the same way. An unknown id is not_found, and an empty key, a missing value or a value that is not JSON is invalid_argument without bumping the revision. A fresh daemon reads the disabled ids and saved states back from settings, and authoring an inline plugin outside the conversation sidebar or the task card is invalid_argument. In the window, the inline plugin's Playhouse.setState comes back as its props.state, and collapsing the Changes section saves its collapsed state as its plugin state. After a relaunch a disabled Changes stays hidden and labeled Disabled while the plugin keeps its saved state, and enabled again, Changes comes back collapsed. An open page plugin receives its newly saved state, and disabling a plugin closes its open surface.
    func test_plugin_enable_disable_and_builtins() throws {
        func listed() throws -> [String: [String: Any]] {
            let plugins = try XCTUnwrap((try runCLI(["plugin", "list"])["result"] as? [String: Any])?["plugins"] as? [[String: Any]])
            return Dictionary(plugins.compactMap { plugin in (plugin["id"] as? String).map { ($0, plugin) } }, uniquingKeysWith: { first, _ in first })
        }
        let initial = try XCTUnwrap((try runCLI(["plugin", "list"])["result"] as? [String: Any])?["plugins"] as? [[String: Any]])
        XCTAssertEqual(initial.map { $0["id"] as? String }, ["changes", "pull-request-mode", "pull-requests", "agents-info", "scheduled-tasks", "built-in-commands"], "Only the built-ins are listed before any plugin is installed.")
        // The board sidebar's Scheduled Tasks popover.
        XCTAssertEqual(initial[4]["name"] as? String, "Scheduled Tasks")
        XCTAssertEqual(initial[4]["placement"] as? String, "mainSidebar")
        XCTAssertEqual(initial[4]["presentation"] as? String, "popover")
        XCTAssertEqual(initial[4]["builtIn"] as? Bool, true)
        // The board sidebar's built-in: Agents info, a section at its bottom.
        XCTAssertEqual(initial[3]["placement"] as? String, "mainSidebarBottom")
        XCTAssertEqual(initial[3]["presentation"] as? String, "section")
        XCTAssertEqual(initial[3]["builtIn"] as? Bool, true)
        // The task card's built-ins: the mode pill and the pull request controls.
        for cardPlugin in initial[1..<3] {
            XCTAssertEqual(cardPlugin["placement"] as? String, "taskItem", "\(cardPlugin)")
            XCTAssertEqual(cardPlugin["presentation"] as? String, "inline", "\(cardPlugin)")
            XCTAssertEqual(cardPlugin["builtIn"] as? Bool, true, "\(cardPlugin)")
            XCTAssertEqual(cardPlugin["valid"] as? Bool, true, "\(cardPlugin)")
        }
        let changes = try XCTUnwrap(initial.first)
        XCTAssertEqual(changes["builtIn"] as? Bool, true)
        XCTAssertEqual(changes["enabled"] as? Bool, true)
        XCTAssertEqual(changes["valid"] as? Bool, true)
        XCTAssertEqual(changes["placement"] as? String, "conversationSidebar")
        XCTAssertEqual(changes["presentation"] as? String, "inline")

        // A task whose root has one real change.
        let repository = runDirectory.appendingPathComponent("inline-plugin-changes", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try "Baseline.\n".write(to: repository.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try runGit(repository, "init", "--initial-branch=main")
        try runGit(repository, "config", "user.name", "Playhouse UI Test")
        try runGit(repository, "config", "user.email", "playhouse-ui-test@example.invalid")
        try runGit(repository, "add", "notes.txt")
        try runGit(repository, "commit", "-m", "Baseline")
        try "Edited by the fixture.\n".write(to: repository.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        _ = try runCLI(["task", "create", "--title", "Inline plugin task", "--prompt", "Fixture task description.", "--root", repository.path])

        let hello = #"Playhouse.render(h(Text, { testID: "hello" }, "Hello"));"#
        let savedPage = #"function Saved() { var props = Playhouse.useProps(); return h(Text, { testID: "page-state" }, "page saved " + ((props.state || {}).clicks || 0)); } Playhouse.render(h(Saved));"#
        try writeInstalledPlugin("hello-board", source: savedPage, placement: "mainSidebar", presentation: "page", name: "Hello Board", icon: "hand.wave")
        try writeInstalledPlugin("workspace-probe", source: Self.pluginWorkspaceSource, placement: "conversationSidebar", presentation: "inline", name: "Workspace Probe", icon: "eye")
        try writeInstalledPlugin("inline-composer", source: hello, placement: "composerActions", presentation: "inline")
        try writeInstalledPlugin("card-badge", source: hello, placement: "taskItem", presentation: "inline")
        launchApp(defaultParent: fixture.parent.path)
        let refreshed = try listedAfterRefresh()
        XCTAssertEqual(refreshed["workspace-probe"]?["valid"] as? Bool, true, "\(refreshed)")
        XCTAssertEqual(refreshed["card-badge"]?["valid"] as? Bool, true, "An inline plugin is valid on the task card too.")
        XCTAssertEqual(refreshed["inline-composer"]?["valid"] as? Bool, false, "An inline plugin is valid only at the conversation sidebar.")
        XCTAssertTrue((refreshed["inline-composer"]?["errors"] as? [String] ?? []).contains { $0.contains("only in the conversation sidebar") })

        // An installed inline plugin renders in place beside the built-in Changes section.
        openTask(named: "Inline plugin task")
        XCTAssertTrue(element("workspace-changes-title").waitToExist(timeout: 10), "The built-in Changes section shows.")
        XCTAssertTrue(element("workspace-change-unviewed-notes.txt").waitToExist(timeout: 10))
        let probe = element("plugin-surface-workspace-probe")
        XCTAssertTrue(probe.waitToExist(timeout: 10), "The inline plugin renders as a section of the task sidebar.")
        XCTAssertFalse(element("plugin-entry-workspace-probe").exists, "An inline plugin has no entry button.")
        XCTAssertFalse(probe.descendants(matching: .any)["plugin-surface-title"].exists, "An inline plugin has no surface header.")
        XCTAssertEqual(pluginText(element("probe-rail")), "expanded")
        XCTAssertEqual(pluginText(element("probe-open")), "no diff")
        let revisionText = pluginText(element("probe-revision"))
        let startRevision = try XCTUnwrap(Int(revisionText.replacingOccurrences(of: "revision ", with: "")), revisionText)
        element("probe-refresh").click()
        XCTAssertTrue(waitUntil({ self.pluginText(self.element("probe-status")) == "refresh: ok" }, timeout: 10))
        XCTAssertTrue(waitUntil({ (Int(self.pluginText(self.element("probe-revision")).replacingOccurrences(of: "revision ", with: "")) ?? 0) > startRevision }, timeout: 10),
                      "refreshWorkspace raises the workspace revision: \(pluginText(element("probe-revision")))")
        attachScreenshot(named: "An installed inline plugin below the built-in Changes section")
        // A plugin's saved values come back as props.state.
        assertText("probe-state", equals: "saved 0")
        element("probe-save").click()
        XCTAssertTrue(waitUntil({ self.pluginText(self.element("probe-state")) == "saved 1" }, timeout: 10), "Playhouse.setState comes back as props.state.")
        XCTAssertEqual(pluginText(element("probe-status")), "save: ok")
        let probeState = try XCTUnwrap(try runCLI(["plugin", "state", "--id", "workspace-probe"])["result"] as? [String: Any])
        XCTAssertEqual(probeState["state"] as? [String: Int], ["clicks": 1], "The saved state is stored.")
        XCTAssertEqual(probeState["enabled"] as? Bool, true, "Reading a plugin's state also says whether it is enabled.")
        // Changes keeps whether its section is collapsed in its plugin state.
        assertText("toggle-workspace-changes-section-button", equals: "Expanded")
        element("toggle-workspace-changes-section-button").click()
        XCTAssertTrue(element("workspace-change-unviewed-notes.txt").waitForNonExistence(timeout: 5), "Collapsing Changes hides its list.")
        XCTAssertTrue(waitUntil({ ((try? listed())?["changes"]?["state"] as? [String: Bool]) == ["collapsed": true] }, timeout: 10),
                      "Changes saves its collapsed state as its plugin state.")
        element("probe-open-diff").click()
        XCTAssertTrue(element("workspace-diff-overlay").waitToExist(timeout: 10), "openDiff opens the window's diff view.")
        assertText("workspace-diff-title", equals: "notes.txt")
        XCTAssertTrue(waitUntil({ self.pluginText(self.element("probe-open")) == "open notes.txt" }, timeout: 10), "The open diff reaches the plugin's props.")
        XCTAssertEqual(pluginText(element("probe-status")), "openDiff: ok")
        attachScreenshot(named: "An inline plugin's openDiff opens the diff view")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(element("workspace-diff-overlay").waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitUntil({ self.pluginText(self.element("probe-open")) == "no diff" }, timeout: 10))
        element("hide-task-sidebar-button").click()
        XCTAssertTrue(element("task-sidebar-collapsed").waitToExist(timeout: 5))
        XCTAssertTrue(waitUntil({ self.pluginText(self.element("probe-rail")) == "rail" }, timeout: 10), "On the hidden sidebar's rail the plugin reads that it is on the rail.")
        element("show-task-sidebar-button").click()
        XCTAssertTrue(element("workspace-changes-title").waitToExist(timeout: 10))
        assertText("toggle-workspace-changes-section-button", equals: "Collapsed")
        element("toggle-workspace-changes-section-button").click()
        XCTAssertTrue(element("workspace-change-unviewed-notes.txt").waitToExist(timeout: 10), "Expanding Changes shows its list again.")

        // The Plugins menu: a built-in offers only Disable.
        let menu = app.menuBars.menuBarItems["Plugins"]
        menu.click()
        XCTAssertTrue(menu.menuItems["Built-in Plugins"].waitToExist(timeout: 5), "The Plugins menu has a Built-in Plugins section.")
        // A headless built-in has no placement surface: its row says so.
        let commandsRow = menu.menuItems["Built-in Commands — Headless (slash commands only)"]
        XCTAssertTrue(commandsRow.waitToExist(timeout: 5), "The Built-in Commands plugin is labeled headless.")
        XCTAssertTrue(waitForStableFrame(commandsRow))
        commandsRow.hover()
        XCTAssertTrue(waitUntil({ commandsRow.descendants(matching: .menuItem)["Disable"].isHittable }, timeout: 5), "Its submenu offers Disable.")
        XCTAssertFalse(commandsRow.descendants(matching: .menuItem)["Delete…"].exists, "A built-in can't be deleted.")
        XCTAssertFalse(commandsRow.descendants(matching: .menuItem)["Edit…"].exists, "A built-in can't be edited.")
        attachMenuScreenshot(menu, named: "The Plugins menu labels Built-in Commands headless")
        let changesRow = menu.menuItems["Changes — Conversation sidebar"]
        XCTAssertTrue(changesRow.waitToExist(timeout: 5))
        XCTAssertTrue(waitForStableFrame(changesRow))
        changesRow.hover()
        let disableChanges = changesRow.descendants(matching: .menuItem)["Disable"]
        XCTAssertTrue(waitUntil({ disableChanges.isHittable }, timeout: 5), "A built-in's submenu offers Disable.")
        XCTAssertFalse(changesRow.descendants(matching: .menuItem)["Delete…"].exists, "A built-in can't be deleted.")
        XCTAssertFalse(changesRow.descendants(matching: .menuItem)["Edit…"].exists, "A built-in can't be edited.")
        attachScreenshot(named: "The Built-in Plugins section offers Disable for Changes")
        disableChanges.click()
        XCTAssertTrue(waitForDisappearance(element("workspace-changes-title"), timeout: 10), "Disabling Changes removes its section.")
        XCTAssertTrue(probe.exists, "Other inline plugins stay.")
        XCTAssertEqual(try listed()["changes"]?["enabled"] as? Bool, false, "The disabled state is stored.")
        menu.click()
        XCTAssertTrue(menu.menuItems["Changes — Conversation sidebar (Disabled)"].waitToExist(timeout: 5), "The menu labels a disabled plugin.")
        attachScreenshot(named: "A disabled built-in is labeled in the Plugins menu and its section is gone")
        app.typeKey(.escape, modifierFlags: [])
        clickInstalledPluginAction("Enable", pluginRow: "Changes — Conversation sidebar (Disabled)")
        XCTAssertTrue(element("workspace-changes-title").waitToExist(timeout: 10), "Enabling Changes brings its section back.")
        XCTAssertTrue(element("workspace-change-unviewed-notes.txt").waitToExist(timeout: 10))
        XCTAssertEqual(try listed()["changes"]?["enabled"] as? Bool, true)

        // An installed plugin offers Disable beside Edit and Delete.
        openTask(named: "Inline plugin task")
        clickInstalledPluginAction("Disable", pluginRow: "Workspace Probe — Conversation sidebar")
        XCTAssertTrue(waitForDisappearance(probe, timeout: 10), "Disabling an installed inline plugin removes its section.")
        XCTAssertTrue(element("workspace-changes-title").exists)
        menu.click()
        let probeRow = menu.menuItems["Workspace Probe — Conversation sidebar (Disabled)"]
        XCTAssertTrue(probeRow.waitToExist(timeout: 5))
        XCTAssertTrue(waitForStableFrame(probeRow))
        probeRow.hover()
        let enableProbe = probeRow.descendants(matching: .menuItem)["Enable"]
        XCTAssertTrue(waitUntil({ enableProbe.isHittable }, timeout: 5))
        XCTAssertTrue(probeRow.descendants(matching: .menuItem)["Edit…"].exists, "An installed plugin keeps Edit.")
        XCTAssertTrue(probeRow.descendants(matching: .menuItem)["Delete…"].exists, "An installed plugin keeps Delete.")
        // A refresh with nothing changed bumps the revision, and the window's reload finds the same
        // plugins: the open submenu stays open instead of being rebuilt shut.
        _ = try runCLI(["plugin", "refresh"])
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertTrue(enableProbe.isHittable, "An unchanged plugin refresh leaves the open submenu open.")
        attachScreenshot(named: "A disabled installed plugin offers Enable beside Edit and Delete")
        // A submenu held open across the screenshot can drop the click; choose Enable from a freshly opened menu.
        menu.click()
        clickInstalledPluginAction("Enable", pluginRow: "Workspace Probe — Conversation sidebar (Disabled)")
        XCTAssertTrue(probe.waitToExist(timeout: 10), "Enabling restores the inline plugin.")

        // Disabled plugins and plugin states persist across a relaunch.
        _ = try runCLI(["plugin", "state", "--id", "changes", "--key", "collapsed", "--value", "true"])
        clickInstalledPluginAction("Disable", pluginRow: "Changes — Conversation sidebar")
        XCTAssertTrue(waitForDisappearance(element("workspace-changes-title"), timeout: 10))
        relaunchApp()
        openTask(named: "Inline plugin task")
        XCTAssertTrue(probe.waitToExist(timeout: 10))
        XCTAssertTrue(waitUntil({ self.pluginText(self.element("probe-state")) == "saved 1" }, timeout: 10), "A plugin's saved state survives a relaunch.")
        XCTAssertFalse(element("workspace-changes-title").exists, "A disabled built-in stays hidden after a relaunch.")
        menu.click()
        XCTAssertTrue(menu.menuItems["Changes — Conversation sidebar (Disabled)"].waitToExist(timeout: 5), "The menu still labels it Disabled after a relaunch.")
        attachScreenshot(named: "After a relaunch Changes stays disabled and the plugin keeps its saved state")
        app.typeKey(.escape, modifierFlags: [])
        clickInstalledPluginAction("Enable", pluginRow: "Changes — Conversation sidebar (Disabled)")
        XCTAssertTrue(element("workspace-changes-title").waitToExist(timeout: 10))
        assertText("toggle-workspace-changes-section-button", equals: "Collapsed")
        XCTAssertFalse(element("workspace-change-unviewed-notes.txt").exists, "Changes comes back collapsed, as its state saved.")
        assertText("collapsed-workspace-changes-section-count", equals: "Changes to review: 1")
        attachScreenshot(named: "Enabled again after a relaunch, Changes comes back collapsed")
        element("toggle-workspace-changes-section-button").click()
        XCTAssertTrue(element("workspace-change-unviewed-notes.txt").waitToExist(timeout: 10))

        element("back-to-board-button").click()
        let boardEntry = element("plugin-entry-hello-board")
        XCTAssertTrue(boardEntry.waitToExist(timeout: 10))
        // An open surface closes when its plugin is disabled.
        boardEntry.click()
        let boardSurface = element("plugin-surface-hello-board")
        XCTAssertTrue(boardSurface.waitToExist(timeout: 10), "The plugin's page opens.")
        assertText("page-state", equals: "page saved 0")
        _ = try runCLI(["plugin", "state", "--id", "hello-board", "--key", "clicks", "--value", "2"])
        XCTAssertTrue(waitUntil({ self.pluginText(self.element("page-state")) == "page saved 2" }, timeout: 10), "An open page receives its newly saved state.")
        XCTAssertTrue(boardSurface.exists, "Saving state keeps the page open.")
        _ = try runCLI(["plugin", "disable", "--id", "hello-board"])
        XCTAssertTrue(waitForDisappearance(boardSurface, timeout: 10), "Disabling a plugin closes its open surface.")
        XCTAssertTrue(waitForDisappearance(boardEntry, timeout: 10), "A plugin disabled through the CLI loses its button.")
        _ = try runCLI(["plugin", "enable", "--id", "hello-board"])
        XCTAssertTrue(boardEntry.waitToExist(timeout: 10), "Enabling it through the CLI restores its button.")

        assertCLIError(try runCLI(["plugin", "delete", "--id", "changes"], expectedStatus: 2), code: "invalid_argument")
        assertCLIError(try runCLI(["plugin", "edit", "--id", "changes"], expectedStatus: 2), code: "invalid_argument")
        assertCLIError(try runCLI(["plugin", "render", "--plugin", "changes"], expectedStatus: 2), code: "invalid_argument")
        _ = try runCLI(["plugin", "disable", "--id", "workspace-probe"])
        assertCLIError(try runCLI(["plugin", "render", "--plugin", "workspace-probe"], expectedStatus: 1), code: "unavailable")
        assertCLIError(try runCLI(["plugin", "disable", "--id", "no-such-plugin"], expectedStatus: 3), code: "not_found")
        assertCLIError(try runCLI(["plugin", "enable", "--id", "../plugins"], expectedStatus: 2), code: "invalid_argument")
        assertCLIError(try runCLI(["plugin", "state", "--id", "no-such-plugin"], expectedStatus: 3), code: "not_found")
        assertCLIError(try runCLI(["plugin", "state", "--id", "workspace-probe", "--key", " ", "--value", "1"], expectedStatus: 2), code: "invalid_argument")
        assertCLIError(try runCLI(["plugin", "author", "--placement", "composerActions", "--name", "Inline", "--presentation", "inline"], expectedStatus: 2), code: "invalid_argument")
        _ = try runCLI(["plugin", "delete", "--id", "workspace-probe"])
        try writeInstalledPlugin("workspace-probe", source: Self.pluginWorkspaceSource, placement: "conversationSidebar", presentation: "inline", name: "Workspace Probe", icon: "eye")
        let reinstalled = try XCTUnwrap(try listedAfterRefresh()["workspace-probe"])
        XCTAssertEqual(reinstalled["enabled"] as? Bool, true, "A deleted plugin installed again starts enabled.")
        XCTAssertEqual((reinstalled["state"] as? [String: Any])?.isEmpty, true, "A deleted plugin installed again has no saved state.")
    }
    /// `plugin refresh`'s plugins by id.
    private func listedAfterRefresh() throws -> [String: [String: Any]] {
        let plugins = try XCTUnwrap((try runCLI(["plugin", "refresh"])["result"] as? [String: Any])?["plugins"] as? [[String: Any]])
        return Dictionary(plugins.compactMap { plugin in (plugin["id"] as? String).map { ($0, plugin) } }, uniquingKeysWith: { first, _ in first })
    }
    // case-contract: test_plugin_install_refresh_and_delete | Each plugin is a folder in the data directory's plugins folder holding plugin.json (id, name, icon, placement, presentation) and its script. `plugin list` reports only the built-in plugins at first; after plugins are written, `plugin refresh` validates every folder, bumps the plugins revision, and reports the valid plugin beside invalid ones with their errors (an unknown placement or presentation, a manifest id that does not match its folder, a missing manifest or script, and a script that throws or uses an unknown atom when rendered once with sample context), which a fresh `plugin list` reports the same way without bumping the revision. The CLI reports each plugin's name, icon, placement, validity and first validation errors, and deleting through `plugin delete --id` removes only that plugin's folder. In the window, each plugin has its own submenu labeled with its placement, containing Edit, Delete and a disabled Settings placeholder; an invalid plugin's first error is inside its submenu. The Plugins menu visibly lists each plugin with a submenu indicator and opens a submenu with Edit, Delete and disabled Settings actions; an invalid plugin's first error is visible in its submenu. After a refresh the window shows the valid plugin's button at its placement. Deleting a plugin from its submenu after confirming, or with `plugin delete --id`, removes its folder, its button and its menu entry; an unknown id is not_found and an id that is not a plugin folder name is invalid_argument.
    func test_plugin_install_refresh_and_delete() throws {
        launchApp(defaultParent: fixture.parent.path)
        XCTAssertTrue(element("plugin-entry-scheduled-tasks").waitToExist(timeout: 15))
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
        XCTAssertGreaterThanOrEqual(entry.frame.minY, element("plugin-entry-scheduled-tasks").frame.maxY - 1, "Its button sits below Scheduled Tasks.")
        XCTAssertFalse(element("plugin-entry-throws").exists, "An invalid plugin shows no button.")
        attachScreenshot(named: "An installed plugin's button in the board's sidebar")

        let menu = app.menuBars.menuBarItems["Plugins"]
        menu.click()
        let helloItem = menu.menuItems["Hello Board — Main sidebar"]
        XCTAssertTrue(helloItem.waitToExist(timeout: 5), "The Plugins menu lists the installed plugin with its placement.")
        let throwsItem = menu.menuItems["Throws — Chat input actions"]
        XCTAssertTrue(throwsItem.exists, "The Plugins menu lists an invalid plugin too.")
        XCTAssertTrue(menu.menuItems["Bad Placement — titleBar"].exists)
        XCTAssertTrue(helloItem.isEnabled, "The plugin row is an enabled submenu trigger, not a command that runs the plugin.")
        attachScreenshot(named: "The Plugins menu lists installed plugins with their placement")

        // Hovering opens the submenu; a click followed by Right Arrow can instead move on to the next menu bar menu.
        // The menu is still opening; a pointer aimed at the row's first frame can miss it.
        XCTAssertTrue(waitForStableFrame(helloItem))
        helloItem.hover()
        let editAction = helloItem.descendants(matching: .menuItem)["Edit…"]
        let deleteAction = helloItem.descendants(matching: .menuItem)["Delete…"]
        let settingsAction = helloItem.descendants(matching: .menuItem)["Settings…"]
        XCTAssertTrue(waitUntil({ editAction.isHittable && deleteAction.isHittable }, timeout: 5),
                      "The plugin submenu is open and its Edit and Delete rows are visible.")
        XCTAssertTrue(settingsAction.exists, "The plugin submenu reserves Settings for later.")
        XCTAssertFalse(settingsAction.isEnabled, "Plugin Settings is a placeholder until settings are implemented.")
        attachScreenshot(named: "A plugin submenu offers Edit, Delete and placeholder Settings")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        menu.click()

        let invalidMenuItem = menu.menuItems["Throws — Chat input actions"]
        XCTAssertTrue(invalidMenuItem.waitToExist(timeout: 5))
        XCTAssertTrue(waitForStableFrame(invalidMenuItem))
        invalidMenuItem.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).hover()
        let pluginError = invalidMenuItem.descendants(matching: .menuItem)
            .matching(NSPredicate(format: "title CONTAINS %@", "Plugin exploded")).firstMatch
        let invalidEdit = invalidMenuItem.descendants(matching: .menuItem)["Edit…"]
        let invalidDelete = invalidMenuItem.descendants(matching: .menuItem)["Delete…"]
        let invalidSettings = invalidMenuItem.descendants(matching: .menuItem)["Settings…"]
        XCTAssertTrue(waitUntil({ pluginError.exists && invalidEdit.isHittable && invalidDelete.isHittable }, timeout: 5),
                      "The invalid plugin's error and actions are visible in its open submenu.")
        XCTAssertTrue(invalidSettings.exists)
        XCTAssertFalse(invalidSettings.isEnabled)
        attachScreenshot(named: "An invalid plugin submenu shows its error and actions")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])

        menu.click()
        let currentHelloItem = menu.menuItems["Hello Board — Main sidebar"]
        XCTAssertTrue(currentHelloItem.waitToExist(timeout: 5))
        XCTAssertTrue(waitForStableFrame(currentHelloItem))
        currentHelloItem.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).hover()
        let currentDeleteAction = currentHelloItem.descendants(matching: .menuItem)["Delete…"]
        XCTAssertTrue(waitUntil({ currentDeleteAction.isHittable }, timeout: 5),
                      "The valid plugin's Delete action is available after opening its submenu.")
        currentDeleteAction.click()
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
        XCTAssertFalse(menu.menuItems["Hello Board — Main sidebar"].exists, "The menu drops deleted plugins.")
        XCTAssertFalse(menu.menuItems["Throws — Chat input actions"].exists, "CLI deletion also removes the plugin entry.")
        attachScreenshot(named: "The Plugins menu after deleting plugins")
        app.typeKey(.escape, modifierFlags: [])
        assertCLIError(try runCLI(["plugin", "delete", "--id", "throws"], expectedStatus: 3), code: "not_found")
        assertCLIError(try runCLI(["plugin", "delete", "--id", "../plugins"], expectedStatus: 2), code: "invalid_argument")
    }
    // case-contract: test_plugin_surfaces_receive_context_and_host_access | An installed plugin receives its placement's context in Playhouse.props: the plugin and the appearance everywhere, the task with its repositories and context folders in the conversation placements, and the composer's draft and selected text in the composer placement, while the board's sidebar gets no task. `plugin render --plugin <id> --task <id>` renders it headlessly with that real context. Playhouse.bridge runs any bridge command but plugin render against the real store (a rename is seen by a fresh CLI process) and rejects a failing one with its code; Playhouse.ui close, openTask and the composer's setDraft, insertText, replaceSelection and focus are recorded headlessly; a composer call from the board's sidebar and a plugin render call are refused the same way in both hosts; and --task without --plugin or an unknown plugin is refused. In the window a page plugin from the board's sidebar covers the board, reads the real board, and its openTask opens that task without sending anything, keeping the page open behind it, so going back from the task returns to the page; a composer popover plugin opens anchored to its button showing the draft and the selected text, and its replaceSelection replaces the selected text in the composer; a sidebar plugin from the conversation sidebar slides in at the trailing edge showing the task's title and repository, inserts text after the selection, replaces the draft, renames the task, and closes with its close button; and a modal plugin beside the Terminal button opens as a sheet with the task's context and closes itself with Playhouse.ui.close. Every presentation starts with the app's standard modal header (the plugin's icon, its name and a close button) above the plugin's atoms, which bring no padding of their own yet sit inside the presentation's inset, as does the header: 24 points in a page or sheet, 20 in a sidebar, and 16 in a popover, whose header title is smaller than a sheet's.
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
        XCTAssertTrue(waitForDisappearance(page, timeout: 10), "The opened task covers the page.")
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("task-view-title")) == "Plugin context task" }, timeout: 15),
                      "openTask opens the task.")
        let composer = element("message-composer")
        XCTAssertTrue(composer.waitToExist(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'user-message-'")).firstMatch.exists,
                       "openTask sends nothing.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Backlog", "The opened task did not start.")
        element("back-to-board-button").click()
        XCTAssertTrue(page.waitToExist(timeout: 10), "The page waited behind the task, so going back returns to it.")
        XCTAssertTrue(waitForStableFrame(page))
        page.descendants(matching: .any)["plugin-surface-close"].click()
        XCTAssertTrue(waitForDisappearance(page, timeout: 10), "The page closes.")
        openTask(named: "Plugin context task")
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 10), "The task's composer is back.")

        // A popover plugin at the start of the composer's toolbar sees the draft and the selection.
        composer.click()
        composer.typeText("make this loud")
        for _ in 0..<4 { composer.typeKey(.leftArrow, modifierFlags: [.shift]) }
        let composerEntry = element("plugin-entry-context-composer")
        XCTAssertTrue(composerEntry.waitToExist(timeout: 5))
        XCTAssertLessThanOrEqual(composerEntry.frame.maxX, element("conversation-plan-button").frame.minX + 1, "Its button sits before the Plan button in the composer's toolbar.")
        XCTAssertEqual(abs(element("open-skills-button").frame.midY - element("toggle-terminal-button").frame.midY), 0, accuracy: 2, "A task's only Skills button is the sidebar's, beside the terminal button.")
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
        XCTAssertEqual(pluginText(popover.descendants(matching: .any)["plugin-version"]), "0")
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
        XCTAssertEqual(plugins.filter { $0["builtIn"] as? Bool != true }.map { $0["valid"] as? Bool }, [true], "A plugin that fetches on mount stays valid: \(plugins)")

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
    // case-contract: test_plugin_image_atom_loads_caches_and_falls_back | An Image atom shows a picture its window loads natively from its url. An installed page plugin's circular 48-point Image of a PNG served over http from 127.0.0.1 draws the picture's red and blue halves clipped to a circle and is one accessibility element with its label, a 64 by 32 file:// Image draws the same PNG from the plugin's folder with its corners rounded, an unlabeled Image of the same URL is decorative (hidden from accessibility), and an Image whose URL answers with something that isn't a picture, or whose server refuses the connection, draws its placeholder symbol instead, with no plugin error. The window loads the served picture once: the copies mounted together share one request, and a second copy mounted by a re-render (the readout reads Copies: 2) and the page closed and opened again draw it with no further request to the server, which marks it no-store; the failed URL isn't asked for again at once either. The Plugin Catalog's Image page draws a data:image picture filled (covering its 64-point square, cropped), fitted (letterboxed inside it), clipped to a circle and with rounded corners, shows the failing URL's placeholder symbol, and keeps its unlabeled Image out of accessibility. `plugin render` reports the plugin's Image nodes and their props (url, size, width and height, circle, cornerRadius, contentMode, placeholder, label) without loading any picture, the added copy is one commit that creates one Image and changes the readout, and the catalog page renders without errors. An Image url that isn't an absolute https, http, file or data:image URL (ftp, a relative path, a data URL of text, an https URL with no host), a missing url, a mistyped size, circle or contentMode, a child, or an event is reported in errors with exit 1, naming the prop and what is wrong.
    func test_plugin_image_atom_loads_caches_and_falls_back() throws {
        let server = try PluginFetchServer()
        addTeardownBlock { withExtendedLifetime(server) {} }
        let base = "http://127.0.0.1:\(server.port)", closed = "http://127.0.0.1:\(try PluginFetchServer.closedPort())"
        try writeInstalledPlugin("avatars", source: nil, placement: "mainSidebar", presentation: "page", name: "Avatars", icon: "person.2")
        let picture = pluginsFolder.appendingPathComponent("avatars/avatar.png")
        try PluginFetchServer.avatarPNG.write(to: picture)
        let source = "var BASE = \"\(base)\";\nvar CLOSED = \"\(closed)\";\nvar FILE = \"\(picture.absoluteString)\";\n" + Self.pluginImageSource
        try source.write(to: pluginsFolder.appendingPathComponent("avatars/index.js"), atomically: true, encoding: .utf8)
        launchApp(defaultParent: fixture.parent.path)
        let plugins = try XCTUnwrap((try runCLI(["plugin", "refresh"])["result"] as? [String: Any])?["plugins"] as? [[String: Any]])
        XCTAssertEqual(plugins.filter { $0["builtIn"] as? Bool != true }.map { $0["valid"] as? Bool }, [true], "A plugin of Images is valid: \(plugins)")

        // The picture's red left half and blue right half, which a placeholder never shows.
        let red = (229, 72, 77), blue = (62, 99, 221)
        func rgb(_ element: XCUIElement, x: CGFloat, y: CGFloat) -> (Int, Int, Int)? {
            guard let image = element.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let color = NSBitmapImageRep(cgImage: image).colorAt(x: min(image.width - 1, Int(CGFloat(image.width) * x)),
                                                                       y: min(image.height - 1, Int(CGFloat(image.height) * y)))?.usingColorSpace(.deviceRGB)
            else { return nil }
            return (Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
        }
        func near(_ element: XCUIElement, x: CGFloat, y: CGFloat, _ expected: (Int, Int, Int)) -> Bool {
            guard let color = rgb(element, x: x, y: y) else { return false }
            return max(abs(color.0 - expected.0), abs(color.1 - expected.1), abs(color.2 - expected.2)) <= 30
        }
        func showsPicture(_ element: XCUIElement) -> Bool {
            element.exists && near(element, x: 0.3, y: 0.5, red) && near(element, x: 0.7, y: 0.5, blue)
        }
        func showsNoPicture(_ element: XCUIElement) -> Bool {
            [0.3, 0.5, 0.7].allSatisfy { x in !near(element, x: x, y: 0.5, red) && !near(element, x: x, y: 0.5, blue) }
        }
        // The placeholder symbol: a share of the middle's pixels clearly darker or lighter than the faint fill above
        // the symbol (inside a circle too), which a plain fill or nothing at all doesn't draw.
        func drawsSymbol(_ element: XCUIElement) -> Bool {
            guard let image = element.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
            let bitmap = NSBitmapImageRep(cgImage: image)
            func luminance(_ x: Int, _ y: Int) -> CGFloat? {
                bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB).map { 0.3 * $0.redComponent + 0.59 * $0.greenComponent + 0.11 * $0.blueComponent }
            }
            guard let fill = luminance(image.width / 2, image.height / 8) else { return false }
            var marked = 0, total = 0
            for y in stride(from: image.height / 4, to: image.height * 3 / 4, by: 2) {
                for x in stride(from: image.width / 4, to: image.width * 3 / 4, by: 2) {
                    total += 1
                    if let value = luminance(x, y), abs(value - fill) > 0.15 { marked += 1 }
                }
            }
            return total > 0 && Double(marked) / Double(total) > 0.03
        }

        let entry = element("plugin-entry-avatars")
        XCTAssertTrue(entry.waitToExist(timeout: 15))
        entry.click()
        var page = element("plugin-surface-avatars")
        XCTAssertTrue(page.waitToExist(timeout: 10), "The Avatars plugin opens.")
        XCTAssertTrue(waitForStableFrame(page), "The page finishes sliding in before its pictures are read.")
        let avatar = page.descendants(matching: .any)["image-remote-1"]
        XCTAssertTrue(avatar.waitToExist(timeout: 10), "A labeled Image is one accessibility element.")
        XCTAssertEqual(avatar.label, "Avatar 1")
        XCTAssertEqual(avatar.frame.width, 48, accuracy: 1)
        XCTAssertEqual(avatar.frame.height, 48, accuracy: 1)
        XCTAssertTrue(waitUntil({ showsPicture(avatar) }, timeout: 15), "The window loads the served PNG over http: \(String(describing: rgb(avatar, x: 0.3, y: 0.5)))")
        XCTAssertFalse(near(avatar, x: 0.06, y: 0.06, red) || near(avatar, x: 0.94, y: 0.06, blue), "circle clips the picture's corners.")
        XCTAssertEqual(server.requests(to: "/avatar.png"), 1, "The served picture is requested once.")

        let onDisk = page.descendants(matching: .any)["image-file"]
        XCTAssertTrue(onDisk.waitToExist(timeout: 10))
        XCTAssertEqual(onDisk.frame.width, 64, accuracy: 1)
        XCTAssertEqual(onDisk.frame.height, 32, accuracy: 1)
        XCTAssertTrue(waitUntil({ showsPicture(onDisk) }, timeout: 10), "A file:// Image draws the PNG from the plugin's folder.")
        XCTAssertFalse(near(onDisk, x: 0.01, y: 0.02, red), "cornerRadius rounds the picture's corners.")
        XCTAssertFalse(page.descendants(matching: .any)["image-decorative"].exists, "An Image without a label is decorative: hidden from accessibility.")

        let broken = page.descendants(matching: .any)["image-broken"], refused = page.descendants(matching: .any)["image-refused"]
        XCTAssertTrue(broken.waitToExist(timeout: 10) && refused.exists, "The Images that can't load are still shown.")
        XCTAssertTrue(waitUntil({ server.requests(to: "/not-an-image.png") == 1 }, timeout: 10), "The window asked for the URL that isn't a picture.")
        XCTAssertFalse(waitUntil({ !showsNoPicture(broken) || !showsNoPicture(refused) }, timeout: 2),
                       "A response that isn't a picture, and a refused connection, leave the placeholder.")
        XCTAssertTrue(drawsSymbol(broken) && drawsSymbol(refused), "The failed Images draw their placeholder symbol.")
        XCTAssertFalse(element("plugin-error").exists, "A failed load is not a plugin error.")
        XCTAssertFalse(element("plugin-node-error").exists, "A failed load is not a node error.")
        attachScreenshot(named: "Image atoms: an http avatar clipped to a circle, a file picture and two placeholders")
        attachElementScreenshot(page.descendants(matching: .any)["image-plugin"], named: "Image atoms close up: avatar, file picture and placeholders")

        page.descendants(matching: .any)["image-add-copy"].click()
        let copy = page.descendants(matching: .any)["image-remote-2"]
        XCTAssertTrue(copy.waitToExist(timeout: 10), "The re-render mounts a second copy.")
        XCTAssertEqual(pluginText(page.descendants(matching: .any)["image-copies"]), "Copies: 2")
        XCTAssertTrue(waitUntil({ showsPicture(copy) }, timeout: 10), "The copy draws the cached picture.")
        XCTAssertTrue(showsPicture(avatar), "The first copy keeps its picture through the re-render.")
        XCTAssertEqual(server.requests(to: "/avatar.png"), 1, "Neither the re-render nor the new copy loads the picture again.")
        attachScreenshot(named: "Image atoms after a second copy of the avatar mounted from the cache")
        attachElementScreenshot(page.descendants(matching: .any)["image-plugin"], named: "Image atoms close up: two copies of the cached avatar")

        element("plugin-surface-close").click()
        XCTAssertTrue(waitUntil({ !page.exists }, timeout: 10), "The page closes.")
        entry.click()
        page = element("plugin-surface-avatars")
        XCTAssertTrue(page.waitToExist(timeout: 10) && waitForStableFrame(page), "The page opens again.")
        let reopened = page.descendants(matching: .any)["image-remote-1"]
        XCTAssertTrue(reopened.waitToExist(timeout: 10))
        XCTAssertTrue(waitUntil({ showsPicture(reopened) }, timeout: 10), "The reopened page draws the picture.")
        XCTAssertEqual(server.requests(to: "/avatar.png"), 1, "Reopening the page loads nothing again; the server marked it no-store, so the memory cache answered.")
        XCTAssertFalse(waitUntil({ server.requests(to: "/not-an-image.png") > 1 }, timeout: 2), "A failed load is remembered, so reopening doesn't ask again at once.")

        clickPluginsMenuItem("Plugin Catalog")
        let imagePage = catalogSidebarRow("plugin-catalog-atom-Image")
        imagePage.click()
        let filled = element("image-fill"), fitted = element("image-fit"), round = element("image-circle")
        XCTAssertTrue(filled.waitToExist(timeout: 10) && fitted.exists && round.exists, "The catalog's Image page shows its Images.")
        XCTAssertFalse(element("plugin-error").exists, "The Image page renders without a plugin error.")
        XCTAssertEqual(filled.frame.width, 64, accuracy: 1)
        XCTAssertTrue(waitUntil({ showsPicture(filled) && showsPicture(fitted) && showsPicture(round) }, timeout: 10), "The data:image picture draws.")
        XCTAssertTrue(near(filled, x: 0.3, y: 0.08, red), "fill covers the square, cropping the picture's sides.")
        XCTAssertFalse(near(fitted, x: 0.3, y: 0.08, red), "fit letterboxes the 2:1 picture inside the square.")
        XCTAssertFalse(near(round, x: 0.06, y: 0.06, red), "circle clips the corners.")
        let rounded = element("image-rounded"), failed = element("image-failed")
        XCTAssertTrue(showsPicture(rounded) && !near(rounded, x: 0.02, y: 0.02, red), "cornerRadius rounds the corners.")
        XCTAssertTrue(waitUntil({ drawsSymbol(failed) }, timeout: 10) && showsNoPicture(failed), "A URL that fails shows its placeholder symbol.")
        XCTAssertFalse(element("image-decorative-catalog").exists, "The unlabeled Image is decorative.")
        attachScreenshot(named: "Plugin Catalog — Image page: fill, fit, circle, rounded and a failed URL")
        attachElementScreenshot(element("image-page"), named: "Plugin Catalog — Image page close up")
    }
    static let pluginImageSource = #"""
function Avatars() {
  var copies = React.useState(1);
  var avatars = [];
  for (var index = 1; index <= copies[0]; index++) {
    avatars.push(h(Image, { key: index, url: BASE + "/avatar.png", size: 48, circle: true, label: "Avatar " + index, testID: "image-remote-" + index }));
  }
  return h(Stack, { spacing: 12, align: "leading", group: true, testID: "image-plugin" },
    h(Stack, { axis: "h", spacing: 12 }, avatars),
    h(Button, { style: "bordered", testID: "image-add-copy", onPress: function () { copies[1](copies[0] + 1); } }, h(Text, null, "Add a copy")),
    h(Text, { size: 11, testID: "image-copies" }, "Copies: ", String(copies[0])),
    h(Image, { url: FILE, width: 64, height: 32, cornerRadius: 8, label: "Picture from disk", testID: "image-file" }),
    h(Image, { url: BASE + "/avatar.png", size: 24, testID: "image-decorative" }),
    h(Stack, { axis: "h", spacing: 12 },
      h(Image, { url: BASE + "/not-an-image.png", size: 48, placeholder: "person.crop.circle", label: "Not a picture", testID: "image-broken" }),
      h(Image, { url: CLOSED + "/avatar.png", size: 48, placeholder: "person.crop.circle", label: "Unreachable picture", testID: "image-refused" })));
}
Playhouse.render(h(Avatars));
"""#
    static let taskCardPluginSource = #"""
function Card() {
  var props = Playhouse.useProps();
  var log = React.useState([]);
  var probes = React.useState(0);
  var focusProbes = React.useState(0);
  React.useEffect(function () {
    var note = function (entry) { log[1](function (entries) { return entries.concat([entry]); }); };
    var probe = Playhouse.throttle(function (reason) {
      probes[1](function (count) { return count + 1; });
      if (reason === "focus") focusProbes[1](function (count) { return count + 1; });
      note("probe " + reason);
    }, 10);
    var offMove = Playhouse.on("task.statusChanged", function (event) { note(event.from + " to " + event.to); probe("move"); });
    var offFocus = Playhouse.on("app.focus", function () { probe("focus"); });
    var offState = Playhouse.on("plugin.stateChanged", function (event) { note("state " + event.key); offMove(); });
    return function () { offMove(); offFocus(); offState(); };
  }, []);
  return h(Stack, { axis: "h", spacing: 4 },
    h(Text, { size: 10, testID: "card-status" }, props.task ? props.task.status : "no task"),
    h(Text, { size: 10, testID: "card-probes" }, "probes " + probes[0]),
    h(Text, { size: 10, testID: "card-focus" }, "focus " + focusProbes[0]),
    // The plugin keeps running as its card changes columns: show only its latest entries.
    h(Text, { size: 10, testID: "card-log" }, log[0].slice(-3).join(", ")));
}
Playhouse.render(h(Card));
"""#
    static let taskCardButtonSource = #"""
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
"""#
    // case-contract: test_plugin_task_card_placement_events_and_throttle | A plugin installed at the taskItem placement (inline or as a button) is valid and runs with its card's task as `props.task`. Playhouse.on delivers app events to a plugin's listeners: task.statusChanged with {taskID, from, to} when its task moves between columns, app.focus when the app comes to the front, and plugin.stateChanged with {pluginID, key, value} when a saved value changes; `plugin render --event @<name>[:json]` reports how many listeners heard each, and the function Playhouse.on returns stops listening. Playhouse.throttle(fn, seconds) runs the first call at once and collapses the calls made within its cooldown into one trailing call with the latest arguments when the cooldown ends. `plugin event <name> [--payload <json>]` hands an app event to the built-in plugins' services; an unknown name is invalid_argument and a payload that is not a JSON object is a usage error. In the window, an installed task card plugin renders on every card, a Backlog card included (which has no built-in pull request controls yet), in the bottom row beside the built-in mode pill once the task has started, shows its task's status, hears the task move to Review and probes through its throttle, and probes through it again when the app comes back to the front (the window's app.focus), repeated focuses within its cooldown collapsing into at most two probes; a task card plugin with a button opens a popover showing its card's task. Only a task card's plugin may call ui.moveTask (which moves its task as dragging the card does), ui.resolveConflicts (which in the window opens its task and sends the conflict instruction) and ui.alert (which shows the board's alert); from the conversation sidebar or the board's sidebar they are unavailable, and so is the composer from a task card, the same in `plugin render`, which records each call in hostCalls, and in the window. The Plugins menu lists the card's built-ins, and disabling the built-in Pull request mode removes the card's mode pill while installed task card plugins stay, until it is enabled again. A turn's move of its task, on Codex and on Claude, is published to the services from the provider's own callbacks, and no move is dropped.
    func test_plugin_task_card_placement_events_and_throttle() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        try writeInstalledPlugin("card-probe", source: Self.taskCardPluginSource, placement: "taskItem", presentation: "inline", name: "Card Probe", icon: "eye")
        try writeInstalledPlugin("card-button", source: Self.taskCardButtonSource, placement: "taskItem", presentation: "popover", name: "Card Button", icon: "tag")
        try writeInstalledPlugin("sidebar-button", source: Self.taskCardButtonSource, placement: "conversationSidebar", presentation: "popover", name: "Sidebar Button", icon: "tag")
        try writeInstalledPlugin("board-button", source: Self.taskCardButtonSource, placement: "mainSidebar", presentation: "popover", name: "Board Button", icon: "tag")
        let claudeEnvironment = try installClaudeFixture(named: "claude-fixture-ui-card-move")
        launchApp(defaultParent: fixture.parent.path)
        let refreshed = try XCTUnwrap((try runCLI(["plugin", "refresh"])["result"] as? [String: Any])?["plugins"] as? [[String: Any]])
        for (pluginID, presentation) in [("card-probe", "inline"), ("card-button", "popover")] {
            let plugin = try XCTUnwrap(refreshed.first { $0["id"] as? String == pluginID })
            XCTAssertEqual(plugin["placement"] as? String, "taskItem")
            XCTAssertEqual(plugin["presentation"] as? String, presentation)
            XCTAssertEqual(plugin["valid"] as? Bool, true, "\(plugin)")
        }

        // In a repository, so the started card has the built-in pull request controls.
        _ = try runCLI(["task", "create", "--title", "Task card plugin", "--prompt", "Fixture task description.", "--repo", fixture.primary.path])
        let taskID = try taskID(named: "Task card plugin")
        let card = element("task-card-\(taskID)")
        XCTAssertTrue(card.waitToExist(timeout: 10))
        let cardRow = element("task-card-plugins-\(taskID)")
        let surface = cardRow.descendants(matching: .any)["plugin-surface-card-probe"]
        let status = cardRow.descendants(matching: .any)["card-status"]
        XCTAssertTrue(surface.waitToExist(timeout: 10), "An installed task card plugin shows on every card, a Backlog one too.")
        XCTAssertTrue(waitUntil({ self.pluginText(status) == "Backlog" }, timeout: 10), "The Backlog card's plugin gets its task: \(pluginText(status))")
        XCTAssertFalse(element("task-pr-mode-\(taskID)").exists, "A Backlog card has no built-in pull request controls yet.")
        attachElementScreenshot(card, named: "Task card plugin on a Backlog card")
        // Manual mode: the move to Review below opens no pull request.
        _ = try runCLI(["plugin", "state", "--id", "pull-request-mode", "--key", taskID, "--value", #""manual""#])

        // Started, the card's bottom row runs the plugin with its task.
        XCTAssertEqual(
            try runCLI([
                "conversation", "send", taskID, "--message", "Please ask your questions.", "--mode", "plan",
                "--answer", "color=Blue", "--answer", "token=fixture-secret"
            ])["ok"] as? Bool,
            true
        )
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response")
        XCTAssertTrue(surface.waitToExist(timeout: 10), "A started task's card renders the task card plugin in its bottom row.")
        XCTAssertFalse(element("plugin-entry-card-probe").exists, "An inline task card plugin has no entry button.")
        XCTAssertTrue(waitUntil({ self.pluginText(status) == "Waiting Response" }, timeout: 10), "The plugin gets its card's task: \(pluginText(status))")
        XCTAssertGreaterThanOrEqual(surface.frame.minY, element("task-title-\(taskID)").frame.maxY, "The plugin row sits below the card's title.")
        let modePill = cardRow.descendants(matching: .any)["task-pr-mode-\(taskID)"]
        XCTAssertTrue(modePill.waitToExist(timeout: 10), "The started card shows the built-in mode pill.")
        XCTAssertTrue(surface.frame.minY < modePill.frame.maxY && modePill.frame.minY < surface.frame.maxY,
                      "The plugin sits in the same row as the built-in pull request controls: \(surface.frame) vs \(modePill.frame)")
        XCTAssertTrue(card.frame.contains(modePill.frame) && card.frame.contains(surface.frame), "Both are inside the card.")
        attachElementScreenshot(card, named: "Task card plugin in a Waiting Response card's bottom row")

        // The card's controls are built-in plugins: disabling the mode pill's removes it, and the installed plugin stays.
        let menu = app.menuBars.menuBarItems["Plugins"]
        menu.click()
        XCTAssertTrue(menu.menuItems["Pull requests — Task card"].waitToExist(timeout: 5), "The Plugins menu lists the card's built-ins.")
        app.typeKey(.escape, modifierFlags: [])
        clickInstalledPluginAction("Disable", pluginRow: "Pull request mode — Task card")
        XCTAssertTrue(waitForDisappearance(modePill, timeout: 10), "Disabling the built-in Pull request mode removes the card's mode pill.")
        XCTAssertTrue(surface.exists, "The installed task card plugin stays.")
        attachElementScreenshot(card, named: "Task card with the Pull request mode built-in disabled")
        _ = try runCLI(["plugin", "enable", "--id", "pull-request-mode"])
        XCTAssertTrue(modePill.waitToExist(timeout: 10), "Enabling it brings the mode pill back.")

        // A task card plugin with a button opens with its card's task.
        let entry = cardRow.descendants(matching: .any)["plugin-entry-card-button"]
        XCTAssertTrue(entry.waitToExist(timeout: 10), "A popover task card plugin has an entry button on the card.")
        entry.click()
        let buttonTask = element("button-task")
        XCTAssertTrue(waitUntil({ buttonTask.exists && self.pluginText(buttonTask) == "Task card plugin" }, timeout: 10),
                      "The popover gets its card's task: \(buttonTask.exists ? pluginText(buttonTask) : "absent")")
        attachScreenshot(named: "Task card plugin opened from its card button")
        // The board answers a card plugin's alert; a task card has no composer.
        let buttonResult = element("button-result")
        element("button-compose").click()
        XCTAssertTrue(waitUntil({ self.pluginText(buttonResult) == "composer: unavailable" }, timeout: 5), "A task card has no composer: \(pluginText(buttonResult))")
        element("button-alert").click()
        let alert = app.sheets.matching(NSPredicate(format: "label == %@", "alert")).firstMatch
        XCTAssertTrue(alert.waitToExist(timeout: 10), "ui.alert from a card plugin shows the board's alert.")
        XCTAssertTrue(alert.staticTexts["Card plugin alert"].exists)
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "value == %@", "Raised from the task card.")).firstMatch.exists)
        attachScreenshot(named: "A task card plugin's ui.alert")
        alert.buttons["OK"].click()
        XCTAssertTrue(waitForDisappearance(alert))
        // The board's alert can close the popover behind it; reopened, the plugin renders afresh.
        let popoverStayed = buttonTask.exists
        if !popoverStayed { entry.click() }
        XCTAssertTrue(waitUntil({ buttonTask.exists && self.pluginText(buttonResult) == (popoverStayed ? "alert: ok" : "idle") }, timeout: 5), pluginText(buttonResult))

        // ui.moveTask moves the card's task as dragging it does; the move to Review reaches the
        // inline plugin as task.statusChanged, which probes through its throttle. The plugin keeps
        // running as its card changes columns, so it counts on from the earlier moves' probes.
        let probes = cardRow.descendants(matching: .any)["card-probes"]
        func probeCount(_ element: XCUIElement) -> Int { Int(pluginText(element).split(separator: " ").last ?? "") ?? -1 }
        let probesBeforeMove = probeCount(probes)
        XCTAssertGreaterThanOrEqual(probesBeforeMove, 0, pluginText(probes))
        element("button-move").click()
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["status"] as? String) == "Review" }, timeout: 10), "ui.moveTask moves the card's task to Review.")
        if buttonTask.exists { app.typeKey(.escape, modifierFlags: []) }
        XCTAssertTrue(waitUntil({ !buttonTask.exists }, timeout: 5))
        // The card now sits in the Review column, which may be scrolled off the board.
        revealOnBoard(card)
        let log = cardRow.descendants(matching: .any)["card-log"]
        XCTAssertTrue(waitUntil({ self.pluginText(log).contains("Waiting Response to Review") }, timeout: 10),
                      "The plugin hears its task move between columns: \(pluginText(log))")
        XCTAssertTrue(waitUntil({ self.pluginText(status) == "Review" }, timeout: 10))
        // An earlier move's probe may hold the 10-second cooldown; the move's call then runs when it ends.
        XCTAssertTrue(waitUntil({ probeCount(probes) > probesBeforeMove }, timeout: 15), "The throttled probe ran: \(pluginText(probes))")
        XCTAssertTrue(waitUntil({ self.pluginText(log).contains("Waiting Response to Review, probe move") }, timeout: 5), "\(pluginText(log))")
        attachElementScreenshot(card, named: "Task card plugin heard the move to Review")
        // Coming back to the front reaches the card's plugin as app.focus. Three focuses within the
        // throttle's 10-second cooldown probe at most twice: once at once (unless the move's probe
        // still holds the cooldown) and once, with the latest call, when the cooldown ends.
        let focusCount = cardRow.descendants(matching: .any)["card-focus"]
        func focusProbes() -> Int { probeCount(focusCount) }
        let focusesBefore = focusProbes()
        let focusStart = Date()
        activateOtherAppThenReturn()
        activateOtherAppThenReturn()
        activateOtherAppThenReturn()
        XCTAssertLessThan(Date().timeIntervalSince(focusStart), 10, "The three focuses land within one cooldown.")
        XCTAssertTrue(waitUntil({ focusProbes() > focusesBefore }, timeout: 15), "The window hands app.focus to the card's plugin: \(pluginText(log))")
        Thread.sleep(forTimeInterval: max(0, 11 - Date().timeIntervalSince(focusStart)))
        XCTAssertLessThanOrEqual(focusProbes(), focusesBefore + 2, "The throttle collapses the three focuses: \(pluginText(log))")
        XCTAssertGreaterThanOrEqual(focusProbes(), focusesBefore + 1)
        attachElementScreenshot(card, named: "Task card plugin probed on focus through its throttle")
        attachScreenshot(named: "Board with a task card plugin")

        // Only a task card's plugin may move a task, resolve conflicts or raise an alert:
        // from the board's sidebar and the conversation sidebar the window refuses them.
        func assertCardOnlyCallsRefused(_ surface: XCUIElement, _ context: String) {
            let result = surface.descendants(matching: .any)["button-result"]
            for (button, label) in [("button-move", "moveTask"), ("button-resolve", "resolveConflicts"), ("button-alert", "alert")] {
                surface.descendants(matching: .any)[button].click()
                XCTAssertTrue(waitUntil({ self.pluginText(result) == "\(label): unavailable" }, timeout: 5), "\(context) refuses \(label): \(pluginText(result))")
            }
            XCTAssertFalse(app.sheets.matching(NSPredicate(format: "label == %@", "alert")).firstMatch.exists, "\(context) raises no alert.")
        }
        let boardEntry = element("plugin-entry-board-button")
        XCTAssertTrue(boardEntry.waitToExist(timeout: 10))
        boardEntry.click()
        let boardPopover = app.popovers.descendants(matching: .any)["plugin-surface-board-button"]
        XCTAssertTrue(boardPopover.waitToExist(timeout: 10), "The board's sidebar plugin opens in a popover.")
        XCTAssertTrue(waitForStableFrame(boardPopover))
        assertCardOnlyCallsRefused(boardPopover, "The board's sidebar")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Review", "The refused move moved nothing.")
        attachElementScreenshot(boardPopover, named: "Card-only calls refused from the board's sidebar")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForDisappearance(boardPopover, timeout: 5))

        // A card's ui.resolveConflicts opens its task and sends the conflict instruction.
        entry.click()
        XCTAssertTrue(waitUntil({ buttonTask.exists && self.pluginText(buttonTask) == "Task card plugin" }, timeout: 10))
        element("button-resolve").click()
        XCTAssertTrue(waitForDisappearance(buttonTask, timeout: 5), "Resolving closes the card's popover.")
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("task-view-title")) == "Task card plugin" }, timeout: 15),
                      "ui.resolveConflicts opens the card's task.")
        let conflictPrompt = element("conversation-scroll-view").descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "The PR has conflicts. Fix them, commit, and push.")).firstMatch
        XCTAssertTrue(conflictPrompt.waitToExist(timeout: 10), "The opened task gets the conflict instruction.")
        attachScreenshot(named: "A card plugin's ui.resolveConflicts opened its task with the conflict instruction")

        let sidebarEntry = element("plugin-entry-sidebar-button")
        XCTAssertTrue(sidebarEntry.waitToExist(timeout: 10))
        sidebarEntry.click()
        let sidebarPopover = app.popovers.descendants(matching: .any)["plugin-surface-sidebar-button"]
        XCTAssertTrue(sidebarPopover.waitToExist(timeout: 10), "The conversation sidebar plugin opens in a popover.")
        XCTAssertTrue(waitForStableFrame(sidebarPopover))
        XCTAssertEqual(pluginText(sidebarPopover.descendants(matching: .any)["button-task"]), "Task card plugin")
        assertCardOnlyCallsRefused(sidebarPopover, "The conversation sidebar")
        attachElementScreenshot(sidebarPopover, named: "Card-only calls refused from the conversation sidebar")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForDisappearance(sidebarPopover, timeout: 5))

        // A turn's end moves its task on whichever provider ran it, from the provider's
        // own callbacks; each move still reaches the services, none dropped.
        func published(_ id: String, to: String) throws -> Bool {
            try diagnosticEvents().contains {
                $0["event"] as? String == "plugin.event.published" && $0["name"] as? String == "task.statusChanged"
                    && $0["taskID"] as? String == id && $0["to"] as? String == to
            }
        }
        XCTAssertTrue(try published(taskID, to: "Waiting Response"), "The Codex turn's move is published to the services.")
        let claudeTaskID = try XCTUnwrap((try runCLI([
            "task", "create", "--title", "Task card Claude move", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
        ])["result"] as? [String: Any])?["id"] as? String)
        _ = try runCLI(["conversation", "send", claudeTaskID, "--message", "Tell me a story."], extraEnvironment: claudeEnvironment)
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: claudeTaskID)?["status"] as? String) == "Review" }, timeout: 30))
        XCTAssertTrue(try published(claudeTaskID, to: "Review"), "The Claude turn's move to Review is published to the services.")
        XCTAssertTrue(try diagnosticEvents().filter { $0["event"] as? String == "plugin.event.dropped" }.isEmpty, "No move is dropped for want of its request.")
    }
}
