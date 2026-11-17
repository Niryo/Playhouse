// The task header's repository chips and the Add repository picker (the hint
// its + button opens), composed in JavaScript from the same atoms the native
// RepositoryChipsView and RepositoryPickerView
// (Playhouse/App/RepositoryChipsView.swift) use, from the same display models
// (Playhouse.props.repositoryChips and Playhouse.props.repositoryPicker). The
// header presents the picker as a popover; here it shows in a panel under the
// chips, and the + button shows and hides it. A readout names the last action.
// The demo keeps the chips, the search text and the highlighted row.

// Children of a row are siblings in an array, so each needs a key.
function keyed(element, index) {
  return element && React.cloneElement(element, { key: element.key != null ? element.key : String(index) });
}

function Chip(props) {
  var model = props.model, chip = props.chip, on = props.on, prefix = model.prefix, name = chip.name;
  return h(Overlay, { align: "topTrailing", offsetX: 6, offsetY: -6 },
    h(Button, {
      disabled: model.readOnly, testID: prefix + "conversation-repository-badge-" + name,
      help: "Edit repository settings for " + name, onPress: function () { on.edit(chip.key || chip.path); }
    }, h(Panel, { fill: "primary", fillOpacity: 0.08, capsule: true, stroke: "primary", strokeOpacity: 0.14, padding: 7, paddingX: 5.5 },
      h(Stack, { axis: "h", spacing: 6 },
        h(Icon, { name: "arrow.triangle.branch", size: 11, weight: "semibold", color: model.accent }),
        h(Text, { size: 13, weight: "semibold", color: "primary", lineLimit: 1 }, chip.branch ? chip.path.split("/").pop() : name),
        chip.branch ? h(Text, { size: 11, color: "secondary", lineLimit: 1, truncation: "middle" }, chip.branch) : null))),
    model.readOnly ? null : h(Button, {
      testID: prefix + "remove-conversation-repository-" + name, label: "Remove " + name,
      help: "Remove " + name + " from this task", onPress: function () { on.remove(chip.key || chip.path); }
    }, h(Panel, { fill: "panel", fillOpacity: 1, capsule: true, stroke: "primary", strokeOpacity: 0.16, width: 20, height: 20, padding: 0 },
      h(Icon, { name: "xmark", size: 9, weight: "bold", color: "secondary" }))));
}

function Chips(props) {
  var model = props.model, on = props.on, prefix = model.prefix;
  var children = model.chips.map(function (chip) { return h(Chip, { key: chip.key || chip.path, model: model, chip: chip, on: on }); });
  children.push(h(Button, {
    key: "add", disabled: model.readOnly, testID: prefix + "add-conversation-repository-button",
    label: "Add repository", help: "Add a repository", onPress: on.add
  }, h(Panel, { fillOpacity: 0.07, capsule: true, width: 28, height: 28, padding: 0 },
    h(Icon, { name: "plus", size: 12, weight: "semibold" }))));
  return h(Stack, { axis: "h", spacing: 10 }, children);
}

function ChooseParentButton(props) {
  var model = props.model;
  return h(Button, {
    style: "automatic", disabled: model.isChoosingParent, testID: model.prefix + "choose-repository-suggestion-parent-button",
    help: props.help, onPress: props.onPress
  }, h(Text, { size: 10, color: "secondary" }, props.title));
}

