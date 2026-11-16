// The Skills page's header, tabs and skill gallery, composed in JavaScript from
// the same atoms the native SkillsPageHeader, SkillsPageTabs and
// SkillGalleryView (Playhouse/App/SkillGalleryView.swift) use, from the same display model
// (Playhouse.props.skillsPage). Above it, the composer's Skills button
// (SkillsButton) opens it, its close button closes it, and a readout names the
// last action. The demo keeps the page's own state: the kind picker, the
// group the anchors last scrolled to, the search text, the switches and the
// selection.

function SkillsButton(props) {
  return h(Button, { testID: props.testID, label: "Skills", help: "Skills", onPress: props.onPress },
    h(Icon, { name: "sparkles" }));
}

// Children of a row are siblings in an array, so each needs a key.
function keyed(element, index) {
  return element && React.cloneElement(element, { key: element.key != null ? element.key : String(index) });
}

function rowsOf(model) {
  var rows = [];
  model.groups.forEach(function (group) {
    group.sections.forEach(function (section) { rows = rows.concat(section.rows); });
  });
  return rows;
}

function Header(props) {
  var model = props.model, on = props.on, prefix = model.prefix, selection = model.selection;
  var selecting = selection != null;
  var children = [
    h(Stack, { fill: "accent", fillOpacity: 0.14, cornerRadius: 7, width: 26, height: 26 },
      h(Icon, { name: "sparkles", size: 13, weight: "semibold", color: "accent" })),
    h(Text, { size: 15, weight: "semibold", testID: prefix + "skills-title" }, model.title),
    h(Spacer),
    h(Button, {
      shortcut: model.panelOpen || selecting ? undefined : "cancel", testID: prefix + "skills-back-button",
      label: "Close", help: "Close (Esc)", onPress: on.back
    }, h(Stack, { fill: "primary", fillOpacity: 0.07, capsule: true, width: 22, height: 22 },
      h(Icon, { name: "xmark", size: 9, weight: "bold", color: "secondary" })))
  ];
  return h(Stack, { axis: "h", spacing: 10, paddingX: 20, paddingY: 14 }, children.map(keyed));
}

// The Skills | Rules | MCP tabs, centered at the top of the modal's body.
function Tabs(props) {
  var model = props.model, on = props.on;
  return h(Stack, { axis: "h", paddingX: 20, paddingY: 14 },
    h(Spacer),
    h(Segmented, {
      options: model.kinds, selected: model.kind, disabled: model.selection != null || model.panelOpen,
      testID: model.prefix + "skills-kind-picker", label: "Show",
      help: "Show skills, the rule files agents follow on every turn, or the MCP servers that give them tools", onChange: on.selectKind
    }),
    h(Spacer));
}

// The anchors scroll the list to a group; they are not tabs.
function AnchorBar(props) {
  var model = props.model, on = props.on, prefix = model.prefix;
  return h(Stack, { axis: "h", spacing: 6, group: true, testID: prefix + "skills-tab-picker", label: "Jump to" },
    model.groups.map(function (group) {
      return h(Button, {
        key: group.value, testID: prefix + "skills-anchor-" + group.value, label: group.label, help: "Scroll to " + group.label,
        onPress: function () { on.jump(group.value); }
      }, h(Stack, { axis: "h", spacing: 5, fill: "primary", fillOpacity: 0.06, capsule: true, paddingX: 10, paddingY: 4 },
        h(Text, { size: 11, weight: "medium" }, group.label),
        h(Text, { size: 11, color: "secondary", monospacedDigits: true }, String(group.count))));
    }));
}

// The search and New Skill (or the selection's actions) on one row, the anchors on the next.
function Toolbar(props) {
  var model = props.model, on = props.on, prefix = model.prefix;
  var children = model.selection != null ? [h(Spacer), h(SelectionActions, { model: model, on: on })] : [
    h(Stack, { axis: "h", spacing: 6, fill: "primary", fillOpacity: 0.05, cornerRadius: 7, fillWidth: true, paddingX: 8, paddingY: 5 },
      h(Icon, { name: "magnifyingglass", size: 11, color: "secondary" }),
      h(TextField, { text: model.search, placeholder: "Search skills", style: "plain", testID: prefix + "skills-search", fillWidth: true, onChange: on.search })),
    h(Button, { style: "bordered", controlSize: "small", testID: prefix + "new-skill-button", help: "Create a skill that both Claude and Codex can use", onPress: on.newSkill },
      h(Label, { text: "New Skill", icon: "plus" }))
  ];
  return [
    h(Stack, { key: "search", axis: "h", spacing: 8, paddingX: 20 }, children.map(keyed)),
    h(Stack, { key: "anchors", axis: "h", spacing: 8, paddingX: 20, paddingY: 12 }, h(AnchorBar, { model: model, on: on }), h(Spacer))
  ];
}

