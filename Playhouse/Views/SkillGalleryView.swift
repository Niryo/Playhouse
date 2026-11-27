import Foundation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI

/// What the Skills page's header and skill gallery show, already derived from
/// a task's skill catalog and the page's state: plain values the native page
/// and the catalog's JavaScript copy (catalog/SkillsPage.js, as
/// `Playhouse.props.skillsPage`) compose the same way. `prefix` starts every
/// accessibility identifier ("" on the page, so its identifiers read
/// "skills-…" and "skill-…").
package struct SkillsPageModel: Codable, Equatable {
    package struct Option: Codable, Equatable {
        package var value: String
        package var label: String

        package init(value: String, label: String) {
            self.value = value
            self.label = label
        }
    }

    /// A capsule in a skill's hint (Private or Linked, a private skill's
    /// namespaced command, or the row's flag: Conflict, Shadowed or Invalid,
    /// which shows as its icon beside the name). `testID` is unprefixed.
    package struct Badge: Codable, Equatable {
        package var text: String
        package var icon: String
        package var color: String
        package var testID: String

        package init(text: String, icon: String, color: String, testID: String) {
            self.text = text
            self.icon = icon
            self.color = color
            self.testID = testID
        }
    }

    /// The small icon beside a skill's name that says who can use it: Claude's
    /// or Codex's logo (`asset`) for a skill only one of them can use, or a
    /// green check (`icon`) for one both can. `testID` is unprefixed and ends
    /// in claude, codex or both.
    package struct ProviderMark: Codable, Equatable {
        package var label: String
        package var icon: String?
        package var asset: String?
        package var color: String
        package var testID: String

        package init(label: String, icon: String? = nil, asset: String? = nil, color: String, testID: String) {
            self.label = label
            self.icon = icon
            self.asset = asset
            self.color = color
            self.testID = testID
        }
    }

    /// One action in a skill's menu; `testID` is unprefixed.
    package struct MenuItem: Codable, Equatable {
        /// use, toggle, edit, reveal, move-global, move-repo:<root path>, move-private:<root path>, unlink, link or delete.
        package var id: String
        package var title: String
        package var help: String
        package var destructive: Bool?
        package var disabled: Bool?
        package var testID: String

        package init(id: String, title: String, help: String, destructive: Bool? = nil, disabled: Bool? = nil, testID: String) {
            self.id = id
            self.title = title
            self.help = help
            self.destructive = destructive
            self.disabled = disabled
            self.testID = testID
        }
    }

    package struct Row: Codable, Equatable {
        /// The skill's id, which every row action names.
        package var id: String
        package var name: String
        /// Who can use it, beside the name on the row; nil when no provider can.
        package var provider: ProviderMark?
        /// What the hint lists under the description.
        package var badges: [Badge]
        /// Conflict, Shadowed or Invalid, marked beside the name.
        package var flag: Badge?
        /// A namespaced private skill's `/<repository>:<name>`, on its own line in the hint.
        package var command: Badge?
        package var description: String?
        package var issue: String?
        package var location: String
        /// Not built in: it can be selected, fixed, moved and deleted.
        package var editable: Bool
        /// A click opens its folder's SKILL.md (outside selecting).
        package var opensOnClick: Bool
        /// A conflict or an invalid SKILL.md that an agent can repair.
        package var fixable: Bool
        /// Off, it shows dimmed; its controls still respond.
        package var enabled: Bool
        /// Some provider can use it, so Use can insert it.
        package var usable: Bool
        /// The menu's groups after its Use and Enable/Disable group
        /// (`SkillsPageModel.leadingMenu`), a separator between each.
        package var menu: [[MenuItem]]

        package init(id: String, name: String, provider: ProviderMark? = nil, badges: [Badge], flag: Badge? = nil, command: Badge? = nil, description: String? = nil, issue: String? = nil, location: String, editable: Bool, opensOnClick: Bool, fixable: Bool, enabled: Bool, usable: Bool, menu: [[MenuItem]]) {
            self.id = id
            self.name = name
            self.provider = provider
            self.badges = badges
            self.flag = flag
            self.command = command
            self.description = description
            self.issue = issue
            self.location = location
            self.editable = editable
            self.opensOnClick = opensOnClick
            self.fixable = fixable
            self.enabled = enabled
            self.usable = usable
            self.menu = menu
        }
    }

    /// Text shown where a list has no skills; its identifier is "skills-empty-<key>".
    package struct Empty: Codable, Equatable {
        package var key: String
        package var text: String

        package init(key: String, text: String) {
            self.key = key
            self.text = text
        }
    }

    /// A repository's skills under its name, or (no title) a group's own list.
    package struct Section: Codable, Equatable {
        package var title: String?
        package var empty: Empty?
        package var rows: [Row]

        package init(title: String? = nil, empty: Empty? = nil, rows: [Row]) {
            self.title = title
            self.empty = empty
            self.rows = rows
        }
    }

    /// One of the list's sections, which the anchor bar scrolls to.
    package struct Group: Codable, Equatable {
        /// repo, global or builtin.
        package var value: String
        package var label: String
        /// How many skills it shows.
        package var count: Int
        package var intro: String
        /// Claude Code's built-ins are still being read.
        package var loading: Bool
        /// Only its header shows (Built-in starts so); a search shows every group's matches.
        package var collapsed: Bool
        package var empty: Empty?
        package var sections: [Section]

        package init(value: String, label: String, count: Int, intro: String, loading: Bool, collapsed: Bool, empty: Empty? = nil, sections: [Section]) {
            self.value = value
            self.label = label
            self.count = count
            self.intro = intro
            self.loading = loading
            self.collapsed = collapsed
            self.empty = empty
            self.sections = sections
        }
    }

    package var prefix: String
    /// The page's name, the header icon's label; the tabs take the title's place.
    package var title: String
    package var kinds: [Option]
    /// skills, rules or mcp.
    package var kind: String
    package var groups: [Group]
    /// The group the list scrolls to on each new `scrollRequest`.
    package var scrollTo: String?
    package var scrollRequest: Int
    package var search: String
    /// The selected skills' ids while selecting, nil otherwise.
    package var selection: [String]?
    /// "1 selected" or "N selected", counting the selected skills the catalog still has.
    package var selectionCount: String
    /// A selected skill is broken and an agent can repair it.
    package var canFixSelection: Bool
    package var isFixing: Bool
    package var error: String?
    package var hint: String
    package var selectingHint: String
    /// The catalog's first read has finished.
    package var loaded: Bool
    /// An editor or New panel is open over the page, so Escape and the
    /// kind picker belong to it.
    package var panelOpen: Bool

    package init(prefix: String, title: String, kinds: [Option], kind: String, groups: [Group], scrollTo: String? = nil, scrollRequest: Int, search: String, selection: [String]? = nil, selectionCount: String, canFixSelection: Bool, isFixing: Bool, error: String? = nil, hint: String, selectingHint: String, loaded: Bool, panelOpen: Bool) {
        self.prefix = prefix
        self.title = title
        self.kinds = kinds
        self.kind = kind
        self.groups = groups
        self.scrollTo = scrollTo
        self.scrollRequest = scrollRequest
        self.search = search
        self.selection = selection
        self.selectionCount = selectionCount
        self.canFixSelection = canFixSelection
        self.isFixing = isFixing
        self.error = error
        self.hint = hint
        self.selectingHint = selectingHint
        self.loaded = loaded
        self.panelOpen = panelOpen
    }
}

