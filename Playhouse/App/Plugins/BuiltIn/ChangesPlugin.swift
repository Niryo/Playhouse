import SwiftUI

/// The conversation sidebar's Changes section, the built-in plugin
/// `BuiltInPlugins.changesID`. It is written in Swift but composed only of
/// atoms, and it reads and does only what a JavaScript plugin can: it lists
/// the task's Git changes with `Playhouse.bridge("task.changes.list")`,
/// marks them viewed or unviewed with `task.changes.mark-viewed`,
/// `mark-unviewed` and `mark-all-viewed`, opens a diff with
/// `Playhouse.ui.openDiff(entry)`, refreshes with
/// `Playhouse.ui.refreshWorkspace()`, and reloads whenever
/// `props.workspace.revision` changes. On the sidebar's narrow rail
/// (`props.sidebar.collapsed`) it shows only the pending count. Whether the
/// section is collapsed is its plugin state (`props.state.collapsed`), saved
/// with `plugin.state.set`.
struct ChangesPlugin: View {
    let host: PluginHost
    let props: [String: PluginValue]

    /// Above this many changed files the section shows a notice instead of the list, which would stall layout.
    static let maxRenderedChangeCount = 1000

    @State private var inventory: WorkspaceChangeInventory?
    @State private var loadError: String?
    @State private var isViewedExpanded = false
    /// A toggle not yet back in `props.state`, so the section folds at once.
    @State private var pendingCollapsed: Bool?

    private struct LoadKey: Hashable {
        let taskID: String
        let revision: Int
    }

    private var taskID: String { props["task"]?.object?["id"]?.string ?? "" }
    private var workspace: [String: PluginValue] { props["workspace"]?.object ?? [:] }
    private var revision: Int { workspace["revision"]?.int ?? 0 }
    private var isRail: Bool { props["sidebar"]?.object?["collapsed"] == .bool(true) }
    private var openDiff: PluginValue? { workspace["openDiff"].flatMap { $0 == .null ? nil : $0 } }
    private var savedCollapsed: Bool { props["state"]?.object?["collapsed"] == .bool(true) }
    private var isCollapsed: Bool { pendingCollapsed ?? savedCollapsed }

    var body: some View {
        // Always a container, even when the rail shows no count, so the load still runs.
        AtomStack(props: StackProps(spacing: 0)) {
            if isRail {
                if let inventory, !inventory.unviewed.isEmpty {
                    AtomText(
                        props: TextProps(text: "\(inventory.unviewed.count)", size: 10, weight: "medium", design: "rounded", color: "secondary"),
                        common: AtomCommon(testID: "collapsed-task-sidebar-count", label: "Changes to review: \(inventory.unviewed.count)")
                    )
                }
            } else {
                AtomStack(props: StackProps(spacing: 0), common: AtomCommon(fillWidth: true)) {
                    header
                    if !isCollapsed { content }
                }
            }
        }
        .task(id: LoadKey(taskID: taskID, revision: revision)) { await load() }
        .onChange(of: taskID) {
            inventory = nil
            loadError = nil
        }
        .onChange(of: savedCollapsed) { pendingCollapsed = nil }
    }

    private func load() async {
        guard !taskID.isEmpty else { return }
        let taskID = taskID
        do {
            let loaded = try await host.bridge("task.changes.list", ["taskID": .string(taskID)], as: WorkspaceChangeInventory.self)
            // A newer revision or another task restarted the load; its result wins.
            guard !Task.isCancelled, taskID == self.taskID else { return }
            inventory = loaded
            loadError = nil
        } catch {
            guard !Task.isCancelled, taskID == self.taskID else { return }
            loadError = Self.message(error)
        }
    }

    private func refresh() {
        Task { try? await host.call("ui", "refreshWorkspace") }
    }

    private func mark(_ command: String, _ entry: WorkspaceChangeEntry? = nil) {
        var arguments: [String: PluginValue] = ["taskID": .string(taskID)]
        if let entry {
            arguments["repository"] = .string(entry.repository)
            arguments["path"] = .string(entry.path)
        }
        Task {
            do {
                try await host.call("bridge", command, arguments)
                try await host.call("ui", "refreshWorkspace")
            } catch {
                loadError = Self.message(error)
            }
        }
    }

    private func toggleCollapsed() {
        let collapsed = !isCollapsed
        pendingCollapsed = collapsed
        Task {
            do {
                try await host.call("bridge", "plugin.state.set", ["pluginID": .string(BuiltInPlugins.changesID), "key": .string("collapsed"), "value": .bool(collapsed)])
            } catch {
                // The section springs back to its saved state; the Git
                // changes themselves still read fine.
                pendingCollapsed = nil
            }
        }
    }