function SelectionActions(props) {
  var model = props.model, on = props.on, prefix = model.prefix, selection = model.selection;
  return h(Stack, { axis: "h", spacing: 6 },
    h(Text, { size: 12, color: "secondary", monospacedDigits: true, testID: prefix + "skills-selection-count" }, model.selectionCount),
    h(Button, {
      style: "bordered", disabled: !model.canFixSelection || model.isFixing, controlSize: "small", testID: prefix + "skills-fix-selected",
      help: "Open a task whose agent fixes the selected conflicting or invalid skills", onPress: on.fixSelected
    }, h(Label, { text: "Fix with Agent", icon: "wand.and.stars" })),
    h(Button, {
      style: "bordered", disabled: selection.length === 0, controlSize: "small", destructive: true, testID: prefix + "skills-delete-selected",
      help: "Delete the selected skills from disk", onPress: on.deleteSelected
    }, h(Label, { text: "Delete", icon: "trash" })),
    h(Button, {
      style: "bordered", controlSize: "small", shortcut: model.panelOpen ? undefined : "cancel", testID: prefix + "skills-selection-done",
      help: "Stop selecting skills", onPress: on.endSelection
    }, h(Text, null, "Done")));
}

function emptyState(prefix, empty) {
  return h(Text, { key: "empty-" + empty.key, size: 12, color: "secondary", paddingX: 4, testID: prefix + "skills-empty-" + empty.key }, empty.text);
}

function badge(badge, testID) {
  return h(Stack, { key: badge.testID, fill: badge.color, fillOpacity: 0.12, capsule: true, paddingX: 6, paddingY: 2, fixedSize: true, testID: testID },
    h(Label, { text: badge.text, icon: badge.icon, size: 10, weight: "medium", color: badge.color }));
}

function Controls(model, row, on) {
  var prefix = model.prefix, name = row.name;
  return [
    row.fixable ? h(Button, {
      style: "bordered", disabled: model.isFixing, controlSize: "small", testID: prefix + "skill-fix-" + name,
      help: "Open a task whose agent fixes " + name, onPress: function () { on.fix(row.id); }
    }, h(Label, { text: "Fix", icon: "wand.and.stars" })) : null,
    h(Toggle, {
      isOn: row.enabled, size: "mini", testID: prefix + "skill-toggle-" + name, label: name + " enabled",
      help: row.enabled ? "Turn the skill off in Playhouse sessions" : "Turn the skill on in Playhouse sessions",
      onToggle: function () { on.toggle(row.id); }
    }),
    h(Button, {
      style: "bordered", disabled: !row.enabled || !row.usable, controlSize: "small", testID: prefix + "skill-use-" + name,
      help: "Insert /" + name + " into the message", onPress: function () { on.use(row.id); }
    }, h(Text, null, "Use")),
    h(Menu, {
      icon: "ellipsis", size: 12, weight: "semibold",
      items: row.menu.map(function (group) {
        return group.map(function (item) {
          return { id: item.id, title: item.title, destructive: item.destructive, help: item.help, testID: prefix + item.testID };
        });
      }),
      testID: prefix + "skill-actions-" + name, label: "Actions for " + name, help: "More actions for " + name, width: 22, height: 22,
      onMenu: function (item) { on.menu(row.id, item); }
    })
  ];
}

// A skill's details, shown beside its row while the pointer rests on it.
function Hint(props) {
  var model = props.model, row = props.row, prefix = model.prefix, name = row.name;
  var badges = (row.flag ? [badge(row.flag, undefined)] : [])
    .concat(row.badges.map(function (each) { return badge(each, prefix + each.testID); }));
  var children = [
    h(Text, { size: 13, weight: "semibold" }, name),
    row.description != null ? h(Text, { size: 12, color: "secondary", wrap: true, testID: prefix + "skill-description-" + name }, row.description) : null,
    badges.length > 0 ? h(Stack, { axis: "h", spacing: 4 }, badges) : null,
    // Its own line, so the command never wraps beside the chips.
    row.command ? badge(row.command, prefix + row.command.testID) : null,
    row.issue != null ? h(Text, { size: 11, color: "orange", wrap: true, testID: prefix + "skill-issue-" + name }, row.issue) : null,
    h(Text, { size: 10, color: "tertiary", wrap: true, testID: prefix + "skill-location-" + name }, row.location)
  ];
  return h(Stack, { axis: "v", spacing: 6, align: "leading", group: true, testID: prefix + "skill-hint-" + name }, children.map(keyed));
}

