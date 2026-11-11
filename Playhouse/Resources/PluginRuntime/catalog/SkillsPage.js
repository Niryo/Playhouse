// The Skills page's header and skill gallery, composed in JavaScript from the
// same atoms the native SkillsPageHeader and SkillGalleryView
// (Playhouse/App/SkillGalleryView.swift) use, from the same display model
// (Playhouse.props.skillsPage). Above it, the composer's Skills button
// (SkillsButton) opens it, its back button closes it, and a readout names the
// last action. The demo keeps the page's own state: the kind and source
// pickers, the search text, the switches and the selection.

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
  model.tabs.forEach(function (tab) {
    tab.sections.forEach(function (section) { rows = rows.concat(section.rows); });
  });
  return rows;
}

function Header(props) {
  var model = props.model, on = props.on, prefix = model.prefix, selection = model.selection;
  var selecting = selection != null;
  var children = [
    h(Button, {
      shortcut: model.panelOpen || selecting ? undefined : "cancel", testID: prefix + "skills-back-button",
      label: "Back to the conversation", help: "Back to the conversation", onPress: on.back
    }, h(Panel, { fillOpacity: 0.07, cornerRadius: 13, width: 26, height: 26 },
      h(Icon, { name: "chevron.left", size: 13, weight: "semibold" }))),
    h(Text, { size: 17, weight: "semibold", testID: prefix + "skills-title" }, model.title),
    h(Segmented, {
      options: model.kinds, selected: model.kind, disabled: selecting || model.panelOpen,
      testID: prefix + "skills-kind-picker", label: "Show",
      help: "Show skills, the rule files agents follow on every turn, or the MCP servers that give them tools", onChange: on.selectKind
    })
  ];
  return h(Stack, { axis: "h", spacing: 12, padding: 12, paddingX: 8 }, children.map(keyed));
}

function SourceRow(props) {
  var model = props.model, on = props.on, prefix = model.prefix;
  var children = [
    h(Segmented, {
      options: model.tabs.map(function (tab) { return { value: tab.value, label: tab.label }; }), selected: model.tab,
      testID: prefix + "skills-tab-picker", label: "Skill source", width: 260, onChange: on.selectTab
    }),
    h(Spacer)
  ];
  if (model.selection != null) {
    children.push(h(SelectionActions, { model: model, on: on }));
  } else {
    children.push(h(TextField, { text: model.search, placeholder: "Search skills", testID: prefix + "skills-search", width: 200, onChange: on.search }));
    children.push(h(Button, { style: "bordered", testID: prefix + "new-skill-button", help: "Create a skill that both Claude and Codex can use", onPress: on.newSkill },
      h(Label, { text: "New Skill", icon: "plus" })));
  }
  return h(Stack, { axis: "h", spacing: 12, padding: 10, paddingX: 20 }, children.map(keyed));
}

function SelectionActions(props) {
  var model = props.model, on = props.on, prefix = model.prefix, selection = model.selection;
  return h(Stack, { axis: "h", spacing: 8 },
    h(Text, { color: "secondary", monospacedDigits: true, testID: prefix + "skills-selection-count" }, model.selectionCount),
    h(Button, {
      style: "bordered", disabled: !model.canFixSelection || model.isFixing, testID: prefix + "skills-fix-selected",
      help: "Open a task whose agent fixes the selected conflicting or invalid skills", onPress: on.fixSelected
    }, h(Label, { text: "Fix with Agent", icon: "wand.and.stars" })),
    h(Button, {
      style: "bordered", disabled: selection.length === 0, destructive: true, testID: prefix + "skills-delete-selected",
      help: "Delete the selected skills from disk", onPress: on.deleteSelected
    }, h(Label, { text: "Delete", icon: "trash" })),
    h(Button, {
      style: "bordered", shortcut: model.panelOpen ? undefined : "cancel", testID: prefix + "skills-selection-done",
      help: "Stop selecting skills", onPress: on.endSelection
    }, h(Text, null, "Done")));
}

function emptyState(prefix, empty) {
  return h(Text, { key: "empty-" + empty.key, color: "secondary", testID: prefix + "skills-empty-" + empty.key }, empty.text);
}

function badge(prefix, badge) {
  return h(Panel, { key: badge.testID, fill: badge.color, fillOpacity: 0.12, cornerRadius: 8, padding: 2, paddingX: 4, testID: prefix + badge.testID },
    h(Label, { text: badge.text, icon: badge.icon, size: 10, weight: "medium", color: badge.color }));
}

function Controls(model, row, on) {
  var prefix = model.prefix, name = row.name;
  return [
    row.fixable ? h(Button, {
      style: "bordered", disabled: model.isFixing, controlSize: "small", testID: prefix + "skill-fix-" + name,
      help: "Open a task whose agent fixes " + name, onPress: function () { on.fix(row.id); }
    }, h(Label, { text: "Fix with Agent", icon: "wand.and.stars" })) : null,
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
      icon: "ellipsis", size: 13, weight: "semibold",
      items: row.menu.map(function (group) {
        return group.map(function (item) {
          return { id: item.id, title: item.title, destructive: item.destructive, help: item.help, testID: prefix + item.testID };
        });
      }),
      testID: prefix + "skill-actions-" + name, label: "Actions for " + name, help: "More actions for " + name, width: 24, height: 24,
      onMenu: function (item) { on.menu(row.id, item); }
    })
  ];
}