    // MARK: Header

    /// Collapsing hides the lists so later sidebar sections can share the
    /// column, and the pending count stays visible while it's collapsed.
    private var header: some View {
        let collapsedLabel = isCollapsed ? "Expand changes" : "Collapse changes"
        return AtomStack(
            props: StackProps(axis: "h", spacing: 6, group: true),
            common: AtomCommon(testID: "workspace-changes-section-header", fillWidth: true, paddingX: 12, paddingY: 8)
        ) {
            AtomButton(
                common: AtomCommon(testID: "toggle-workspace-changes-section-button", label: collapsedLabel, value: isCollapsed ? "Collapsed" : "Expanded", help: collapsedLabel, width: 14, height: 24),
                action: toggleCollapsed
            ) {
                AtomIcon(props: IconProps(name: isCollapsed ? "chevron.right" : "chevron.down", size: 9, weight: "semibold", color: "secondary"))
            }
            AtomPressArea(common: AtomCommon(fillWidth: true), onPress: toggleCollapsed, onLongPress: {}) {
                AtomStack(props: StackProps(axis: "h", spacing: 6), common: AtomCommon(fillWidth: true)) {
                    AtomText(props: TextProps(text: "Changes", size: 13, weight: "semibold"), common: AtomCommon(testID: "workspace-changes-title"))
                    if isCollapsed, let pending = inventory?.unviewed.count, pending > 0 {
                        AtomText(
                            props: TextProps(text: "\(pending)", size: 10, weight: "medium", design: "rounded", color: "secondary"),
                            common: AtomCommon(testID: "collapsed-workspace-changes-section-count", label: "Changes to review: \(pending)")
                        )
                    }
                    AtomSpacer(props: SpacerProps(minLength: 0))
                }
            }
            AtomButton(
                props: ButtonProps(disabled: inventory == nil && loadError == nil),
                common: AtomCommon(testID: "refresh-workspace-changes-button", label: "Refresh workspace changes", help: "Refresh workspace changes", width: 24, height: 24),
                action: refresh
            ) {
                AtomIcon(props: IconProps(name: "arrow.clockwise", size: 11, weight: "medium"))
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let loadError {
            AtomStack(props: StackProps(spacing: 8, align: "leading", group: true), common: AtomCommon(testID: "workspace-changes-error", fillWidth: true, padding: 12)) {
                AtomLabel(props: LabelProps(text: "Couldn't read Git changes", icon: "exclamationmark.triangle.fill", size: 11, weight: "medium", color: "red"))
                AtomText(props: TextProps(text: loadError, size: 10, color: "secondary", wrap: true))
                AtomButton(props: ButtonProps(style: "automatic"), common: AtomCommon(testID: "retry-workspace-changes-button", label: "Retry", help: "Retry"), action: refresh) {
                    AtomText(props: TextProps(text: "Retry", size: 11, weight: "medium"))
                }
            }
        } else if let inventory {
            if inventory.isEmpty && !inventory.mergingRepositories.isEmpty {
                centered { mergeInProgressNotice(inventory) }
            } else if inventory.isEmpty {
                centered {
                    AtomStack(props: StackProps(spacing: 8, group: true), common: AtomCommon(testID: "workspace-changes-empty", fillWidth: true)) {
                        AtomIcon(props: IconProps(name: "checkmark.circle", size: 20, color: "secondary"))
                        AtomText(props: TextProps(text: "No changes", size: 12, weight: "medium"))
                        AtomText(props: TextProps(text: "Changes in Git repositories under this task's folders will appear here.", size: 10, color: "secondary", wrap: true, align: "center"))
                    }
                }
            } else if inventory.count > Self.maxRenderedChangeCount {
                let message = "\(inventory.count) changed files is more than the \(Self.maxRenderedChangeCount) this list shows. Check for files that should be ignored, such as build output."
                centered {
                    // One element read as its label: a combined element of these texts reads back with an empty label.
                    AtomStack(props: StackProps(spacing: 8, summary: true), common: AtomCommon(testID: "workspace-changes-too-many", label: "Too many changes to list. \(message)", fillWidth: true)) {
                        AtomIcon(props: IconProps(name: "exclamationmark.triangle", size: 20, color: "secondary"))
                        AtomText(props: TextProps(text: "Too many changes to list", size: 12, weight: "medium"))
                        AtomText(props: TextProps(text: message, size: 10, color: "secondary", wrap: true, align: "center"))
                    }
                }
            } else {
                // Lazy, with every header and row a direct child, so off-screen rows stay out of the view
                // and accessibility trees; every row carries AppKit tooltip views. The spacers part the sections.
                AtomScroll(props: ScrollProps(spacing: 4, lazy: true), common: AtomCommon(testID: "workspace-changes-list")) {
                    AtomSpacer(props: SpacerProps(minLength: 8))
                    if !inventory.mergingRepositories.isEmpty {
                        AtomStack(common: AtomCommon(fillWidth: true, paddingX: 14)) {
                            mergeInProgressNotice(inventory)
                        }
                        AtomSpacer(props: SpacerProps(minLength: 7))
                    }
                    section(viewed: true, entries: inventory.viewed, inventory: inventory)
                    AtomSpacer(props: SpacerProps(minLength: 7))
                    section(viewed: false, entries: inventory.unviewed, inventory: inventory)
                    AtomSpacer(props: SpacerProps(minLength: 8))
                }
            }
        } else {
            centered {
                AtomStack(props: StackProps(spacing: 6, summary: true), common: AtomCommon(testID: "workspace-changes-loading", label: "Checking folders…")) {
                    AtomSpinner(props: SpinnerProps(size: "small"))
                    AtomText(props: TextProps(text: "Checking folders…", size: 11))
                }
            }
        }
    }

    /// A notice in the middle of the section's room.
    private func centered(@ViewBuilder _ content: () -> some View) -> some View {
        let notice = content()
        return AtomStack(props: StackProps(spacing: 0), common: AtomCommon(fillWidth: true, padding: 15)) {
            AtomSpacer(props: SpacerProps(minLength: 0))
            notice
            AtomSpacer(props: SpacerProps(minLength: 0))
        }
    }

    /// Shown in place of a repository's files while it has a merge open, since the merge stages
    /// everything the merged branch brought in.
    private func mergeInProgressNotice(_ inventory: WorkspaceChangeInventory) -> some View {
        let message = "Changes in \(inventory.mergingRepositories.map(WorkspaceChangeStyle.repositoryLabel).joined(separator: ", ")) are hidden until the merge is committed or aborted."
        // One element read as its label: a combined element of these texts reads back with an empty label.
        return AtomStack(props: StackProps(spacing: 8, summary: true), common: AtomCommon(testID: "workspace-changes-merge-in-progress", label: "Merge in progress. \(message)", fillWidth: true)) {
            AtomIcon(props: IconProps(name: "arrow.triangle.merge", size: 20, color: "secondary"))
            AtomText(props: TextProps(text: "Merge in progress", size: 12, weight: "medium"))
            AtomText(props: TextProps(text: message, size: 10, color: "secondary", wrap: true, align: "center"))
        }
    }

    // MARK: Sections

    /// A section's header and rows, laid out by the list itself rather than a Stack of their own.
    @ViewBuilder
    private func section(viewed: Bool, entries: [WorkspaceChangeEntry], inventory: WorkspaceChangeInventory) -> some View {
        if viewed {
            // The Viewed section starts folded; its whole header unfolds it.
            AtomPressArea(common: AtomCommon(testID: "viewed-changes-section", fillWidth: true), onPress: { isViewedExpanded.toggle() }, onLongPress: {}) {
                sectionHeader(viewed: true, entries: entries)
            }
        } else {
            AtomStack(props: StackProps(group: true), common: AtomCommon(testID: "unviewed-changes-section", fillWidth: true)) {
                sectionHeader(viewed: false, entries: entries)
            }
        }
        if viewed && !isViewedExpanded {
            EmptyView()
        } else if entries.isEmpty {
            AtomText(props: TextProps(text: "No files", size: 10, color: "tertiary"), common: AtomCommon(paddingX: 31, paddingY: 3))
        } else {
            let showsRepositories = Set((inventory.unviewed + inventory.viewed).map(\.repository)).count > 1
            ForEach(WorkspaceChangeStyle.repositoryGroups(entries), id: \.repository) { group in
                if showsRepositories {
                    AtomText(
                        props: TextProps(text: WorkspaceChangeStyle.repositoryLabel(group.repository), size: 10, weight: "medium", color: "secondary", lineLimit: 1, truncation: "middle"),
                        common: AtomCommon(testID: "workspace-repository-\(WorkspaceChangeStyle.repositoryLabel(group.repository))", paddingX: 17, paddingY: 2)
                    )
                }
                ForEach(group.entries) { entry in row(entry) }
            }
        }
    }

    private func sectionHeader(viewed: Bool, entries: [WorkspaceChangeEntry]) -> some View {
        AtomStack(props: StackProps(axis: "h", spacing: 7), common: AtomCommon(fillWidth: true, paddingX: 14)) {
            AtomIcon(props: IconProps(name: viewed ? "checkmark.circle.fill" : "circle.dashed", size: 10, weight: "semibold", color: viewed ? "green" : "secondary"))
            AtomText(props: TextProps(text: viewed ? "Viewed" : "Changes", size: 11, weight: "semibold", lineLimit: 1), common: AtomCommon(testID: viewed ? "viewed-changes-title" : "unviewed-changes-title"))
            AtomText(props: TextProps(text: "\(entries.count)", size: 10, weight: "medium", design: "rounded", color: "secondary"))
            AtomSpacer(props: SpacerProps(minLength: 0))
            if viewed {
                AtomIcon(props: IconProps(name: isViewedExpanded ? "chevron.down" : "chevron.right", size: 9, weight: "semibold", color: "secondary"))
            } else if !entries.isEmpty {
                AtomButton(common: AtomCommon(testID: "mark-all-viewed-button", label: "Mark all as viewed", help: "Mark all as viewed", width: 20, height: 18), action: { mark("task.changes.mark-all-viewed") }) {
                    AtomIcon(props: IconProps(name: "checklist.checked", size: 11, weight: "medium", color: "secondary"))
                }
            }
        }
    }

    private func isOpen(_ entry: WorkspaceChangeEntry) -> Bool {
        guard let openDiff = openDiff?.object else { return false }
        return openDiff["repository"]?.string == entry.repository && openDiff["path"]?.string == entry.path && openDiff["group"]?.string == entry.group.rawValue
    }

    private func row(_ entry: WorkspaceChangeEntry) -> some View {
        let color = WorkspaceChangeStyle.colorName(for: entry.status)
        let selected = isOpen(entry)
        return AtomStack(props: StackProps(axis: "h", spacing: 2), common: AtomCommon(fillWidth: true, paddingX: 7)) {
            AtomButton(
                common: AtomCommon(
                    testID: "workspace-change-\(entry.group.rawValue)-\(entry.path)",
                    label: "\(entry.path), \(entry.status), \(entry.group.displayName)",
                    // The button is one accessibility element, so the name's color is reported here.
                    value: entry.isUncommitted ? "Uncommitted, green" : "Committed, primary",
                    help: "View \(entry.group.displayName) diff for \(entry.path)",
                    fillWidth: true
                ),
                action: { Task { try? await host.call("ui", "openDiff", Self.value(entry)) } }
            ) {
                AtomStack(
                    props: StackProps(axis: "h", spacing: 7, fill: "accent", fillOpacity: selected ? 0.15 : 0, cornerRadius: 5),
                    common: AtomCommon(fillWidth: true, paddingX: 8, paddingY: 5)
                ) {
                    AtomIcon(props: IconProps(name: WorkspaceChangeStyle.symbol(for: entry.status), size: 10, weight: "medium", color: color), common: AtomCommon(width: 12))
                    AtomText(props: TextProps(text: entry.path, size: 10, design: "monospaced", color: entry.isUncommitted ? "green" : "primary", lineLimit: 1, truncation: "middle"))
                    AtomSpacer(props: SpacerProps(minLength: 0))
                    AtomText(props: TextProps(text: WorkspaceChangeStyle.badge(for: entry), size: 9, weight: "medium", design: "monospaced", color: color))
                }
            }
            if entry.group == .unviewed {
                AtomButton(common: AtomCommon(testID: "mark-viewed-\(entry.path)", label: "Mark \(entry.path) as viewed", help: "Mark as viewed", width: 20, height: 22), action: { mark("task.changes.mark-viewed", entry) }) {
                    AtomIcon(props: IconProps(name: "checkmark.circle", size: 11, weight: "medium", color: "secondary"))
                }
            } else {
                AtomButton(common: AtomCommon(testID: "mark-unviewed-\(entry.path)", label: "Mark \(entry.path) as unviewed", help: "Mark as unviewed", width: 20, height: 22), action: { mark("task.changes.mark-unviewed", entry) }) {
                    AtomIcon(props: IconProps(name: "arrow.uturn.backward.circle", size: 11, weight: "medium", color: "secondary"))
                }
            }
        }
    }

    // MARK: Helpers

    /// The entry as `task.changes.list` returned it, for `ui.openDiff`.
    private static func value(_ entry: WorkspaceChangeEntry) -> [String: PluginValue] {
        guard let data = try? JSONEncoder().encode(entry),
              let value = try? JSONDecoder().decode(PluginValue.self, from: data) else { return [:] }
        return value.object ?? [:]
    }

    private static func message(_ error: Error) -> String {
        (error as? PluginHostError)?.message ?? error.localizedDescription
    }
}
