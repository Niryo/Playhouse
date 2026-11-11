// Scroll: a vertical scroll view around a leading column. `maxHeight` caps
// it and lets it shrink to its content; the common `height` fixes it. A lazy
// Scroll builds only the rows in view and raises onEndReached each time the
// end of its content scrolls into view, so its owner can append a page.
function Demo() {
  var rows = React.useState(4);
  var pages = React.useState(1);
  var paged = [];
  for (var row = 1; row <= pages[0] * 20; row++) {
    paged.push(h(Text, { key: String(row), size: 11, testID: "scroll-paged-row-" + row }, "Paged row ", String(row)));
  }
  var items = [];
  for (var index = 1; index <= rows[0]; index++) {
    items.push(h(Text, { key: String(index), size: 11, testID: "scroll-row-" + index }, "Row ", String(index)));
  }
  return h(Stack, { axis: "v", spacing: 10, align: "leading", width: 220 },
    h(Scroll, { spacing: 6, maxHeight: 120, testID: "scroll-demo" }, items),
    h(Button, { style: "borderless", testID: "scroll-add", onPress: function () { rows[1](rows[0] + 4); } },
      h(Text, { size: 11, weight: "medium", color: "accent" }, "Add 4 rows")),
    h(Text, { size: 11, color: "secondary", testID: "scroll-count" }, String(rows[0]), " rows"),
    h(Scroll, { spacing: 6, height: 120, lazy: true, testID: "scroll-paged", onEndReached: function () { pages[1](function (count) { return Math.min(count + 1, 5); }); } }, paged),
    h(Text, { size: 11, color: "secondary", testID: "scroll-pages" }, String(pages[0]), " pages loaded"));
}

Playhouse.render(h(Demo));