function Row(props) {
  var model = props.model, row = props.row, on = props.on, prefix = model.prefix, name = row.name;
  var selecting = model.selection != null;
  var selected = selecting && model.selection.indexOf(row.id) >= 0;
  var text = [
    selecting && row.editable ? h(Icon, {
      name: selected ? "checkmark.circle.fill" : "circle", size: 16, color: selected ? "accent" : "secondary",
      testID: prefix + "skill-select-" + name, label: selected ? "Selected" : "Not selected"
    }) : null,
    h(Stack, { axis: "v", spacing: 4, align: "leading" },
      h(Stack, { axis: "h", spacing: 6 },
        [h(Text, { key: "name", size: 13, weight: "semibold", testID: prefix + "skill-name-" + name }, name)]
          .concat(row.badges.map(function (each) { return badge(prefix, each); }))),
      row.description != null ? h(Text, { size: 12, color: "secondary", lineLimit: 3, testID: prefix + "skill-description-" + name }, row.description) : null,
      row.issue != null ? h(Text, { size: 10, color: "orange", testID: prefix + "skill-issue-" + name }, row.issue) : null,
      h(Text, { size: 10, color: "tertiary", testID: prefix + "skill-location-" + name }, row.location)),
    h(Spacer, { minLength: 8 })
  ];
  // A press and hold starts selecting; a click opens the skill, or selects while
  // selecting. Only the skill's own text takes them.
  var children = [
    h(PressArea, {
      pointer: selecting ? row.editable : row.opensOnClick, testID: prefix + "skill-text-" + name,
      onPress: function () { on.press(row.id); }, onLongPress: function () { on.longPress(row.id); }
    }, h(Stack, { axis: "h", spacing: 12 }, text.map(keyed)))
  ].concat(selecting ? [] : Controls(model, row, on));
  return h(Panel, {
    fill: selected ? "accent" : "panel", fillOpacity: selected ? 0.12 : 1, cornerRadius: 10,
    stroke: selected ? "accent" : undefined, strokeOpacity: 0.6,
    testID: prefix + "skill-row-" + name, fillWidth: true, padding: 10, paddingX: 4
  }, h(Stack, { axis: "h", spacing: 12 }, children.map(keyed)));
}

function sectionRows(model, section, on) {
  var children = section.empty ? [emptyState(model.prefix, section.empty)] : [];
  return children.concat(section.rows.map(function (row) { return h(Row, { key: row.id, model: model, row: row, on: on }); }));
}

function galleryContent(model, on) {
  var prefix = model.prefix;
  if (!model.loaded) {
    return [h(Stack, { key: "loading", axis: "h" }, h(Spacer), h(Spinner, { size: "regular", testID: prefix + "skills-loading" }), h(Spacer))];
  }
  var tab = model.tabs.filter(function (each) { return each.value === model.tab; })[0];
  if (!tab) return [];
  var children = [h(Text, { key: "intro", size: 12, color: "secondary" }, tab.intro)];
  if (tab.loading) children.push(h(Spinner, { key: "builtin-loading", testID: prefix + "skills-builtin-loading" }));
  if (tab.empty) children.push(emptyState(prefix, tab.empty));
  tab.sections.forEach(function (section, index) {
    if (section.title != null) {
      children.push(h(Stack, { key: "section-" + index, axis: "v", spacing: 8, align: "leading" },
        [h(Text, { key: "title", size: 13, weight: "bold", testID: prefix + "skills-repo-section-" + section.title }, section.title)]
          .concat(sectionRows(model, section, on))));
    } else {
      children = children.concat(sectionRows(model, section, on));
    }
  });
  return children;
}

function Gallery(props) {
  var model = props.model, on = props.on, prefix = model.prefix;
  return h(Stack, { axis: "v", spacing: 0, align: "leading" },
    model.kind === "skills" ? h(SourceRow, { model: model, on: on }) : null,
    model.error != null ? h(Text, { size: 12, color: "red", testID: prefix + "skills-error", fillWidth: true, padding: 8, paddingX: 12 }, model.error) : null,
    h(Text, { size: 10, color: "secondary", testID: prefix + "skills-provider-timing", padding: 8, paddingX: 12 },
      model.selection != null ? model.selectingHint : model.hint),
    h(Scroll, { spacing: 10, inset: 20, lazy: true, testID: prefix + "skills-list" }, galleryContent(model, on)));
}

function rowNamed(model, id) {
  return rowsOf(model).filter(function (row) { return row.id === id; })[0];
}

function Demo() {
  var sample = Playhouse.props.skillsPage;
  var open = React.useState(true);
  var kind = React.useState(sample.kind);
  var tab = React.useState(sample.tab);
  var search = React.useState(sample.search);
  var selection = React.useState(null);
  var switched = React.useState({});
  var last = React.useState("none");

  // The page's state applied to the sample, as SkillsPageView applies it to the catalog.
  var chosen = rowsOf(sample).filter(function (row) { return selection[0] != null && selection[0].indexOf(row.id) >= 0; });
  var model = Object.assign({}, sample, {
    kind: kind[0], tab: tab[0], search: search[0], selection: selection[0],
    selectionCount: chosen.length === 1 ? "1 selected" : chosen.length + " selected",
    canFixSelection: chosen.some(function (row) { return row.fixable; }),
    tabs: sample.tabs.map(function (each) {
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
    selectTab: function (value) { tab[1](value); last[1]("tab " + value); },
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
  var page = open[0] ? h(Panel, { spacing: 0, fill: "window", fillOpacity: 1, cornerRadius: 10, width: 1040, height: 520, testID: model.prefix + "skills-page" },
    h(Header, { model: model, on: on }),
    h(Divider),
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
