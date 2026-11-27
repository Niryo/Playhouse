// TextField: a rounded one-line field. It is controlled: `text` is what it
// shows, and every edit calls onChange with the new text. With handlers,
// Return calls onSubmit and the Up and Down arrows call onArrow. `style:
// "plain"` drops the border, for a field on a decorated Stack (the Done
// archive's search). `secure` hides what is typed, `multiline` wraps and
// grows down, `size` and `design` set the font, each new `focusRequest`
// moves the keyboard in, and with a handler Escape calls onEscape.
function Demo() {
  var text = React.useState("");
  var keys = React.useState("none");
  var plain = React.useState("");
  var secret = React.useState("");
  var note = React.useState("");
  var focus = React.useState(0);
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
    h(Text, { size: 11, color: "secondary", testID: "text-field-plain-value" }, "Plain: ", plain[0]),
    h(TextField, { text: secret[0], placeholder: "Password", secure: true, width: 200, testID: "text-field-secure", onChange: secret[1],
      onEscape: function () { keys[1]("escape"); } }),
    h(Text, { size: 11, color: "secondary", testID: "text-field-secure-length" }, "Secret length: ", String(secret[0].length)),
    h(TextField, { text: note[0], placeholder: "A note that wraps", multiline: true, size: 12, design: "monospaced", width: 200,
      focusRequest: focus[0] || undefined, testID: "text-field-multiline", onChange: note[1] }),
    h(Button, { style: "borderless", testID: "text-field-focus", onPress: function () { focus[1](function (count) { return count + 1; }); } },
      h(Text, { size: 11, weight: "medium", color: "accent" }, "Focus the note")));
}

Playhouse.render(h(Demo));
