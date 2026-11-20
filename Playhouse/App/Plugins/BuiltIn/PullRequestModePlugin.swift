import SwiftUI

/// The task card's pull request mode pill, the built-in plugin
/// `BuiltInPlugins.pullRequestModeID`. It is written in Swift but composed
/// only of atoms, and it does only what a JavaScript plugin can: the mode is
/// its own state (`props.state[taskID]`, saved with `plugin.state.set`; a
/// recurring schedule's runs inherit their schedule's), not a property of the
/// task. What each mode does when the task reaches Review or the app comes to
/// the front is its daemon half's work (`PullRequestModeService`).
struct PullRequestModePlugin: View {
    let host: PluginHost
    let props: [String: PluginValue]

    /// A choice not yet back in `props.state`, so the pill folds onto it at once.
    @State private var pendingMode: PullRequestMode?

    private var task: [String: PluginValue] { props["task"]?.object ?? [:] }
    private var taskID: String { task["id"]?.string ?? "" }
    private var status: String { task["status"]?.string ?? "" }
    private var repositories: [[String: PluginValue]] { props["repositories"]?.array?.compactMap(\.object) ?? [] }
    private var linked: [[String: PluginValue]] { repositories.filter { $0["pullRequest"]?.object != nil } }

    private var savedMode: PullRequestMode {
        PullRequestMode.resolve(state: props["state"]?.object ?? [:], taskID: taskID, scheduleSourceTaskID: task["scheduleSourceTaskID"]?.string)
    }

    private var mode: PullRequestMode { pendingMode ?? savedMode }

    /// Shown once the task has started in a repository: while it's worked on,
    /// beside the create button of a task in Review or Done with no pull
    /// request, and beside its linked pull requests until they have all merged.
    private var isVisible: Bool {
        guard status != TaskStatus.backlog.rawValue, !repositories.isEmpty else { return false }
        return linked.isEmpty || !linked.allSatisfy { $0["pullRequest"]?.object?["merged"] == .bool(true) }
    }

    var body: some View {
        AtomStack(props: StackProps(axis: "h", spacing: 0)) {
            if isVisible {
                AtomPillPicker(
                    props: PillPickerProps(options: Self.options(taskID: taskID), selected: mode.rawValue),
                    common: AtomCommon(testID: "task-pr-mode-\(taskID)", label: "Pull request mode", help: "How Playhouse handles this task's pull request. {help}. Click to choose another mode."),
                    onChange: choose
                )
            }
        }
        .onChange(of: savedMode) { pendingMode = nil }
    }

    static func options(taskID: String) -> [PillPickerProps.Option] {
        PullRequestMode.allCases.map {
            PillPickerProps.Option(value: $0.rawValue, label: $0.label, help: $0.helpText, testID: "task-pr-mode-\($0.rawValue)-\(taskID)")
        }
    }

    private func choose(_ value: String) {
        guard let chosen = PullRequestMode(rawValue: value), chosen != mode else { return }
        pendingMode = chosen
        Task {
            do {
                // The default mode is no entry, so the state stays small; a
                // schedule's run keeps every choice, the default included, so
                // it overrides the mode its schedule was given.
                try await host.call("bridge", "plugin.state.set", [
                    "pluginID": .string(BuiltInPlugins.pullRequestModeID), "key": .string(taskID),
                    "value": chosen == PullRequestMode.defaultMode && task["scheduleSourceTaskID"]?.string == nil ? .null : .string(chosen.rawValue)
                ])
            } catch {
                pendingMode = nil
                try? await host.call("ui", "alert", ["title": .string("Couldn't change the pull request mode"), "message": .string(Self.message(error))])
            }
        }
    }

    static func message(_ error: Error) -> String {
        (error as? PluginHostError)?.message ?? error.localizedDescription
    }
}
