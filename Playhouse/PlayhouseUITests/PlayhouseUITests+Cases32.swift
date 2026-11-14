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
    // case-contract: test_debug_highlight_native_atoms_outlines_atoms | Debug ▸ Highlight Native Atoms outlines every atom view without moving it, so UI built from plugin atoms reads apart from plain SwiftUI. `plugin render` reports the container atoms (Stack, Panel, Card, Scroll, Disclosure, Overlay, Popover, Modal, Page, SidePanel), every one of them a known atom, and every other atom is a leaf. With the item off no atom carries an outline; turned on, the board's task card is outlined live, its Card as a container and its Text as a leaf, at the same frame as with it off, and the Plugin Catalog outlines each atom type it renders, including Spacer, Card and PillPicker, as a container or a leaf to match, the Card and the PillPicker keep the same frames as with it off, and hovering a Text atom shows a label naming its type that goes away when the pointer leaves. The setting persists: after a relaunch the reopened catalog is still outlined, and turning the item off removes every outline.
    func test_debug_highlight_native_atoms_outlines_atoms() throws {
        executionTimeAllowance = 360 // It opens and checks every atom's catalog page.
        launchApp(defaultParent: fixture.parent.path)
        let rendered = try XCTUnwrap(try runCLI(["plugin", "render", "--page", "Card"])["result"] as? [String: Any])
        let atoms = try XCTUnwrap(rendered["atoms"] as? [String])
        let containers = Set(try XCTUnwrap(rendered["containerAtoms"] as? [String]))
        XCTAssertEqual(containers, ["Stack", "Panel", "Card", "Scroll", "Disclosure", "Overlay", "Popover", "Modal", "Page", "SidePanel"], "Only the structural atoms are containers.")
        XCTAssertTrue(containers.isSubset(of: Set(atoms)), "Every container is a known atom.")
        let highlight = NSPredicate(format: "identifier IN %@", ["atom-highlight-container", "atom-highlight-leaf"])
        func outlines(in root: XCUIElement, _ atom: String? = nil) -> XCUIElementQuery {
            let all = root.descendants(matching: .any).matching(highlight)
            return atom.map { all.matching(NSPredicate(format: "label == %@", $0)) } ?? all
        }

        // The board's task card is the native task item, built from atoms.
        let created = try XCTUnwrap(try runCLI(["task", "create", "--title", "Highlighted card", "--prompt", "Fixture task description.", "--root", fixture.primary.path])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String).uppercased()
        let boardCard = element("task-card-\(taskID)")
        XCTAssertTrue(boardCard.waitToExist(timeout: 15), "The board shows the task card.")
        XCTAssertEqual(outlines(in: app).count, 0, "With the item off no atom carries an outline.")
        let boardCardFrame = boardCard.frame
        attachScreenshot(named: "Highlight Native Atoms off: board")
        clickDebugHighlightNativeAtoms()
        XCTAssertTrue(waitUntil({ outlines(in: self.app, "Card").count > 0 }, timeout: 5), "Turning the item on outlines the board's task card live.")
        XCTAssertEqual(outlines(in: app, "Card").firstMatch.identifier, "atom-highlight-container", "The task card's Card is outlined as a container.")
        XCTAssertTrue(outlines(in: app, "Text").count > 0, "The task card's Text atoms are outlined.")
        XCTAssertEqual(outlines(in: app, "Text").firstMatch.identifier, "atom-highlight-leaf", "A Text atom is outlined as a leaf.")
        XCTAssertEqual(boardCard.frame, boardCardFrame, "The outline doesn't move or resize the task card.")
        attachScreenshot(named: "Highlight Native Atoms on: board task card")
        clickDebugHighlightNativeAtoms()
        XCTAssertTrue(waitUntil({ outlines(in: self.app).count == 0 }, timeout: 5), "Turning the item off removes the board's outlines.")

        clickPluginsMenuItem("Plugin Catalog")
        XCTAssertTrue(element("plugin-catalog-atom-Card").waitToExist(timeout: 15), "Plugins ▸ Plugin Catalog opens the catalog.")
        let catalog = app.windows.matching(NSPredicate(format: "title == 'Plugin Catalog'")).firstMatch
        XCTAssertTrue(catalog.waitToExist(timeout: 5), "The catalog has its own window.")
        catalogSidebarRow("plugin-catalog-atom-Card").click()
        let card = element("card-demo")
        XCTAssertTrue(card.waitToExist(timeout: 10))
        XCTAssertEqual(outlines(in: catalog).count, 0, "With the item off the catalog's atoms carry no outline.")
        let cardFrame = card.frame
        catalogSidebarRow("plugin-catalog-atom-PillPicker").click()
        let picker = element("pill-picker")
        XCTAssertTrue(picker.waitToExist(timeout: 10))
        XCTAssertEqual(outlines(in: catalog).count, 0)
        let pickerFrame = picker.frame
        attachScreenshot(named: "Highlight Native Atoms off: PillPicker page")

        clickDebugHighlightNativeAtoms()
        XCTAssertTrue(waitUntil({ outlines(in: catalog).count > 0 }, timeout: 5), "Turning the item on outlines the catalog's atoms live.")
        XCTAssertEqual(picker.frame, pickerFrame, "The outline doesn't move or resize the PillPicker.")
        attachScreenshot(named: "Highlight Native Atoms on: PillPicker page")

        var roles: [String: String] = [:]
        for atom in atoms {
            catalogSidebarRow("plugin-catalog-atom-\(atom)").click()
            let title = element("plugin-catalog-title")
            XCTAssertTrue(waitUntil({ title.exists && self.pluginText(title) == atom }, timeout: 10), "Selecting \(atom) shows its page.")
            XCTAssertTrue(element("plugin-last-commit").waitToExist(timeout: 10), "The \(atom) page rendered.")
            XCTAssertTrue(waitUntil({ outlines(in: catalog, atom).count > 0 }, timeout: 5), "The \(atom) page outlines its \(atom) atom.")
            for outline in outlines(in: catalog).allElementsBoundByIndex {
                let role = outline.identifier.replacingOccurrences(of: "atom-highlight-", with: "")
                if let earlier = roles[outline.label] {
                    XCTAssertEqual(role, earlier, "Every \(outline.label) outline has one role.")
                }
                roles[outline.label] = role
            }
            if atom == "Card" {
                XCTAssertTrue(card.waitToExist(timeout: 5))
                XCTAssertEqual(card.frame, cardFrame, "The outline doesn't move or resize the Card.")
                attachScreenshot(named: "Highlight Native Atoms on: Card page")
            }
            if atom == "Spacer" {
                attachScreenshot(named: "Highlight Native Atoms on: Spacer page")
            }
        }
        for atom in atoms {
            XCTAssertEqual(roles[atom], containers.contains(atom) ? "container" : "leaf", "\(atom) is outlined as a \(containers.contains(atom) ? "container" : "leaf").")
        }

        catalogSidebarRow("plugin-catalog-atom-Card").click()
        let pressed = element("card-pressed")
        XCTAssertTrue(pressed.waitToExist(timeout: 10))
        let hoverLabels = app.descendants(matching: .any).matching(identifier: "atom-hover-label")
        let catalogTitle = element("plugin-catalog-title")
        catalogTitle.hover()
        XCTAssertTrue(waitUntil({ hoverLabels.count == 0 }, timeout: 5), "No type label shows while the pointer is off the atoms.")
        // The Text's outline covers it for XCUITest's hittability check (not for
        // the pointer: the outline doesn't hit-test), so hover by coordinate.
        pressed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        XCTAssertTrue(waitUntil({ hoverLabels.allElementsBoundByIndex.contains { self.pluginText($0) == "Text" } }, timeout: 5),
                      "Hovering a Text atom shows a label naming its type.")
        attachScreenshot(named: "Highlight Native Atoms on: hovering a Text atom")
        catalogTitle.hover()
        XCTAssertTrue(waitUntil({ hoverLabels.count == 0 }, timeout: 5), "The type label goes away when the pointer leaves the atom.")

        relaunchApp()
        clickPluginsMenuItem("Plugin Catalog")
        XCTAssertTrue(element("plugin-catalog-atom-Card").waitToExist(timeout: 15))
        catalogSidebarRow("plugin-catalog-atom-Card").click()
        XCTAssertTrue(element("card-demo").waitToExist(timeout: 10))
        let relaunchedCatalog = app.windows.matching(NSPredicate(format: "title == 'Plugin Catalog'")).firstMatch
        XCTAssertTrue(waitUntil({ outlines(in: relaunchedCatalog).count > 0 }, timeout: 5), "After a relaunch the catalog is still outlined.")
        attachScreenshot(named: "Highlight Native Atoms still on after relaunch")
        clickDebugHighlightNativeAtoms()
        XCTAssertTrue(waitUntil({ outlines(in: self.app).count == 0 }, timeout: 5), "Turning the item off removes every outline.")
    }
    // case-contract: test_plugin_skills_page_renders_from_atoms_like_native | The Plugin Catalog's Skills Page shows the Skills page's header and skill gallery composed in JavaScript from atoms above the native SwiftUI header and gallery the Skills page uses, built from the same atoms and sample data, each opened by the composer's Skills button (the same plain Button atom with the sparkles icon, labelled Skills). Both show the back button, the Skills, Rules & MCP title, the Skills | Rules | MCP and Repo | Global | Built-in segmented pickers, the search field and New Skill, the hint, a repository section whose skill rows show their name, provider, Conflict and Invalid badges, description, issue and location, a small Fix with Agent button on a broken skill, the mini switch, a small Use button that is disabled for a skill no provider can use, and the actions menu, and an empty repository's empty state, each at the same size in both, and the JavaScript tree uses only atoms (Panel, Stack, Text, Icon, Label, Button, Spacer, Divider, Scroll, Segmented, TextField, Toggle, Menu, PressArea) with the Skills page's identifiers. Choosing Global in the JavaScript source picker runs onChange (Last: tab global) and shows the Linked and switched-off global skills while the native page stays on Repo. Clicking a JavaScript switch runs onToggle (Last: toggle release-notes off), which turns it off and disables its Use button, and Use runs its handler (Last: use release-notes) without re-rendering any row. Clicking a skill's text runs onPress (Last: open release-notes); pressing and holding it runs onLongPress, which starts selecting (Last: select release-notes): its row shows a checked checkbox and the accent highlight, the rows' own controls hide, built-in skills show no checkbox, and the header shows 1 selected with Fix with Agent, Delete and Done; a click on another row adds it (2 selected), and Done ends selecting (Last: done selecting). The actions menu runs onMenu with the chosen item's id (Last: menu release-notes edit), typing in the search runs onChange with the text, choosing Rules hides the source picker and the search, and the back button closes the JavaScript page (Last: back) while the native one stays open, until the Skills button opens it again (Last: open). The search field raises no onPress, so pressing it is refused as invalid_argument.
    func test_plugin_skills_page_renders_from_atoms_like_native() throws {
        launchApp(defaultParent: fixture.parent.path)
        clickPluginsMenuItem("Plugin Catalog")
        let example = catalogSidebarRow("plugin-catalog-skills-page")
        XCTAssertTrue(example.waitToExist(timeout: 15), "Plugins ▸ Plugin Catalog lists the Skills Page example.")
        example.click()
        let jsSide = element("plugin-catalog-js-skills-page")
        let nativeSide = element("plugin-catalog-native-skills-page")
        XCTAssertTrue(jsSide.waitToExist(timeout: 10), "The page shows the JavaScript Skills page.")
        XCTAssertTrue(nativeSide.waitToExist(timeout: 10), "The page shows the native Skills page.")
        XCTAssertFalse(element("plugin-error").exists, "The JavaScript page renders without errors.")
        XCTAssertFalse(element("plugin-node-error").exists, "Every node on the JavaScript page has a registered atom.")

        func js(_ identifier: String) -> XCUIElement {
            jsSide.descendants(matching: .any).matching(identifier: identifier).firstMatch
        }
        func native(_ identifier: String) -> XCUIElement {
            nativeSide.descendants(matching: .any).matching(identifier: identifier).firstMatch
        }
        func pair(_ identifier: String) -> (js: XCUIElement, native: XCUIElement) {
            (js(identifier), native("native-\(identifier)"))
        }
        // The pages are as wide as a window (1040 points) and 520 tall, so the
        // native one sits below the JavaScript one, and the catalog page scrolls
        // down and across to reach either.
        let page = app.scrollViews.matching(NSPredicate(format: "identifier != %@", "plugin-catalog-skills-page-scroll"))
            .containing(.any, identifier: "plugin-catalog-js-skills-page").firstMatch
        let across = element("plugin-catalog-skills-page-scroll")
        @discardableResult func reveal(_ element: XCUIElement) -> XCUIElement {
            XCTAssertTrue(element.waitToExist(timeout: 10), "\(element) should exist before scrolling to it.")
            // Composite groups can be visible while XCTest reports no hit point
            // for the parent inside this nested scroll view; later actions target
            // their interactive child directly. Use the center point to decide
            // whether the parent is visible, even when XCTest cannot hit-test it.
            func hasHitTarget(_ element: XCUIElement) -> Bool {
                let frame = element.frame
                return element.isHittable || page.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
            }
            var scrolls = 0
            while !hasHitTarget(element), scrolls < 20 {
                let visible = page.frame, target = element.frame
                if target.midY < visible.minY + 20 || target.midY > visible.maxY - 20 {
                    page.scroll(byDeltaX: 0, deltaY: target.midY > visible.midY ? -250 : 250)
                } else if target.midX < visible.midX && target.minX < visible.minX + 20 {
                    across.scroll(byDeltaX: 250, deltaY: 0)
                } else if target.midX > visible.midX && target.maxX > visible.maxX - 20 {
                    across.scroll(byDeltaX: -250, deltaY: 0)
                } else if target.midX < visible.minX + 20 || target.midX > visible.maxX - 20 {
                    across.scroll(byDeltaX: target.midX > visible.midX ? -250 : 250, deltaY: 0)
                } else {
                    page.scroll(byDeltaX: 0, deltaY: target.midY > visible.midY ? -100 : 100)
                }
                scrolls += 1
            }
            XCTAssertTrue(hasHitTarget(element), "\(element) should be on screen after scrolling the catalog page.")
            return element
        }
        func clickNativeRadio(_ label: String) {
            let button = pair("skills-tab-picker").native.radioButtons[label]
            if button.isHittable {
                button.click()
                return
            }
            // This Picker is visibly inside the nested horizontal comparison
            // scroll view, but AppKit doesn't expose a hit point for its radio
            // buttons to XCTest. Tap the same visible screen frame directly.
            button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        }
        func assertSameSize(_ identifier: String) {
            let (js, native) = pair(identifier)
            XCTAssertTrue(js.waitToExist(timeout: 10), "The JavaScript page has \(identifier).")
            XCTAssertTrue(native.waitToExist(timeout: 10), "The native page has \(identifier).")
            XCTAssertEqual(js.frame.width, native.frame.width, accuracy: 1, "\(identifier) has the same width in both.")
            XCTAssertEqual(js.frame.height, native.frame.height, accuracy: 1, "\(identifier) has the same height in both.")
        }
        let commit = jsSide.descendants(matching: .any).matching(identifier: "plugin-last-commit").firstMatch
        let lastAction = js("js-last-action")

        // The composer's Skills button opens the page: the same plain Button atom.
        assertSameSize("open-skills-button")
        XCTAssertEqual(js("open-skills-button").label, "Skills")
        XCTAssertEqual(native("native-open-skills-button").label, "Skills")

        for identifier in ["skills-page", "skills-back-button", "skills-title", "skills-kind-picker", "skills-tab-picker", "skills-search", "new-skill-button",
                           "skills-provider-timing", "skills-repo-section-login-app", "skill-row-release-notes", "skill-row-review-login", "skill-row-broken-skill",
                           "skill-name-release-notes", "skill-provider-release-notes-claude", "skill-provider-release-notes-codex", "skill-description-release-notes",
                           "skill-location-release-notes", "skill-toggle-release-notes", "skill-use-release-notes", "skill-actions-release-notes",
                           "skill-conflict-review-login", "skill-issue-review-login", "skill-fix-review-login", "skill-invalid-broken-skill",
                           "skill-fix-broken-skill", "skill-use-broken-skill", "skills-repo-section-docs-site", "skills-empty-docs-site"] {
            assertSameSize(identifier)
        }
        XCTAssertEqual(pluginText(pair("skills-title").js), "Skills, Rules & MCP")
        XCTAssertEqual(pair("skills-page").js.frame.width, 1040, accuracy: 1, "Each page is as wide as a window, 1040 points.")
        XCTAssertGreaterThan(pair("skills-title").js.frame.width, 100, "The title shows in full on one line.")
        XCTAssertLessThan(pair("skills-title").js.frame.height, 30)
        for side in [(pair("skills-title").js, pair("skills-kind-picker").js, pair("skills-tab-picker").js, pair("skills-search").js, pair("new-skill-button").js),
                     (pair("skills-title").native, pair("skills-kind-picker").native, pair("skills-tab-picker").native, pair("skills-search").native, pair("new-skill-button").native)] {
            let (title, kinds, tabs, search, newSkill) = side
            XCTAssertEqual(kinds.frame.midY, title.frame.midY, accuracy: 6, "The Skills | Rules | MCP picker stays in the title row.")
            for control in [tabs, search, newSkill] {
                XCTAssertGreaterThanOrEqual(control.frame.minY, title.frame.maxY, "The source picker, search and New Skill sit on their own row below the title.")
                XCTAssertEqual(control.frame.midY, tabs.frame.midY, accuracy: 8, "The source picker, search and New Skill share one row.")
            }
        }
        XCTAssertLessThanOrEqual(pair("skills-page").js.frame.maxY, pair("skills-page").native.frame.minY, "The JavaScript page sits above the native one.")
        for side in [pair("skills-tab-picker").js, pair("skills-tab-picker").native] {
            XCTAssertTrue(isOn(side.radioButtons["Repo"]), "The page opens on its Repo skills.")
        }
        XCTAssertTrue(isOn(pair("skills-kind-picker").js.radioButtons["Skills"]), "The page opens on Skills.")
        XCTAssertEqual(pluginText(js("skill-description-release-notes")), "Draft release notes from the merged pull requests.")
        XCTAssertEqual(pluginText(js("skill-location-release-notes")), ".agents/skills")
        XCTAssertTrue(isOn(pair("skill-toggle-release-notes").js) && isOn(pair("skill-toggle-release-notes").native), "Both switches start on.")
        XCTAssertTrue(pair("skill-use-release-notes").js.isEnabled)
        XCTAssertFalse(js("skill-use-broken-skill").isEnabled, "No provider can use an invalid skill.")
        XCTAssertFalse(native("native-skill-use-broken-skill").isEnabled)
        XCTAssertFalse(js("skill-provider-broken-skill-claude").exists)
        XCTAssertEqual(js("skill-actions-release-notes").label, "Actions for release-notes")
        reveal(js("skills-empty-docs-site"))
        XCTAssertEqual(pluginText(js("skills-empty-docs-site")), "No skills in docs-site.")
        reveal(pair("skills-page").js)
        attachScreenshot(named: "Skills page: JavaScript above native, both on Repo")

        // Each side keeps its own source; the Segmented atom is controlled.
        reveal(pair("skills-tab-picker").js).radioButtons["Global"].click()
        XCTAssertTrue(js("skill-row-shared-notes").waitToExist(timeout: 5), "Choosing Global shows the global skills.")
        XCTAssertTrue(waitUntil({ self.pluginText(lastAction) == "Last: tab global" }, timeout: 5), "The source picker ran onChange with its value.")
        XCTAssertTrue(js("skill-linked-shared-notes").exists, "A linked skill shows Linked.")
        XCTAssertFalse(isOn(js("skill-toggle-quiet-skill")), "A switched-off skill shows its switch off.")
        XCTAssertFalse(js("skill-use-quiet-skill").isEnabled, "A switched-off skill can't be used.")
        XCTAssertFalse(js("skill-row-release-notes").exists, "Global replaces the repository's skills.")
        XCTAssertTrue(native("native-skill-row-release-notes").exists, "The native page stays on Repo.")
        attachScreenshot(named: "Skills page: JavaScript on Global, native still on Repo")
        reveal(pair("skills-tab-picker").native)
        clickNativeRadio("Global")
        XCTAssertTrue(native("native-skill-row-shared-notes").waitToExist(timeout: 5), "The native picker moves its own page.")
        for identifier in ["skill-row-shared-notes", "skill-linked-shared-notes", "skill-row-quiet-skill", "skill-toggle-quiet-skill"] {
            assertSameSize(identifier)
        }
        reveal(pair("skills-tab-picker").js).radioButtons["Repo"].click()
        XCTAssertTrue(js("skill-row-release-notes").waitToExist(timeout: 5))
        reveal(pair("skills-tab-picker").native)
        clickNativeRadio("Repo")
        XCTAssertTrue(native("native-skill-row-release-notes").waitToExist(timeout: 5))

        // The switch runs onToggle and turns Use off; Use runs its handler.
        let jsToggle = reveal(js("skill-toggle-release-notes"))
        reveal(js("skill-use-release-notes")).click()
        XCTAssertTrue(waitUntil({ self.pluginText(lastAction) == "Last: use release-notes" }, timeout: 5), "Use ran its JavaScript handler.")
        XCTAssertTrue(waitUntil({ self.pluginText(commit).contains(": text → node ") }, timeout: 5), "Use changed only the readout: \(pluginText(commit))")
        jsToggle.click()
        XCTAssertTrue(waitUntil({ !self.isOn(jsToggle) && self.pluginText(lastAction) == "Last: toggle release-notes off" }, timeout: 5), "onToggle turned the switch off.")
        XCTAssertTrue(waitUntil({ !js("skill-use-release-notes").isEnabled }, timeout: 5), "Turning a skill off disables Use.")
        XCTAssertTrue(isOn(native("native-skill-toggle-release-notes")), "The native switch keeps its own state.")
        attachScreenshot(named: "Skills page: the JavaScript switch turned release-notes off")
        jsToggle.click()
        XCTAssertTrue(waitUntil({ self.isOn(jsToggle) }, timeout: 5))

        // A click on a skill's text opens it; a press and hold starts selecting.
        reveal(js("skill-text-release-notes")).click()
        XCTAssertTrue(waitUntil({ self.pluginText(lastAction) == "Last: open release-notes" }, timeout: 5), "A click on the skill ran onPress.")
        js("skill-row-release-notes").press(forDuration: 1.0)
        XCTAssertTrue(waitUntil({ self.pluginText(lastAction) == "Last: select release-notes" }, timeout: 5), "A press and hold ran onLongPress.")
        XCTAssertTrue(js("skills-selection-count").waitToExist(timeout: 5), "Selecting shows the selection's actions.")
        XCTAssertEqual(pluginText(js("skills-selection-count")), "1 selected")
        XCTAssertEqual(js("skill-select-release-notes").label, "Selected", "The pressed skill's checkbox is checked.")
        XCTAssertEqual(js("skill-select-review-login").label, "Not selected")
        XCTAssertFalse(js("skill-toggle-release-notes").exists, "Selecting hides a row's own controls.")
        XCTAssertFalse(js("skills-search").exists, "Selecting replaces the search with the selection's actions.")
        XCTAssertTrue(js("skills-fix-selected").exists && js("skills-delete-selected").exists && js("skills-selection-done").exists)
        XCTAssertGreaterThanOrEqual(js("skills-selection-done").frame.minY, js("skills-title").frame.maxY, "While selecting, the actions replace search on the source row below the title.")
        XCTAssertFalse(js("skills-fix-selected").isEnabled, "Nothing selected is broken, so nothing can be fixed.")
        XCTAssertFalse(pair("skills-kind-picker").js.isEnabled, "The kind picker is locked while selecting.")
        XCTAssertTrue(native("native-skill-toggle-release-notes").exists, "The native page isn't selecting.")
        attachScreenshot(named: "Skills page: selecting in JavaScript")
        // While selecting, the row's text area is part of the row, so a click on the row's middle lands on it.
        reveal(js("skill-row-review-login")).click()
        XCTAssertTrue(waitUntil({ self.pluginText(js("skills-selection-count")) == "2 selected" }, timeout: 5), "A click on another row adds it.")
        XCTAssertTrue(waitUntil({ js("skills-fix-selected").isEnabled }, timeout: 5), "A selected conflict can be fixed.")
        reveal(pair("skills-tab-picker").js).radioButtons["Built-in"].click()
        XCTAssertTrue(js("skill-row-simplify").waitToExist(timeout: 5))
        XCTAssertFalse(js("skill-select-simplify").exists, "A built-in skill shows no checkbox.")
        let nativeSkillText = reveal(native("native-skill-text-release-notes"))
        nativeSkillText.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.0)
        XCTAssertTrue(native("native-skills-selection-count").waitToExist(timeout: 5), "The native row starts selecting too.")
        for identifier in ["skills-selection-count", "skills-fix-selected", "skills-delete-selected", "skills-selection-done"] {
            assertSameSize(identifier)
        }
        reveal(pair("skills-tab-picker").js).radioButtons["Repo"].click()
        XCTAssertTrue(js("skill-select-release-notes").waitToExist(timeout: 5))
        assertSameSize("skill-row-release-notes")
        assertSameSize("skill-select-release-notes")
        reveal(js("skills-selection-done")).click()
        XCTAssertTrue(waitUntil({ !js("skills-selection-count").exists && self.pluginText(lastAction) == "Last: done selecting" }, timeout: 5), "Done ends selecting.")
        XCTAssertTrue(js("skill-toggle-release-notes").waitToExist(timeout: 5), "Rows show their controls again.")
        let nativeDone = reveal(native("native-skills-selection-done"))
        nativeDone.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        // The actions menu runs onMenu with the chosen item's id.
        reveal(js("skill-actions-release-notes")).click()
        let edit = app.menuItems.matching(identifier: "skill-edit-release-notes").firstMatch
        XCTAssertTrue(edit.waitToExist(timeout: 5), "The actions menu opens.")
        XCTAssertTrue(app.menuItems["Move to docs-site"].exists && app.menuItems["Delete…"].exists, "It lists the skill's moves and Delete.")
        attachScreenshot(named: "Skills page: the JavaScript actions menu open")
        edit.click()
        XCTAssertTrue(waitUntil({ self.pluginText(lastAction) == "Last: menu release-notes edit" }, timeout: 5), "onMenu received the item's id.")

        // Search runs onChange with the text; Rules hides the source picker and search.
        let search = reveal(js("skills-search"))
        search.click()
        search.typeText("rel")
        XCTAssertTrue(waitUntil({ self.pluginText(lastAction) == "Last: search rel" }, timeout: 5), "Typing in the search ran onChange with the text.")
        reveal(pair("skills-kind-picker").js).radioButtons["Rules"].click()
        XCTAssertTrue(waitUntil({ !js("skills-tab-picker").exists && !js("skills-search").exists }, timeout: 5), "Rules hides the source picker and the search.")
        XCTAssertTrue(waitUntil({ self.pluginText(lastAction) == "Last: kind rules" }, timeout: 5))
        XCTAssertTrue(native("native-skills-tab-picker").exists, "The native page stays on Skills.")
        attachScreenshot(named: "Skills page: JavaScript on Rules, native on Skills")
        reveal(pair("skills-kind-picker").js).radioButtons["Skills"].click()
        XCTAssertTrue(js("skills-tab-picker").waitToExist(timeout: 5))

        // Back closes the JavaScript page; the Skills button opens it again.
        reveal(js("skills-back-button")).click()
        XCTAssertTrue(waitUntil({ !pair("skills-page").js.exists }, timeout: 5), "Back closed the JavaScript page.")
        XCTAssertTrue(waitUntil({ self.pluginText(lastAction) == "Last: back" }, timeout: 5))
        XCTAssertTrue(pair("skills-page").native.exists, "The native page stays open.")
        reveal(js("open-skills-button")).click()
        XCTAssertTrue(pair("skills-page").js.waitToExist(timeout: 5), "The Skills button opened the page again.")
        XCTAssertTrue(waitUntil({ self.pluginText(lastAction) == "Last: open" }, timeout: 5))
        XCTAssertEqual(pluginText(native("native-last-action")), "Last: done selecting", "The native page keeps its own state.")
        attachScreenshot(named: "Skills page: the Skills button reopened the JavaScript page")
    }
    // case-contract: test_plugin_repository_chips_renders_from_atoms_like_native | The Plugin Catalog's Repository Chips page shows the task header's repository chips and the Add repository picker their + button opens, composed in JavaScript from atoms beside the native SwiftUI chips and picker the task header uses, built from the same atoms and sample models. Both show a capsule chip per repository (the branch icon and its name) carrying a 20-point circular remove badge on its top trailing corner, the 28-point circular + button labelled Add repository, and the picker: Suggestions from the suggestion folder with its Change… button, the search with the saved repositories' placeholder, the Recent header and one row per recent repository (its name and path) with the first highlighted, in a 280-point list that stops growing at 180 points and scrolls, each at the same size in both, and the JavaScript tree uses only atoms (Overlay, Panel, Stack, Text, Icon, Button, Spacer, TextField, Scroll) with the task header's identifiers. Typing in the JavaScript search runs onChange (Last: search pla); Down and Up run onArrow (Last: down, then Last: up) and move the highlight while the native picker's highlight stays put; Return runs onSubmit with the highlighted row (Last: submit wix-one-app) and closes the picker; the + button shows it again (Last: open picker) and hides it (Last: close picker); clicking a row runs its onPress (Last: select Viband); Change… runs its handler (Last: choose folder); clicking a chip runs its onPress (Last: edit infragod) without re-rendering the other chip; and its remove badge removes it (Last: remove infragod) while the native chips keep theirs. A chip raises no onChange, so sending it one is refused as invalid_argument.
    func test_plugin_repository_chips_renders_from_atoms_like_native() throws {
        launchApp(defaultParent: fixture.parent.path)
        clickPluginsMenuItem("Plugin Catalog")
        let example = catalogSidebarRow("plugin-catalog-repository-chips")
        XCTAssertTrue(example.waitToExist(timeout: 15), "Plugins ▸ Plugin Catalog lists the Repository Chips example.")
        example.click()
        let jsSide = element("plugin-catalog-js-repository-chips")
        let nativeSide = element("plugin-catalog-native-repository-chips")
        XCTAssertTrue(jsSide.waitToExist(timeout: 10), "The page shows the JavaScript chips and picker.")
        XCTAssertTrue(nativeSide.waitToExist(timeout: 10), "The page shows the native chips and picker.")
        XCTAssertFalse(element("plugin-error").exists, "The JavaScript page renders without errors.")
        XCTAssertFalse(element("plugin-node-error").exists, "Every node on the JavaScript page has a registered atom.")

        func js(_ identifier: String) -> XCUIElement {
            jsSide.descendants(matching: .any).matching(identifier: identifier).firstMatch
        }
        func native(_ identifier: String) -> XCUIElement {
            nativeSide.descendants(matching: .any).matching(identifier: identifier).firstMatch
        }
        func pair(_ identifier: String) -> (js: XCUIElement, native: XCUIElement) {
            (js(identifier), native("native-\(identifier)"))
        }
        func assertSameSize(_ identifier: String) {
            let (js, native) = pair(identifier)
            XCTAssertTrue(js.waitToExist(timeout: 10), "The JavaScript side has \(identifier).")
            XCTAssertTrue(native.waitToExist(timeout: 10), "The native side has \(identifier).")
            XCTAssertEqual(js.frame.width, native.frame.width, accuracy: 1, "\(identifier) has the same width in both.")
            XCTAssertEqual(js.frame.height, native.frame.height, accuracy: 1, "\(identifier) has the same height in both.")
        }
        let commit = jsSide.descendants(matching: .any).matching(identifier: "plugin-last-commit").firstMatch
        let lastAction = js("js-last-action")
        let nativeLastAction = native("native-last-action")

        for identifier in ["conversation-repository-badge-infragod", "remove-conversation-repository-infragod", "conversation-repository-badge-Playhouse",
                           "remove-conversation-repository-Playhouse", "add-conversation-repository-button",
                           "conversation-repository-suggestion-parent", "choose-repository-suggestion-parent-button", "conversation-repository-search",
                           "conversation-repository-recent-header", "conversation-repository-list", "conversation-repository-recent-mre",
                           "conversation-repository-recent-wix-one-app", "conversation-repository-recent-Viband"] {
            assertSameSize(identifier)
        }
        // The picker is the panel's only child, so the two share one accessibility element: the panel's.
        let jsPicker = js("js-repository-picker-panel")
        let nativePicker = native("native-repository-picker-panel")
        XCTAssertEqual(jsPicker.frame.size, nativePicker.frame.size, "The picker is the same size in both.")
        XCTAssertEqual(jsPicker.frame.width, 304, accuracy: 1, "The picker is 304 points wide: a 280-point column inside 12 points of padding.")
        // The chip and its remove badge, as the header's own chips are checked.
        let chip = js("conversation-repository-badge-infragod")
        let remove = js("remove-conversation-repository-infragod")
        XCTAssertGreaterThanOrEqual(chip.frame.height, 28, "A chip is prominent.")
        XCTAssertEqual(remove.frame.width, 20, accuracy: 1, "The remove badge is a 20-point circle.")
        XCTAssertEqual(remove.frame.height, 20, accuracy: 1)
        XCTAssertGreaterThan(remove.frame.midX, chip.frame.midX, "The remove badge sits on the chip's trailing corner.")
        XCTAssertLessThan(remove.frame.midY, chip.frame.midY, "The remove badge sits on the chip's top corner.")
        XCTAssertEqual(remove.label, "Remove infragod")
        let add = pair("add-conversation-repository-button")
        XCTAssertEqual(add.js.frame.width, 28, accuracy: 1, "The + button is a 28-point circle.")
        XCTAssertEqual(add.js.frame.height, 28, accuracy: 1)
        XCTAssertEqual(add.js.label, "Add repository")
        XCTAssertEqual(add.native.label, "Add repository")
        XCTAssertEqual(pluginText(js("conversation-repository-suggestion-parent")), "Suggestions from /Users/demo/git")
        XCTAssertEqual(js("conversation-repository-search").placeholderValue, "infragod, Playhouse ↵", "The search shows the saved repositories.")
        XCTAssertEqual(pair("conversation-repository-list").js.frame.height, 180, accuracy: 1, "Five rows would be 210 points; the list stops at 180.")
        XCTAssertEqual(pair("conversation-repository-list").js.frame.width, 280, accuracy: 1)
        // A row is one button whose label joins its name and the path under it.
        for row in [js("conversation-repository-recent-wix-one-app"), native("native-conversation-repository-recent-wix-one-app")] {
            XCTAssertEqual(row.label, "wix-one-app, /Users/demo/git/wix-one-app", "A row shows its path under its name.")
        }
        attachScreenshot(named: "Repository chips: JavaScript beside native, the picker on Recent")
        // Five rows don't fit in 180 points: the last is below the fold until the list scrolls.
        for (list, last) in [(js("conversation-repository-list"), js("conversation-repository-recent-zmk-config")),
                             (native("native-conversation-repository-list"), native("native-conversation-repository-recent-zmk-config"))] {
            XCTAssertTrue(last.waitToExist(timeout: 5))
            XCTAssertGreaterThan(last.frame.maxY, list.frame.maxY + 1, "The last row starts below the list's bottom edge.")
            list.scroll(byDeltaX: 0, deltaY: -200)
            XCTAssertTrue(waitUntil({ last.frame.maxY <= list.frame.maxY + 1 && last.isHittable }, timeout: 5), "Scrolling the list reaches its last row.")
            XCTAssertEqual(list.frame.height, 180, accuracy: 1, "Scrolling leaves the list 180 points tall.")
            list.scroll(byDeltaX: 0, deltaY: 200)
        }
        attachScreenshot(named: "Repository chips: the picker lists scrolled back to the top")

        // The search: typing runs onChange, the arrows run onArrow, Return runs onSubmit.
        let search = js("conversation-repository-search")
        search.click()
        search.typeText("pla")
        XCTAssertTrue(waitUntil({ self.pluginText(lastAction) == "Last: search pla" }, timeout: 5), "Typing in the search ran onChange with the text.")
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        XCTAssertTrue(waitUntil({ (search.value as? String ?? "") == "" }, timeout: 5), "The search is empty again, so the recent rows show.")
        search.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(waitUntil({ self.pluginText(lastAction) == "Last: down" }, timeout: 5), "Down ran onArrow.")
        search.typeKey(.downArrow, modifierFlags: [])
        search.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(waitUntil({ self.pluginText(lastAction) == "Last: up" }, timeout: 5), "Up ran onArrow.")
        XCTAssertTrue(waitUntil({ self.pluginText(commit).contains("update") }, timeout: 5), "Moving the highlight updated the rows' panels: \(pluginText(commit))")
        attachScreenshot(named: "Repository chips: the JavaScript highlight moved to wix-one-app")
        search.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil({ self.pluginText(lastAction) == "Last: submit wix-one-app" }, timeout: 5), "Return added the highlighted row.")
        XCTAssertTrue(waitUntil({ !jsPicker.exists }, timeout: 5), "Adding closed the JavaScript picker.")
        XCTAssertTrue(nativePicker.exists, "The native picker stays open.")
        // The native highlight never moved: its Return adds the first row.
        let nativeSearch = native("native-conversation-repository-search")
        nativeSearch.click()
        nativeSearch.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil({ self.pluginText(nativeLastAction) == "Last: submit mre" }, timeout: 5), "The native picker keeps its own highlight.")
        XCTAssertTrue(waitUntil({ !nativePicker.exists }, timeout: 5))

        // The + button shows and hides the picker.
        js("add-conversation-repository-button").click()
        XCTAssertTrue(jsPicker.waitToExist(timeout: 5), "The + button showed the picker again.")
        XCTAssertTrue(waitUntil({ self.pluginText(lastAction) == "Last: open picker" }, timeout: 5))
        js("add-conversation-repository-button").click()
        XCTAssertTrue(waitUntil({ !jsPicker.exists && self.pluginText(lastAction) == "Last: close picker" }, timeout: 5),
                      "The + button hid the picker.")
        js("add-conversation-repository-button").click()
        XCTAssertTrue(js("conversation-repository-recent-Viband").waitToExist(timeout: 5))
        js("conversation-repository-recent-Viband").click()
        XCTAssertTrue(waitUntil({ self.pluginText(lastAction) == "Last: select Viband" }, timeout: 5), "Clicking a row ran its onPress.")
        js("add-conversation-repository-button").click()
        XCTAssertTrue(js("choose-repository-suggestion-parent-button").waitToExist(timeout: 5))
        js("choose-repository-suggestion-parent-button").click()
        XCTAssertTrue(waitUntil({ self.pluginText(lastAction) == "Last: choose folder" }, timeout: 5), "Change… ran its handler.")

        // A chip opens its settings; its remove badge removes it.
        chip.click()
        XCTAssertTrue(waitUntil({ self.pluginText(lastAction) == "Last: edit infragod" }, timeout: 5), "Clicking a chip ran its onPress.")
        XCTAssertTrue(waitUntil({ self.pluginText(commit).contains(": text → node ") }, timeout: 5), "Clicking a chip re-rendered no chip: \(pluginText(commit))")
        remove.click()
        XCTAssertTrue(waitUntil({ !js("conversation-repository-badge-infragod").exists }, timeout: 5), "The remove badge removed its chip.")
        XCTAssertTrue(waitUntil({ self.pluginText(lastAction) == "Last: remove infragod" }, timeout: 5))
        XCTAssertTrue(js("conversation-repository-badge-Playhouse").exists)
        XCTAssertTrue(native("native-conversation-repository-badge-infragod").exists, "The native chips keep theirs.")
        attachScreenshot(named: "Repository chips: the JavaScript infragod chip removed, native kept")
    }
    // case-contract: test_plugin_composer_renders_from_atoms_like_native | The Plugin Catalog's Composer page shows the conversation composer's box composed in JavaScript from atoms above the native SwiftUI box the conversation uses, built from the same atoms and sample data, each as wide as the page's 764-point column and with the composer's identifiers (the native side prefixed native-), and the JavaScript tree uses only atoms (Panel, Stack, Editor, Button, Icon, Menu, Spacer, Popover, Text, Divider, StepSlider). Both show the editor with its message placeholder, the Skills button (the plain Button atom with the sparkles icon, labelled Skills), the plus mode menu, the Claude provider menu, the Sonnet 5.5 model button with its Medium effort, the schedule button and a send button that is disabled while the draft is empty, each at the same size in both. Typing in the JavaScript editor runs onChange (Last: edit) and enables Send, Send runs its handler (Last: send followed by the draft) and clears the editor, and the native editor keeps its own text. The plus menu runs onMenu with the item's id: Plan mode (Last: mode mode:plan) labels the menu Conversation mode: Plan mode and shows the Start Implementing button, and Goal (Last: mode goal) labels the menu Goal and shows the goal placeholder; choosing Codex in the provider menu runs onMenu (Last: provider codex) and shows its title. The model button runs onPress and opens its popover (Last: model picker open) listing the models with the current one checked and the effort slider; choosing a model runs onPress (Last: model claude-opus-5-5), checks it instead and changes the button's model name, moving the effort slider to its last step runs onChange with that effort's value (Last: effort xhigh) and changes the button's effort to Extra High, and Escape runs onDismiss (Last: model picker closed). The schedule button opens its popover (Last: schedule open), whose content stays native. The conversation's own composer is this box: with Debug ▸ Highlight Native Atoms on, a task's composer shows its editor as an Editor atom, its model button in a Popover atom and its mode and provider menus as Menu atoms, with every identifier its controls had unchanged. A Popover shows the children after its first (its anchor) in the popover, so one with only an anchor is valid.
    func test_plugin_composer_renders_from_atoms_like_native() throws {
        launchApp(defaultParent: fixture.parent.path)
        // A task's conversation composes its composer box from atoms: with Highlight
        // Native Atoms on, its editor is an Editor atom and its model button sits in a Popover atom.
        _ = try runCLI(["task", "create", "--title", "Atom composer", "--prompt", "Fixture task description.", "--root", fixture.primary.path])
        openTask(named: "Atom composer")
        let conversationEditor = element("message-composer")
        XCTAssertTrue(conversationEditor.waitToExist(timeout: 15), "The conversation shows its composer.")
        clickDebugHighlightNativeAtoms()
        let highlight = NSPredicate(format: "identifier IN %@", ["atom-highlight-container", "atom-highlight-leaf"])
        func outlines(_ atom: String) -> XCUIElementQuery {
            element("chat-composer").descendants(matching: .any).matching(highlight).matching(NSPredicate(format: "label == %@", atom))
        }
        XCTAssertTrue(waitUntil({ outlines("Editor").count == 1 }, timeout: 5), "The conversation's editor is the Editor atom.")
        XCTAssertEqual(outlines("Editor").firstMatch.identifier, "atom-highlight-leaf")
        XCTAssertGreaterThanOrEqual(outlines("Popover").count, 1, "The model button sits in a Popover atom.")
        XCTAssertEqual(outlines("Popover").firstMatch.identifier, "atom-highlight-container")
        XCTAssertTrue(outlines("Menu").count >= 2, "The mode and provider menus are Menu atoms.")
        for identifier in ["message-composer-scroll-view", "open-skills-button", "conversation-mode-menu", "conversation-provider-menu", "model-picker-menu", "send-message-button"] {
            XCTAssertTrue(element(identifier).exists, "The conversation's composer keeps \(identifier).")
        }
        attachScreenshot(named: "Composer: the conversation's composer outlined as atoms")
        clickDebugHighlightNativeAtoms()
        XCTAssertTrue(waitUntil({ outlines("Editor").count == 0 }, timeout: 5))

        // A Popover shows the children after its anchor; one with only an anchor is valid.
        let loneAnchor = dataDirectory.appendingPathComponent("plugin-lone-popover.js")
        try #"Playhouse.render(h(Popover, { isPresented: false }, h(Text, null, "Anchor")));"#.write(to: loneAnchor, atomically: true, encoding: .utf8)
        let lone = try XCTUnwrap(try runCLI(["plugin", "render", "--file", loneAnchor.path])["result"] as? [String: Any])
        XCTAssertEqual((lone["errors"] as? [String])?.count, 0, "A Popover with only an anchor renders without errors: \(lone)")

        clickPluginsMenuItem("Plugin Catalog")
        let example = catalogSidebarRow("plugin-catalog-composer")
        XCTAssertTrue(example.waitToExist(timeout: 15), "Plugins ▸ Plugin Catalog lists the Composer example.")
        example.click()
        let jsSide = element("plugin-catalog-js-composer")
        let nativeSide = element("plugin-catalog-native-composer")
        XCTAssertTrue(jsSide.waitToExist(timeout: 10), "The page shows the JavaScript composer.")
        XCTAssertTrue(nativeSide.waitToExist(timeout: 10), "The page shows the native composer.")
        XCTAssertFalse(element("plugin-error").exists, "The JavaScript composer renders without errors.")
        XCTAssertFalse(element("plugin-node-error").exists, "Every node of the JavaScript composer has a registered atom.")

        func js(_ identifier: String) -> XCUIElement {
            jsSide.descendants(matching: .any).matching(identifier: identifier).firstMatch
        }
        func native(_ identifier: String) -> XCUIElement {
            nativeSide.descendants(matching: .any).matching(identifier: identifier).firstMatch
        }
        func pair(_ identifier: String) -> (js: XCUIElement, native: XCUIElement) {
            (js(identifier), native("native-\(identifier)"))
        }
        func assertSameSize(_ identifier: String) {
            let (js, native) = pair(identifier)
            XCTAssertTrue(js.waitToExist(timeout: 10), "The JavaScript composer has \(identifier).")
            XCTAssertTrue(native.waitToExist(timeout: 10), "The native composer has \(identifier).")
            // A control that just appeared may still be settling into its layout.
            _ = waitUntil({ abs(js.frame.width - native.frame.width) <= 1 && abs(js.frame.height - native.frame.height) <= 1 }, timeout: 5)
            XCTAssertEqual(js.frame.width, native.frame.width, accuracy: 1, "\(identifier) has the same width in both.")
            XCTAssertEqual(js.frame.height, native.frame.height, accuracy: 1, "\(identifier) has the same height in both.")
        }
        let lastJS = js("js-last-action")
        let lastNative = native("native-last-action")

        for identifier in ["message-composer-scroll-view", "open-skills-button", "conversation-mode-menu", "conversation-provider-menu", "model-picker-menu",
                           "schedule-task-button", "send-message-button"] {
            assertSameSize(identifier)
        }
        XCTAssertEqual(js("open-skills-button").label, "Skills")
        XCTAssertEqual(native("native-open-skills-button").label, "Skills")
        XCTAssertEqual(js("model-picker-menu").label, "Model: Sonnet 5.5, effort: Medium")
        XCTAssertEqual(native("native-model-picker-menu").label, "Model: Sonnet 5.5, effort: Medium")
        XCTAssertEqual(js("conversation-provider-menu").label, "Provider: Claude")
        XCTAssertFalse(js("send-message-button").isEnabled, "Send is disabled while the draft is empty.")
        XCTAssertFalse(native("native-send-message-button").isEnabled)
        XCTAssertLessThanOrEqual(jsSide.frame.maxY, nativeSide.frame.minY + 1, "The JavaScript composer sits above the native one.")
        XCTAssertTrue(jsSide.staticTexts["Message…"].exists && nativeSide.staticTexts["Message…"].exists, "Both editors show their placeholder.")
        // The box fills the 764-point column: its editor is the column less the box's 13-point padding.
        XCTAssertEqual(pair("message-composer-scroll-view").js.frame.width, 738, accuracy: 1, "The JavaScript composer is 764 points wide.")
        XCTAssertEqual(pair("message-composer-scroll-view").native.frame.width, 738, accuracy: 1, "The native composer is 764 points wide.")
        attachScreenshot(named: "Composer: JavaScript above native, both empty")

        // Typing runs onChange and enables Send; Send runs its handler and clears the editor. Each side keeps its own text.
        let jsEditor = jsSide.descendants(matching: .textView).matching(identifier: "message-composer").firstMatch
        XCTAssertTrue(jsEditor.waitToExist(timeout: 10), "The JavaScript editor is a text view.")
        jsEditor.click()
        jsEditor.typeText("hello")
        XCTAssertTrue(waitUntil({ self.pluginText(lastJS) == "Last: edit" }, timeout: 5), "Typing ran onChange.")
        XCTAssertTrue(waitUntil({ js("send-message-button").isEnabled }, timeout: 5), "A draft enables Send.")
        XCTAssertFalse(native("native-send-message-button").isEnabled, "The native composer keeps its own draft.")
        XCTAssertFalse(jsSide.staticTexts["Message…"].exists, "A draft hides the placeholder.")
        attachScreenshot(named: "Composer: text typed into the JavaScript editor")
        js("send-message-button").click()
        XCTAssertTrue(waitUntil({ self.pluginText(lastJS) == "Last: send hello" }, timeout: 5), "Send ran its handler with the draft.")
        XCTAssertTrue(waitUntil({ jsSide.staticTexts["Message…"].exists && !js("send-message-button").isEnabled }, timeout: 5), "Send cleared the editor.")

        let nativeEditor = nativeSide.descendants(matching: .textView).matching(identifier: "native-message-composer").firstMatch
        nativeEditor.click()
        nativeEditor.typeText("hi")
        XCTAssertTrue(waitUntil({ self.pluginText(lastNative) == "Last: edit" && native("native-send-message-button").isEnabled }, timeout: 5), "The native editor ran its action too.")
        native("native-send-message-button").click()
        XCTAssertTrue(waitUntil({ self.pluginText(lastNative) == "Last: send hi" }, timeout: 5))

        // The plus menu.
        for (side, prefix, last) in [(jsSide, "", lastJS), (nativeSide, "native-", lastNative)] {
            side.descendants(matching: .any).matching(identifier: "\(prefix)conversation-mode-menu").firstMatch.click()
            let plan = app.menuItems["Plan mode"]
            XCTAssertTrue(plan.waitToExist(timeout: 5), "The plus menu lists Plan mode.")
            plan.click()
            XCTAssertTrue(waitUntil({ self.pluginText(last) == "Last: mode mode:plan" }, timeout: 5), "Plan mode ran onMenu with its id.")
            XCTAssertTrue(side.descendants(matching: .any).matching(identifier: "\(prefix)start-implementing-button").firstMatch.waitToExist(timeout: 5),
                          "Plan mode shows Start Implementing.")
            XCTAssertEqual(side.descendants(matching: .any).matching(identifier: "\(prefix)conversation-mode-menu").firstMatch.label, "Conversation mode: Plan mode",
                           "Plan mode labels the plus menu.")
        }
        assertSameSize("start-implementing-button")
        assertSameSize("conversation-mode-menu")
        attachScreenshot(named: "Composer: Plan mode on both, with Start Implementing")
        js("conversation-mode-menu").click()
        app.menuItems["Goal"].click()
        XCTAssertTrue(waitUntil({ self.pluginText(lastJS) == "Last: mode goal" }, timeout: 5), "Goal ran onMenu with its id.")
        XCTAssertFalse(js("start-implementing-button").exists, "Leaving Plan mode hides Start Implementing.")
        XCTAssertTrue(jsSide.staticTexts["Set a goal to keep pursuing"].exists, "Goal shows its placeholder.")
        XCTAssertEqual(js("conversation-mode-menu").label, "Goal", "Goal labels the plus menu.")
        js("conversation-provider-menu").click()
        app.menuItems["Codex"].click()
        XCTAssertTrue(waitUntil({ self.pluginText(lastJS) == "Last: provider codex" && js("conversation-provider-menu").label == "Provider: Codex" }, timeout: 5),
                      "Choosing Codex ran onMenu and changed the provider's title.")

        // The model popover.
        js("model-picker-menu").click()
        XCTAssertTrue(waitUntil({ self.pluginText(lastJS) == "Last: model picker open" }, timeout: 5), "The model button ran onPress.")
        let option = app.buttons["model-option-claude-opus-5-5"]
        XCTAssertTrue(option.waitToExist(timeout: 5), "The popover lists the models.")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "model-effort-slider").firstMatch.exists, "The popover shows the effort slider.")
        // A checked model's button reads Selected; its checkmark is part of the button.
        XCTAssertEqual(app.buttons["model-option-claude-sonnet-5-5"].value as? String, "Selected", "The current model is checked.")
        XCTAssertEqual(option.value as? String, "Not selected")
        attachScreenshot(named: "Composer: the JavaScript model popover")
        option.click()
        XCTAssertTrue(waitUntil({ self.pluginText(lastJS) == "Last: model claude-opus-5-5" && js("model-picker-menu").label.hasPrefix("Model: Opus 5.5") }, timeout: 5),
                      "Choosing a model ran onPress and changed the model button.")
        XCTAssertTrue(waitUntil({ option.value as? String == "Selected" && self.app.buttons["model-option-claude-sonnet-5-5"].value as? String == "Not selected" }, timeout: 5),
                      "The chosen model is checked instead.")
        let slider = app.descendants(matching: .any).matching(identifier: "model-effort-slider").firstMatch
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).click()
        XCTAssertTrue(waitUntil({ self.pluginText(lastJS) == "Last: effort xhigh" && js("model-picker-menu").label == "Model: Opus 5.5, effort: Extra High" }, timeout: 5),
                      "Moving the slider ran onChange with the effort's value.")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil({ self.pluginText(lastJS) == "Last: model picker closed" }, timeout: 5), "Escape ran onDismiss.")
        XCTAssertFalse(option.exists, "The popover closed.")
        XCTAssertTrue(native("native-model-picker-menu").label.hasPrefix("Model: Sonnet 5.5"), "The native composer keeps its own model.")

        js("schedule-task-button").click()
        XCTAssertTrue(waitUntil({ self.pluginText(lastJS) == "Last: schedule open" }, timeout: 5), "The schedule button ran onPress.")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "schedule-hint").firstMatch.waitToExist(timeout: 5), "Its popover shows the native hint's stand-in.")
        attachScreenshot(named: "Composer: the schedule popover")
    }
}
