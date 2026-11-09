import SwiftUI

/// Renders one plugin script: its runtime's node tree through the atom
/// registry, any errors, and what its last commit changed.
struct PluginSurface: View {
    let source: String
    let name: String
    var props: [String: PluginValue] = [:]
    @State private var runtime: PluginRuntime?
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let runtime {
                ForEach(runtime.tree.root.children) { node in
                    PluginNodeView(node: node, runtime: runtime)
                }
                PluginErrors(errors: runtime.errors)
                PluginCommitReadout(tree: runtime.tree)
            } else if let loadError {
                PluginErrors(errors: [loadError])
            }
        }
        .task(id: name) {
            do {
                runtime = try PluginRuntime(source: source, sourceName: name, props: props)
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}

private struct PluginErrors: View {
    let errors: [String]

    var body: some View {
        ForEach(Array(errors.enumerated()), id: \.offset) { _, error in
            Text(error)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .accessibilityIdentifier("plugin-error")
        }
    }
}

/// "Commit 3: text → node 36". It reads only `lastCommit`, so it updates once per commit.
private struct PluginCommitReadout: View {
    let tree: PluginNodeTree

    var body: some View {
        if let commit = tree.lastCommit {
            let summary = commit.number == 1
                ? "Commit 1: initial render, \(commit.ops.count) ops"
                : "Commit \(commit.number): \(commit.ops.joined(separator: ", ")) → \(commit.touchedNodes.count == 1 ? "node" : "nodes") \(commit.touchedNodes.map(String.init).joined(separator: ", "))"
            Text(summary)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .accessibilityIdentifier("plugin-last-commit")
        }
    }
}

/// The Plugins menu's catalog: every atom rendered by its JavaScript page, and
/// the native composites (the task item, the Agents info section, the Token
/// Stats modal) composed in JavaScript beside the native ones.
struct PluginCatalogView: View {
    private enum Page: Hashable {
        case atom(AtomType)
        case taskItem
        case agentsInfo
        case tokenStats
    }

    @State private var selection: Page? = .atom(.stack)

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Atoms") {
                    ForEach(AtomType.allCases, id: \.self) { atom in
                        Text(atom.rawValue)
                            .tag(Page.atom(atom))
                            .accessibilityIdentifier("plugin-catalog-atom-\(atom.rawValue)")
                    }
                }
                Section("Examples") {
                    Text("Task Item")
                        .tag(Page.taskItem)
                        .accessibilityIdentifier("plugin-catalog-task-item")
                    Text("Agents Info")
                        .tag(Page.agentsInfo)
                        .accessibilityIdentifier("plugin-catalog-agents-info")
                    Text("Token Stats")
                        .tag(Page.tokenStats)
                        .accessibilityIdentifier("plugin-catalog-token-stats")
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            ScrollView {
                switch selection {
                case .atom(let atom)?:
                    AtomPage(atom: atom).id(atom)
                case .taskItem?:
                    TaskItemComparison()
                case .agentsInfo?:
                    AgentsInfoComparison()
                case .tokenStats?:
                    TokenStatsComparison()
                case nil:
                    EmptyView()
                }
            }
        }
    }
}

private func catalogPage(_ page: String) -> (source: String, props: [String: PluginValue])? {
    try? PluginRenderCommand.catalogPage(page, resources: PluginRuntime.bundledResources)
}

/// One side of a composite's comparison page.
private func comparisonColumn(_ title: String, width: CGFloat, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        Text(title).font(.headline)
        content()
    }
    .frame(width: width, alignment: .leading)
}