extension SkillsPageModel {
    package static let kinds = [
        Option(value: "skills", label: "Skills"),
        Option(value: "rules", label: "Rules"),
        Option(value: "mcp", label: "MCP"),
    ]

    /// The page's model for a catalog (nil while its first read runs), with
    /// the search filter, enable overrides and collapsed groups already applied.
    package init(
        catalog: SkillCatalog?, kind: String, scrollTo: String?, scrollRequest: Int, search: String, selection: Set<String>?,
        enabledOverrides: [String: Bool], collapsedGroups: Set<String>, isLoadingBuiltins: Bool, isFixing: Bool, error: String?, panelOpen: Bool
    ) {
        prefix = ""
        title = "Skills, Rules & MCP"
        kinds = Self.kinds
        self.kind = kind
        self.scrollTo = scrollTo
        self.scrollRequest = scrollRequest
        self.search = search
        let selected = (catalog?.allSkills ?? []).filter { selection?.contains($0.id) == true }
        self.selection = selection?.sorted()
        selectionCount = Self.selectionCount(selected.count)
        canFixSelection = selected.contains(where: Self.isFixable)
        self.isFixing = isFixing
        self.error = error
        hint = "Hover a skill for its details, click it to open it, or press and hold one to select several. Use a skill or turn it on or off from its menu; the change reaches Claude on its next turn, and a Codex conversation the next time its thread starts."
        selectingHint = "Click skills to select them. Built-in skills can't be selected."
        loaded = catalog != nil
        self.panelOpen = panelOpen
        let repositories = catalog?.repositories ?? []
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func isCollapsed(_ group: String) -> Bool { query.isEmpty && collapsedGroups.contains(group) }
        func rows(_ skills: [SkillRecord]) -> [Row] {
            skills
                .filter { query.isEmpty || $0.name.lowercased().contains(query) || $0.description.lowercased().contains(query) }
                .map { Self.row($0, repositories: repositories, enabled: enabledOverrides[$0.id] ?? $0.enabled) }
        }
        let global = rows(catalog?.global ?? [])
        let builtin = rows(catalog?.builtin ?? [])
        let sections = repositories.map { section in
            let shown = rows(section.skills)
            return Section(
                title: section.name,
                empty: shown.isEmpty ? Empty(key: section.name, text: section.skills.isEmpty ? "No skills in \(section.name)." : "No matching skills.") : nil,
                rows: shown
            )
        }
        groups = [
            Group(
                value: "repo", label: "Repo", count: sections.reduce(0) { $0 + $1.rows.count },
                intro: "Skills in the task's repositories. They live in .agents/skills or .claude/skills, and Playhouse shares each one with both Claude and Codex. A Private skill belongs to its repository but is stored by Playhouse, never in the repository, and reaches only this repository's Claude and Codex sessions.",
                loading: false, collapsed: isCollapsed("repo"),
                empty: repositories.isEmpty ? Empty(key: "repo", text: "This task has no repositories.") : nil,
                sections: sections
            ),
            Group(
                value: "global", label: "Global", count: global.count,
                intro: "Your skills for every repository, from ~/.agents/skills and Claude's and Codex's own skill folders.",
                loading: false, collapsed: isCollapsed("global"),
                empty: global.isEmpty ? Empty(key: "global", text: "No global skills.") : nil,
                sections: [Section(rows: global)]
            ),
            Group(
                value: "builtin", label: "Built-in", count: builtin.count,
                intro: "Skills and commands that come with each provider. Each one works only with the provider it ships with.",
                loading: isLoadingBuiltins, collapsed: isCollapsed("builtin"),
                empty: builtin.isEmpty && !isLoadingBuiltins ? Empty(key: "builtin", text: "No built-in skills found.") : nil,
                sections: [Section(rows: builtin)]
            ),
        ]
    }

