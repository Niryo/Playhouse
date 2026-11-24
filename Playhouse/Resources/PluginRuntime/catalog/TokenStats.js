// The Token Stats modal, composed in JavaScript from the same atoms the
// native TokenStatsView (Playhouse/App/TokenStatsView.swift) uses, from the
// same display model (Playhouse.props.tokenStats). Above it, the task item's
// token counter (Playhouse.props.tokenCounter) opens it, Done closes it, and
// a readout names the last action.

function CounterButton(props) {
  var tokens = props.tokens;
  // The hover capsule pads the hit area well past the small text and
  // overhangs, so the larger target doesn't grow the row it sits in.
  return h(Button, {
    emphasis: 6, overhang: true, testID: props.testID, label: tokens.description, hint: "Open Token Stats",
    help: tokens.description + ". Click for Token Stats", paddingX: 4, onPress: props.onPress
  }, h(Text, { size: 10, weight: "medium", design: "monospaced", color: tokens.color, numeric: true }, tokens.compact));
}

function SectionHeader(props) {
  return h(Stack, { axis: "v", spacing: 2, align: "leading" },
    h(Text, { size: 12, weight: "semibold" }, props.title),
    h(Text, { size: 10, color: "tertiary" }, props.caption));
}

function tokens(value, testID) {
  return h(Text, { size: 11, weight: "medium", monospacedDigits: true, testID: testID }, value);
}

function detail(text, testID) {
  return h(Text, { size: 10, color: "secondary", lineLimit: 1, testID: testID }, text);
}

function name(text, testID) {
  return h(Text, { size: 11, lineLimit: 1, testID: testID }, text);
}

function shareBar(bar) {
  return h(Meter, { fraction: bar.fraction, color: bar.color, thickness: 6, trackOpacity: 0.07, minFill: 2, width: 72 });
}

// One accessibility container per row, found by its identifier.
function row(key, testID, align, children) {
  return h(Stack, { key: key, axis: "h", spacing: 8, align: align, group: true, testID: testID }, children);
}

function list(key, children) {
  return h(Stack, { key: key, axis: "v", spacing: 6, align: "leading" }, children);
}

function CallTotals(props) {
  var calls = props.calls, id = props.id;
  if (!calls) {
    return h(Text, { size: 10, color: "tertiary", testID: id + "-calls-unavailable" }, "Call-level stats are not recorded for this task yet.");
  }
  return h(Stack, { axis: "v", spacing: 8, align: "leading" },
    h(Stack, { axis: "h", spacing: 28, align: "top" },
      calls.headlines.map(function (headline) {
        return h(Stack, { key: headline.key, axis: "v", spacing: 2, align: "leading" },
          h(Text, { size: 10, color: "tertiary" }, headline.label),
          h(Text, { size: 22, weight: "semibold", design: "rounded", testID: id + "-" + headline.key }, headline.value));
      })),
    calls.excludingCacheSplit ? h(Text, { size: 11, color: "secondary", testID: id + "-excluding-cache-split" }, calls.excludingCacheSplit) : null,
    h(Text, { size: 11, color: "secondary", testID: id + "-total-calls" }, calls.calls),
    h(Text, { size: 11, color: "secondary", testID: id + "-output" }, calls.output),
    h(Divider),
    h(Text, { size: 10, weight: "semibold", color: "tertiary" }, "Main agent turns"));
}

