// Scroll: a vertical scroll view around a leading column. `maxHeight` caps
// it and lets it shrink to its content; the common `height` fixes it.
function Demo() {
  var rows = React.useState(4);
  var items = [];
  for (var index = 1; index <= rows[0]; index++) {
    items.push(h(Text, { key: String(index), size: 11, testID: "scroll-row-" + index }, "Row ", String(index)));
  }
  return h(Stack, { axis: "v", spacing: 10, align: "leading", width: 220 },
    h(Scroll, { spacing: 6, maxHeight: 120, testID: "scroll-demo" }, items),
    h(Button, { style: "borderless", testID: "scroll-add", onPress: function () { rows[1](rows[0] + 4); } },
      h(Text, { size: 11, weight: "medium", color: "accent" }, "Add 4 rows")),
    h(Text, { size: 11, color: "secondary", testID: "scroll-count" }, String(rows[0]), " rows"));
}

Playhouse.render(h(Demo));