    package static func selectionCount(_ count: Int) -> String {
        count == 1 ? "1 selected" : "\(count) selected"
    }

    package static func isFixable(_ skill: SkillRecord) -> Bool {
        skill.editable && (skill.conflict || skill.issue != nil)
    }

    /// The asset of a provider's logo, shared by the row marks and the MCP sign-in badge.
    package static func logoAsset(_ provider: ConversationProvider) -> String {
        switch provider {
        case .claude: "ClaudeLogo"
        case .codex: "CodexLogo"
        case .opencode: "OpenCodeLogo"
        }
    }

    package static func logoColor(_ provider: ConversationProvider) -> String {
        switch provider {
        case .claude: "#D97757"
        case .codex, .opencode: "primary"
        }
    }

    /// Who can use a skill, rule or MCP server: one provider's logo, a green check for every
    /// provider, or an outlined check for some. `testID` is `<base>-<provider>` for one,
    /// `<base>-both` for every provider, else `<base>-` and the providers joined by `-`.
    package static func providerMark(_ providers: Set<ConversationProvider>, testID base: String) -> ProviderMark? {
        let ordered = [ConversationProvider.claude, .codex, .opencode].filter(providers.contains)
        guard let first = ordered.first else { return nil }
        guard ordered.count > 1 else {
            return ProviderMark(label: "\(first.displayName) only", asset: logoAsset(first), color: logoColor(first), testID: "\(base)-\(first.rawValue)")
        }
        let label = ConversationProvider.names(ordered)
        return ordered.count == ConversationProvider.allCases.count
            ? ProviderMark(label: label, icon: PHIcon.checkmarkCircleFill.name, color: "green", testID: "\(base)-both")
            : ProviderMark(label: label, icon: PHIcon.checkmarkCircle.name, color: "green", testID: "\(base)-" + ordered.map(\.rawValue).joined(separator: "-"))
    }

    /// The menu's first group, composed from the row's current state so a
    /// changed `enabled` updates it: Use, then Enable or Disable.
    package static func leadingMenu(_ row: Row) -> [MenuItem] {
        [
            MenuItem(
                id: "use", title: "Use", help: "Insert /\(row.name) into the message",
                disabled: !row.enabled || !row.usable, testID: "skill-use-\(row.name)"
            ),
            MenuItem(
                id: "toggle", title: row.enabled ? "Disable" : "Enable",
                help: row.enabled ? "Turn the skill off in Playhouse sessions" : "Turn the skill on in Playhouse sessions",
                testID: "skill-toggle-\(row.name)"
            ),
        ]
    }

