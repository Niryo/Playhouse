// The board's Done archive, composed in JavaScript from the same atoms the
// native DoneArchivePanel (Playhouse/App/DoneArchiveView.swift) uses, from
// the same display model (Playhouse.props.doneArchive), and presented the way
// the board presents it: the header's archive button toggles a SidePanel atom
// sliding in over the trailing edge of the view below it. The search filters
// the sample rows by title, as the board's search narrows its own. A readout
// shows each control running its JavaScript handler.

function PullRequests(props) {
  var row = props.row, prs = row.pullRequests, prefix = props.prefix;
  var create = prs.create;
  // Several pull requests keep their numbers whole; the title truncates instead.
  return h(Stack, { axis: "h", spacing: 5, fixedSize: true },
    create ? h(Button, {
      style: "borderless", emphasis: 4, disabled: create.busy, width: 30, height: 30,
      testID: prefix + "done-archive-create-pr-" + row.id, label: create.label, help: create.help,
      onPress: function () { props.onCreate(row); }
    }, create.busy ? h(Spinner, { size: "mini" }) : h(Text, { size: 10, weight: "semibold" }, create.title)) : null,
    prs.links.map(function (link) {
      return h(Link, {
        key: link.url, url: link.url, emphasis: 5, minWidth: 30, minHeight: 30,
        testID: prefix + "done-archive-pr-link-" + row.id + "-" + link.number, value: link.state, help: link.repository + " · " + link.state
      }, h(Text, { size: 10, weight: "semibold", design: "monospaced" }, "#" + link.number));
    }));
}

function Row(props) {
  var row = props.row, prefix = props.prefix;
  return h(Stack, { axis: "h", spacing: 0, paddingX: 10 },
    h(Button, {
      testID: prefix + "done-archive-task-" + row.id, help: "Open task: " + row.title, fillWidth: true,
      onPress: function () { props.onOpen(row); }
    },
      h(Stack, { axis: "h", spacing: 10, fillWidth: true, padding: 10 },
        h(Icon, { name: "checkmark.circle.fill", color: props.accent }),
        h(Stack, { axis: "v", spacing: 3, align: "leading" },
          h(Text, { size: 12, weight: "medium", lineLimit: 1 }, row.title),
          h(Text, { size: 10, color: "secondary" }, row.date)),
        h(Spacer, { minLength: 0 }))),
    row.pullRequests ? h(PullRequests, { row: row, prefix: prefix, onCreate: props.onCreate }) : null,
    row.pullRequests ? h(Stack, { width: 10 }) : null);
}

function DoneArchivePanel(props) {
  var model = props.model, prefix = model.prefix, actions = props.actions;
  return h(Stack, { axis: "v", spacing: 0 },
    h(Stack, { axis: "h", padding: 16 },
      h(Text, { size: 14, weight: "semibold", testID: prefix + "done-archive-title" }, "Done tasks"),
      h(Spacer),
      h(Button, { testID: prefix + "close-done-archive-button", label: "Close done tasks", help: "Close done tasks", onPress: actions.close },
        h(Icon, { name: "xmark" }))),
    h(Divider),
    h(Stack, { axis: "v", fillWidth: true, padding: 12 },
      h(Stack, { axis: "h", spacing: 8, fill: "primary", fillOpacity: 0.045, cornerRadius: 9, fillWidth: true, padding: 10 },
        h(Icon, { name: "magnifyingglass", color: "secondary" }),
        h(TextField, { text: model.search, placeholder: "Search tasks and conversations", style: "plain", testID: prefix + "done-archive-search", onChange: actions.search }),
        model.search ? h(Button, {
          testID: prefix + "clear-archive-search-button", label: "Clear archive search", help: "Clear archive search",
          onPress: function () { actions.search(""); }
        }, h(Icon, { name: "xmark.circle.fill", color: "secondary" })) : null)),
    model.emptyMessage != null
      ? h(Stack, { axis: "v", align: "center", fillOpacity: 0, fillWidth: true },
          h(Spacer),
          h(Text, { size: 12, color: "secondary", testID: prefix + "done-archive-empty-state" }, model.emptyMessage),
          h(Spacer))
      : h(Scroll, { spacing: 5, lazy: true, testID: prefix + "done-archive-list", value: model.loadedValue, onEndReached: actions.loadMore },
          model.rows.map(function (row) {
            return h(Row, { key: row.id, row: row, prefix: prefix, accent: model.accent, onOpen: actions.open, onCreate: actions.createPullRequests });
          }),
          model.loading ? h(Stack, { axis: "h", fillWidth: true, padding: 12 }, h(Spacer), h(Spinner), h(Spacer)) : null));
}

// The board header's archive button.
function DoneArchiveButton(props) {
  return h(Button, { style: "bordered", testID: props.testID, label: "Done tasks", help: "Browse completed tasks", onPress: props.onPress },
    h(Icon, { name: "archivebox", size: 14, weight: "semibold", width: 30, height: 30 }));
}

function Example() {
  var sample = Playhouse.props.doneArchive;
  var open = React.useState(true);
  var search = React.useState("");
  var lastAction = React.useState("none");
  var reachedEnd = React.useState(false);
  var query = search[0].trim().toLowerCase();
  var rows = query ? sample.rows.filter(function (row) { return row.title.toLowerCase().indexOf(query) >= 0; }) : sample.rows;
  var model = Object.assign({}, sample, {
    search: search[0], rows: rows, emptyMessage: rows.length ? null : "No matching tasks"
  });
  var actions = {
    close: function () { open[1](false); lastAction[1]("close"); },
    search: function (text) { search[1](text); lastAction[1]("search " + text); },
    open: function (row) { open[1](false); lastAction[1]("open " + row.title); },
    createPullRequests: function (row) { lastAction[1]("create pr " + row.title); },
    loadMore: function () { reachedEnd[1](true); }
  };
  return h(Stack, { axis: "v", spacing: 12, align: "leading" },
    h(Stack, { axis: "h", spacing: 8 },
      h(Text, { size: 11, color: "secondary" }, "Board header button"),
      h(DoneArchiveButton, { testID: "done-archive-button", onPress: function () { open[1](!open[0]); lastAction[1](open[0] ? "toggle closed" : "toggle open"); } }),
      h(Text, { size: 11, color: "secondary", testID: "js-last-action" }, "Last: ", lastAction[0]),
      h(Text, { size: 11, color: "secondary", testID: "js-end-reached" }, reachedEnd[0] ? "End reached" : "End not reached")),
    h(SidePanel, { isPresented: open[0], width: 340, testID: "done-archive-panel" },
      h(Stack, { axis: "v", spacing: 0, fill: "window", cornerRadius: 10, width: 560, height: 460, group: true, testID: "done-archive-board" },
        h(Text, { size: 12, color: "tertiary" }, "The board")),
      h(DoneArchivePanel, { model: model, actions: actions })));
}

Playhouse.render(h(Example));
