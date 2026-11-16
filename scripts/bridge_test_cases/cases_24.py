from test_bridge_support import *
from test_bridge_support import __file__

class BridgeTestCases24:
    # Each test ID is prefixed with the plugin's id, so two sections never share one.
    SIDEBAR_SECTION_SOURCE = """
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
    # case-contract: test_plugin_sidebar_bottom_sections_and_agents_context | The board sidebar's bottom is the mainSidebarBottom placement, whose plugins always use the section presentation: a manifest or an authoring request with any other presentation there, or with section anywhere else, is invalid with an error naming the rule. A section plugin gets `props.agents` with the last-known agent usage report (the same providers `usage get` reports, each with whether its CLI is installed) and `runningTasks`, each provider's count of In Progress tasks, which counts a running Codex turn. The app.launched event reaches a plugin once per launch, and the first listener a plugin adds after it was emitted still hears it once; a later listener does not. ui.confirm and ui.openURL are host calls: confirm is answered only by the board (unavailable at the conversation sidebar; in `plugin render` it resolves null), and openURL accepts only http and https URLs (anything else is invalid_argument). In the window, sections stack at the bottom of the sidebar, each under a collapsible header with the plugin's name, open by default: collapsed, they sit one above the other at the bottom, and expanding the lower one grows it upward and pushes the upper one up. A section's collapsed state is its plugin state `collapsed` and survives a relaunch. The section's plugin hears app.launched, reads both providers' running counts, gets true from ui.confirm when the user confirms the board's dialog (showing its title, message and confirm button) and false when they cancel, opens http URLs and is refused other URLs, and the built-in Agents info section is not shown when no agent CLI is installed. Authoring a plugin there starts it as a section without asking how it opens: `plugin author --placement mainSidebarBottom` with a name and the section presentation records both and the placement, and in the window Add Plugin mode shows an Add here button below the sections whose setup goes from the name straight to the editor, which says it opens as a collapsible section.
    def test_plugin_sidebar_bottom_sections_and_agents_context(self):
        # Only a section sits at the sidebar's bottom, and a section only there.
        self.write_installed_plugin("bottom-probe", self.SIDEBAR_SECTION_SOURCE, placement="mainSidebarBottom", presentation="section")
        self.write_installed_plugin("bottom-popover", self.SIDEBAR_SECTION_SOURCE, placement="mainSidebarBottom", presentation="popover")
        self.write_installed_plugin("sidebar-section", self.SIDEBAR_SECTION_SOURCE, placement="mainSidebar", presentation="section")
        self.write_installed_plugin("conversation-probe", self.SIDEBAR_SECTION_SOURCE, placement="conversationSidebar", presentation="popover")
        refreshed = {plugin["id"]: plugin for plugin in self.assert_success(self.call_cli("plugin", "refresh")[0])["plugins"]}
        probe = refreshed["bottom-probe"]
        self.assertEqual((probe["placement"], probe["presentation"], probe["valid"]), ("mainSidebarBottom", "section", True), probe["errors"])
        self.assertFalse(refreshed["bottom-popover"]["valid"])
        self.assertTrue(any('always a collapsible section; its presentation must be "section"' in error for error in refreshed["bottom-popover"]["errors"]),
                        refreshed["bottom-popover"]["errors"])
        self.assertFalse(refreshed["sidebar-section"]["valid"])
        self.assertTrue(any("only at the Main sidebar bottom" in error for error in refreshed["sidebar-section"]["errors"]), refreshed["sidebar-section"]["errors"])
        for placement, presentation, message in (("mainSidebarBottom", "popover", "always a collapsible section"),
                                                 ("mainSidebar", "section", "only at the Main sidebar bottom")):
            refused = self.call_cli("plugin", "author", "--placement", placement, "--name", "Bottom", "--presentation", presentation, expected_status=2)[0]
            self.assert_failure(refused, "invalid_argument")
            self.assertIn(message, refused["error"]["message"])
        authored = self.assert_success(self.call_cli("plugin", "author", "--placement", "mainSidebarBottom", "--name", "Usage", "--presentation", "section", "--provider", "claude")[0])["task"]
        self.assertEqual((authored["title"], authored["pluginPlacement"], authored.get("pluginAuthoringName"), authored.get("pluginAuthoringPresentation")),
                         ("Usage", "mainSidebarBottom", "Usage", "section"), "A plugin authored there starts as a section.")
        self.assertEqual(self.assert_success(self.call_cli("plugin", "edit", "--id", authored["authoredPluginID"])[0])["task"]["pluginAuthoringPresentation"], "section")

        # The placement's context: the agents' last-known usage and running tasks.
        rendered = self.assert_success(self.call_cli("plugin", "render", "--plugin", "bottom-probe")[0])
        self.assertEqual(rendered["errors"], [])
        usage = self.assert_success(self.call_cli("usage", "get")[0])
        expected = ", ".join(f"{entry['provider']} {'installed' if entry['installed'] else 'missing'}" for entry in usage["providers"])
        self.assertEqual(self.plugin_text(self.plugin_node(rendered["tree"], "bottom-probe-usage")), expected, "props.agents.usage is the usage report.")
        self.assertEqual(self.plugin_text(self.plugin_node(rendered["tree"], "bottom-probe-running")), "claude 0, codex 0")
        other = self.create_task(title="Sidebar bottom context")
        no_agents = self.assert_success(self.call_cli("plugin", "render", "--plugin", "conversation-probe", "--task", other["id"])[0])
        self.assertEqual(self.plugin_text(self.plugin_node(no_agents["tree"], "conversation-probe-running")), "no agents", "Only the sidebar's bottom gets props.agents.")
        held = {}
        def render_while_running():
            held["tree"] = self.assert_success(self.call_cli("plugin", "render", "--plugin", "bottom-probe")[0])["tree"]
        task = self.create_task(title="Sidebar bottom running task")
        self.complete_fixture_turn(task["id"], while_turn_held=render_while_running)
        self.assertEqual(self.plugin_text(self.plugin_node(held["tree"], "bottom-probe-running")), "claude 0, codex 1", "A running Codex turn counts.")

        # app.launched reaches the listeners there are, and the first one added after it.
        launched = self.assert_success(self.call_cli("plugin", "render", "--plugin", "bottom-probe",
                                                     "--event", "@app.launched", "--event", "bottom-probe-listen:onPress", "--event", "bottom-probe-listen:onPress")[0])
        self.assertEqual(launched["errors"], [])
        self.assertEqual([(event["name"], event["listeners"]) for event in launched["emitted"]], [("app.launched", 1)])
        self.assertEqual(self.plugin_text(self.plugin_node(launched["tree"], "bottom-probe-launches")), "launches 1, late 0", "One launch, heard by the mounted listener.")
        unheard = """
