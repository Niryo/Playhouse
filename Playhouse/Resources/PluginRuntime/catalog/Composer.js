// The conversation composer's box, composed in JavaScript from the same atoms
// the native ComposerView (Playhouse/App/ComposerView.swift) uses, from the
// same display model (Playhouse.props.composer). The notices, attached images,
// queued follow-ups and goal row above the box, and the schedule popover's
// content, stay native. The demo keeps the box's own state (the draft, the
// mode, the provider, the model and effort, the popovers) and a readout names
// the last action.

function SkillsButton(props) {
  return h(Button, { testID: props.testID, label: "Skills", help: "Skills", onPress: props.onPress },
    h(Icon, { name: "sparkles" }));
}

function menuItem(prefix, item) {
  return { id: item.id, title: item.title, help: item.help, testID: prefix + item.testID, checked: item.checked, icon: item.checked ? undefined : item.icon };
}

function AttachButton(props) {
  var model = props.model, attach = model.attach;
  return h(Button, { disabled: attach.disabled, testID: model.prefix + "composer-attach-button", label: "Attach files", help: attach.help, onPress: props.on.attach },
    h(Panel, { fillOpacity: 0, cornerRadius: 13, width: 26, height: 26, padding: 0 },
      h(Icon, { name: "paperclip", size: 13, weight: "medium", color: "secondary" })));
}

// The Plan or Goal button: its icon, on an orange highlight while the mode is on.
function ModeToggle(props) {
  var toggle = props.toggle;
  return h(Button, { testID: props.testID, label: props.label, value: toggle.on ? "On" : "Off", help: toggle.help, onPress: props.onPress },
    h(Panel, { fill: "orange", fillOpacity: toggle.on ? 0.18 : 0, cornerRadius: 13, width: 26, height: 26, padding: 0 }, props.icon(toggle.on ? "orange" : "secondary")));
}

function ModeToggles(props) {
  var model = props.model, on = props.on, prefix = model.prefix;
  return [
    h(ModeToggle, {
      key: "plan", toggle: model.plan, testID: prefix + "conversation-plan-button", label: "Plan mode", onPress: on.togglePlan,
      icon: function (color) { return h(Icon, { name: "lightbulb.max", size: 13, weight: "medium", color: color }); }
    }),
    model.optimizedContext != null ? h(ModeToggle, {
      key: "optimized", toggle: model.optimizedContext, testID: prefix + "conversation-optimized-context-button", label: "Optimized context",
      onPress: on.toggleOptimizedContext,
      icon: function (color) { return h(Icon, { name: "gauge.open.with.lines.needle.33percent.and.arrowtriangle.from.0percent.to.50percent", size: 14, weight: "medium", color: color }); }
    }) : null,
    model.goal != null ? h(ModeToggle, {
      key: "goal", toggle: model.goal, testID: prefix + "conversation-goal-button", label: "Goal", onPress: on.toggleGoal,
      icon: function (color) { return h(Icon, { asset: "GoalIcon", color: color, width: 15, height: 15 }); }
    }) : null
  ];
}

function StartImplementing(props) {
  var model = props.model, start = model.startImplementing, prefix = model.prefix;
  return [
    h(Button, {
      key: "start", disabled: start.disabled, testID: prefix + "start-implementing-button", value: start.value,
      hint: "Switches to Code mode and starts implementing this plan", help: start.help, onPress: props.on.startImplementing
    }, h(Panel, { fill: "accent", fillOpacity: 1, cornerRadius: 15.5, height: 31, padding: 0, paddingX: 11 },
      h(Text, { size: 12, weight: "semibold", color: "white" }, "Start Implementing"))),
    start.unavailableReason != null ? h(Button, {
      key: "reason", disabled: start.reasonDisabled, testID: prefix + "start-implementing-unavailable-reason", label: "No repository",
      value: start.unavailableReason, hint: "Opens the repository picker", help: start.unavailableReason, onPress: props.on.showRepositoryPicker
    }, h(Label, { text: "No repository", icon: "exclamationmark.triangle.fill", size: 11, weight: "semibold", color: start.reasonColor })) : null
  ];
}

function ProviderMenu(props) {
  var model = props.model, provider = model.provider, prefix = model.prefix;
  return h(Menu, {
    color: "secondary", text: provider.title, textSize: 12, textWeight: "medium", indicator: true, disabled: !provider.enabled,
    items: [provider.items.map(function (item) { return menuItem(prefix, item); })],
    testID: prefix + "conversation-provider-menu", label: provider.label, value: provider.value, help: provider.help,
    onMenu: props.on.provider
  });
}

