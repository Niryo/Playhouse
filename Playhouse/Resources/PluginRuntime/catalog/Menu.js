// Menu: a borderless pull-down menu labelled by an SF Symbol. Its items come
// in groups with a separator between them; choosing one calls onMenu with its id.
// A disabled item is dimmed and can't be chosen.
function Demo() {
  var chosen = React.useState("none");
  var items = [
    [{ id: "edit", title: "Edit…", help: "Edit the item", testID: "menu-edit" }, { id: "reveal", title: "Reveal in Finder", testID: "menu-reveal" }, { id: "busy", title: "Run Now", disabled: true, help: "Already running", testID: "menu-disabled" }],
    [],
    [{ id: "delete", title: "Delete…", destructive: true, help: "Delete the item", testID: "menu-delete" }]
  ];
  return h(Stack, { axis: "h", spacing: 10 },
    h(Menu, { icon: "ellipsis", size: 13, weight: "semibold", items: items, width: 24, height: 24, testID: "menu-demo", label: "Actions", help: "More actions", onMenu: chosen[1] }),
    h(Text, { size: 11, color: "secondary", testID: "menu-chosen" }, "Chosen: ", chosen[0]));
}

Playhouse.render(h(Demo));
