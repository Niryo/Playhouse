from test_bridge_support import *
from test_bridge_support import __file__

class BridgeTestCases21:
    # case-contract: test_plugin_kanban_column_renders_from_atoms_like_native | The Plugin Catalog's Kanban Column page shows the board's columns composed in JavaScript from atoms beside the native SwiftUI columns the board uses, built from the same atoms and sample models (a column's cards are native and not part of the page): each side shows a Backlog column with its Add button and its empty state, an In Progress column with a count of 2 and no empty state, a Blocked column with the Waiting for user intervention notice and its empty state, a Waiting Response column washed in its purple accent (a tint Panel filling the column with a soft fill and hairline border in the accent, its pixels visibly purple beside the other columns, and its count in the accent) and its empty state, and a Done column with its empty state, with the board's identifiers (column-heading, column-count, add-backlog-task-button, empty-state, blocked-waiting-indicator), and every one is the same size in both and reads the same text (the uppercased title, the count, No tasks yet with Create a task to get started or Drop a task here). The JavaScript tree uses only atoms (Panel, Stack, Text, Icon, Label, Button, Spacer): each column is a Panel holding the header (a status dot Panel, the title, a Spacer, the count Panel, and for the Backlog the Add button), then the notice and the empty state, which is a dashed Panel with centered content; only the tinted column nests that content in its tint Panel. Pressing the JavaScript Add button runs its onPress in JavaScript (Last: add) as one commit that changes only the readout, and the native Add button runs its own handler without touching the JavaScript side. On the board itself, every column keeps its column-<status>, column-heading-<status> and empty-state-<status> identifiers, the Backlog its Add button and the Blocked column its notice, now built from the same atoms.
    def test_plugin_kanban_column_renders_from_atoms_like_native(self):
        rendered = self.assert_success(self.call_cli("plugin", "render", "--page", "KanbanColumn", "--event", "add-backlog-task-button:onPress")[0])
        self.assertEqual(rendered["errors"], [])
        tree = rendered["tree"]
        # The same identifiers the board's native KanbanColumnSection gives its column.
        for test_id in ["column-backlog", "column-heading-backlog", "column-count-backlog", "add-backlog-task-button", "empty-state-backlog",
                        "column-in-progress", "column-heading-in-progress", "column-count-in-progress",
                        "column-blocked", "column-heading-blocked", "column-count-blocked", "blocked-waiting-indicator", "empty-state-blocked",
                        "column-waiting-response", "column-heading-waiting-response", "column-count-waiting-response",
                        "empty-state-waiting-response",
                        "column-done", "column-heading-done", "column-count-done", "empty-state-done"]:
            self.plugin_node(tree, test_id)
        types = {node["type"] for node in self.plugin_nodes(tree)} - {"#root", "#text"}
        self.assertEqual(types, {"Panel", "Stack", "Text", "Icon", "Label", "Button", "Spacer"}, "The columns are atoms only.")
        all_ids = [node.get("props", {}).get("testID") for node in self.plugin_nodes(tree)]
        self.assertEqual(all_ids.count("add-backlog-task-button"), 1, "Only the Backlog has an Add button.")
        self.assertEqual(all_ids.count("blocked-waiting-indicator"), 1, "Only the Blocked column has the notice.")
        self.assertNotIn("empty-state-in-progress", all_ids, "A column with tasks has no empty state.")
        tinted = [key for key in ["backlog", "in-progress", "blocked", "waiting-response", "done"]
                  if self.plugin_node(tree, "column-" + key)["children"][0]["type"] == "Panel"]
        self.assertEqual(tinted, ["waiting-response"], "Only the Waiting Response column nests its content in a tint Panel.")

        backlog = self.plugin_node(tree, "column-backlog")
        self.assertEqual(backlog["type"], "Panel")
        self.assertEqual((backlog["props"]["spacing"], backlog["props"]["padding"], backlog["props"]["cornerRadius"], backlog["props"]["minHeight"]), (13, 14, 16, 170))
        self.assertEqual([child["type"] for child in backlog["children"]], ["Stack", "Panel"], "The header, then the empty state.")
        header = backlog["children"][0]
        self.assertEqual([child["type"] for child in header["children"]], ["Panel", "Text", "Spacer", "Panel", "Button"], "Dot, title, spacer, count, Add.")
        dot = header["children"][0]
        self.assertEqual((dot["props"]["fill"], dot["props"]["width"], dot["props"]["height"]), ("#8591A8", 8, 8))
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "column-heading-backlog")), "BACKLOG")
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "column-count-backlog")), "0")
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "column-count-in-progress")), "2")
        add = self.plugin_node(tree, "add-backlog-task-button")
        self.assertEqual((add["props"]["style"], add["props"]["controlSize"], add["props"]["label"], add["events"]), ("bordered", "small", "Add task to Backlog", ["onPress"]))
        empty = self.plugin_node(tree, "empty-state-backlog")
        self.assertEqual((empty["props"]["dash"], empty["props"]["align"], empty["props"]["minHeight"]), ([5, 4], "center", 124))
        self.assertEqual([self.plugin_text(child) for child in empty["children"] if child["type"] == "Text"], ["No tasks yet", "Create a task to get started"])
        self.assertEqual([self.plugin_text(child) for child in self.plugin_node(tree, "empty-state-done")["children"] if child["type"] == "Text"], ["No tasks yet", "Drop a task here"])
        self.assertEqual(self.plugin_node(tree, "empty-state-done")["children"][0]["props"]["name"], "checkmark.circle")
        notice = self.plugin_node(tree, "blocked-waiting-indicator")
        self.assertEqual((notice["type"], notice["props"]["text"], notice["props"]["icon"], notice["props"]["color"]), ("Label", "Waiting for user intervention", "hand.raised.fill", "red"))

        # The Waiting Response column lays a tint Panel in its accent over the column's base panel.
        waiting = self.plugin_node(tree, "column-waiting-response")
        self.assertEqual((waiting["type"], waiting["props"]["fill"], waiting["props"]["cornerRadius"], waiting["props"]["minHeight"]), ("Panel", "panel", 16, 170))
        self.assertNotIn("stroke", waiting["props"], "The tint Panel draws the tinted column's border.")
        self.assertEqual([child["type"] for child in waiting["children"]], ["Panel"], "The column holds only its tint Panel.")
        tint = waiting["children"][0]
        self.assertEqual((tint["type"], tint["props"]["fill"], tint["props"]["fillOpacity"], tint["props"]["stroke"], tint["props"]["strokeOpacity"]),
                         ("Panel", "#A370CC", 0.12, "#A370CC", 0.34), "A soft purple wash with a hairline purple border.")
        self.assertEqual((tint["props"]["spacing"], tint["props"]["padding"], tint["props"]["cornerRadius"], tint["props"]["minHeight"]), (13, 14, 16, 170))
        self.assertEqual([child["type"] for child in tint["children"]], ["Stack", "Panel"], "The header, then the empty state, inside the tint.")
        waiting_count = self.plugin_node(tree, "column-count-waiting-response")
        self.assertEqual(waiting_count["props"]["color"], "#A370CC", "The tinted column's count reads in its accent.")
        self.assertEqual(self.plugin_node(tree, "column-count-backlog")["props"]["color"], "secondary")
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "column-heading-waiting-response")), "WAITING RESPONSE")

        last_action = self.plugin_node(tree, "js-last-action")
        self.assertEqual(self.plugin_text(last_action), "Last: add", "The Add button ran its JavaScript handler.")
        pressed = {commit["step"]: commit for commit in rendered["commits"]}["add-backlog-task-button:onPress"]
        self.assertEqual(pressed["ops"], ["text"], "Pressing Add changes only the readout.")
        self.assertEqual(pressed["touchedNodes"], [last_action["children"][1]["id"]])
        self.assertEqual(backlog["updates"], 0, "No column re-rendered.")
        self.assert_failure(self.call_cli("plugin", "render", "--page", "KanbanColumn", "--event", "column-backlog:onPress", expected_status=2)[0], "invalid_argument")
    # case-contract: test_plugin_card_uses_default_content_padding | The Plugin Catalog's Card page gives a Card with no padding prop its 14-point default, while `padding: 0` removes it. `plugin render --page Card` omits the default common padding but keeps the explicit zero override on the second Card, and in the UI two otherwise identical cards have the same width while the default-padded card is 28 points taller; each card keeps its own content inside the surface.
    def test_plugin_card_uses_default_content_padding(self):
        rendered = self.assert_success(self.call_cli("plugin", "render", "--page", "Card")[0])
        self.assertEqual(rendered["errors"], [])
        default_card = self.plugin_node(rendered["tree"], "card-demo")
        zero_card = self.plugin_node(rendered["tree"], "card-zero-padding")
        self.assertEqual((default_card["type"], default_card["props"]["testID"]), ("Card", "card-demo"))
        self.assertNotIn("padding", default_card["props"], "Card uses its default content padding.")
        self.assertEqual((zero_card["type"], zero_card["props"]["padding"]), ("Card", 0), "Card padding remains overrideable.")
        self.assertEqual([child["type"] for child in default_card["children"]], ["Stack"])
        self.assertEqual([child["type"] for child in zero_card["children"]], ["Stack"])
    # case-contract: test_plugin_presentation_atoms_open_modal_page_and_side_panel | Plugins present UI the three ways the board does, each a controlled atom whose first child is what it is presented from and stays laid out as usual. On the Plugin Catalog's Modal page, the Open modal button runs onPress (Last: open) and opens a 320-point sheet over the window that starts with the standard header its title props describe (its icon, the Modal title and its subtitle, and a close button) above content that brings no padding of its own yet sits 24 points in from the sheet's edges (the default inset) and a default spacing below the header, with a Done button; Done closes it (Last: done), the header's close button closes it through onDismiss (Last: dismiss), and Escape closes it again through onDismiss. On the Popover page the anchor opens a popover whose content, again with no padding of its own, is inset 14 points by default and spaced apart, and Escape dismisses it; a titled Modal and a second Popover each override inset to 0 and spacing to 4, which the UI geometry and `plugin render` tree both confirm. On the Page page, Open page (Last: open) slides a page over the whole 420 by 220 point view below it, covering that view's frame and showing its title, and its Back button closes it (Last: back), uncovering the view. On the SidePanel page, Open trailing (Last: open trailing) slides a 200-point panel as tall as the 480 by 240 point view below it in over that view's trailing edge, Open leading (Last: open leading) over its leading edge, and the panel's close button closes it (Last: close). `plugin render` keeps each atom's presented content in the tree after its first child, and opening or closing is one commit that updates only the presentation atom's props and the readout. `plugin render` reports the Modal's title, subtitle and icon with no inset or spacing set and the Popover's content with no Stack of its own, and an explicit inset and spacing override the defaults with no errors. Only a Modal raises onDismiss: a Page or SidePanel given an onDismiss handler, or a Modal, Page or SidePanel without isPresented or with a mistyped width or edge, or a mistyped Modal title or inset or Popover spacing, is reported in errors.
    def test_plugin_presentation_atoms_open_modal_page_and_side_panel(self):
        def commit(rendered, step):
            return {entry["step"]: entry for entry in rendered["commits"]}[step]

        # Modal: the presenter, then the sheet's content, kept in the tree while closed.
        modal_page = self.assert_success(self.call_cli("plugin", "render", "--page", "Modal")[0])
        self.assertEqual(modal_page["errors"], [])
        modal = self.plugin_node(modal_page["tree"], "modal-demo")
        self.assertEqual((modal["type"], modal["props"]["isPresented"], modal["props"]["width"], modal["events"]), ("Modal", False, 320, ["onDismiss"]))
        self.assertEqual((modal["props"]["title"], modal["props"]["subtitle"], modal["props"]["icon"]), ("Modal title", "A standard header over padded content", "macwindow"),
                         "The sheet's standard header comes from the Modal's own title props.")
        self.assertNotIn("inset", modal["props"], "The content is padded by the Modal's default inset.")
        self.assertNotIn("spacing", modal["props"])
        self.assertEqual(modal["children"][0]["props"]["testID"], "modal-open", "The first child presents the sheet.")
        self.assertEqual([child["type"] for child in modal["children"][1:]], ["Text", "Stack"], "The content brings no title or padding Stack of its own.")
        self.assertNotIn("padding", modal["children"][1]["props"])
        self.plugin_node(modal["children"][1], "modal-body")
        self.plugin_node(modal_page["tree"], "modal-done")
        last = self.plugin_node(modal_page["tree"], "modal-last")
        opened = self.assert_success(self.call_cli("plugin", "render", "--page", "Modal", "--event", "modal-open:onPress",
                                                   "--event", "modal-done:onPress", "--event", "modal-open:onPress", "--event", "modal-demo:onDismiss")[0])
        self.assertEqual(opened["errors"], [])
        steps = [entry for entry in opened["commits"] if entry["step"] != "render"]
        self.assertEqual([entry["step"] for entry in steps], ["modal-open:onPress", "modal-done:onPress", "modal-open:onPress", "modal-demo:onDismiss"])
        for entry in steps:
            self.assertEqual(sorted(entry["ops"]), ["text", "update"], f"{entry['step']} updates only the Modal's props and the readout.")
            self.assertEqual(sorted(entry["touchedNodes"]), sorted([modal["id"], last["children"][1]["id"]]))
        self.assertFalse(self.plugin_node(opened["tree"], "modal-demo")["props"]["isPresented"])
        self.assertEqual(self.plugin_text(self.plugin_node(opened["tree"], "modal-last")), "Last: dismiss", "Escape's onDismiss ran its JavaScript handler.")
        reopened = self.assert_success(self.call_cli("plugin", "render", "--page", "Modal", "--event", "modal-open:onPress")[0])
        self.assertTrue(self.plugin_node(reopened["tree"], "modal-demo")["props"]["isPresented"])
        self.assertEqual(self.plugin_text(self.plugin_node(reopened["tree"], "modal-last")), "Last: open")
        modal_override = self.assert_success(self.call_cli("plugin", "render", "--page", "Modal", "--event", "modal-override-open:onPress")[0])
        compact_modal = self.plugin_node(modal_override["tree"], "modal-override")
        self.assertEqual((compact_modal["props"]["isPresented"], compact_modal["props"]["inset"], compact_modal["props"]["spacing"], compact_modal["props"]["title"]), (True, 0, 4, "Compact modal"))
        self.assertEqual(self.plugin_node(modal_override["tree"], "modal-override-body")["props"]["testID"], "modal-override-body")

        # Popover: its content padded and spaced by default, with no Stack of its own.
        popover_page = self.assert_success(self.call_cli("plugin", "render", "--page", "Popover", "--event", "popover-anchor:onPress")[0])
        self.assertEqual(popover_page["errors"], [])
        popover = self.plugin_node(popover_page["tree"], "popover-demo")
        self.assertEqual((popover["type"], popover["props"]["isPresented"], popover["props"]["width"]), ("Popover", True, 220))
        self.assertNotIn("inset", popover["props"])
        self.assertEqual([child["props"]["testID"] for child in popover["children"]], ["popover-anchor", "popover-title", "popover-body"])
        self.assertEqual(self.plugin_text(self.plugin_node(popover_page["tree"], "popover-last")), "Last: toggle")
        override_page = self.assert_success(self.call_cli("plugin", "render", "--page", "Popover", "--event", "popover-override-anchor:onPress")[0])
        self.assertEqual(override_page["errors"], [])
        override_popover = self.plugin_node(override_page["tree"], "popover-override")
        self.assertEqual((override_popover["props"]["isPresented"], override_popover["props"]["inset"], override_popover["props"]["spacing"]), (True, 0, 4), "Popover inset and spacing overrides are preserved.")
        self.assertEqual([child["props"]["testID"] for child in override_popover["children"]], ["popover-override-anchor", "popover-override-title", "popover-override-body"])
        overridden = self.render_plugin('Playhouse.render(h(Modal, { isPresented: true, title: "Sized", inset: 0, spacing: 4 }, h(Text, null, "Base"), h(Text, null, "Content")));')
        self.assertEqual(overridden["result"]["errors"], [], "inset and spacing override the defaults.")
        sized = next(node for node in self.plugin_nodes(overridden["result"]["tree"]) if node["type"] == "Modal")
        self.assertEqual((sized["props"]["inset"], sized["props"]["spacing"], sized["props"]["title"]), (0, 4, "Sized"))

        # Page: the covered view, then the page.
        page_page = self.assert_success(self.call_cli("plugin", "render", "--page", "Page", "--event", "page-open:onPress")[0])
        self.assertEqual(page_page["errors"], [])
        page = self.plugin_node(page_page["tree"], "page-demo")
        self.assertEqual((page["type"], page["props"]["isPresented"], page.get("events", [])), ("Page", True, []))
        base = page["children"][0]
        self.assertEqual((base["props"]["testID"], base["props"]["width"], base["props"]["height"]), ("page-base", 420, 220))
        self.assertEqual([child["type"] for child in page["children"]], ["Stack", "Stack", "Divider", "Text"], "The covered view, then the page's column.")
        self.plugin_node(page["children"][1], "page-title")
        self.assertEqual(sorted(commit(page_page, "page-open:onPress")["ops"]), ["text", "update"])
        closed = self.assert_success(self.call_cli("plugin", "render", "--page", "Page", "--event", "page-open:onPress", "--event", "page-back:onPress")[0])
        self.assertFalse(self.plugin_node(closed["tree"], "page-demo")["props"]["isPresented"])
        self.assertEqual(self.plugin_text(self.plugin_node(closed["tree"], "page-last")), "Last: back")
        self.assertEqual(sorted(commit(closed, "page-back:onPress")["ops"]), ["text", "update"])

        # SidePanel: the covered view, then the panel, on either edge.
        side_page = self.assert_success(self.call_cli("plugin", "render", "--page", "SidePanel", "--event", "side-panel-open-trailing:onPress")[0])
        self.assertEqual(side_page["errors"], [])
        panel = self.plugin_node(side_page["tree"], "side-panel-demo")
        self.assertEqual((panel["type"], panel["props"]["isPresented"], panel["props"]["edge"], panel["props"]["width"], panel.get("events", [])), ("SidePanel", True, "trailing", 200, []))
        base = panel["children"][0]
        self.assertEqual((base["props"]["testID"], base["props"]["width"], base["props"]["height"]), ("side-panel-base", 480, 240))
        self.plugin_node(panel["children"][1], "side-panel-title")
        self.plugin_node(panel["children"][1], "side-panel-close")
        self.assertEqual(self.plugin_text(self.plugin_node(side_page["tree"], "side-panel-last")), "Last: open trailing")
        leading = self.assert_success(self.call_cli("plugin", "render", "--page", "SidePanel", "--event", "side-panel-open-leading:onPress", "--event", "side-panel-close:onPress")[0])
        self.assertEqual(self.plugin_node(leading["tree"], "side-panel-demo")["props"]["edge"], "leading")
        self.assertEqual(sorted(commit(leading, "side-panel-open-leading:onPress")["ops"]), ["text", "update"])
        self.assertFalse(self.plugin_node(leading["tree"], "side-panel-demo")["props"]["isPresented"])
        self.assertEqual(self.plugin_text(self.plugin_node(leading["tree"], "side-panel-last")), "Last: close")

        # Only a Modal raises onDismiss, and each needs isPresented with well-typed props.
        for source, error in [
            ('Playhouse.render(h(Page, { isPresented: true, onDismiss: function () {} }, h(Text, null, "Base")));', '<Page> has no event "onDismiss"'),
            ('Playhouse.render(h(SidePanel, { isPresented: true, onDismiss: function () {} }, h(Text, null, "Base")));', '<SidePanel> has no event "onDismiss"'),
            ('Playhouse.render(h(Modal, { width: 300 }, h(Text, null, "Base")));', "<Modal> has an invalid prop: isPresented: missing"),
            ('Playhouse.render(h(Modal, { isPresented: true, title: 3 }, h(Text, null, "Base")));', "<Modal> has an invalid prop: title: expected a string, found 3"),
            ('Playhouse.render(h(Modal, { isPresented: true, inset: "wide" }, h(Text, null, "Base")));', "<Modal> has an invalid prop: inset: expected a number, found a string"),
            ('Playhouse.render(h(Popover, { isPresented: true, spacing: true }, h(Text, null, "Base")));', "<Popover> has an invalid prop: spacing: expected a number, found a boolean"),
            ('Playhouse.render(h(Page, {}, h(Text, null, "Base")));', "<Page> has an invalid prop: isPresented: missing"),
            ('Playhouse.render(h(SidePanel, { isPresented: true, width: "wide" }, h(Text, null, "Base")));', "<SidePanel> has an invalid prop: width: expected a number, found a string"),
            ('Playhouse.render(h(SidePanel, { isPresented: true, edge: 3 }, h(Text, null, "Base")));', "<SidePanel> has an invalid prop: edge: expected a string, found 3"),
        ]:
            failed = self.render_plugin(source, expected_status=1)
            self.assertTrue(failed["ok"], "A plugin that fails still reports its render.")
            self.assertTrue(any(error in message for message in failed["result"]["errors"]), f"{source} reports {error}: {failed['result']['errors']}")
        self.assert_failure(self.call_cli("plugin", "render", "--page", "SidePanel", "--event", "side-panel-demo:onDismiss", expected_status=2)[0], "invalid_argument")
    # case-contract: test_plugin_done_archive_renders_from_atoms_like_native | The Plugin Catalog's Done Archive page shows the board's Done archive composed in JavaScript from atoms above the native SwiftUI archive the board presents, built from the same atoms and sample model, each opened by the board header's archive button (the bordered Button atom with the archivebox icon, labelled Done tasks) into a 340-point SidePanel over the trailing edge of a 560 by 460 point stand-in for the board, open at first. Both show the Done tasks title and its close button, the search field with its Search tasks and conversations placeholder, and a list of five rows, each a button opening its task with the done checkmark, its title and its date, beside its pull request actions: a #227 link, a PR button beside a #228 link, a PRs button, a disabled busy PR button showing a spinner, and nothing for a task without repositories, each at the same size in both and with the board archive's identifiers (done-archive-task, done-archive-create-pr, done-archive-pr-link, done-archive-search, and done-archive-list valued 5 tasks loaded). The JavaScript tree uses only atoms (SidePanel, Stack, Text, Icon, Button, Link, Spinner, Spacer, Divider, TextField, Scroll), its search a plain TextField on a rounded Stack. The list's end is in view, so its onEndReached runs on both sides (End reached). Typing in the JavaScript search runs onChange (Last: search followed by the text), narrows the rows to the matching title and shows the clear button, which clears the search and brings every row back; a search that matches nothing shows No matching tasks instead of the list. A PR button runs its handler with its task (Last: create pr followed by the title), a row runs open (Last: open followed by the title) and slides the panel away, the archive button opens it again (Last: toggle open), and the close button closes it (Last: close), while the native archive keeps its own state. The list raises no onPress, so pressing it is refused as invalid_argument.
    def test_plugin_done_archive_renders_from_atoms_like_native(self):
        rendered = self.assert_success(self.call_cli("plugin", "render", "--page", "DoneArchive")[0])
        self.assertEqual(rendered["errors"], [])
        tree = rendered["tree"]
        sample = json.loads((Path(__file__).resolve().parent.parent / "Playhouse/Resources/PluginRuntime/catalog/sample-done-archive.json").read_text(encoding="utf-8"))["doneArchive"]
        ids = [row["id"] for row in sample["rows"]]
        types = {node["type"] for node in self.plugin_nodes(tree)} - {"#root", "#text"}
        self.assertEqual(types, {"SidePanel", "Stack", "Text", "Icon", "Button", "Link", "Spinner", "Spacer", "Divider", "TextField", "Scroll"}, "The archive is atoms only.")

        button = self.plugin_node(tree, "done-archive-button")
        self.assertEqual((button["type"], button["props"]["style"], button["props"]["label"], button["props"]["help"]), ("Button", "bordered", "Done tasks", "Browse completed tasks"))
        self.assertEqual(button["children"][0]["props"]["name"], "archivebox")
        panel = self.plugin_node(tree, "done-archive-panel")
        self.assertEqual((panel["type"], panel["props"]["isPresented"], panel["props"]["width"]), ("SidePanel", True, 340), "The archive starts open in a 340-point SidePanel.")
        self.assertNotIn("edge", panel["props"], "It slides in over the trailing edge, the default.")
        board = panel["children"][0]
        self.assertEqual((board["props"]["testID"], board["props"]["width"], board["props"]["height"]), ("done-archive-board", 560, 460))
        archive = panel["children"][1]
        self.assertEqual([child["type"] for child in archive["children"]], ["Stack", "Divider", "Stack", "Scroll"], "Header, divider, search, then the list.")
        self.assertEqual(self.plugin_text(self.plugin_node(archive, "done-archive-title")), "Done tasks")
        close = self.plugin_node(archive, "close-done-archive-button")
        self.assertEqual((close["props"]["label"], close["props"]["help"], close["children"][0]["props"]["name"]), ("Close done tasks", "Close done tasks", "xmark"))
        search = self.plugin_node(archive, "done-archive-search")
        self.assertEqual((search["type"], search["props"]["style"], search["props"]["placeholder"], search["props"]["text"]), ("TextField", "plain", "Search tasks and conversations", ""))
        search_box = archive["children"][2]["children"][0]
        self.assertEqual((search_box["props"]["fill"], search_box["props"]["fillOpacity"], search_box["props"]["cornerRadius"], search_box["props"]["padding"]), ("primary", 0.045, 9, 10), "The search sits on a rounded Stack.")
        self.assertEqual(search_box["children"][0]["props"]["name"], "magnifyingglass")
        all_ids = [node.get("props", {}).get("testID") for node in self.plugin_nodes(tree)]
        self.assertNotIn("clear-archive-search-button", all_ids, "An empty search has no clear button.")

        listing = self.plugin_node(archive, "done-archive-list")
        self.assertEqual((listing["props"]["lazy"], listing["props"]["spacing"], listing["props"]["value"], listing["events"]), (True, 5, "5 tasks loaded", ["onEndReached"]))
        self.assertEqual(len(listing["children"]), 5, "One row per sample task.")
        for row in sample["rows"]:
            opener = self.plugin_node(listing, f"done-archive-task-{row['id']}")
            self.assertEqual(opener["props"]["help"], f"Open task: {row['title']}")
            texts = [self.plugin_text(node) for node in self.plugin_nodes(opener) if node["type"] == "Text"]
            self.assertEqual(texts, [row["title"], row["date"]])
            icon = next(node for node in self.plugin_nodes(opener) if node["type"] == "Icon")
            self.assertEqual((icon["props"]["name"], icon["props"]["color"]), ("checkmark.circle.fill", "#339E73"))
        link = self.plugin_node(listing, f"done-archive-pr-link-{ids[0]}-227")
        self.assertEqual((link["type"], link["props"]["url"], link["props"]["help"], link["props"]["minWidth"], link["props"]["minHeight"]), ("Link", "https://github.com/example/playhouse/pull/227", "playhouse", 30, 30))
        self.assertEqual(self.plugin_text(link["children"][0]), "#227")
        create = self.plugin_node(listing, f"done-archive-create-pr-{ids[1]}")
        self.assertEqual((create["props"]["style"], create["props"]["width"], create["props"]["height"], create["props"]["disabled"]), ("borderless", 30, 30, False))
        self.assertEqual(self.plugin_text(create["children"][0]), "PR")
        self.plugin_node(listing, f"done-archive-pr-link-{ids[1]}-228")
        self.assertEqual(self.plugin_text(self.plugin_node(listing, f"done-archive-create-pr-{ids[2]}")["children"][0]), "PRs")
        busy = self.plugin_node(listing, f"done-archive-create-pr-{ids[3]}")
        self.assertEqual((busy["props"]["disabled"], busy["children"][0]["type"], busy["children"][0]["props"]["size"]), (True, "Spinner", "mini"))
        self.assertNotIn(f"done-archive-create-pr-{ids[4]}", all_ids, "A task without repositories has no pull request actions.")
        self.assertEqual(len(listing["children"][4]["children"]), 1, "Its row is only its open button.")
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "js-end-reached")), "End not reached", "Headlessly nothing scrolls into view.")

        # Each control runs its JavaScript handler.
        steps = ["done-archive-list:onEndReached", "done-archive-search:onChange:release"]
        driven = self.assert_success(self.call_cli("plugin", "render", "--page", "DoneArchive", *[part for step in steps for part in ("--event", step)])[0])
        self.assertEqual(driven["errors"], [])
        commits = {entry["step"]: entry for entry in driven["commits"]}
        end_text = self.plugin_node(tree, "js-end-reached")
        self.assertEqual(commits["done-archive-list:onEndReached"]["ops"], ["text"])
        self.assertEqual(commits["done-archive-list:onEndReached"]["touchedNodes"], [end_text["children"][0]["id"]], "Reaching the end changes only its readout.")
        self.assertEqual(self.plugin_text(self.plugin_node(driven["tree"], "js-end-reached")), "End reached")
        narrowed = self.plugin_node(driven["tree"], "done-archive-list")
        self.assertEqual([child["children"][0]["props"]["testID"] for child in narrowed["children"]], [f"done-archive-task-{ids[4]}"], "The search narrows the rows to the matching title.")
        self.assertEqual(self.plugin_node(driven["tree"], "done-archive-search")["props"]["text"], "release")
        self.plugin_node(driven["tree"], "clear-archive-search-button")
        self.assertEqual(self.plugin_text(self.plugin_node(driven["tree"], "js-last-action")), "Last: search release")

        pressed = self.assert_success(self.call_cli("plugin", "render", "--page", "DoneArchive", "--event", f"done-archive-create-pr-{ids[1]}:onPress")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(pressed["tree"], "js-last-action")), f"Last: create pr {sample['rows'][1]['title']}")
        self.assertEqual({entry["step"]: entry for entry in pressed["commits"]}[f"done-archive-create-pr-{ids[1]}:onPress"]["ops"], ["text"], "A PR button changes only the readout.")

        cleared = self.assert_success(self.call_cli("plugin", "render", "--page", "DoneArchive", "--event", "done-archive-search:onChange:nothing-matches",
                                                    "--event", "clear-archive-search-button:onPress")[0])
        self.assertEqual(len(self.plugin_node(cleared["tree"], "done-archive-list")["children"]), 5, "Clearing the search brings every row back.")
        self.assertEqual(self.plugin_node(cleared["tree"], "done-archive-search")["props"]["text"], "")
        empty = self.assert_success(self.call_cli("plugin", "render", "--page", "DoneArchive", "--event", "done-archive-search:onChange:nothing-matches")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(empty["tree"], "done-archive-empty-state")), "No matching tasks")
        self.assertNotIn("done-archive-list", [node.get("props", {}).get("testID") for node in self.plugin_nodes(empty["tree"])], "No list while nothing matches.")

        opened = self.assert_success(self.call_cli("plugin", "render", "--page", "DoneArchive", "--event", f"done-archive-task-{ids[0]}:onPress",
                                                   "--event", "done-archive-button:onPress", "--event", "close-done-archive-button:onPress")[0])
        opened_commits = [entry for entry in opened["commits"] if entry["step"] != "render"]
        self.assertEqual(sorted(opened_commits[0]["ops"]), ["text", "update"], "Opening a row closes the panel: its props and the readout.")
        self.assertEqual(self.plugin_text(self.plugin_node(opened["tree"], "js-last-action")), "Last: close")
        self.assertFalse(self.plugin_node(opened["tree"], "done-archive-panel")["props"]["isPresented"])
        reopened = self.assert_success(self.call_cli("plugin", "render", "--page", "DoneArchive", "--event", f"done-archive-task-{ids[0]}:onPress", "--event", "done-archive-button:onPress")[0])
        self.assertTrue(self.plugin_node(reopened["tree"], "done-archive-panel")["props"]["isPresented"])
        self.assertEqual(self.plugin_text(self.plugin_node(reopened["tree"], "js-last-action")), "Last: toggle open")
        first_open = self.assert_success(self.call_cli("plugin", "render", "--page", "DoneArchive", "--event", f"done-archive-task-{ids[0]}:onPress")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(first_open["tree"], "js-last-action")), f"Last: open {sample['rows'][0]['title']}")
        self.assert_failure(self.call_cli("plugin", "render", "--page", "DoneArchive", "--event", "done-archive-list:onPress", expected_status=2)[0], "invalid_argument")
    # case-contract: test_plugin_token_stats_renders_from_atoms_like_native | The Plugin Catalog's Token Stats page shows the Token Stats modal composed in JavaScript from atoms above the native SwiftUI modal the board presents, built from the same atoms and sample data, each opened by the task item's token counter (the same overhanging Button atom, labelled with its description and hinted Open Token Stats). Both show the title and the task's title, the View raw input… button, a section bar of Overview, Wasters, Tools & MCP and Overhead with Overview selected, the call headlines (Final transcript size, Total sent (incl. subagents), Excluding cache reads (incl. subagents)), the main-agent and subagent split, the call and output lines, the total, the four buckets, the context compaction and resume cache miss lines, the per-tool rollup and the per-turn rows, each at the same size in both, and the JavaScript tree uses only atoms (Panel, Stack, Text, Label, Button, Spacer, ChoiceBar, Divider, Scroll, Meter) with the board modal's identifiers. Choosing Wasters in the JavaScript section bar runs onChange with its value (Last: section wasters) and shows the largest items, each with a 72-point share bar, its kind, the removed-by-compaction flag, its request count and a small Show button, then the repeated result and the cache miss, while the native modal stays on Overview until its own bar moves it, after which both show the same rows at the same size. Show runs its JavaScript handler with the item's raw input target (Last: raw input claude #14) and View raw input… with the final transcript (Last: raw input final transcript), without re-rendering any row. Tools & MCP lists each tool's bar, calls and total and the MCP server, and Overhead lists what every request carries and each agent. The overview scrolls within at most 320 points and each map section within a fixed 420. Done closes the JavaScript modal (Last: done) and leaves the native one open, and the counter opens it again (Last: open). The section bar raises no onPress, so pressing it is refused as invalid_argument.
    def test_plugin_token_stats_renders_from_atoms_like_native(self):
        rendered = self.assert_success(self.call_cli("plugin", "render", "--page", "TokenStats")[0])
        self.assertEqual(rendered["errors"], [])
        tree = rendered["tree"]
        # The same identifiers the board's native TokenStatsView gives its modal.
        for test_id in ["token-stats", "token-stats-title", "token-stats-task-title", "token-stats-raw-input-button", "token-stats-sections",
                        "token-stats-final-transcript", "token-stats-total-sent", "token-stats-excluding-cache", "token-stats-excluding-cache-split",
                        "token-stats-total-calls", "token-stats-output", "token-stats-total", "token-stats-overview",
                        "token-stats-compaction-0", "token-stats-resume-cache-miss-0",
                        "token-stats-tool-Bash", "token-stats-tool-Read", "token-stats-turn-turn-1", "token-stats-turn-turn-2", "close-token-stats-button"]:
            self.plugin_node(tree, test_id)
        types = {node["type"] for node in self.plugin_nodes(tree)} - {"#root", "#text"}
        self.assertEqual(types, {"Panel", "Stack", "Text", "Label", "Button", "Spacer", "ChoiceBar", "Divider", "Scroll"},
                         "The overview is atoms only.")

        # The task item's counter opens the modal: the same Button atom as on the card.
        counter = self.plugin_node(tree, "token-stats-counter")
        self.assertEqual((counter["type"], counter["events"]), ("Button", ["onPress"]))
        self.assertEqual((counter["props"]["emphasis"], counter["props"]["overhang"], counter["props"]["paddingX"]), (6, True, 4))
        self.assertEqual((counter["props"]["label"], counter["props"]["hint"]), ("3.7K tokens sent · 8 calls · 650 final transcript", "Open Token Stats"))
        self.assertEqual(self.plugin_text(counter["children"][0]), "3.7K")
        self.assertEqual((counter["children"][0]["props"]["design"], counter["children"][0]["props"]["numeric"]), ("monospaced", True))

        modal = self.plugin_node(tree, "token-stats")
        self.assertEqual((modal["props"]["width"], modal["props"]["padding"], modal["props"]["group"]), (672, 24, True), "720 points wide, padding included.")
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "token-stats-title")), "Token stats")
        self.assertEqual(self.plugin_node(tree, "token-stats-title")["props"]["design"], "rounded")
        raw_input = self.plugin_node(tree, "token-stats-raw-input-button")
        self.assertEqual((raw_input["props"]["style"], raw_input["props"]["disabled"]), ("bordered", False))
        self.assertEqual((raw_input["children"][0]["type"], raw_input["children"][0]["props"]["text"]), ("Label", "View raw input…"))
        sections = self.plugin_node(tree, "token-stats-sections")
        self.assertEqual(sections["props"]["selected"], "overview", "Token Stats opens on its Overview section.")
        self.assertEqual([(option["label"], option["testID"]) for option in sections["props"]["options"]], [
            ("Overview", "token-stats-section-overview"), ("Wasters", "token-stats-section-wasters"),
            ("Tools & MCP", "token-stats-section-tools"), ("Overhead", "token-stats-section-overhead")])
        for test_id, text in [("token-stats-final-transcript", "650"), ("token-stats-total-sent", "3,680"), ("token-stats-excluding-cache", "1,710"),
                              ("token-stats-excluding-cache-split", "Excluding cache reads: 720 main agent · 990 subagents"),
                              ("token-stats-total-calls", "8 model calls · 4 main, 4 across 2 subagents"), ("token-stats-output", "Output 170"),
                              ("token-stats-total", "3,200"),
                              ("token-stats-compaction-0", "Requested with /compact · 2,900 → 900 tokens"),
                              ("token-stats-resume-cache-miss-0", "Resume cache miss · Cache read 0 tokens · cache rewritten with 390 tokens")]:
            self.assertEqual(self.plugin_text(self.plugin_node(tree, test_id)), text)
        scroll = self.plugin_node(tree, "token-stats-overview")
        self.assertEqual((scroll["type"], scroll["props"]["maxHeight"], scroll["props"]["spacing"]), ("Scroll", 320, 18))
        tool = self.plugin_node(tree, "token-stats-tool-Bash")
        self.assertEqual((tool["props"]["align"], tool["props"]["group"]), ("baseline", True))
        self.assertEqual([self.plugin_text(child) for child in tool["children"] if child["type"] == "Text"], ["Bash", "2 turns", "3,200"])
        texts = [self.plugin_text(node) for node in self.plugin_nodes(tree) if node["type"] == "Text"]
        for label, value in [("Input", "240"), ("Output", "170"), ("Cache read", "2,400"), ("Cache write", "390")]:
            index = texts.index(label)
            self.assertEqual(texts[index + 1], value, f"The {label} bucket reads {value}.")
        done = self.plugin_node(tree, "close-token-stats-button")
        self.assertEqual((done["props"]["style"], done["props"]["shortcut"]), ("prominent", "default"))

        wasters = self.assert_success(self.call_cli(
            "plugin", "render", "--page", "TokenStats",
            "--event", "token-stats-sections:onChange:wasters",
            "--event", "token-stats-waster-0-show:onPress",
            "--event", "token-stats-raw-input-button:onPress")[0])
        self.assertEqual(wasters["errors"], [])
        tree = wasters["tree"]
        self.assertEqual(self.plugin_node(tree, "token-stats-sections")["props"]["selected"], "wasters")
        test_ids = {node.get("props", {}).get("testID") for node in self.plugin_nodes(tree)}
        self.assertNotIn("token-stats-total", test_ids, "Wasters replaces the overview.")
        self.assertEqual(self.plugin_node(tree, "token-stats-map")["props"]["height"], 420, "Each map section scrolls within a fixed 420 points.")
        first = self.plugin_node(tree, "token-stats-waster-0")
        self.assertEqual([child["type"] for child in first["children"]], ["Meter", "Stack", "Spacer", "Text", "Text", "Button"],
                         "Share bar, label and preview, the request count, the tokens, then Show.")
        bar = first["children"][0]["props"]
        self.assertEqual((bar["width"], bar["thickness"], bar["trackOpacity"], bar["minFill"], bar["fraction"]), (72, 6, 0.07, 2, 1))
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "token-stats-waster-0-label")), "fixturelogs/query_logs")
        label_row = first["children"][1]["children"][0]
        self.assertEqual([self.plugin_text(child) for child in label_row["children"]], ["fixturelogs/query_logs", "Tool result", "removed by compaction"],
                         "The label, its kind, then the compaction flag.")
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "token-stats-waster-0-requests")), "×63")
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "token-stats-waster-0-tokens")), "18,000")
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "token-stats-waster-0-removed")), "removed by compaction")
        self.assertNotIn("token-stats-waster-1-removed", test_ids, "An item still in the final transcript isn't flagged.")
        show = self.plugin_node(tree, "token-stats-waster-0-show")
        self.assertEqual((show["props"]["style"], show["props"]["controlSize"]), ("bordered", "small"))
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "token-stats-duplicate-0-copies")), "2 copies of 2,400")
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "token-stats-cache-miss-0-request")), "Request 34")
        commits = {commit["step"]: commit for commit in wasters["commits"]}
        last_action = self.plugin_node(tree, "js-last-action")
        self.assertEqual(self.plugin_text(last_action), "Last: raw input final transcript", "View raw input… ran its handler with the final transcript.")
        shown = commits["token-stats-waster-0-show:onPress"]
        self.assertEqual((shown["ops"], shown["touchedNodes"]), (["text"], [last_action["children"][1]["id"]]),
                         "Show ran its JavaScript handler without re-rendering any row.")
        self.assertIn("update", commits["token-stats-sections:onChange"]["ops"], "Choosing a section updates the ChoiceBar's selection.")
        shown_text = self.assert_success(self.call_cli(
            "plugin", "render", "--page", "TokenStats", "--event", "token-stats-sections:onChange:wasters", "--event", "token-stats-waster-0-show:onPress")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(shown_text["tree"], "js-last-action")), "Last: raw input claude #14",
                         "Show passes the item's raw input target.")

        tools = self.assert_success(self.call_cli("plugin", "render", "--page", "TokenStats", "--event", "token-stats-sections:onChange:tools")[0])
        tree = tools["tree"]
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "token-stats-measured-tool-fixturelogs/query_logs-total")), "18,000")
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "token-stats-measured-tool-Read-calls")), "2 calls · largest 2,400 · average 2,400")
        self.assertEqual(self.plugin_node(tree, "token-stats-measured-tool-Bash")["children"][0]["type"], "Meter")
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "token-stats-server-fixturelogs-detail")), "2 tools · 1 calls · definitions 1,200")

        overhead = self.assert_success(self.call_cli("plugin", "render", "--page", "TokenStats", "--event", "token-stats-sections:onChange:overhead")[0])
        tree = overhead["tree"]
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "token-stats-overhead-0-label")), "System prompt (part 1)")
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "token-stats-overhead-0-requests")), "× every request")
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "token-stats-overhead-2-requests")), "×63")
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "token-stats-agent-claude/fxw-sent")), "31,200")

        closed = self.assert_success(self.call_cli("plugin", "render", "--page", "TokenStats", "--event", "close-token-stats-button:onPress")[0])
        test_ids = {node.get("props", {}).get("testID") for node in self.plugin_nodes(closed["tree"])}
        self.assertNotIn("token-stats", test_ids, "Done closed the modal.")
        self.assertEqual(self.plugin_text(self.plugin_node(closed["tree"], "js-last-action")), "Last: done")
        reopened = self.assert_success(self.call_cli(
            "plugin", "render", "--page", "TokenStats", "--event", "close-token-stats-button:onPress", "--event", "token-stats-counter:onPress")[0])
        self.plugin_node(reopened["tree"], "token-stats-total")
        self.assertEqual(self.plugin_text(self.plugin_node(reopened["tree"], "js-last-action")), "Last: open", "The counter opened it again.")
        self.assert_failure(self.call_cli("plugin", "render", "--page", "TokenStats", "--event", "token-stats-sections:onPress", expected_status=2)[0], "invalid_argument")
    # case-contract: test_plugin_skills_page_renders_from_atoms_like_native | The Plugin Catalog's Skills Page shows the Skills modal's header and skill list composed in JavaScript from atoms above the native SwiftUI header and list the Skills modal uses, built from the same atoms and sample data, each 336 points wide like the modal and opened by the Skills button (the same plain Button atom with the sparkles icon, labelled Skills). Both show the close button (an xmark capsule labelled Close), a header of the page's sparkles icon (labelled Skills, Rules & MCP) followed by the Skills | Rules | MCP segmented tabs, then the search field and a small New Skill button, a Jump to bar of Repo, Global and Built-in anchors with their counts below them, then one scrolling list with the Repo, Global and Built-in sections in order, each headed by a button that collapses or expands it with Built-in collapsed at first, and the hint below them; a repository section's skills share one card with hairlines between them, each a single line with only its name led by one provider icon (the Claude logo for a Claude-only skill, the Codex logo for a Codex-only skill, a green check for one both can use, none for a skill no provider can use), a Conflict or Invalid icon right of a broken skill's name, a small Fix button on a broken skill and the actions menu, with no switch or Use button: the menu starts with Use (disabled for a skill that is off or that no provider can use) and Disable, or Enable for a skill that is off, which shows grayed out, while its description, issue and location sit in a hover hint (a Popover with hover on, left of the row) and the description is also the row's accessibility hint; and an empty repository's empty state, each at the same size in both, and the JavaScript tree uses only atoms (Panel, Stack, Text, Icon, Label, Button, Spacer, Divider, Scroll, Segmented, TextField, Menu, PressArea, Popover) with the Skills modal's identifiers. Clicking the JavaScript Built-in header runs its handler (Last: expand builtin) and shows its skills. Pressing the JavaScript Global anchor runs its handler (Last: jump global) and asks the list to scroll to Global (scrollTo global, a new scrollRequest on each press) while every section stays in the list, and an anchor expands a collapsed section. The menu's Use runs its handler (Last: use release-notes) without re-rendering any row, and its Disable runs onMenu (Last: toggle release-notes off), which grays the row out, disables Use and offers Enable, while the grayed-out row still responds to clicks; Enable turns it back on (Last: toggle release-notes on). Clicking a skill's text runs onPress (Last: open release-notes); pressing and holding it runs onLongPress, which starts selecting (Last: select release-notes): its row shows a checked checkbox and the accent highlight, the rows' own controls hide, built-in skills show no checkbox, and the search's row shows 1 selected with Fix, Delete and Done; a click on another row adds it (2 selected), and Done ends selecting (Last: done selecting). The actions menu runs onMenu with the chosen item's id (Last: menu release-notes edit), typing in the search runs onChange with the text, choosing Rules hides the anchors and the search, and the close button closes the JavaScript modal (Last: back) while the native one stays open, until the Skills button opens it again (Last: open). The search field raises no onPress, so pressing it is refused as invalid_argument.
    def test_plugin_skills_page_renders_from_atoms_like_native(self):
        rendered = self.assert_success(self.call_cli("plugin", "render", "--page", "SkillsPage")[0])
        self.assertEqual(rendered["errors"], [])
        tree = rendered["tree"]
        # The same identifiers the Skills page's native header and gallery give their atoms.
        for test_id in ["skills-page", "skills-back-button", "skills-title", "skills-kind-picker", "skills-tab-picker", "skills-anchor-repo", "skills-anchor-global",
                        "skills-anchor-builtin", "skills-group-repo", "skills-group-global", "skills-group-builtin", "skills-intro-repo", "skills-search", "new-skill-button",
                        "skills-provider-timing", "skills-list", "skills-repo-section-login-app", "skills-repo-section-docs-site", "skills-empty-docs-site",
                        "skill-row-release-notes", "skill-text-release-notes", "skill-name-release-notes", "skill-hint-release-notes", "skill-provider-release-notes-both",
                        "skill-description-release-notes", "skill-location-release-notes", "skill-actions-release-notes", "skill-conflict-review-login", "skill-issue-review-login",
                        "skill-fix-review-login", "skill-invalid-broken-skill", "skill-fix-broken-skill", "skills-collapse-repo", "skills-collapse-global", "skills-collapse-builtin"]:
            self.plugin_node(tree, test_id)
        types = {node["type"] for node in self.plugin_nodes(tree)} - {"#root", "#text"}
        self.assertEqual(types, {"Panel", "Stack", "Text", "Icon", "Label", "Button", "Spacer", "Divider", "Scroll", "Segmented", "TextField", "Menu", "PressArea", "Popover"},
                         "The page is atoms only, with no switch: Enable and Disable are in each skill's menu.")

        # The Skills button opens it: a plain Button atom with the sparkles icon.
        opener = self.plugin_node(tree, "open-skills-button")
        self.assertEqual((opener["type"], opener["events"], opener["props"].get("style")), ("Button", ["onPress"], None))
        self.assertEqual((opener["props"]["label"], opener["props"]["help"]), ("Skills", "Skills"))
        self.assertEqual((opener["children"][0]["type"], opener["children"][0]["props"]["name"]), ("Icon", "sparkles"))

        back = self.plugin_node(tree, "skills-back-button")
        self.assertEqual((back["props"]["shortcut"], back["props"]["label"], back["props"]["help"]), ("cancel", "Close", "Close (Esc)"), "Escape closes the modal while nothing is open.")
        circle = back["children"][0]
        self.assertEqual((circle["type"], circle["props"]["width"], circle["props"]["height"], circle["props"]["capsule"]), ("Stack", 22, 22, True))
        self.assertEqual(circle["children"][0]["props"]["name"], "xmark")
        page = self.plugin_node(tree, "skills-page")
        self.assertEqual((page["props"]["width"], page["props"]["cornerRadius"]), (336, 14), "The modal is a narrow 336-point column.")
        title = self.plugin_node(tree, "skills-title")
        self.assertEqual((title["type"], title["props"]["label"], title["props"]["summary"], title["children"][0]["props"]["name"]), ("Stack", "Skills, Rules & MCP", True, "sparkles"),
                         "The header's icon names the page; the tabs take the title's place.")
        kinds = self.plugin_node(tree, "skills-kind-picker")
        self.assertEqual(([option["label"] for option in kinds["props"]["options"]], kinds["props"]["selected"], kinds["props"]["disabled"]),
                         (["Skills", "Rules", "MCP"], "skills", False))
        # The sources are anchors that scroll one sectioned list, not tabs.
        anchors = self.plugin_node(tree, "skills-tab-picker")
        self.assertEqual((anchors["type"], anchors["props"]["group"], anchors["props"]["label"]), ("Stack", True, "Jump to"))
        self.assertEqual([(child["props"]["testID"], child["props"]["label"]) for child in anchors["children"]],
                         [("skills-anchor-repo", "Repo"), ("skills-anchor-global", "Global"), ("skills-anchor-builtin", "Built-in")])
        self.assertEqual([self.plugin_text(text) for text in anchors["children"][0]["children"][0]["children"]], ["Repo", "3"], "Each anchor shows its section's count.")
        scroll = self.plugin_node(tree, "skills-list")
        self.assertEqual([child["props"].get("testID") for child in scroll["children"]],
                         ["skills-group-repo", "skills-group-global", "skills-group-builtin", "skills-provider-timing"], "Every section in one list, then the hint.")
        self.assertEqual([child["props"].get("scrollID") for child in scroll["children"][:3]], ["repo", "global", "builtin"])
        self.assertEqual(self.plugin_node(tree, "skills-intro-repo")["props"]["help"].split(".")[0], "Skills in the task's repositories")
        group_ids = lambda tree, group: {node.get("props", {}).get("testID") for node in self.plugin_nodes(self.plugin_node(tree, f"skills-group-{group}"))}
        self.assertIn("skill-row-shared-notes", group_ids(tree, "global"), "Global skills show in the same list, under Global.")
        self.assertIn("skill-row-release-notes", group_ids(tree, "repo"))
        self.assertNotIn("skill-row-simplify", group_ids(tree, "builtin"), "Built-in starts collapsed.")
        collapse = self.plugin_node(tree, "skills-collapse-builtin")
        self.assertEqual((collapse["type"], collapse["props"]["label"], collapse["props"]["value"], collapse["props"]["help"]), ("Button", "Built-in", "Collapsed", "Show Built-in"))
        self.assertEqual(collapse["children"][0]["children"][0]["props"]["name"], "chevron.right")
        self.assertEqual(self.plugin_node(tree, "skills-collapse-repo")["props"]["value"], "Expanded")
        title_row = page["children"][0]
        self.assertEqual([child["type"] for child in title_row["children"]], ["Stack", "Segmented", "Spacer", "Button"],
                         "The header holds the icon, then the tabs where the title was, and the close button.")
        self.assertEqual(({node.get("props", {}).get("testID") for node in self.plugin_nodes(title_row)} - {None}), {"skills-title", "skills-kind-picker", "skills-back-button"})
        self.assertEqual([child["type"] for child in page["children"][1:3]], ["Divider", "Stack"], "A divider separates the header from the body.")
        self.assertNotIn(kinds, [node for child in page["children"][1:] for node in self.plugin_nodes(child)], "The tabs are only in the header.")
        expanded = self.assert_success(self.call_cli("plugin", "render", "--page", "SkillsPage", "--event", "skills-collapse-builtin:onPress")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(expanded["tree"], "js-last-action")), "Last: expand builtin")
        self.assertIn("skill-row-simplify", group_ids(expanded["tree"], "builtin"), "Its header expands Built-in.")
        self.assertEqual(self.plugin_node(expanded["tree"], "skills-collapse-builtin")["props"]["value"], "Expanded")
        claude_only = self.plugin_node(expanded["tree"], "skill-provider-simplify-claude")
        self.assertEqual((claude_only["type"], claude_only["props"]["asset"], claude_only["props"]["label"]), ("Icon", "ClaudeLogo", "Claude only"), "A Claude-only skill shows the Claude logo.")
        codex_only = self.plugin_node(expanded["tree"], "skill-provider-skill-creator-codex")
        self.assertEqual((codex_only["props"]["asset"], codex_only["props"]["label"]), ("CodexLogo", "Codex only"), "A Codex-only skill shows the Codex logo.")
        collapsed_again = self.assert_success(self.call_cli("plugin", "render", "--page", "SkillsPage", "--event", "skills-collapse-repo:onPress")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(collapsed_again["tree"], "js-last-action")), "Last: collapse repo")
        self.assertNotIn("skill-row-release-notes", group_ids(collapsed_again["tree"], "repo"), "Any group collapses from its header.")
        anchored = self.assert_success(self.call_cli("plugin", "render", "--page", "SkillsPage", "--event", "skills-anchor-builtin:onPress")[0])
        self.assertIn("skill-row-simplify", group_ids(anchored["tree"], "builtin"), "Jumping to a collapsed group expands it.")
        search = self.plugin_node(tree, "skills-search")
        self.assertEqual((search["props"]["text"], search["props"]["placeholder"], search["props"]["style"]), ("", "Search skills", "plain"))
        search_box = next(node for node in self.plugin_nodes(tree) if search in node.get("children", []))
        self.assertEqual((search_box["props"].get("width"), search_box["props"]["fillWidth"]), (None, True), "The search fills its row.")
        search_row = next(node for node in self.plugin_nodes(tree) if search_box in node.get("children", []))
        self.assertEqual([child["props"].get("testID") for child in search_row["children"]], [None, "new-skill-button"], "New Skill sits beside the search, and nothing else.")
        self.assertEqual(search_row["props"]["paddingX"], 20)
        anchors_row = next(node for node in self.plugin_nodes(tree) if anchors in node.get("children", []))
        self.assertEqual(([child["type"] for child in anchors_row["children"]], anchors_row["props"]["paddingY"]), (["Stack", "Spacer"], 12), "The anchors sit on their own row under the search.")
        new_skill = self.plugin_node(tree, "new-skill-button")
        self.assertEqual((new_skill["props"]["style"], new_skill["props"]["controlSize"], new_skill["children"][0]["props"]["text"]), ("bordered", "small", "New Skill"))
        self.assertTrue(self.plugin_text(self.plugin_node(tree, "skills-provider-timing")).startswith("Hover a skill for its details, click it to open it, or press and hold one"))
        self.assertEqual((scroll["props"].get("lazy"), scroll["props"]["inset"], scroll["props"]["spacing"], scroll["props"]["scrollRequest"]), (None, 20, 18, 0))
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "skills-empty-docs-site")), "No skills in docs-site.")

        row = self.plugin_node(tree, "skill-row-release-notes")
        self.assertEqual((row["type"], row["props"].get("fill"), row["props"]["paddingY"]), ("Stack", None, 6), "An unselected row is a plain compact line.")
        self.assertEqual([child["type"] for child in row["children"]], ["PressArea", "Menu"], "The skill's text, then only its menu.")
        self.assertIsNone(row["props"].get("opacity"), "An enabled row is not dimmed.")
        text = self.plugin_node(tree, "skill-text-release-notes")
        self.assertEqual((text["props"]["pointer"], text["props"]["hint"]), (True, self.plugin_text(self.plugin_node(tree, "skill-description-release-notes"))),
                         "A skill with a folder opens on click, and its text carries the description for accessibility.")
        self.assertEqual(text["props"]["label"], "release-notes", "An enabled skill's text reads as its name.")
        self.assertEqual([child["type"] for child in text["children"][0]["children"]], ["Icon", "Text", "Spacer"], "The row shows one icon for its agents, then the skill's name.")
        self.assertEqual(text["children"][0]["children"][0]["props"]["testID"], "skill-provider-release-notes-both", "The provider icon leads the name on the row.")
        popover = next(node for node in self.plugin_nodes(tree) if node["type"] == "Popover" and row in node["children"])
        self.assertEqual((popover["props"]["hover"], popover["props"]["isPresented"], popover["props"]["arrowEdge"], popover["props"]["width"]), (True, False, "leading", 200),
                         "The details show in a hint left of the row while the pointer rests on it.")
        hint_ids = {node.get("props", {}).get("testID") for node in self.plugin_nodes(popover["children"][1])}
        for detail in ["skill-description-release-notes", "skill-location-release-notes"]:
            self.assertIn(detail, hint_ids, f"{detail} is in the hint, not the row.")
        self.assertFalse(any(str(each).startswith("skill-provider-") for each in hint_ids), "The provider icon is on the row, not in the hint.")
        card = next(node for node in self.plugin_nodes(tree) if popover in node.get("children", []))
        self.assertEqual((card["props"]["fill"], card["props"]["cornerRadius"], card["props"]["stroke"]), ("panel", 10, "primary"), "A section's rows share one card.")
        self.assertIn("Divider", [child["type"] for child in card["children"]], "A hairline separates the rows.")
        both = self.plugin_node(tree, "skill-provider-release-notes-both")
        self.assertEqual((both["props"]["name"], both["props"]["color"], both["props"]["label"], both["props"]["width"], both["props"]["height"]),
                         ("checkmark.circle.fill", "green", "Claude and Codex", 12, 12), "A skill both agents use shows a small green check.")
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "skill-location-release-notes")), ".agents/skills")
        actions = self.plugin_node(tree, "skill-actions-release-notes")
        self.assertEqual((actions["props"]["icon"], actions["props"]["width"], actions["props"]["height"], actions["props"]["label"]),
                         ("ellipsis", 22, 22, "Actions for release-notes"))
        self.assertEqual([[item["testID"] for item in group] for group in actions["props"]["items"]], [
            ["skill-use-release-notes", "skill-toggle-release-notes"],
            ["skill-edit-release-notes", "skill-reveal-release-notes"],
            ["skill-move-global-release-notes", "skill-move-repo-release-notes-docs-site"],
            ["skill-link-release-notes"], ["skill-delete-release-notes"]])
        self.assertEqual(actions["props"]["items"][4][0]["destructive"], True)
        use, toggle = actions["props"]["items"][0]
        self.assertEqual((use["title"], bool(use.get("disabled")), use["help"]), ("Use", False, "Insert /release-notes into the message"), "Use is the menu's first item.")
        self.assertEqual((toggle["title"], toggle["help"]), ("Disable", "Turn the skill off in Playhouse sessions"))
        conflict = self.plugin_node(tree, "skill-row-review-login")
        self.assertEqual([child["type"] for child in conflict["children"]], ["PressArea", "Button", "Menu"],
                         "A conflicting skill offers Fix before its menu.")
        fix = self.plugin_node(tree, "skill-fix-review-login")
        self.assertEqual((fix["props"]["controlSize"], fix["children"][0]["props"]["text"]), ("small", "Fix"))
        flag = self.plugin_node(tree, "skill-conflict-review-login")
        self.assertEqual((flag["type"], flag["props"]["color"], flag["props"]["label"]), ("Icon", "orange", "Conflict"), "A conflict is an icon beside the name.")
        conflict_ids = [child["props"].get("testID") for child in self.plugin_node(tree, "skill-text-review-login")["children"][0]["children"]]
        self.assertEqual(conflict_ids[:3], ["skill-provider-review-login-both", "skill-name-review-login", "skill-conflict-review-login"],
                         "The provider icon leads the name and the warning follows it.")
        self.assertEqual(self.plugin_node(tree, "skill-invalid-broken-skill")["props"]["color"], "red")
        self.assertEqual(self.plugin_node(tree, "skill-actions-broken-skill")["props"]["items"][0][0]["disabled"], True, "No provider can use an invalid skill.")
        test_ids = {node.get("props", {}).get("testID") for node in self.plugin_nodes(tree)}
        self.assertFalse(any(str(each).startswith("skill-provider-broken-skill") for each in test_ids), "A skill no agent can use shows no provider icon.")
        self.assertNotIn("skill-select-release-notes", test_ids, "Rows show no checkbox until selecting.")

        switched = self.assert_success(self.call_cli(
            "plugin", "render", "--page", "SkillsPage", "--event", "skills-anchor-global:onPress",
            "--event", "skill-actions-shared-notes:onMenu:toggle", "--event", "skill-actions-shared-notes:onMenu:use")[0])
        self.assertEqual(switched["errors"], [])
        tree = switched["tree"]
        last_action = self.plugin_node(tree, "js-last-action")
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "js-last-action")), "Last: use shared-notes")
        jumped = self.assert_success(self.call_cli("plugin", "render", "--page", "SkillsPage", "--event", "skills-anchor-global:onPress")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(jumped["tree"], "js-last-action")), "Last: jump global", "The Global anchor ran its handler.")
        jumped_scroll = self.plugin_node(jumped["tree"], "skills-list")["props"]
        self.assertEqual((jumped_scroll["scrollTo"], jumped_scroll["scrollRequest"]), ("global", 1), "The anchor asks the list to scroll to Global.")
        self.assertIn("skill-row-release-notes", group_ids(jumped["tree"], "repo"), "Jumping keeps every section in the list.")
        again = self.assert_success(self.call_cli(
            "plugin", "render", "--page", "SkillsPage", "--event", "skills-anchor-global:onPress", "--event", "skills-anchor-global:onPress")[0])
        self.assertEqual(self.plugin_node(again["tree"], "skills-list")["props"]["scrollRequest"], 2, "Each press asks again, so a second jump scrolls back.")
        self.plugin_node(tree, "skill-linked-shared-notes")
        def leading(tree, name):
            return [(item["title"], bool(item.get("disabled"))) for item in self.plugin_node(tree, f"skill-actions-{name}")["props"]["items"][0]]
        self.assertEqual(leading(tree, "quiet-skill"), [("Use", True), ("Enable", False)], "A skill that is off can't be used, and its menu offers Enable.")
        self.assertEqual(self.plugin_node(tree, "skill-row-quiet-skill")["props"]["opacity"], 0.45, "A skill that is off is grayed out.")
        self.assertEqual(self.plugin_node(tree, "skill-text-quiet-skill")["props"]["label"], "quiet-skill, off", "A skill that is off says so to accessibility.")
        self.assertEqual(self.plugin_node(tree, "skill-text-quiet-skill")["props"]["pointer"], True, "A grayed-out skill still opens on click.")
        self.assertEqual(leading(tree, "shared-notes"), [("Use", True), ("Enable", False)], "Disable turned the skill off and disabled Use.")
        self.assertEqual(self.plugin_node(tree, "skill-row-shared-notes")["props"]["opacity"], 0.45)
        self.assertEqual([[item["id"] for item in group] for group in self.plugin_node(tree, "skill-actions-shared-notes")["props"]["items"]][3], ["unlink"],
                         "A linked skill offers Remove Outside Link.")
        menu_commits = [commit for commit in switched["commits"] if commit["step"] == "skill-actions-shared-notes:onMenu"]
        self.assertEqual(len(menu_commits), 2, "Disable and Use each commit once.")
        toggled = menu_commits[0]
        self.assertNotIn("create", toggled["ops"], "Turning a skill off updates its row in place.")
        used = menu_commits[1]
        self.assertEqual((used["ops"], used["touchedNodes"]), (["text"], [last_action["children"][1]["id"]]), "Use runs its handler without re-rendering any row.")
        self.assertEqual(self.plugin_text(last_action), "Last: use shared-notes")

        toggled_off = self.assert_success(self.call_cli("plugin", "render", "--page", "SkillsPage", "--event", "skill-actions-release-notes:onMenu:toggle")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(toggled_off["tree"], "js-last-action")), "Last: toggle release-notes off")
        self.assertEqual(leading(toggled_off["tree"], "release-notes"), [("Use", True), ("Enable", False)])
        toggled_on = self.assert_success(self.call_cli("plugin", "render", "--page", "SkillsPage", "--event", "skill-actions-quiet-skill:onMenu:toggle")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(toggled_on["tree"], "js-last-action")), "Last: toggle quiet-skill on")
        self.assertEqual(leading(toggled_on["tree"], "quiet-skill"), [("Use", False), ("Disable", False)], "Enable turns it back on.")
        self.assertIsNone(self.plugin_node(toggled_on["tree"], "skill-row-quiet-skill")["props"].get("opacity"))

        opened = self.assert_success(self.call_cli("plugin", "render", "--page", "SkillsPage", "--event", "skill-text-release-notes:onPress")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(opened["tree"], "js-last-action")), "Last: open release-notes")

        selecting = self.assert_success(self.call_cli(
            "plugin", "render", "--page", "SkillsPage", "--event", "skill-text-release-notes:onLongPress")[0])
        tree = selecting["tree"]
        test_ids = {node.get("props", {}).get("testID") for node in self.plugin_nodes(tree)}
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "js-last-action")), "Last: select release-notes")
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "skills-selection-count")), "1 selected")
        checked = self.plugin_node(tree, "skill-select-release-notes")
        self.assertEqual((checked["props"]["name"], checked["props"]["label"], checked["props"]["color"]), ("checkmark.circle.fill", "Selected", "accent"))
        self.assertEqual(self.plugin_node(tree, "skill-select-review-login")["props"]["label"], "Not selected")
        selected_row = self.plugin_node(tree, "skill-row-release-notes")["props"]
        self.assertEqual((selected_row["fill"], selected_row["fillOpacity"]), ("accent", 0.12), "A selected row is highlighted with the accent.")
        for hidden in ["skill-actions-release-notes", "skill-fix-review-login", "skills-search", "new-skill-button"]:
            self.assertNotIn(hidden, test_ids, f"Selecting hides {hidden}.")
        self.assertEqual(self.plugin_node(tree, "skills-kind-picker")["props"]["disabled"], True, "The kind picker is locked while selecting.")
        self.assertNotIn("shortcut", self.plugin_node(tree, "skills-back-button")["props"], "Escape ends selecting instead of going back.")
        self.assertEqual(self.plugin_node(tree, "skills-selection-done")["props"]["shortcut"], "cancel")
        selecting_title_row = self.plugin_node(tree, "skills-page")["children"][0]
        self.assertNotIn("skills-selection-done", {node.get("props", {}).get("testID") for node in self.plugin_nodes(selecting_title_row)},
                         "The selection actions sit in the body, not in the title row.")
        selecting_anchors = self.plugin_node(tree, "skills-tab-picker")
        selecting_rows = next(node for node in self.plugin_nodes(tree) if any(selecting_anchors in child.get("children", []) for child in node.get("children", [])))["children"]
        anchors_index = next(index for index, child in enumerate(selecting_rows) if selecting_anchors in child.get("children", []))
        search_row_ids = {node.get("props", {}).get("testID") for node in self.plugin_nodes(selecting_rows[anchors_index - 1])}
        self.assertTrue({"skills-selection-count", "skills-selection-done", "skills-delete-selected"} <= search_row_ids, "The selection's actions take the search's row, just above the anchors.")
        self.assertNotIn("skills-selection-done", {node.get("props", {}).get("testID") for node in self.plugin_nodes(selecting_rows[anchors_index])})
        self.assertEqual(self.plugin_node(tree, "skills-fix-selected")["props"]["disabled"], True, "Nothing selected is broken, so nothing can be fixed.")
        self.assertIn("Fix", [node.get("props", {}).get("text") for node in self.plugin_nodes(self.plugin_node(tree, "skills-fix-selected"))],
                      "The selection's fix button reads Fix, short enough for the narrow modal.")
        delete = self.plugin_node(tree, "skills-delete-selected")["props"]
        self.assertEqual((delete["disabled"], delete["destructive"]), (False, True))
        self.assertTrue(self.plugin_text(self.plugin_node(tree, "skills-provider-timing")).startswith("Click skills to select them."))

        built_in = self.assert_success(self.call_cli(
            "plugin", "render", "--page", "SkillsPage", "--event", "skills-collapse-builtin:onPress", "--event", "skill-text-release-notes:onLongPress")[0])
        test_ids = {node.get("props", {}).get("testID") for node in self.plugin_nodes(built_in["tree"])}
        self.assertIn("skill-row-simplify", test_ids)
        self.assertNotIn("skill-select-simplify", test_ids, "A built-in skill shows no checkbox.")

        added = self.assert_success(self.call_cli(
            "plugin", "render", "--page", "SkillsPage", "--event", "skill-text-release-notes:onLongPress",
            "--event", "skill-text-review-login:onPress", "--event", "skills-fix-selected:onPress", "--event", "skills-selection-done:onPress")[0])
        commits = {commit["step"]: commit for commit in added["commits"]}
        fixed = self.assert_success(self.call_cli(
            "plugin", "render", "--page", "SkillsPage", "--event", "skill-text-release-notes:onLongPress",
            "--event", "skill-text-review-login:onPress", "--event", "skills-fix-selected:onPress")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(fixed["tree"], "js-last-action")), "Last: fix 2 selected", "Fix with Agent ran with the selection.")
        self.assertEqual(self.plugin_text(self.plugin_node(added["tree"], "js-last-action")), "Last: done selecting")
        test_ids = {node.get("props", {}).get("testID") for node in self.plugin_nodes(added["tree"])}
        self.assertNotIn("skills-selection-count", test_ids, "Done ends selecting.")
        self.assertIn("skill-actions-release-notes", test_ids, "Rows show their controls again.")
        two = self.assert_success(self.call_cli(
            "plugin", "render", "--page", "SkillsPage", "--event", "skill-text-release-notes:onLongPress", "--event", "skill-text-review-login:onPress")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(two["tree"], "skills-selection-count")), "2 selected", "A click on another row adds it.")
        self.assertEqual(self.plugin_node(two["tree"], "skills-fix-selected")["props"]["disabled"], False, "A selected conflict can be fixed.")
        self.assertIn("skills-fix-selected:onPress", commits)

        menu = self.assert_success(self.call_cli(
            "plugin", "render", "--page", "SkillsPage", "--event", "skill-actions-release-notes:onMenu:edit",
            "--event", "skills-search:onChange:release")[0])
        tree = menu["tree"]
        self.assertEqual(self.plugin_node(tree, "skills-search")["props"]["text"], "release", "onChange received the search text.")
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "js-last-action")), "Last: search release")
        menu_only = self.assert_success(self.call_cli("plugin", "render", "--page", "SkillsPage", "--event", "skill-actions-release-notes:onMenu:edit")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(menu_only["tree"], "js-last-action")), "Last: menu release-notes edit")

        rules = self.assert_success(self.call_cli("plugin", "render", "--page", "SkillsPage", "--event", "skills-kind-picker:onChange:rules")[0])
        test_ids = {node.get("props", {}).get("testID") for node in self.plugin_nodes(rules["tree"])}
        self.assertEqual(self.plugin_node(rules["tree"], "skills-kind-picker")["props"]["selected"], "rules")
        self.assertEqual(self.plugin_text(self.plugin_node(rules["tree"], "js-last-action")), "Last: kind rules")
        for hidden in ["skills-tab-picker", "skills-search", "new-skill-button", "skills-list"]:
            self.assertNotIn(hidden, test_ids, f"Rules hides {hidden}.")

        closed = self.assert_success(self.call_cli("plugin", "render", "--page", "SkillsPage", "--event", "skills-back-button:onPress")[0])
        test_ids = {node.get("props", {}).get("testID") for node in self.plugin_nodes(closed["tree"])}
        self.assertNotIn("skills-page", test_ids, "Close closed the modal.")
        self.assertEqual(self.plugin_text(self.plugin_node(closed["tree"], "js-last-action")), "Last: back")
        reopened = self.assert_success(self.call_cli(
            "plugin", "render", "--page", "SkillsPage", "--event", "skills-back-button:onPress", "--event", "open-skills-button:onPress")[0])
        self.plugin_node(reopened["tree"], "skill-row-release-notes")
        self.assertEqual(self.plugin_text(self.plugin_node(reopened["tree"], "js-last-action")), "Last: open", "The Skills button opened it again.")
        self.assert_failure(self.call_cli("plugin", "render", "--page", "SkillsPage", "--event", "skills-search:onPress", expected_status=2)[0], "invalid_argument")
    # case-contract: test_plugin_repository_chips_renders_from_atoms_like_native | The Plugin Catalog's Repository Chips page shows the task header's repository chips and the Add repository picker their + button opens, composed in JavaScript from atoms beside the native SwiftUI chips and picker the task header uses, built from the same atoms and sample models. Both show a capsule chip per repository (the branch icon and its name) carrying a 20-point circular remove badge on its top trailing corner, the 28-point circular + button labelled Add repository, and the picker: Suggestions from the suggestion folder with its Change… button, the search with the saved repositories' placeholder, the Recent header and one row per recent repository (its name and path) with the first highlighted, in a 280-point list that stops growing at 180 points and scrolls, each at the same size in both, and the JavaScript tree uses only atoms (Overlay, Panel, Stack, Text, Icon, Button, Spacer, TextField, Scroll) with the task header's identifiers. Typing in the JavaScript search runs onChange (Last: search pla); Down and Up run onArrow (Last: down, then Last: up) and move the highlight while the native picker's highlight stays put; Return runs onSubmit with the highlighted row (Last: submit wix-one-app) and closes the picker; the + button shows it again (Last: open picker) and hides it (Last: close picker); clicking a row runs its onPress (Last: select Viband); Change… runs its handler (Last: choose folder); clicking a chip runs its onPress (Last: edit infragod) without re-rendering the other chip; and its remove badge removes it (Last: remove infragod) while the native chips keep theirs. A chip raises no onChange, so sending it one is refused as invalid_argument.
    def test_plugin_repository_chips_renders_from_atoms_like_native(self):
        rendered = self.assert_success(self.call_cli("plugin", "render", "--page", "RepositoryChips")[0])
        self.assertEqual(rendered["errors"], [])
        tree = rendered["tree"]
        # The same identifiers the task header's native chips and picker give their atoms.
        for test_id in ["conversation-repository-badge-infragod", "remove-conversation-repository-infragod", "conversation-repository-badge-Playhouse",
                        "remove-conversation-repository-Playhouse", "add-conversation-repository-button", "conversation-repository-picker",
                        "conversation-repository-suggestion-parent", "choose-repository-suggestion-parent-button", "conversation-repository-search",
                        "conversation-repository-recent-header", "conversation-repository-list", "conversation-repository-recent-mre",
                        "conversation-repository-recent-wix-one-app", "conversation-repository-recent-zmk-config"]:
            self.plugin_node(tree, test_id)
        types = {node["type"] for node in self.plugin_nodes(tree)} - {"#root", "#text"}
        self.assertEqual(types, {"Overlay", "Panel", "Stack", "Text", "Icon", "Button", "Spacer", "TextField", "Scroll"}, "The chips and the picker are atoms only.")

        # A chip: a capsule button with the branch icon and the name, its remove badge over its top trailing corner.
        chip = self.plugin_node(tree, "conversation-repository-badge-infragod")
        overlay = next(node for node in self.plugin_nodes(tree) if node["type"] == "Overlay" and chip in node["children"])
        self.assertEqual((overlay["props"]["align"], overlay["props"]["offsetX"], overlay["props"]["offsetY"]), ("topTrailing", 6, -6))
        self.assertEqual([child["props"].get("testID") for child in overlay["children"]],
                         ["conversation-repository-badge-infragod", "remove-conversation-repository-infragod"], "The chip, then its badge over it.")
        self.assertEqual((chip["type"], chip["events"], chip["props"]["help"], chip["props"]["disabled"]),
                         ("Button", ["onPress"], "Edit repository settings for infragod", False))
        capsule = chip["children"][0]
        self.assertEqual((capsule["type"], capsule["props"]["capsule"], capsule["props"]["fillOpacity"], capsule["props"]["stroke"], capsule["props"]["strokeOpacity"]),
                         ("Panel", True, 0.08, "primary", 0.14))
        label = capsule["children"][0]["children"]
        self.assertEqual((label[0]["props"]["name"], label[0]["props"]["color"]), ("arrow.triangle.branch", "#007ACC"), "The workspace accent.")
        self.assertEqual((self.plugin_text(label[1]), label[1]["props"]["size"], label[1]["props"]["weight"]), ("infragod", 13, "semibold"))
        remove = self.plugin_node(tree, "remove-conversation-repository-infragod")
        self.assertEqual((remove["props"]["label"], remove["props"]["help"]), ("Remove infragod", "Remove infragod from this task"))
        badge = remove["children"][0]
        self.assertEqual((badge["props"]["capsule"], badge["props"]["width"], badge["props"]["height"], badge["props"]["fill"]), (True, 20, 20, "panel"))
        self.assertEqual(badge["children"][0]["props"]["name"], "xmark")
        add = self.plugin_node(tree, "add-conversation-repository-button")
        self.assertEqual((add["props"]["label"], add["props"]["help"], add["props"]["disabled"]), ("Add repository", "Add a repository", False))
        circle = add["children"][0]
        self.assertEqual((circle["props"]["capsule"], circle["props"]["width"], circle["props"]["height"], circle["children"][0]["props"]["name"]), (True, 28, 28, "plus"))

        # The picker: where suggestions come from, the search, then the recent repositories.
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "conversation-repository-suggestion-parent")), "Suggestions from /Users/demo/git")
        change = self.plugin_node(tree, "choose-repository-suggestion-parent-button")
        self.assertEqual((change["props"]["style"], change["props"]["disabled"], self.plugin_text(change["children"][0])), ("automatic", False, "Change…"))
        search = self.plugin_node(tree, "conversation-repository-search")
        self.assertEqual((search["props"]["text"], search["props"]["placeholder"], sorted(search["events"])),
                         ("", "infragod, Playhouse ↵", ["onArrow", "onChange", "onSubmit"]))
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "conversation-repository-recent-header")), "Recent")
        scroll = self.plugin_node(tree, "conversation-repository-list")
        self.assertEqual((scroll["props"]["width"], scroll["props"]["height"], scroll["props"]["lazy"]), (280, 180, True), "Five rows would be 210 points; the list stops at 180.")
        zmk = self.plugin_node(tree, "conversation-repository-recent-zmk-config")
        self.assertTrue(any(row["type"] == "Overlay" and zmk in row["children"] for row in scroll["children"]), "The rows past 180 points stay in the scrolling list.")
        self.assertEqual(len(scroll["children"]), 5)
        def row_fill(tree, name):
            return self.plugin_node(tree, f"conversation-repository-recent-{name}")["children"][0]["props"]["fillOpacity"]
        first = self.plugin_node(tree, "conversation-repository-recent-mre")
        self.assertEqual(first["props"]["help"], "Add mre alongside the selected repositories")
        row = next(node for node in scroll["children"] if first in node["children"])
        self.assertEqual((row["props"]["align"], row["props"]["revealOnHover"]), ("trailing", True), "A row's buttons show only while hovering it.")
        hint = {"replace": "Replace the selected repositories with mre", "add": "Add mre alongside the selected repositories"}
        icon = {"replace": "repeat", "add": "plus"}
        for action in ["replace", "add"]:
            button = self.plugin_node(tree, f"conversation-repository-recent-mre-{action}")
            self.assertEqual((button["props"]["help"], button["children"][0]["props"]["name"]), (hint[action], icon[action]))
        self.assertEqual([self.plugin_text(text) for text in self.plugin_nodes(first) if text["type"] == "Text"], ["mre", "/Users/demo/git/mre"])
        reserved = [node for node in self.plugin_nodes(first) if node["type"] == "Spacer"]
        self.assertEqual([node["props"]["minLength"] for node in reserved], [64], "The row text leaves room for the hover buttons.")
        self.assertEqual((row_fill(tree, "mre"), row_fill(tree, "wix-one-app")), (0.16, 0), "The first row is highlighted.")

        searched = self.assert_success(self.call_cli("plugin", "render", "--page", "RepositoryChips", "--event", "conversation-repository-search:onChange:pla")[0])
        self.assertEqual(self.plugin_node(searched["tree"], "conversation-repository-search")["props"]["text"], "pla", "onChange received the search text.")
        self.assertEqual(self.plugin_text(self.plugin_node(searched["tree"], "js-last-action")), "Last: search pla")

        moved = self.assert_success(self.call_cli(
            "plugin", "render", "--page", "RepositoryChips", "--event", "conversation-repository-search:onArrow:down",
            "--event", "conversation-repository-search:onArrow:down", "--event", "conversation-repository-search:onArrow:up")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(moved["tree"], "js-last-action")), "Last: up")
        self.assertEqual((row_fill(moved["tree"], "mre"), row_fill(moved["tree"], "wix-one-app"), row_fill(moved["tree"], "Viband")), (0, 0.16, 0),
                         "Down, Down, Up highlights the second row.")
        down = next(commit for commit in moved["commits"] if commit["step"] == "conversation-repository-search:onArrow")
        self.assertEqual(sorted(down["ops"]), ["text", "update", "update"], "Moving the highlight updates only two rows' panels and the readout.")

        submitted = self.assert_success(self.call_cli(
            "plugin", "render", "--page", "RepositoryChips", "--event", "conversation-repository-search:onArrow:down",
            "--event", "conversation-repository-search:onSubmit")[0])
        test_ids = {node.get("props", {}).get("testID") for node in self.plugin_nodes(submitted["tree"])}
        self.assertEqual(self.plugin_text(self.plugin_node(submitted["tree"], "js-last-action")), "Last: submit wix-one-app", "Return adds the highlighted row.")
        self.assertNotIn("conversation-repository-picker", test_ids, "Adding closes the picker.")
        reopened = self.assert_success(self.call_cli(
            "plugin", "render", "--page", "RepositoryChips", "--event", "conversation-repository-search:onSubmit",
            "--event", "add-conversation-repository-button:onPress")[0])
        self.plugin_node(reopened["tree"], "conversation-repository-picker")
        self.assertEqual(self.plugin_text(self.plugin_node(reopened["tree"], "js-last-action")), "Last: open picker", "The + button shows the picker again.")
        hidden = self.assert_success(self.call_cli("plugin", "render", "--page", "RepositoryChips", "--event", "add-conversation-repository-button:onPress")[0])
        self.assertNotIn("conversation-repository-picker", {node.get("props", {}).get("testID") for node in self.plugin_nodes(hidden["tree"])})
        self.assertEqual(self.plugin_text(self.plugin_node(hidden["tree"], "js-last-action")), "Last: close picker")

        selected = self.assert_success(self.call_cli("plugin", "render", "--page", "RepositoryChips", "--event", "conversation-repository-recent-Viband:onPress")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(selected["tree"], "js-last-action")), "Last: select Viband")
        chosen = self.assert_success(self.call_cli("plugin", "render", "--page", "RepositoryChips", "--event", "choose-repository-suggestion-parent-button:onPress")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(chosen["tree"], "js-last-action")), "Last: choose folder")

        edited = self.assert_success(self.call_cli("plugin", "render", "--page", "RepositoryChips", "--event", "conversation-repository-badge-infragod:onPress")[0])
        last_action = self.plugin_node(edited["tree"], "js-last-action")
        self.assertEqual(self.plugin_text(last_action), "Last: edit infragod")
        self.assertEqual((edited["commits"][-1]["ops"], edited["commits"][-1]["touchedNodes"]), (["text"], [last_action["children"][1]["id"]]),
                         "Opening a chip's settings re-renders no chip.")
        removed = self.assert_success(self.call_cli("plugin", "render", "--page", "RepositoryChips", "--event", "remove-conversation-repository-infragod:onPress")[0])
        test_ids = {node.get("props", {}).get("testID") for node in self.plugin_nodes(removed["tree"])}
        self.assertNotIn("conversation-repository-badge-infragod", test_ids, "The remove badge removed its chip.")
        self.assertIn("conversation-repository-badge-Playhouse", test_ids)
        self.assertEqual(self.plugin_text(self.plugin_node(removed["tree"], "js-last-action")), "Last: remove infragod")
        self.assert_failure(self.call_cli("plugin", "render", "--page", "RepositoryChips", "--event", "conversation-repository-badge-infragod:onChange", expected_status=2)[0],
                            "invalid_argument")
    # case-contract: test_plugin_composer_renders_from_atoms_like_native | The Plugin Catalog's Composer page shows the conversation composer's box composed in JavaScript from atoms above the native SwiftUI box the conversation uses, built from the same atoms and sample data, each as wide as the page's 764-point column and with the composer's identifiers (the native side prefixed native-), and the JavaScript tree uses only atoms (Panel, Stack, Editor, Button, Icon, Menu, Spacer, Popover, Text, Divider, StepSlider). Both show the editor with its message placeholder, the Skills button (the plain Button atom with the sparkles icon, labelled Skills), the plus mode menu, the Claude provider menu, the Sonnet 5.5 model button with its Medium effort, the schedule button and a send button that is disabled while the draft is empty, each at the same size in both. Typing in the JavaScript editor runs onChange (Last: edit) and enables Send, Send runs its handler (Last: send followed by the draft) and clears the editor, and the native editor keeps its own text. The plus menu runs onMenu with the item's id: Plan mode (Last: mode mode:plan) labels the menu Conversation mode: Plan mode and shows the Start Implementing button, and Goal (Last: mode goal) labels the menu Goal and shows the goal placeholder; choosing Codex in the provider menu runs onMenu (Last: provider codex) and shows its title. The model button runs onPress and opens its popover (Last: model picker open) listing the models with the current one checked and the effort slider; choosing a model runs onPress (Last: model claude-opus-5-5), checks it instead and changes the button's model name, moving the effort slider to its last step runs onChange with that effort's value (Last: effort xhigh) and changes the button's effort to Extra High, and Escape runs onDismiss (Last: model picker closed). The schedule button opens its popover (Last: schedule open), whose content stays native. The conversation's own composer is this box: with Debug ▸ Highlight Native Atoms on, a task's composer shows its editor as an Editor atom, its model button in a Popover atom and its mode and provider menus as Menu atoms, with every identifier its controls had unchanged. A Popover shows the children after its first (its anchor) in the popover, so one with only an anchor is valid.
    def test_plugin_composer_renders_from_atoms_like_native(self):
        rendered = self.assert_success(self.call_cli("plugin", "render", "--page", "Composer")[0])
        self.assertEqual(rendered["errors"], [])
        tree = rendered["tree"]
        # The same identifiers the conversation's composer gives its controls.
        for test_id in ["message-composer-scroll-view", "open-skills-button", "conversation-mode-menu", "conversation-provider-menu", "model-picker-menu",
                        "model-picker-popover", "schedule-task-button", "schedule-popover", "send-message-button", "js-last-action"]:
            self.plugin_node(tree, test_id)
        types = {node["type"] for node in self.plugin_nodes(tree)} - {"#root", "#text"}
        self.assertEqual(types, {"Panel", "Stack", "Editor", "Button", "Icon", "Menu", "Spacer", "Popover", "Text", "StepSlider", "Divider"}, "The box is atoms only.")

        self.assertEqual(self.plugin_node(tree, "message-composer-scroll-view")["props"]["inputTestID"], "message-composer")
        column = [node for node in self.plugin_nodes(tree) if node["type"] == "Stack" and node.get("props", {}).get("width") == 764]
        self.assertEqual(len(column), 1, "The box sits in the page's 764-point column.")
        editor = self.plugin_node(tree, "message-composer-scroll-view")
        self.assertEqual((editor["type"], editor["events"], editor["props"]["placeholder"], editor["props"]["placeholderTestID"], editor["props"]["text"]),
                         ("Editor", ["onChange", "onFocusChange", "onSteerSubmit", "onSubmit"], "Message…", "composer-placeholder", ""))
        opener = self.plugin_node(tree, "open-skills-button")
        self.assertEqual((opener["type"], opener["events"], opener["props"].get("style"), opener["props"]["label"], opener["props"]["help"]),
                         ("Button", ["onPress"], None, "Skills", "Skills"))
        self.assertEqual((opener["children"][0]["type"], opener["children"][0]["props"]["name"]), ("Icon", "sparkles"))
        mode = self.plugin_node(tree, "conversation-mode-menu")["props"]
        self.assertEqual((mode["icon"], mode["color"], mode["label"], [item["id"] for item in mode["items"][0]], [item["checked"] for item in mode["items"][0]]),
                         ("plus", "secondary", "Conversation mode: Code mode", ["goal", "mode:default", "mode:plan"], [False, True, False]))
        provider = self.plugin_node(tree, "conversation-provider-menu")["props"]
        self.assertEqual((provider["text"], provider["value"], provider["indicator"], provider["disabled"]), ("Claude", "claude", True, False))
        model = self.plugin_node(tree, "model-picker-menu")["props"]
        self.assertEqual((model["label"], model["value"]), ("Model: Sonnet 5.5, effort: Medium", "Sonnet 5.5"))
        popover = self.plugin_node(tree, "model-picker-popover")
        self.assertEqual((popover["type"], popover["events"], popover["props"]["isPresented"], popover["props"]["width"], len(popover["children"])), ("Popover", ["onDismiss"], False, 320, 2),
                         "A popover is its anchor and its content, closed at first.")
        send = self.plugin_node(tree, "send-message-button")
        self.assertEqual((send["props"]["disabled"], send["props"]["label"]), (True, "Send message"), "Send is disabled while the draft is empty.")
        self.assertNotIn("start-implementing-button", {node.get("props", {}).get("testID") for node in self.plugin_nodes(tree)}, "Start Implementing shows in plan mode only.")

        # Typing runs onChange and enables Send; Send runs its handler and clears the editor.
        typed = self.assert_success(self.call_cli("plugin", "render", "--page", "Composer", "--event", "message-composer-scroll-view:onChange:hello")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(typed["tree"], "js-last-action")), "Last: edit")
        self.assertEqual(self.plugin_node(typed["tree"], "message-composer-scroll-view")["props"]["text"], "hello")
        self.assertFalse(self.plugin_node(typed["tree"], "send-message-button")["props"]["disabled"], "A draft enables Send.")
        sent = self.assert_success(self.call_cli(
            "plugin", "render", "--page", "Composer", "--event", "message-composer-scroll-view:onChange:hello", "--event", "send-message-button:onPress")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(sent["tree"], "js-last-action")), "Last: send hello")
        self.assertEqual(self.plugin_node(sent["tree"], "message-composer-scroll-view")["props"]["text"], "", "Send clears the editor.")
        submitted = self.assert_success(self.call_cli(
            "plugin", "render", "--page", "Composer", "--event", "message-composer-scroll-view:onChange:again", "--event", "message-composer-scroll-view:onSubmit")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(submitted["tree"], "js-last-action")), "Last: submit again", "Return runs onSubmit.")
        steered = self.assert_success(self.call_cli("plugin", "render", "--page", "Composer", "--event", "message-composer-scroll-view:onSteerSubmit")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(steered["tree"], "js-last-action")), "Last: steer", "Command-Return runs onSteerSubmit.")

        # The plus menu: Plan mode and Goal.
        plan = self.assert_success(self.call_cli("plugin", "render", "--page", "Composer", "--event", "conversation-mode-menu:onMenu:mode:plan")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(plan["tree"], "js-last-action")), "Last: mode mode:plan")
        mode = self.plugin_node(plan["tree"], "conversation-mode-menu")["props"]
        self.assertEqual((mode["text"], mode["color"], mode["label"], [item["checked"] for item in mode["items"][0]]),
                         ("Plan", "accent", "Conversation mode: Plan mode", [False, False, True]))
        start = self.plugin_node(plan["tree"], "start-implementing-button")
        self.assertEqual((start["events"], start["props"]["value"], start["children"][0]["props"]["fill"]), (["onPress"], "Available", "accent"))
        goal = self.assert_success(self.call_cli("plugin", "render", "--page", "Composer", "--event", "conversation-mode-menu:onMenu:goal")[0])
        mode = self.plugin_node(goal["tree"], "conversation-mode-menu")["props"]
        self.assertEqual((mode["text"], mode["badgeIcon"], mode["label"]), ("Goal", "scope", "Goal"), "Goal labels the plus menu.")
        self.assertEqual(self.plugin_node(goal["tree"], "message-composer-scroll-view")["props"]["placeholder"], "Set a goal to keep pursuing")
        self.assertFalse(self.plugin_node(goal["tree"], "send-message-button")["props"]["disabled"], "A goal can be sent without a draft.")
        codex = self.assert_success(self.call_cli("plugin", "render", "--page", "Composer", "--event", "conversation-provider-menu:onMenu:codex")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(codex["tree"], "js-last-action")), "Last: provider codex")
        self.assertEqual(self.plugin_node(codex["tree"], "conversation-provider-menu")["props"]["text"], "Codex")

        # The model popover: open, choose a model and an effort, dismiss.
        opened = self.assert_success(self.call_cli("plugin", "render", "--page", "Composer", "--event", "model-picker-menu:onPress")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(opened["tree"], "js-last-action")), "Last: model picker open")
        self.assertTrue(self.plugin_node(opened["tree"], "model-picker-popover")["props"]["isPresented"])
        self.assertEqual(self.plugin_node(opened["tree"], "model-option-claude-sonnet-5-5-checked")["props"]["name"], "checkmark", "The current model is checked.")
        self.assertEqual((self.plugin_node(opened["tree"], "model-option-claude-sonnet-5-5")["props"]["value"], self.plugin_node(opened["tree"], "model-option-claude-opus-5-5")["props"]["value"]),
                         ("Selected", "Not selected"), "A checked model's button reads Selected.")
        self.assertNotIn("model-option-claude-opus-5-5-checked", {node.get("props", {}).get("testID") for node in self.plugin_nodes(opened["tree"])})
        slider = self.plugin_node(opened["tree"], "model-effort-slider")
        self.assertEqual((slider["type"], slider["events"], slider["props"]["selected"], [option["value"] for option in slider["props"]["options"]]),
                         ("StepSlider", ["onChange"], "medium", ["low", "medium", "high", "xhigh"]))
        chosen = self.assert_success(self.call_cli(
            "plugin", "render", "--page", "Composer", "--event", "model-picker-menu:onPress", "--event", "model-option-claude-opus-5-5:onPress",
            "--event", "model-effort-slider:onChange:xhigh")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(chosen["tree"], "js-last-action")), "Last: effort xhigh")
        self.assertEqual(self.plugin_node(chosen["tree"], "model-picker-menu")["props"]["label"], "Model: Opus 5.5, effort: Extra High")
        self.assertEqual(self.plugin_text(self.plugin_node(chosen["tree"], "selected-model-effort")), "Extra High")
        self.assertEqual(self.plugin_node(chosen["tree"], "model-option-claude-opus-5-5-checked")["props"]["name"], "checkmark", "The chosen model is checked instead.")
        model_only = self.assert_success(self.call_cli(
            "plugin", "render", "--page", "Composer", "--event", "model-picker-menu:onPress", "--event", "model-option-claude-opus-5-5:onPress")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(model_only["tree"], "js-last-action")), "Last: model claude-opus-5-5")
        dismissed = self.assert_success(self.call_cli(
            "plugin", "render", "--page", "Composer", "--event", "model-picker-menu:onPress", "--event", "model-picker-popover:onDismiss")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(dismissed["tree"], "js-last-action")), "Last: model picker closed")
        self.assertFalse(self.plugin_node(dismissed["tree"], "model-picker-popover")["props"]["isPresented"])

        # The schedule popover opens; its content stays native in the conversation.
        schedule = self.assert_success(self.call_cli("plugin", "render", "--page", "Composer", "--event", "schedule-task-button:onPress")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(schedule["tree"], "js-last-action")), "Last: schedule open")
        self.assertTrue(self.plugin_node(schedule["tree"], "schedule-popover")["props"]["isPresented"])

        # A Popover shows every child after its anchor; one with only an anchor is valid.
        lone = self.assert_success(self.render_plugin('Playhouse.render(h(Popover, { isPresented: false }, h(Text, null, "Anchor")));'))
        self.assertEqual(lone["errors"], [])

        # The editor raises no onPress, so pressing it is refused.
        self.assert_failure(self.call_cli("plugin", "render", "--page", "Composer", "--event", "message-composer-scroll-view:onPress", expected_status=2)[0], "invalid_argument")