function ModelPicker(props) {
  var model = props.model, picker = model.model, prefix = model.prefix, on = props.on;
  var effortTitle = picker.effortChoices.filter(function (choice) { return choice.value === picker.selectedEffort; })[0];
  return h(Popover, { isPresented: picker.open, arrowEdge: "top", width: 320, inset: 0, spacing: 0, testID: prefix + "model-picker-popover", onDismiss: on.dismissModelPicker },
    h(Button, {
      testID: prefix + "model-picker-menu", label: picker.label, value: picker.name,
      help: "Choose a model and reasoning effort", opacity: 0.82, onPress: on.toggleModelPicker
    }, h(Stack, { axis: "h", spacing: 7 },
      h(Text, { size: 12, weight: "medium" }, picker.name),
      h(Text, { size: 12, weight: "medium", color: "secondary" }, picker.effort),
      h(Icon, { name: "chevron.down", size: 9, weight: "semibold", color: "tertiary" }))),
    h(Stack, { axis: "v", spacing: 0, align: "leading", padding: 13, paddingX: 5 },
      picker.models.map(function (option) {
        return h(Button, {
          key: option.id, testID: prefix + option.testID, value: option.checked ? "Selected" : "Not selected", help: option.help,
          onPress: function () { on.selectModel(option.id); }
        }, h(Stack, { axis: "h", minHeight: 32, fillWidth: true },
          h(Text, {}, option.title),
          h(Spacer),
          option.checked ? h(Icon, { name: "checkmark", size: 12, weight: "semibold", testID: prefix + option.testID + "-checked" }) : null));
      }),
      h(Divider, { paddingY: 8 }),
      h(Text, { size: 14, weight: "medium", color: "accent", testID: prefix + "selected-model-effort" }, effortTitle ? effortTitle.label : picker.selectedEffort),
      h(StepSlider, { options: picker.effortChoices, selected: picker.selectedEffort, testID: prefix + "model-effort-slider", label: "Model effort", onChange: on.selectEffort })));
}

function ScheduleButton(props) {
  var model = props.model, schedule = model.schedule, prefix = model.prefix, on = props.on;
  return h(Popover, { isPresented: schedule.open, arrowEdge: "top", inset: 0, spacing: 0, testID: prefix + "schedule-popover", onDismiss: on.dismissSchedule },
    h(Button, {
      testID: prefix + "schedule-task-button", label: "Schedule", value: schedule.on ? "On" : "Off", help: schedule.help, onPress: on.toggleSchedule
    }, h(Panel, { fill: "accent", fillOpacity: schedule.on ? 0.14 : 0, cornerRadius: 13, width: 26, height: 26, padding: 0 },
      h(Icon, { name: schedule.on ? "clock.fill" : "clock", size: 12, weight: "medium", color: schedule.on ? "accent" : "secondary" }))),
    h(Text, { size: 12, padding: 12, testID: prefix + "schedule-hint" }, "The schedule hint stays native."));
}

function primaryIcon(name, fill, opacity, size, radius, dimmed) {
  return h(Panel, { fill: fill, fillOpacity: opacity, cornerRadius: radius, width: 31, height: 31, padding: 0, opacity: dimmed ? 0.45 : 1 },
    h(Icon, { name: name, size: size, weight: "bold", color: "white" }));
}

function Primary(props) {
  var model = props.model, primary = model.primary;
  var label;
  if (primary.kind === "stop") label = primaryIcon("stop.fill", "primary", 0.72, 11, 9, false);
  else if (primary.kind === "continue") label = primaryIcon("play.fill", "accent", 1, 11, 9, false);
  else if (primary.kind === "schedule") {
    label = h(Panel, { fill: "accent", fillOpacity: 1, cornerRadius: 15.5, height: 31, padding: 0, paddingX: 12, opacity: primary.disabled ? 0.45 : 1 },
      h(Label, { text: "Schedule", icon: "clock", size: 12, weight: "semibold", color: "white" }));
  } else label = primaryIcon("arrow.up", "accent", 1, 13, 15.5, primary.disabled);
  return h(Button, {
    disabled: primary.disabled, testID: model.prefix + primary.testID, label: primary.label,
    value: primary.value === "" ? undefined : primary.value, help: primary.help, onPress: props.on.primary
  }, label);
}

// The actions, then the provider, model and send at the trailing edge. Where one row is too
// narrow for both, the native box moves the second group to a row of its own; this copy is
// always shown at the catalog's width, where they share a row.
function Toolbar(props) {
  var model = props.model, on = props.on;
  return h(Stack, { axis: "h", spacing: 12 },
    h(Stack, { axis: "h", spacing: 12 },
      h(AttachButton, { model: model, on: on }),
      model.skills ? h(SkillsButton, { testID: model.prefix + "open-skills-button", onPress: on.openSkills }) : null,
      h(ModeToggles, { model: model, on: on }),
      model.startImplementing != null ? h(StartImplementing, { model: model, on: on }) : null),
    h(Spacer, { minLength: 0 }),
    h(Stack, { axis: "h", spacing: 12 },
      h(ProviderMenu, { model: model, on: on }),
      h(ModelPicker, { model: model, on: on }),
      model.schedule != null ? h(ScheduleButton, { model: model, on: on }) : null,
      h(Primary, { model: model, on: on })));
}