    private static func row(_ skill: SkillRecord, repositories: [SkillRepositorySection], enabled: Bool) -> Row {
        let name = skill.name
        var badges: [Badge] = []
        let isPrivate = skill.scope == .privateRepo
        var command: Badge?
        if isPrivate {
            badges.append(Badge(text: "Private", icon: PHIcon.lockFill.name, color: "purple", testID: "skill-private-\(name)"))
            command = skill.invocationName.map { Badge(text: "/" + $0, icon: PHIcon.number.name, color: "purple", testID: "skill-namespaced-\(name)") }
        }
        if skill.availableOutsidePlayhouse {
            badges.append(Badge(text: "Linked", icon: PHIcon.link.name, color: "blue", testID: "skill-linked-\(name)"))
        }
        let flag: Badge? = if skill.conflict {
            Badge(text: "Conflict", icon: PHIcon.exclamationmarkTriangleFill.name, color: "orange", testID: "skill-conflict-\(name)")
        } else if skill.shadowedBy != nil {
            Badge(text: "Shadowed", icon: PHIcon.eyeSlash.name, color: "orange", testID: "skill-shadowed-\(name)")
        } else if skill.issue != nil {
            Badge(text: "Invalid", icon: PHIcon.exclamationmarkTriangleFill.name, color: "red", testID: "skill-invalid-\(name)")
        } else {
            nil
        }
        return Row(
            id: skill.id, name: name, provider: providerMark(Set(skill.providers), testID: "skill-provider-\(name)"), badges: badges, flag: flag, command: command,
            description: skill.description.isEmpty ? nil : skill.description,
            issue: skill.issue,
            location: (isPrivate
                ? "Private to \(skill.repositoryPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "its repository") · stored by Playhouse, not in the repository"
                : skill.locations.map(\.layout.displayPath).joined(separator: " · ")) + (skill.providerNote.map { " · " + $0 } ?? ""),
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

/// A provider mark as the small icon that leads a Skills, Rules or MCP row's name.
package struct ProviderMarkIcon: PHView {
    package let mark: SkillsPageModel.ProviderMark
    package var prefix = ""

    package var body: some PHView {
        AtomIcon(
            props: IconProps(name: mark.icon, asset: mark.asset, size: 11, color: mark.color),
            common: AtomCommon(testID: "\(prefix)\(mark.testID)", label: mark.label, help: mark.label, width: 12, height: 12)
        )
    }

    package init(mark: SkillsPageModel.ProviderMark, prefix: String = "") {
        self.mark = mark
        self.prefix = prefix
    }
}

/// What the page's controls do. Row actions name the skill by its id; `menu`
/// also names the chosen item's id.
package struct SkillsPageActions {
    package var back: () -> Void = {}
    package var selectKind: (String) -> Void = { _ in }
    /// Scrolls the list to a group (repo, global or builtin).
    package var jump: (String) -> Void = { _ in }
    package var search: (String) -> Void = { _ in }
    package var newSkill: () -> Void = {}
    package var fixSelected: () -> Void = {}
    package var deleteSelected: () -> Void = {}
    package var endSelection: () -> Void = {}
    package var press: (String) -> Void = { _ in }
    package var longPress: (String) -> Void = { _ in }
    package var fix: (String) -> Void = { _ in }
    /// Collapses or expands a group (repo, global or builtin).
    package var toggleGroup: (String) -> Void = { _ in }
    /// Includes the menu's Use and Enable/Disable (`use`, `toggle`).
    package var menu: (String, String) -> Void = { _, _ in }

    package init(back: @escaping () -> Void = {}, selectKind: @escaping (String) -> Void = { _ in }, jump: @escaping (String) -> Void = { _ in }, search: @escaping (String) -> Void = { _ in }, newSkill: @escaping () -> Void = {}, fixSelected: @escaping () -> Void = {}, deleteSelected: @escaping () -> Void = {}, endSelection: @escaping () -> Void = {}, press: @escaping (String) -> Void = { _ in }, longPress: @escaping (String) -> Void = { _ in }, fix: @escaping (String) -> Void = { _ in }, toggleGroup: @escaping (String) -> Void = { _ in }, menu: @escaping (String, String) -> Void = { _, _ in }) {
        self.back = back
        self.selectKind = selectKind
        self.jump = jump
        self.search = search
        self.newSkill = newSkill
        self.fixSelected = fixSelected
        self.deleteSelected = deleteSelected
        self.endSelection = endSelection
        self.press = press
        self.longPress = longPress
        self.fix = fix
        self.toggleGroup = toggleGroup
        self.menu = menu
    }
}

/// The Skills button, which opens the Skills page: in a standalone chat's
/// composer, and in the catalog's demo. A task opens it from its sidebar.
package struct SkillsButton: PHView {
    package let testID: String
    package var shortcut: String? = nil
    package let action: () -> Void

    package var body: some PHView {
        AtomButton(props: ButtonProps(shortcut: shortcut), common: AtomCommon(testID: testID, label: "Skills", help: "Skills"), action: action) {
            AtomIcon(props: IconProps(name: PHIcon.sparkles.name))
        }
    }

    package init(testID: String, shortcut: String? = nil, action: @escaping () -> Void) {
        self.testID = testID
        self.shortcut = shortcut
        self.action = action
    }
}

/// The Skills page's header, composed only of plugin atoms: the page's icon
/// (named by its title), the Skills | Rules | MCP tabs in the title's place,
/// and the close button. Each list's search, New button and anchors sit on
/// their own rows under it.
package struct SkillsPageHeader: PHView {
    package let model: SkillsPageModel
    package var actions = SkillsPageActions()

    private var prefix: String { model.prefix }

    package var body: some PHView {
        AtomStack(props: StackProps(axis: "h", spacing: 10), common: AtomCommon(paddingX: 20, paddingY: 12)) {
            AtomStack(
                props: StackProps(fill: "accent", fillOpacity: 0.14, cornerRadius: 7, summary: true),
                common: AtomCommon(testID: "\(prefix)skills-title", label: model.title, help: model.title, width: 26, height: 26)
            ) {
                AtomIcon(props: IconProps(name: PHIcon.sparkles.name, size: 13, weight: "semibold", color: "accent"))
            }
            AtomSegmented(
                props: SegmentedProps(options: model.kinds.map { .init(value: $0.value, label: $0.label) }, selected: model.kind, disabled: model.selection != nil || model.panelOpen),
                common: AtomCommon(testID: "\(prefix)skills-kind-picker", label: "Show", help: "Show skills, the rule files agents follow on every turn, or the MCP servers that give them tools"),
                onChange: actions.selectKind
            )
            AtomSpacer()
            AtomButton(
                props: ButtonProps(shortcut: model.panelOpen || model.selection != nil ? nil : "cancel"),
                common: AtomCommon(testID: "\(prefix)skills-back-button", label: "Close", help: "Close"),
                action: actions.back
            ) {
                AtomStack(props: StackProps(fill: "primary", fillOpacity: 0.07, capsule: true), common: AtomCommon(width: 22, height: 22)) {
                    AtomIcon(props: IconProps(name: PHIcon.xmark.name, size: 9, weight: "bold", color: "secondary"))
                }
            }
        }
    }

    package init(model: SkillsPageModel, actions: SkillsPageActions = SkillsPageActions()) {
        self.model = model
        self.actions = actions
    }
}

/// One anchor in a list's anchor bar: the section it scrolls to and how many items it holds.
package struct SkillsPageAnchor: Equatable {
    package var value: String
    package var label: String
    package var count: Int

    package init(value: String, label: String, count: Int) {
        self.value = value
        self.label = label
        self.count = count
    }
}

/// A list's anchors, composed only of plugin atoms: a capsule per section
/// that scrolls the list to it. `testID` names the bar, and each anchor is
/// "<anchorPrefix>-<value>", labelled with its section's name.
package struct SkillsPageAnchorBar: PHView {
    package let testID: String
    package let anchorPrefix: String
    package let anchors: [SkillsPageAnchor]
    package let onJump: (String) -> Void

    package var body: some PHView {
        AtomStack(props: StackProps(axis: "h", spacing: 6, group: true), common: AtomCommon(testID: testID, label: "Jump to")) {
            PHForEach(anchors, id: \.value) { anchor in
                AtomButton(
                    common: AtomCommon(testID: "\(anchorPrefix)-\(anchor.value)", label: anchor.label, help: "Scroll to \(anchor.label)"),
                    action: { onJump(anchor.value) }
                ) {
                    AtomStack(props: StackProps(axis: "h", spacing: 5, fill: "primary", fillOpacity: 0.06, capsule: true), common: AtomCommon(paddingX: 10, paddingY: 4)) {
                        AtomText(props: TextProps(text: anchor.label, size: 11, weight: "medium"))
                        AtomText(props: TextProps(text: String(anchor.count), size: 11, color: "secondary", monospacedDigits: true))
                    }
                }
            }
        }
    }

    package init(testID: String, anchorPrefix: String, anchors: [SkillsPageAnchor], onJump: @escaping (String) -> Void) {
        self.testID = testID
        self.anchorPrefix = anchorPrefix
        self.anchors = anchors
        self.onJump = onJump
    }
}

/// A list's search field, composed only of plugin atoms: a magnifying glass
/// and a plain text field in a soft rounded box as wide as its row.
package struct SkillsPageSearchField: PHView {
    package let text: String
    package let placeholder: String
    package let testID: String
    package let onChange: (String) -> Void

    package var body: some PHView {
        AtomStack(props: StackProps(axis: "h", spacing: 6, fill: "primary", fillOpacity: 0.05, cornerRadius: 7), common: AtomCommon(fillWidth: true, paddingX: 8, paddingY: 5)) {
            AtomIcon(props: IconProps(name: PHIcon.magnifyingglass.name, size: 11, color: "secondary"))
            AtomTextField(props: TextFieldProps(text: text, placeholder: placeholder, style: "plain"), common: AtomCommon(testID: testID, fillWidth: true), onChange: onChange)
        }
    }

    package init(text: String, placeholder: String, testID: String, onChange: @escaping (String) -> Void) {
        self.text = text
        self.placeholder = placeholder
        self.testID = testID
        self.onChange = onChange
    }
}

/// A section's heading in a list, composed only of plugin atoms: its name in
/// small capitals and its count (with `onToggle`, one button with a chevron
/// that collapses and expands the section), a spinner while it loads, and an
/// info icon whose help explains the section.
package struct SkillsPageGroupHeader: PHView {
    package let label: String
    package let count: Int
    package let intro: String
    package var loading = false
    package var loadingTestID: String?
    package let introTestID: String
    package var collapsed = false
    package var toggleTestID: String?
    package var onToggle: (() -> Void)?

    package var body: some PHView {
        AtomStack(props: StackProps(axis: "h", spacing: 6), common: AtomCommon(paddingX: 4)) {
            if let onToggle {
                AtomButton(
                    common: AtomCommon(
                        testID: toggleTestID, label: label, value: collapsed ? "Collapsed" : "Expanded",
                        help: collapsed ? "Show \(label)" : "Hide \(label)"
                    ),
                    action: onToggle
                ) {
                    AtomStack(props: StackProps(axis: "h", spacing: 6)) {
                        AtomIcon(props: IconProps(name: collapsed ? PHIcon.chevronRight.name : PHIcon.chevronDown.name, size: 9, weight: "bold", color: "tertiary"), common: AtomCommon(width: 10))
                        title
                    }
                }
            } else {
                title
            }
            if loading {
                AtomSpinner(props: SpinnerProps(size: "mini"), common: AtomCommon(testID: loadingTestID))
            }
            AtomSpacer()
            // A hover hint like a skill row's: a tooltip never showed inside the list.
            AtomPopover(props: PopoverProps(isPresented: false, arrowEdge: "bottom", width: 240, inset: 12, hover: true), onDismiss: {}) {
                AtomIcon(props: IconProps(name: PHIcon.infoCircle.name, size: 11, color: "tertiary"), common: AtomCommon(testID: introTestID, label: "About \(label)", hint: intro))
            } content: {
                AtomText(props: TextProps(text: intro, size: 12, color: "secondary", wrap: true), common: AtomCommon(testID: "\(introTestID)-hint"))
            }
        }
    }

    private var title: some PHView {
        AtomStack(props: StackProps(axis: "h", spacing: 6)) {
            AtomText(props: TextProps(text: label.uppercased(), size: 11, weight: "semibold", color: "secondary", tracking: 0.6))
            AtomText(props: TextProps(text: String(count), size: 11, color: "tertiary", monospacedDigits: true))
        }
    }

    package init(label: String, count: Int, intro: String, loading: Bool = false, loadingTestID: String? = nil, introTestID: String, collapsed: Bool = false, toggleTestID: String? = nil, onToggle: (() -> Void)? = nil) {
        self.label = label
        self.count = count
        self.intro = intro
        self.loading = loading
        self.loadingTestID = loadingTestID
        self.introTestID = introTestID
        self.collapsed = collapsed
        self.toggleTestID = toggleTestID
        self.onToggle = onToggle
    }
}

/// A list's rows in one rounded card, a hairline between each, composed only of plugin atoms.
package struct SkillsPageCard<Content: PHView>: PHView {
    @PHViewBuilder package var content: () -> Content

    package var body: some PHView {
        AtomStack(props: StackProps(axis: "v", spacing: 0, align: "leading", fill: "panel", cornerRadius: 10, stroke: "primary", strokeOpacity: 0.08), common: AtomCommon(fillWidth: true)) {
            content()
        }
    }

    package init(@PHViewBuilder content: @escaping () -> Content) {
        self.content = content
    }
}

/// The Skills list under the tabs, composed only of plugin atoms: a row with
/// the search and New Skill (or the selection's actions), a row with the
/// sections' anchors, then every section in one scroll view (a collapsed one
/// only its header), each skill a single line with its name, the mark of who
/// can use it and its actions menu (Use and Enable/Disable among them), dimmed
/// while it is off, whose details show in a hint left of it while the pointer
/// rests on it.
package struct SkillGalleryView: PHView {
    package let model: SkillsPageModel
    package var actions = SkillsPageActions()

    private var prefix: String { model.prefix }
    private var isSelecting: Bool { model.selection != nil }

    package var body: some PHView {
        AtomStack(props: StackProps(axis: "v", spacing: 0, align: "leading")) {
            AtomStack(props: StackProps(axis: "h", spacing: 8), common: AtomCommon(paddingX: 20)) {
                if isSelecting {
                    AtomSpacer()
                    selectionActions
                } else {
                    SkillsPageSearchField(text: model.search, placeholder: "Search skills", testID: "\(prefix)skills-search", onChange: actions.search)
                    AtomButton(
                        props: ButtonProps(style: "bordered", controlSize: "small"),
                        common: AtomCommon(testID: "\(prefix)new-skill-button", help: "Create a skill that both Claude and Codex can use"),
                        action: actions.newSkill
                    ) {
                        AtomLabel(props: LabelProps(text: "New Skill", icon: PHIcon.plus.name))
                    }
                }
            }
            AtomStack(props: StackProps(axis: "h", spacing: 8), common: AtomCommon(paddingX: 20, paddingY: 12)) {
                SkillsPageAnchorBar(
                    testID: "\(prefix)skills-tab-picker", anchorPrefix: "\(prefix)skills-anchor",
                    anchors: model.groups.map { SkillsPageAnchor(value: $0.value, label: $0.label, count: $0.count) },
                    onJump: actions.jump
                )
                AtomSpacer()
            }
            if let error = model.error {
                AtomText(props: TextProps(text: error, size: 12, color: "red"), common: AtomCommon(testID: "\(prefix)skills-error", fillWidth: true, paddingX: 20, paddingY: 4))
            }
            AtomDivider()
            AtomScroll(
                props: ScrollProps(spacing: 18, inset: 20, scrollTo: model.scrollTo, scrollRequest: model.scrollRequest),
                common: AtomCommon(testID: "\(prefix)skills-list")
            ) {
                content
            }
        }
    }

    private var selectionActions: some PHView {
        AtomStack(props: StackProps(axis: "h", spacing: 6)) {
            AtomText(
                props: TextProps(text: model.selectionCount, size: 12, color: "secondary", monospacedDigits: true),
                common: AtomCommon(testID: "\(prefix)skills-selection-count")
            )
            AtomButton(
                props: ButtonProps(style: "bordered", disabled: !model.canFixSelection || model.isFixing, controlSize: "small"),
                common: AtomCommon(testID: "\(prefix)skills-fix-selected", help: "Open a task whose agent fixes the selected conflicting or invalid skills"),
                action: actions.fixSelected
            ) {
                AtomLabel(props: LabelProps(text: "Fix", icon: PHIcon.wandAndStars.name))
            }
            AtomButton(
                props: ButtonProps(style: "bordered", disabled: model.selection?.isEmpty != false, controlSize: "small", destructive: true),
                common: AtomCommon(testID: "\(prefix)skills-delete-selected", help: "Delete the selected skills from disk"),
                action: actions.deleteSelected
            ) {
                AtomLabel(props: LabelProps(text: "Delete", icon: PHIcon.trash.name))
            }
            AtomButton(
                props: ButtonProps(style: "bordered", controlSize: "small", shortcut: model.panelOpen ? nil : "cancel"),
                common: AtomCommon(testID: "\(prefix)skills-selection-done", help: "Stop selecting skills"),
                action: actions.endSelection
            ) {
                AtomText(props: TextProps(text: "Done"))
            }
        }
    }

    @PHViewBuilder
    private var content: some PHView {
        if !model.loaded {
            AtomStack(props: StackProps(axis: "h")) {
                AtomSpacer()
                AtomSpinner(props: SpinnerProps(size: "regular"), common: AtomCommon(testID: "\(prefix)skills-loading"))
                AtomSpacer()
            }
        } else {
            PHForEach(model.groups, id: \.value) { group($0) }
            AtomText(
                props: TextProps(text: isSelecting ? model.selectingHint : model.hint, size: 10, color: "tertiary"),
                common: AtomCommon(testID: "\(prefix)skills-provider-timing", paddingX: 4)
            )
        }
    }

    private func group(_ group: SkillsPageModel.Group) -> some PHView {
        AtomStack(
            props: StackProps(axis: "v", spacing: 8, align: "leading", group: true, scrollID: group.value),
            common: AtomCommon(testID: "\(prefix)skills-group-\(group.value)", label: group.label, fillWidth: true)
        ) {
            SkillsPageGroupHeader(
                label: group.label, count: group.count, intro: group.intro, loading: group.loading,
                loadingTestID: "\(prefix)skills-\(group.value)-loading", introTestID: "\(prefix)skills-intro-\(group.value)",
                collapsed: group.collapsed, toggleTestID: "\(prefix)skills-collapse-\(group.value)",
                onToggle: { actions.toggleGroup(group.value) }
            )
            if !group.collapsed { groupContent(group) }
        }
    }

    @PHViewBuilder
    private func groupContent(_ group: SkillsPageModel.Group) -> some PHView {
        if let empty = group.empty { emptyState(empty) }
        PHForEach(Array(group.sections.enumerated()), id: \.offset) { _, section in
            if let title = section.title {
                AtomText(props: TextProps(text: title, size: 12, weight: "semibold"), common: AtomCommon(testID: "\(prefix)skills-repo-section-\(title)", paddingX: 4))
            }
            if let empty = section.empty { emptyState(empty) }
            if !section.rows.isEmpty {
                SkillsPageCard {
                    PHForEach(Array(section.rows.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { AtomDivider() }
                        row(item)
                    }
                }
            }
        }
    }

    private func emptyState(_ empty: SkillsPageModel.Empty) -> some PHView {
        AtomText(props: TextProps(text: empty.text, size: 12, color: "secondary"), common: AtomCommon(testID: "\(prefix)skills-empty-\(empty.key)", paddingX: 4))
    }

    private func row(_ row: SkillsPageModel.Row) -> some PHView {
        let name = row.name
        let isSelected = model.selection?.contains(row.id) == true
        return AtomPopover(
            props: PopoverProps(isPresented: false, arrowEdge: "leading", width: 200, inset: 12, hover: true),
            onDismiss: {}
        ) {
            AtomStack(
                props: StackProps(axis: "h", spacing: 8, group: true, fill: isSelected ? "accent" : nil, fillOpacity: isSelected ? 0.12 : nil),
                // Off, the row dims but every control in it still responds.
                common: AtomCommon(testID: "\(prefix)skill-row-\(name)", fillWidth: true, paddingX: 12, paddingY: 6, opacity: row.enabled ? nil : 0.45)
            ) {
                // A press and hold starts selecting; a click opens the skill, or selects while
                // selecting. Only the skill's own text takes them: a held click on a control, such
                // as the actions menu while it tracks, must not start selecting.
                AtomPressArea(
                    props: PressAreaProps(pointer: isSelecting ? row.editable : row.opensOnClick),
                    common: AtomCommon(testID: "\(prefix)skill-text-\(name)", label: row.enabled ? name : "\(name), off", hint: row.description),
                    onPress: { actions.press(row.id) },
                    onLongPress: { actions.longPress(row.id) }
                ) {
                    AtomStack(props: StackProps(axis: "h", spacing: 8)) {
                        if isSelecting, row.editable {
                            AtomIcon(
                                props: IconProps(name: isSelected ? PHIcon.checkmarkCircleFill.name : "circle", size: 14, color: isSelected ? "accent" : "secondary"),
                                common: AtomCommon(testID: "\(prefix)skill-select-\(name)", label: isSelected ? "Selected" : "Not selected")
                            )
                        }
                        // Who can use the skill leads its name; its warning follows it.
                        if let mark = row.provider {
                            ProviderMarkIcon(mark: mark, prefix: prefix)
                        }
                        AtomText(props: TextProps(text: name, size: 13, weight: "medium", lineLimit: 1), common: AtomCommon(testID: "\(prefix)skill-name-\(name)"))
                        if let flag = row.flag {
                            AtomIcon(props: IconProps(name: flag.icon, size: 11, color: flag.color), common: AtomCommon(testID: "\(prefix)\(flag.testID)", label: flag.text, help: flag.text))
                        }
                        AtomSpacer(props: SpacerProps(minLength: 8))
                    }
                }
                if !isSelecting {
                    controls(row)
                }
            }
        } content: {
            hint(row)
        }
    }

    /// A skill's details, shown left of its row while the pointer rests on it.
    private func hint(_ row: SkillsPageModel.Row) -> some PHView {
        let name = row.name
        return AtomStack(props: StackProps(axis: "v", spacing: 6, align: "leading", group: true), common: AtomCommon(testID: "\(prefix)skill-hint-\(name)")) {
            AtomText(props: TextProps(text: name, size: 13, weight: "semibold"))
            if let description = row.description {
                AtomText(props: TextProps(text: description, size: 12, color: "secondary", wrap: true), common: AtomCommon(testID: "\(prefix)skill-description-\(name)"))
            }
            if !row.badges.isEmpty || row.flag != nil {
                AtomStack(props: StackProps(axis: "h", spacing: 4)) {
                    if let flag = row.flag { badge(flag, testID: nil) }
                    PHForEach(row.badges, id: \.testID) { badge($0, testID: "\(prefix)\($0.testID)") }
                }
            }
            // Its own line, so the command never wraps beside the chips.
            if let command = row.command { badge(command, testID: "\(prefix)\(command.testID)") }
            if let issue = row.issue {
                AtomText(props: TextProps(text: issue, size: 11, color: "orange", wrap: true), common: AtomCommon(testID: "\(prefix)skill-issue-\(name)"))
            }
            AtomText(props: TextProps(text: row.location, size: 10, color: "tertiary", wrap: true), common: AtomCommon(testID: "\(prefix)skill-location-\(name)"))
        }
    }

    @PHViewBuilder
    private func controls(_ row: SkillsPageModel.Row) -> some PHView {
        let name = row.name
        if row.fixable {
            AtomButton(
                props: ButtonProps(style: "bordered", disabled: model.isFixing, controlSize: "small"),
                common: AtomCommon(testID: "\(prefix)skill-fix-\(name)", help: "Open a task whose agent fixes \(name)"),
                action: { actions.fix(row.id) }
            ) {
                AtomLabel(props: LabelProps(text: "Fix", icon: PHIcon.wandAndStars.name))
            }
        }
        AtomMenu(
            props: MenuProps(icon: PHIcon.ellipsis.name, size: 12, weight: "semibold", items: ([SkillsPageModel.leadingMenu(row)] + row.menu).map { group in
                group.map { .init(id: $0.id, title: $0.title, destructive: $0.destructive, help: $0.help, testID: "\(prefix)\($0.testID)", disabled: $0.disabled) }
            }),
            common: AtomCommon(testID: "\(prefix)skill-actions-\(name)", label: "Actions for \(name)", help: "More actions for \(name)", width: 22, height: 22),
            onMenu: { actions.menu(row.id, $0) }
        )
    }

    private func badge(_ badge: SkillsPageModel.Badge, testID: String?) -> some PHView {
        AtomStack(props: StackProps(fill: badge.color, fillOpacity: 0.12, capsule: true), common: AtomCommon(testID: testID, fixedSize: true, paddingX: 6, paddingY: 2)) {
            AtomLabel(props: LabelProps(text: badge.text, icon: badge.icon, size: 10, weight: "medium", color: badge.color))
        }
    }

    package init(model: SkillsPageModel, actions: SkillsPageActions = SkillsPageActions()) {
        self.model = model
        self.actions = actions
    }
}