function Totals(props) {
  var overview = props.overview, id = props.id;
  return h(Stack, { axis: "v", spacing: 8, align: "leading" },
    h(CallTotals, { calls: overview.calls, id: id }),
    h(Text, { size: 30, weight: "semibold", design: "rounded", testID: id + "-total" }, overview.total),
    h(Text, { size: 11, color: "secondary" }, overview.turnsCaption),
    overview.hiddenTurnsNote ? h(Text, { size: 10, color: "tertiary", testID: id + "-hidden-turns-note" }, "Includes tokens from private turns not shown below.") : null,
    h(Stack, { axis: "h", spacing: 18 },
      overview.buckets.map(function (bucket) {
        return h(Stack, { key: bucket.label, axis: "v", spacing: 2, align: "leading" },
          h(Text, { size: 10, color: "tertiary" }, bucket.label),
          h(Text, { size: 13, weight: "medium" }, bucket.value));
      })),
    overview.contextCompactions.map(function (detail, index) {
      return h(Text, { key: "compaction-" + index, size: 10, color: "secondary", wrap: true, testID: id + "-compaction-" + index }, detail);
    }),
    overview.resumeCacheMisses.map(function (detail, index) {
      return h(Text, { key: "resume-cache-miss-" + index, size: 10, color: "secondary", wrap: true, testID: id + "-resume-cache-miss-" + index }, "Resume cache miss · " + detail);
    }));
}

function overviewSection(model) {
  var overview = model.overview, id = model.id;
  if (!overview) {
    return model.loaded ? [h(Text, { key: "empty", size: 12, color: "secondary", testID: id + "-empty" }, "No tokens recorded for this task yet.")] : [];
  }
  var scrolled = [];
  // Providers report usage once per turn, so a turn's cost counts toward
  // every tool that ran in it. Say so rather than implying these totals add
  // up to the task total.
  if (overview.tools.length > 0) {
    scrolled.push(list("tools", [
      h(Text, { key: "title", size: 12, weight: "semibold" }, "By tool, skill and MCP"),
      h(Text, { key: "caption", size: 10, color: "tertiary" }, "Cost of the turns each ran in; turns with several tools count toward each.")
    ].concat(overview.tools.map(function (tool) {
      return row(tool.id, id + "-tool-" + tool.id, "baseline", [
        name(tool.id), h(Spacer, { key: "spacer", minLength: 8 }), h(Text, { key: "turns", size: 10, color: "tertiary" }, tool.turns), tokens(tool.total)
      ].map(keyed));
    }))));
  }
  scrolled.push(list("turns", [h(Text, { key: "title", size: 12, weight: "semibold" }, "By turn")].concat(overview.turns.map(function (turn) {
    return h(Stack, { key: turn.id, axis: "v", spacing: 2, align: "leading", group: true, testID: id + "-turn-" + turn.id },
      h(Stack, { axis: "h", spacing: 8, align: "baseline" },
        h(Text, { size: 11 }, turn.recordedAt),
        h(Text, { size: 10, color: "tertiary" }, turn.provider),
        h(Spacer, { minLength: 8 }),
        tokens(turn.total)),
      turn.tools ? h(Text, { size: 10, color: "secondary", lineLimit: 2 }, turn.tools) : null);
  }))));
  return [
    h(Totals, { key: "totals", overview: overview, id: id }),
    h(Divider, { key: "divider" }),
    h(Scroll, { key: "scroll", spacing: 18, maxHeight: 320, testID: id + "-overview" }, scrolled)
  ];
}

// Children of a row are siblings in an array, so each needs a key.
function keyed(element, index) {
  return element && React.cloneElement(element, { key: element.key != null ? element.key : String(index) });
}

