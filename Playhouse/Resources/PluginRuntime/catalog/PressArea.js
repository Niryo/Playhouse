// PressArea: a leading column that tells a click (onPress) from a press and
// hold (onLongPress). It takes every click on its children.
function Demo() {
  var clicks = React.useState(0);
  var held = React.useState(0);
  return h(Stack, { axis: "v", spacing: 10, align: "leading" },
    h(Panel, { fill: "panel", fillOpacity: 1, cornerRadius: 10, padding: 10, paddingX: 4, width: 260 },
      h(PressArea, {
        pointer: true, testID: "press-area-demo",
        onPress: function () { clicks[1](clicks[0] + 1); }, onLongPress: function () { held[1](held[0] + 1); }
      },
        h(Text, { size: 13, weight: "semibold" }, "Click or press and hold"),
        h(Text, { size: 10, color: "tertiary" }, "The whole column takes the press"))),
    h(Text, { size: 11, color: "secondary", testID: "press-area-count" }, "Clicked ", String(clicks[0]), " · held ", String(held[0])));
}

Playhouse.render(h(Demo));
