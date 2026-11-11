import SwiftUI

/// What the Done archive shows, already derived from the loaded or searched
/// completed tasks: plain values the native archive and the catalog's
/// JavaScript copy (catalog/DoneArchive.js, as `Playhouse.props.doneArchive`)
/// compose the same way. `prefix` is empty on the board; the catalog's native
/// copy sets one so the two sides never share accessibility identifiers.
struct DoneArchiveModel: Codable, Equatable {
    /// A row's pull request actions: the Create button while a repository
    /// still awaits one, then a chip per linked pull request.
    struct PullRequests: Codable, Equatable {
        struct Create: Codable, Equatable {
            /// "PR", or "PRs" for several repositories.
            var title: String
            var busy: Bool
            var label: String
            var help: String
        }

        struct Link: Codable, Equatable {
            var number: Int
            var url: String
            /// The repository's folder name, the chip's help.
            var repository: String
        }

        var create: Create?
        var links: [Link]
    }

    struct Row: Codable, Equatable {
        /// The task's UUID.
        var id: String
        var title: String
        /// The task's creation date, formatted.
        var date: String
        /// Only a task with repositories has pull request actions.
        var pullRequests: PullRequests?
    }

    var prefix: String
    var search: String
    var rows: [Row]
    /// Shown instead of the list: No completed tasks, or No matching tasks.
    var emptyMessage: String?
    /// A page or the search is still loading.
    var loading: Bool
    /// "40 tasks loaded", the list's accessibility value.
    var loadedValue: String
    /// The Done status color, as #RRGGBB.
    var accent: String

    init(prefix: String = "", search: String, rows: [Row], emptyMessage: String?, loading: Bool, loadedCount: Int) {
        self.prefix = prefix
        self.search = search
        self.rows = rows
        self.emptyMessage = emptyMessage
        self.loading = loading
        loadedValue = "\(loadedCount) tasks loaded"
        accent = AtomColor.hex(TaskStatus.done.accent)
    }

    /// A completed task's row, its pull request actions as the board offers them.
    static func row(_ task: BoardTask, isCreatingPullRequests: Bool) -> Row {
        Row(
            id: task.id.uuidString,
            title: task.title,
            date: task.createdAt.formatted(date: .long, time: .omitted),
            pullRequests: task.repositoryWorktrees.isEmpty ? nil : pullRequests(task, busy: isCreatingPullRequests)
        )
    }

    private static func pullRequests(_ task: BoardTask, busy: Bool) -> PullRequests {
        let linked = task.repositoryWorktrees.filter { $0.pullRequestNumber != nil && $0.pullRequestURL != nil }
        let awaiting = task.repositoryWorktrees.filter(\.awaitsPullRequest)
        let started = task.repositoryWorktrees.filter { !$0.isPending }
        let hasMultipleRepositories = (awaiting.isEmpty ? started : awaiting).count > 1
        let title = hasMultipleRepositories ? "PRs" : "PR"
        var create: PullRequests.Create?
        if linked.isEmpty {
            create = .init(
                title: title, busy: busy,
                label: hasMultipleRepositories ? "PRs. Create pull requests for each repository linked to this completed task" : "PR. Create a pull request for each repository linked to this completed task",
                help: "Create a pull request for each repository linked to this completed task"
            )
        } else if !awaiting.isEmpty {
            create = .init(
                title: title, busy: busy,
                label: hasMultipleRepositories ? "PRs. Create pull requests for repositories without a linked pull request" : "PR. Create a pull request for the repository without a linked pull request",
                help: "Create pull requests for repositories without a linked pull request"
            )
        }
        // Pull requests merged before a renewed worktree stay listed ahead of the current ones.
        let records = task.pastRepositoryWorktrees.filter { $0.pullRequestNumber != nil && $0.pullRequestURL != nil }.map { ($0.pullRequestNumber, $0.pullRequestURL, $0.repositoryPath) }
            + linked.map { ($0.pullRequestNumber, $0.pullRequestURL, $0.repositoryPath) }
        var seen = Set<String>()
        let links: [PullRequests.Link] = records.compactMap { number, url, path in
            guard let number, let url, seen.insert(url).inserted else { return nil }
            return .init(number: number, url: url, repository: URL(fileURLWithPath: path).lastPathComponent)
        }
        return PullRequests(create: create, links: links)
    }
}

/// What the archive's controls do; the board, or the catalog's demo, owns the state.
struct DoneArchiveActions {
    var close: () -> Void
    var search: (String) -> Void
    /// Opens the task with this id.
    var open: (String) -> Void
    var createPullRequests: (String) -> Void
    /// The end of the list scrolled into view.
    var loadMore: () -> Void
}

/// The Done archive's content, composed only of plugin atoms (Plugins/Atoms),
/// so a plugin building it from the same atoms looks identical: the title and
/// close button, a divider, the search field on a rounded fill, then the empty
/// message or the lazy list of rows, each a button opening its task beside
/// its pull request actions. The board presents it in a SidePanel atom.
struct DoneArchivePanel: View {
    let model: DoneArchiveModel
    let actions: DoneArchiveActions

    private var prefix: String { model.prefix }

