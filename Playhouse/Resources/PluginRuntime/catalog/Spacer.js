// Spacer: takes the free space in a stack, at least minLength.
Playhouse.render(h(Stack, { axis: "v", spacing: 12, align: "leading", width: 280 },
  h(Stack, { axis: "h", fillWidth: true, testID: "spacer-row" },
    h(Text, { size: 11 }, "Leading"),
    h(Spacer),
    h(Text, { size: 11 }, "Trailing")),
  h(Stack, { axis: "h", spacing: 0 },
    h(Text, { size: 11 }, "minLength 40 →"),
    h(Spacer, { minLength: 40 }),
    h(Text, { size: 11 }, "←"))
));
