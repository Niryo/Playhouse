// Editor: a multiline message editor that grows with its text, under a
// placeholder. It is controlled: text is what it shows, and each edit calls
// onChange. Return calls onSubmit and Command-Return onSteerSubmit.
function Demo() {
  var text = React.useState("");
  var last = React.useState("none");
  return h(Stack, { axis: "v", spacing: 8, align: "leading" },
    h(Editor, {
      text: text[0], placeholder: "Message…", placeholderTestID: "editor-placeholder", inputTestID: "editor-input", inputLabel: "Demo message", testID: "editor-demo", width: 360,
      onChange: function (value) { text[1](value); last[1]("change"); },
      onSubmit: function () { last[1]("submit " + text[0]); text[1](""); },
      onSteerSubmit: function () { last[1]("steer"); }
    }),
    h(Text, { size: 11, color: "secondary", testID: "editor-last" }, "Last: ", last[0]),
    h(Text, { size: 11, color: "secondary", testID: "editor-text" }, "Text: ", text[0]));
}

Playhouse.render(h(Demo));
