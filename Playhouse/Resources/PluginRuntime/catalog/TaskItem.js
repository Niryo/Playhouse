// The task item, composed in JavaScript from the same atoms the native
// TaskItemView (Playhouse/App/TaskItemView.swift) uses, from the same
// display model (Playhouse.props.task). Below it, controls whose state
// changes show which nodes each commit touches. The card's bottom row holds
// its task card plugins (the built-in pull request controls and mode pill),
// which are plugins of their own, not part of this composite.

function shortDuration(seconds) {
  if (seconds < 60) return Math.floor(seconds) + "s";
  var minutes = Math.floor(seconds / 60);
  if (minutes < 60) return minutes + "m";
  var hours = Math.floor(minutes / 60);
  if (hours < 24) return hours + "h" + (minutes % 60 === 0 ? "" : " " + (minutes % 60) + "m");
  var days = Math.floor(hours / 24);
  return days + "d" + (hours % 24 === 0 ? "" : " " + (hours % 24) + "h");
}

function workingDuration(task, now) {
  var active = task.workingSince == null ? 0 : Math.max(0, now / 1000 - task.workingSince);
  var text = shortDuration(active);
  return task.workedSeconds > 0 ? text + " (" + shortDuration(task.workedSeconds + active) + " total)" : text;
}

function WorkingTime(props) {
  var now = React.useState(Date.now());
  React.useEffect(function () {
    var timer = setInterval(function () { now[1](Date.now()); }, 1000);
    return function () { clearInterval(timer); };
  }, []);
  return h(Text, { size: 10, color: "tertiary", passThrough: true, testID: "task-working-duration-" + props.task.id }, workingDuration(props.task, now[0]));
}

function menuItems(task) {
  var items = [];
  if (task.canMoveToDone) items.push({ id: "done", title: "Move to Done", icon: "checkmark.circle", testID: "move-task-to-done-menu-item" });
  if (task.canMoveToReview) items.push({ id: "review", title: "Move to Review", icon: "eye", testID: "move-task-to-review-menu-item" });
  items.push({ id: "rename", title: "Rename…", icon: "pencil", testID: "rename-task-menu-item" });
  items.push({ id: "stats", title: "Token Stats…", icon: "chart.bar", testID: "token-stats-task-menu-item" });
  items.push({ id: "delete", title: "Delete Task", icon: "trash", destructive: true, testID: "delete-task-menu-item" });
  return items;
}

function TaskItem(props) {
  var task = props.task, on = props.on, id = task.id;
  var progress = task.progress;
  return h(Card, {
    menu: menuItems(task), meter: task.cpu ? task.cpu.fraction : undefined,
    meterLabel: task.cpu ? task.cpu.label : undefined, meterTestID: "task-cpu-usage-bar-" + id,
    testID: "task-card-" + id, label: task.title, hint: "Open task", fillWidth: true, padding: 14,
    onPress: on.open, onMenu: on.menu
  },
    h(Stack, { axis: "v", spacing: 10, align: "leading" },
      h(Stack, { axis: "h", spacing: 6, testID: "task-title-" + id, passThrough: true },
        task.titleSpinner ? h(Spinner) : null,
        h(Text, { size: 13, weight: "semibold", color: "text", tracking: 0.35, lineSpacing: 2, wrap: true }, task.title)),
      progress ? h(Stack, {
        axis: "h", spacing: 6, align: "top", group: true,
        testID: "task-progress-report-" + id,
        label: [progress.label, progress.detail].filter(Boolean).join(", "),
        value: "Progress icon: " + progress.symbol, fillWidth: true, passThrough: true
      },
        h(Icon, { name: progress.symbol, size: 10, weight: "semibold", color: "accent", testID: "task-progress-icon-" + id, label: progress.symbol }),
        h(Stack, { axis: "v", spacing: 2, align: "leading" },
          h(Text, { size: 10, weight: "semibold", color: "text", testID: "task-progress-label-" + id }, progress.label),
          progress.detail ? h(Text, { size: 10, color: "secondary", lineLimit: 2, testID: "task-progress-detail-" + id }, progress.detail) : null)) : null,
      task.schedule ? h(Label, { text: task.schedule, icon: "clock", size: 10, weight: "medium", color: "accent", testID: "task-schedule-badge-" + id, passThrough: true }) : null,
      task.statusMessage ? h(Text, {
        size: 10, color: task.statusIsBlocked ? "red" : "secondary", lineLimit: 3,
        testID: "task-status-message-" + id, fillWidth: true, passThrough: true
      }, task.statusMessage) : null,
      // One row of clock, time and counter, as in TaskItemView.
      h(Stack, { axis: "h", spacing: 6 },
        h(Icon, { name: "clock", size: 10, color: "tertiary", passThrough: true }),
        task.isWorking ? h(WorkingTime, { task: task }) : h(Text, { size: 10, color: "tertiary", testID: "task-created-time-" + id, passThrough: true }, task.createdText),
        task.tokens ? h(Button, {
          emphasis: 6, overhang: true,
          testID: "task-token-usage-counter-" + id, label: task.tokens.description, hint: "Open Token Stats",
          help: task.tokens.description + ". Click for Token Stats", paddingX: 4,
          onPress: on.showTokenStats
        }, h(Text, { size: 10, weight: "medium", design: "monospaced", color: task.tokens.color, numeric: true }, task.tokens.compact)) : null)));
}

function Example() {
  var sample = Playhouse.props;
  var blocked = React.useState(false);
  var opened = React.useState(0);
  var lastAction = React.useState("none");

  var task = Object.assign({}, sample.task, {
    statusMessage: blocked[0] ? sample.blockedStatusMessage : sample.task.statusMessage,
    statusIsBlocked: blocked[0]
  });
  var on = {
    open: function () { opened[1](function (count) { return count + 1; }); },
    menu: function (item) { lastAction[1]("menu " + item); },
    showTokenStats: function () { lastAction[1]("token stats"); }
  };

  return h(Stack, { axis: "v", spacing: 12, align: "leading" },
    h(TaskItem, { task: task, on: on }),
    h(Stack, { axis: "h", spacing: 8 },
      h(Button, { style: "borderless", testID: "js-toggle-blocked", onPress: function () { blocked[1](!blocked[0]); } },
        h(Text, { size: 11, weight: "medium", color: "accent" }, blocked[0] ? "Unblock" : "Block")),
      h(Text, { size: 11, color: "secondary", testID: "js-opened-count" }, "Opened ", String(opened[0]), " times"),
      h(Text, { size: 11, color: "secondary", testID: "js-last-action" }, "Last: ", lastAction[0])));
}

Playhouse.render(h(Example));
