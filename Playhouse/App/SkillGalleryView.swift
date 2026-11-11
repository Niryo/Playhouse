import SwiftUI

/// What the Skills page's header and skill gallery show, already derived from
/// a task's skill catalog and the page's state: plain values the native page
/// and the catalog's JavaScript copy (catalog/SkillsPage.js, as
/// `Playhouse.props.skillsPage`) compose the same way. `prefix` starts every
/// accessibility identifier ("" on the page, so its identifiers read
/// "skills-…" and "skill-…").
struct SkillsPageModel: Codable, Equatable {
    struct Option: Codable, Equatable {
        var value: String
        var label: String
    }

    /// A capsule beside a skill's name: a provider that can use it, Private,
    /// its namespaced name, Linked, Conflict, Shadowed or Invalid. `testID` is unprefixed.
    struct Badge: Codable, Equatable {
        var text: String
        var icon: String
        var color: String
        var testID: String
    }

    /// One action in a skill's menu; `testID` is unprefixed.
    struct MenuItem: Codable, Equatable {
        /// edit, reveal, move-global, move-repo:<root path>, move-private:<root path>, unlink, link or delete.
        var id: String
        var title: String
        var help: String
        var destructive: Bool?
        var testID: String
    }

    struct Row: Codable, Equatable {
        /// The skill's id, which every row action names.
        var id: String
        var name: String
        var badges: [Badge]
        var description: String?
        var issue: String?
        var location: String
        /// Not built in: it can be selected, fixed, moved and deleted.
        var editable: Bool
        /// A click opens its folder's SKILL.md (outside selecting).
        var opensOnClick: Bool
        /// A conflict or an invalid SKILL.md that an agent can repair.
        var fixable: Bool
        var enabled: Bool
        /// Some provider can use it, so Use can insert it.
        var usable: Bool
        /// The menu's groups, a separator between each.
        var menu: [[MenuItem]]
    }

    /// Text shown where a list has no skills; its identifier is "skills-empty-<key>".
    struct Empty: Codable, Equatable {
        var key: String
        var text: String
    }

    /// A repository's skills under its name, or (no title) a tab's own list.
    struct Section: Codable, Equatable {
        var title: String?
        var empty: Empty?
        var rows: [Row]
    }

    struct Tab: Codable, Equatable {
        /// repo, global or builtin.
        var value: String
        var label: String
        var intro: String
        /// Claude Code's built-ins are still being read.
        var loading: Bool
        var empty: Empty?
        var sections: [Section]
    }

    var prefix: String
    var title: String
    var kinds: [Option]
    /// skills, rules or mcp.
    var kind: String
    var tabs: [Tab]
    var tab: String
    var search: String
    /// The selected skills' ids while selecting, nil otherwise.
    var selection: [String]?
    /// "1 selected" or "N selected", counting the selected skills the catalog still has.
    var selectionCount: String
    /// A selected skill is broken and an agent can repair it.
    var canFixSelection: Bool
    var isFixing: Bool
    var error: String?
    var hint: String
    var selectingHint: String
    /// The catalog's first read has finished.
    var loaded: Bool
    /// An editor or New panel is open over the page, so Escape and the
    /// kind picker belong to it.
    var panelOpen: Bool
}

extension SkillsPageModel {
    static let kinds = [
        Option(value: "skills", label: "Skills"),
        Option(value: "rules", label: "Rules"),
        Option(value: "mcp", label: "MCP"),
    ]

