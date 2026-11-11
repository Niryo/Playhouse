// A board column's frame, composed in JavaScript from the same atoms the
// native KanbanColumnSection (Playhouse/App/KanbanColumnSection.swift) uses,
// from the same display models (Playhouse.props.kanbanColumns). The cards a
// column holds are native and not part of this example. Below the columns, a
// readout shows the Backlog's Add button running its JavaScript handler.

function Header(props) {
  var model = props.model, prefix = model.idPrefix;
  return h(Stack, { axis: "h", spacing: 9, paddingX: 3 },
    h(Panel, { fill: model.accent, fillOpacity: 1, cornerRadius: 4, width: 8, height: 8 }),
    h(Text, { size: 11, weight: "bold", design: "rounded", color: "primary", tracking: 0.65, testID: prefix + "column-heading-" + model.key }, model.title),
    h(Spacer, { minLength: 4 }),
    h(Panel, { fill: model.tint, fillOpacity: model.tint ? 0.16 : 0.055, cornerRadius: 100, padding: 3, paddingX: 4 },
      h(Text, { size: 11, weight: "semibold", design: "rounded", color: model.tint || "secondary", testID: prefix + "column-count-" + model.key }, model.count)),
    model.addHelp ? h(Button, {
      style: "bordered", controlSize: "small", testID: prefix + "add-backlog-task-button",
      label: model.addHelp, help: model.addHelp, onPress: props.onAdd
    }, h(Icon, { name: "plus", size: 11, weight: "semibold" })) : null);
}

function EmptyState(props) {
  var model = props.model, empty = model.empty;
  return h(Panel, {
    spacing: 9, fillOpacity: 0, cornerRadius: 12, stroke: "primary", strokeOpacity: 0.10, dash: [5, 4], align: "center", combine: true,
    minHeight: 124, fillWidth: true, testID: model.idPrefix + "empty-state-" + model.key
  },
    h(Icon, { name: empty.icon, size: 18, weight: "regular", color: model.accent }),
    h(Text, { size: 12, weight: "medium", color: "secondary" }, empty.title),
    h(Text, { size: 11, color: "tertiary" }, empty.hint));
}

// A tinted column (Waiting Response) lays a second Panel in its tint, a soft
// wash and hairline border, over the first.
function KanbanColumn(props) {
  var model = props.model, tint = model.tint;
  var content = [
    h(Header, { key: "header", model: model, onAdd: props.onAdd }),
    model.notice ? h(Label, {
      key: "notice", text: model.notice, icon: "hand.raised.fill", size: 10, weight: "semibold", color: "red",
      paddingX: 3, testID: model.idPrefix + "blocked-waiting-indicator"
    }) : null,
    model.empty ? h(EmptyState, { key: "empty", model: model }) : null];
  if (tint) {
    return h(Panel, {
      fill: "panel", fillOpacity: 0.78, cornerRadius: 16,
      minHeight: props.minHeight, fillWidth: true, testID: model.idPrefix + "column-" + model.key
    },
      h(Panel, {
        spacing: 13, fill: tint, fillOpacity: 0.12, cornerRadius: 16, stroke: tint, strokeOpacity: 0.34,
        minHeight: props.minHeight, fillWidth: true, padding: 14
      }, content));
  }
  return h(Panel, {
    spacing: 13, fill: "panel", fillOpacity: 0.78, cornerRadius: 16, stroke: "primary", strokeOpacity: 0.075,
    minHeight: props.minHeight, fillWidth: true, padding: 14, testID: model.idPrefix + "column-" + model.key
  }, content);
}

function Example() {
  var lastAction = React.useState("none");
  var columns = Playhouse.props.kanbanColumns.map(function (model) {
    return h(Stack, { key: model.key, axis: "v", width: 264 },
      h(KanbanColumn, { model: model, minHeight: 170, onAdd: function () { lastAction[1]("add"); } }));
  });
  return h(Stack, { axis: "v", spacing: 12, align: "leading" },
    columns,
    h(Text, { size: 11, color: "secondary", testID: "js-last-action" }, "Last: ", lastAction[0]));
}

Playhouse.render(h(Example));
