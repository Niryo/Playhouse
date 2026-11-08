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
/// the task item composed in JavaScript beside the native one.
struct PluginCatalogView: View {
    private enum Page: Hashable {
        case atom(AtomType)
        case taskItem
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
                Text(atom.propKeys.sorted().joined(separator: ", "))
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
                    column("JavaScript (React → atoms)") {
                        PluginSurface(source: page.source, name: "TaskItem.js", props: page.props)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("plugin-catalog-js-task-item")
                    column("Native SwiftUI (atoms)") {
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

    private func column(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .frame(width: 300, alignment: .leading)
    }

    struct Sample: Decodable {
        var task: TaskItemModel
        var blockedStatusMessage: String
    }

    static func sample(_ props: [String: PluginValue]) throws -> Sample {
        try JSONDecoder().decode(Sample.self, from: JSONEncoder().encode(PluginValue.object(props)))
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