    /// The page's model for a catalog (nil while its first read runs), with
    /// the search filter and switch overrides already applied.
    init(
        catalog: SkillCatalog?, kind: String, tab: String, search: String, selection: Set<String>?,
        enabledOverrides: [String: Bool], isLoadingBuiltins: Bool, isFixing: Bool, error: String?, panelOpen: Bool
    ) {
        prefix = ""
        title = "Skills, Rules & MCP"
        kinds = Self.kinds
        self.kind = kind
        self.tab = tab
        self.search = search
        let selected = (catalog?.allSkills ?? []).filter { selection?.contains($0.id) == true }
        self.selection = selection?.sorted()
        selectionCount = Self.selectionCount(selected.count)
        canFixSelection = selected.contains(where: Self.isFixable)
        self.isFixing = isFixing
        self.error = error
        hint = "Click a skill to open it, or press and hold one to select several. Turning a skill on or off reaches Claude on its next turn, and a Codex conversation the next time its thread starts."
        selectingHint = "Click skills to select them. Built-in skills can't be selected."
        loaded = catalog != nil
        self.panelOpen = panelOpen
        let repositories = catalog?.repositories ?? []
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func rows(_ skills: [SkillRecord]) -> [Row] {
            skills
                .filter { query.isEmpty || $0.name.lowercased().contains(query) || $0.description.lowercased().contains(query) }
                .map { Self.row($0, repositories: repositories, enabled: enabledOverrides[$0.id] ?? $0.enabled) }
        }
        let global = rows(catalog?.global ?? [])
        let builtin = rows(catalog?.builtin ?? [])
        tabs = [
            Tab(
                value: "repo", label: "Repo",
                intro: "Skills in the task's repositories. They live in .agents/skills or .claude/skills, and Playhouse shares each one with both Claude and Codex. A Private skill belongs to its repository but is stored by Playhouse, never in the repository, and reaches only this repository's Claude and Codex sessions.",
                loading: false,
                empty: repositories.isEmpty ? Empty(key: "repo", text: "This task has no repositories.") : nil,
                sections: repositories.map { section in
                    let shown = rows(section.skills)
                    return Section(
                        title: section.name,
                        empty: shown.isEmpty ? Empty(key: section.name, text: section.skills.isEmpty ? "No skills in \(section.name)." : "No matching skills.") : nil,
                        rows: shown
                    )
                }
            ),
            Tab(
                value: "global", label: "Global",
                intro: "Your skills for every repository, from ~/.agents/skills and Claude's and Codex's own skill folders.",
                loading: false,
                empty: global.isEmpty ? Empty(key: "global", text: "No global skills.") : nil,
                sections: [Section(rows: global)]
            ),
            Tab(
                value: "builtin", label: "Built-in",
                intro: "Skills and commands that come with each provider. Each one works only with the provider it ships with.",
                loading: isLoadingBuiltins,
                empty: builtin.isEmpty && !isLoadingBuiltins ? Empty(key: "builtin", text: "No built-in skills found.") : nil,
                sections: [Section(rows: builtin)]
            ),
        ]
    }

    static func selectionCount(_ count: Int) -> String {
        count == 1 ? "1 selected" : "\(count) selected"
    }

    static func isFixable(_ skill: SkillRecord) -> Bool {
        skill.editable && (skill.conflict || skill.issue != nil)
    }

    private static func row(_ skill: SkillRecord, repositories: [SkillRepositorySection], enabled: Bool) -> Row {
        let name = skill.name
        var badges = ConversationProvider.allCases.filter(skill.providers.contains).map { provider in
            Badge(text: provider.displayName, icon: "checkmark", color: "green", testID: "skill-provider-\(name)-\(provider.rawValue)")
        }
        let isPrivate = skill.scope == .privateRepo
        if isPrivate {
            badges.append(Badge(text: "Private", icon: "lock.fill", color: "purple", testID: "skill-private-\(name)"))
            if let namespaced = skill.invocationName {
                badges.append(Badge(text: "/" + namespaced, icon: "number", color: "purple", testID: "skill-namespaced-\(name)"))
            }
        }
        if skill.availableOutsidePlayhouse {
            badges.append(Badge(text: "Linked", icon: "link", color: "blue", testID: "skill-linked-\(name)"))
        }
        if skill.conflict {
            badges.append(Badge(text: "Conflict", icon: "exclamationmark.triangle", color: "orange", testID: "skill-conflict-\(name)"))
        } else if skill.shadowedBy != nil {
            badges.append(Badge(text: "Shadowed", icon: "eye.slash", color: "orange", testID: "skill-shadowed-\(name)"))
        } else if skill.issue != nil {
            badges.append(Badge(text: "Invalid", icon: "exclamationmark.triangle", color: "red", testID: "skill-invalid-\(name)"))
        }
        return Row(
            id: skill.id, name: name, badges: badges,
            description: skill.description.isEmpty ? nil : skill.description,
            issue: skill.issue,
            location: isPrivate
                ? "Private to \(skill.repositoryPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "its repository") · stored by Playhouse, not in the repository"
                : skill.locations.map(\.layout.displayPath).joined(separator: " · "),
            editable: skill.editable,
            opensOnClick: skill.folderPath != nil,
            fixable: isFixable(skill),
            enabled: enabled,
            usable: !skill.providers.isEmpty,
            menu: menu(skill, repositories: repositories)
        )
    }