function Picker(props) {
  var model = props.model, on = props.on, prefix = model.prefix;
  var children = [];
  if (model.parentFolder != null) {
    children.push(h(Stack, { axis: "h", spacing: 5 },
      h(Text, {
        size: 10, color: "secondary", lineLimit: 1, truncation: "middle",
        testID: prefix + "conversation-repository-suggestion-parent", help: model.parentFolder
      }, "Suggestions from " + model.parentFolder),
      h(Spacer, { minLength: 0 }),
      h(ChooseParentButton, { model: model, title: "Change…", help: "Choose a different repository suggestion folder", onPress: on.chooseParent })));
  } else {
    children.push(h(Text, { size: 10, color: "secondary" }, "Choose a parent folder to find Git repositories."));
    children.push(h(ChooseParentButton, { model: model, title: "Choose suggestion folder…", help: "Choose a folder to find repository suggestions", onPress: on.chooseParent }));
  }
  children.push(h(TextField, {
    text: model.search, placeholder: model.placeholder, autoFocus: model.focusesSearch,
    testID: prefix + "conversation-repository-search", onChange: on.search,
    onSubmit: model.canSubmit ? on.submit : undefined,
    onArrow: model.repositories.length > 0 ? on.arrow : undefined
  }));
  if (model.listing === "recent") {
    children.push(h(Text, { size: 10, weight: "semibold", color: "secondary", testID: prefix + "conversation-repository-recent-header" }, "Recent"));
  }
  if (model.showsList) {
    if (model.repositories.length === 0) {
      children.push(h(Text, { size: 10, color: "secondary", testID: prefix + "conversation-repository-empty" }, "No matching repositories."));
    } else {
      children.push(h(Scroll, {
        spacing: 2, lazy: true, width: 280, height: model.listHeight,
        testID: prefix + "conversation-repository-list"
      }, model.repositories.map(function (repository, index) {
        var id = prefix + "conversation-repository-" + model.listing + "-" + repository.name;
        return h(Overlay, { key: repository.path, align: "trailing", offsetX: -6, revealOnHover: true },
          h(Button, { testID: id, help: "Add " + repository.name + " alongside the selected repositories", onPress: function () { on.select(repository.path); } },
            h(Panel, { fill: "accent", fillOpacity: index === model.highlighted ? 0.16 : 0, cornerRadius: 5, fillWidth: true, padding: 7 },
              // The spacer keeps the text clear of the buttons the hover reveals.
              h(Stack, { axis: "h", spacing: 0 },
                h(Stack, { axis: "v", spacing: 2, align: "leading" },
                  h(Text, { size: 11, weight: "medium" }, repository.name),
                  h(Text, { size: 9, color: "secondary", lineLimit: 1 }, repository.path)),
                h(Spacer, { minLength: 44 })))),
          h(Stack, { axis: "h", spacing: 6 },
            model.canReplace ? h(Button, {
              testID: id + "-replace", label: "Replace with " + repository.name,
              help: "Replace the selected repositories with " + repository.name,
              onPress: function () { on.replace(repository.path); }
            }, h(Icon, { name: "repeat", size: 11, weight: "semibold", color: "secondary" })) : null,
            h(Button, {
              testID: id + "-add", label: "Add " + repository.name,
              help: "Add " + repository.name + " alongside the selected repositories",
              onPress: function () { on.select(repository.path); }
            }, h(Icon, { name: "plus", size: 11, weight: "semibold", color: "secondary" }))));
      })));
    }
  }
  return h(Stack, { axis: "v", spacing: 8, align: "leading", group: true, width: 280, padding: 12, testID: prefix + "conversation-repository-picker" },
    children.map(keyed));
}

function Demo() {
  var chipsSample = Playhouse.props.repositoryChips, pickerSample = Playhouse.props.repositoryPicker;
  var chips = React.useState(chipsSample.chips);
  var open = React.useState(true);
  var search = React.useState(pickerSample.search);
  var highlighted = React.useState(pickerSample.highlighted);
  var last = React.useState("none");
  var chipsModel = Object.assign({}, chipsSample, { chips: chips[0] });
  var pickerModel = Object.assign({}, pickerSample, { search: search[0], highlighted: highlighted[0] });
  // A chip's actions name its worktree (key), or its repository's path.
  function named(path, list) {
    var found = list.filter(function (each) { return (each.key || each.path) === path; })[0];
    return found ? found.name : path;
  }
  var on = {
    edit: function (path) { last[1]("edit " + named(path, chips[0])); },
    remove: function (path) {
      chips[1](chips[0].filter(function (chip) { return (chip.key || chip.path) !== path; }));
      last[1]("remove " + named(path, chips[0]));
    },
    add: function () { open[1](!open[0]); last[1](open[0] ? "close picker" : "open picker"); },
    chooseParent: function () { last[1]("choose folder"); },
    search: function (text) { search[1](text); highlighted[1](0); last[1]("search " + text); },
    arrow: function (direction) {
      var count = pickerModel.repositories.length;
      highlighted[1](direction === "down" ? Math.min(highlighted[0] + 1, count - 1) : Math.max(highlighted[0] - 1, 0));
      last[1](direction);
    },
    submit: function () {
      var repository = pickerModel.repositories[highlighted[0]];
      open[1](false);
      last[1]("submit " + (repository ? repository.name : "saved"));
    },
    select: function (path) { open[1](false); last[1]("select " + named(path, pickerModel.repositories)); },
    replace: function (path) { open[1](false); last[1]("replace " + named(path, pickerModel.repositories)); }
  };
  return h(Stack, { axis: "v", spacing: 12, align: "leading" },
    h(Text, { size: 11, color: "secondary", testID: "js-last-action" }, "Last: ", last[0]),
    h(Chips, { model: chipsModel, on: on }),
    open[0] ? h(Panel, { fill: "window", fillOpacity: 1, cornerRadius: 10, stroke: "primary", strokeOpacity: 0.12, padding: 0, testID: "js-repository-picker-panel" },
      h(Picker, { model: pickerModel, on: on })) : null);
}

Playhouse.render(h(Demo));
