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
    // case-contract: test_settings_cpu_usage_color_max_round_trip | The CPU usage color maximum defaults to one fully busy core per logical CPU, round-trips through the CLI/XPC settings commands, and rejects a non-positive value as invalid_argument without changing the stored setting.
    func test_settings_cpu_usage_color_max_round_trip() throws {
        launchApp(defaultParent: fixture.parent.path)
        let expectedDefault = ProcessInfo.processInfo.activeProcessorCount * 100
        XCTAssertEqual(
            (try runCLI(["settings", "get"])["result"] as? [String: Any])?["cpuUsageColorMax"] as? Int, expectedDefault,
            "The bar's scale tops out at one busy core per logical CPU by default."
        )

        app.typeKey(",", modifierFlags: .command)
        let preferences = settingsWindow
        XCTAssertTrue(preferences.waitToExist(timeout: 10), "Workspace Settings did not open.")
        let maxField = preferences.descendants(matching: .any)
            .matching(identifier: "cpu-usage-color-max-field").firstMatch
        XCTAssertTrue(maxField.waitToExist(timeout: 5), "Settings should expose the CPU usage maximum.")
        XCTAssertEqual(maxField.value as? String, expectedDefault.formatted(), "The field should show the stored maximum.")
        attachScreenshot(named: "Workspace Settings exposes the CPU usage color maximum")
        maxField.click()
        maxField.typeKey("a", modifierFlags: .command)
        maxField.typeText("250\r")
        XCTAssertTrue(waitUntil({
            ((try? self.runCLI(["settings", "get"])["result"] as? [String: Any])?["cpuUsageColorMax"] as? Int) == 250
        }, timeout: 10), "An edited maximum should save through the same settings manager the CLI reads.")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitUntil({ !preferences.exists }, timeout: 5))

        assertCLIError(
            try runCLI(["settings", "set-cpu-usage-color-max", "0"], expectedStatus: 2),
            code: "invalid_argument"
        )
        XCTAssertEqual(
            (try runCLI(["settings", "get"])["result"] as? [String: Any])?["cpuUsageColorMax"] as? Int, 250,
            "A rejected maximum should leave the stored one alone."
        )
    }
    // case-contract: test_settings_status_sounds_toggle_mutes_task_sounds | Task status sounds are on by default and turn off and back on through the CLI/XPC settings commands, persisting across a fresh read; an unknown value is rejected as invalid_argument without changing the stored setting. With sounds off, a task that waits for a response and then settles in Review after its turn plays no sound and records the Ping and Glass it would have played as muted; once sounds are back on, the next such task plays Ping then Glass. In the visible UI, the Workspace Settings Sounds toggle shows the stored setting and turning it off or on changes the setting the bridge reads.
    func test_settings_status_sounds_toggle_mutes_task_sounds() throws {
        launchApp(defaultParent: fixture.parent.path)
        func storedSounds() -> Bool? {
            (try? runCLI(["settings", "get"])["result"] as? [String: Any])?["statusSounds"] as? Bool
        }
        func sounds(_ taskID: String, _ event: String) throws -> [String] {
            try diagnosticEvents().filter { $0["event"] as? String == event && $0["taskID"] as? String == taskID }
                .compactMap { $0["sound"] as? String }
        }
        func soundsToggle() -> XCUIElement {
            app.typeKey(",", modifierFlags: .command)
            XCTAssertTrue(settingsWindow.waitToExist(timeout: 10), "Workspace Settings did not open.")
            let toggle = settingsWindow.descendants(matching: .any).matching(identifier: "status-sounds-toggle").firstMatch
            XCTAssertTrue(toggle.waitToExist(timeout: 5), "Settings should expose the status sounds toggle.")
            return toggle
        }
        func closeSettings() {
            let preferences = settingsWindow
            app.typeKey("w", modifierFlags: .command)
            XCTAssertTrue(waitUntil({ !preferences.exists }, timeout: 5))
        }
        XCTAssertEqual(storedSounds(), true, "Status sounds are on by default.")

        var toggle = soundsToggle()
        XCTAssertEqual((toggle.value as? NSNumber)?.intValue, 1, "The toggle should show sounds on by default.")
        toggle.click()
        XCTAssertTrue(waitUntil({ storedSounds() == false }, timeout: 10), "The visible toggle should turn sounds off in the settings the CLI reads.")
        XCTAssertEqual((toggle.value as? NSNumber)?.intValue, 0)
        closeSettings()

        assertCLIError(try runCLI(["settings", "set-status-sounds", "maybe"], expectedStatus: 2), code: "invalid_argument")
        XCTAssertEqual(storedSounds(), false, "A rejected value should leave the stored setting alone.")

        try createTaskFixture(title: "Muted status sound", roots: [fixture.primary.path])
        let mutedID = try taskID(named: "Muted status sound")
        openTask(named: "Muted status sound")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Muted status sound")
        XCTAssertEqual(try sounds(mutedID, "task.status_sound.played"), [], "A muted task reaching Review plays no sound.")
        // The fixture turn asks a question first, so the task waits for a response (Ping) before settling in Review (Glass).
        XCTAssertEqual(try sounds(mutedID, "task.status_sound.muted"), ["Ping", "Glass"])
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10))

        toggle = soundsToggle()
        XCTAssertEqual((toggle.value as? NSNumber)?.intValue, 0, "The toggle should reopen showing sounds off.")
        // Captured on reopen, not right after the click, so the switch has finished animating to off.
        attachScreenshot(named: "Workspace Settings with task sounds turned off")
        attachElementScreenshot(toggle, named: "Task sounds toggle turned off")
        toggle.click()
        XCTAssertTrue(waitUntil({ storedSounds() == true }, timeout: 10), "The visible toggle should turn sounds back on.")
        XCTAssertEqual((toggle.value as? NSNumber)?.intValue, 1)
        _ = try runCLI(["settings", "set-status-sounds", "off"])
        XCTAssertTrue(waitUntil({ (toggle.value as? NSNumber)?.intValue == 0 }, timeout: 5), "The open toggle should follow a change made through the CLI.")
        _ = try runCLI(["settings", "set-status-sounds", "on"])
        XCTAssertTrue(waitUntil({ (toggle.value as? NSNumber)?.intValue == 1 }, timeout: 5))
        closeSettings()

        try createTaskFixture(title: "Audible status sound", roots: [fixture.primary.path])
        let audibleID = try taskID(named: "Audible status sound")
        openTask(named: "Audible status sound")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Audible status sound")
        XCTAssertEqual(try sounds(audibleID, "task.status_sound.played"), ["Ping", "Glass"], "Turning sounds back on restores them.")
        XCTAssertEqual(try sounds(audibleID, "task.status_sound.muted"), [])
    }
    // case-contract: test_plugin_renderer_commits_minimal_ops_and_runs_handlers | The Plugins menu opens the Plugin Catalog, whose sidebar lists every atom (Stack, Text, Icon, Label, Button, Link, Spinner, Spacer, PillPicker, Card, Disclosure, Panel, Meter, Scroll, Divider, ChoiceBar, Toggle, TextField, Segmented, Menu, PressArea, Overlay, Editor, Popover, StepSlider, Modal, Page, SidePanel) and the Task Item, Agents Info, Token Stats, Skills Page, Repository Chips, Composer and Done Archive examples; each atom page renders its JavaScript page through the React renderer into native SwiftUI with no plugin error and lists the atom's props. Clicking a Button atom runs its JavaScript onPress handler, whose state change commits a single text op on that Text's string node, and clicking a Disclosure's title runs its onToggle handler, which collapses it (its children hide while staying in the tree: one commit updating only the Disclosure's props and the state readout) and expands it again, and clicking a ChoiceBar's option runs its onChange handler with that option's value, which selects it (one commit updating only the ChoiceBar's props and the readout), while clicking the option already selected commits nothing, and the Scroll page's scroll view shrinks to its four rows, then, once added rows pass its 120-point maxHeight, stays 120 points tall and scrolls to reach the last row. On the Skills page's controls' pages, clicking the Toggle runs its onToggle handler, which flips it (one commit updating only the Toggle's props and the readout), typing in the TextField runs onChange with the new text, Return in it runs onSubmit and an arrow key runs onArrow with its direction, choosing a Segmented segment runs onChange with its value, choosing a Menu item runs onMenu with that item's id, and the PressArea tells a click (onPress) from a press and hold (onLongPress). On the Overlay page, the badge drawn over the chip's top trailing corner leaves the chip its own size and runs its own onPress. `plugin render` runs a plugin headlessly through the same runtime and node tree: the first render is one commit, each event sent by testID runs its handler and commits only the ops for the nodes that changed (a toggled label is one text op on one node), an interval advanced with --advance updates only its own node, and every bundled catalog page renders without errors. An unknown atom, an unknown or mistyped prop, a missing required prop, an event the atom doesn't raise, a child the atom can't hold, a string outside a Text, or a handler that throws is reported in errors with exit 1 (a mistyped or missing prop, decoded straight from the plugin's values, names its path and what is wrong, such as size: expected a number, found a string or options.0.label: missing), and an event for a missing testID, an event the atom has no handler for, or an unknown catalog page is refused as invalid_argument. Commits, the plugin's props and event values cross between JavaScript and Swift as JavaScript values with JSON.stringify's rules: props keep their types and nesting, NaN becomes null, a Date becomes its ISO string, undefined, function and inherited fields are left out of nested values, toJSON is called once per value (one that returns itself gives an empty object), an event value arrives as a string, and a circular prop or an op whose node id is out of range is reported in errors. The Button page also shows a link-style Button and a large one (taller than a regular Button), each running onPress, the Menu page's disabled Run Now item is shown but can't be chosen, and the Icon page draws the app logo asset in its own colors (original) in a 50-point frame with its accessibility label; a mistyped original or Menu item disabled is reported with its path. The Scroll page's lazy paged list raises onEndReached each time its end scrolls into view: it starts at 1 pages loaded, and scrolling to its end appends a page and then, scrolled to the new end, another (2, then 3 pages loaded); in `plugin render` each onEndReached is one commit that adds the page's rows and changes the readout. The TextField page's plain field (style plain) draws no border on its rounded Stack, so it is shorter than the rounded field, and typing in it runs its onChange.
    func test_plugin_renderer_commits_minimal_ops_and_runs_handlers() throws {
        executionTimeAllowance = 360 // It opens and checks every atom's catalog page, then exercises each control.
        launchApp(defaultParent: fixture.parent.path)
        clickPluginsMenuItem("Plugin Catalog")
        XCTAssertTrue(element("plugin-catalog-atom-Stack").waitToExist(timeout: 15), "Plugins ▸ Plugin Catalog opens the catalog.")
        XCTAssertTrue(element("plugin-catalog-task-item").exists, "The sidebar lists the Task Item example.")
        XCTAssertTrue(element("plugin-catalog-agents-info").exists, "The sidebar lists the Agents Info example.")
        XCTAssertTrue(element("plugin-catalog-token-stats").exists, "The sidebar lists the Token Stats example.")
        XCTAssertTrue(element("plugin-catalog-skills-page").exists, "The sidebar lists the Skills Page example.")
        XCTAssertTrue(element("plugin-catalog-repository-chips").exists, "The sidebar lists the Repository Chips example.")
        XCTAssertTrue(element("plugin-catalog-composer").exists, "The sidebar lists the Composer example.")
        XCTAssertTrue(element("plugin-catalog-done-archive").exists, "The sidebar lists the Done Archive example.")

        let rendered = try XCTUnwrap(try runCLI(["plugin", "render", "--page", "Stack"])["result"] as? [String: Any])
        let atoms = try XCTUnwrap(rendered["atoms"] as? [String])
        XCTAssertEqual(atoms, ["Stack", "Text", "Icon", "Label", "Button", "Link", "Spinner", "Spacer", "PillPicker", "Card", "Disclosure", "Panel", "Meter",
                               "Scroll", "Divider", "ChoiceBar", "Toggle", "TextField", "Segmented", "Menu", "PressArea", "Overlay", "Editor", "Popover", "StepSlider",
                               "Modal", "Page", "SidePanel"])
        try assertPluginValuesCrossWithJSONRules()
        for atom in atoms {
            let row = catalogSidebarRow("plugin-catalog-atom-\(atom)")
            XCTAssertTrue(row.waitToExist(timeout: 10), "The sidebar lists the \(atom) atom.")
            row.click()
            let title = element("plugin-catalog-title")
            XCTAssertTrue(waitUntil({ title.exists && self.pluginText(title) == atom }, timeout: 10), "Selecting \(atom) shows its page.")
            let surface = element("plugin-catalog-surface")
            XCTAssertTrue(surface.waitToExist(timeout: 10), "The \(atom) page renders its JavaScript page.")
            let commit = element("plugin-last-commit")
            XCTAssertTrue(commit.waitToExist(timeout: 10), "The \(atom) page committed its first render.")
            XCTAssertTrue(pluginText(commit).hasPrefix("Commit 1: initial render"), pluginText(commit))
            XCTAssertFalse(element("plugin-error").exists, "The \(atom) page renders without a plugin error.")
            XCTAssertFalse(element("plugin-node-error").exists, "Every node on the \(atom) page has a registered atom.")
            XCTAssertFalse(pluginText(element("plugin-catalog-props")).isEmpty, "The \(atom) page lists its props.")
            attachScreenshot(named: "Plugin Catalog — \(atom)")
        }

        catalogSidebarRow("plugin-catalog-atom-Text").click()
        XCTAssertTrue(element("text-title").waitToExist(timeout: 10), "Text atoms render natively from the JavaScript page.")
        XCTAssertEqual(pluginText(element("text-title")), "Title: 13 semibold, tracking 0.35")

        catalogSidebarRow("plugin-catalog-atom-Button").click()
        let pressCount = element("button-press-count")
        XCTAssertTrue(pressCount.waitToExist(timeout: 10))
        XCTAssertEqual(pluginText(pressCount), "Pressed 0 times")
        element("button-plain").click()
        XCTAssertTrue(waitUntil({ self.pluginText(pressCount) == "Pressed 1 times" }, timeout: 5), "The tap ran the JavaScript onPress handler.")
        let commit = element("plugin-last-commit")
        XCTAssertTrue(waitUntil({ self.pluginText(commit).hasPrefix("Commit 2: text → node ") }, timeout: 5),
                      "The press committed one text op on one node: \(pluginText(commit))")
        attachScreenshot(named: "Button atom after one press")
        element("button-disabled").click()
        XCTAssertFalse(waitUntil({ self.pluginText(pressCount) != "Pressed 1 times" }, timeout: 2), "A disabled Button doesn't call its handler.")
        XCTAssertTrue(pluginText(commit).hasPrefix("Commit 2: "), "No commit followed the disabled tap: \(pluginText(commit))")
        let linkStyled = element("button-link")
        let large = element("button-large")
        XCTAssertTrue(linkStyled.exists && large.exists, "The Button page shows a link-style and a large button.")
        XCTAssertGreaterThan(large.frame.height, element("button-automatic").frame.height, "A large Button is taller than a regular one.")
        linkStyled.click()
        XCTAssertTrue(waitUntil({ self.pluginText(pressCount) == "Pressed 2 times" }, timeout: 5), "The link-style Button runs its onPress.")
        large.click()
        XCTAssertTrue(waitUntil({ self.pluginText(pressCount) == "Pressed 3 times" }, timeout: 5), "The large Button runs its onPress.")
        attachScreenshot(named: "Button atom link style and large control size")

        catalogSidebarRow("plugin-catalog-atom-Icon").click()
        let logo = element("icon-asset-original")
        XCTAssertTrue(logo.waitToExist(timeout: 10), "The Icon page draws the app logo in its own colors.")
        // The logo keeps its aspect ratio inside its 50-point frame, the board header's size.
        XCTAssertEqual(max(logo.frame.width, logo.frame.height), 50, accuracy: 1)
        XCTAssertEqual(logo.label, "Playhouse logo")
        // The logo's own blue, purple and pink, which a template (single-tint) image can't show. Only its opaque
        // spots are sampled: the catalog is light, and the board header's check assumes the dark board behind it.
        let logoImage = logo.screenshot().image
        assertPixel(logoImage, normalizedX: 0.20, normalizedY: 0.50, rgb: (71, 176, 235), accuracy: 30)
        assertPixel(logoImage, normalizedX: 0.80, normalizedY: 0.50, rgb: (148, 41, 121), accuracy: 30)
        assertPixel(logoImage, normalizedX: 0.20, normalizedY: 0.80, rgb: (177, 54, 171), accuracy: 35)
        assertPixel(logoImage, normalizedX: 0.80, normalizedY: 0.80, rgb: (240, 82, 121), accuracy: 30)
        attachScreenshot(named: "Icon atom with an original-color asset")

        catalogSidebarRow("plugin-catalog-atom-Disclosure").click()
        let disclosureToggle = element("disclosure-toggle")
        XCTAssertTrue(disclosureToggle.waitToExist(timeout: 10))
        XCTAssertEqual(disclosureToggle.value as? String, "Expanded")
        XCTAssertTrue(element("disclosure-first").exists, "An expanded Disclosure shows its children.")
        disclosureToggle.click()
        XCTAssertTrue(waitUntil({ !self.element("disclosure-first").exists }, timeout: 5), "Clicking the title ran onToggle, which collapsed it.")
        XCTAssertEqual(disclosureToggle.value as? String, "Collapsed")
        XCTAssertEqual(pluginText(element("disclosure-state")), "Collapsed")
        XCTAssertTrue(waitUntil({ self.pluginText(commit).hasPrefix("Commit 2: update, text → nodes ") }, timeout: 5),
                      "Collapsing changed only the Disclosure's props and the readout: \(pluginText(commit))")
        attachScreenshot(named: "Disclosure atom collapsed")
        disclosureToggle.click()
        XCTAssertTrue(element("disclosure-first").waitToExist(timeout: 5), "Expanding brings the children back.")
        XCTAssertEqual(disclosureToggle.value as? String, "Expanded")

        catalogSidebarRow("plugin-catalog-atom-ChoiceBar").click()
        let overviewChoice = element("choice-overview"), wastersChoice = element("choice-wasters")
        XCTAssertTrue(wastersChoice.waitToExist(timeout: 10))
        XCTAssertTrue(overviewChoice.isSelected, "The selected option carries the selected trait.")
        XCTAssertFalse(wastersChoice.isSelected)
        wastersChoice.click()
        XCTAssertTrue(waitUntil({ self.pluginText(self.element("choice-selected")) == "Selected: wasters" }, timeout: 5), "Clicking an option ran onChange with its value.")
        XCTAssertTrue(waitUntil({ wastersChoice.isSelected && !overviewChoice.isSelected }, timeout: 5), "The chosen option is now the selected one.")
        XCTAssertTrue(waitUntil({ self.pluginText(commit).hasPrefix("Commit 2: update, text → nodes ") }, timeout: 5),
                      "Choosing changed only the ChoiceBar's props and the readout: \(pluginText(commit))")
        attachScreenshot(named: "ChoiceBar atom after choosing Wasters")
        wastersChoice.click()
        XCTAssertFalse(waitUntil({ !self.pluginText(commit).hasPrefix("Commit 2: ") }, timeout: 2), "Clicking the selected option commits nothing: \(pluginText(commit))")

        catalogSidebarRow("plugin-catalog-atom-Scroll").click()
        let scroll = element("scroll-demo")
        XCTAssertTrue(scroll.waitToExist(timeout: 10))
        XCTAssertTrue(element("scroll-row-4").waitToExist(timeout: 5))
        XCTAssertLessThan(scroll.frame.height, 119, "Four rows fit, so the Scroll shrinks to them.")
        element("scroll-add").click()
        XCTAssertTrue(waitUntil({ self.pluginText(self.element("scroll-count")) == "8 rows" }, timeout: 5))
        let lastRow = element("scroll-row-8")
        XCTAssertTrue(lastRow.waitToExist(timeout: 5))
        XCTAssertTrue(waitUntil({ abs(scroll.frame.height - 120) <= 1 }, timeout: 5), "Past its maxHeight the Scroll stays 120 points tall: \(scroll.frame.height)")
        // A row clipped by a scroll view still reports itself hittable, so its frame says where it is.
        XCTAssertGreaterThan(lastRow.frame.maxY, scroll.frame.maxY + 1, "The last row starts below the Scroll's visible area.")
        for _ in 0..<10 where lastRow.frame.maxY > scroll.frame.maxY + 1 {
            scroll.scroll(byDeltaX: 0, deltaY: -60)
        }
        XCTAssertLessThanOrEqual(lastRow.frame.maxY, scroll.frame.maxY + 1, "Scrolling inside the Scroll brings its last row into view.")
        attachScreenshot(named: "Scroll atom capped at 120 points and scrolled to its last row")
        // A lazy Scroll raises onEndReached each time its end scrolls into view.
        let paged = element("scroll-paged")
        let pages = element("scroll-pages")
        XCTAssertTrue(paged.waitToExist(timeout: 5))
        XCTAssertEqual(pluginText(pages), "1 pages loaded", "The paged list's end starts out of view.")
        for expected in ["2 pages loaded", "3 pages loaded"] {
            for _ in 0..<40 where pluginText(pages) != expected {
                paged.scroll(byDeltaX: 0, deltaY: -200)
            }
            XCTAssertTrue(waitUntil({ self.pluginText(pages) == expected }, timeout: 5), "Scrolling to the end loads the next page: \(pluginText(pages))")
        }
        // The list is lazy, so the third page's last row is built only once it scrolls near.
        let pagedLastRow = element("scroll-paged-row-60")
        for _ in 0..<20 where !pagedLastRow.exists { paged.scroll(byDeltaX: 0, deltaY: -200) }
        XCTAssertTrue(pagedLastRow.exists, "The third page's rows are in the list.")
        attachScreenshot(named: "Lazy Scroll appended two pages as its end scrolled into view")

        // The Skills page's controls.
        catalogSidebarRow("plugin-catalog-atom-Toggle").click()
        let toggle = element("toggle-demo")
        XCTAssertTrue(toggle.waitToExist(timeout: 10))
        XCTAssertTrue(isOn(toggle), "The Toggle page's switch starts on.")
        toggle.click()
        XCTAssertTrue(waitUntil({ !self.isOn(toggle) && self.pluginText(self.element("toggle-state")) == "Off" }, timeout: 5), "onToggle flipped the switch off.")
        XCTAssertTrue(waitUntil({ self.pluginText(commit).hasPrefix("Commit 2: update, text → nodes ") }, timeout: 5),
                      "Toggling updated only the Toggle's props and the readout: \(pluginText(commit))")
        attachScreenshot(named: "Toggle atom switched off")

        catalogSidebarRow("plugin-catalog-atom-TextField").click()
        let field = element("text-field-demo")
        XCTAssertTrue(field.waitToExist(timeout: 10))
        field.click()
        field.typeText("release")
        XCTAssertTrue(waitUntil({ self.pluginText(self.element("text-field-value")) == "Text: release" }, timeout: 5), "onChange received the typed text.")
        let plainField = element("text-field-plain")
        XCTAssertTrue(plainField.waitToExist(timeout: 5))
        XCTAssertLessThan(plainField.frame.height, field.frame.height - 1, "The plain field draws no border, so it is shorter than the rounded one.")
        XCTAssertTrue(element("text-field-plain-box").frame.contains(plainField.frame), "The plain field sits inside its rounded Stack.")
        plainField.click()
        plainField.typeText("quiet")
        XCTAssertTrue(waitUntil({ self.pluginText(self.element("text-field-plain-value")) == "Plain: quiet" }, timeout: 5), "Typing in the plain field runs its onChange.")
        field.click()
        field.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(waitUntil({ self.pluginText(self.element("text-field-key")) == "Key: down" }, timeout: 5), "Down ran onArrow with its direction.")
        field.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(waitUntil({ self.pluginText(self.element("text-field-key")) == "Key: up" }, timeout: 5), "Up ran onArrow with its direction.")
        field.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil({ self.pluginText(self.element("text-field-key")) == "Key: return" }, timeout: 5), "Return ran onSubmit.")
        XCTAssertEqual(field.value as? String, "release", "The handled keys leave the text alone.")
        attachScreenshot(named: "TextField atom after typing")
        element("text-field-clear").click()
        XCTAssertTrue(waitUntil({ (field.value as? String ?? "") == "" && self.pluginText(self.element("text-field-value")) == "Text: " }, timeout: 5),
                      "The field shows the text its owner sets.")

        catalogSidebarRow("plugin-catalog-atom-Segmented").click()
        let segmented = element("segmented-demo")
        XCTAssertTrue(segmented.waitToExist(timeout: 10))
        segmented.radioButtons["Global"].click()
        XCTAssertTrue(waitUntil({ self.pluginText(self.element("segmented-selected")) == "Selected: global" }, timeout: 5), "onChange received the segment's value.")
        XCTAssertTrue(waitUntil({ self.isOn(segmented.radioButtons["Global"]) }, timeout: 5))
        attachScreenshot(named: "Segmented atom on Global")

        catalogSidebarRow("plugin-catalog-atom-Menu").click()
        let menu = element("menu-demo")
        XCTAssertTrue(menu.waitToExist(timeout: 10))
        menu.click()
        let delete = app.menuItems.matching(identifier: "menu-delete").firstMatch
        XCTAssertTrue(delete.waitToExist(timeout: 5), "The Menu opens its items.")
        XCTAssertTrue(app.menuItems["Reveal in Finder"].exists)
        let disabledItem = app.menuItems.matching(identifier: "menu-disabled").firstMatch
        XCTAssertTrue(disabledItem.exists, "The Menu shows its disabled item.")
        XCTAssertFalse(disabledItem.isEnabled, "A disabled Menu item can't be chosen.")
        attachScreenshot(named: "Menu atom open with its groups")
        delete.click()
        XCTAssertTrue(waitUntil({ self.pluginText(self.element("menu-chosen")) == "Chosen: delete" }, timeout: 5), "onMenu received the item's id.")

        catalogSidebarRow("plugin-catalog-atom-PressArea").click()
        let area = element("press-area-demo")
        XCTAssertTrue(area.waitToExist(timeout: 10))
        area.click()
        XCTAssertTrue(waitUntil({ self.pluginText(self.element("press-area-count")) == "Clicked 1 · held 0" }, timeout: 5), "A click runs onPress.")
        area.press(forDuration: 1.0)
        XCTAssertTrue(waitUntil({ self.pluginText(self.element("press-area-count")) == "Clicked 1 · held 1" }, timeout: 5), "A press and hold runs onLongPress, not onPress.")
        attachScreenshot(named: "PressArea atom after a click and a press and hold")

        catalogSidebarRow("plugin-catalog-atom-Overlay").click()
        let overlaid = element("overlay-base")
        let overlayBadge = element("overlay-badge")
        XCTAssertTrue(overlaid.waitToExist(timeout: 10) && overlayBadge.waitToExist(timeout: 10))
        // The overlay's accessibility frame spans the badge too; its layout is the chip's, so the next row sits 12 points below the chip.
        XCTAssertEqual(element("overlay-count").frame.minY, overlaid.frame.maxY + 12, accuracy: 1.5, "The badge drawn over the chip leaves it its own size.")
        XCTAssertEqual(overlayBadge.frame.width, 20, accuracy: 1)
        XCTAssertEqual(overlayBadge.frame.midX, overlaid.frame.maxX + 6 - 10, accuracy: 1.5, "The badge sits on the chip's trailing edge, moved 6 points out.")
        XCTAssertEqual(overlayBadge.frame.midY, overlaid.frame.minY - 6 + 10, accuracy: 1.5, "The badge sits on the chip's top edge, moved 6 points up.")
        overlayBadge.click()
        XCTAssertTrue(waitUntil({ self.pluginText(self.element("overlay-count")) == "Pressed the badge 1 times" }, timeout: 5), "The badge runs its own onPress.")
        attachScreenshot(named: "Overlay atom: a badge on a chip's top trailing corner")
    }
    // case-contract: test_plugin_stack_surface_composes_panel_and_choice_bar | The Plugin Catalog's Stack page draws a surface on a Stack in both axes, while its Stacks without surface props draw nothing: a column filled accent at 0.18 with an accent border and an 8-point radius keeps its children at its top leading corner, inside its padding, when its 220-point minWidth and 90-point minHeight are larger than they are; a capsule row filled #2E7D32 with a dashed border lays its icon and text out side by side on that green; and a border-only Stack with align unset (a Stack's default, center) and fillWidth stretches across the page, draws its border and no fill with rounded corners, and keeps its text centered both ways in its 60-point minHeight. The Panel page shows each Panel beside the Stack it is shorthand for (a column Stack with group, fill primary at 0.05, radius 8 and padding 12 unless set), and each pair is the same size, including a Panel with no padding prop beside a Stack padded 12, including the accent Log in Panel and the single decorated row Stack that replaces its nested row. `plugin render` reports the surface props on those nodes with no errors and none on the plain Stacks, and a mistyped surface prop on a Stack (fill, fillOpacity, cornerRadius, capsule, strokeWidth or dash) or an unknown one (shadow, or axis on a Panel) is reported in errors with exit 1, naming the prop and what is wrong. The ChoiceBar page also composes the bar from atoms, a decorated row Stack of Buttons each marked selected (the Button's selected prop) around a decorated Stack with a Text: it is the same size as the ChoiceBar atom beside it, its Overview button carries the selected trait, and clicking Wasters runs its onPress, which moves the selected trait to it (Composed: wasters) while the ChoiceBar atom stays on Overview; a mistyped selected on a Button is reported with its path.
    func test_plugin_stack_surface_composes_panel_and_choice_bar() throws {
        launchApp(defaultParent: fixture.parent.path)
        clickPluginsMenuItem("Plugin Catalog")
        let stackPage = catalogSidebarRow("plugin-catalog-atom-Stack")
        XCTAssertTrue(stackPage.waitToExist(timeout: 15), "Plugins ▸ Plugin Catalog lists the Stack atom.")
        stackPage.click()
        func rgb(_ element: XCUIElement, x: CGFloat, y: CGFloat) throws -> (Int, Int, Int) {
            let image = try XCTUnwrap(element.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let bitmap = NSBitmapImageRep(cgImage: image)
            let color = try XCTUnwrap(bitmap.colorAt(x: min(image.width - 1, Int(CGFloat(image.width) * x)),
                                                     y: min(image.height - 1, Int(CGFloat(image.height) * y)))?.usingColorSpace(.deviceRGB))
            return (Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
        }
        func distance(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int { max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2)) }

        let column = element("stack-surface-column"), first = element("stack-surface-column-first")
        XCTAssertTrue(column.waitToExist(timeout: 10), "The Stack page shows a column Stack with a surface.")
        XCTAssertFalse(element("plugin-error").exists, "The Stack page renders without a plugin error.")
        XCTAssertFalse(element("plugin-node-error").exists, "Every surface prop decodes.")
        XCTAssertEqual(column.frame.height, 90, accuracy: 1, "The column is its 90-point minHeight: \(column.frame)")
        XCTAssertEqual(column.frame.width, 220, accuracy: 1, "The column is its 220-point minWidth: \(column.frame)")
        XCTAssertEqual(first.frame.minY - column.frame.minY, 8, accuracy: 2, "The children stay at the top, inside the padding: \(first.frame) in \(column.frame)")
        XCTAssertEqual(first.frame.minX - column.frame.minX, 8, accuracy: 2, "The children stay at the leading edge, inside the padding: \(first.frame) in \(column.frame)")

        // A Stack without surface props draws nothing: its empty part shows the page behind it. A plain Stack's
        // accessibility frame is only its children's, so both points are read from the screen on its row: inside
        // the full-width Stack well past its text, and in the page's padding 6 points in from its straight edge.
        let plain = element("stack-fill"), page = element("plugin-catalog-surface")
        XCTAssertTrue(plain.exists && page.exists)
        let screenFrame = try XCTUnwrap(NSScreen.main?.frame)
        let screen = NSBitmapImageRep(cgImage: try XCTUnwrap(XCUIScreen.main.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        func screenRGB(x: CGFloat, y: CGFloat) throws -> (Int, Int, Int) {
            let color = try XCTUnwrap(screen.colorAt(x: Int(x * CGFloat(screen.pixelsWide) / screenFrame.width),
                                                     y: Int(y * CGFloat(screen.pixelsHigh) / screenFrame.height))?.usingColorSpace(.deviceRGB))
            return (Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
        }
        XCTAssertLessThan(plain.frame.maxX, page.frame.maxX - 60, "The plain Stack's text ends well before the page's edge: \(plain.frame) in \(page.frame)")
        let background = try screenRGB(x: page.frame.maxX - 6, y: plain.frame.midY)
        XCTAssertLessThanOrEqual(distance(try screenRGB(x: page.frame.maxX - 30, y: plain.frame.midY), background), 4, "A plain Stack draws no background.")
        XCTAssertGreaterThan(distance(try rgb(column, x: 0.9, y: 0.85), background), 8, "The decorated column is filled.")
        XCTAssertGreaterThan(distance(try rgb(column, x: 0.5, y: 0.003), try rgb(column, x: 0.9, y: 0.85)), 20, "The column's accent border is drawn along its edge, over its fill.")
        XCTAssertLessThanOrEqual(distance(try rgb(column, x: 0, y: 0), background), 6, "The column's corner is rounded: its outermost corner pixel is the page.")

        attachScreenshot(named: "Stack atom: plain Stacks and a decorated column")
        // The last two examples can sit below the catalog's visible area; their pixels are sampled only once they are in view.
        let row = element("stack-surface-row"), rowText = element("stack-surface-row-text")
        let center = element("stack-surface-center"), centerText = element("stack-surface-center-text")
        XCTAssertTrue(row.exists && rowText.exists, "The Stack page shows a row Stack with a surface.")
        XCTAssertTrue(center.exists && centerText.exists)
        let pageScroll = app.scrollViews.containing(.any, identifier: "plugin-catalog-surface").firstMatch
        for _ in 0..<10 where center.frame.maxY > pageScroll.frame.maxY - 2 {
            pageScroll.scroll(byDeltaX: 0, deltaY: -60)
        }
        XCTAssertLessThanOrEqual(center.frame.maxY, pageScroll.frame.maxY - 2, "The border-only Stack is in view: \(center.frame) in \(pageScroll.frame)")
        XCTAssertGreaterThanOrEqual(row.frame.minY, pageScroll.frame.minY + 2, "The decorated row is in view too: \(row.frame) in \(pageScroll.frame)")
        XCTAssertEqual(rowText.frame.midY, row.frame.midY, accuracy: 2, "The row lays its text out beside its icon, centered vertically.")
        XCTAssertGreaterThan(rowText.frame.minX - row.frame.minX, 20, "The icon sits before the text in the row: \(rowText.frame) in \(row.frame)")
        assertPixel(row.screenshot().image, normalizedX: 0.5, normalizedY: 0.14, rgb: (46, 125, 50), accuracy: 25)
        XCTAssertLessThanOrEqual(distance(try rgb(row, x: 0, y: 0), background), 6, "The row is a capsule: its corner is the page behind it.")
        assertPixel(row.screenshot().image, normalizedX: 0.5, normalizedY: 0.86, rgb: (46, 125, 50), accuracy: 25)

        XCTAssertEqual(center.frame.height, 60, accuracy: 1, "The border-only Stack is its 60-point minHeight.")
        XCTAssertGreaterThan(center.frame.width, column.frame.width + 40, "fillWidth stretches it across the page: \(center.frame)")
        XCTAssertEqual(centerText.frame.midX, center.frame.midX, accuracy: 2, "An unset align (center) keeps the text centered across the stretched width.")
        XCTAssertEqual(centerText.frame.midY, center.frame.midY, accuracy: 2, "An unset align (center) keeps the text centered in the minHeight.")
        XCTAssertGreaterThan(distance(try rgb(center, x: 0.5, y: 0.01), background), 40, "strokeWidth alone draws a primary border along the edge.")
        XCTAssertLessThanOrEqual(distance(try rgb(center, x: 0.1, y: 0.5), background), 4, "A border alone draws no fill.")
        XCTAssertLessThanOrEqual(distance(try rgb(center, x: 0, y: 0), background), 6, "The border-only Stack's corners are rounded.")
        attachScreenshot(named: "Stack atom: decorated column, capsule row and border-only Stack")

        catalogSidebarRow("plugin-catalog-atom-Panel").click()
        let panelDefault = element("panel-default")
        XCTAssertTrue(panelDefault.waitToExist(timeout: 10), "The Panel page shows its Panels.")
        XCTAssertFalse(element("plugin-error").exists, "The Panel page renders without a plugin error.")
        for name in ["panel-padded", "panel-default", "panel-accent", "panel-capsule"] {
            let panel = element(name), stack = element("\(name)-stack")
            XCTAssertTrue(panel.waitToExist(timeout: 5) && stack.waitToExist(timeout: 5), "\(name) sits beside the Stack it stands for.")
            XCTAssertEqual(panel.frame.width, stack.frame.width, accuracy: 0.5, "\(name) is as wide as its Stack.")
            XCTAssertEqual(panel.frame.height, stack.frame.height, accuracy: 0.5, "\(name) is as tall as its Stack.")
            XCTAssertLessThanOrEqual(distance(try rgb(panel, x: 0.97, y: 0.5), try rgb(stack, x: 0.97, y: 0.5)), 3, "\(name) draws the same surface as its Stack.")
        }
        attachScreenshot(named: "Panel atom beside the Stacks it is shorthand for")

        catalogSidebarRow("plugin-catalog-atom-ChoiceBar").click()
        let atomBar = element("choice-bar"), composedBar = element("choice-bar-composed")
        XCTAssertTrue(atomBar.waitToExist(timeout: 10) && composedBar.waitToExist(timeout: 10), "The ChoiceBar page shows the atom and the bar composed from atoms.")
        XCTAssertEqual(composedBar.frame.width, atomBar.frame.width, accuracy: 1, "The composed bar is as wide as the ChoiceBar atom.")
        XCTAssertEqual(composedBar.frame.height, atomBar.frame.height, accuracy: 1, "The composed bar is as tall as the ChoiceBar atom.")
        let composedOverview = element("choice-composed-overview"), composedWasters = element("choice-composed-wasters")
        XCTAssertTrue(composedOverview.isSelected, "A Button marked selected carries the selected trait.")
        XCTAssertFalse(composedWasters.isSelected)
        composedWasters.click()
        XCTAssertTrue(waitUntil({ self.pluginText(self.element("choice-composed-selected")) == "Composed: wasters" }, timeout: 5), "Clicking Wasters ran its onPress.")
        XCTAssertTrue(waitUntil({ composedWasters.isSelected && !composedOverview.isSelected }, timeout: 5), "The selected trait moved to Wasters.")
        XCTAssertTrue(element("choice-overview").isSelected, "The ChoiceBar atom stays on Overview.")
        attachScreenshot(named: "ChoiceBar atom beside the bar composed from Stack and Button atoms")

        for (source, message) in [
            (#"Playhouse.render(h(Stack, { fill: 3 }));"#, "<Stack> has an invalid prop: fill: expected a string, found 3"),
            (#"Playhouse.render(h(Stack, { axis: "h", fillOpacity: "high" }));"#, "<Stack> has an invalid prop: fillOpacity: expected a number, found a string"),
            (#"Playhouse.render(h(Stack, { cornerRadius: true }));"#, "<Stack> has an invalid prop: cornerRadius: expected a number, found a boolean"),
            (#"Playhouse.render(h(Stack, { capsule: "yes" }));"#, "<Stack> has an invalid prop: capsule: expected a boolean, found a string"),
            (#"Playhouse.render(h(Stack, { strokeWidth: "2" }));"#, "<Stack> has an invalid prop: strokeWidth: expected a number, found a string"),
            (#"Playhouse.render(h(Stack, { dash: "4" }));"#, "<Stack> has an invalid prop: dash: expected an array, found a string"),
            (#"Playhouse.render(h(Stack, { dash: [4, "3"] }));"#, "<Stack> has an invalid prop: dash.1: expected a number, found a string"),
            (#"Playhouse.render(h(Stack, { shadow: 4 }));"#, #"<Stack> has no prop "shadow""#),
            (#"Playhouse.render(h(Panel, { axis: "h" }));"#, #"<Panel> has no prop "axis""#),
            (#"Playhouse.render(h(Button, { selected: "yes" }));"#, "<Button> has an invalid prop: selected: expected a boolean, found a string"),
        ] {
            let file = dataDirectory.appendingPathComponent("plugin-surface-\(UUID().uuidString.prefix(8)).js")
            try source.write(to: file, atomically: true, encoding: .utf8)
            let failed = try runCLI(["plugin", "render", "--file", file.path], expectedStatus: 1)
            let errors = (failed["result"] as? [String: Any])?["errors"] as? [String] ?? []
            XCTAssertTrue(errors.contains { $0.contains(message) }, "\(source) reports \(message): \(errors)")
        }
    }
    // case-contract: test_plugin_task_item_renders_from_atoms_like_native | The Plugin Catalog's Task Item page shows the task item composed in JavaScript from atoms beside the native SwiftUI task item built from the same atoms and sample data: both show the same title, progress report, status message and token counter with the same sizes, and the JavaScript tree uses only atoms with the native card's identifiers and context menu; neither shows a pull-request mode pill, pull-request link, create button or conflicts button, which are task card plugins and not part of the task item. Blocking the JavaScript item changes only its status message and the toggle's label (one commit: text, update, text on three nodes) while the native item keeps its own state, clicking the JavaScript card runs its onPress handler (Opened 1 times, one text op) without re-rendering the title or the card, and right-clicking the JavaScript card offers the native card's menu, whose Move to Done runs onMenu with its id (Last: menu done). The time row is one flat row: the clock, the created time and the token counter are siblings in one stack, so the time shows in full (Nov 8, 2026), as wide in the JavaScript item as in the native one and left of the counter.
    func test_plugin_task_item_renders_from_atoms_like_native() throws {
        launchApp(defaultParent: fixture.parent.path)
        clickPluginsMenuItem("Plugin Catalog")
        let example = catalogSidebarRow("plugin-catalog-task-item")
        XCTAssertTrue(example.waitToExist(timeout: 15), "Plugins ▸ Plugin Catalog lists the Task Item example.")
        example.click()
        let jsSide = element("plugin-catalog-js-task-item")
        let nativeSide = element("plugin-catalog-native-task-item")
        XCTAssertTrue(jsSide.waitToExist(timeout: 10), "The page shows the JavaScript task item.")
        XCTAssertTrue(nativeSide.waitToExist(timeout: 10), "The page shows the native task item.")
        XCTAssertFalse(element("plugin-error").exists, "The JavaScript task item renders without errors.")

        let id = "C0FFEE00-0000-4000-8000-000000000001"
        func pair(_ prefix: String, _ suffix: String = "") -> (js: XCUIElement, native: XCUIElement) {
            (element("\(prefix)\(id)\(suffix)"), element("\(prefix)native-\(id)\(suffix)"))
        }
        let shared = [("task-card-", ""), ("task-title-", ""), ("task-progress-report-", ""), ("task-progress-label-", ""),
                      ("task-status-message-", ""), ("task-token-usage-counter-", "")]
        for (prefix, suffix) in shared {
            let (js, native) = pair(prefix, suffix)
            XCTAssertTrue(js.waitToExist(timeout: 10), "The JavaScript item has \(prefix)…")
            XCTAssertTrue(native.waitToExist(timeout: 10), "The native item has \(prefix)…")
            XCTAssertEqual(js.frame.width, native.frame.width, accuracy: 1, "\(prefix) has the same width in both.")
            XCTAssertEqual(js.frame.height, native.frame.height, accuracy: 1, "\(prefix) has the same height in both.")
        }
        XCTAssertEqual(pluginText(pair("task-title-").js), "Add a React renderer for plugins")
        XCTAssertEqual(pluginText(pair("task-title-").js), pluginText(pair("task-title-").native), "Both show the same title.")
        XCTAssertEqual(pluginText(pair("task-progress-label-").js), "Building")
        for prefix in ["task-pr-mode-", "task-resolve-pr-conflicts-", "task-create-pr-"] {
            XCTAssertFalse(pair(prefix).js.exists || pair(prefix).native.exists,
                           "The pull request controls (\(prefix)…) are task card plugins, not part of the task item.")
        }
        XCTAssertFalse(pair("task-pr-link-", "-193").js.exists || pair("task-pr-link-", "-193").native.exists,
                       "The pull request link is the pull-requests plugin's, not part of the task item.")
        let jsStatus = pair("task-status-message-").js, nativeStatus = pair("task-status-message-").native
        XCTAssertEqual(pluginText(jsStatus), "Waiting on CI checks")
        XCTAssertEqual(pluginText(nativeStatus), "Waiting on CI checks")
        // Squeezed by the atoms' empty frames, the time wrapped or showed "…"; it must show in full.
        let createdWidth = ceil("Nov 8, 2026".size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width)
        for (time, counter) in [(pair("task-created-time-").js, pair("task-token-usage-counter-").js),
                                (pair("task-created-time-").native, pair("task-token-usage-counter-").native)] {
            XCTAssertTrue(time.waitForExistence(timeout: 5), "The item shows its created time.")
            XCTAssertEqual(pluginText(time), "Nov 8, 2026")
            XCTAssertGreaterThanOrEqual(time.frame.width, createdWidth - 1, "The created time shows in full, not truncated.")
            XCTAssertLessThanOrEqual(time.frame.maxX, counter.frame.midX, "The time sits left of the token counter.")
        }
        XCTAssertEqual(pair("task-created-time-").js.frame.width, pair("task-created-time-").native.frame.width, accuracy: 1,
                       "The time is as wide in the JavaScript item as in the native one.")
        attachScreenshot(named: "Task item: JavaScript beside native")

        let commit = jsSide.descendants(matching: .any).matching(identifier: "plugin-last-commit").firstMatch
        element("js-toggle-blocked").click()
        XCTAssertTrue(waitUntil({ self.pluginText(jsStatus) == "Blocked: 2 checks failing" }, timeout: 5), "Block ran the JavaScript handler.")
        XCTAssertEqual(pluginText(nativeStatus), "Waiting on CI checks", "The native item keeps its own state.")
        XCTAssertTrue(waitUntil({ self.pluginText(commit).hasPrefix("Commit 2: text, update, text → nodes ") }, timeout: 5),
                      "Blocking changed only the status message and the toggle's label: \(pluginText(commit))")
        XCTAssertEqual(pluginText(element("js-toggle-blocked")), "Unblock")
        attachScreenshot(named: "Task item: JavaScript item blocked")

        element("native-toggle-blocked").click()
        XCTAssertTrue(waitUntil({ self.pluginText(nativeStatus) == "Blocked: 2 checks failing" }, timeout: 5))
        XCTAssertEqual(jsStatus.frame.height, nativeStatus.frame.height, accuracy: 1, "Both blocked messages lay out the same.")

        let jsCard = pair("task-card-").js
        jsCard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).click()
        XCTAssertTrue(waitUntil({ self.pluginText(self.element("js-opened-count")) == "Opened 1 times" }, timeout: 5), "Clicking the card ran its onPress handler.")
        XCTAssertTrue(waitUntil({ self.pluginText(commit).hasPrefix("Commit 3: text → node ") }, timeout: 5), pluginText(commit))

        attachScreenshot(named: "Task item: both blocked")

        jsCard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).rightClick()
        let moveToDone = element("move-task-to-done-menu-item")
        XCTAssertTrue(moveToDone.waitToExist(timeout: 5), "The JavaScript card's context menu lists Move to Done.")
        XCTAssertTrue(element("rename-task-menu-item").exists && element("delete-task-menu-item").exists,
                      "It has the native card's menu items.")
        moveToDone.click()
        XCTAssertTrue(waitUntil({ self.pluginText(self.element("js-last-action")) == "Last: menu done" }, timeout: 5), "The menu item ran onMenu with its id.")
        XCTAssertTrue(waitUntil({ self.pluginText(commit).hasPrefix("Commit 4: text → node ") }, timeout: 5), pluginText(commit))
    }
    // case-contract: test_plugin_agents_info_renders_from_atoms_like_native | The Plugin Catalog's Agents Info page shows the Agents info section composed in JavaScript from atoms beside the native SwiftUI section the board uses, built from the same atoms and sample data: both show the Agents info title button (Expanded), a Claude block above a Codex block with the same account and plan rows, window rows (label, percent, usage bar and reset time), Codex's credits, its Near limit status and the updated hints, each at the same size in both, and the JavaScript tree uses only atoms (Disclosure, Panel, Meter, Stack, Text, Icon, Button, Spacer) with the board section's identifiers. Collapsing is the Disclosure atom's own: clicking the JavaScript title runs onToggle, whose state change is one commit that updates only the Disclosure's props and the readout (Last: collapse) while the blocks stay in the tree, the JavaScript blocks go away and its title reads Collapsed while the native section stays open, the native title collapses its own section to the same size, and expanding brings the blocks back (Last: expand). Signing Claude out in the JavaScript example replaces its window rows with a Log in button the same size as the native one, whose onPress runs in JavaScript (Last: login claude) and brings the rows back, and Codex's switch-account button runs its JavaScript handler with its provider (Last: switch codex) without re-rendering any block.
    func test_plugin_agents_info_renders_from_atoms_like_native() throws {
        launchApp(defaultParent: fixture.parent.path)
        clickPluginsMenuItem("Plugin Catalog")
        let example = catalogSidebarRow("plugin-catalog-agents-info")
        XCTAssertTrue(example.waitToExist(timeout: 15), "Plugins ▸ Plugin Catalog lists the Agents Info example.")
        example.click()
        let jsSide = element("plugin-catalog-js-agents-info")
        let nativeSide = element("plugin-catalog-native-agents-info")
        XCTAssertTrue(jsSide.waitToExist(timeout: 10), "The page shows the JavaScript Agents info section.")
        XCTAssertTrue(nativeSide.waitToExist(timeout: 10), "The page shows the native Agents info section.")
        XCTAssertFalse(element("plugin-error").exists, "The JavaScript section renders without errors.")

        // The board window behind the catalog shows the real Agents info section
        // (the Codex fixture is installed) with the same identifiers as the
        // JavaScript copy, so every lookup is scoped to its catalog column.
        func js(_ identifier: String) -> XCUIElement {
            jsSide.descendants(matching: .any).matching(identifier: identifier).firstMatch
        }
        func native(_ identifier: String) -> XCUIElement {
            nativeSide.descendants(matching: .any).matching(identifier: identifier).firstMatch
        }
        func pair(_ suffix: String) -> (js: XCUIElement, native: XCUIElement) {
            (js("agents-info\(suffix)"), native("native-agents-info\(suffix)"))
        }
        func assertSameSize(_ suffix: String) {
            let (js, native) = pair(suffix)
            XCTAssertTrue(js.waitToExist(timeout: 10), "The JavaScript section has agents-info\(suffix).")
            XCTAssertTrue(native.waitToExist(timeout: 10), "The native section has agents-info\(suffix).")
            XCTAssertEqual(js.frame.width, native.frame.width, accuracy: 1, "agents-info\(suffix) has the same width in both.")
            XCTAssertEqual(js.frame.height, native.frame.height, accuracy: 1, "agents-info\(suffix) has the same height in both.")
        }
        for suffix in ["", "-toggle", "-claude", "-codex", "-claude-account", "-codex-account", "-switch-claude", "-switch-codex",
                       "-claude-window-five_hour", "-claude-window-seven_day", "-codex-window-overage",
                       "-codex-credits", "-codex-status", "-claude-updated", "-codex-updated"] {
            assertSameSize(suffix)
        }
        let jsToggle = pair("-toggle").js, nativeToggle = pair("-toggle").native
        XCTAssertEqual(jsToggle.value as? String, "Expanded", "The section is open by default.")
        XCTAssertEqual(nativeToggle.value as? String, "Expanded")
        XCTAssertLessThanOrEqual(pair("-claude").js.frame.maxY, pair("-codex").js.frame.minY, "Claude's block sits above Codex's.")
        for side in [pair("").js, pair("").native] {
            XCTAssertTrue(side.descendants(matching: .any).matching(NSPredicate(format: "label =[c] %@", "Agents info")).firstMatch.exists, "The title reads Agents info.")
        }
        for (js, native) in [pair("-claude-account"), pair("-codex-status"), pair("-codex-credits"), pair("-claude-updated")] {
            XCTAssertEqual(pluginText(js), pluginText(native), "Both show the same text.")
        }
        XCTAssertEqual(pluginText(pair("-claude-account").js), "claude@example.com Team", "The account and plan share the row below the name.")
        XCTAssertEqual(pluginText(pair("-codex-status").js), "Near limit")
        XCTAssertEqual(pluginText(pair("-codex-credits").js), "Credits available")
        let fiveHour = accessibleLabelOrValue(of: pair("-claude-window-five_hour").js)
        XCTAssertTrue(fiveHour.contains("5h") && fiveHour.contains("5%") && fiveHour.contains("Resets in 3h 24m"), "A window row reads as one element: \(fiveHour)")
        XCTAssertEqual(fiveHour, accessibleLabelOrValue(of: pair("-claude-window-five_hour").native), "Both window rows read the same.")
        attachScreenshot(named: "Agents info: JavaScript beside native")

        // Collapsing is the Disclosure atom's own; each side keeps its own state.
        let commit = jsSide.descendants(matching: .any).matching(identifier: "plugin-last-commit").firstMatch
        let expandedHeight = pair("").js.frame.height
        jsToggle.click()
        XCTAssertTrue(waitUntil({ !js("agents-info-claude").exists && !js("agents-info-codex").exists }, timeout: 5),
                      "Collapsing hides the JavaScript blocks.")
        XCTAssertEqual(jsToggle.value as? String, "Collapsed")
        XCTAssertLessThan(pair("").js.frame.height, expandedHeight, "The collapsed section is only its title.")
        XCTAssertTrue(pair("-claude").native.exists, "The native section stays open.")
        XCTAssertEqual(nativeToggle.value as? String, "Expanded")
        XCTAssertTrue(waitUntil({ self.pluginText(js("js-last-action")) == "Last: collapse" }, timeout: 5), "The title ran onToggle.")
        XCTAssertTrue(waitUntil({ self.pluginText(commit).hasPrefix("Commit 2: update, text → nodes ") }, timeout: 5),
                      "Collapsing changed only the Disclosure's props and the readout: \(pluginText(commit))")
        attachScreenshot(named: "Agents info: JavaScript section collapsed, native open")
        nativeToggle.click()
        XCTAssertTrue(waitUntil({ !native("native-agents-info-claude").exists }, timeout: 5), "The native title collapses its own section.")
        XCTAssertEqual(nativeToggle.value as? String, "Collapsed")
        assertSameSize("")
        attachScreenshot(named: "Agents info: both sections collapsed")
        jsToggle.click()
        nativeToggle.click()
        XCTAssertTrue(js("agents-info-claude").waitToExist(timeout: 5), "Expanding brings the JavaScript blocks back.")
        XCTAssertTrue(native("native-agents-info-claude").waitToExist(timeout: 5), "Expanding brings the native blocks back.")
        XCTAssertEqual(jsToggle.value as? String, "Expanded")
        XCTAssertTrue(waitUntil({ self.pluginText(js("js-last-action")) == "Last: expand" }, timeout: 5))
        XCTAssertTrue(waitUntil({ self.pluginText(commit).hasPrefix("Commit 3: update, text → nodes ") }, timeout: 5), pluginText(commit))
        XCTAssertEqual(pair("").js.frame.height, expandedHeight, accuracy: 1, "Expanded again, the section is its full height.")

        // A signed-out agent shows Log in instead of its usage.
        js("js-toggle-signed-out").click()
        native("native-toggle-signed-out").click()
        XCTAssertTrue(js("agents-info-login-claude").waitToExist(timeout: 5), "A signed-out Claude shows Log in.")
        XCTAssertTrue(native("native-agents-info-login-claude").waitToExist(timeout: 5))
        XCTAssertFalse(js("agents-info-claude-window-five_hour").exists, "A signed-out agent shows no usage.")
        assertSameSize("-login-claude")
        assertSameSize("-claude")
        attachScreenshot(named: "Agents info: Claude signed out in both")
        js("agents-info-login-claude").click()
        XCTAssertTrue(waitUntil({ self.pluginText(js("js-last-action")) == "Last: login claude" }, timeout: 5), "Log in ran its JavaScript handler.")
        XCTAssertTrue(js("agents-info-claude-window-five_hour").waitToExist(timeout: 5), "Logged in again, Claude's usage is back.")
        XCTAssertFalse(js("agents-info-login-claude").exists)
        XCTAssertTrue(waitUntil({ self.pluginText(commit).hasPrefix("Commit 5: ") }, timeout: 5), "Log in is one commit: \(pluginText(commit))")
        attachScreenshot(named: "Agents info: Claude logged in again in JavaScript")

        pair("-switch-codex").js.click()
        XCTAssertTrue(waitUntil({ self.pluginText(js("js-last-action")) == "Last: switch codex" }, timeout: 5),
                      "The switch-account button ran its JavaScript handler with its provider.")
        XCTAssertTrue(waitUntil({ self.pluginText(commit).hasPrefix("Commit 6: text → node ") }, timeout: 5),
                      "Switching changed only the readout: \(pluginText(commit))")
        XCTAssertEqual(pluginText(native("native-last-action")), "Last: expand", "The native section keeps its own state.")
    }
    // case-contract: test_plugin_kanban_column_renders_from_atoms_like_native | The Plugin Catalog's Kanban Column page shows the board's columns composed in JavaScript from atoms beside the native SwiftUI columns the board uses, built from the same atoms and sample models (a column's cards are native and not part of the page): each side shows a Backlog column with its Add button and its empty state, an In Progress column with a count of 2 and no empty state, a Blocked column with the Waiting for user intervention notice and its empty state, a Waiting Response column washed in its purple accent (a tint Panel filling the column with a soft fill and hairline border in the accent, its pixels visibly purple beside the other columns, and its count in the accent) and its empty state, and a Done column with its empty state, with the board's identifiers (column-heading, column-count, add-backlog-task-button, empty-state, blocked-waiting-indicator), and every one is the same size in both and reads the same text (the uppercased title, the count, No tasks yet with Create a task to get started or Drop a task here). The JavaScript tree uses only atoms (Panel, Stack, Text, Icon, Label, Button, Spacer): each column is a Panel holding the header (a status dot Panel, the title, a Spacer, the count Panel, and for the Backlog the Add button), then the notice and the empty state, which is a dashed Panel with centered content; only the tinted column nests that content in its tint Panel. Pressing the JavaScript Add button runs its onPress in JavaScript (Last: add) as one commit that changes only the readout, and the native Add button runs its own handler without touching the JavaScript side. On the board itself, every column keeps its column-<status>, column-heading-<status> and empty-state-<status> identifiers, the Backlog its Add button and the Blocked column its notice, now built from the same atoms.
    func test_plugin_kanban_column_renders_from_atoms_like_native() throws {
        launchApp(defaultParent: fixture.parent.path)
        clickPluginsMenuItem("Plugin Catalog")
        let example = catalogSidebarRow("plugin-catalog-kanban-column")
        XCTAssertTrue(example.waitToExist(timeout: 15), "Plugins ▸ Plugin Catalog lists the Kanban Column example.")
        example.click()
        let jsSide = element("plugin-catalog-js-kanban-column")
        let nativeSide = element("plugin-catalog-native-kanban-column")
        XCTAssertTrue(jsSide.waitToExist(timeout: 10), "The page shows the JavaScript columns.")
        XCTAssertTrue(nativeSide.waitToExist(timeout: 10), "The page shows the native columns.")
        XCTAssertFalse(element("plugin-error").exists, "The JavaScript columns render without errors.")

        // The board window behind the catalog has the same identifiers, so every
        // lookup is scoped to its catalog column.
        func js(_ identifier: String) -> XCUIElement {
            jsSide.descendants(matching: .any).matching(identifier: identifier).firstMatch
        }
        func native(_ identifier: String) -> XCUIElement {
            nativeSide.descendants(matching: .any).matching(identifier: identifier).firstMatch
        }
        func assertSameSize(_ identifier: String) {
            let jsElement = js(identifier), nativeElement = native("native-\(identifier)")
            XCTAssertTrue(jsElement.waitToExist(timeout: 10), "The JavaScript column has \(identifier).")
            XCTAssertTrue(nativeElement.waitToExist(timeout: 10), "The native column has \(identifier).")
            XCTAssertEqual(jsElement.frame.width, nativeElement.frame.width, accuracy: 1, "\(identifier) has the same width in both.")
            XCTAssertEqual(jsElement.frame.height, nativeElement.frame.height, accuracy: 1, "\(identifier) has the same height in both.")
        }
        for key in ["backlog", "in-progress", "blocked", "waiting-response", "done"] {
            for identifier in ["column-\(key)", "column-heading-\(key)", "column-count-\(key)"] {
                assertSameSize(identifier)
            }
        }
        for identifier in ["add-backlog-task-button", "empty-state-backlog", "blocked-waiting-indicator", "empty-state-blocked",
                           "empty-state-waiting-response", "empty-state-done"] {
            assertSameSize(identifier)
        }
        // Only the Waiting Response column is washed purple, on both sides. It is
        // second in the sample, so its top and its neighbours' sit in the window.
        let catalogPage = app.scrollViews.containing(.any, identifier: "plugin-catalog-js-kanban-column").firstMatch
        for (side, prefix) in [(js, ""), (native, "native-")] {
            let waitingTint = try columnPurpleness(side("\(prefix)column-waiting-response"), visibleIn: catalogPage)
            for key in ["backlog", "in-progress"] {
                let neutral = try columnPurpleness(side("\(prefix)column-\(key)"), visibleIn: catalogPage)
                XCTAssertGreaterThan(waitingTint, neutral + 0.012, "\(prefix)column-waiting-response reads purple beside \(key) (\(waitingTint) vs \(neutral)).")
            }
        }
        XCTAssertFalse(js("empty-state-in-progress").exists, "A column with tasks has no empty state.")
        XCTAssertFalse(native("native-empty-state-in-progress").exists)
        XCTAssertEqual(pluginText(js("column-heading-in-progress")), "IN PROGRESS")
        XCTAssertEqual(pluginText(js("column-heading-in-progress")), pluginText(native("native-column-heading-in-progress")), "Both show the same title.")
        for key in ["backlog", "in-progress", "blocked", "waiting-response", "done"] {
            XCTAssertEqual(pluginText(js("column-count-\(key)")), pluginText(native("native-column-count-\(key)")), "Both show the same count for \(key).")
        }
        XCTAssertEqual(pluginText(js("column-count-in-progress")), "2")
        for key in ["backlog", "blocked", "waiting-response", "done"] {
            let jsLabel = accessibleLabelOrValue(of: js("empty-state-\(key)"))
            XCTAssertTrue(jsLabel.contains("No tasks yet"), "The \(key) empty state reads No tasks yet: \(jsLabel)")
        }
        XCTAssertTrue(accessibleLabelOrValue(of: js("empty-state-backlog")).contains("Create a task to get started"))
        XCTAssertTrue(accessibleLabelOrValue(of: js("empty-state-done")).contains("Drop a task here"))
        XCTAssertTrue(jsSide.staticTexts["Waiting for user intervention"].exists, "The JavaScript Blocked column shows its notice.")
        XCTAssertTrue(nativeSide.staticTexts["Waiting for user intervention"].exists, "The native Blocked column shows its notice.")
        XCTAssertLessThanOrEqual(js("column-backlog").frame.maxY, js("column-in-progress").frame.minY, "The columns stack in the order of the sample.")
        attachScreenshot(named: "Kanban columns: JavaScript beside native")

        // Pressing Add runs the pressed side's own handler.
        let commit = jsSide.descendants(matching: .any).matching(identifier: "plugin-last-commit").firstMatch
        js("add-backlog-task-button").click()
        XCTAssertTrue(waitUntil({ self.pluginText(js("js-last-action")) == "Last: add" }, timeout: 5), "Add ran its JavaScript handler.")
        XCTAssertTrue(waitUntil({ self.pluginText(commit).hasPrefix("Commit 2: text → node ") }, timeout: 5),
                      "Pressing Add changed only the readout: \(pluginText(commit))")
        XCTAssertEqual(pluginText(native("native-last-action")), "Last: none", "The native columns keep their own state.")
        native("native-add-backlog-task-button").click()
        XCTAssertTrue(waitUntil({ self.pluginText(native("native-last-action")) == "Last: add" }, timeout: 5), "The native Add button ran its handler.")
        attachScreenshot(named: "Kanban columns: Add pressed in both")
    }
    // case-contract: test_plugin_card_uses_default_content_padding | The Plugin Catalog's Card page gives a Card with no padding prop its 14-point default, while `padding: 0` removes it. `plugin render --page Card` omits the default common padding but keeps the explicit zero override on the second Card, and in the UI two otherwise identical cards have the same width while the default-padded card is 28 points taller; each card keeps its own content inside the surface.
    func test_plugin_card_uses_default_content_padding() throws {
        launchApp(defaultParent: fixture.parent.path)
        clickPluginsMenuItem("Plugin Catalog")
        XCTAssertTrue(element("plugin-catalog-atom-Card").waitToExist(timeout: 15))
        catalogSidebarRow("plugin-catalog-atom-Card").click()
        let defaultCard = element("card-demo"), zeroCard = element("card-zero-padding")
        XCTAssertTrue(defaultCard.waitToExist(timeout: 10), "The catalog Card omits padding and uses the default.")
        XCTAssertTrue(zeroCard.waitToExist(timeout: 10), "The comparison Card explicitly sets padding to zero.")
        XCTAssertEqual(defaultCard.frame.width, zeroCard.frame.width, accuracy: 1, "Both Cards have the same width and one-line content.")
        XCTAssertEqual(defaultCard.frame.height - zeroCard.frame.height, 28, accuracy: 2, "With identical one-line content, the default Card adds 14 points on each vertical edge.")
        attachElementScreenshot(defaultCard, named: "Card atom: default 14-point content padding")
        attachElementScreenshot(zeroCard, named: "Card atom: explicit zero padding")
    }
    // case-contract: test_plugin_presentation_atoms_open_modal_page_and_side_panel | Plugins present UI the three ways the board does, each a controlled atom whose first child is what it is presented from and stays laid out as usual. On the Plugin Catalog's Modal page, the Open modal button runs onPress (Last: open) and opens a 320-point sheet over the window that starts with the standard header its title props describe (its icon, the Modal title and its subtitle, and a close button) above content that brings no padding of its own yet sits 24 points in from the sheet's edges (the default inset) and a default spacing below the header, with a Done button; Done closes it (Last: done), the header's close button closes it through onDismiss (Last: dismiss), and Escape closes it again through onDismiss. On the Popover page the anchor opens a popover whose content, again with no padding of its own, is inset 14 points by default and spaced apart, and Escape dismisses it; a titled Modal and a second Popover each override inset to 0 and spacing to 4, which the UI geometry and `plugin render` tree both confirm. On the Page page, Open page (Last: open) slides a page over the whole 420 by 220 point view below it, covering that view's frame and showing its title, and its Back button closes it (Last: back), uncovering the view. On the SidePanel page, Open trailing (Last: open trailing) slides a 200-point panel as tall as the 480 by 240 point view below it in over that view's trailing edge, Open leading (Last: open leading) over its leading edge, and the panel's close button closes it (Last: close). `plugin render` keeps each atom's presented content in the tree after its first child, and opening or closing is one commit that updates only the presentation atom's props and the readout. `plugin render` reports the Modal's title, subtitle and icon with no inset or spacing set and the Popover's content with no Stack of its own, and an explicit inset and spacing override the defaults with no errors. Only a Modal raises onDismiss: a Page or SidePanel given an onDismiss handler, or a Modal, Page or SidePanel without isPresented or with a mistyped width or edge, or a mistyped Modal title or inset or Popover spacing, is reported in errors.
    func test_plugin_presentation_atoms_open_modal_page_and_side_panel() throws {
        launchApp(defaultParent: fixture.parent.path)
        clickPluginsMenuItem("Plugin Catalog")
        func open(_ atom: String) {
            let row = catalogSidebarRow("plugin-catalog-atom-\(atom)")
            row.click()
            let title = element("plugin-catalog-title")
            XCTAssertTrue(waitUntil({ title.exists && self.pluginText(title) == atom }, timeout: 10), "Selecting \(atom) shows its page.")
            XCTAssertFalse(element("plugin-error").exists, "The \(atom) page renders without errors.")
        }

        // Modal: a sheet over the window with the standard header and padded
        // content, closed by its Done button, its close button or Escape.
        open("Modal")
        let modalLast = element("modal-last")
        XCTAssertFalse(element("modal-demo-title").exists, "The modal starts closed.")
        XCTAssertLessThan(element("modal-open").frame.width, 200, "The Modal's width sizes its sheet, not the button it is presented from.")
        element("modal-open").click()
        let modalTitle = element("modal-demo-title")
        XCTAssertTrue(modalTitle.waitToExist(timeout: 5), "Open modal presents the sheet with its standard header.")
        XCTAssertEqual(pluginText(modalLast), "Last: open")
        XCTAssertEqual(pluginText(modalTitle), "Modal title", "The header shows the Modal's title.")
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitToExist(timeout: 5), "The modal is a sheet over the catalog window.")
        let modalContent = element("modal-demo"), modalBody = element("modal-body"), modalClose = element("modal-demo-close")
        // The content column is one accessibility container, so its frame is its
        // children's; the sheet window is the modal's 320-point width.
        XCTAssertEqual(sheet.frame.width, 320, accuracy: 1, "The sheet is the modal's 320-point width.")
        XCTAssertTrue(sheet.frame.contains(element("modal-done").frame), "The Done button is in the sheet.")
        let modalSubtitle = sheet.staticTexts["A standard header over padded content"]
        XCTAssertTrue(modalSubtitle.exists, "The header shows the subtitle.")
        XCTAssertEqual(modalBody.frame.minX - sheet.frame.minX, 24, accuracy: 1.5, "The content is inset 24 points by default: \(modalBody.frame) in \(sheet.frame)")
        XCTAssertEqual(modalTitle.frame.minY - sheet.frame.minY, 24, accuracy: 4, "The header is inset from the top too: \(modalTitle.frame) in \(sheet.frame)")
        XCTAssertGreaterThan(modalTitle.frame.minX, modalBody.frame.minX + 20, "The header's icon sits before the title.")
        XCTAssertEqual(modalBody.frame.minY - modalSubtitle.frame.maxY, 16, accuracy: 2, "The content follows the subtitle by the default 16-point spacing.")
        XCTAssertEqual(sheet.frame.maxX - modalClose.frame.maxX, 24, accuracy: 8, "The close button sits at the header's trailing inset: \(modalClose.frame) in \(sheet.frame)")
        attachScreenshot(named: "Modal atom: standard header over padded content")
        attachElementScreenshot(modalContent, named: "Modal atom: sheet content")
        element("modal-done").click()
        XCTAssertTrue(waitUntil({ !modalTitle.exists && self.pluginText(modalLast) == "Last: done" }, timeout: 5), "Done closes the sheet through its handler.")
        element("modal-open").click()
        XCTAssertTrue(modalTitle.waitToExist(timeout: 5), "The modal opens again.")
        modalClose.click()
        XCTAssertTrue(waitUntil({ !modalTitle.exists && self.pluginText(modalLast) == "Last: dismiss" }, timeout: 5), "The header's close button runs onDismiss, which closes the sheet.")
        element("modal-open").click()
        XCTAssertTrue(modalTitle.waitToExist(timeout: 5), "The modal opens again.")
        XCTAssertEqual(pluginText(modalLast), "Last: open")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil({ !modalTitle.exists && self.pluginText(modalLast) == "Last: dismiss" }, timeout: 5), "Escape runs onDismiss, which closes the sheet.")
        element("modal-override-open").click()
        let compactSheet = app.sheets.firstMatch
        let compactTitle = element("modal-override-title"), compactBody = element("modal-override-body")
        XCTAssertTrue(compactTitle.waitToExist(timeout: 5), "The explicit Modal override opens.")
        XCTAssertTrue(compactSheet.waitToExist(timeout: 5))
        let compactHeaderTop = compactTitle.frame.minY - compactSheet.frame.minY
        XCTAssertEqual(compactHeaderTop, 13.5, accuracy: 2, "The zero inset leaves only the sheet's native top margin.")
        let compactContentGap = compactBody.frame.minY - compactTitle.frame.maxY
        XCTAssertEqual(compactContentGap, 15, accuracy: 2, "The 4-point spacing override plus native sheet margin leaves 15 points between header and body.")
        attachElementScreenshot(compactSheet, named: "Modal atom: explicit inset and spacing overrides")
        element("modal-override-close").click()
        XCTAssertTrue(waitForDisappearance(compactTitle, timeout: 5), "The overridden Modal's close button dismisses the sheet.")

        // Popover: its content padded and spaced by default.
        open("Popover")
        element("popover-anchor").click()
        let popoverTitle = element("popover-title"), popoverBody = element("popover-body")
        XCTAssertTrue(popoverTitle.waitToExist(timeout: 5), "The anchor opens the popover.")
        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.waitToExist(timeout: 5))
        XCTAssertEqual(popoverBody.frame.minY - popoverTitle.frame.maxY, 10, accuracy: 2, "The popover's children use the 10-point default spacing.")
        let defaultPopoverHeight = popover.frame.height
        attachScreenshot(named: "Popover atom: padded content")
        attachElementScreenshot(popover, named: "Popover atom: content inset 14 points")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil({ !popoverTitle.exists && self.pluginText(self.element("popover-last")) == "Last: dismiss" }, timeout: 5), "Escape dismisses the popover.")
        element("popover-override-anchor").click()
        let overridePopover = app.popovers.firstMatch
        let overrideTitle = element("popover-override-title"), overrideBody = element("popover-override-body")
        XCTAssertTrue(overrideTitle.waitToExist(timeout: 5), "The second Popover opens with explicit inset and spacing overrides.")
        XCTAssertTrue(overridePopover.waitToExist(timeout: 5))
        XCTAssertEqual(defaultPopoverHeight - overridePopover.frame.height, 34, accuracy: 3, "Matching content and arrow edges isolate 28 points of default inset plus the 6-point spacing difference.")
        XCTAssertEqual(overrideBody.frame.minY - overrideTitle.frame.maxY, 4, accuracy: 2, "The explicit spacing override is applied.")
        attachElementScreenshot(overridePopover, named: "Popover atom: explicit inset and spacing overrides")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForDisappearance(overrideTitle, timeout: 5), "Escape dismisses the overridden Popover too.")

        // Page: slides over all of the view below it, closed by its Back button.
        open("Page")
        let pageBase = element("page-base")
        let page = element("page-demo")
        XCTAssertTrue(pageBase.waitToExist(timeout: 5))
        XCTAssertEqual(pageBase.frame.width, 420, accuracy: 1)
        XCTAssertEqual(pageBase.frame.height, 220, accuracy: 1)
        XCTAssertFalse(page.exists, "The page starts closed.")
        element("page-open").click()
        XCTAssertTrue(element("page-title").waitToExist(timeout: 5), "Open page slides the page in.")
        XCTAssertEqual(pluginText(element("page-last")), "Last: open")
        XCTAssertTrue(waitUntil({ abs(page.frame.minX - pageBase.frame.minX) < 1 }, timeout: 5), "The page finishes sliding in over the view.")
        XCTAssertEqual(page.frame.width, pageBase.frame.width, accuracy: 1, "The page covers the view's width.")
        XCTAssertEqual(page.frame.height, pageBase.frame.height, accuracy: 1, "The page covers the view's height.")
        XCTAssertEqual(page.frame.minY, pageBase.frame.minY, accuracy: 1)
        attachScreenshot(named: "Page atom: page over its view")
        element("page-back").click()
        XCTAssertTrue(waitUntil({ !page.exists && self.pluginText(self.element("page-last")) == "Last: back" }, timeout: 5), "Back closes the page.")
        XCTAssertTrue(element("page-open").isHittable, "The view is uncovered again.")

        // SidePanel: slides in over either edge of the view below it; its controls are reachable.
        func pressPanelClose() {
            let close = element("side-panel-close")
            XCTAssertTrue(close.waitToExist(timeout: 5))
            XCTAssertTrue(waitUntil({ close.isHittable }, timeout: 5), "The panel's close button is hittable, so assistive clients reach it.")
            close.click()
        }
        open("SidePanel")
        let panelBase = element("side-panel-base")
        let panel = element("side-panel-demo")
        XCTAssertTrue(panelBase.waitToExist(timeout: 5))
        XCTAssertFalse(panel.exists, "The panel starts closed.")
        element("side-panel-open-trailing").click()
        XCTAssertTrue(element("side-panel-title").waitToExist(timeout: 5), "Open trailing slides the panel in.")
        XCTAssertEqual(pluginText(element("side-panel-last")), "Last: open trailing")
        XCTAssertTrue(waitUntil({ abs(panel.frame.maxX - panelBase.frame.maxX) < 1 }, timeout: 5), "The panel rests along the view's trailing edge.")
        XCTAssertEqual(panel.frame.width, 200, accuracy: 1, "The panel is its 200-point width.")
        XCTAssertEqual(panel.frame.height, panelBase.frame.height, accuracy: 1, "The panel is as tall as the view.")
        XCTAssertEqual(panel.frame.minY, panelBase.frame.minY, accuracy: 1)
        attachScreenshot(named: "SidePanel atom: trailing panel")
        pressPanelClose()
        XCTAssertTrue(waitUntil({ !panel.exists && self.pluginText(self.element("side-panel-last")) == "Last: close" }, timeout: 5), "The close button closes the panel.")
        element("side-panel-open-leading").click()
        XCTAssertTrue(element("side-panel-title").waitToExist(timeout: 5), "Open leading slides the panel in.")
        XCTAssertEqual(pluginText(element("side-panel-last")), "Last: open leading")
        XCTAssertTrue(waitUntil({ abs(panel.frame.minX - panelBase.frame.minX) < 1 }, timeout: 5), "The panel rests along the view's leading edge.")
        XCTAssertEqual(panel.frame.width, 200, accuracy: 1)
        attachScreenshot(named: "SidePanel atom: leading panel")
        pressPanelClose()
        XCTAssertTrue(waitUntil({ !panel.exists }, timeout: 5), "The close button closes the leading panel too.")
    }
}