    private static func menu(_ skill: SkillRecord, repositories: [SkillRepositorySection]) -> [[MenuItem]] {
        let name = skill.name
        var open: [MenuItem] = []
        if skill.editable {
            open.append(MenuItem(id: "edit", title: "Edit…", help: "Edit the skill's SKILL.md", testID: "skill-edit-\(name)"))
        }
        if skill.folderPath != nil {
            open.append(MenuItem(id: "reveal", title: "Reveal in Finder", help: "Show the skill folder in Finder", testID: "skill-reveal-\(name)"))
        }
        guard skill.editable else { return [open] }
        var moves: [MenuItem] = []
        if let section = repositories.first(where: { $0.rootPath == skill.rootPath }), skill.scope == .privateRepo {
            moves.append(MenuItem(
                id: "move-repo:\(section.rootPath)", title: "Convert to Repository Skill",
                help: "Move the skill into \(section.name)'s .agents/skills, so it can be committed and shared",
                testID: "skill-convert-repo-\(name)"
            ))
        }
        if skill.scope != .global {
            moves.append(MenuItem(id: "move-global", title: "Move to Global", help: "Make the skill available in every repository", testID: "skill-move-global-\(name)"))
        }
        for section in repositories where skill.scope == .global || skill.rootPath != section.rootPath {
            moves.append(MenuItem(
                id: "move-repo:\(section.rootPath)", title: "Move to \(section.name)", help: "Keep the skill only in \(section.name)",
                testID: "skill-move-repo-\(name)-\(section.name)"
            ))
        }
        for section in repositories where skill.scope != .privateRepo || skill.rootPath != section.rootPath {
            let own = skill.scope == .repo && skill.rootPath == section.rootPath
            moves.append(MenuItem(
                id: "move-private:\(section.rootPath)", title: own ? "Make Private" : "Make Private to \(section.name)",
                help: "Move the skill out of the repository into Playhouse's private store; only \(section.name)'s sessions see it",
                testID: own ? "skill-make-private-\(name)" : "skill-make-private-\(name)-\(section.name)"
            ))
        }
        guard skill.scope != .privateRepo else {
            let delete = [MenuItem(id: "delete", title: "Delete…", help: "Delete the private skill from Playhouse's store", destructive: true, testID: "skill-delete-\(name)")]
            return [open, moves, delete]
        }
        var link: [MenuItem] = []
        if skill.locations.contains(where: \.isSymlink) {
            link.append(MenuItem(
                id: "unlink", title: "Remove Outside Link", help: "Remove the symlink Playhouse wrote; Playhouse sessions still share the skill",
                testID: "skill-unlink-\(name)"
            ))
        } else if !skill.availableOutsidePlayhouse, !skill.conflict {
            link.append(MenuItem(
                id: "link", title: "Make Available Outside Playhouse…", help: "Write a symlink so the claude and codex CLIs find the skill on their own",
                testID: "skill-link-\(name)"
            ))
        }
        let delete = [MenuItem(id: "delete", title: "Delete…", help: "Delete the skill from disk", destructive: true, testID: "skill-delete-\(name)")]
        return [open, moves, link, delete]
    }
}

/// What the page's controls do. Row actions name the skill by its id; `menu`
/// also names the chosen item's id.
struct SkillsPageActions {
    var back: () -> Void = {}
    var selectKind: (String) -> Void = { _ in }
    var selectTab: (String) -> Void = { _ in }
    var search: (String) -> Void = { _ in }
    var newSkill: () -> Void = {}
    var fixSelected: () -> Void = {}
    var deleteSelected: () -> Void = {}
    var endSelection: () -> Void = {}
    var press: (String) -> Void = { _ in }
    var longPress: (String) -> Void = { _ in }
    var fix: (String) -> Void = { _ in }
    var toggle: (String) -> Void = { _ in }
    var use: (String) -> Void = { _ in }
    var menu: (String, String) -> Void = { _, _ in }
}

