// Disclosure: a title button that collapses and expands its children. It is
// controlled: `collapsed` is what it shows, and onToggle (no value) asks the owner to flip it.
function Demo() {
  var collapsed = React.useState(false);
  return h(Stack, { axis: "v", spacing: 10, align: "leading", width: 220 },
    h(Disclosure, {
      title: "Section", collapsed: collapsed[0], testID: "disclosure-demo", toggleTestID: "disclosure-toggle",
      onToggle: function () { collapsed[1](!collapsed[0]); }
    },
      h(Text, { size: 11, testID: "disclosure-first" }, "First child"),
      h(Text, { size: 11, color: "secondary" }, "Second child")),
    h(Text, { size: 11, color: "secondary", testID: "disclosure-state" }, collapsed[0] ? "Collapsed" : "Expanded"));
}

Playhouse.render(h(Demo));
