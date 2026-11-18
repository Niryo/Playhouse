// TextField: a rounded one-line field. It is controlled: `text` is what it
// shows, and every edit calls onChange with the new text. With handlers,
// Return calls onSubmit and the Up and Down arrows call onArrow. `style:
// "plain"` drops the border, for a field on a decorated Stack (the Done
// archive's search).
function Demo() {
  var text = React.useState("");
  var keys = React.useState("none");
  var plain = React.useState("");
  return h(Stack, { axis: "v", spacing: 10, align: "leading" },
    h(TextField, {
      text: text[0], placeholder: "Search skills", width: 200, testID: "text-field-demo", onChange: text[1],
      onSubmit: function () { keys[1]("return"); }, onArrow: function (direction) { keys[1](direction); }
    }),
    h(Button, { style: "borderless", testID: "text-field-clear", onPress: function () { text[1](""); } },
      h(Text, { size: 11, weight: "medium", color: "accent" }, "Clear")),
    h(Text, { size: 11, color: "secondary", testID: "text-field-value" }, "Text: ", text[0]),
    h(Text, { size: 11, color: "secondary", testID: "text-field-key" }, "Key: ", keys[0]),
    h(Stack, { axis: "h", spacing: 8, fill: "primary", fillOpacity: 0.045, cornerRadius: 9, padding: 10, width: 240, group: true, testID: "text-field-plain-box" },
      h(Icon, { name: "magnifyingglass", color: "secondary" }),
      h(TextField, { text: plain[0], placeholder: "Plain field", style: "plain", testID: "text-field-plain", onChange: plain[1] })),
    h(Text, { size: 11, color: "secondary", testID: "text-field-plain-value" }, "Plain: ", plain[0]));
}

Playhouse.render(h(Demo));
