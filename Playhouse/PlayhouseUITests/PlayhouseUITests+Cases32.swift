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
    // case-contract: test_plugin_skills_page_renders_from_atoms_like_native | The Plugin Catalog's Skills Page shows the Skills modal's header and skill list composed in JavaScript from atoms above the native SwiftUI header and list the Skills modal uses, built from the same atoms and sample data, each 336 points wide like the modal and opened by the Skills button (the same plain Button atom with the sparkles icon, labelled Skills). Both show the close button (an xmark capsule labelled Close), a header of the page's sparkles icon (labelled Skills, Rules & MCP) followed by the Skills | Rules | MCP segmented tabs, then the search field and a small New Skill button, a Jump to bar of Repo, Global and Built-in anchors with their counts below them, then one scrolling list with the Repo, Global and Built-in sections in order, each headed by a button that collapses or expands it with Built-in collapsed at first and an info icon whose hover hint (a Popover with hover on, not a tooltip) explains the section, and the hint below them; a repository section's skills share one card with hairlines between them, each a single line with only its name led by one provider icon (the Claude logo for a Claude-only skill, the Codex logo for a Codex-only skill, a green check for one both can use, none for a skill no provider can use), a Conflict or Invalid icon right of a broken skill's name, a small Fix button on a broken skill and the actions menu, with no switch or Use button: the menu starts with Use (disabled for a skill that is off or that no provider can use) and Disable, or Enable for a skill that is off, which shows grayed out, while its description, issue and location sit in a hover hint (a Popover with hover on, left of the row) and the description is also the row's accessibility hint; and an empty repository's empty state, each at the same size in both, and the JavaScript tree uses only atoms (Panel, Stack, Text, Icon, Label, Button, Spacer, Divider, Scroll, Segmented, TextField, Menu, PressArea, Popover) with the Skills modal's identifiers. Clicking the JavaScript Built-in header runs its handler (Last: expand builtin) and shows its skills. Pressing the JavaScript Global anchor runs its handler (Last: jump global) and asks the list to scroll to Global (scrollTo global, a new scrollRequest on each press) while every section stays in the list, and an anchor expands a collapsed section. The menu's Use runs its handler (Last: use release-notes) without re-rendering any row, and its Disable runs onMenu (Last: toggle release-notes off), which grays the row out, disables Use and offers Enable, while the grayed-out row still responds to clicks; Enable turns it back on (Last: toggle release-notes on). Clicking a skill's text runs onPress (Last: open release-notes); pressing and holding it runs onLongPress, which starts selecting (Last: select release-notes): its row shows a checked checkbox and the accent highlight, the rows' own controls hide, built-in skills show no checkbox, and the search's row shows 1 selected with Fix, Delete and Done; a click on another row adds it (2 selected), and Done ends selecting (Last: done selecting). The actions menu runs onMenu with the chosen item's id (Last: menu release-notes edit), typing in the search runs onChange with the text, choosing Rules hides the anchors and the search, and the close button closes the JavaScript modal (Last: back) while the native one stays open, until the Skills button opens it again (Last: open). The search field raises no onPress, so pressing it is refused as invalid_argument.
    func test_plugin_skills_page_renders_from_atoms_like_native() throws {
        executionTimeAllowance = 360 // It walks every section, anchor and hint of both pages.
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
        // The pages are as wide as the modal (336 points) and 520 tall, the
        // native one below the JavaScript one, and the catalog page scrolls
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
            // While a row's hint popover shows, XCTest may report no hit point
            // for the scroll views, so rest the pointer on the catalog's sidebar
            // to close it before scrolling.
            if !hasHitTarget(element), app.popovers.count > 0 {
                app.windows.matching(NSPredicate(format: "title == 'Plugin Catalog'")).firstMatch
                    .coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).hover()
                _ = waitUntil({ self.app.popovers.count == 0 }, timeout: 3)
            }
            // Scroll at a point of the view that is on screen rather than at its
            // hit point: XCTest may report no hit point for these nested scroll
            // views even while they are visible and scrollable. Scroll near the
            // view's right edge, beside the 336-point pages: at its center the
            // event lands on a page's own skills list, which takes the scroll
            // and leaves the catalog page where it was.
            func scroll(_ view: XCUIElement, deltaX: CGFloat, deltaY: CGFloat) {
                let shown = view.frame.intersection(page.frame)
                guard !shown.isNull else {
                    XCTFail("\(view) has no part on screen inside the catalog page to scroll.")
                    return
                }
                let origin = page.frame.origin
                page.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: shown.maxX - 12 - origin.x, dy: shown.midY - origin.y))
                    .scroll(byDeltaX: deltaX, deltaY: deltaY)
            }
            var scrolls = 0
            while !hasHitTarget(element), scrolls < 20 {
                let visible = page.frame, target = element.frame
                if target.midY < visible.minY + 20 || target.midY > visible.maxY - 20 {
                    scroll(page, deltaX: 0, deltaY: target.midY > visible.midY ? -250 : 250)
                } else if target.midX < visible.midX && target.minX < visible.minX + 20 {
                    scroll(across, deltaX: 250, deltaY: 0)
                } else if target.midX > visible.midX && target.maxX > visible.maxX - 20 {
                    scroll(across, deltaX: -250, deltaY: 0)
                } else if target.midX < visible.minX + 20 || target.midX > visible.maxX - 20 {
                    scroll(across, deltaX: target.midX > visible.midX ? -250 : 250, deltaY: 0)
                } else {
                    scroll(page, deltaX: 0, deltaY: target.midY > visible.midY ? -100 : 100)
                }
                scrolls += 1
            }
            XCTAssertTrue(hasHitTarget(element), "\(element) should be on screen after scrolling the catalog page.")
            return element
        }
        func clickAnchor(_ element: XCUIElement) {
            reveal(element)
            if element.isHittable {
                element.click()
                return
            }
            // The anchor is visibly inside the nested horizontal comparison
            // scroll view, but XCTest may report no hit point for it there.
            // Click the same visible screen frame directly.
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        }
        // A row's details show only in its hover hint, a popover beside the row.
        @discardableResult func hint(_ identifier: String, row: XCUIElement) -> XCUIElement {
            let detail = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
            reveal(row)
            // Like clickAnchor, hover the row's visible frame: inside the nested
            // comparison scroll view XCTest may report no hit point for it.
            for _ in 0..<3 where !detail.exists {
                row.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).hover()
                if detail.waitToExist(timeout: 3) { break }
                js("skills-title").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
            }
            XCTAssertTrue(detail.exists, "Resting on \(row) shows \(identifier) in its hint.")
            return detail
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

        // The Skills button opens the page: the same plain Button atom.
        assertSameSize("open-skills-button")
        XCTAssertEqual(js("open-skills-button").label, "Skills")
        XCTAssertEqual(native("native-open-skills-button").label, "Skills")

        for identifier in ["skills-page", "skills-back-button", "skills-title", "skills-kind-picker", "skills-tab-picker", "skills-search", "new-skill-button",
                           "skills-provider-timing", "skills-repo-section-login-app", "skill-row-release-notes", "skill-row-review-login", "skill-row-broken-skill",
                           "skill-name-release-notes", "skill-provider-release-notes-both", "skill-actions-release-notes",
                           "skill-conflict-review-login", "skill-fix-review-login", "skill-invalid-broken-skill",
                           "skill-fix-broken-skill", "skills-repo-section-docs-site", "skills-empty-docs-site", "skills-collapse-repo", "skills-collapse-builtin"] {
            assertSameSize(identifier)
        }
        XCTAssertEqual(pair("skills-title").js.label, "Skills, Rules & MCP", "The header's icon names the page.")
        XCTAssertEqual(pair("skills-title").native.label, "Skills, Rules & MCP")
        XCTAssertEqual(pair("skills-page").js.frame.width, 336, accuracy: 1, "Each page is as wide as the modal, 336 points.")
        for anchor in ["repo", "global", "builtin"] {
            assertSameSize("skills-anchor-\(anchor)")
            assertSameSize("skills-group-\(anchor)")
        }
        XCTAssertEqual(pair("skills-tab-picker").js.label, "Jump to")
        XCTAssertEqual(js("skills-anchor-global").label, "Global")
        for side in [(js("skills-group-repo"), js("skills-group-global"), js("skills-group-builtin")),
                     (native("native-skills-group-repo"), native("native-skills-group-global"), native("native-skills-group-builtin"))] {
            XCTAssertLessThan(side.0.frame.minY, side.1.frame.minY, "Repo comes before Global in the one list.")
            XCTAssertLessThan(side.1.frame.minY, side.2.frame.minY, "Global comes before Built-in in the one list.")
        }
        XCTAssertEqual(pair("skills-title").js.frame.width, 26, accuracy: 1, "The header shows the page's icon, not its title.")
        for side in [(pair("skills-back-button").js, pair("skills-title").js, pair("skills-kind-picker").js, pair("skills-tab-picker").js, pair("skills-search").js, pair("new-skill-button").js),
                     (pair("skills-back-button").native, pair("skills-title").native, pair("skills-kind-picker").native, pair("skills-tab-picker").native, pair("skills-search").native, pair("new-skill-button").native)] {
            let (close, title, kinds, anchors, search, newSkill) = side
            XCTAssertEqual(kinds.frame.midY, title.frame.midY, accuracy: 4, "The Skills | Rules | MCP tabs sit in the header, in the title's place.")
            XCTAssertGreaterThanOrEqual(kinds.frame.minX, title.frame.maxX, "The tabs follow the header's icon.")
            XCTAssertLessThanOrEqual(kinds.frame.maxX, close.frame.minX, "The close button stays at the header's end.")
            XCTAssertEqual(search.frame.midY, newSkill.frame.midY, accuracy: 8, "The search and New Skill share one row.")
            XCTAssertGreaterThanOrEqual(search.frame.minY, kinds.frame.maxY, "The search row sits below the header.")
            XCTAssertGreaterThanOrEqual(anchors.frame.minY, search.frame.maxY, "The anchors sit on their own row below the search.")
        }
        for (search, newSkill, page) in [(pair("skills-search").js, pair("new-skill-button").js, pair("skills-page").js),
                                         (pair("skills-search").native, pair("new-skill-button").native, pair("skills-page").native)] {
            // The card is a narrow column, so the search fills what New Skill leaves of the row.
            XCTAssertLessThan(newSkill.frame.minX - search.frame.maxX, 24, "The search reaches New Skill.")
            XCTAssertGreaterThan(search.frame.width, page.frame.width * 0.4, "The search fills its row.")
            XCTAssertLessThanOrEqual(newSkill.frame.maxX, page.frame.maxX, "New Skill fits inside the card.")
        }
        XCTAssertLessThanOrEqual(pair("skills-page").js.frame.maxY, pair("skills-page").native.frame.minY, "The JavaScript page sits above the native one.")
        XCTAssertTrue(isOn(pair("skills-kind-picker").js.radioButtons["Skills"]), "The page opens on Skills.")
        // Built-in starts collapsed; its header expands it on each side.
        for (collapse, prefix) in [(js("skills-collapse-builtin"), ""), (native("native-skills-collapse-builtin"), "native-")] {
            XCTAssertEqual(collapse.value as? String, "Collapsed", "Built-in starts collapsed.")
            XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "\(prefix)skill-row-simplify").firstMatch.exists, "A collapsed group hides its skills.")
        }
        XCTAssertEqual(js("skills-collapse-repo").value as? String, "Expanded")
        // A section's info icon explains it in a hover hint once the pointer rests on it; the native
        // header's is checked in the Skills modal itself (test_skills_catalog_lists_repo_global_and_builtin_skills).
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "skills-intro-repo-hint").firstMatch.exists, "The intro stays hidden until the pointer rests on its icon.")
        let introHint = hint("skills-intro-repo-hint", row: js("skills-intro-repo"))
        XCTAssertTrue(accessibleLabelOrValue(of: introHint).hasPrefix("Skills in the task's repositories"), "The hint explains the Repo section.")
        XCTAssertGreaterThan(introHint.frame.minY, js("skills-intro-repo").frame.maxY - 1, "The hint opens below the icon.")
        js("skills-title").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        XCTAssertTrue(waitUntil({ !introHint.exists }, timeout: 3), "The intro closes when the pointer leaves its icon.")
        attachElementScreenshot(reveal(pair("skills-page").js), named: "The JavaScript Skills modal: tabs in the header, Built-in collapsed")
        clickAnchor(js("skills-collapse-builtin"))
        XCTAssertTrue(waitUntil({ self.pluginText(lastAction) == "Last: expand builtin" && js("skill-row-simplify").exists }, timeout: 5), "Built-in's header expands it.")
        XCTAssertEqual(js("skills-collapse-builtin").value as? String, "Expanded")
        XCTAssertFalse(native("native-skill-row-simplify").exists, "The native page keeps Built-in collapsed.")
        clickAnchor(native("native-skills-collapse-builtin"))
        XCTAssertTrue(waitUntil({ native("native-skill-row-simplify").exists }, timeout: 5), "The native header expands it too.")
        XCTAssertEqual(js("skill-provider-simplify-claude").label, "Claude only", "A Claude-only skill shows the Claude logo.")
        XCTAssertEqual(js("skill-provider-skill-creator-codex").label, "Codex only", "A Codex-only skill shows the Codex logo.")
        XCTAssertEqual(js("skill-provider-release-notes-both").label, "Claude and Codex", "A skill both agents use shows the green check.")
        for identifier in ["skill-provider-simplify-claude", "skill-provider-skill-creator-codex"] {
            assertSameSize(identifier)
        }
        attachElementScreenshot(reveal(js("skills-group-builtin")), named: "Built-in expanded: the Claude and Codex logos")
        for row in [js("skill-row-release-notes"), native("native-skill-row-release-notes")] {
            XCTAssertFalse(row.staticTexts["Draft release notes from the merged pull requests."].exists, "A row shows only the skill's name, not its description.")
        }
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "skill-description-release-notes").firstMatch.exists, "The details stay hidden until the pointer rests on the row.")
        XCTAssertEqual(pluginText(hint("skill-description-release-notes", row: js("skill-row-release-notes"))), "Draft release notes from the merged pull requests.")
        XCTAssertEqual(pluginText(hint("skill-location-release-notes", row: js("skill-row-release-notes"))), ".agents/skills")
        for (row, prefix) in [(js("skill-row-release-notes"), ""), (native("native-skill-row-release-notes"), "native-")] {
            XCTAssertTrue(row.descendants(matching: .any).matching(identifier: "\(prefix)skill-provider-release-notes-both").firstMatch.exists, "The row carries one provider icon.")
            XCTAssertFalse(row.descendants(matching: .any).matching(identifier: "\(prefix)skill-provider-release-notes-claude").firstMatch.exists, "No separate Claude badge.")
        }
        for (rowID, prefix) in [("skill-row-review-login", ""), ("native-skill-row-review-login", "native-")] {
            let row = rowID.hasPrefix("native-") ? native(rowID) : js(rowID)
            func part(_ identifier: String) -> XCUIElement { row.descendants(matching: .any).matching(identifier: "\(prefix)\(identifier)").firstMatch }
            XCTAssertLessThan(part("skill-provider-review-login-both").frame.maxX, part("skill-name-review-login").frame.minX, "\(prefix)The provider icon leads the skill's name.")
            XCTAssertGreaterThan(part("skill-conflict-review-login").frame.minX, part("skill-name-review-login").frame.maxX, "\(prefix)The warning stays right of the name.")
        }
        XCTAssertFalse(hint("skill-hint-release-notes", row: js("skill-row-release-notes")).descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'skill-provider-'")).firstMatch.exists, "The provider icon is on the row, not in the hint.")
        XCTAssertLessThan(hint("skill-hint-release-notes", row: js("skill-row-release-notes")).frame.midX, js("skill-row-release-notes").frame.midX, "The hint shows left of the row.")
        attachScreenshot(named: "Skills page: the JavaScript hover hint of release-notes")
        // A hint closes when the pointer leaves its row, so read each one's size while it shows.
        let jsHint = hint("skill-hint-release-notes", row: js("skill-row-release-notes"))
        attachElementScreenshot(jsHint, named: "The JavaScript hint of release-notes")
        let jsHintSize = jsHint.frame.size
        let nativeHintSize = hint("native-skill-hint-release-notes", row: native("native-skill-row-release-notes")).frame.size
        XCTAssertEqual(jsHintSize.width, nativeHintSize.width, accuracy: 1, "Both hints have the same width.")
        XCTAssertEqual(jsHintSize.height, nativeHintSize.height, accuracy: 1, "Both hints have the same height.")
        XCTAssertTrue(pluginText(hint("skill-issue-review-login", row: js("skill-row-review-login"))).isEmpty == false, "A conflicting skill's hint explains its issue.")
        XCTAssertTrue(waitUntil({ !js("skill-hint-release-notes").exists }, timeout: 3), "Only one JavaScript hint shows at a time.")
        XCTAssertEqual(pair("skill-text-release-notes").js.label, "release-notes", "Both skills start on.")
        XCTAssertEqual(pair("skill-text-release-notes").native.label, "release-notes")
        XCTAssertFalse(js("skill-row-release-notes").switches.firstMatch.exists, "A row has no switch; Enable and Disable are in its menu.")
        XCTAssertFalse(js("skill-row-release-notes").buttons["Use"].exists, "A row has no Use button; Use is in its menu.")
        hint("skill-hint-broken-skill", row: js("skill-row-broken-skill"))
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'skill-provider-broken-skill'")).firstMatch.exists, "No provider icon shows for an invalid skill.")
        reveal(js("skill-actions-broken-skill")).click()
        XCTAssertTrue(app.menuItems.matching(identifier: "skill-use-broken-skill").firstMatch.waitToExist(timeout: 5), "The menu opens with Use.")
        XCTAssertFalse(app.menuItems.matching(identifier: "skill-use-broken-skill").firstMatch.isEnabled, "No provider can use an invalid skill.")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil({ !self.app.menuItems.matching(identifier: "skill-use-broken-skill").firstMatch.exists }, timeout: 5))
        XCTAssertEqual(js("skill-actions-release-notes").label, "Actions for release-notes")
        reveal(js("skills-empty-docs-site"))
        XCTAssertEqual(pluginText(js("skills-empty-docs-site")), "No skills in docs-site.")
        reveal(pair("skills-page").js)
        attachScreenshot(named: "Skills page: JavaScript above native, every section in one list")
        attachElementScreenshot(reveal(pair("skills-page").js), named: "The JavaScript Skills modal card")

        // An anchor scrolls its side's list to the section; every section stays listed.
        func offset(_ group: XCUIElement, in list: XCUIElement) -> CGFloat { group.frame.minY - list.frame.minY }
        let jsGlobal = js("skills-group-global"), nativeGlobal = native("native-skills-group-global")
        let jsList = js("skills-list"), nativeList = native("native-skills-list")
        // The sample list overflows only a little, so start the JavaScript one at
        // its top (the Repo anchor) to leave the Global anchor room to move it.
        clickAnchor(js("skills-anchor-repo"))
        XCTAssertTrue(waitUntil({ self.pluginText(lastAction) == "Last: jump repo" && abs(offset(js("skills-group-repo"), in: jsList)) < 20 }, timeout: 5),
                      "The Repo anchor scrolls the JavaScript list to its top.")
        let jsBefore = offset(jsGlobal, in: jsList), nativeBefore = offset(nativeGlobal, in: nativeList)
        clickAnchor(js("skills-anchor-global"))
        XCTAssertTrue(waitUntil({ self.pluginText(lastAction) == "Last: jump global" }, timeout: 5), "The Global anchor ran its handler.")
        XCTAssertTrue(waitUntil({ offset(jsGlobal, in: jsList) < jsBefore - 10 || abs(offset(jsGlobal, in: jsList)) < 40 }, timeout: 5),
                      "The Global anchor scrolled the JavaScript list toward Global (\(jsBefore) → \(offset(jsGlobal, in: jsList))).")
        XCTAssertTrue(js("skill-row-release-notes").exists && js("skill-row-shared-notes").exists && js("skill-row-simplify").exists, "Every expanded section stays in the list.")
        XCTAssertEqual(offset(nativeGlobal, in: nativeList), nativeBefore, accuracy: 2, "The native list keeps its own scroll.")
        XCTAssertTrue(hint("skill-linked-shared-notes", row: js("skill-row-shared-notes")).exists, "A linked skill's hint shows Linked.")
        XCTAssertEqual(js("skill-text-quiet-skill").label, "quiet-skill, off", "A skill that is off says so (and is grayed out).")
        attachScreenshot(named: "Skills page: the JavaScript Global anchor scrolled its list")
        clickAnchor(native("native-skills-anchor-global"))
        XCTAssertTrue(waitUntil({ self.pluginText(native("native-last-action")) == "Last: jump global" }, timeout: 5), "The native anchor runs its own handler.")
        XCTAssertTrue(waitUntil({ abs(offset(nativeGlobal, in: nativeList) - offset(jsGlobal, in: jsList)) < 2 }, timeout: 5), "Both lists scroll Global to the same place.")
        for identifier in ["skill-row-shared-notes", "skill-row-quiet-skill", "skill-actions-quiet-skill"] {
            assertSameSize(identifier)
        }
        clickAnchor(js("skills-anchor-repo"))
        XCTAssertTrue(waitUntil({ self.pluginText(lastAction) == "Last: jump repo" }, timeout: 5))
        clickAnchor(native("native-skills-anchor-repo"))

        // The menu's Use runs its handler; Disable grays the row out, turns Use off and offers Enable.
        func openMenu(_ actions: XCUIElement, showing identifier: String) -> XCUIElement {
            reveal(actions).click()
            let item = app.menuItems.matching(identifier: identifier).firstMatch
            XCTAssertTrue(item.waitToExist(timeout: 5), "\(actions) opens its menu with \(identifier).")
            return item
        }
        let jsActions = js("skill-actions-release-notes")
        let use = openMenu(jsActions, showing: "skill-use-release-notes")
        XCTAssertTrue(use.isEnabled && app.menuItems["Disable"].exists, "An enabled skill's menu offers Use and Disable.")
        use.click()
        XCTAssertTrue(waitUntil({ self.pluginText(lastAction) == "Last: use release-notes" }, timeout: 5), "Use ran its JavaScript handler.")
        XCTAssertTrue(waitUntil({ self.pluginText(commit).contains(": text → node ") }, timeout: 5), "Use changed only the readout: \(pluginText(commit))")
        openMenu(jsActions, showing: "skill-toggle-release-notes").click()
        XCTAssertTrue(waitUntil({ js("skill-text-release-notes").label == "release-notes, off" && self.pluginText(lastAction) == "Last: toggle release-notes off" }, timeout: 5),
                      "Disable turned the skill off.")
        XCTAssertEqual(native("native-skill-text-release-notes").label, "release-notes", "The native page keeps its own state.")
        let disabledUse = openMenu(jsActions, showing: "skill-use-release-notes")
        XCTAssertFalse(disabledUse.isEnabled, "Turning a skill off disables Use.")
        XCTAssertTrue(app.menuItems["Enable"].exists, "A skill that is off offers Enable.")
        attachScreenshot(named: "Skills page: release-notes turned off, grayed out, its menu offering Enable")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil({ !disabledUse.exists }, timeout: 5))
        reveal(js("skill-text-release-notes")).click()
        XCTAssertTrue(waitUntil({ self.pluginText(lastAction) == "Last: open release-notes" }, timeout: 5), "A grayed-out skill still responds to a click.")
        openMenu(jsActions, showing: "skill-toggle-release-notes").click()
        XCTAssertTrue(waitUntil({ js("skill-text-release-notes").label == "release-notes" && self.pluginText(lastAction) == "Last: toggle release-notes on" }, timeout: 5),
                      "Enable turned it back on.")

        // A click on a skill's text opens it; a press and hold starts selecting.
        reveal(js("skill-text-release-notes")).click()
        XCTAssertTrue(waitUntil({ self.pluginText(lastAction) == "Last: open release-notes" }, timeout: 5), "A click on the skill ran onPress.")
        js("skill-row-release-notes").press(forDuration: 1.0)
        XCTAssertTrue(waitUntil({ self.pluginText(lastAction) == "Last: select release-notes" }, timeout: 5), "A press and hold ran onLongPress.")
        XCTAssertTrue(js("skills-selection-count").waitToExist(timeout: 5), "Selecting shows the selection's actions.")
        XCTAssertEqual(pluginText(js("skills-selection-count")), "1 selected")
        XCTAssertEqual(js("skill-select-release-notes").label, "Selected", "The pressed skill's checkbox is checked.")
        XCTAssertEqual(js("skill-select-review-login").label, "Not selected")
        XCTAssertFalse(js("skill-actions-release-notes").exists, "Selecting hides a row's own controls.")
        XCTAssertFalse(js("skills-search").exists, "Selecting replaces the search with the selection's actions.")
        XCTAssertTrue(js("skills-fix-selected").exists && js("skills-delete-selected").exists && js("skills-selection-done").exists)
        XCTAssertGreaterThanOrEqual(js("skills-selection-done").frame.minY, js("skills-kind-picker").frame.maxY, "While selecting, the actions replace the search on its row below the header.")
        XCTAssertEqual(js("skills-selection-done").frame.midY, js("skills-selection-count").frame.midY, accuracy: 4, "The selection's count and actions share one row.")
        XCTAssertLessThanOrEqual(js("skills-selection-done").frame.maxY, js("skills-tab-picker").frame.minY, "The anchors stay on their own row below the selection's actions.")
        XCTAssertGreaterThanOrEqual(js("skills-selection-count").frame.minX, pair("skills-page").js.frame.minX, "The selection's row fits the narrow card.")
        XCTAssertLessThanOrEqual(js("skills-selection-done").frame.maxX, pair("skills-page").js.frame.maxX, "The selection's row fits the narrow card.")
        XCTAssertFalse(js("skills-fix-selected").isEnabled, "Nothing selected is broken, so nothing can be fixed.")
        // The button's label is its Label atom's text, or the text inside it.
        func readsFix(_ button: XCUIElement) -> Bool { self.accessibleLabelOrValue(of: button) == "Fix" || button.staticTexts["Fix"].exists }
        XCTAssertTrue(readsFix(js("skills-fix-selected")), "The selection's fix button reads Fix, short enough for the narrow modal.")
        XCTAssertFalse(pair("skills-kind-picker").js.isEnabled, "The kind picker is locked while selecting.")
        XCTAssertTrue(native("native-skill-actions-release-notes").exists, "The native page isn't selecting.")
        attachScreenshot(named: "Skills page: selecting in JavaScript")
        // While selecting, the row's text area is part of the row, so a click on the row's middle lands on it.
        reveal(js("skill-row-review-login")).click()
        XCTAssertTrue(waitUntil({ self.pluginText(js("skills-selection-count")) == "2 selected" }, timeout: 5), "A click on another row adds it.")
        XCTAssertTrue(waitUntil({ js("skills-fix-selected").isEnabled }, timeout: 5), "A selected conflict can be fixed.")
        clickAnchor(js("skills-anchor-builtin"))
        XCTAssertTrue(waitUntil({ self.pluginText(lastAction) == "Last: jump builtin" }, timeout: 5))
        XCTAssertTrue(js("skill-row-simplify").waitToExist(timeout: 5))
        XCTAssertFalse(js("skill-select-simplify").exists, "A built-in skill shows no checkbox.")
        let nativeSkillText = reveal(native("native-skill-text-release-notes"))
        nativeSkillText.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.0)
        XCTAssertTrue(native("native-skills-selection-count").waitToExist(timeout: 5), "The native row starts selecting too.")
        XCTAssertTrue(readsFix(native("native-skills-fix-selected")), "The native selection's fix button reads Fix too.")
        for identifier in ["skills-selection-count", "skills-fix-selected", "skills-delete-selected", "skills-selection-done"] {
            assertSameSize(identifier)
        }
        clickAnchor(js("skills-anchor-repo"))
        XCTAssertTrue(js("skill-select-release-notes").waitToExist(timeout: 5))
        assertSameSize("skill-row-release-notes")
        assertSameSize("skill-select-release-notes")
        reveal(js("skills-selection-done")).click()
        XCTAssertTrue(waitUntil({ !js("skills-selection-count").exists && self.pluginText(lastAction) == "Last: done selecting" }, timeout: 5), "Done ends selecting.")
        XCTAssertTrue(js("skill-actions-release-notes").waitToExist(timeout: 5), "Rows show their controls again.")
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

        // Search runs onChange with the text; Rules hides the anchors and search.
        let search = reveal(js("skills-search"))
        search.click()
        search.typeText("rel")
        XCTAssertTrue(waitUntil({ self.pluginText(lastAction) == "Last: search rel" }, timeout: 5), "Typing in the search ran onChange with the text.")
        reveal(pair("skills-kind-picker").js).radioButtons["Rules"].click()
        XCTAssertTrue(waitUntil({ !js("skills-tab-picker").exists && !js("skills-search").exists }, timeout: 5), "Rules hides the anchors and the search.")
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

    // case-contract: test_conversation_history_defers_earlier_images | A reader that asks history to defer images (--defer-images, as the app does) gets image data only for the newest turn the user started: earlier messages with images come back marked imagesDeferred with no image data, on the newest page, on an earlier --before page, where every image waits, and in the history a send returns, while plain history stays complete and never carries the mark, and the mark is never stored. conversation images returns the exact stored images of the named messages and nothing for a message without images; in a Codex conversation, whose user images live in the provider thread, an earlier image is deferred the same way and read back from the thread. Naming no message fails with invalid_argument and an unknown task fails with not_found. Reopening the conversation in the visible UI reads no image data until the reader scrolls up: each earlier image then loads when its message comes into view and is shown, and a turn sent afterwards from the composer keeps the loaded images without reading them again.
    func test_conversation_history_defers_earlier_images() throws {
        let claude = dataDirectory.appendingPathComponent("claude-fixture-deferred-images")
        try copyFixtureFile(at: WorkspaceFixture.root.appendingPathComponent("claude-fixture-ui"), to: claude)
        let codex = dataDirectory.appendingPathComponent("codex-fixture-image-serial-success")
        try copyFixtureFile(at: WorkspaceFixture.root.appendingPathComponent("codex-fixture-ui"), to: codex)
        for (executable, owner, contents) in [
            (claude, ".playhouse-claude-fixture-owner", "Playhouse test owns this Claude Code protocol fixture (v1).\n"),
            (codex, ".playhouse-codex-fixture-owner", "Playhouse test owns this Codex protocol fixture (v1).\n"),
        ] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            try Data(contents.utf8).write(to: dataDirectory.appendingPathComponent(owner))
        }
        claudeFixtureExecutable = claude.path
        codexFixtureExecutable = codex.path
        launchApp(defaultParent: fixture.parent.path)

        func writeImage(_ name: String, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> String {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 48, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let color = NSColor(deviceRed: red, green: green, blue: blue, alpha: 1)
            for x in 0..<48 { for y in 0..<48 { bitmap.setColor(color, atX: x, y: y) } }
            let url = dataDirectory.appendingPathComponent(name)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
            return url.path
        }
        let firstImage = try writeImage("first-turn.png", red: 0.1, green: 0.6, blue: 0.7)
        let secondImage = try writeImage("second-turn.png", red: 0.9, green: 0.5, blue: 0.1)
        func result(_ arguments: [String]) throws -> [String: Any] {
            try XCTUnwrap(try runCLI(arguments)["result"] as? [String: Any])
        }
        func messages(_ history: [String: Any]) -> [[String: Any]] { history["messages"] as? [[String: Any]] ?? [] }
        func imageURLs(_ message: [String: Any]) -> [String] { message["imageDataURLs"] as? [String] ?? [] }
        func imageMessages(_ history: [String: Any]) -> [[String: Any]] {
            messages(history).filter { !imageURLs($0).isEmpty || $0["imagesDeferred"] as? Bool == true }
        }
        /// Each message holding or deferring images, as "id:image count:deferred".
        func imageStates(_ history: [String: Any]) -> [String] {
            imageMessages(history).map { "\($0["id"] as? String ?? ""):\(imageURLs($0).count):\($0["imagesDeferred"] as? Bool == true)" }
        }
        func reads(_ event: String, taskID: String) throws -> [[String: Any]] {
            try diagnosticEvents().filter { $0["event"] as? String == event && $0["taskID"] as? String == taskID.uppercased() }
        }

        let taskID = try XCTUnwrap(try result([
            "task", "create", "--title", "Claude deferred images", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
        ])["id"] as? String)
        _ = try runCLI(["conversation", "send", taskID, "--message", "Say hello.", "--image", firstImage])
        let second = try result(["conversation", "send", taskID, "--message", "Long history turn 2.", "--image", secondImage, "--defer-images"])
        let full = try result(["conversation", "history", taskID])
        let fullImageMessages = imageMessages(full)
        XCTAssertEqual(fullImageMessages.map { $0["text"] as? String }, ["Say hello.", "Long history turn 2."])
        let firstMessage = fullImageMessages[0], secondMessage = fullImageMessages[1]
        let firstID = try XCTUnwrap(firstMessage["id"] as? String), secondID = try XCTUnwrap(secondMessage["id"] as? String)
        XCTAssertTrue(fullImageMessages.allSatisfy { imageURLs($0).count == 1 && imageURLs($0)[0].hasPrefix("data:image/png;base64,") })
        XCTAssertNotEqual(imageURLs(firstMessage), imageURLs(secondMessage))
        XCTAssertTrue(messages(full).allSatisfy { $0["imagesDeferred"] == nil }, "Plain history is complete and unmarked.")

        func assertFirstDeferred(_ history: [String: Any], _ context: String) {
            XCTAssertEqual(imageStates(history), ["\(firstID):0:true", "\(secondID):1:false"], context)
            XCTAssertEqual(imageMessages(history).last.map { $0 as NSDictionary }, secondMessage as NSDictionary,
                           "\(context): the newest turn keeps its image and is not marked.")
        }
        assertFirstDeferred(second, "The history a send returns defers the earlier turn's image")
        let deferred = try result(["conversation", "history", taskID, "--defer-images"])
        assertFirstDeferred(deferred, "Complete history defers the earlier turn's image")
        func withoutImages(_ history: [String: Any]) -> NSArray {
            messages(history).map { message -> [String: Any] in
                var message = message
                message["imageDataURLs"] = [String]()
                message["imagesDeferred"] = nil
                return message
            } as NSArray
        }
        XCTAssertEqual(withoutImages(deferred), withoutImages(full), "Deferring changes nothing but the image data.")
        let page = try result(["conversation", "history", taskID, "--limit", "80", "--defer-images"])
        assertFirstDeferred(page, "The newest page defers the earlier turn's image")
        XCTAssertEqual(page["earlierMessageCount"] as? Int, 0)
        let newestRead = try XCTUnwrap(try reads("conversation.history.read", taskID: taskID).last)
        XCTAssertEqual(["source", "deferredImageMessageCount", "hydratedImageMessageCount"].map { newestRead[$0] as? String }, ["stored-page", "1", "1"])
        let earlier = try result(["conversation", "history", taskID, "--limit", "80", "--before", secondID, "--defer-images"])
        XCTAssertEqual(imageStates(earlier), ["\(firstID):0:true"], "An earlier page defers every image it holds.")
        let earlierRead = try XCTUnwrap(try reads("conversation.history.read", taskID: taskID).last)
        XCTAssertEqual(["deferredImageMessageCount", "hydratedImageMessageCount"].map { earlierRead[$0] as? String }, ["1", "0"])
        let plainReadCount = try reads("conversation.history.read", taskID: taskID).count
        _ = try result(["conversation", "history", taskID, "--limit", "80"])
        let plainRead = try reads("conversation.history.read", taskID: taskID)[plainReadCount]
        XCTAssertEqual(["deferredImageMessageCount", "hydratedImageMessageCount"].map { plainRead[$0] as? String }, ["0", "2"])

        let imageless = try XCTUnwrap(messages(full).first { $0["role"] as? String == "assistant" }?["id"] as? String)
        func images(_ arguments: [String]) throws -> [[String: Any]] {
            try XCTUnwrap(try runCLI(["conversation", "images"] + arguments)["result"] as? [[String: Any]])
        }
        let read = try images([taskID, "--message", secondID, "--message", imageless, "--message", firstID])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: read.map { ($0["id"] as? String ?? "", imageURLs($0)) }),
                       [firstID: imageURLs(firstMessage), secondID: imageURLs(secondMessage)],
                       "The named messages' exact images are returned, and nothing for a message without images.")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: read.map { ($0["id"] as? String ?? "", $0["turnID"] as? String) }),
                       [firstID: firstMessage["turnID"] as? String, secondID: secondMessage["turnID"] as? String])
        let imagesRead = try XCTUnwrap(try reads("conversation.images.read", taskID: taskID).last)
        XCTAssertEqual(["requestedMessageCount", "returnedMessageCount", "readProviderThread"].map { imagesRead[$0] as? String }, ["3", "2", "false"])
        XCTAssertEqual(try images([taskID, "--message", imageless, "--message", "no-such-message"]).count, 0)
        assertCLIError(try runCLI(["conversation", "images", taskID], expectedStatus: 2), code: "invalid_argument")
        assertCLIError(try runCLI(["conversation", "images", UUID().uuidString, "--message", firstID], expectedStatus: 3), code: "not_found")

        let third = try result(["conversation", "send", taskID, "--message", "Say hello.", "--defer-images"])
        XCTAssertEqual(imageStates(third), ["\(firstID):0:true", "\(secondID):0:true"], "Once a later turn starts, both earlier images are deferred.")
        XCTAssertEqual(try reads("conversation.history.read", taskID: taskID).last?["deferredImageMessageCount"] as? String, "2")
        let payloads = try conversationRows("SELECT payload FROM conversation_messages WHERE task_id = '\(taskID.uppercased())'").compactMap { $0[0] }
        XCTAssertFalse(payloads.isEmpty)
        XCTAssertFalse(payloads.contains { $0.contains("imagesDeferred") }, "The mark describes one read and is never stored.")
        let resumed = try result(["conversation", "history", taskID])
        XCTAssertEqual(imageMessages(resumed) as NSArray, [firstMessage, secondMessage] as NSArray, "Plain history still carries every image after deferred reads.")

        // Codex keeps a user's images in its thread, so a deferred one is read back from there.
        let codexTask = try XCTUnwrap(try result([
            "task", "create", "--title", "Codex deferred images", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "codex",
        ])["id"] as? String)
        _ = try runCLI(["conversation", "send", codexTask, "--image", firstImage])
        _ = try runCLI(["conversation", "send", codexTask, "--message", "Continue using the earlier image as context."])
        let codexImageMessages = imageMessages(try result(["conversation", "history", codexTask]))
        XCTAssertEqual(codexImageMessages.map { $0["role"] as? String }, ["user"])
        let codexImageID = try XCTUnwrap(codexImageMessages.first?["id"] as? String)
        func codexImageRead() throws -> [String?] {
            let codexImages = try images([codexTask, "--message", codexImageID])
            XCTAssertEqual(codexImages.map { $0["id"] as? String }, [codexImageID])
            XCTAssertEqual(codexImages.first.map(imageURLs), codexImageMessages.first.map(imageURLs))
            let read = try XCTUnwrap(try reads("conversation.images.read", taskID: codexTask).last)
            return ["returnedMessageCount", "readProviderThread"].map { read[$0] as? String }
        }
        XCTAssertEqual(imageStates(try result(["conversation", "history", codexTask, "--defer-images"])), ["\(codexImageID):0:true"],
                       "A Codex thread's earlier image is deferred too.")
        XCTAssertEqual(try codexImageRead(), ["1", "true"], "A Codex image is read from its thread.")

        // The app defers images itself: opening the conversation reads none of the earlier ones.
        let latestQuestionID = try XCTUnwrap(messages(third).last {
            $0["role"] as? String == "user" && $0["text"] as? String == "Say hello."
        }?["id"] as? String)
        let historyReadsBeforeOpen = try reads("conversation.history.read", taskID: taskID).count
        let imageReadsBeforeOpen = try reads("conversation.images.read", taskID: taskID).count
        func imageReadsSinceOpen() -> [[String: Any]] {
            Array(((try? reads("conversation.images.read", taskID: taskID)) ?? []).dropFirst(imageReadsBeforeOpen))
        }
        openTask(named: "Claude deferred images")
        let scrollView = element("conversation-scroll-view")
        let latestQuestion = element("user-message-\(latestQuestionID)")
        XCTAssertTrue(waitUntil({ latestQuestion.exists && latestQuestion.isHittable }, timeout: 20), "The latest question is visible on open.")
        XCTAssertTrue(waitUntil({
            ((try? reads("conversation.history.read", taskID: taskID)) ?? []).dropFirst(historyReadsBeforeOpen).contains {
                $0["deferredImageMessageCount"] as? String == "2" && $0["hydratedImageMessageCount"] as? String == "0"
            }
        }, timeout: 10), "Opening reads the newest page with both earlier images deferred.")
        let firstChatImage = element("chat-image-\(firstID)-0")
        let secondChatImage = element("chat-image-\(secondID)-0")
        XCTAssertFalse(firstChatImage.exists || secondChatImage.exists, "No earlier image is shown before the reader scrolls up.")
        XCTAssertEqual(imageReadsSinceOpen().count, 0, "Opening the conversation reads no deferred image data.")
        attachScreenshot(named: "Deferred images: conversation opens on the latest turn without reading earlier images")

        func isVisible(_ candidate: XCUIElement) -> Bool {
            candidate.exists && scrollView.frame.intersects(candidate.frame)
        }
        func scrollUp(until condition: () -> Bool) {
            for _ in 0..<60 where !condition() {
                scrollView.scroll(byDeltaX: 0, deltaY: 400)
                _ = waitUntil(condition, timeout: 1)
            }
        }
        XCTAssertEqual(imageReadsSinceOpen().count, 0, "No image data is read while the reader stays on the latest turn.")
        scrollUp(until: { isVisible(secondChatImage) })
        XCTAssertTrue(waitUntil({ isVisible(secondChatImage) }, timeout: 10), "The second turn's image loads once its message scrolls into view.")
        XCTAssertFalse(element("deferred-chat-image-\(secondID)").exists, "The loaded image replaces its placeholder.")
        attachScreenshot(named: "Deferred images: the second turn's image loaded on scroll")
        scrollUp(until: { isVisible(firstChatImage) })
        XCTAssertTrue(waitUntil({ isVisible(firstChatImage) }, timeout: 10), "The first turn's image loads once its message scrolls into view.")
        attachScreenshot(named: "Deferred images: the first turn's image loaded on scroll")
        let loaded = imageReadsSinceOpen()
        XCTAssertEqual(loaded.compactMap { Int($0["returnedMessageCount"] as? String ?? "") }.reduce(0, +), 2,
                       "Each earlier image is read once, when its message comes into view.")
        XCTAssertTrue(loaded.allSatisfy { $0["readProviderThread"] as? String == "false" })

        // A turn sent from the composer brings back history with the images deferred again; the loaded ones stay.
        let historyReadsBeforeSend = try reads("conversation.history.read", taskID: taskID).count
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 10))
        composer.click()
        composer.typeText("Say hello again.")
        element("send-message-button").click()
        func sentTurnAnswered() -> Bool {
            guard let history = try? result(["conversation", "history", taskID]) else { return false }
            let ordinary = ordinaryMessages(messages(history))
            return ordinary.dropLast().last?["text"] as? String == "Say hello again." && ordinary.last?["role"] as? String == "assistant"
        }
        XCTAssertTrue(waitUntil({ sentTurnAnswered() && self.noTurnIsRunning() }, timeout: 60), "The new turn and its status nudges should finish.")
        // The test's own polls read complete history without a limit; only the window reads the newest 80.
        XCTAssertTrue(waitUntil({
            ((try? reads("conversation.history.read", taskID: taskID)) ?? []).dropFirst(historyReadsBeforeSend).contains {
                $0["messageLimit"] as? String == "80" && $0["deferredImageMessageCount"] as? String == "2"
                    && $0["hydratedImageMessageCount"] as? String == "0"
            }
        }, timeout: 10), "The history the window receives for the completed turn defers the earlier images again.")
        XCTAssertFalse(try reads("conversation.history.read", taskID: taskID).dropFirst(historyReadsBeforeSend).contains {
            $0["messageLimit"] as? String == "80" && $0["hydratedImageMessageCount"] as? String != "0"
        }, "No history the window receives after the send carries earlier image data.")
        scrollUp(until: { isVisible(secondChatImage) })
        XCTAssertTrue(waitUntil({ isVisible(secondChatImage) }, timeout: 10), "The second turn's image stays loaded after a later turn.")
        scrollUp(until: { isVisible(firstChatImage) })
        XCTAssertTrue(waitUntil({ isVisible(firstChatImage) }, timeout: 10), "The first turn's image stays loaded after a later turn.")
        XCTAssertEqual(imageReadsSinceOpen().count, loaded.count, "Images already loaded are not read again after a later turn.")
        attachScreenshot(named: "Deferred images: loaded images kept after a later turn")
    }

    // case-contract: test_codex_stop_during_turn_launch_stops_before_agent_starts | A Stop that arrives while Codex is still starting the thread moves the task out of In Progress at once, before Codex answers. Nothing of the message is sent: the send ends with turn_stopped, no turn starts, the prompt returns to the draft with no failure reason, and the task returns to the status it had before the send. A steer sent for that message before the Stop is stopped with it: it ends with turn_stopped, is not queued and never runs as a turn of its own. A follow-up queued during that launch stays in the queue, marked as needing the user's action, and does not run. A Stop that arrives after turn/start was sent but before Codex acknowledged the turn also leaves In Progress at once, and Codex's turn/interrupt follows as soon as the turn has its ID, leaving the task in Waiting Response. In the window Stop is enabled as soon as the message is sent, and clicking it replaces Stop at once while the provider is still held; the stopped steer's bubble leaves the transcript and its text returns to the composer with the stopped message, without an error.
    func test_codex_stop_during_turn_launch_stops_before_agent_starts() throws {
        let title = "Codex stop during launch"
        let prompt = "Hold until stopped."
        let steerText = "Steer the message that is about to be stopped."
        let followUpText = "Run this follow-up after the stopped message."
        let executable = try prepareLaunchFixture(provider: "codex", name: "codex-fixture-hold-interrupt")
        let taskID = try createLaunchTask(title: title, provider: "codex")
        let priorStatus = try XCTUnwrap(try taskRecord(id: taskID)?["status"] as? String)

        // Stopped while the thread is starting: nothing was sent yet.
        try writeLaunchMarker(executable, "thread-start-pause")
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: title)
        let composer = element("message-composer")
        XCTAssertTrue(composer.waitToExist(timeout: 10))
        composer.click()
        composer.typeText(prompt)
        let sentText = try XCTUnwrap(composer.value as? String)
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ self.launchMarkerExists(executable, "thread-start-ready") }, timeout: 15), "Codex should be held while starting the thread.")
        let stop = element("pause-response-button")
        XCTAssertTrue(stop.waitToExist(timeout: 5), "Send should turn into Stop as soon as the message is sent.")
        XCTAssertTrue(stop.isEnabled, "Stop should work while Codex is still starting the thread.")
        composer.click()
        composer.typeText(steerText)
        composer.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(transcriptMessage(steerText).waitToExist(timeout: 2), "The steer should join the transcript at once.")
        composer.click()
        composer.typeText(followUpText)
        composer.typeKey(.return, modifierFlags: [])
        var followUpID = ""
        XCTAssertTrue(waitUntil({
            let rows = (try? self.runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]) ?? []
            followUpID = rows.first(where: { $0["text"] as? String == followUpText })?["id"] as? String ?? ""
            return !followUpID.isEmpty
        }, timeout: 5), "Return should queue a follow-up while Codex is still starting the conversation.")
        XCTAssertTrue(element("queued-message-text-\(followUpID)").waitToExist(timeout: 2))
        attachScreenshot(named: "Codex launch: Stop is available while the thread starts")
        attachElementScreenshot(stop, named: "Codex launch: the Stop button while the thread starts")
        stop.click()
        XCTAssertTrue(waitUntil({ !self.element("pause-response-button").exists }, timeout: 2), "Stop should be replaced as soon as it is clicked, while Codex is still held.")
        XCTAssertTrue(element("continue-response-button").exists || element("send-message-button").exists, "Stop gives way to Continue or Send.")
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["status"] as? String) != "In Progress" }, timeout: 5), "Stop should move the task out of In Progress while Codex is still starting.")
        attachScreenshot(named: "Codex launch: stopped at once while the thread starts")
        try? FileManager.default.removeItem(atPath: executable + ".thread-start-pause")
        try writeLaunchMarker(executable, "thread-start-release")
        XCTAssertTrue(waitUntil({
            let value = composer.value as? String ?? ""
            return value.contains(sentText) && value.contains(steerText)
        }, timeout: 15), "The stopped message and its stopped steer should return to the composer.")
        let returnedText = try XCTUnwrap(composer.value as? String)
        XCTAssertEqual(returnedText.count, sentText.count + steerText.count + 1, "Each stopped text returns once.")
        XCTAssertTrue(element("send-message-button").waitToExist(timeout: 5), "A message stopped before it was sent leaves nothing to continue.")
        let keptRows = try XCTUnwrap(try runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]])
        XCTAssertEqual(keptRows.compactMap { $0["id"] as? String }, [followUpID], "The stopped steer must not be queued; only the queued follow-up stays.")
        XCTAssertEqual(keptRows.first?["state"] as? String, "needsAction", "A follow-up queued for a stopped message waits for the user instead of running.")
        XCTAssertTrue(element("queued-message-needs-action-\(followUpID)").waitToExist(timeout: 5), "The kept follow-up should show that it needs the user's action.")
        XCTAssertEqual(app.groups.matching(NSPredicate(format: "identifier BEGINSWITH %@", "user-message-")).count, 0, "A message stopped before it was sent should leave the transcript.")
        attachScreenshot(named: "Codex launch: the queued follow-up waits for the user after the stop")
        element("remove-queued-message-\(followUpID)").click()
        XCTAssertTrue(waitUntil({ ((try? self.runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]])?.count ?? 1) == 0 }, timeout: 5), "The kept follow-up can be removed.")
        XCTAssertFalse(element("codex-chat-error").exists, "A user's stop is not an error.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, priorStatus, "A message stopped before it was sent leaves the task where it was.")
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["savedPrompt"] as? String) == returnedText }, timeout: 5), "The returned text is saved as the draft.")
        XCTAssertNil(try taskRecord(id: taskID)?["statusMessage"] as? String, "A user's stop leaves no failure reason.")
        XCTAssertFalse(launchMarkerExists(executable, "interrupt-ready"), "No Codex turn may start for a message stopped before it was sent.")
        attachScreenshot(named: "Codex launch: the stopped message is back in the composer")

        // Stopped after turn/start was sent, before Codex acknowledged the turn.
        try writeLaunchMarker(executable, "turn-start-pause")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ self.launchMarkerExists(executable, "turn-start-ready") }, timeout: 15), "Codex should hold its turn/start answer.")
        XCTAssertTrue(stop.waitToExist(timeout: 5))
        XCTAssertTrue(stop.isEnabled, "Stop should work before Codex acknowledges the turn.")
        stop.click()
        XCTAssertTrue(element("continue-response-button").waitToExist(timeout: 2), "Continue should replace Stop at once, before Codex acknowledges the turn.")
        XCTAssertFalse(element("pause-response-button").exists)
        attachScreenshot(named: "Codex launch: Continue before Codex acknowledged the turn")
        attachElementScreenshot(element("continue-response-button"), named: "Codex launch: the Continue button before the turn is acknowledged")
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["status"] as? String) == "Waiting Response" }, timeout: 5))
        XCTAssertFalse(launchMarkerExists(executable, "interrupt-received"), "Codex cannot be interrupted before the turn has an ID.")
        try writeLaunchMarker(executable, "turn-start-release")
        XCTAssertTrue(waitUntil({ self.launchMarkerExists(executable, "interrupt-received") }, timeout: 15), "The interrupt should follow as soon as the turn has its ID.")
        XCTAssertFalse(element("pause-response-button").exists, "The stopped turn starting late must not bring Stop back.")
        try writeLaunchMarker(executable, "interrupt-release")
        XCTAssertTrue(waitUntil({ (try? self.runCLI(["conversation", "runtime"])["result"] as? [String: Any])?["activeThreadIDs"] as? [String] == [] }, timeout: 15), "The stopped turn should settle.")
        XCTAssertTrue(element("continue-response-button").exists, "The stopped turn stays resumable.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response")
        XCTAssertNil(try taskRecord(id: taskID)?["statusMessage"] as? String)
    }

    // case-contract: test_claude_stop_during_turn_launch_interrupts_once_started | A Stop that arrives while Claude Code is still starting the session moves the task to Waiting Response at once, before the session answers. The control interrupt follows as soon as the turn has started, the send settles as stopped without a failure reason, and the task stays in Waiting Response. In the window Stop is enabled as soon as the message is sent, and clicking it replaces Stop with Continue at once while the session is still starting.
    func test_claude_stop_during_turn_launch_interrupts_once_started() throws {
        let title = "Claude stop during launch"
        let executable = try prepareLaunchFixture(provider: "claude", name: "claude-fixture-ui")
        let taskID = try createLaunchTask(title: title, provider: "claude")
        try writeLaunchMarker(executable, "launch-pause")
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: title)
        let composer = element("message-composer")
        XCTAssertTrue(composer.waitToExist(timeout: 10))
        composer.click()
        composer.typeText("Hold until stopped.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ self.launchMarkerExists(executable, "launch-ready") }, timeout: 15), "Claude Code should be held while starting the session.")
        let stop = element("pause-response-button")
        XCTAssertTrue(stop.waitToExist(timeout: 5), "Send should turn into Stop as soon as the message is sent.")
        XCTAssertTrue(stop.isEnabled, "Stop should work while Claude Code is still starting the session.")
        attachScreenshot(named: "Claude launch: Stop is available while the session starts")
        attachElementScreenshot(stop, named: "Claude launch: the Stop button while the session starts")
        stop.click()
        XCTAssertTrue(element("continue-response-button").waitToExist(timeout: 2), "Continue should replace Stop at once, while the session is still starting.")
        attachElementScreenshot(element("continue-response-button"), named: "Claude launch: the Continue button while the session starts")
        XCTAssertFalse(element("pause-response-button").exists)
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["status"] as? String) == "Waiting Response" }, timeout: 5), "Stop should move the task to Waiting Response while the session is still starting.")
        XCTAssertFalse(launchMarkerExists(executable, "interrupt-received"), "A session that has not started cannot be interrupted yet.")
        attachScreenshot(named: "Claude launch: stopped at once while the session starts")
        try? FileManager.default.removeItem(atPath: executable + ".launch-pause")
        try writeLaunchMarker(executable, "launch-release")
        XCTAssertTrue(waitUntil({ self.launchMarkerExists(executable, "interrupt-received") }, timeout: 15), "The interrupt should follow as soon as the turn has started.")
        XCTAssertFalse(element("pause-response-button").exists, "The stopped turn starting late must not bring Stop back.")
        try writeLaunchMarker(executable, "interrupt-release")
        XCTAssertTrue(waitUntil({ (try? self.runCLI(["conversation", "runtime"])["result"] as? [String: Any])?["activeThreadIDs"] as? [String] == [] }, timeout: 15), "The stopped turn should settle.")
        XCTAssertTrue(element("continue-response-button").exists, "The stopped turn stays resumable.")
        XCTAssertFalse(element("codex-chat-error").exists, "A user's stop is not an error.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response")
        XCTAssertNil(try taskRecord(id: taskID)?["statusMessage"] as? String, "A user's stop leaves no failure reason.")
    }

    // case-contract: test_codex_steer_during_turn_launch_reaches_started_turn | A steer sent while Codex is still starting the thread waits for the turn instead of missing it: once the turn has its ID the steer reaches that turn through turn/steer and is not queued for a turn of its own. A follow-up can be queued during the same launch, before Codex has named the conversation; steered, it reaches that turn the same way and leaves the queue. One left in the queue runs once as a turn of its own after that turn ends. In the window the steer's bubble joins the transcript and the composer clears at once, a follow-up typed with Return joins the queue at once without an error, and its row gives way to its bubble at once when steered, while Codex is still held and has not received either.
    func test_codex_steer_during_turn_launch_reaches_started_turn() throws {
        let title = "Codex steer during launch"
        let steerText = "Steer the turn that is still starting."
        let rowText = "Steer this queued follow-up into the starting turn."
        let laterText = "Run this follow-up after the starting turn."
        let executable = try prepareLaunchFixture(provider: "codex", name: "codex-fixture-steer-queue-serial-success-wait")
        let taskID = try createLaunchTask(title: title, provider: "codex")
        try writeLaunchMarker(executable, "thread-start-pause")
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: title)
        let composer = element("message-composer")
        XCTAssertTrue(composer.waitToExist(timeout: 10))
        composer.click()
        composer.typeText("Start a turn slowly.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ self.launchMarkerExists(executable, "thread-start-ready") }, timeout: 15), "Codex should be held while starting the thread.")
        composer.click()
        composer.typeText(steerText)
        composer.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(transcriptMessage(steerText).waitToExist(timeout: 2), "The steer should join the transcript at once, while Codex is still held.")
        XCTAssertEqual(composer.value as? String, "", "The composer should clear as soon as the steer is sent.")
        XCTAssertFalse(launchMarkerExists(executable, "resolve-ready"), "Codex has not started the turn, so it cannot have the steer yet.")
        attachScreenshot(named: "Codex launch: the steer shows before Codex has it")
        attachElementScreenshot(transcriptMessage(steerText), named: "Codex launch: the steer's bubble")

        // A queued follow-up steered during the same launch.
        composer.click()
        composer.typeText(rowText)
        composer.typeKey(.return, modifierFlags: [])
        var rowID = ""
        XCTAssertTrue(waitUntil({
            let rows = (try? self.runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]) ?? []
            rowID = rows.first(where: { $0["text"] as? String == rowText })?["id"] as? String ?? ""
            return !rowID.isEmpty
        }, timeout: 5), "Return should queue a follow-up while Codex is still starting the conversation.")
        XCTAssertTrue(element("queued-message-text-\(rowID)").waitToExist(timeout: 2), "The queued follow-up's row should show at once.")
        XCTAssertEqual(composer.value as? String, "", "The composer should clear as soon as the follow-up is queued.")
        XCTAssertFalse(element("codex-chat-error").exists, "Queueing during the launch is not an error.")
        XCTAssertFalse(launchMarkerExists(executable, "resolve-ready"))
        attachScreenshot(named: "Codex launch: a follow-up is queued while the thread starts")
        let rowSteer = element("steer-queued-message-\(rowID)")
        XCTAssertTrue(rowSteer.waitToExist(timeout: 5), "The queued follow-up should offer Steer while Codex is still starting.")
        rowSteer.click()
        XCTAssertTrue(transcriptMessage(rowText).waitToExist(timeout: 2), "The steered follow-up's bubble should join the transcript at once.")
        XCTAssertTrue(waitUntil({ !self.element("queued-message-text-\(rowID)").exists }, timeout: 2), "The steered follow-up's row should give way to its bubble at once.")
        XCTAssertFalse(launchMarkerExists(executable, "resolve-ready"), "Codex has not started the turn, so it cannot have the follow-up yet.")
        attachScreenshot(named: "Codex launch: the steered follow-up shows before Codex has it")

        // A follow-up queued during the launch and left in the queue.
        composer.click()
        composer.typeText(laterText)
        composer.typeKey(.return, modifierFlags: [])
        var laterID = ""
        XCTAssertTrue(waitUntil({
            let rows = (try? self.runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]) ?? []
            laterID = rows.first(where: { $0["text"] as? String == laterText })?["id"] as? String ?? ""
            return !laterID.isEmpty
        }, timeout: 5), "Return should queue a second follow-up while Codex is still starting the conversation.")
        XCTAssertTrue(element("queued-message-text-\(laterID)").waitToExist(timeout: 2))

        try? FileManager.default.removeItem(atPath: executable + ".thread-start-pause")
        try writeLaunchMarker(executable, "thread-start-release")
        XCTAssertTrue(waitUntil({ self.launchMarkerExists(executable, "resolve-ready") }, timeout: 15), "The steered turn should be active.")
        XCTAssertTrue(waitUntil({ (try? String(contentsOfFile: executable + ".steers-received", encoding: .utf8)) == "2" }, timeout: 15), "Codex should take both steers in the turn that was starting.")
        XCTAssertTrue(waitUntil({
            (try? self.runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == [laterID]
        }, timeout: 10), "Only the follow-up that was not steered stays queued.")
        XCTAssertTrue(element("queued-message-text-\(laterID)").exists)
        try writeLaunchMarker(executable, "resolve-continue")
        XCTAssertTrue(waitUntil({ ((try? self.runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]])?.count ?? 1) == 0 }, timeout: 30), "The follow-up left in the queue should be delivered after the steered turn.")
        XCTAssertTrue(transcriptMessage(laterText).waitToExist(timeout: 10), "The delivered follow-up should join the transcript.")
        XCTAssertTrue(waitUntil({ !self.element("pause-response-button").exists }, timeout: 30), "Both turns should finish.")
        let protocolHistory = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: executable + ".history"))) as? [String: Any])
        let steerRequests = try XCTUnwrap(protocolHistory["steerRequests"] as? [[String: Any]], "Codex should have received the steers through turn/steer.")
        XCTAssertEqual(Set(steerRequests.compactMap { ($0["input"] as? [[String: String]])?.first?["text"] }), [steerText, rowText])
        XCTAssertEqual(steerRequests.count, 2)
        let turnPrompts = (protocolHistory["messages"] as? [[String: Any]] ?? []).compactMap { $0["userMessage"] as? String }
        XCTAssertFalse(turnPrompts.contains(steerText), "The steer must not have started a turn of its own.")
        XCTAssertFalse(turnPrompts.contains(rowText), "The steered follow-up must not have started a turn of its own.")
        XCTAssertEqual(turnPrompts.filter { $0 == laterText }.count, 1, "The follow-up left in the queue runs once as a turn of its own.")
        XCTAssertEqual(turnPrompts.firstIndex(of: laterText), 1, "It runs right after the turn that was starting.")
        XCTAssertFalse(element("queued-message-text-\(laterID)").exists)
        for text in [steerText, rowText, laterText] {
            let bubbles = app.groups.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "user-message-", text))
            XCTAssertEqual(bubbles.count, 1, "The delivered steer should stay in the transcript exactly once.")
        }
        XCTAssertFalse(element("queued-message-text-\(rowID)").exists)
        attachScreenshot(named: "Codex launch: both steers stayed in the finished turn")
    }

    // case-contract: test_codex_stop_reaches_message_waiting_behind_stopping_turn | A message sent while the task's earlier turn is still being stopped waits for that turn, and a Stop that arrives while it waits stops it too. That Stop answers at once without asking Codex to interrupt a second time; once the earlier turn is over the waiting send ends with turn_stopped, no second turn starts, and the task stays in Waiting Response with no failure reason. In the window Continue replaces Stop at once, the stopped Continue's message leaves the transcript without an error, and Continue stays available for the turn that was stopped first. The stopped message is saved neither as a draft nor as a prompt still being sent.
    func test_codex_stop_reaches_message_waiting_behind_stopping_turn() throws {
        let title = "Codex stop while a message waits"
        let continueText = "Continue with the same request from where you left off."
        let executable = try prepareLaunchFixture(provider: "codex", name: "codex-fixture-hold-interrupt")
        let taskID = try createLaunchTask(title: title, provider: "codex")
        let events: (String) -> Int = { name in
            ((try? self.diagnosticEvents()) ?? []).filter {
                $0["event"] as? String == name && ($0["taskID"] as? String)?.lowercased() == taskID.lowercased()
            }.count
        }
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: title)
        let composer = element("message-composer")
        XCTAssertTrue(composer.waitToExist(timeout: 10))
        composer.click()
        composer.typeText("Hold until stopped.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ self.launchMarkerExists(executable, "interrupt-ready") }, timeout: 15), "The first turn should be running.")
        let stop = element("pause-response-button")
        XCTAssertTrue(stop.waitToExist(timeout: 5))
        stop.click()
        XCTAssertTrue(waitUntil({ self.launchMarkerExists(executable, "interrupt-received") }, timeout: 10), "Codex should hold its answer to the first Stop.")
        let resume = element("continue-response-button")
        XCTAssertTrue(resume.waitToExist(timeout: 2))
        XCTAssertTrue(resume.isEnabled, "Continue should work while Codex is still stopping the turn.")
        resume.click()
        XCTAssertTrue(waitUntil({ events("conversation.send.accepted") == 2 }, timeout: 10), "The Continue should be accepted while the first turn is still being stopped.")
        XCTAssertTrue(transcriptMessage(continueText).waitToExist(timeout: 5), "The Continue's message should show while it waits.")
        XCTAssertTrue(stop.waitToExist(timeout: 5), "A message that waits for its turn can be stopped.")
        XCTAssertTrue(stop.isEnabled)
        attachScreenshot(named: "Codex waiting message: Stop is available while the earlier turn is still stopping")
        attachElementScreenshot(stop, named: "Codex waiting message: the Stop button")
        stop.click()
        XCTAssertTrue(resume.waitToExist(timeout: 2), "Continue should replace Stop at once, while Codex still holds the first Stop.")
        XCTAssertFalse(element("pause-response-button").exists)
        XCTAssertFalse(launchMarkerExists(executable, "interrupt-release"))
        attachScreenshot(named: "Codex waiting message: stopped at once")
        attachElementScreenshot(resume, named: "Codex waiting message: the Continue button")
        try writeLaunchMarker(executable, "interrupt-release")
        XCTAssertTrue(waitUntil({ (try? self.runCLI(["conversation", "runtime"])["result"] as? [String: Any])?["activeThreadIDs"] as? [String] == [] }, timeout: 15), "The stopped turn should settle.")
        XCTAssertTrue(waitUntil({ !self.transcriptMessage(continueText).exists }, timeout: 10), "The stopped Continue's message should leave the transcript.")
        XCTAssertTrue(resume.waitToExist(timeout: 5), "Continue stays available for the turn that was stopped first.")
        XCTAssertTrue(waitUntil({ resume.isEnabled }, timeout: 5))
        XCTAssertFalse(element("pause-response-button").exists)
        XCTAssertFalse(element("codex-chat-error").exists, "A user's stop is not an error.")
        XCTAssertEqual(composer.value as? String, "", "A stopped Continue is not a draft.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response")
        XCTAssertNil(try taskRecord(id: taskID)?["statusMessage"] as? String, "A user's stop leaves no failure reason.")
        XCTAssertTrue(waitUntil({
            guard let record = try? self.taskRecord(id: taskID) else { return false }
            return record["hasUnsentDraft"] as? Bool == false && record["pendingSubmittedPrompt"] as? String == nil
        }, timeout: 10), "A stopped Continue is saved neither as a draft nor as a prompt still being sent.")
        XCTAssertNotEqual(try taskRecord(id: taskID)?["savedPrompt"] as? String, continueText)
        XCTAssertEqual(try String(contentsOfFile: executable + ".held-turns", encoding: .utf8).split(whereSeparator: \.isNewline).count, 1, "Codex should have received one turn only.")
        XCTAssertFalse(launchMarkerExists(executable, "interrupt-ready"), "Codex must not be running a second turn.")
        attachScreenshot(named: "Codex waiting message: Continue remains for the first stopped turn")
    }

    // case-contract: test_claude_steer_during_turn_launch_reaches_started_turn | A steer sent while Claude Code is still starting the session waits for the turn instead of missing it: once the turn has started the steer reaches it as a next-priority message, the turn answers it, and it is not queued for a turn of its own. The steer is recorded inside the turn it steered, before any reply in it. In the window the steer's bubble joins the transcript and the composer clears at once, while the session is still starting and has not received it, and the turn's work stays above the bubble while it waits, while Claude Code holds it unanswered, and after its answer renders below it.
    func test_claude_steer_during_turn_launch_reaches_started_turn() throws {
        let title = "Claude steer during launch"
        let steerText = "Steer the session that is still starting."
        let executable = try prepareLaunchFixture(provider: "claude", name: "claude-fixture-ui")
        let taskID = try createLaunchTask(title: title, provider: "claude")
        try writeLaunchMarker(executable, "launch-pause")
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: title)
        let composer = element("message-composer")
        XCTAssertTrue(composer.waitToExist(timeout: 10))
        composer.click()
        composer.typeText("Hold for a steer.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ self.launchMarkerExists(executable, "launch-ready") }, timeout: 15), "Claude Code should be held while starting the session.")
        composer.click()
        composer.typeText(steerText)
        composer.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(transcriptMessage(steerText).waitToExist(timeout: 2), "The steer should join the transcript at once, while the session is still starting.")
        XCTAssertEqual(composer.value as? String, "", "The composer should clear as soon as the steer is sent.")
        XCTAssertFalse(launchMarkerExists(executable, "steer-ready"), "The session has not started the turn, so it cannot have the steer yet.")
        attachScreenshot(named: "Claude launch: the steer shows before Claude Code has it")
        attachElementScreenshot(transcriptMessage(steerText), named: "Claude launch: the steer's bubble")
        assertWorkStaysAboveSteer(steerText, state: "while the steer waits for the session")
        // Claude Code takes the steer but holds its answer, so the steer is the turn's newest message.
        try writeLaunchMarker(executable, "steer-answer-pause")
        try? FileManager.default.removeItem(atPath: executable + ".launch-pause")
        try writeLaunchMarker(executable, "launch-release")
        XCTAssertTrue(waitUntil({ self.launchMarkerExists(executable, "steer-answer-ready") }, timeout: 20), "Claude Code should take the steer before answering it.")
        assertWorkStaysAboveSteer(steerText, state: "while Claude Code holds the steer unanswered")
        attachScreenshot(named: "Claude launch: the turn's work stays above the unanswered steer")
        try writeLaunchMarker(executable, "steer-answer-release")
        let answer = transcriptMessage("STEERED: \(steerText)")
        XCTAssertTrue(answer.waitToExist(timeout: 20), "Claude Code should answer the steer inside the launched turn.")
        XCTAssertTrue(waitUntil({ !self.element("pause-response-button").exists }, timeout: 20), "The steered turn should finish.")
        assertWorkStaysAboveSteer(steerText, state: "after the turn ends")
        XCTAssertLessThanOrEqual(transcriptMessage(steerText).frame.maxY, answer.frame.minY, "The steer's answer renders below it.")
        XCTAssertEqual((try runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]])?.count, 0, "The steer should not be queued for a turn of its own.")
        let steerBubbles = app.groups.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "user-message-", steerText))
        XCTAssertEqual(steerBubbles.count, 1, "The delivered steer should stay in the transcript exactly once.")
        attachScreenshot(named: "Claude launch: the steer was answered in the launched turn")
    }

    /// The work a turn did before a steer stays above the steer, even when no reply came before it.
    /// A running turn with no work yet shows its Thinking row in the same place as the work list.
    func assertWorkStaysAboveSteer(_ steer: String, state: String, file: StaticString = #filePath, line: UInt = #line) {
        let bubble = transcriptMessage(steer)
        let work = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier IN %@", ["codex-activity-disclosure", "codex-activity-thinking"])
        ).firstMatch
        XCTAssertTrue(bubble.waitToExist(timeout: 10) && work.waitToExist(timeout: 10),
                      "The steer and the turn's work are both shown \(state).", file: file, line: line)
        XCTAssertLessThanOrEqual(work.frame.maxY, bubble.frame.minY,
                                 "The turn's work stays above the steered message \(state).", file: file, line: line)
    }

    /// Points the provider at a shared fixture and clears the launch markers earlier cases left.
    func prepareLaunchFixture(provider: String, name: String) throws -> String {
        let executable = WorkspaceFixture.root.appendingPathComponent(name).path
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable), "The UI runner should have prepared \(name).")
        for suffix in ["thread-start-pause", "thread-start-ready", "thread-start-release", "turn-start-pause", "turn-start-ready", "turn-start-release",
                       "launch-pause", "launch-ready", "launch-release", "interrupt-ready", "interrupt-received", "interrupt-release",
                       "steer-ready", "steer-answer-pause", "steer-answer-ready", "steer-answer-release", "resolve-ready", "resolve-continue", "reject-next-steer", "steers-received", "held-turns", "history",
                       "serial-first-turn", "serial-second-turn-started"] {
            try? FileManager.default.removeItem(atPath: executable + ".\(suffix)")
        }
        if provider == "codex" { codexFixtureExecutable = executable } else { claudeFixtureExecutable = executable }
        return executable
    }

    func createLaunchTask(title: String, provider: String) throws -> String {
        let task = try XCTUnwrap(try runCLI([
            "task", "create", "--title", title, "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", provider,
        ])["result"] as? [String: Any])
        return try XCTUnwrap(task["id"] as? String)
    }

    func writeLaunchMarker(_ executable: String, _ suffix: String) throws {
        try Data("\(suffix)\n".utf8).write(to: URL(fileURLWithPath: executable + ".\(suffix)"))
    }

    func launchMarkerExists(_ executable: String, _ suffix: String) -> Bool {
        FileManager.default.fileExists(atPath: executable + ".\(suffix)")
    }

    // Each test ID is prefixed with the plugin's id, so two sections never share one.
    static let sidebarSectionSource = """
        function Section() {
          var props = Playhouse.useProps();
          var id = props.plugin.id;
          var launches = React.useState(0);
          var late = React.useState(0);
          var result = React.useState("idle");
          var agents = props.agents || {};
          React.useEffect(function () {
            return Playhouse.on("app.launched", function () { launches[1](function (count) { return count + 1; }); });
          }, []);
          function act(name, call) {
            return h(Button, { testID: id + "-" + name, style: "bordered", onPress: function () {
              call().then(function (value) { result[1](name + ": " + JSON.stringify(value)); }, function (error) { result[1](name + ": " + error.code); });
            } }, h(Text, { size: 11 }, name));
          }
          var running = agents.runningTasks ? "claude " + agents.runningTasks.claude + ", codex " + agents.runningTasks.codex : "no agents";
          var usage = agents.usage ? agents.usage.providers.map(function (entry) { return entry.provider + (entry.installed ? " installed" : " missing"); }).join(", ") : "no usage";
          return h(Stack, { spacing: 4, align: "leading" },
            h(Text, { size: 11, testID: id + "-running" }, running),
            h(Text, { size: 11, testID: id + "-usage" }, usage),
            h(Text, { size: 11, testID: id + "-launches" }, "launches " + launches[0] + ", late " + late[0]),
            h(Text, { size: 11, testID: id + "-result" }, result[0]),
            h(Stack, { axis: "h", spacing: 4 },
              h(Button, { testID: id + "-listen", style: "bordered", onPress: function () {
                Playhouse.on("app.launched", function () { late[1](function (count) { return count + 1; }); });
              } }, h(Text, { size: 11 }, "listen")),
              act("confirm", function () { return Playhouse.ui.confirm({ title: "Run " + id + "?", message: "Asked from the sidebar bottom.", confirm: "Run It", destructive: true }); })),
            h(Stack, { axis: "h", spacing: 4 },
              act("open", function () { return Playhouse.ui.openURL("https://example.com/usage"); }),
              act("open-file", function () { return Playhouse.ui.openURL("file:///etc/hosts"); })));
        }
        Playhouse.render(h(Section));
        """

    // case-contract: test_plugin_sidebar_bottom_sections_and_agents_context | The board sidebar's bottom is the mainSidebarBottom placement, whose plugins always use the section presentation: a manifest or an authoring request with any other presentation there, or with section anywhere else, is invalid with an error naming the rule. A section plugin gets `props.agents` with the last-known agent usage report (the same providers `usage get` reports, each with whether its CLI is installed) and `runningTasks`, each provider's count of In Progress tasks, which counts a running Codex turn. The app.launched event reaches a plugin once per launch, and the first listener a plugin adds after it was emitted still hears it once; a later listener does not. ui.confirm and ui.openURL are host calls: confirm is answered only by the board (unavailable at the conversation sidebar; in `plugin render` it resolves null), and openURL accepts only http and https URLs (anything else is invalid_argument). In the window, sections stack at the bottom of the sidebar, each under a collapsible header with the plugin's name, open by default: collapsed, they sit one above the other at the bottom, and expanding the lower one grows it upward and pushes the upper one up. A section's collapsed state is its plugin state `collapsed` and survives a relaunch. The section's plugin hears app.launched, reads both providers' running counts, gets true from ui.confirm when the user confirms the board's dialog (showing its title, message and confirm button) and false when they cancel, opens http URLs and is refused other URLs, and the built-in Agents info section is not shown when no agent CLI is installed. Authoring a plugin there starts it as a section without asking how it opens: `plugin author --placement mainSidebarBottom` with a name and the section presentation records both and the placement, and in the window Add Plugin mode shows an Add here button below the sections whose setup goes from the name straight to the editor, which says it opens as a collapsible section.
    func test_plugin_sidebar_bottom_sections_and_agents_context() throws {
        try writeInstalledPlugin("section-a", source: Self.sidebarSectionSource, placement: "mainSidebarBottom", presentation: "section", name: "Section A")
        try writeInstalledPlugin("section-b", source: Self.sidebarSectionSource, placement: "mainSidebarBottom", presentation: "section", name: "Section B")
        try writeInstalledPlugin("bottom-popover", source: Self.sidebarSectionSource, placement: "mainSidebarBottom", presentation: "popover")
        try writeInstalledPlugin("sidebar-section", source: Self.sidebarSectionSource, placement: "mainSidebar", presentation: "section")
        // Neither agent CLI is installed, so the built-in Agents info section is not there.
        codexFixtureExecutable = "none"
        claudeFixtureExecutable = "none"
        launchApp(defaultParent: fixture.parent.path)
        let refreshed = try XCTUnwrap((try runCLI(["plugin", "refresh"])["result"] as? [String: Any])?["plugins"] as? [[String: Any]])
        let byID = Dictionary(uniqueKeysWithValues: refreshed.compactMap { plugin in (plugin["id"] as? String).map { ($0, plugin) } })
        XCTAssertEqual(byID["section-a"]?["valid"] as? Bool, true, "\(byID["section-a"] ?? [:])")
        XCTAssertEqual(byID["section-b"]?["presentation"] as? String, "section")
        XCTAssertEqual(byID["bottom-popover"]?["valid"] as? Bool, false)
        XCTAssertTrue((byID["bottom-popover"]?["errors"] as? [String] ?? []).contains { $0.contains("always a collapsible section; its presentation must be \"section\"") })
        XCTAssertEqual(byID["sidebar-section"]?["valid"] as? Bool, false)
        XCTAssertTrue((byID["sidebar-section"]?["errors"] as? [String] ?? []).contains { $0.contains("only at the Main sidebar bottom") })
        for (placement, presentation) in [("mainSidebarBottom", "popover"), ("mainSidebar", "section")] {
            assertCLIError(try runCLI(["plugin", "author", "--placement", placement, "--name", "Bottom", "--presentation", presentation], expectedStatus: 2), code: "invalid_argument")
        }

        // Both sections are open by default, stacked at the sidebar's bottom.
        let headerA = element("plugin-section-section-a-toggle")
        let headerB = element("plugin-section-section-b-toggle")
        XCTAssertTrue(headerA.waitToExist(timeout: 15), "Section A's header shows at the sidebar's bottom.")
        XCTAssertTrue(headerB.waitToExist(timeout: 5))
        XCTAssertTrue(element("section-a-running").waitToExist(timeout: 10), "A section is open by default.")
        XCTAssertTrue(element("section-b-running").waitToExist(timeout: 5))
        XCTAssertLessThan(headerA.frame.minY, headerB.frame.minY, "Section A sits above Section B.")
        XCTAssertLessThan(headerB.frame.maxY, element("section-b-running").frame.minY + 1, "A section's content is below its header.")
        XCTAssertLessThan(element("section-a-running").frame.maxY, headerB.frame.minY + 1, "The upper section's content sits above the lower header.")
        XCTAssertFalse(element("plugin-section-bottom-popover").exists, "An invalid plugin has no section.")
        XCTAssertFalse(element("plugin-section-agents-info").exists, "Agents info is not shown when no agent CLI is installed.")

        // The plugin's context: launches, running agents, and the usage report.
        XCTAssertTrue(waitUntil({ self.pluginText(self.element("section-a-launches")) == "launches 1, late 0" }, timeout: 10), "The section hears app.launched once.")
        XCTAssertEqual(pluginText(element("section-b-launches")), "launches 1, late 0")
        XCTAssertEqual(pluginText(element("section-a-running")), "claude 0, codex 0", "Both providers' running counts are listed.")
        let usage = try XCTUnwrap(try runCLI(["usage", "get"])["result"] as? [String: Any])
        let expectedUsage = (usage["providers"] as? [[String: Any]] ?? []).map { "\($0["provider"] as? String ?? "") \($0["installed"] as? Bool == true ? "installed" : "missing")" }.joined(separator: ", ")
        XCTAssertTrue(waitUntil({ self.pluginText(self.element("section-a-usage")) == expectedUsage }, timeout: 15), "props.agents.usage is the usage report: \(self.pluginText(self.element("section-a-usage")))")
        element("section-a-listen").click()
        XCTAssertFalse(waitUntil({ self.pluginText(self.element("section-a-launches")) != "launches 1, late 0" }, timeout: 2), "A launch that was heard is not heard again.")
        attachScreenshot(named: "Sidebar bottom: two open sections stacked above each other")
        attachElementScreenshot(element("plugin-section-section-a"), named: "Sidebar bottom: Section A open")

        // ui.confirm asks with the board's dialog; ui.openURL opens only web pages.
        element("section-a-confirm").click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitToExist(timeout: 10), "ui.confirm asks with a dialog.")
        XCTAssertTrue(sheet.staticTexts["Run section-a?"].exists, "The dialog shows the title.")
        XCTAssertTrue(sheet.staticTexts["Asked from the sidebar bottom."].exists, "The dialog shows the message.")
        XCTAssertTrue(sheet.buttons["Run It"].exists, "The dialog shows the confirm button.")
        attachScreenshot(named: "Sidebar bottom: a section's ui.confirm dialog")
        sheet.buttons["Run It"].click()
        XCTAssertTrue(waitForDisappearance(sheet))
        XCTAssertTrue(waitUntil({ self.pluginText(self.element("section-a-result")) == "confirm: true" }, timeout: 5), "Confirming answers true.")
        element("section-a-confirm").click()
        XCTAssertTrue(sheet.waitToExist(timeout: 10))
        sheet.buttons["Cancel"].click()
        XCTAssertTrue(waitForDisappearance(sheet))
        XCTAssertTrue(waitUntil({ self.pluginText(self.element("section-a-result")) == "confirm: false" }, timeout: 5), "Cancelling answers false.")
        element("section-a-open").click()
        XCTAssertTrue(waitUntil({ self.pluginText(self.element("section-a-result")) == "open: null" }, timeout: 5), "An https URL opens.")
        element("section-a-open-file").click()
        XCTAssertTrue(waitUntil({ self.pluginText(self.element("section-a-result")) == "open-file: invalid_argument" }, timeout: 5), "A file URL is refused.")

        // Collapsed, they sit one above the other at the bottom.
        headerA.click()
        XCTAssertTrue(waitForDisappearance(element("section-a-running")), "Collapsing hides Section A's content.")
        headerB.click()
        XCTAssertTrue(waitForDisappearance(element("section-b-running")))
        XCTAssertTrue(waitUntil({ self.waitForStableFrame(headerB) && abs(headerA.frame.maxY - headerB.frame.minY) < 24 }, timeout: 5),
                      "Collapsed, Section A's header sits right above Section B's: \(headerA.frame) \(headerB.frame)")
        XCTAssertLessThan(visibleSidebarBottom() - headerB.frame.maxY, 60, "The collapsed sections sit at the sidebar's bottom: \(headerB.frame) above \(visibleSidebarBottom())")
        let collapsedA = headerA.frame
        let collapsedB = headerB.frame
        attachScreenshot(named: "Sidebar bottom: both sections collapsed at the bottom")
        XCTAssertTrue(waitUntil({
            let states = ((try? self.runCLI(["plugin", "list"]))?["result"] as? [String: Any])?["plugins"] as? [[String: Any]] ?? []
            return states.filter { ["section-a", "section-b"].contains($0["id"] as? String ?? "") }.allSatisfy { ($0["state"] as? [String: Any])?["collapsed"] as? Bool == true }
        }, timeout: 10), "Each section's collapsed state is its plugin state.")

        // Expanding the lower one grows it upward and pushes the upper one up.
        headerB.click()
        XCTAssertTrue(element("section-b-running").waitToExist(timeout: 5), "Expanding shows Section B's content.")
        XCTAssertTrue(waitUntil({ self.waitForStableFrame(headerB) && headerB.frame.minY < collapsedB.minY - 40 }, timeout: 5), "Section B's header moves up as it grows: \(headerB.frame)")
        XCTAssertLessThan(headerA.frame.minY, collapsedA.minY - 40, "Section A is pushed up: \(headerA.frame) from \(collapsedA)")
        XCTAssertGreaterThan(element("section-b-running").frame.minY, headerB.frame.maxY - 1, "The lower section's content is below its header.")
        XCTAssertFalse(element("section-a-running").exists, "Section A stays collapsed.")
        attachScreenshot(named: "Sidebar bottom: the lower section expanded pushes the upper one up")

        // The collapsed state survives a relaunch, and the next launch is heard again.
        XCTAssertTrue(waitUntil({
            let states = ((try? self.runCLI(["plugin", "list"]))?["result"] as? [String: Any])?["plugins"] as? [[String: Any]] ?? []
            return (states.first { $0["id"] as? String == "section-b" }?["state"] as? [String: Any])?["collapsed"] as? Bool == false
        }, timeout: 10))
        XCTAssertTrue(terminateAppAndWait(app))
        launchAppWithOpen()
        waitForBoardOrAbortSuite()
        XCTAssertTrue(element("section-b-running").waitToExist(timeout: 15), "Section B is still open after a relaunch.")
        XCTAssertTrue(headerA.waitToExist(timeout: 5))
        XCTAssertFalse(element("section-a-running").exists, "Section A is still collapsed after a relaunch.")
        XCTAssertTrue(waitUntil({ self.pluginText(self.element("section-b-launches")) == "launches 1, late 0" }, timeout: 10), "The new launch is heard once.")
        attachScreenshot(named: "Sidebar bottom: sections keep their collapsed state after a relaunch")

        // Authoring there goes from the name straight to the editor: a section never asks how it opens.
        _ = try runCLI(["plugin", "mode", "--on"])
        let placeholder = element("plugin-add-here-mainSidebarBottom")
        XCTAssertTrue(placeholder.waitToExist(timeout: 10), "Add Plugin mode shows the sidebar bottom's placeholder.")
        XCTAssertGreaterThanOrEqual(placeholder.frame.minY, headerB.frame.maxY - 1, "The placeholder sits below the sections.")
        attachScreenshot(named: "Sidebar bottom: Add here below the sections")
        placeholder.click()
        XCTAssertTrue(element("plugin-creation-name").waitToExist(timeout: 10))
        element("plugin-creation-name").click()
        element("plugin-creation-name").typeText("Usage")
        element("plugin-creation-continue").click()
        XCTAssertTrue(element("plugin-creation-preview").waitToExist(timeout: 15), "Continue opens the editor at once.")
        XCTAssertFalse(element("plugin-creation-presentation").exists, "A section never asks how it opens.")
        XCTAssertTrue(element("plugin-detail-placement").waitToExist(timeout: 15), "The editor's empty state lists the new plugin's details.")
        XCTAssertEqual(accessibleLabelOrValue(of: element("plugin-detail-placement")), "Placement: Main sidebar bottom")
        XCTAssertEqual(accessibleLabelOrValue(of: element("plugin-detail-presentation")), "Opens as: Collapsible section")
        let sessions = try XCTUnwrap((try runCLI(["plugin", "sessions"])["result"] as? [String: Any])?["sessions"] as? [[String: Any]])
        let usageSession = try XCTUnwrap(sessions.first { $0["title"] as? String == "Usage" })
        XCTAssertEqual(usageSession["pluginPlacement"] as? String, "mainSidebarBottom")
        XCTAssertEqual(usageSession["pluginAuthoringPresentation"] as? String, "section")
        attachElementScreenshot(element("plugin-details"), named: "Sidebar bottom: a new plugin there opens as a collapsible section")
    }

    // Each test ID is prefixed with the plugin's id; it reads props.schedules when it has them.
    static let schedulesPageSource = """
        function Page() {
          var props = Playhouse.useProps();
          var id = props.plugin.id;
          var result = React.useState("idle");
          var schedules = props.schedules;
          var tasks = schedules ? schedules.tasks : [];
          function act(name, call) {
            return h(Button, { testID: id + "-" + name, style: "bordered", onPress: function () {
              call().then(function (value) { result[1](name + ": " + JSON.stringify(value)); }, function (error) { result[1](name + ": " + error.code); });
            } }, h(Text, { size: 11 }, name));
          }
          return h(Stack, { spacing: 4, align: "leading" },
            h(Text, { size: 11, testID: id + "-count" }, schedules ? tasks.length + " scheduled" : "no schedules"),
            h(Text, { size: 11, testID: id + "-ids" }, tasks.map(function (task) { return task.id; }).join(",")),
            h(Text, { size: 11, testID: id + "-kinds" }, tasks.map(function (task) { return task.schedule.kind + (task.schedule.paused ? " paused" : ""); }).join(",")),
            h(Text, { size: 11, testID: id + "-approval" }, schedules ? "approval " + schedules.needsLoginItemsApproval : "no approval"),
            h(Text, { size: 11, testID: id + "-result" }, result[0]),
            h(Stack, { axis: "h", spacing: 4 },
              act("new-recurring", function () { return Playhouse.ui.newTask({ schedule: "recurring" }); }),
              act("new-once", function () { return Playhouse.ui.newTask({ schedule: "once" }); }),
              act("new-plain", function () { return Playhouse.ui.newTask(); }),
              act("new-weekly", function () { return Playhouse.ui.newTask({ schedule: "weekly" }); }),
              act("login-items", function () { return Playhouse.ui.openLoginItems(); })));
        }
        Playhouse.render(h(Page));
        """
    // case-contract: test_plugin_main_sidebar_schedules_context_and_new_task | A plugin at the board's mainSidebar placement gets `props.schedules`: `tasks`, the scheduled tasks exactly as `schedule list` returns them (soonest first, each with its schedule's kind and paused state), and `needsLoginItemsApproval`; with no schedules the list is empty, and a conversation sidebar plugin gets no schedules. ui.newTask (with schedule "recurring", "once" or none) and ui.openLoginItems are host calls only the board answers: a conversation sidebar plugin is refused as unavailable, and any other schedule is invalid_argument. The board's Scheduled Tasks button and page are the built-in scheduled-tasks plugin, which can't be rendered headlessly (invalid_argument). In the window, a mainSidebar page plugin lists the schedules and follows them live as one is paused, and its ui.newTask opens a new task with the schedule picker up; disabling the built-in Scheduled Tasks removes its sidebar button, and enabling it brings back the button, which opens the Scheduled Tasks page.
    func test_plugin_main_sidebar_schedules_context_and_new_task() throws {
        try writeInstalledPlugin("schedules-probe", source: Self.schedulesPageSource, placement: "mainSidebar", presentation: "page", name: "Schedules Probe", icon: "calendar")
        launchApp(defaultParent: fixture.parent.path)
        _ = try runCLI(["plugin", "refresh"])

        // With no schedules, the page plugin's list is there and empty.
        let entry = element("plugin-entry-schedules-probe")
        XCTAssertTrue(entry.waitToExist(timeout: 15), "The page plugin's button is in the board's sidebar.")
        entry.click()
        let page = element("plugin-surface-schedules-probe")
        XCTAssertTrue(page.waitToExist(timeout: 10), "The page plugin opens.")
        XCTAssertTrue(waitForStableFrame(page), "The page finishes sliding in.")
        func probe(_ name: String) -> XCUIElement { page.descendants(matching: .any)["schedules-probe-\(name)"] }
        XCTAssertTrue(waitUntil({ self.pluginText(probe("count")) == "0 scheduled" }, timeout: 10), "No schedules yet: \(pluginText(probe("count")))")
        XCTAssertTrue(["approval true", "approval false"].contains(pluginText(probe("approval"))), "props.schedules says whether Login Items approval is needed.")

        // Schedules made elsewhere reach the open page live, in `schedule list`'s order.
        func createTask(_ title: String) throws -> String {
            try XCTUnwrap((try runCLI([
                "task", "create", "--title", title, "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
            ])["result"] as? [String: Any])?["id"] as? String)
        }
        let onceID = try createTask("Plugin one-time schedule")
        _ = try runCLI(["schedule", "set", onceID, "--prompt", "Tell me a story.", "--once", scheduleISO(Date().addingTimeInterval(3 * 86_400))])
        let dailyID = try createTask("Plugin daily schedule")
        _ = try runCLI(["schedule", "set", dailyID, "--prompt", "Summarize the day.", "--repeat", "daily", "--time", "09:00", "--title", "Daily summary"])
        let listed = ((try runCLI(["schedule", "list"])["result"] as? [String: Any])?["tasks"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        XCTAssertEqual(Set(listed), [onceID, dailyID])
        XCTAssertTrue(waitUntil({ self.pluginText(probe("count")) == "2 scheduled" }, timeout: 10), "The open page follows new schedules: \(pluginText(probe("count")))")
        XCTAssertEqual(pluginText(probe("ids")), listed.joined(separator: ","), "props.schedules.tasks is `schedule list` in its order.")
        let kinds = Dictionary(uniqueKeysWithValues: zip(listed, pluginText(probe("kinds")).components(separatedBy: ",")))
        XCTAssertEqual(kinds, [onceID: "once", dailyID: "recurring"])
        _ = try runCLI(["schedule", "pause", dailyID])
        XCTAssertTrue(waitUntil({ self.pluginText(probe("kinds")).components(separatedBy: ",").contains("recurring paused") }, timeout: 10),
                      "Pausing a schedule reaches the open page: \(pluginText(probe("kinds")))")
        attachScreenshot(named: "A mainSidebar page plugin lists the schedules, one paused")
        attachElementScreenshot(page, named: "The page plugin's schedules from props.schedules")

        // ui.newTask opens a new task with the schedule picker up; going back shows the page again.
        probe("new-weekly").click()
        XCTAssertTrue(waitUntil({ self.pluginText(probe("result")) == "new-weekly: invalid_argument" }, timeout: 5), "Only once, recurring or no schedule.")
        probe("new-recurring").click()
        XCTAssertTrue(element("schedule-hint").waitToExist(timeout: 10), "ui.newTask opens the new task with the schedule hint up.")
        XCTAssertTrue(element("schedule-title-field").waitToExist(timeout: 5), "It starts on Recurring.")
        attachScreenshot(named: "ui.newTask from a page plugin opens the schedule hint")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(waitForDisappearance(element("schedule-hint"), timeout: 5), "Escape dismisses the schedule hint.")
        element("back-to-board-button").click()
        XCTAssertTrue(waitForDisappearance(element("back-to-board-button"), timeout: 10), "Going back leaves the new task.")
        XCTAssertTrue(page.waitToExist(timeout: 10), "Going back shows the page plugin again.")
        XCTAssertTrue(waitUntil({ self.pluginText(probe("count")) == "2 scheduled" }, timeout: 10), "The page plugin still lists the schedules.")
        page.descendants(matching: .any)["plugin-surface-close"].click()
        XCTAssertTrue(waitForDisappearance(page, timeout: 10), "The page closes.")

        // The board's Scheduled Tasks is the built-in plugin: disabling it removes its button.
        let scheduledEntry = element("plugin-entry-scheduled-tasks")
        XCTAssertTrue(scheduledEntry.waitToExist(timeout: 5), "The built-in Scheduled Tasks has its sidebar button.")
        _ = try runCLI(["plugin", "disable", "--id", "scheduled-tasks"])
        XCTAssertTrue(waitForDisappearance(scheduledEntry, timeout: 10), "Disabling Scheduled Tasks removes its button.")
        attachElementScreenshot(element(withAccessibilityLabel: "Kanban sidebar"), named: "The board's sidebar with Scheduled Tasks disabled")
        _ = try runCLI(["plugin", "enable", "--id", "scheduled-tasks"])
        XCTAssertTrue(scheduledEntry.waitToExist(timeout: 10), "Enabling it brings the button back.")
        scheduledEntry.click()
        XCTAssertTrue(element("plugin-surface-scheduled-tasks").waitToExist(timeout: 10), "The button opens the Scheduled Tasks page.")
        XCTAssertTrue(element("scheduled-task-row-\(onceID)").waitToExist(timeout: 10), "The page lists the one-time schedule.")
        XCTAssertTrue(element("scheduled-task-row-\(dailyID)").exists, "The page lists the recurring schedule.")
        XCTAssertTrue(waitForStableFrame(element("plugin-surface-scheduled-tasks")), "The page finishes sliding in.")
        attachScreenshot(named: "The built-in Scheduled Tasks page, enabled again")
    }
}

extension PlayhouseUITests {
    // case-contract: test_slash_commands_menu_lists_commands_and_items | Typing / where a word starts anywhere in the composer opens a command menu listing /mcp, /plan, /goal, /skill, /login and /plugin in that order, narrowed to the commands whose name starts with what follows the /. On a Claude task /goal can't be chosen and says goal mode isn't supported by Claude, while on a Codex task it can. Choosing /plan turns plan mode on and choosing /goal on a Codex task opens the goal entry, each removing the typed command from the draft. The command menu shares the mention menu's look: the same floating panel, as wide as the mention menu, with the same section headers and highlighted-row surface. Typing a command with its own list in full lists its items, narrowed by text after a space: /mcp lists the MCP servers the composer can mention, and asked with sign-in status marks each server with the agents that need a sign-in to it (shown as a Sign in button per agent on its row); /skill lists the mentionable skills, editable ones with a working gear and built-in ones with a disabled gear; choosing either mentions it as @handle in place of the command. /login lists both agents, the task's own first, and choosing one starts that agent's sign-in. /plugin lists Create Plugin first, which turns on Add Plugin mode, then the user's own plugins (never built-in ones), disabled ones marked so, each with edit, which opens the plugin's editor conversation, delete, which asks first, and a settings gear that stays disabled until plugins have settings. In the window an MCP server's gear opens the MCP page with that server's editor, its Sign in button opens the MCP page filtered to it and starts that agent's sign-in, and every choice removes the typed command. Listing without a task is a usage error and for an unknown task is not_found.
    func test_slash_commands_menu_lists_commands_and_items() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        let codexPath = try XCTUnwrap(codexFixtureExecutable)
        let codexSidecars = [".mcp-status", ".mcp-login"].map { URL(fileURLWithPath: codexPath + $0) }
        codexSidecars.forEach { try? FileManager.default.removeItem(at: $0) }
        addTeardownBlock { codexSidecars.forEach { try? FileManager.default.removeItem(at: $0) } }
        let repository = try makeSkillRepository("slash-repo", skills: [
            ".agents/skills/slash-skill/SKILL.md": skillManifest("slash-skill", "A skill the slash menu lists"),
            ".mcp.json": #"{"mcpServers": {"slash-docs": {"type": "stdio", "command": "node", "args": ["docs.js"]}}}"#,
        ])
        try writeSkill(in: skillsCodexHome.appendingPathComponent("skills/.system"), "slash-system-skill", "Bundled with Codex")
        try writeMcpJSON(mcpClaudeState, ["mcpServers": ["slash-remote": ["type": "http", "url": "https://remote.example.com/mcp"]]])
        let claude = try installSkillsClaudeFixture("claude-fixture-slash")
        let claudeAuth = URL(fileURLWithPath: claude.path + ".auth-state")
        try writeMcpJSON(URL(fileURLWithPath: claude.path + ".mcp-status"), [["name": "slash-remote", "status": "needs-auth"]])
        try writeMcpJSON(URL(fileURLWithPath: codexPath + ".mcp-status"), [["name": "slash-remote", "authStatus": "notLoggedIn", "tools": [:]]])
        try writeInstalledPlugin("slash-panel", source: "function Panel() { return h(Text, null, 'hi'); }", placement: "conversationToolbar", presentation: "modal")
        try writeInstalledPlugin("slash-doomed", source: "function Panel() { return h(Text, null, 'bye'); }", placement: "conversationToolbar", presentation: "modal")
        try writeInstalledPlugin("slash-off", source: "function Panel() { return h(Text, null, 'off'); }", placement: "conversationToolbar", presentation: "modal")
        launchApp(defaultParent: fixture.parent.path)
        _ = try runCLI(["plugin", "disable", "--id", "slash-off"])
        let task = try createSkillsTask("Slash task", repositories: [repository], provider: "claude")
        let taskID = try XCTUnwrap(task["id"] as? String)
        _ = try createSkillsTask("Slash Codex task", repositories: [repository], provider: "codex")

        let menu = element("slash-menu")
        let composer = element("message-composer")
        func clearComposer() {
            composer.click()
            composer.typeKey("a", modifierFlags: .command)
            composer.typeKey(.delete, modifierFlags: [])
            XCTAssertTrue(waitUntil({ (composer.value as? String ?? "").isEmpty }, timeout: 5))
        }
        func slashRows() -> [String] {
            app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "slash-command-")).allElementsBoundByIndex
                .filter { $0.exists }.sorted { $0.frame.minY < $1.frame.minY }
                .map { String($0.identifier.dropFirst("slash-command-".count)) }
        }
        /// A real click at the row's center: XCUITest reports rows of the floating menu as not hittable.
        func clickRow(_ row: XCUIElement) {
            XCTAssertTrue(row.waitToExist(timeout: 10), "\(row) shows.")
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        }

        openTask(named: "Slash task")
        XCTAssertTrue(composer.waitToExist(timeout: 10))
        let modeMenu = element("conversation-mode-menu")
        XCTAssertTrue(modeMenu.waitToExist(timeout: 10))
        XCTAssertFalse(modeMenu.label.contains("Plan mode"), "The task starts outside plan mode.")
        composer.click()
        composer.typeText("Draft first, then /")
        XCTAssertTrue(menu.waitToExist(timeout: 10), "Typing / where a word starts, anywhere in the draft, opens the command menu.")
        XCTAssertLessThanOrEqual(menu.frame.maxY, composer.frame.minY + 1, "The menu opens above the composer.")
        // Measured from the rows, which fill the panel's inner width: the mention menu's identifier
        // lands on its scroll view, inside the panel's inset, so its frame isn't the panel's.
        let slashRowWidth = element("slash-command-plan").frame.width
        let slashTitleInset = element("slash-menu-title").frame.minX - element("slash-command-plan").frame.minX
        let slashRowHeight = element("slash-command-plan").frame.height
        let highlighted = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND selected == true", "slash-command-"))
        XCTAssertEqual(highlighted.count, 1, "Only one command row is highlighted.")
        XCTAssertEqual(highlighted.firstMatch.identifier, "slash-command-mcp", "The first row starts highlighted.")
        XCTAssertEqual(slashRows(), ["mcp", "plan", "goal", "skill", "login", "plugin"], "Every command is listed, in order.")
        let goal = element("slash-command-goal")
        XCTAssertFalse(goal.isEnabled, "Claude can't run goal mode, so /goal can't be chosen.")
        // The row shows why; the button carries the same text as its accessibility value.
        let reason = goal.value as? String ?? ""
        XCTAssertTrue(reason.contains("isn't supported by Claude"), "The row says why: \(reason)")
        attachScreenshot(named: "Typing / lists the commands; goal mode isn't supported by Claude")
        attachElementScreenshot(menu, named: "Command menu with /goal disabled on Claude")
        clickRow(goal)
        XCTAssertEqual(composer.value as? String, "Draft first, then /", "A disabled command does nothing when clicked.")

        composer.typeText("pl")
        XCTAssertTrue(waitUntil({ slashRows() == ["plan", "plugin"] }, timeout: 5), "Typing after the / narrows the commands by prefix.")
        composer.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil({ (composer.value as? String) == "Draft first, then " }, timeout: 5), "Choosing /plan removes the typed command and keeps the rest.")
        XCTAssertTrue(waitUntil({ modeMenu.label.contains("Plan mode") }, timeout: 5), "Choosing /plan turns plan mode on.")
        XCTAssertTrue(waitForDisappearance(menu))
        attachScreenshot(named: "Choosing /plan turns plan mode on and removes the command")
        clearComposer()
        composer.typeText("@")
        let mentionMenu = element("mention-menu")
        XCTAssertTrue(mentionMenu.waitToExist(timeout: 10), "Typing @ opens the mention menu.")
        let mentionHeader = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR identifier == %@", "mention-section-", "mention-menu-title")).firstMatch
        let mentionRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mention-item-")).firstMatch
        XCTAssertTrue(mentionHeader.waitToExist(timeout: 10) && mentionRow.waitToExist(timeout: 10), "The mention menu lists a section with rows.")
        XCTAssertEqual(slashTitleInset, mentionHeader.frame.minX - mentionRow.frame.minX, accuracy: 1, "Both menus' headers sit at the same inset from their rows.")
        XCTAssertEqual(slashRowHeight, mentionRow.frame.height, accuracy: 1, "Both menus' rows are the same height.")
        XCTAssertEqual(slashRowWidth, mentionRow.frame.width, accuracy: 1, "The command menu sits in the mention menu's panel, as wide as it.")
        attachScreenshot(named: "The mention menu, the design the command menu shares")
        clearComposer()
        XCTAssertTrue(waitForDisappearance(mentionMenu))

        // /mcp: choosing a server mentions it.
        composer.typeText("/mcp")
        XCTAssertTrue(element("slash-item-mcp-slash-docs").waitToExist(timeout: 10), "Typing /mcp lists the MCP servers.")
        XCTAssertTrue(element("slash-item-mcp-slash-remote").exists)
        XCTAssertEqual(accessibleLabelOrValue(of: element("slash-menu-title")), "MCP servers")
        let claudeSignIn = element("slash-signin-mcp-slash-remote-claude")
        XCTAssertTrue(claudeSignIn.waitToExist(timeout: 30), "A server Claude needs a sign-in to shows a Sign in button for Claude.")
        XCTAssertTrue(element("slash-signin-mcp-slash-remote-codex").exists, "and one for Codex, on the same row.")
        XCTAssertFalse(element("slash-signin-mcp-slash-docs-claude").exists, "A server that needs no sign-in has no button.")
        XCTAssertTrue(element("slash-gear-mcp-slash-docs").isEnabled, "Every server has a gear.")
        attachScreenshot(named: "/mcp lists servers, with Sign in buttons and gears")
        attachElementScreenshot(menu, named: "/mcp list with sign-in buttons")
        composer.typeText(" doc")
        XCTAssertTrue(waitForDisappearance(element("slash-item-mcp-slash-remote")), "Text after a space narrows the servers.")
        clickRow(element("slash-item-mcp-slash-docs"))
        XCTAssertTrue(waitUntil({ (composer.value as? String) == "@slash-docs " }, timeout: 5), "Choosing a server mentions it in place of the command.")
        XCTAssertTrue(waitForDisappearance(menu))

        // The gear opens the server's editor on the MCP page.
        composer.typeText("/mcp")
        clickRow(element("slash-gear-mcp-slash-remote"))
        XCTAssertTrue(element("mcp-page").waitToExist(timeout: 10), "The gear opens the MCP page.")
        XCTAssertTrue(element("mcp-editor-panel").waitToExist(timeout: 10), "with the server's editor open.")
        XCTAssertEqual(accessibleLabelOrValue(of: element("mcp-editor-title")), "slash-remote", "The editor is the server's own.")
        attachScreenshot(named: "The /mcp gear opens the server's editor")
        element("mcp-editor-cancel").click()
        XCTAssertTrue(waitForDisappearance(element("mcp-editor-panel")))
        element("skills-back-button").click()
        XCTAssertTrue(waitForDisappearance(element("skills-page"), timeout: 10))
        XCTAssertEqual(composer.value as? String, "@slash-docs ", "The gear removes the typed command.")

        // Sign in opens the MCP page on that server and starts that agent's sign-in.
        composer.click()
        composer.typeText("/mcp")
        let signIn = element("slash-signin-mcp-slash-remote-claude")
        XCTAssertTrue(signIn.waitToExist(timeout: 30))
        clickRow(signIn)
        XCTAssertTrue(element("mcp-page").waitToExist(timeout: 10), "Sign in opens the MCP page.")
        XCTAssertEqual(element("mcp-search").value as? String, "slash-remote", "The page is narrowed to the server.")
        let pageBadge = element("mcp-signin-slash-remote-claude")
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: pageBadge).contains("Waiting for sign-in") }, timeout: 20),
                      "Claude's sign-in to the server has started.")
        func logged(_ path: String) -> [[String: String]] {
            ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: String]
            }
        }
        XCTAssertTrue(waitUntil({ logged(claude.path + ".mcp-authenticate") == [["serverName": "slash-remote"]] }, timeout: 20),
                      "Claude Code is asked to sign in to that server only.")
        XCTAssertTrue(logged(codexPath + ".mcp-login").isEmpty, "Codex is not asked.")
        attachScreenshot(named: "/mcp Sign in starts Claude's sign-in on the MCP page")
        element("skills-back-button").click()
        XCTAssertTrue(waitForDisappearance(element("skills-page"), timeout: 10))
        XCTAssertEqual(composer.value as? String, "@slash-docs ", "Sign in removes the typed command.")

        // /skill: choosing a skill mentions it; its gear opens its editor.
        composer.click()
        composer.typeText("/skill slash")
        let skillRow = element("slash-item-skill-slash-skill")
        XCTAssertTrue(skillRow.waitToExist(timeout: 10), "Typing /skill lists the skills.")
        XCTAssertTrue(element("slash-gear-skill-slash-skill").isEnabled, "A repository skill's gear can open its editor.")
        attachElementScreenshot(menu, named: "/skill list narrowed by its filter")
        composer.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil({ (composer.value as? String) == "@slash-docs @slash-skill " }, timeout: 5), "Return mentions the highlighted skill in place of the command.")
        composer.typeText("/skill")
        clickRow(element("slash-gear-skill-slash-skill"))
        XCTAssertTrue(element("skill-editor-panel").waitToExist(timeout: 10), "The skill's gear opens its editor on the Skills page.")
        XCTAssertEqual(accessibleLabelOrValue(of: element("skill-editor-name")), "slash-skill", "The editor is that skill's.")
        attachScreenshot(named: "The /skill gear opens the skill's editor")
        element("skill-editor-cancel").click()
        XCTAssertTrue(waitForDisappearance(element("skill-editor-panel")))
        element("skills-back-button").click()
        XCTAssertTrue(waitForDisappearance(element("skills-page"), timeout: 10))
        XCTAssertEqual(composer.value as? String, "@slash-docs @slash-skill ")
        clearComposer()

        // /login lists both agents, the task's own first; choosing one starts its sign-in.
        composer.typeText("/login")
        XCTAssertTrue(element("slash-item-login-claude").waitToExist(timeout: 10))
        XCTAssertTrue(element("slash-item-login-codex").exists)
        XCTAssertLessThan(element("slash-item-login-claude").frame.minY, element("slash-item-login-codex").frame.minY, "The task's own agent comes first.")
        attachElementScreenshot(menu, named: "/login lists both agents, the task's own first")
        composer.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForDisappearance(menu), "Escape closes the menu.")
        XCTAssertEqual(composer.value as? String, "/login", "Escape keeps the typed text.")
        clearComposer()
        try JSONSerialization.data(withJSONObject: ["loggedIn": false]).write(to: claudeAuth)
        composer.typeText("Before /login")
        clickRow(element("slash-item-login-claude"))
        XCTAssertTrue(waitUntil({ (composer.value as? String) == "Before " }, timeout: 5), "Choosing an agent removes the typed command.")
        XCTAssertTrue(waitUntil({ ((try? String(contentsOf: claudeAuth, encoding: .utf8)) ?? "").contains("claude-second@example.com") }, timeout: 20),
                      "Choosing Claude runs Claude Code's sign-in.")
        clearComposer()

        // /plugin: Create Plugin, then the user's plugins with edit, delete and a settings gear.
        composer.typeText("/plugin")
        let create = element("slash-item-create-plugin")
        XCTAssertTrue(create.waitToExist(timeout: 10), "Typing /plugin offers Create Plugin.")
        XCTAssertTrue(element("slash-item-plugin-slash-panel").exists, "and lists the user's plugins.")
        XCTAssertTrue(element("slash-item-plugin-slash-doomed").exists)
        XCTAssertFalse(element("slash-item-plugin-scheduled-tasks").exists, "Built-in plugins are not listed.")
        XCTAssertLessThan(create.frame.minY, element("slash-item-plugin-slash-panel").frame.minY, "Create Plugin comes first.")
        XCTAssertTrue(element("slash-edit-plugin-slash-panel").isEnabled, "Each plugin has an edit button.")
        XCTAssertTrue(element("slash-delete-plugin-slash-panel").isEnabled, "and a delete button.")
        let pluginGear = element("slash-gear-plugin-slash-panel")
        XCTAssertTrue(pluginGear.exists, "and a settings gear,")
        XCTAssertFalse(pluginGear.isEnabled, "disabled until plugins have settings.")
        XCTAssertTrue(element("slash-item-plugin-slash-off").exists, "A disabled plugin is listed too,")
        XCTAssertEqual(element("slash-item-plugin-slash-off").value as? String, "Conversation sidebar toolbar (Disabled)", "marked as disabled.")
        XCTAssertEqual(element("slash-item-plugin-slash-panel").value as? String, "Conversation sidebar toolbar", "An enabled plugin isn't marked.")
        attachScreenshot(named: "/plugin offers Create Plugin and the user's plugins")
        attachElementScreenshot(menu, named: "/plugin list with edit, delete and settings")
        clickRow(element("slash-delete-plugin-slash-doomed"))
        let confirm = app.dialogs.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitToExist(timeout: 5), "Deleting asks for confirmation.")
        XCTAssertTrue(app.dialogs.staticTexts["Delete the plugin Slash Doomed?"].exists, "The confirmation names the plugin.")
        confirm.click()
        XCTAssertTrue(waitUntil({ (try? self.installedPluginIDs())?.contains("slash-doomed") == false }, timeout: 10), "Confirming deletes the plugin.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pluginsFolder.appendingPathComponent("slash-doomed").path))
        XCTAssertTrue(waitUntil({ (composer.value as? String ?? "").isEmpty }, timeout: 5), "Delete removes the typed command.")
        composer.click()
        composer.typeText("/plugin")
        XCTAssertTrue(create.waitToExist(timeout: 10))
        XCTAssertFalse(element("slash-item-plugin-slash-doomed").exists, "A deleted plugin is no longer listed.")
        clickRow(element("slash-edit-plugin-slash-panel"))
        XCTAssertTrue(app.staticTexts["Plugin editor"].waitToExist(timeout: 15), "Edit opens the plugin's editor conversation.")
        let editors = try XCTUnwrap((try runCLI(["plugin", "sessions"])["result"] as? [String: Any])?["sessions"] as? [[String: Any]])
        XCTAssertTrue(editors.contains { $0["authoredPluginID"] as? String == "slash-panel" }, "The editor is that plugin's.")
        attachScreenshot(named: "Edit in /plugin opens the plugin's editor")
        element("back-to-board-button").click()
        openTask(named: "Slash task")
        XCTAssertTrue(composer.waitToExist(timeout: 10))
        XCTAssertTrue(waitUntil({ (composer.value as? String ?? "").isEmpty }, timeout: 5), "Edit removes the typed command.")
        composer.click()
        composer.typeText("/plugin")
        XCTAssertTrue(create.waitToExist(timeout: 10))
        composer.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(element("plugin-mode-banner").waitToExist(timeout: 10), "Create Plugin turns on Add Plugin mode.")
        XCTAssertTrue(try pluginMode())
        XCTAssertTrue(waitUntil({ (composer.value as? String ?? "").isEmpty }, timeout: 5), "Create Plugin removes the typed command.")
        attachScreenshot(named: "Create Plugin turns on Add Plugin mode")
        element("plugin-mode-close").click()
        XCTAssertTrue(waitForDisappearance(element("plugin-mode-banner")))

        // On a Codex task, /goal can be chosen and opens the goal entry.
        openTask(named: "Slash Codex task")
        let codexComposer = element("message-composer")
        XCTAssertTrue(codexComposer.waitToExist(timeout: 10))
        codexComposer.click()
        codexComposer.typeText("/skill slash")
        let systemGear = element("slash-gear-skill-slash-system-skill")
        XCTAssertTrue(systemGear.waitToExist(timeout: 10), "Codex's built-in skills are listed on a Codex task.")
        XCTAssertFalse(systemGear.isEnabled, "A built-in skill's gear is disabled.")
        XCTAssertTrue(element("slash-gear-skill-slash-skill").isEnabled)
        attachElementScreenshot(menu, named: "/skill on a Codex task: a built-in skill's gear is disabled")
        codexComposer.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForDisappearance(menu))
        codexComposer.typeKey("a", modifierFlags: .command)
        codexComposer.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(waitUntil({ (codexComposer.value as? String ?? "").isEmpty }, timeout: 5))
        codexComposer.typeText("/go")
        let codexGoal = element("slash-command-goal")
        XCTAssertTrue(codexGoal.waitToExist(timeout: 10))
        XCTAssertTrue(codexGoal.isEnabled, "Codex runs goal mode.")
        XCTAssertEqual(codexGoal.value as? String, "Turn on goal mode", "An enabled /goal shows its description, not an unsupported reason.")
        codexComposer.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil({ (codexComposer.value as? String ?? "").isEmpty }, timeout: 5), "Choosing /goal removes the typed command.")
        XCTAssertTrue(waitUntil({ self.element("conversation-mode-menu").label.contains("Goal") }, timeout: 5), "Choosing /goal opens the goal entry.")
        attachScreenshot(named: "Choosing /goal on a Codex task opens the goal entry")

        let listed = try XCTUnwrap(try runCLI(["slash-commands", "list", "--task", taskID])["result"] as? [String: Any])
        let commands = try XCTUnwrap(listed["commands"] as? [[String: Any]])
        XCTAssertEqual(commands.compactMap { $0["command"] as? String }, ["mcp", "plan", "goal", "skill", "login", "plugin"])
        XCTAssertEqual(commands.first { $0["command"] as? String == "goal" }?["enabled"] as? Bool, false)
        assertCLIError(try runCLI(["slash-commands", "list"], expectedStatus: 2), code: "invalid_argument")
        assertCLIError(try runCLI(["slash-commands", "list", "--task", UUID().uuidString], expectedStatus: 3), code: "not_found")
    }
}