function Row(props) {
  var model = props.model, row = props.row, on = props.on, prefix = model.prefix, name = row.name;
  var selecting = model.selection != null;
  var selected = selecting && model.selection.indexOf(row.id) >= 0;
  var text = [
    selecting && row.editable ? h(Icon, {
      name: selected ? "checkmark.circle.fill" : "circle", size: 14, color: selected ? "accent" : "secondary",
      testID: prefix + "skill-select-" + name, label: selected ? "Selected" : "Not selected"
    }) : null,
    h(Text, { size: 13, weight: "medium", lineLimit: 1, testID: prefix + "skill-name-" + name }, name),
    row.flag ? h(Icon, { name: row.flag.icon, size: 11, color: row.flag.color, testID: prefix + row.flag.testID, label: row.flag.text, help: row.flag.text }) : null
  ].concat(row.providers.map(function (each) { return badge(each, prefix + each.testID); }), [h(Spacer, { minLength: 8 })]);
  // A press and hold starts selecting; a click opens the skill, or selects while
  // selecting. Only the skill's own text takes them.
  var children = [
    h(PressArea, {
      pointer: selecting ? row.editable : row.opensOnClick, testID: prefix + "skill-text-" + name, hint: row.description,
      onPress: function () { on.press(row.id); }, onLongPress: function () { on.longPress(row.id); }
    }, h(Stack, { axis: "h", spacing: 8 }, text.map(keyed)))
  ].concat(selecting ? [] : Controls(model, row, on));
  return h(Popover, { isPresented: false, arrowEdge: "trailing", width: 300, inset: 12, hover: true, onDismiss: function () {} },
    h(Stack, {
      axis: "h", spacing: 8, fill: selected ? "accent" : undefined, fillOpacity: selected ? 0.12 : undefined, group: true,
      testID: prefix + "skill-row-" + name, fillWidth: true, paddingX: 12, paddingY: 6
    }, children.map(keyed)),
    h(Hint, { model: model, row: row }));
}

function Card(props) {
  return h(Stack, { axis: "v", spacing: 0, align: "leading", fill: "panel", cornerRadius: 10, stroke: "primary", strokeOpacity: 0.08, fillWidth: true },
    props.rows.reduce(function (children, row, index) {
      if (index > 0) children.push(h(Divider, { key: "divider-" + row.id }));
      children.push(h(Row, { key: row.id, model: props.model, row: row, on: props.on }));
      return children;
    }, []));
}

function GroupHeader(props) {
  var model = props.model, group = props.group, prefix = model.prefix;
  var children = [
    h(Text, { size: 11, weight: "semibold", color: "secondary", tracking: 0.6 }, group.label.toUpperCase()),
    h(Text, { size: 11, color: "tertiary", monospacedDigits: true }, String(group.count)),
    group.loading ? h(Spinner, { size: "mini", testID: prefix + "skills-" + group.value + "-loading" }) : null,
    h(Spacer),
    h(Icon, { name: "info.circle", size: 11, color: "tertiary", testID: prefix + "skills-intro-" + group.value, label: "About " + group.label, help: group.intro })
  ];
  return h(Stack, { axis: "h", spacing: 6, paddingX: 4 }, children.map(keyed));
}

function Group(props) {
  var model = props.model, group = props.group, on = props.on, prefix = model.prefix;
  var children = [h(GroupHeader, { key: "header", model: model, group: group })];
  if (group.empty) children.push(emptyState(prefix, group.empty));
  group.sections.forEach(function (section, index) {
    if (section.title != null) {
      children.push(h(Text, { key: "title-" + index, size: 12, weight: "semibold", paddingX: 4, testID: prefix + "skills-repo-section-" + section.title }, section.title));
    }
    if (section.empty) children.push(emptyState(prefix, section.empty));
    if (section.rows.length > 0) children.push(h(Card, { key: "card-" + index, model: model, rows: section.rows, on: on }));
  });
  return h(Stack, {
    axis: "v", spacing: 8, align: "leading", group: true, scrollID: group.value,
    testID: prefix + "skills-group-" + group.value, label: group.label, fillWidth: true
  }, children);
}

function galleryContent(model, on) {
  var prefix = model.prefix;
  if (!model.loaded) {
    return [h(Stack, { key: "loading", axis: "h" }, h(Spacer), h(Spinner, { size: "regular", testID: prefix + "skills-loading" }), h(Spacer))];
  }
  return model.groups.map(function (group) { return h(Group, { key: group.value, model: model, group: group, on: on }); })
    .concat([h(Text, { key: "hint", size: 10, color: "tertiary", paddingX: 4, testID: prefix + "skills-provider-timing" },
      model.selection != null ? model.selectingHint : model.hint)]);
}