/// The composer's Skills button, which opens the Skills page.
struct SkillsButton: View {
    let testID: String
    let action: () -> Void

    var body: some View {
        AtomButton(common: AtomCommon(testID: testID, label: "Skills", help: "Skills"), action: action) {
            AtomIcon(props: IconProps(name: "sparkles"))
        }
    }
}

/// The Skills page's header, composed only of plugin atoms: the back button,
/// the title and the Skills | Rules | MCP picker. The source picker, search
/// and New Skill (or the selection's actions) sit on their own row in the gallery.
struct SkillsPageHeader: View {
    let model: SkillsPageModel
    var actions = SkillsPageActions()

    private var prefix: String { model.prefix }
    private var selection: [String]? { model.selection }

    var body: some View {
        AtomStack(props: StackProps(axis: "h", spacing: 12), common: AtomCommon(padding: 12, paddingX: 8)) {
            AtomButton(
                props: ButtonProps(shortcut: model.panelOpen || selection != nil ? nil : "cancel"),
                common: AtomCommon(testID: "\(prefix)skills-back-button", label: "Back to the conversation", help: "Back to the conversation"),
                action: actions.back
            ) {
                AtomPanel(props: PanelProps(fillOpacity: 0.07, cornerRadius: 13), common: AtomCommon(width: 26, height: 26)) {
                    AtomIcon(props: IconProps(name: "chevron.left", size: 13, weight: "semibold"))
                }
            }
            AtomText(props: TextProps(text: model.title, size: 17, weight: "semibold"), common: AtomCommon(testID: "\(prefix)skills-title"))
            AtomSegmented(
                props: SegmentedProps(options: model.kinds.map { .init(value: $0.value, label: $0.label) }, selected: model.kind, disabled: selection != nil || model.panelOpen),
                common: AtomCommon(testID: "\(prefix)skills-kind-picker", label: "Show", help: "Show skills, the rule files agents follow on every turn, or the MCP servers that give them tools"),
                onChange: actions.selectKind
            )
        }
    }
}

/// The Skills list under the header, composed only of plugin atoms: the
/// error, the hint, then the selected source's skills in a lazy scroll view,
/// one row each with its badges, switch, Use button and actions menu.
struct SkillGalleryView: View {
    let model: SkillsPageModel
    var actions = SkillsPageActions()

    private var prefix: String { model.prefix }
    private var isSelecting: Bool { model.selection != nil }

    var body: some View {
        AtomStack(props: StackProps(axis: "v", spacing: 0, align: "leading")) {
            if model.kind == "skills" {
                AtomStack(props: StackProps(axis: "h", spacing: 12), common: AtomCommon(padding: 10, paddingX: 20)) {
                    AtomSegmented(
                        props: SegmentedProps(options: model.tabs.map { .init(value: $0.value, label: $0.label) }, selected: model.tab),
                        common: AtomCommon(testID: "\(prefix)skills-tab-picker", label: "Skill source", width: 260),
                        onChange: actions.selectTab
                    )
                    AtomSpacer()
                    if model.selection != nil {
                        selectionActions
                    } else {
                        AtomTextField(props: TextFieldProps(text: model.search, placeholder: "Search skills"), common: AtomCommon(testID: "\(prefix)skills-search", width: 200), onChange: actions.search)
                        AtomButton(
                            props: ButtonProps(style: "bordered"),
                            common: AtomCommon(testID: "\(prefix)new-skill-button", help: "Create a skill that both Claude and Codex can use"),
                            action: actions.newSkill
                        ) {
                            AtomLabel(props: LabelProps(text: "New Skill", icon: "plus"))
                        }
                    }
                }
            }
            if let error = model.error {
                AtomText(props: TextProps(text: error, size: 12, color: "red"), common: AtomCommon(testID: "\(prefix)skills-error", fillWidth: true, padding: 8, paddingX: 12))
            }
            AtomText(
                props: TextProps(text: isSelecting ? model.selectingHint : model.hint, size: 10, color: "secondary"),
                common: AtomCommon(testID: "\(prefix)skills-provider-timing", padding: 8, paddingX: 12)
            )
            AtomScroll(props: ScrollProps(spacing: 10, inset: 20, lazy: true), common: AtomCommon(testID: "\(prefix)skills-list")) {
                content
            }
        }
    }

