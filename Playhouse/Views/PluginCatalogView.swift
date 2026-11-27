import Foundation
import PlayhouseCore
import PlayhouseAtoms
import PlayhouseUI

/// Renders one plugin script: its runtime's node tree through the atom
/// registry, any errors, and what its last commit changed.
package struct PluginSurface: PHView {
    package let source: String
    package let name: String
    package var props: [String: PluginValue] = [:]
    @PHState private var runtime: PluginRuntime?
    @PHState private var loadError: String?

    package var body: some PHView {
        AtomStack(props: StackProps(spacing: 10, align: "leading")) {
            if let runtime {
                PHForEach(runtime.tree.root.children) { node in
                    PluginNodeView(node: node, events: runtime)
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

    package init(source: String, name: String, props: [String: PluginValue] = [:]) {
        self.source = source
        self.name = name
        self.props = props
    }
}

private struct PluginErrors: PHView {
    let errors: [String]

    var body: some PHView {
        PHForEach(Array(errors.enumerated()), id: \.offset) { _, error in
            AtomText(props: TextProps(text: error, size: 11, design: "monospaced", color: "red", selectable: true), common: AtomCommon(testID: "plugin-error"))
        }
    }
}

/// "Commit 3: text → node 36". It reads only `lastCommit`, so it updates once per commit.
private struct PluginCommitReadout: PHView {
    let tree: PluginNodeTree

    var body: some PHView {
        if let commit = tree.lastCommit {
            let summary = commit.number == 1
                ? "Commit 1: initial render, \(commit.ops.count) ops"
                : "Commit \(commit.number): \(commit.ops.joined(separator: ", ")) → \(commit.touchedNodes.count == 1 ? "node" : "nodes") \(commit.touchedNodes.map(String.init).joined(separator: ", "))"
            AtomText(props: TextProps(text: summary, size: 10, design: "monospaced", color: "tertiary"), common: AtomCommon(testID: "plugin-last-commit"))
        }
    }
}

/// The Plugins menu's catalog: every atom rendered by its JavaScript page, and
/// the native composites (the task item, the Agents info section, the Token
/// Stats modal, the Skills page, the repository chips and picker, the
/// composer, the Done archive) composed in JavaScript beside the native ones.
package struct PluginCatalogView: PHView {
    private enum Page: Hashable {
        case atom(AtomType)
        case taskItem
        case agentsInfo
        case kanbanColumn
        case tokenStats
        case skillsPage
        case repositoryChips
        case composer
        case doneArchive
    }

    @PHState private var selection: Page? = .atom(.stack)

    package var body: some PHView {
        PHNavigationSplitView {
            // A Scroll of selectable rows, in the sidebar's look: section headers, then
            // rows where the selected one is filled with the accent color.
            AtomScroll(props: ScrollProps(spacing: 0, inset: 10)) {
                sidebarHeader("Atoms", first: true)
                PHForEach(AtomType.allCases, id: \.self) { atom in
                    sidebarRow(atom.rawValue, page: .atom(atom), testID: "plugin-catalog-atom-\(atom.rawValue)")
                }
                sidebarHeader("Examples")
                sidebarRow("Task Item", page: .taskItem, testID: "plugin-catalog-task-item")
                sidebarRow("Agents Info", page: .agentsInfo, testID: "plugin-catalog-agents-info")
                sidebarRow("Kanban Column", page: .kanbanColumn, testID: "plugin-catalog-kanban-column")
                sidebarRow("Token Stats", page: .tokenStats, testID: "plugin-catalog-token-stats")
                sidebarRow("Skills Page", page: .skillsPage, testID: "plugin-catalog-skills-page")
                sidebarRow("Repository Chips", page: .repositoryChips, testID: "plugin-catalog-repository-chips")
                sidebarRow("Composer", page: .composer, testID: "plugin-catalog-composer")
                sidebarRow("Done Archive", page: .doneArchive, testID: "plugin-catalog-done-archive")
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            AtomScroll {
                PHGroup {
                    switch selection {
                    case .atom(let atom)?:
                        AtomCatalogPage(atom: atom).id(atom)
                    case .taskItem?:
                        TaskItemComparison()
                    case .agentsInfo?:
                        AgentsInfoComparison()
                    case .kanbanColumn?:
                        KanbanColumnComparison()
                    case .tokenStats?:
                        TokenStatsComparison()
                    case .skillsPage?:
                        SkillsPageComparison()
                    case .repositoryChips?:
                        RepositoryChipsComparison()
                    case .composer?:
                        ComposerComparison()
                    case .doneArchive?:
                        DoneArchiveComparison()
                    case nil:
                        PHEmptyView()
                    }
                }
            }
        }
    }

    /// A sidebar section's title.
    private func sidebarHeader(_ title: String, first: Bool = false) -> some PHView {
        AtomText(
            props: TextProps(text: title, size: 11, weight: "semibold", color: "secondary"),
            common: AtomCommon(paddingTop: first ? 4 : 12, paddingBottom: 4, paddingLeading: 8)
        )
    }

    /// A sidebar row that selects its page; the selected one is marked selected.
    private func sidebarRow(_ title: String, page: Page, testID: String) -> some PHView {
        let selected = selection == page
        return AtomButton(props: ButtonProps(selected: selected), common: AtomCommon(testID: testID, fillWidth: true), action: { selection = page }) {
            AtomStack(props: StackProps(align: "leading", fill: selected ? "accent" : "clear", cornerRadius: 5), common: AtomCommon(fillWidth: true, paddingX: 8, paddingY: 6)) {
                AtomText(props: TextProps(text: title, size: 13, color: selected ? "white" : "primary", lineLimit: 1))
            }
        }
    }

    package init() {}
}

@MainActor
private func catalogPage(_ page: String) -> (source: String, props: [String: PluginValue])? {
    catalogValue(page) { try PluginRenderCommand.catalogPage(page, resources: PluginRuntime.bundledResources) }
}

/// A page's bundled script or decoded sample. A page that cannot load renders
/// only its title, so the reason goes to diagnostics.
@MainActor
private func catalogValue<Value>(_ page: String, _ load: () throws -> Value) -> Value? {
    do {
        return try load()
    } catch {
        var fields = PlayhouseDiagnostics.errorFields(error)
        fields["page"] = page
        fields["error"] = String(describing: error)
        PlayhouseDiagnostics.record("plugin.catalog.page_failed", fields: fields)
        return nil
    }
}

/// A catalog page: its title, then its content, inset 24 and as wide as the detail.
private func catalogPageColumn<Content: PHView>(_ title: String, @PHViewBuilder content: @escaping () -> Content) -> some PHView {
    AtomStack(props: StackProps(spacing: 18, align: "leading"), common: AtomCommon(fillWidth: true, paddingX: 24, paddingY: 24)) {
        AtomText(props: TextProps(text: title, size: 17, weight: "semibold"), common: AtomCommon(testID: "plugin-catalog-title"))
        content()
    }
}

/// One side of a composite's comparison page, one accessibility container named `testID`.
private func comparisonColumn<Content: PHView>(_ title: String, width: CGFloat, testID: String, @PHViewBuilder content: @escaping () -> Content) -> some PHView {
    AtomStack(props: StackProps(spacing: 10, align: "leading", group: true), common: AtomCommon(testID: testID, width: Double(width), frameAlign: "leading")) {
        AtomText(props: TextProps(text: title, size: 13, weight: "bold"))
        content()
    }
}

/// Two comparison columns side by side.
private func comparisonRow<Content: PHView>(@PHViewBuilder content: @escaping () -> Content) -> some PHView {
    AtomStack(props: StackProps(axis: "h", spacing: 28, align: "top"), content: content)
}

private struct AtomCatalogPage: PHView {
    let atom: AtomType

    var body: some PHView {
        catalogPageColumn(atom.rawValue) {
            if let page = catalogPage(atom.rawValue) {
                AtomStack(
                    props: StackProps(align: "leading", group: true, fill: "primary", fillOpacity: 0.04, cornerRadius: 10),
                    common: AtomCommon(testID: "plugin-catalog-surface", fillWidth: true, paddingX: 16, paddingY: 16)
                ) {
                    PluginSurface(source: page.source, name: "\(atom.rawValue).js", props: page.props)
                }
            }
            AtomStack(props: StackProps(spacing: 4, align: "leading")) {
                AtomText(props: TextProps(text: "Props", size: 13, weight: "bold"))
                AtomText(
                    props: TextProps(text: atom.propKeys.isEmpty ? "none of its own" : atom.propKeys.sorted().joined(separator: ", "), size: 11, design: "monospaced"),
                    common: AtomCommon(testID: "plugin-catalog-props")
                )
                if !atom.events.isEmpty {
                    AtomText(props: TextProps(text: "Events: \(atom.events.sorted().joined(separator: ", "))", size: 11, design: "monospaced"))
                }
                AtomText(props: TextProps(text: "Every atom also takes: \(AtomCommon.keys.sorted().joined(separator: ", "))", size: 11, color: "secondary"))
            }
        }
    }
}

/// The JavaScript task item beside the native one, from the same sample model.
/// Each side keeps its own state; the native card uses a "native-" id so the
/// two never share accessibility identifiers.
private struct TaskItemComparison: PHView {
    var body: some PHView {
        catalogPageColumn("Task Item") {
            if let page = catalogPage("TaskItem"),
               let sample = catalogValue("TaskItem", { try Self.sample(page.props) }) {
                comparisonRow {
                    comparisonColumn("JavaScript (React → atoms)", width: 300, testID: "plugin-catalog-js-task-item") {
                        PluginSurface(source: page.source, name: "TaskItem.js", props: page.props)
                    }
                    comparisonColumn("Native SwiftUI (atoms)", width: 300, testID: "plugin-catalog-native-task-item") {
                        NativeTaskItemDemo(sample: sample)
                    }
                }
            }
        }
    }

    struct Sample: Decodable {
        package var task: TaskItemModel
        package var blockedStatusMessage: String
    }

    static func sample(_ props: [String: PluginValue]) throws -> Sample {
        try PluginValueDecoder.decode(Sample.self, from: .object(props))
    }
}

/// The native task item with the same demo controls as TaskItem.js, built from the same atoms.
private struct NativeTaskItemDemo: PHView {
    let sample: TaskItemComparison.Sample
    @PHState private var blocked = false
    @PHState private var opened = 0
    @PHState private var lastAction = "none"

    private var model: TaskItemModel {
        var task = sample.task
        task.id = "native-\(task.id)"
        if blocked {
            task.statusMessage = sample.blockedStatusMessage
            task.statusIsBlocked = true
        }
        return task
    }

    var body: some PHView {
        AtomStack(props: StackProps(axis: "v", spacing: 12, align: "leading")) {
            TaskItemView(model: model, actions: TaskItemActions(
                open: { opened += 1 },
                menu: { lastAction = "menu \($0)" },
                showTokenStats: { lastAction = "token stats" }
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
private struct AgentsInfoComparison: PHView {
    var body: some PHView {
        catalogPageColumn("Agents Info") {
            if let page = catalogPage("AgentsInfo"),
               let sample = catalogValue("AgentsInfo", { try Self.sample(page.props) }) {
                comparisonRow {
                    comparisonColumn("JavaScript (React → atoms)", width: 240, testID: "plugin-catalog-js-agents-info") {
                        PluginSurface(source: page.source, name: "AgentsInfo.js", props: page.props)
                    }
                    comparisonColumn("Native SwiftUI (atoms)", width: 240, testID: "plugin-catalog-native-agents-info") {
                        NativeAgentsInfoDemo(sample: sample)
                    }
                }
            }
        }
    }

    struct Sample: Decodable {
        package var agentsInfo: AgentsInfoModel
    }

    static func sample(_ props: [String: PluginValue]) throws -> Sample {
        try PluginValueDecoder.decode(Sample.self, from: .object(props))
    }
}

/// The native Agents info section with the same demo controls as AgentsInfo.js, built from the same atoms.
private struct NativeAgentsInfoDemo: PHView {
    let sample: AgentsInfoComparison.Sample
    @PHState private var collapsed = false
    @PHState private var signedOut = false
    @PHState private var lastAction = "none"

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

    var body: some PHView {
        // As wide as the board sidebar's content.
        AtomStack(props: StackProps(axis: "v", spacing: 12, align: "leading")) {
            AtomStack(props: StackProps(axis: "v"), common: AtomCommon(width: 160)) {
                // Like a Main sidebar bottom section: its host's header, the content 6 points below.
                AtomDisclosure(
                    props: DisclosureProps(title: model.title, collapsed: collapsed, spacing: 6, toggleTestID: "\(model.id)-toggle"),
                    common: AtomCommon(testID: model.id),
                    onToggle: { lastAction = collapsed ? "expand" : "collapse"; collapsed.toggle() }
                ) {
                    AgentsInfoSection(model: model, actions: AgentsInfoActions(
                        login: { signedOut = false; lastAction = "login \($0)" },
                        switchAccount: { lastAction = "switch \($0)" }
                    ))
                }
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

/// The JavaScript board columns beside the native ones, from the same sample
/// models (264 points wide, the board's column width, with no cards). The
/// native side uses a "native-" id prefix so the two never share
/// accessibility identifiers.
private struct KanbanColumnComparison: PHView {
    var body: some PHView {
        catalogPageColumn("Kanban Column") {
            if let page = catalogPage("KanbanColumn"),
               let sample = catalogValue("KanbanColumn", { try Self.sample(page.props) }) {
                comparisonRow {
                    comparisonColumn("JavaScript (React → atoms)", width: 264, testID: "plugin-catalog-js-kanban-column") {
                        PluginSurface(source: page.source, name: "KanbanColumn.js", props: page.props)
                    }
                    comparisonColumn("Native SwiftUI (atoms)", width: 264, testID: "plugin-catalog-native-kanban-column") {
                        NativeKanbanColumnDemo(sample: sample)
                    }
                }
            }
        }
    }

    struct Sample: Decodable {
        package var kanbanColumns: [KanbanColumnModel]
    }

    static func sample(_ props: [String: PluginValue]) throws -> Sample {
        try PluginValueDecoder.decode(Sample.self, from: .object(props))
    }
}

/// The native columns with the same demo readout as KanbanColumn.js, built from the same atoms.
private struct NativeKanbanColumnDemo: PHView {
    let sample: KanbanColumnComparison.Sample
    @PHState private var lastAction = "none"

    private func nativeModel(_ column: KanbanColumnModel) -> KanbanColumnModel {
        var model = column
        model.idPrefix = "native-"
        return model
    }

    var body: some PHView {
        AtomStack(props: StackProps(axis: "v", spacing: 12, align: "leading")) {
            PHForEach(sample.kanbanColumns, id: \.key) { column in
                AtomStack(props: StackProps(axis: "v"), common: AtomCommon(width: 264)) {
                    KanbanColumnSection(model: nativeModel(column), minHeight: 170, testID: "native-column-\(column.key)", onAdd: { lastAction = "add" }) {
                        PHEmptyView()
                    }
                }
            }
            AtomText(props: TextProps(text: "Last: \(lastAction)", size: 11, color: "secondary"), common: AtomCommon(testID: "native-last-action"))
        }
    }
}

/// The JavaScript Token Stats modal above the native one (each is 720 points
/// wide), from the same sample model, each opened by the task item's token
/// counter. Each side keeps its own section and open state; the native modal
/// uses a "native-token-stats" id so the two never share accessibility
/// identifiers.
private struct TokenStatsComparison: PHView {
    var body: some PHView {
        catalogPageColumn("Token Stats") {
            if let page = catalogPage("TokenStats"),
               let sample = catalogValue("TokenStats", { try Self.sample(page.props) }) {
                comparisonColumn("JavaScript (React → atoms)", width: 740, testID: "plugin-catalog-js-token-stats") {
                    PluginSurface(source: page.source, name: "TokenStats.js", props: page.props)
                }
                comparisonColumn("Native SwiftUI (atoms)", width: 740, testID: "plugin-catalog-native-token-stats") {
                    NativeTokenStatsDemo(sample: sample)
                }
            }
        }
    }

    struct Sample: Decodable {
        package var tokenCounter: TaskItemModel.Tokens
        package var tokenStats: TokenStatsModel
    }

    static func sample(_ props: [String: PluginValue]) throws -> Sample {
        try PluginValueDecoder.decode(Sample.self, from: .object(props))
    }
}

/// The native Token Stats modal with the same demo controls as TokenStats.js, built from the same atoms.
private struct NativeTokenStatsDemo: PHView {
    let sample: TokenStatsComparison.Sample
    @PHState private var section = "overview"
    @PHState private var open = true
    @PHState private var lastAction = "none"

    private var model: TokenStatsModel {
        var model = sample.tokenStats
        model.id = "native-\(model.id)"
        return model
    }

    var body: some PHView {
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
                AtomPanel(props: PanelProps(fillOpacity: 0.03, cornerRadius: 10), common: AtomCommon(testID: "native-token-stats-modal", padding: 0)) {
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

/// The JavaScript Skills page above the native one (each as wide as the
/// modal, 403 points, and 520 tall), from the same
/// sample model, each opened by the composer's Skills button. Each side keeps its own page state; the native page uses a
/// "native-" prefix so the two never share accessibility identifiers.
private struct SkillsPageComparison: PHView {
    var body: some PHView {
        catalogPageColumn("Skills Page") {
            if let page = catalogPage("SkillsPage"),
               let sample = catalogValue("SkillsPage", { try Self.sample(page.props) }) {
                AtomScroll(props: ScrollProps(axis: "horizontal")) {
                    AtomStack(props: StackProps(spacing: 18, align: "leading")) {
                        comparisonColumn("JavaScript (React → atoms)", width: 740, testID: "plugin-catalog-js-skills-page") {
                            PluginSurface(source: page.source, name: "SkillsPage.js", props: page.props)
                        }
                        comparisonColumn("Native SwiftUI (atoms)", width: 740, testID: "plugin-catalog-native-skills-page") {
                            NativeSkillsPageDemo(sample: sample)
                        }
                    }
                    .hoverRevealScrollers()
                }
                .accessibilityIdentifier("plugin-catalog-skills-page-scroll")
            }
        }
    }

    struct Sample: Decodable {
        package var skillsPage: SkillsPageModel
    }

    static func sample(_ props: [String: PluginValue]) throws -> Sample {
        try PluginValueDecoder.decode(Sample.self, from: .object(props))
    }
}

/// The native Skills page with the same demo state as SkillsPage.js, built from the same atoms.
private struct NativeSkillsPageDemo: PHView {
    let sample: SkillsPageComparison.Sample
    @PHState private var open = true
    @PHState private var kind: String?
    @PHState private var scrollTo: String?
    @PHState private var scrollRequest = 0
    @PHState private var search: String?
    @PHState private var selection: [String]?
    @PHState private var switched: [String: Bool] = [:]
    @PHState private var collapsed: [String: Bool] = [:]
    @PHState private var lastAction = "none"

    /// The demo's state applied to the sample, as SkillsPageView applies it to the catalog.
    private var model: SkillsPageModel {
        var model = sample.skillsPage
        model.prefix = "native-"
        model.kind = kind ?? model.kind
        model.scrollTo = scrollTo ?? model.scrollTo
        model.scrollRequest = scrollRequest
        model.search = search ?? model.search
        model.selection = selection
        let chosen = model.groups.flatMap(\.sections).flatMap(\.rows).filter { selection?.contains($0.id) == true }
        model.selectionCount = SkillsPageModel.selectionCount(chosen.count)
        model.canFixSelection = chosen.contains(where: \.fixable)
        for group in model.groups.indices {
            if let isCollapsed = collapsed[model.groups[group].value] { model.groups[group].collapsed = isCollapsed }
            for section in model.groups[group].sections.indices {
                for row in model.groups[group].sections[section].rows.indices {
                    let id = model.groups[group].sections[section].rows[row].id
                    if let enabled = switched[id] { model.groups[group].sections[section].rows[row].enabled = enabled }
                }
            }
        }
        return model
    }

    private func shownRow(_ id: String) -> SkillsPageModel.Row? {
        model.groups.flatMap(\.sections).flatMap(\.rows).first { $0.id == id }
    }

    private var actions: SkillsPageActions {
        SkillsPageActions(
            back: { open = false; lastAction = "back" },
            selectKind: { kind = $0; lastAction = "kind \($0)" },
            jump: { collapsed[$0] = false; scrollTo = $0; scrollRequest += 1; lastAction = "jump \($0)" },
            search: { search = $0; lastAction = "search \($0)" },
            newSkill: { lastAction = "new skill" },
            fixSelected: { lastAction = "fix \(selection?.count ?? 0) selected" },
            deleteSelected: { lastAction = "delete \(selection?.count ?? 0) selected" },
            endSelection: { selection = nil; lastAction = "done selecting" },
            press: { id in
                guard let row = shownRow(id) else { return }
                if let chosen = selection {
                    guard row.editable else { return }
                    let isChosen = chosen.contains(id)
                    selection = isChosen ? chosen.filter { $0 != id } : chosen + [id]
                    lastAction = (isChosen ? "deselect " : "select ") + row.name
                } else {
                    lastAction = (row.opensOnClick ? "open " : "press ") + row.name
                }
            },
            longPress: { id in
                guard let row = shownRow(id), row.editable else { return }
                let chosen = selection ?? []
                selection = chosen.contains(id) ? chosen : chosen + [id]
                lastAction = "select \(row.name)"
            },
            fix: { id in lastAction = "fix \(shownRow(id)?.name ?? id)" },
            toggleGroup: { value in
                guard let group = model.groups.first(where: { $0.value == value }) else { return }
                collapsed[value] = !group.collapsed
                lastAction = "\(group.collapsed ? "expand" : "collapse") \(value)"
            },
            menu: { id, item in
                guard let row = shownRow(id) else { return }
                if item == "toggle" {
                    switched[id] = !row.enabled
                    lastAction = "toggle \(row.name) \(row.enabled ? "off" : "on")"
                } else {
                    lastAction = item == "use" ? "use \(row.name)" : "menu \(row.name) \(item)"
                }
            }
        )
    }

    var body: some PHView {
        let model = model
        AtomStack(props: StackProps(axis: "v", spacing: 12, align: "leading")) {
            AtomStack(props: StackProps(axis: "h", spacing: 8)) {
                AtomText(props: TextProps(text: "Skills button", size: 11, color: "secondary"))
                SkillsButton(testID: "native-open-skills-button") {
                    open = true
                    lastAction = "open"
                }
                AtomText(props: TextProps(text: "Last: \(lastAction)", size: 11, color: "secondary"), common: AtomCommon(testID: "native-last-action"))
            }
            if open {
                AtomPanel(props: PanelProps(spacing: 0, fill: "window", fillOpacity: 1, cornerRadius: 14), common: AtomCommon(testID: "native-skills-page", width: TaskConversationView.skillsPageWidth, height: 520, padding: 0)) {
                    SkillsPageHeader(model: model, actions: actions)
                    AtomDivider()
                    if model.kind == "skills" {
                        SkillGalleryView(model: model, actions: actions)
                    } else {
                        AtomText(props: TextProps(text: "The Rules and MCP lists stay native.", size: 12, color: "secondary"), common: AtomCommon(testID: "native-skills-native-list", padding: 20))
                    }
                }
            }
        }
    }
}

/// The JavaScript repository chips and picker beside the native ones, from the
/// same sample models. The header presents the picker as a popover from the
/// + button; here each side shows it in a panel under its chips, and its +
/// button shows and hides it. Each side keeps its own state; the native side
/// uses a "native-" prefix so the two never share accessibility identifiers.
private struct RepositoryChipsComparison: PHView {
    var body: some PHView {
        catalogPageColumn("Repository Chips") {
            if let page = catalogPage("RepositoryChips"),
               let sample = catalogValue("RepositoryChips", { try Self.sample(page.props) }) {
                comparisonRow {
                    comparisonColumn("JavaScript (React → atoms)", width: 360, testID: "plugin-catalog-js-repository-chips") {
                        PluginSurface(source: page.source, name: "RepositoryChips.js", props: page.props)
                    }
                    comparisonColumn("Native SwiftUI (atoms)", width: 360, testID: "plugin-catalog-native-repository-chips") {
                        NativeRepositoryChipsDemo(sample: sample)
                    }
                }
            }
        }
    }

    struct Sample: Decodable {
        package var repositoryChips: RepositoryChipsModel
        package var repositoryPicker: RepositoryPickerModel
    }

    static func sample(_ props: [String: PluginValue]) throws -> Sample {
        try PluginValueDecoder.decode(Sample.self, from: .object(props))
    }
}

/// The native chips and picker with the same demo state as RepositoryChips.js, built from the same atoms.
private struct NativeRepositoryChipsDemo: PHView {
    let sample: RepositoryChipsComparison.Sample
    @PHState private var chips: [RepositoryChipsModel.Chip]?
    @PHState private var open = true
    @PHState private var search: String?
    @PHState private var highlighted: Int?
    @PHState private var lastAction = "none"

    private var chipsModel: RepositoryChipsModel {
        var model = sample.repositoryChips
        model.prefix = "native-"
        model.chips = chips ?? model.chips
        return model
    }

    private var pickerModel: RepositoryPickerModel {
        var model = sample.repositoryPicker
        model.prefix = "native-"
        model.search = search ?? model.search
        model.highlighted = highlighted ?? model.highlighted
        return model
    }

    private func name(_ path: String, in names: [(path: String, name: String)]) -> String {
        names.first { $0.path == path }?.name ?? path
    }

    var body: some PHView {
        let chipsModel = chipsModel
        let pickerModel = pickerModel
        let chipNames = chipsModel.chips.map { (path: $0.id, name: $0.name) }
        let repositoryNames = pickerModel.repositories.map { (path: $0.path, name: $0.name) }
        AtomStack(props: StackProps(axis: "v", spacing: 12, align: "leading")) {
            AtomText(props: TextProps(text: "Last: \(lastAction)", size: 11, color: "secondary"), common: AtomCommon(testID: "native-last-action"))
            RepositoryChipsView(model: chipsModel, actions: RepositoryChipsActions(
                edit: { lastAction = "edit \(name($0, in: chipNames))" },
                remove: { path in
                    chips = chipsModel.chips.filter { $0.id != path }
                    lastAction = "remove \(name(path, in: chipNames))"
                },
                add: {
                    lastAction = open ? "close picker" : "open picker"
                    open.toggle()
                }
            ))
            if open {
                AtomPanel(
                    props: PanelProps(fill: "window", fillOpacity: 1, cornerRadius: 10, stroke: "primary", strokeOpacity: 0.12),
                    common: AtomCommon(testID: "native-repository-picker-panel", padding: 0)
                ) {
                    RepositoryPickerView(model: pickerModel, actions: RepositoryPickerActions(
                        chooseParent: { lastAction = "choose folder" },
                        search: { text in
                            search = text
                            highlighted = 0
                            lastAction = "search \(text)"
                        },
                        arrow: { direction in
                            let count = pickerModel.repositories.count
                            highlighted = direction == "down" ? min(pickerModel.highlighted + 1, count - 1) : max(pickerModel.highlighted - 1, 0)
                            lastAction = direction
                        },
                        submit: {
                            let shown = pickerModel.repositories
                            open = false
                            lastAction = "submit \(shown.indices.contains(pickerModel.highlighted) ? shown[pickerModel.highlighted].name : "saved")"
                        },
                        select: { path in
                            open = false
                            lastAction = "select \(name(path, in: repositoryNames))"
                        },
                        replace: { path in
                            open = false
                            lastAction = "replace \(name(path, in: repositoryNames))"
                        }
                    ))
                }
            }
        }
    }
}

/// The JavaScript composer box above the native one, from the same sample
/// model, each 764 points wide (the conversation's composer column). Each side keeps its own state; the native one
/// uses a "native-" prefix so the two never share accessibility identifiers.
private struct ComposerComparison: PHView {
    var body: some PHView {
        catalogPageColumn("Composer") {
            if let page = catalogPage("Composer"),
               let sample = catalogValue("Composer", { try Self.sample(page.props) }) {
                comparisonColumn("JavaScript (React → atoms)", width: 784, testID: "plugin-catalog-js-composer") {
                    PluginSurface(source: page.source, name: "Composer.js", props: page.props)
                }
                comparisonColumn("Native SwiftUI (atoms)", width: 784, testID: "plugin-catalog-native-composer") {
                    NativeComposerDemo(sample: sample)
                }
            }
        }
    }

    struct Sample: Decodable {
        package var composer: ComposerModel
    }

    static func sample(_ props: [String: PluginValue]) throws -> Sample {
        try PluginValueDecoder.decode(Sample.self, from: .object(props))
    }
}

/// The native composer box with the same demo state as Composer.js, built from the same atoms.
private struct NativeComposerDemo: PHView {
    let sample: ComposerComparison.Sample
    @PHState private var draft = ""
    @PHState private var mode = "default"
    @PHState private var optimizedContext = false
    @PHState private var provider = "claude"
    @PHState private var modelID = "claude-sonnet-5-5"
    @PHState private var effort = "medium"
    @PHState private var pickerOpen = false
    @PHState private var scheduleOpen = false
    @PHState private var lastAction = "none"

    /// The demo's state applied to the sample, as the conversation applies its own.
    private var model: ComposerModel {
        var model = sample.composer
        let goal = mode == "goal"
        let plan = mode == "plan"
        let title = provider == "codex" ? "Codex" : "Claude"
        model.prefix = "native-"
        model.draft = draft
        if goal { model.placeholder = "Set a goal to keep pursuing" }
        model.plan.on = plan
        model.optimizedContext?.on = optimizedContext
        model.goal?.on = goal
        if !plan { model.startImplementing = nil }
        model.provider.title = title
        model.provider.value = provider
        model.provider.label = "Provider: \(title)"
        model.provider.items = model.provider.items.map { var item = $0; item.checked = item.id == provider; return item }
        if var picker = model.model {
            let picked = picker.models.first { $0.id == modelID }
            let effortChoice = picker.effortChoices.first { $0.value == effort }
            picker.name = picked?.title ?? ""
            picker.effort = effortChoice?.label ?? ""
            picker.label = "Model: \(picked?.title ?? ""), effort: \(effortChoice?.label ?? "")"
            picker.open = pickerOpen
            picker.selectedEffort = effort
            picker.models = picker.models.map { var item = $0; item.checked = item.id == modelID; return item }
            model.model = picker
        }
        model.schedule?.open = scheduleOpen
        model.primary.disabled = draft.trimmingCharacters(in: .whitespaces).isEmpty && !goal
        return model
    }

    private var actions: ComposerActions {
        ComposerActions(
            change: { draft = $0; lastAction = "edit" },
            submit: { lastAction = "submit \(draft)"; draft = "" },
            steer: { lastAction = "steer" },
            focusChange: { _ in },
            openSkills: { lastAction = "skills" },
            attach: { lastAction = "attach" },
            togglePlan: {
                mode = mode == "plan" ? "default" : "plan"
                lastAction = mode == "plan" ? "plan on" : "plan off"
            },
            toggleOptimizedContext: {
                optimizedContext.toggle()
                lastAction = optimizedContext ? "optimized context on" : "optimized context off"
            },
            toggleGoal: {
                mode = mode == "goal" ? "default" : "goal"
                if mode == "goal" { draft = "" }
                lastAction = mode == "goal" ? "goal on" : "goal off"
            },
            startImplementing: { mode = "default"; lastAction = "start implementing" },
            showRepositoryPicker: { lastAction = "repository picker" },
            provider: { provider = $0; lastAction = "provider \($0)" },
            toggleModelPicker: { pickerOpen.toggle(); lastAction = pickerOpen ? "model picker open" : "model picker closed" },
            dismissModelPicker: { pickerOpen = false; lastAction = "model picker closed" },
            selectModel: { modelID = $0; lastAction = "model \($0)" },
            selectEffort: { effort = $0; lastAction = "effort \($0)" },
            toggleSchedule: { scheduleOpen.toggle(); lastAction = scheduleOpen ? "schedule open" : "schedule closed" },
            dismissSchedule: { scheduleOpen = false; lastAction = "schedule closed" },
            primary: { lastAction = "send \(draft)"; draft = "" }
        )
    }

    var body: some PHView {
        let model = model
        AtomStack(props: StackProps(axis: "v", spacing: 12, align: "leading")) {
            AtomText(props: TextProps(text: "Last: \(lastAction)", size: 11, color: "secondary"), common: AtomCommon(testID: "native-last-action"))
            AtomStack(props: StackProps(axis: "v"), common: AtomCommon(width: 764)) {
                ComposerView(model: model, actions: actions, header: { PHEmptyView() }, scheduleContent: {
                    AtomText(props: TextProps(text: "The schedule hint stays native.", size: 12), common: AtomCommon(testID: "native-schedule-hint", padding: 12))
                })
            }
        }
    }
}

/// The JavaScript Done archive above the native one, from the same sample
/// model, each opened by the board header's archive button into a SidePanel
/// atom over a 560 by 460 point stand-in for the board. Each side keeps its own
/// open state and search; the native side uses a "native-" prefix so the two
/// never share accessibility identifiers.
private struct DoneArchiveComparison: PHView {
    var body: some PHView {
        catalogPageColumn("Done Archive") {
            if let page = catalogPage("DoneArchive"),
               let sample = catalogValue("DoneArchive", { try Self.sample(page.props) }) {
                comparisonColumn("JavaScript (React → atoms)", width: 580, testID: "plugin-catalog-js-done-archive") {
                    PluginSurface(source: page.source, name: "DoneArchive.js", props: page.props)
                }
                comparisonColumn("Native SwiftUI (atoms)", width: 580, testID: "plugin-catalog-native-done-archive") {
                    NativeDoneArchiveDemo(sample: sample)
                }
            }
        }
    }

    struct Sample: Decodable {
        package var doneArchive: DoneArchiveModel
    }

    static func sample(_ props: [String: PluginValue]) throws -> Sample {
        try PluginValueDecoder.decode(Sample.self, from: .object(props))
    }
}

/// The native Done archive with the same demo state as DoneArchive.js, built from the same atoms.
private struct NativeDoneArchiveDemo: PHView {
    let sample: DoneArchiveComparison.Sample
    @PHState private var open = true
    @PHState private var search = ""
    @PHState private var reachedEnd = false
    @PHState private var lastAction = "none"

    /// The demo's search applied to the sample, as the board narrows its own.
    private var model: DoneArchiveModel {
        var model = sample.doneArchive
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        model.prefix = "native-"
        model.search = search
        model.rows = query.isEmpty ? model.rows : model.rows.filter { $0.title.lowercased().contains(query) }
        model.emptyMessage = model.rows.isEmpty ? "No matching tasks" : nil
        return model
    }

    private func title(_ id: String) -> String {
        sample.doneArchive.rows.first { $0.id == id }?.title ?? id
    }

    var body: some PHView {
        AtomStack(props: StackProps(axis: "v", spacing: 12, align: "leading")) {
            AtomStack(props: StackProps(axis: "h", spacing: 8)) {
                AtomText(props: TextProps(text: "Board header button", size: 11, color: "secondary"))
                DoneArchiveButton(testID: "native-done-archive-button") {
                    lastAction = open ? "toggle closed" : "toggle open"
                    open.toggle()
                }
                AtomText(props: TextProps(text: "Last: \(lastAction)", size: 11, color: "secondary"), common: AtomCommon(testID: "native-last-action"))
                AtomText(props: TextProps(text: reachedEnd ? "End reached" : "End not reached", size: 11, color: "secondary"), common: AtomCommon(testID: "native-end-reached"))
            }
            AtomStack(
                props: StackProps(axis: "v", spacing: 0, group: true, fill: "window", cornerRadius: 10),
                common: AtomCommon(testID: "native-done-archive-board", width: 560, height: 460)
            ) {
                AtomText(props: TextProps(text: "The board", size: 12, color: "tertiary"))
            }
            .atomSidePanel(
                SidePanelProps(isPresented: open, width: 340),
                common: AtomCommon(testID: "native-done-archive-panel")
            ) {
                DoneArchivePanel(model: model, actions: DoneArchiveActions(
                    close: { open = false; lastAction = "close" },
                    search: { search = $0; lastAction = "search \($0)" },
                    open: { open = false; lastAction = "open \(title($0))" },
                    createPullRequests: { lastAction = "create pr \(title($0))" },
                    loadMore: { reachedEnd = true }
                ))
            }
        }
    }
}
