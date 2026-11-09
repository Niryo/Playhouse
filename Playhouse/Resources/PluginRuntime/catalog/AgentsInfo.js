// The Agents info section, composed in JavaScript from the same atoms the
// native AgentsInfoSection (Playhouse/App/AgentsInfoView.swift) uses, from the
// same display model (Playhouse.props.agentsInfo). Below it, controls whose
// state changes show which nodes each commit touches.

function WindowRow(props) {
  var window = props.window;
  return h(Stack, { axis: "v", spacing: 2, align: "leading", combine: true, testID: props.prefix + "-window-" + window.id, help: window.help },
    h(Stack, { axis: "h", spacing: 4 },
      h(Text, { size: 10, lineLimit: 1 }, window.label),
      h(Spacer, { minLength: 0 }),
      h(Text, { size: 10, weight: "medium", color: window.percentColor, monospacedDigits: true }, window.percent)),
    h(Meter, { fraction: window.fraction, color: window.barColor }),
    h(Text, { size: 9, color: "secondary" }, window.reset));
}

function Header(props) {
  var agent = props.agent, id = props.id, on = props.on;
  return h(Stack, { axis: "h", spacing: 5, align: "top" },
    h(Icon, { name: agent.icon, size: 9, weight: "semibold", color: "secondary" }),
    h(Stack, { axis: "v", spacing: 1, align: "leading" },
      h(Text, { size: 11, weight: "semibold" }, agent.name),
      agent.identity ? h(Text, {
        size: 9, color: "secondary", lineLimit: 1, truncation: "middle",
        testID: id + "-" + agent.provider + "-account", help: agent.identityHelp
      }, agent.identity) : null),
    h(Spacer, { minLength: 0 }),
    agent.canSwitch ? h(Button, {
      testID: id + "-switch-" + agent.provider, label: "Switch " + agent.name + " account", help: "Switch " + agent.name + " account",
      width: 16, height: 16, onPress: function () { on.switchAccount(agent.provider); }
    }, h(Icon, { name: "person.2", size: 9, color: "secondary" })) : null);
}

function SignedOut(props) {
  var agent = props.agent, id = props.id, on = props.on, prefix = id + "-" + agent.provider;
  return h(Stack, { axis: "v", spacing: 4, align: "leading" },
    agent.loginPending ? h(Text, { size: 9, color: "secondary", testID: prefix + "-login-pending" }, "Waiting for sign-in…") : null,
    h(Button, {
      testID: id + "-login-" + agent.provider, label: "Log in to " + agent.name, help: "Log in to " + agent.name, fillWidth: true,
      onPress: function () { on.login(agent.provider); }
    },
      h(Panel, { fill: "accent", fillOpacity: 0.18, cornerRadius: 5, fillWidth: true, padding: 3 },
        h(Stack, { axis: "h" },
          h(Spacer, { minLength: 0 }),
          h(Text, { size: 10, weight: "medium" }, "Log in"),
          h(Spacer, { minLength: 0 })))));
}

function AgentBlock(props) {
  var agent = props.agent, id = props.id, prefix = id + "-" + agent.provider;
  var body;
  if (agent.signedOut) {
    body = [h(SignedOut, { key: "signed-out", agent: agent, id: id, on: props.on })];
  } else if (agent.hasUsage) {
    body = agent.windows.map(function (window) { return h(WindowRow, { key: window.id, window: window, prefix: prefix }); });
    if (agent.credits) body.push(h(Text, { key: "credits", size: 9, color: "secondary", testID: prefix + "-credits" }, agent.credits));
    if (agent.status) body.push(h(Text, { key: "status", size: 9, weight: "semibold", color: agent.status.color, testID: prefix + "-status" }, agent.status.text));
    if (agent.updated) body.push(h(Text, { key: "updated", size: 9, color: "tertiary", testID: prefix + "-updated" }, agent.updated));
  } else {
    body = [h(Text, { key: "empty", size: 9, color: "secondary", testID: prefix + "-empty" }, "No data yet")];
  }
  return h(Panel, { spacing: 4, testID: prefix, fillWidth: true, padding: 8 },
    h(Header, { agent: agent, id: id, on: props.on }),
    body);
}

function AgentsInfo(props) {
  var model = props.model, id = model.id;
  return h(Disclosure, {
    title: model.title, collapsed: props.collapsed, spacing: 6, toggleTestID: id + "-toggle",
    testID: id, onToggle: props.on.toggle
  },
    model.agents.map(function (agent) { return h(AgentBlock, { key: agent.provider, agent: agent, id: id, on: props.on }); }),
    model.errorMessage ? h(Text, { size: 9, color: "red", lineLimit: 3, testID: id + "-error" }, model.errorMessage) : null);
}

function Example() {
  var sample = Playhouse.props.agentsInfo;
  var collapsed = React.useState(false);
  var signedOut = React.useState(false);
  var lastAction = React.useState("none");

  var model = Object.assign({}, sample, {
    agents: sample.agents.map(function (agent) {
      return agent.provider === "claude" && signedOut[0] ? Object.assign({}, agent, { signedOut: true }) : agent;
    })
  });
  var on = {
    // The Disclosure is controlled: onToggle carries no value, so the owner flips its own state.
    toggle: function () { collapsed[1](!collapsed[0]); lastAction[1](collapsed[0] ? "expand" : "collapse"); },
    login: function (provider) { signedOut[1](false); lastAction[1]("login " + provider); },
    switchAccount: function (provider) { lastAction[1]("switch " + provider); }
  };

  // As wide as the board sidebar's content.
  return h(Stack, { axis: "v", spacing: 12, align: "leading" },
    h(Stack, { axis: "v", width: 160 }, h(AgentsInfo, { model: model, collapsed: collapsed[0], on: on })),
    h(Stack, { axis: "h", spacing: 8 },
      h(Button, { style: "borderless", testID: "js-toggle-signed-out", onPress: function () { signedOut[1](!signedOut[0]); } },
        h(Text, { size: 11, weight: "medium", color: "accent" }, signedOut[0] ? "Sign in Claude" : "Sign out Claude")),
      h(Text, { size: 11, color: "secondary", testID: "js-last-action" }, "Last: ", lastAction[0])));
}

Playhouse.render(h(Example));