function Late() {
  var heard = React.useState(0);
  return h(Stack, {},
    h(Text, { testID: "heard" }, "heard " + heard[0]),
    h(Button, { testID: "listen", onPress: function () {
      Playhouse.on("app.launched", function () { heard[1](function (count) { return count + 1; }); });
    } }, h(Text, {}, "listen")));
}
Playhouse.render(h(Late));
"""
        late = self.assert_success(self.render_plugin(unheard, "--event", "@app.launched", "--event", "listen:onPress", "--event", "+1", "--event", "listen:onPress", "--event", "+1"))
        self.assertEqual(late["errors"], [])
        self.assertEqual([(event["name"], event["listeners"]) for event in late["emitted"]], [("app.launched", 0)], "No listener yet when it is emitted.")
        self.assertEqual(self.plugin_text(self.plugin_node(late["tree"], "heard")), "heard 1", "The first listener added later hears it once; the second doesn't.")
        delivered = self.assert_success(self.call_cli("plugin", "event", "app.launched")[0])
        self.assertEqual(delivered["name"], "app.launched")

        # ui.confirm is the board's to answer; ui.openURL opens only web pages.
        def press(plugin_id, button, *options):
            pressed = self.assert_success(self.call_cli("plugin", "render", "--plugin", plugin_id, *options, "--event", f"{plugin_id}-{button}:onPress")[0])
            return self.plugin_text(self.plugin_node(pressed["tree"], f"{plugin_id}-result")), pressed["hostCalls"][-1]
        text, call = press("bottom-probe", "confirm")
        self.assertEqual(text, "confirm: null", "Headless, nobody is asked.")
        self.assertEqual((call["kind"], call["name"], call["ok"], call["arguments"]),
                         ("ui", "confirm", True, {"title": "Run bottom-probe?", "message": "Asked from the sidebar bottom.", "confirm": "Run It", "destructive": True}))
        text, call = press("conversation-probe", "confirm", "--task", other["id"])
        self.assertEqual((text, call["error"]["code"]), ("confirm: unavailable", "unavailable"), "Only the board asks to confirm.")
        for plugin_id, options in (("bottom-probe", ()), ("conversation-probe", ("--task", other["id"]))):
            text, call = press(plugin_id, "open", *options)
            self.assertEqual((text, call["arguments"]), ("open: null", {"url": "https://example.com/usage"}), f"{plugin_id} opens web pages.")
            text, call = press(plugin_id, "open-file", *options)
            self.assertEqual((text, call["error"]["code"]), ("open-file: invalid_argument", "invalid_argument"), "Only http and https open.")

        # The collapsed state is the plugin's state, as the window saves it.
        self.assert_success(self.call_cli("plugin", "state", "--id", "bottom-probe", "--key", "collapsed", "--value", "true")[0])
        listed = {plugin["id"]: plugin for plugin in self.assert_success(self.call_cli("plugin", "list")[0])["plugins"]}
        self.assertEqual(listed["bottom-probe"]["state"], {"collapsed": True})
