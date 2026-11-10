// TextField: a rounded one-line field. It is controlled: `text` is what it
// shows, and every edit calls onChange with the new text.
function Demo() {
  var text = React.useState("");
  return h(Stack, { axis: "v", spacing: 10, align: "leading" },
    h(TextField, { text: text[0], placeholder: "Search skills", width: 200, testID: "text-field-demo", onChange: text[1] }),
    h(Button, { style: "borderless", testID: "text-field-clear", onPress: function () { text[1](""); } },
      h(Text, { size: 11, weight: "medium", color: "accent" }, "Clear")),
    h(Text, { size: 11, color: "secondary", testID: "text-field-value" }, "Text: ", text[0]));
}

Playhouse.render(h(Demo));