function wastersSection(map, id, on) {
  var sections = [list("largest", [
    h(SectionHeader, { key: "header", title: "Largest items", caption: "Ranked by the tokens each item added. ×N is how many requests carried it; show one to read its full text." })
  ].concat(map.wasters.map(function (item, index) {
    var prefix = id + "-waster-" + index;
    return row(String(index), prefix, undefined, [
      shareBar(item.bar),
      h(Stack, { axis: "v", spacing: 2, align: "leading" },
        h(Stack, { axis: "h", spacing: 6 },
          h(Text, { size: 11, weight: "medium", lineLimit: 1, testID: prefix + "-label" }, item.label),
          h(Text, { size: 9, color: "tertiary" }, item.kind),
          item.removed ? h(Text, { size: 9, color: "orange", testID: prefix + "-removed" }, "removed by compaction") : null),
        detail(item.preview)),
      h(Spacer, { minLength: 8 }),
      detail(item.requests, prefix + "-requests"),
      tokens(item.tokens, prefix + "-tokens"),
      h(Button, {
        style: "bordered", controlSize: "small", testID: prefix + "-show", help: "Show the full text the model received",
        onPress: function () { on.showRawInput(item.target); }
      }, h(Text, null, "Show"))
    ].map(keyed));
  })))];
  if (map.duplicates.length > 0) {
    sections.push(list("duplicates", [
      h(SectionHeader, { key: "header", title: "Repeated results", caption: "Tool results whose text was sent more than once in the same agent." })
    ].concat(map.duplicates.map(function (duplicate, index) {
      return row(String(index), id + "-duplicate-" + index, undefined, [
        name(duplicate.label),
        detail(duplicate.copies, id + "-duplicate-" + index + "-copies"),
        h(Spacer, { minLength: 8 }),
        tokens(duplicate.wasted, id + "-duplicate-" + index + "-wasted")
      ].map(keyed));
    }))));
  }
  if (map.cacheMisses.length > 0) {
    sections.push(list("cache-misses", [
      h(SectionHeader, { key: "header", title: "Cache misses", caption: "Requests that re-sent most of the previous request's context without the prompt cache, paying for it again." })
    ].concat(map.cacheMisses.map(function (miss, index) {
      return row(String(index), id + "-cache-miss-" + index, undefined, [
        h(Text, { size: 11, testID: id + "-cache-miss-" + index + "-request" }, miss.request),
        detail(miss.detail),
        h(Spacer, { minLength: 8 }),
        tokens(miss.rewritten, id + "-cache-miss-" + index + "-rewritten")
      ].map(keyed));
    }))));
  }
  return sections;
}

function toolsSection(map, id) {
  var sections = [list("tools", [
    h(SectionHeader, { key: "header", title: "Tools", caption: "Tokens each tool's calls and results added to the context, across every agent." })
  ].concat(map.tools.map(function (tool) {
    var prefix = id + "-measured-tool-" + tool.id;
    return row(tool.id, prefix, undefined, [
      shareBar(tool.bar), name(tool.id), h(Spacer, { minLength: 8 }), detail(tool.detail, prefix + "-calls"), tokens(tool.total, prefix + "-total")
    ].map(keyed));
  })))];
  if (map.servers.length > 0) {
    sections.push(list("servers", [
      h(SectionHeader, { key: "header", title: "MCP servers", caption: "What each server's calls added, and what its tool definitions cost on every request." })
    ].concat(map.servers.map(function (server) {
      var prefix = id + "-server-" + server.id;
      return row(server.id, prefix, undefined, [
        name(server.id), h(Spacer, { minLength: 8 }), detail(server.detail, prefix + "-detail"), tokens(server.total, prefix + "-total")
      ].map(keyed));
    }))));
  }
  return sections;
}

function overheadSection(map, id) {
  return [
    list("overhead", [
      h(SectionHeader, { key: "header", title: "Sent with every request", caption: "The system prompt and tool definitions each main agent carries, whatever the conversation does." })
    ].concat(map.overhead.map(function (entry, index) {
      var prefix = id + "-overhead-" + index;
      return row(String(index), prefix, undefined, [
        shareBar(entry.bar), name(entry.label, prefix + "-label"), h(Spacer, { minLength: 8 }),
        detail(entry.requests, prefix + "-requests"), tokens(entry.tokens, prefix + "-tokens")
      ].map(keyed));
    }))),
    list("agents", [
      h(SectionHeader, { key: "header", title: "Agents", caption: "Each agent's own requests, everything they sent, and the size of its final transcript." })
    ].concat(map.agents.map(function (agent) {
      var prefix = id + "-agent-" + agent.id;
      return row(agent.id, prefix, undefined, [
        name(agent.label), h(Spacer, { minLength: 8 }), detail(agent.detail, prefix + "-detail"), tokens(agent.sent, prefix + "-sent")
      ].map(keyed));
    })))
  ];
}

