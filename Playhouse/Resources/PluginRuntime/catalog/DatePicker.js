// DatePicker: a date or time field edited with the keyboard or its arrows,
// as the composer's schedule uses. It is controlled: `date` (seconds since
// 1970) is what it shows, and each edit calls onChange with the new date.
// `components` is "dateTime" (default), "date" or "time"; `min` is the
// earliest value it takes.
var start = 1767261600; // 2026-01-01 10:00 UTC

function Demo() {
  var value = React.useState(start);
  return h(Stack, { axis: "v", spacing: 10, align: "leading" },
    h(DatePicker, { date: value[0], testID: "date-picker-demo", label: "Run at", onChange: function (next) { value[1](Number(next)); } }),
    h(DatePicker, { date: value[0], components: "date", min: start, testID: "date-picker-date", label: "Day" }),
    h(DatePicker, { date: value[0], components: "time", testID: "date-picker-time", label: "Time" }),
    h(Text, { size: 11, color: "secondary", testID: "date-picker-value" }, "Value: ", String(value[0])));
}

Playhouse.render(h(Demo));