function Gallery(props) {
  var model = props.model, on = props.on, prefix = model.prefix;
  return h(Stack, { axis: "v", spacing: 0, align: "leading" },
    Toolbar({ model: model, on: on }),
    model.error != null ? h(Text, { size: 12, color: "red", testID: prefix + "skills-error", fillWidth: true, paddingX: 20, paddingY: 4 }, model.error) : null,
    h(Divider),
    h(Scroll, { spacing: 18, inset: 20, scrollTo: model.scrollTo, scrollRequest: model.scrollRequest, testID: prefix + "skills-list" }, galleryContent(model, on)));
}

function rowNamed(model, id) {
  return rowsOf(model).filter(function (row) { return row.id === id; })[0];
}

function Demo() {
  var sample = Playhouse.props.skillsPage;
  var open = React.useState(true);
  var kind = React.useState(sample.kind);
  var scrollTo = React.useState(sample.scrollTo);
  var scrollRequest = React.useState(sample.scrollRequest);
  var search = React.useState(sample.search);
  var selection = React.useState(null);
  var switched = React.useState({});
  var last = React.useState("none");

  // The page's state applied to the sample, as SkillsPageView applies it to the catalog.
  var chosen = rowsOf(sample).filter(function (row) { return selection[0] != null && selection[0].indexOf(row.id) >= 0; });
  var model = Object.assign({}, sample, {
    kind: kind[0], scrollTo: scrollTo[0], scrollRequest: scrollRequest[0], search: search[0], selection: selection[0],
    selectionCount: chosen.length === 1 ? "1 selected" : chosen.length + " selected",
    canFixSelection: chosen.some(function (row) { return row.fixable; }),
    groups: sample.groups.map(function (each) {
      return Object.assign({}, each, {
        sections: each.sections.map(function (section) {
          return Object.assign({}, section, {
            rows: section.rows.map(function (row) {
              return switched[0][row.id] == null ? row : Object.assign({}, row, { enabled: switched[0][row.id] });
            })
          });
        })
      });
    })
  });
  function name(id) { return rowNamed(model, id).name; }
  var on = {
    back: function () { open[1](false); last[1]("back"); },
    selectKind: function (value) { kind[1](value); last[1]("kind " + value); },
    jump: function (value) { scrollTo[1](value); scrollRequest[1](scrollRequest[0] + 1); last[1]("jump " + value); },
    search: function (text) { search[1](text); last[1]("search " + text); },
    newSkill: function () { last[1]("new skill"); },
    fixSelected: function () { last[1]("fix " + selection[0].length + " selected"); },
    deleteSelected: function () { last[1]("delete " + selection[0].length + " selected"); },
    endSelection: function () { selection[1](null); last[1]("done selecting"); },
    press: function (id) {
      var row = rowNamed(model, id);
      if (selection[0] == null) {
        last[1](row.opensOnClick ? "open " + row.name : "press " + row.name);
      } else if (row.editable) {
        var chosen = selection[0].indexOf(id) >= 0;
        selection[1](chosen ? selection[0].filter(function (each) { return each !== id; }) : selection[0].concat([id]));
        last[1]((chosen ? "deselect " : "select ") + row.name);
      }
    },
    longPress: function (id) {
      var row = rowNamed(model, id);
      if (!row.editable) return;
      selection[1](selection[0] == null ? [id] : selection[0].indexOf(id) >= 0 ? selection[0] : selection[0].concat([id]));
      last[1]("select " + row.name);
    },
    fix: function (id) { last[1]("fix " + name(id)); },
    toggle: function (id) {
      var row = rowNamed(model, id);
      var next = Object.assign({}, switched[0]);
      next[id] = !row.enabled;
      switched[1](next);
      last[1]("toggle " + row.name + (row.enabled ? " off" : " on"));
    },
    use: function (id) { last[1]("use " + name(id)); },
    menu: function (id, item) { last[1]("menu " + name(id) + " " + item); }
  };
  var page = open[0] ? h(Panel, { spacing: 0, fill: "window", fillOpacity: 1, cornerRadius: 14, width: 480, height: 520, padding: 0, testID: model.prefix + "skills-page" },
    h(Header, { model: model, on: on }),
    h(Divider),
    h(Tabs, { model: model, on: on }),
    model.kind === "skills" ? h(Gallery, { model: model, on: on })
      : h(Text, { size: 12, color: "secondary", padding: 20, testID: model.prefix + "skills-native-list" }, "The Rules and MCP lists stay native.")) : null;
  return h(Stack, { axis: "v", spacing: 12, align: "leading" },
    h(Stack, { axis: "h", spacing: 8 },
      h(Text, { size: 11, color: "secondary" }, "Composer button"),
      h(SkillsButton, { testID: model.prefix + "open-skills-button", onPress: function () { open[1](true); last[1]("open"); } }),
      h(Text, { size: 11, color: "secondary", testID: "js-last-action" }, "Last: ", last[0])),
    page);
}

Playhouse.render(h(Demo));