    var body: some View {
        AtomStack(props: StackProps(axis: "v", spacing: 0)) {
            AtomStack(props: StackProps(axis: "h"), common: AtomCommon(padding: 16)) {
                AtomText(props: TextProps(text: "Done tasks", size: 14, weight: "semibold"), common: AtomCommon(testID: "\(prefix)done-archive-title"))
                AtomSpacer()
                AtomButton(common: AtomCommon(testID: "\(prefix)close-done-archive-button", label: "Close done tasks", help: "Close done tasks"), action: actions.close) {
                    AtomIcon(props: IconProps(name: "xmark"))
                }
            }
            AtomDivider()
            AtomStack(props: StackProps(axis: "v"), common: AtomCommon(fillWidth: true, padding: 12)) {
                AtomStack(
                    props: StackProps(axis: "h", spacing: 8, fill: "primary", fillOpacity: 0.045, cornerRadius: 9),
                    common: AtomCommon(fillWidth: true, padding: 10)
                ) {
                    AtomIcon(props: IconProps(name: "magnifyingglass", color: "secondary"))
                    AtomTextField(
                        props: TextFieldProps(text: model.search, placeholder: "Search tasks and conversations", style: "plain"),
                        common: AtomCommon(testID: "\(prefix)done-archive-search"),
                        onChange: actions.search
                    )
                    if !model.search.isEmpty {
                        AtomButton(
                            common: AtomCommon(testID: "\(prefix)clear-archive-search-button", label: "Clear archive search", help: "Clear archive search"),
                            action: { actions.search("") }
                        ) {
                            AtomIcon(props: IconProps(name: "xmark.circle.fill", color: "secondary"))
                        }
                    }
                }
            }
            if let message = model.emptyMessage {
                AtomStack(props: StackProps(axis: "v", align: "center", fillOpacity: 0), common: AtomCommon(fillWidth: true)) {
                    AtomSpacer()
                    AtomText(props: TextProps(text: message, size: 12, color: "secondary"), common: AtomCommon(testID: "\(prefix)done-archive-empty-state"))
                    AtomSpacer()
                }
            } else {
                AtomScroll(
                    props: ScrollProps(spacing: 5, lazy: true),
                    common: AtomCommon(testID: "\(prefix)done-archive-list", value: model.loadedValue),
                    onEndReached: actions.loadMore
                ) {
                    ForEach(model.rows, id: \.id) { row in
                        rowView(row)
                    }
                    if model.loading {
                        AtomStack(props: StackProps(axis: "h"), common: AtomCommon(fillWidth: true, padding: 12)) {
                            AtomSpacer()
                            AtomSpinner()
                            AtomSpacer()
                        }
                    }
                }
            }
        }
    }

    private func rowView(_ row: DoneArchiveModel.Row) -> some View {
        AtomStack(props: StackProps(axis: "h", spacing: 0), common: AtomCommon(paddingX: 10)) {
            AtomButton(
                common: AtomCommon(testID: "\(prefix)done-archive-task-\(row.id)", help: "Open task: \(row.title)", fillWidth: true),
                action: { actions.open(row.id) }
            ) {
                AtomStack(props: StackProps(axis: "h", spacing: 10), common: AtomCommon(fillWidth: true, padding: 10)) {
                    AtomIcon(props: IconProps(name: "checkmark.circle.fill", color: model.accent))
                    AtomStack(props: StackProps(axis: "v", spacing: 3, align: "leading")) {
                        AtomText(props: TextProps(text: row.title, size: 12, weight: "medium", lineLimit: 1))
                        AtomText(props: TextProps(text: row.date, size: 10, color: "secondary"))
                    }
                    AtomSpacer(props: SpacerProps(minLength: 0))
                }
            }
            if let pullRequests = row.pullRequests {
                pullRequestControl(row, pullRequests)
                AtomStack(common: AtomCommon(width: 10)) {}
            }
        }
    }

    /// The row's pull request actions, the same atoms as the task item's.
    private func pullRequestControl(_ row: DoneArchiveModel.Row, _ pullRequests: DoneArchiveModel.PullRequests) -> some View {
        AtomStack(props: StackProps(axis: "h", spacing: 5)) {
            if let create = pullRequests.create {
                AtomButton(
                    props: ButtonProps(style: "borderless", emphasis: 4, disabled: create.busy),
                    common: AtomCommon(testID: "\(prefix)done-archive-create-pr-\(row.id)", label: create.label, help: create.help, width: 30, height: 30),
                    action: { actions.createPullRequests(row.id) }
                ) {
                    if create.busy {
                        AtomSpinner(props: SpinnerProps(size: "mini"))
                    } else {
                        AtomText(props: TextProps(text: create.title, size: 10, weight: "semibold"))
                    }
                }
            }
            ForEach(pullRequests.links, id: \.url) { link in
                // The chip stays compact; the click target keeps the 30 pt minimum of its sibling actions.
                AtomLink(
                    props: LinkProps(url: link.url, emphasis: 5),
                    common: AtomCommon(testID: "\(prefix)done-archive-pr-link-\(row.id)-\(link.number)", help: link.repository, minWidth: 30, minHeight: 30)
                ) {
                    AtomText(props: TextProps(text: "#\(link.number)", size: 10, weight: "semibold", design: "monospaced"))
                }
            }
        }
    }
}

/// The board header's Done archive button, the same Button atom the catalog's copy uses.
struct DoneArchiveButton: View {
    var testID = "done-archive-button"
    let action: () -> Void

    var body: some View {
        AtomButton(
            props: ButtonProps(style: "bordered"),
            common: AtomCommon(testID: testID, label: "Done tasks", help: "Browse completed tasks"),
            action: action
        ) {
            AtomIcon(props: IconProps(name: "archivebox", size: 14, weight: "semibold"), common: AtomCommon(width: 30, height: 30))
        }
    }
}
