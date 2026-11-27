// ResizeHandle: an invisible strip that drags a border, the way the terminal
// panel's and the chat sidebar's edges resize them. The resize cursor shows
// over it and stays for the whole drag; onDrag gets the translation along its
// axis since the drag began, and onDragEnd follows the last one. Give it a
// width (its grab area), and draw the border itself with a Stack: here a
// 1-point line in a layered Stack, the handle centered over it.
function Demo() {
  var width = React.useState(200);
  var start = React.useState(null);
  var ended = React.useState(0);
  function drag(translation) {
    var from = start[0] === null ? width[0] : start[0];
    if (start[0] === null) start[1](from);
    width[1](Math.max(120, Math.min(320, from + Number(translation))));
  }
  return h(Stack, { axis: "v", spacing: 10, align: "leading" },
    h(Stack, { axis: "h", spacing: 0, height: 80 },
      h(Stack, { fill: "accent", fillOpacity: 0.12, width: width[0], fillHeight: true, testID: "resize-handle-pane" },
        h(Text, { size: 11, color: "secondary" }, "Drag the right edge")),
      h(Stack, { axis: "z", width: 1, fillHeight: true },
        h(Stack, { fill: "primary", fillOpacity: 0.12, width: 1, fillHeight: true, decorative: true }),
        h(ResizeHandle, { width: 9, fillHeight: true, testID: "resize-handle-demo", label: "Resize pane", value: Math.round(width[0]) + " points",
          onDrag: drag, onDragEnd: function () { start[1](null); ended[1](function (count) { return count + 1; }); } }))),
    h(Text, { size: 11, color: "secondary", testID: "resize-handle-width" }, "Width: ", String(Math.round(width[0]))),
    h(Text, { size: 11, color: "secondary", testID: "resize-handle-ended" }, "Drags ended: ", String(ended[0])));
}

Playhouse.render(h(Demo));