private struct AtomPage: View {
    let atom: AtomType

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(atom.rawValue)
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("plugin-catalog-title")
            if let page = catalogPage(atom.rawValue) {
                PluginSurface(source: page.source, name: "\(atom.rawValue).js", props: page.props)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("plugin-catalog-surface")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Props").font(.headline)
                Text(atom.propKeys.isEmpty ? "none of its own" : atom.propKeys.sorted().joined(separator: ", "))
                    .font(.system(size: 11, design: .monospaced))
                    .accessibilityIdentifier("plugin-catalog-props")
                if !atom.events.isEmpty {
                    Text("Events: \(atom.events.sorted().joined(separator: ", "))")
                        .font(.system(size: 11, design: .monospaced))
                }
                Text("Every atom also takes: \(AtomCommon.keys.sorted().joined(separator: ", "))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The JavaScript task item beside the native one, from the same sample model.
/// Each side keeps its own state; the native card uses a "native-" id so the
/// two never share accessibility identifiers.
private struct TaskItemComparison: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Task Item")
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("plugin-catalog-title")
            if let page = catalogPage("TaskItem"),
               let sample = try? Self.sample(page.props) {
                HStack(alignment: .top, spacing: 28) {
                    comparisonColumn("JavaScript (React → atoms)", width: 300) {
                        PluginSurface(source: page.source, name: "TaskItem.js", props: page.props)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("plugin-catalog-js-task-item")
                    comparisonColumn("Native SwiftUI (atoms)", width: 300) {
                        NativeTaskItemDemo(sample: sample)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("plugin-catalog-native-task-item")
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    struct Sample: Decodable {
        var task: TaskItemModel
        var blockedStatusMessage: String
    }

    static func sample(_ props: [String: PluginValue]) throws -> Sample {
        try PluginValueDecoder.decode(Sample.self, from: .object(props))
    }
}

/// The native task item with the same demo controls as TaskItem.js, built from the same atoms.
private struct NativeTaskItemDemo: View {
    let sample: TaskItemComparison.Sample
    @State private var blocked = false
    @State private var mode: String?
    @State private var opened = 0
    @State private var lastAction = "none"

    private var model: TaskItemModel {
        var task = sample.task
        task.id = "native-\(task.id)"
        if blocked {
            task.statusMessage = sample.blockedStatusMessage
            task.statusIsBlocked = true
        }
        if var pullRequests = task.pullRequests {
            pullRequests.modes = TaskItemModel.modeOptions(taskID: task.id).filter { option in pullRequests.modes.contains { $0.value == option.value } }
            pullRequests.mode = mode ?? pullRequests.mode
            task.pullRequests = pullRequests
        }
        return task
    }

    var body: some View {
        AtomStack(props: StackProps(axis: "v", spacing: 12, align: "leading")) {
            TaskItemView(model: model, actions: TaskItemActions(
                open: { opened += 1 },
                menu: { lastAction = "menu \($0)" },
                showTokenStats: { lastAction = "token stats" },
                createPullRequests: { lastAction = "create pull requests" },
                setPullRequestMode: { mode = $0; lastAction = "mode \($0)" },
                moveToDone: { lastAction = "move to done" },
                resolveConflicts: { lastAction = "resolve conflicts" }
            ))
            AtomStack(props: StackProps(axis: "h", spacing: 8)) {
                AtomButton(props: ButtonProps(style: "borderless"), common: AtomCommon(testID: "native-toggle-blocked"), action: { blocked.toggle() }) {
                    AtomText(props: TextProps(text: blocked ? "Unblock" : "Block", size: 11, weight: "medium", color: "accent"))
                }
                AtomText(props: TextProps(text: "Opened \(opened) times", size: 11, color: "secondary"), common: AtomCommon(testID: "native-opened-count"))
                AtomText(props: TextProps(text: "Last: \(lastAction)", size: 11, color: "secondary"), common: AtomCommon(testID: "native-last-action"))
            }
        }
    }
}

/// The JavaScript Agents info section beside the native one, from the same
/// sample model. Each side keeps its own collapsed and signed-out state; the
/// native section uses a "native-agents-info" id so the two never share
/// accessibility identifiers.
private struct AgentsInfoComparison: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Agents Info")
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("plugin-catalog-title")
            if let page = catalogPage("AgentsInfo"),
               let sample = try? Self.sample(page.props) {
                HStack(alignment: .top, spacing: 28) {
                    comparisonColumn("JavaScript (React → atoms)", width: 240) {
                        PluginSurface(source: page.source, name: "AgentsInfo.js", props: page.props)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("plugin-catalog-js-agents-info")
                    comparisonColumn("Native SwiftUI (atoms)", width: 240) {
                        NativeAgentsInfoDemo(sample: sample)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("plugin-catalog-native-agents-info")
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    struct Sample: Decodable {
        var agentsInfo: AgentsInfoModel
    }

    static func sample(_ props: [String: PluginValue]) throws -> Sample {
        try PluginValueDecoder.decode(Sample.self, from: .object(props))
    }
}

/// The native Agents info section with the same demo controls as AgentsInfo.js, built from the same atoms.
private struct NativeAgentsInfoDemo: View {
    let sample: AgentsInfoComparison.Sample
    @State private var collapsed = false
    @State private var signedOut = false
    @State private var lastAction = "none"

    private var model: AgentsInfoModel {
        var model = sample.agentsInfo
        model.id = "native-\(model.id)"
        model.agents = model.agents.map { agent in
            var agent = agent
            if agent.provider == "claude" && signedOut { agent.signedOut = true }
            return agent
        }
        return model
    }

    var body: some View {
        // As wide as the board sidebar's content.
        AtomStack(props: StackProps(axis: "v", spacing: 12, align: "leading")) {
            AtomStack(props: StackProps(axis: "v"), common: AtomCommon(width: 160)) {
                AgentsInfoSection(model: model, collapsed: collapsed, actions: AgentsInfoActions(
                    toggle: { lastAction = collapsed ? "expand" : "collapse"; collapsed.toggle() },
                    login: { signedOut = false; lastAction = "login \($0)" },
                    switchAccount: { lastAction = "switch \($0)" }
                ))
            }
            AtomStack(props: StackProps(axis: "h", spacing: 8)) {
                AtomButton(props: ButtonProps(style: "borderless"), common: AtomCommon(testID: "native-toggle-signed-out"), action: { signedOut.toggle() }) {
                    AtomText(props: TextProps(text: signedOut ? "Sign in Claude" : "Sign out Claude", size: 11, weight: "medium", color: "accent"))
                }
                AtomText(props: TextProps(text: "Last: \(lastAction)", size: 11, color: "secondary"), common: AtomCommon(testID: "native-last-action"))
            }
        }
    }
}

/// The JavaScript Token Stats modal above the native one (each is 720 points
/// wide), from the same sample model, each opened by the task item's token
/// counter. Each side keeps its own section and open state; the native modal
/// uses a "native-token-stats" id so the two never share accessibility
/// identifiers.
private struct TokenStatsComparison: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Token Stats")
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("plugin-catalog-title")
            if let page = catalogPage("TokenStats"),
               let sample = try? Self.sample(page.props) {
                comparisonColumn("JavaScript (React → atoms)", width: 740) {
                    PluginSurface(source: page.source, name: "TokenStats.js", props: page.props)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("plugin-catalog-js-token-stats")
                comparisonColumn("Native SwiftUI (atoms)", width: 740) {
                    NativeTokenStatsDemo(sample: sample)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("plugin-catalog-native-token-stats")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    struct Sample: Decodable {
        var tokenCounter: TaskItemModel.Tokens
        var tokenStats: TokenStatsModel
    }

    static func sample(_ props: [String: PluginValue]) throws -> Sample {
        try PluginValueDecoder.decode(Sample.self, from: .object(props))
    }
}

/// The native Token Stats modal with the same demo controls as TokenStats.js, built from the same atoms.
private struct NativeTokenStatsDemo: View {
    let sample: TokenStatsComparison.Sample
    @State private var section = "overview"
    @State private var open = true
    @State private var lastAction = "none"

    private var model: TokenStatsModel {
        var model = sample.tokenStats
        model.id = "native-\(model.id)"
        return model
    }

    var body: some View {
        AtomStack(props: StackProps(axis: "v", spacing: 12, align: "leading")) {
            AtomStack(props: StackProps(axis: "h", spacing: 8)) {
                AtomText(props: TextProps(text: "Task item counter", size: 11, color: "secondary"))
                TokenCounterButton(tokens: sample.tokenCounter, testID: "native-token-stats-counter") {
                    open = true
                    lastAction = "open"
                }
                AtomText(props: TextProps(text: "Last: \(lastAction)", size: 11, color: "secondary"), common: AtomCommon(testID: "native-last-action"))
            }
            if open {
                AtomPanel(props: PanelProps(fillOpacity: 0.03, cornerRadius: 10), common: AtomCommon(testID: "native-token-stats-modal")) {
                    TokenStatsView(model: model, section: section, actions: TokenStatsActions(
                        selectSection: { section = $0; lastAction = "section \($0)" },
                        showRawInput: { target in
                            lastAction = "raw input " + (target.agent.map { "\($0) #\(target.item ?? 0)" } ?? "final transcript")
                        },
                        done: { open = false; lastAction = "done" }
                    ))
                }
            }
        }
    }
}