// A map section, or why there is no map: the providers only log their
// requests once a conversation has run with a version that writes them.
function mapSection(model, content) {
  var id = model.id;
  if (model.map) {
    return [h(Scroll, { key: "map", spacing: 18, testID: id + "-map", height: 420 }, content(model.map))];
  }
  return model.loaded ? [h(Text, { key: "unavailable", size: 12, color: "secondary", testID: id + "-map-unavailable" },
    "No request log for this task yet. Claude Code and Codex write one to their session files, and OpenCode's turns save their session's messages, as the conversation runs.")] : [];
}

function TokenStats(props) {
  var model = props.model, id = model.id, on = props.on;
  var content;
  switch (props.section) {
    case "wasters": content = mapSection(model, function (map) { return wastersSection(map, id, on); }); break;
    case "tools": content = mapSection(model, function (map) { return toolsSection(map, id); }); break;
    case "overhead": content = mapSection(model, function (map) { return overheadSection(map, id); }); break;
    default: content = overviewSection(model);
  }
  return h(Stack, { axis: "v", spacing: 14, align: "leading", group: true, testID: id, width: 672, padding: 24 },
    h(Stack, { axis: "h", align: "top" },
      h(Stack, { axis: "v", spacing: 4, align: "leading" },
        h(Text, { size: 19, weight: "semibold", design: "rounded", testID: id + "-title" }, model.title),
        h(Text, { size: 12, color: "secondary", lineLimit: 2, testID: id + "-task-title" }, model.taskTitle)),
      h(Spacer),
      h(Button, {
        style: "bordered", disabled: !model.rawInputAvailable, testID: id + "-raw-input-button",
        help: "Open the full input the model was sent, item by item",
        onPress: function () { on.showRawInput({ agent: null, item: null, inFinalTranscript: true }); }
      }, h(Label, { text: "View raw input…", icon: "doc.text.magnifyingglass" }))),
    h(ChoiceBar, {
      options: model.sections.map(function (section) { return { value: section.value, label: section.label, testID: id + "-section-" + section.value }; }),
      selected: props.section, testID: id + "-sections", onChange: on.selectSection
    }),
    content,
    h(Stack, { axis: "h" },
      h(Spacer),
      h(Button, { style: "prominent", shortcut: "default", testID: "close-" + id + "-button", help: "Done", onPress: on.done },
        h(Text, null, "Done"))));
}

function Example() {
  var section = React.useState("overview");
  var open = React.useState(true);
  var lastAction = React.useState("none");
  var on = {
    // The ChoiceBar is controlled: onChange carries the chosen section, and the owner selects it.
    selectSection: function (value) { section[1](value); lastAction[1]("section " + value); },
    showRawInput: function (target) {
      lastAction[1]("raw input " + (target.agent ? target.agent + " #" + target.item : "final transcript"));
    },
    done: function () { open[1](false); lastAction[1]("done"); }
  };

  return h(Stack, { axis: "v", spacing: 12, align: "leading" },
    h(Stack, { axis: "h", spacing: 8 },
      h(Text, { size: 11, color: "secondary" }, "Task item counter"),
      h(CounterButton, {
        tokens: Playhouse.props.tokenCounter, testID: "token-stats-counter",
        onPress: function () { open[1](true); lastAction[1]("open"); }
      }),
      h(Text, { size: 11, color: "secondary", testID: "js-last-action" }, "Last: ", lastAction[0])),
    open[0] ? h(Panel, { fillOpacity: 0.03, cornerRadius: 10, padding: 0, testID: "token-stats-modal" },
      h(TokenStats, { model: Playhouse.props.tokenStats, section: section[0], on: on })) : null);
}

Playhouse.render(h(Example));