function Composer(props) {
  var model = props.model, on = props.on;
  return h(Panel, { spacing: 10, fill: "panel", fillOpacity: 1, cornerRadius: 21, stroke: "primary", strokeOpacity: 0.1, padding: 13 },
    h(Editor, {
      text: model.draft, placeholder: model.placeholder, placeholderTestID: model.prefix + "composer-placeholder",
      enabled: model.enabled, autofocus: model.autofocus, focused: model.focused, focusRequest: model.focusRequest,
      inputTestID: model.prefix + "message-composer", inputLabel: "Message",
      testID: model.prefix + "message-composer-scroll-view", hint: model.editorHelp,
      onChange: on.change, onSubmit: on.submit, onSteerSubmit: on.steer, onFocusChange: on.focusChange
    }),
    h(Toolbar, { model: model, on: on }));
}

function Demo() {
  var sample = Playhouse.props.composer;
  var draft = React.useState("");
  var mode = React.useState("default");
  var provider = React.useState("claude");
  var modelID = React.useState("claude-sonnet-5-5");
  var effort = React.useState("medium");
  var pickerOpen = React.useState(false);
  var scheduleOpen = React.useState(false);
  var last = React.useState("none");
  var optimized = React.useState(false);

  var picked = sample.model.models.filter(function (option) { return option.id === modelID[0]; })[0];
  var effortChoice = sample.model.effortChoices.filter(function (choice) { return choice.value === effort[0]; })[0];
  var goal = mode[0] === "goal";
  var plan = mode[0] === "plan";
  var codex = provider[0] === "codex";
  var empty = draft[0].trim() === "";
  var title = codex ? "Codex" : "Claude";
  var model = Object.assign({}, sample, {
    draft: draft[0],
    placeholder: goal ? "Set a goal to keep pursuing" : sample.placeholder,
    plan: Object.assign({}, sample.plan, { on: plan }),
    optimizedContext: Object.assign({}, sample.optimizedContext, { on: optimized[0] }),
    goal: Object.assign({}, sample.goal, { on: goal }),
    startImplementing: plan ? sample.startImplementing : undefined,
    provider: Object.assign({}, sample.provider, {
      title: title, value: provider[0], label: "Provider: " + title,
      items: sample.provider.items.map(function (item) { return Object.assign({}, item, { checked: item.id === provider[0] }); })
    }),
    model: Object.assign({}, sample.model, {
      name: picked.title, effort: effortChoice.label, label: "Model: " + picked.title + ", effort: " + effortChoice.label,
      open: pickerOpen[0], selectedEffort: effort[0],
      models: sample.model.models.map(function (option) { return Object.assign({}, option, { checked: option.id === modelID[0] }); })
    }),
    schedule: Object.assign({}, sample.schedule, { open: scheduleOpen[0] }),
    primary: Object.assign({}, sample.primary, { disabled: empty && !goal })
  });
  var on = {
    change: function (text) { draft[1](text); last[1]("edit"); },
    submit: function () { last[1]("submit " + draft[0]); draft[1](""); },
    steer: function () { last[1]("steer"); },
    focusChange: function () {},
    openSkills: function () { last[1]("skills"); },
    attach: function () { last[1]("attach"); },
    togglePlan: function () { mode[1](plan ? "default" : "plan"); last[1](plan ? "plan off" : "plan on"); },
    toggleOptimizedContext: function () { optimized[1](!optimized[0]); last[1](optimized[0] ? "optimized context off" : "optimized context on"); },
    toggleGoal: function () {
      mode[1](goal ? "default" : "goal");
      if (!goal) draft[1]("");
      last[1](goal ? "goal off" : "goal on");
    },
    startImplementing: function () { mode[1]("default"); last[1]("start implementing"); },
    showRepositoryPicker: function () { last[1]("repository picker"); },
    provider: function (id) { provider[1](id); last[1]("provider " + id); },
    toggleModelPicker: function () { pickerOpen[1](!pickerOpen[0]); last[1](pickerOpen[0] ? "model picker closed" : "model picker open"); },
    dismissModelPicker: function () { pickerOpen[1](false); last[1]("model picker closed"); },
    selectModel: function (id) { modelID[1](id); last[1]("model " + id); },
    selectEffort: function (value) { effort[1](value); last[1]("effort " + value); },
    toggleSchedule: function () { scheduleOpen[1](!scheduleOpen[0]); last[1](scheduleOpen[0] ? "schedule closed" : "schedule open"); },
    dismissSchedule: function () { scheduleOpen[1](false); last[1]("schedule closed"); },
    primary: function () { last[1]("send " + draft[0]); draft[1](""); }
  };
  return h(Stack, { axis: "v", spacing: 12, align: "leading" },
    h(Text, { size: 11, color: "secondary", testID: model.prefix + "js-last-action" }, "Last: ", last[0]),
    h(Stack, { axis: "v", width: 764 }, h(Composer, { model: model, on: on })));
}

Playhouse.render(h(Demo));