    private var selectionActions: some View {
        AtomStack(props: StackProps(axis: "h", spacing: 8)) {
            AtomText(
                props: TextProps(text: model.selectionCount, color: "secondary", monospacedDigits: true),
                common: AtomCommon(testID: "\(prefix)skills-selection-count")
            )
            AtomButton(
                props: ButtonProps(style: "bordered", disabled: !model.canFixSelection || model.isFixing),
                common: AtomCommon(testID: "\(prefix)skills-fix-selected", help: "Open a task whose agent fixes the selected conflicting or invalid skills"),
                action: actions.fixSelected
            ) {
                AtomLabel(props: LabelProps(text: "Fix with Agent", icon: "wand.and.stars"))
            }
            AtomButton(
                props: ButtonProps(style: "bordered", disabled: model.selection?.isEmpty != false, destructive: true),
                common: AtomCommon(testID: "\(prefix)skills-delete-selected", help: "Delete the selected skills from disk"),
                action: actions.deleteSelected
            ) {
                AtomLabel(props: LabelProps(text: "Delete", icon: "trash"))
            }
            AtomButton(
                props: ButtonProps(style: "bordered", shortcut: model.panelOpen ? nil : "cancel"),
                common: AtomCommon(testID: "\(prefix)skills-selection-done", help: "Stop selecting skills"),
                action: actions.endSelection
            ) {
                AtomText(props: TextProps(text: "Done"))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.loaded {
            AtomStack(props: StackProps(axis: "h")) {
                AtomSpacer()
                AtomSpinner(props: SpinnerProps(size: "regular"), common: AtomCommon(testID: "\(prefix)skills-loading"))
                AtomSpacer()
            }
        } else if let tab = model.tabs.first(where: { $0.value == model.tab }) {
            AtomText(props: TextProps(text: tab.intro, size: 12, color: "secondary"))
            if tab.loading {
                AtomSpinner(common: AtomCommon(testID: "\(prefix)skills-builtin-loading"))
            }
            if let empty = tab.empty { emptyState(empty) }
            ForEach(Array(tab.sections.enumerated()), id: \.offset) { _, section in
                if let title = section.title {
                    AtomStack(props: StackProps(axis: "v", spacing: 8, align: "leading")) {
                        AtomText(props: TextProps(text: title, size: 13, weight: "bold"), common: AtomCommon(testID: "\(prefix)skills-repo-section-\(title)"))
                        sectionRows(section)
                    }
                } else {
                    sectionRows(section)
                }
            }
        }
    }

    @ViewBuilder
    private func sectionRows(_ section: SkillsPageModel.Section) -> some View {
        if let empty = section.empty { emptyState(empty) }
        ForEach(section.rows, id: \.id) { row($0) }
    }

    private func emptyState(_ empty: SkillsPageModel.Empty) -> some View {
        AtomText(props: TextProps(text: empty.text, color: "secondary"), common: AtomCommon(testID: "\(prefix)skills-empty-\(empty.key)"))
    }

    private func row(_ row: SkillsPageModel.Row) -> some View {
        let name = row.name
        let isSelected = model.selection?.contains(row.id) == true
        return AtomPanel(
            props: PanelProps(
                fill: isSelected ? "accent" : "panel", fillOpacity: isSelected ? 0.12 : 1, cornerRadius: 10,
                stroke: isSelected ? "accent" : nil, strokeOpacity: 0.6
            ),
            common: AtomCommon(testID: "\(prefix)skill-row-\(name)", fillWidth: true, padding: 10, paddingX: 4)
        ) {
            AtomStack(props: StackProps(axis: "h", spacing: 12)) {
                // A press and hold starts selecting; a click opens the skill, or selects while
                // selecting. Only the skill's own text takes them: a held click on a control, such
                // as the actions menu while it tracks, must not start selecting.
                AtomPressArea(
                    props: PressAreaProps(pointer: isSelecting ? row.editable : row.opensOnClick),
                    common: AtomCommon(testID: "\(prefix)skill-text-\(name)"),
                    onPress: { actions.press(row.id) },
                    onLongPress: { actions.longPress(row.id) }
                ) {
                    AtomStack(props: StackProps(axis: "h", spacing: 12)) {
                        if isSelecting, row.editable {
                            AtomIcon(
                                props: IconProps(name: isSelected ? "checkmark.circle.fill" : "circle", size: 16, color: isSelected ? "accent" : "secondary"),
                                common: AtomCommon(testID: "\(prefix)skill-select-\(name)", label: isSelected ? "Selected" : "Not selected")
                            )
                        }
                        AtomStack(props: StackProps(axis: "v", spacing: 4, align: "leading")) {
                            AtomStack(props: StackProps(axis: "h", spacing: 6)) {
                                AtomText(props: TextProps(text: name, size: 13, weight: "semibold"), common: AtomCommon(testID: "\(prefix)skill-name-\(name)"))
                                ForEach(row.badges, id: \.testID) { badge($0) }
                            }
                            if let description = row.description {
                                AtomText(props: TextProps(text: description, size: 12, color: "secondary", lineLimit: 3), common: AtomCommon(testID: "\(prefix)skill-description-\(name)"))
                            }
                            if let issue = row.issue {
                                AtomText(props: TextProps(text: issue, size: 10, color: "orange"), common: AtomCommon(testID: "\(prefix)skill-issue-\(name)"))
                            }
                            AtomText(props: TextProps(text: row.location, size: 10, color: "tertiary"), common: AtomCommon(testID: "\(prefix)skill-location-\(name)"))
                        }
                        AtomSpacer(props: SpacerProps(minLength: 8))
                    }
                }
                if !isSelecting {
                    controls(row)
                }
            }
        }
    }

    @ViewBuilder
    private func controls(_ row: SkillsPageModel.Row) -> some View {
        let name = row.name
        if row.fixable {
            AtomButton(
                props: ButtonProps(style: "bordered", disabled: model.isFixing, controlSize: "small"),
                common: AtomCommon(testID: "\(prefix)skill-fix-\(name)", help: "Open a task whose agent fixes \(name)"),
                action: { actions.fix(row.id) }
            ) {
                AtomLabel(props: LabelProps(text: "Fix with Agent", icon: "wand.and.stars"))
            }
        }
        AtomToggle(
            props: ToggleProps(isOn: row.enabled, size: "mini"),
            common: AtomCommon(
                testID: "\(prefix)skill-toggle-\(name)", label: "\(name) enabled",
                help: row.enabled ? "Turn the skill off in Playhouse sessions" : "Turn the skill on in Playhouse sessions"
            ),
            onToggle: { actions.toggle(row.id) }
        )
        AtomButton(
            props: ButtonProps(style: "bordered", disabled: !row.enabled || !row.usable, controlSize: "small"),
            common: AtomCommon(testID: "\(prefix)skill-use-\(name)", help: "Insert /\(name) into the message"),
            action: { actions.use(row.id) }
        ) {
            AtomText(props: TextProps(text: "Use"))
        }
        AtomMenu(
            props: MenuProps(icon: "ellipsis", size: 13, weight: "semibold", items: row.menu.map { group in
                group.map { .init(id: $0.id, title: $0.title, destructive: $0.destructive, help: $0.help, testID: "\(prefix)\($0.testID)") }
            }),
            common: AtomCommon(testID: "\(prefix)skill-actions-\(name)", label: "Actions for \(name)", help: "More actions for \(name)", width: 24, height: 24),
            onMenu: { actions.menu(row.id, $0) }
        )
    }

    private func badge(_ badge: SkillsPageModel.Badge) -> some View {
        AtomPanel(props: PanelProps(fill: badge.color, fillOpacity: 0.12, cornerRadius: 8), common: AtomCommon(testID: "\(prefix)\(badge.testID)", padding: 2, paddingX: 4)) {
            AtomLabel(props: LabelProps(text: badge.text, icon: badge.icon, size: 10, weight: "medium", color: badge.color))
        }
    }
}
