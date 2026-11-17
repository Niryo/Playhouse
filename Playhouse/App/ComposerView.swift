import SwiftUI

/// What the conversation composer's box shows, already derived from the
/// conversation's state: plain values the native composer and the catalog's
/// JavaScript copy (catalog/Composer.js, as `Playhouse.props.composer`)
/// compose the same way. Notices, attached images, queued follow-ups and the
/// goal row stay native, above the box.
struct ComposerModel: Codable, Equatable {
    /// A menu entry; `id` is what the action receives, `testID` the identifier.
    struct Item: Codable, Equatable {
        var id: String
        var title: String
        var checked: Bool
        var icon: String?
        var help: String
        var testID: String
    }

    struct Option: Codable, Equatable {
        var value: String
        var label: String
    }

    /// The + menu: Goal (where the provider supports goals) and the modes. `text` is
    /// "Goal" or "Plan" beside the symbol while either is on, which also tints it.
    struct ModeMenu: Codable, Equatable {
        var text: String?
        var badgeIcon: String?
        var active: Bool
        var label: String
        var items: [Item]
    }

    /// The Start Implementing button of a finished plan; `unavailableReason` also
    /// shows beside it as a button that opens the repository picker.
    struct StartImplementing: Codable, Equatable {
        var disabled: Bool
        var help: String
        var value: String
        var unavailableReason: String?
        /// secondary or orange, as the repository title is.
        var reasonColor: String
        var reasonDisabled: Bool
    }

    struct ProviderMenu: Codable, Equatable {
        var title: String
        var value: String
        var label: String
        var help: String
        var enabled: Bool
        var items: [Item]
    }

    /// The model button and its popover: the models and the reasoning effort slider.
    struct ModelPicker: Codable, Equatable {
        var name: String
        var effort: String
        var label: String
        var open: Bool
        var models: [Item]
        var effortChoices: [Option]
        var selectedEffort: String
    }

    struct Schedule: Codable, Equatable {
        var on: Bool
        var help: String
        var open: Bool
    }

    /// The control after the pickers. `kind` is stop, continue, schedule or send.
    struct Primary: Codable, Equatable {
        var kind: String
        var disabled: Bool
        var help: String
        var label: String
        var value: String
        var testID: String
    }

    /// Starts every accessibility identifier ("" in the conversation, "native-"
    /// on the catalog's native side, so the two never share one).
    var prefix: String
    var draft: String
    var placeholder: String
    var enabled: Bool
    var autofocus: Bool
    var focused: Bool
    var focusRequest: Int
    var editorHelp: String
    var modeMenu: ModeMenu
    var startImplementing: StartImplementing?
    var provider: ProviderMenu
    var model: ModelPicker
    /// Nil where the conversation can't be scheduled.
    var schedule: Schedule?
    var primary: Primary
}

/// What the composer's controls do. The native composer sets each; the
/// catalog's native copy leaves them as no-ops.
struct ComposerActions {
    var change: (String) -> Void = { _ in }
    var submit: () -> Void = {}
    var steer: () -> Void = {}
    var focusChange: (Bool) -> Void = { _ in }
    var pasteImage: (Data) -> Void = { _ in }
    /// The editor's selected range, in UTF-16 offsets.
    var selectionChange: (NSRange) -> Void = { _ in }
    var openSkills: () -> Void = {}
    /// goal, mode:default or mode:plan.
    var modeMenu: (String) -> Void = { _ in }
    var startImplementing: () -> Void = {}
    var showRepositoryPicker: () -> Void = {}
    /// A provider's raw value.
    var provider: (String) -> Void = { _ in }
    var toggleModelPicker: () -> Void = {}
    var dismissModelPicker: () -> Void = {}
    var selectModel: (String) -> Void = { _ in }
    var selectEffort: (String) -> Void = { _ in }
    var toggleSchedule: () -> Void = {}
    var dismissSchedule: () -> Void = {}
    var primary: () -> Void = {}
}

/// The composer's box, composed only of plugin atoms: the editor, then the
/// Skills button, the + menu, Start Implementing, the provider menu, the
/// model button with its popover, the schedule button and the send, stop,
/// continue or schedule control. What sits above the editor (`header`) and
/// the schedule popover's content are native and handed in.
struct ComposerView<Header: View, ScheduleContent: View>: View {
    let model: ComposerModel
    var actions = ComposerActions()
    @ViewBuilder var header: () -> Header
    @ViewBuilder var scheduleContent: () -> ScheduleContent
    /// Installed plugins' entries (and Add Plugin mode's placeholder) beside
    /// the Skills button; native, and absent from the catalog's copy.
    var pluginActions: AnyView? = nil
    /// The editor's `@` mentions; native, and absent from the catalog's copy.
    var mentions = ChatEditorMentions()

    var body: some View {
        AtomPanel(
            props: PanelProps(spacing: 10, fill: "panel", fillOpacity: 1, cornerRadius: 21, stroke: "primary", strokeOpacity: 0.1),
            common: AtomCommon(padding: 13)
        ) {
            header()
            AtomEditor(
                props: EditorProps(
                    text: model.draft, placeholder: model.placeholder, placeholderTestID: prefix + "composer-placeholder",
                    enabled: model.enabled, autofocus: model.autofocus, focused: model.focused, focusRequest: model.focusRequest,
                    inputTestID: prefix + "message-composer", inputLabel: "Message"
                ),
                common: AtomCommon(testID: prefix + "message-composer-scroll-view", hint: model.editorHelp),
                onChange: actions.change, onSubmit: actions.submit, onSteerSubmit: actions.steer,
                onFocusChange: actions.focusChange, onPasteImage: actions.pasteImage,
                onSelectionChange: actions.selectionChange, mentions: mentions
            )
            toolbar
        }
    }

    private var toolbar: some View {
        AtomStack(props: StackProps(axis: "h", spacing: 12)) {
            SkillsButton(testID: prefix + "open-skills-button", action: actions.openSkills)
            if let pluginActions {
                pluginActions
            }
            modeMenu
            if let start = model.startImplementing {
                startImplementing(start)
            }
            AtomSpacer(props: SpacerProps(minLength: 0))
            providerMenu
            modelPicker
            if let schedule = model.schedule {
                scheduleButton(schedule)
            }
            primary
        }
    }

    private var modeMenu: some View {
        let mode = model.modeMenu
        return AtomMenu(
            props: MenuProps(
                icon: "plus", size: 14, weight: "semibold", color: mode.active ? "accent" : "secondary",
                text: mode.text, textSize: 11, textWeight: "semibold", badgeIcon: mode.badgeIcon,
                items: [mode.items.map(menuItem)]
            ),
            common: AtomCommon(
                testID: prefix + "conversation-mode-menu", label: mode.label,
                help: "Change conversation mode or add context", minWidth: 30, minHeight: 31
            ),
            onMenu: actions.modeMenu
        )
    }

    private var prefix: String { model.prefix }

    private func menuItem(_ item: ComposerModel.Item) -> MenuProps.Item {
        MenuProps.Item(id: item.id, title: item.title, help: item.help, testID: prefix + item.testID, checked: item.checked, icon: item.checked ? nil : item.icon)
    }

    @ViewBuilder
    private func startImplementing(_ start: ComposerModel.StartImplementing) -> some View {
        AtomButton(
            props: ButtonProps(disabled: start.disabled),
            common: AtomCommon(
                testID: prefix + "start-implementing-button", value: start.value,
                hint: "Switches to Code mode and starts implementing this plan", help: start.help
            ),
            action: actions.startImplementing
        ) {
            AtomPanel(props: PanelProps(fill: "accent", fillOpacity: 1, cornerRadius: 15.5), common: AtomCommon(height: 31, padding: 0, paddingX: 11)) {
                AtomText(props: TextProps(text: "Start Implementing", size: 12, weight: "semibold", color: "white"))
            }
        }
        if let reason = start.unavailableReason {
            AtomButton(
                props: ButtonProps(disabled: start.reasonDisabled),
                common: AtomCommon(testID: prefix + "start-implementing-unavailable-reason", label: "No repository", value: reason, hint: "Opens the repository picker", help: reason),
                action: actions.showRepositoryPicker
            ) {
                AtomLabel(props: LabelProps(text: "No repository", icon: "exclamationmark.triangle.fill", size: 11, weight: "semibold", color: start.reasonColor))
            }
        }
    }

    private var providerMenu: some View {
        let provider = model.provider
        return AtomMenu(
            props: MenuProps(
                color: "secondary", text: provider.title, textSize: 12, textWeight: "medium",
                indicator: true, disabled: !provider.enabled, items: [provider.items.map(menuItem)]
            ),
            common: AtomCommon(testID: prefix + "conversation-provider-menu", label: provider.label, value: provider.value, help: provider.help),
            onMenu: actions.provider
        )
    }

    private var modelPicker: some View {
        ComposerModelPicker(
            picker: model.model, prefix: prefix,
            toggle: actions.toggleModelPicker, dismiss: actions.dismissModelPicker,
            selectModel: actions.selectModel, selectEffort: actions.selectEffort
        )
    }

    private func scheduleButton(_ schedule: ComposerModel.Schedule) -> some View {
        AtomPopover(
            props: PopoverProps(isPresented: schedule.open, arrowEdge: "top", inset: 0),
            common: AtomCommon(testID: prefix + "schedule-popover"),
            onDismiss: actions.dismissSchedule,
            anchor: {
                AtomButton(
                    common: AtomCommon(testID: prefix + "schedule-task-button", label: "Schedule", value: schedule.on ? "On" : "Off", help: schedule.help),
                    action: actions.toggleSchedule
                ) {
                    AtomPanel(
                        props: PanelProps(fill: "accent", fillOpacity: schedule.on ? 0.14 : 0, cornerRadius: 13),
                        common: AtomCommon(width: 26, height: 26, padding: 0)
                    ) {
                        AtomIcon(props: IconProps(name: schedule.on ? "clock.fill" : "clock", size: 12, weight: "medium", color: schedule.on ? "accent" : "secondary"))
                    }
                }
            },
            content: scheduleContent
        )
    }

    @ViewBuilder
    private var primary: some View {
        let primary = model.primary
        AtomButton(
            props: ButtonProps(disabled: primary.disabled),
            common: AtomCommon(testID: prefix + primary.testID, label: primary.label, value: primary.value.isEmpty ? nil : primary.value, help: primary.help),
            action: actions.primary
        ) {
            switch primary.kind {
            case "stop":
                primaryIcon("stop.fill", fill: "primary", opacity: 0.72, size: 11, radius: 9)
            case "continue":
                primaryIcon("play.fill", fill: "accent", opacity: 1, size: 11, radius: 9)
            case "schedule":
                AtomPanel(
                    props: PanelProps(fill: "accent", fillOpacity: 1, cornerRadius: 15.5),
                    common: AtomCommon(height: 31, padding: 0, paddingX: 12, opacity: primary.disabled ? 0.45 : 1)
                ) {
                    AtomLabel(props: LabelProps(text: "Schedule", icon: "clock", size: 12, weight: "semibold", color: "white"))
                }
            default:
                primaryIcon("arrow.up", fill: "accent", opacity: 1, size: 13, radius: 15.5, dimmed: primary.disabled)
            }
        }
    }

    private func primaryIcon(_ name: String, fill: String, opacity: Double, size: Double, radius: Double, dimmed: Bool = false) -> some View {
        AtomPanel(
            props: PanelProps(fill: fill, fillOpacity: opacity, cornerRadius: radius),
            common: AtomCommon(width: 31, height: 31, padding: 0, opacity: dimmed ? 0.45 : 1)
        ) {
            AtomIcon(props: IconProps(name: name, size: size, weight: "bold", color: "white"))
        }
    }
}

/// The model button and its popover of models and reasoning effort, composed of plugin atoms.
/// The composer shows it in its toolbar and the side chat bubble in its own; `prefix` starts
/// every accessibility identifier, so the two never share one.
struct ComposerModelPicker: View {
    let picker: ComposerModel.ModelPicker
    var prefix = ""
    let toggle: () -> Void
    let dismiss: () -> Void
    let selectModel: (String) -> Void
    let selectEffort: (String) -> Void

    var body: some View {
        return AtomPopover(
            props: PopoverProps(isPresented: picker.open, arrowEdge: "top", width: 320, inset: 0),
            common: AtomCommon(testID: prefix + "model-picker-popover"),
            onDismiss: dismiss,
            anchor: {
                AtomButton(
                    common: AtomCommon(
                        testID: prefix + "model-picker-menu", label: picker.label, value: picker.name,
                        help: "Choose a model and reasoning effort", opacity: 0.82
                    ),
                    action: toggle
                ) {
                    AtomStack(props: StackProps(axis: "h", spacing: 7)) {
                        AtomText(props: TextProps(text: picker.name, size: 12, weight: "medium"))
                        AtomText(props: TextProps(text: picker.effort, size: 12, weight: "medium", color: "secondary"))
                        AtomIcon(props: IconProps(name: "chevron.down", size: 9, weight: "semibold", color: "tertiary"))
                    }
                }
            },
            content: {
                AtomStack(props: StackProps(axis: "v", spacing: 0, align: "leading"), common: AtomCommon(padding: 13, paddingX: 5)) {
                    ForEach(picker.models, id: \.id) { option in
                        AtomButton(
                            common: AtomCommon(testID: prefix + option.testID, value: option.checked ? "Selected" : "Not selected", help: option.help),
                            action: { selectModel(option.id) }
                        ) {
                            AtomStack(props: StackProps(axis: "h"), common: AtomCommon(minHeight: 32, fillWidth: true)) {
                                AtomText(props: TextProps(text: option.title))
                                AtomSpacer(props: SpacerProps())
                                if option.checked {
                                    AtomIcon(props: IconProps(name: "checkmark", size: 12, weight: "semibold"), common: AtomCommon(testID: prefix + option.testID + "-checked"))
                                }
                            }
                        }
                    }
                    AtomDivider(common: AtomCommon(paddingY: 8))
                    AtomText(
                        props: TextProps(text: Self.title(of: picker.selectedEffort, in: picker.effortChoices), size: 14, weight: "medium", color: "accent"),
                        common: AtomCommon(testID: prefix + "selected-model-effort")
                    )
                    AtomStepSlider(
                        props: StepSliderProps(options: picker.effortChoices.map { .init(value: $0.value, label: $0.label) }, selected: picker.selectedEffort),
                        common: AtomCommon(testID: prefix + "model-effort-slider", label: "Model effort"),
                        onChange: selectEffort
                    )
                }
            }
        )
    }

    private static func title(of value: String, in options: [ComposerModel.Option]) -> String {
        options.first { $0.value == value }?.label ?? value
    }
}

extension ComposerView where Header == EmptyView, ScheduleContent == EmptyView {
    init(model: ComposerModel, actions: ComposerActions = ComposerActions()) {
        self.init(model: model, actions: actions, header: { EmptyView() }, scheduleContent: { EmptyView() })
    }
}

/// The `@` mention menu above the composer: the suggestions for what follows the `@`, the
/// highlighted one first in keyboard order. Browsing everything groups the rows under a header
/// per kind; recent mentions and a query's matches are one list under one header. Rows and
/// headers are plugin atoms; the list is a native scroll view so the highlighted row stays in
/// view as the arrow keys move it. It holds at most 80 rows, so it builds them all.
struct ComposerMentionMenu: View {
    let query: String
    let items: [MentionItem]
    /// Whether `items` are the recent mentions an empty query shows.
    let showsRecent: Bool
    let isLoading: Bool
    let selectedIndex: Int
    let select: (MentionItem) -> Void

    private static let width: CGFloat = 460
    private static let inset: CGFloat = 8
    private static let rowHeight: CGFloat = 32
    private static let headerHeight: CGFloat = 30
    private static let maxListHeight: CGFloat = 360

    private struct Section: Identifiable {
        let id: String
        let title: String
        /// The header's identifier: the menu's title for a single list, the kind's section otherwise.
        let testID: String
        /// Each row with its index in `items`, which is the keyboard order.
        let rows: [(index: Int, item: MentionItem)]
    }

    var body: some View {
        AtomPanel(
            props: PanelProps(spacing: 0, fill: "panel", fillOpacity: 1, cornerRadius: 18, stroke: "primary", strokeOpacity: 0.1),
            common: AtomCommon(testID: "mention-menu", label: "Mentions", value: title, width: Double(Self.width), padding: Double(Self.inset))
        ) {
            if items.isEmpty {
                header(title, testID: "mention-menu-title")
                AtomText(
                    props: TextProps(text: isLoading ? "Loading…" : "Nothing to mention matches “\(query)”", size: 13, color: "tertiary"),
                    common: AtomCommon(testID: "mention-menu-empty", fillWidth: true, paddingX: 12, paddingY: 8)
                )
            } else {
                let sections = sections
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(sections) { section in
                                header(section.title, testID: section.testID)
                                ForEach(section.rows, id: \.item.id) { row in
                                    self.row(row.item, selected: row.index == selectedIndex).id(row.item.id)
                                }
                            }
                        }
                        .hoverRevealScrollers()
                    }
                    .frame(height: min(Self.listHeight(sections), Self.maxListHeight))
                    .onChange(of: selectedIndex) { _, index in
                        if items.indices.contains(index) { proxy.scrollTo(items[index].id) }
                    }
                }
            }
        }
        .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
    }

    private var title: String {
        if !query.isEmpty { return "Mention matching “\(query)”" }
        return showsRecent ? "Recent mentions" : "Mention a skill, MCP server, agent, repository or task"
    }

    /// One section per run of a kind while browsing everything; otherwise one under the menu's title.
    private var sections: [Section] {
        let indexed = items.enumerated().map { (index: $0.offset, item: $0.element) }
        guard query.isEmpty, !showsRecent else {
            return [Section(id: "all", title: title, testID: "mention-menu-title", rows: indexed)]
        }
        var sections: [Section] = []
        var start = 0
        while start < indexed.count {
            let kind = indexed[start].item.kind
            var end = start
            while end < indexed.count, indexed[end].item.kind == kind { end += 1 }
            sections.append(Section(id: "\(kind.rawValue)-\(start)", title: kind.sectionTitle, testID: "mention-section-\(kind.rawValue)", rows: Array(indexed[start..<end])))
            start = end
        }
        return sections
    }

    private static func listHeight(_ sections: [Section]) -> CGFloat {
        sections.reduce(0) { $0 + headerHeight + CGFloat($1.rows.count) * rowHeight }
    }

    private func header(_ text: String, testID: String) -> some View {
        AtomText(
            props: TextProps(text: text, size: 12, weight: "medium", color: "secondary", lineLimit: 1, truncation: "tail"),
            common: AtomCommon(testID: testID, height: Double(Self.headerHeight), fillWidth: true, paddingX: 12)
        )
    }

    private func row(_ item: MentionItem, selected: Bool) -> some View {
        AtomButton(
            props: ButtonProps(selected: selected),
            common: AtomCommon(
                testID: "mention-item-\(item.handle)", label: "@" + item.handle,
                value: "\(item.kind.title): \(item.title)" + (item.detail.isEmpty ? "" : " — \(item.detail)"),
                help: item.detail.isEmpty ? "@" + item.handle : "@\(item.handle) · \(item.detail)"
            ),
            action: { select(item) }
        ) {
            // Only the highlighted row draws a surface; a fill on every row read as a stack of cards.
            AtomStack(
                props: StackProps(axis: "h", spacing: 10, fill: selected ? "primary" : nil, fillOpacity: selected ? 0.09 : nil, cornerRadius: 9),
                common: AtomCommon(height: Double(Self.rowHeight), fillWidth: true, paddingX: 12)
            ) {
                AtomIcon(props: IconProps(name: Self.icon(item.kind), size: 13, weight: "regular", color: "secondary"), common: AtomCommon(width: 18))
                AtomText(props: TextProps(text: item.title, size: 13, color: "primary", lineLimit: 1, truncation: "tail"))
                    .layoutPriority(1)
                if !item.detail.isEmpty {
                    AtomText(props: TextProps(text: item.detail, size: 13, color: "secondary", lineLimit: 1, truncation: "tail"))
                }
                AtomSpacer(props: SpacerProps(minLength: 0))
            }
        }
    }

    static func icon(_ kind: MentionKind) -> String {
        switch kind {
        case .skill: "sparkles"
        case .mcp: "server.rack"
        case .agent: "person.crop.circle"
        case .repository: "folder"
        case .task: "checklist"
        }
    }
}

/// What the `/` menu's rows do: choosing a row (by its keyboard index) and the buttons at
/// the end of an item's row.
struct ComposerSlashActions {
    var choose: (Int) -> Void
    var gear: (SlashCommandItem) -> Void
    var signIn: (SlashCommandItem, ConversationProvider) -> Void
    var edit: (SlashCommandItem) -> Void
    var delete: (SlashCommandItem) -> Void
}

/// The `/` command menu above the composer: the matching commands, or a command's own list
/// (MCP servers, skills, agents to sign in to, plugins), the highlighted row first in keyboard
/// order. A command the task's agent can't run is listed disabled with why. Rows are plugin
/// atoms, as in the mention menu.
struct ComposerSlashMenu: View {
    let menu: SlashCommandMenu
    let isLoading: Bool
    /// Both agents are still asked which MCP servers need a sign-in.
    let isCheckingSignIn: Bool
    let selectedIndex: Int
    let actions: ComposerSlashActions

    static let rowHeight: CGFloat = 34

    private var rowCount: Int { menu.command == nil ? menu.commands.count : menu.items.count }

    var body: some View {
        AtomPanel(
            props: PanelProps(spacing: 4, fill: "panel", fillOpacity: 1, cornerRadius: 12, stroke: "primary", strokeOpacity: 0.14),
            common: AtomCommon(testID: "slash-menu", label: "Commands", value: title, width: 480, padding: 6)
        ) {
            AtomStack(props: StackProps(axis: "h", spacing: 6), common: AtomCommon(paddingX: 8, paddingY: 3)) {
                AtomText(
                    props: TextProps(text: title, size: 11, weight: "semibold", color: "secondary", lineLimit: 1, truncation: "tail"),
                    common: AtomCommon(testID: "slash-menu-title")
                )
                AtomSpacer(props: SpacerProps(minLength: 6))
                if isCheckingSignIn {
                    AtomText(
                        props: TextProps(text: "Checking sign-in…", size: 11, color: "tertiary", lineLimit: 1),
                        common: AtomCommon(testID: "slash-menu-checking")
                    )
                }
            }
            if rowCount == 0 {
                AtomText(
                    props: TextProps(text: emptyText, size: 12, color: "tertiary"),
                    common: AtomCommon(testID: "slash-menu-empty", paddingX: 8, paddingY: 6)
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            if menu.command == nil {
                                ForEach(Array(menu.commands.enumerated()), id: \.element.id) { index, entry in
                                    commandRow(entry, index: index).id(index)
                                }
                            } else {
                                ForEach(Array(menu.items.enumerated()), id: \.element.id) { index, item in
                                    itemRow(item, index: index).id(index)
                                }
                            }
                        }
                        .hoverRevealScrollers()
                    }
                    // Nine rows show before the list scrolls.
                    .frame(height: min(CGFloat(rowCount) * (Self.rowHeight + 1), (Self.rowHeight + 1) * 9))
                    .onChange(of: selectedIndex) { _, index in
                        if index < rowCount { proxy.scrollTo(index) }
                    }
                }
            }
        }
    }

    private var title: String {
        switch menu.command {
        case nil: menu.query.isEmpty ? "Commands" : "Commands matching “/\(menu.query)”"
        case .mcp: "MCP servers"
        case .skill: "Skills"
        case .login: "Sign in"
        case .plugin: "Plugins"
        case .plan, .goal: ""
        }
    }

    private var emptyText: String {
        if isLoading { return "Loading…" }
        guard let command = menu.command else { return "No command matches “/\(menu.query)”" }
        let what = command == .mcp ? "MCP server" : command == .skill ? "skill" : "item"
        return menu.filter.isEmpty ? "No \(what)s" : "No \(what) matches “\(menu.filter)”"
    }

    private func commandRow(_ entry: SlashCommandEntry, index: Int) -> some View {
        let selected = index == selectedIndex
        return AtomButton(
            props: ButtonProps(disabled: !entry.enabled, selected: selected),
            common: AtomCommon(
                testID: "slash-command-\(entry.command.rawValue)", label: "/" + entry.command.rawValue,
                value: entry.enabled ? entry.detail : entry.disabledReason, help: entry.disabledReason ?? entry.detail
            ),
            action: { actions.choose(index) }
        ) {
            AtomStack(
                props: StackProps(axis: "h", spacing: 8, fill: selected ? "accent" : nil, fillOpacity: 0.16, cornerRadius: 7),
                common: AtomCommon(minHeight: Self.rowHeight, fillWidth: true, paddingX: 8, opacity: entry.enabled ? 1 : 0.6)
            ) {
                AtomIcon(props: IconProps(name: entry.command.icon, size: 12, weight: "medium", color: "secondary"), common: AtomCommon(width: 16))
                AtomText(props: TextProps(text: "/" + entry.command.rawValue, size: 13, weight: "semibold", color: entry.enabled ? "accent" : "secondary", lineLimit: 1))
                AtomSpacer(props: SpacerProps(minLength: 6))
                AtomText(props: TextProps(text: entry.disabledReason ?? entry.detail, size: 11, color: entry.enabled ? "secondary" : "tertiary", lineLimit: 2, truncation: "tail"))
            }
        }
    }

    /// The suffix of an item's identifiers: the handle for an MCP server or skill.
    static func key(_ item: SlashCommandItem) -> String {
        switch item.kind {
        case .mcp, .skill: "\(item.kind.rawValue)-\(item.handle ?? item.targetID)"
        case .login, .plugin: "\(item.kind.rawValue)-\(item.targetID)"
        case .createPlugin: "create-plugin"
        }
    }

    private func itemRow(_ item: SlashCommandItem, index: Int) -> some View {
        let selected = index == selectedIndex
        let key = Self.key(item)
        return AtomStack(
            props: StackProps(axis: "h", spacing: 4, fill: selected ? "accent" : nil, fillOpacity: 0.16, cornerRadius: 7),
            common: AtomCommon(minHeight: Self.rowHeight, fillWidth: true, paddingX: 4)
        ) {
            AtomButton(
                props: ButtonProps(selected: selected),
                common: AtomCommon(testID: "slash-item-\(key)", label: item.handle.map { "@" + $0 } ?? item.title, value: item.detail, help: itemHelp(item)),
                action: { actions.choose(index) }
            ) {
                AtomStack(props: StackProps(axis: "h", spacing: 8), common: AtomCommon(minHeight: Self.rowHeight, fillWidth: true, paddingX: 4)) {
                    AtomIcon(props: IconProps(name: icon(item), size: 12, weight: "medium", color: "secondary"), common: AtomCommon(width: 16))
                    AtomText(props: TextProps(text: item.handle.map { "@" + $0 } ?? item.title, size: 13, weight: "semibold", color: "accent", lineLimit: 1, truncation: "middle"))
                    AtomSpacer(props: SpacerProps(minLength: 6))
                    AtomText(props: TextProps(text: item.detail, size: 11, color: "secondary", lineLimit: 1, truncation: "tail"))
                }
            }
            ForEach(item.needsSignIn, id: \.self) { provider in
                AtomButton(
                    props: ButtonProps(style: "bordered", controlSize: "small"),
                    common: AtomCommon(testID: "slash-signin-\(key)-\(provider.rawValue)", label: "Sign in for \(provider.displayName)", help: "Sign in to \(item.title) for \(provider.displayName)"),
                    action: { actions.signIn(item, provider) }
                ) {
                    AtomLabel(props: LabelProps(text: "Sign in · \(provider.displayName)", icon: "key", size: 11, weight: "medium"))
                }
            }
            if item.kind == .plugin {
                iconButton("pencil", testID: "slash-edit-\(key)", label: "Edit", help: "Open this plugin's editor") { actions.edit(item) }
                iconButton("trash", testID: "slash-delete-\(key)", label: "Delete", help: "Delete this plugin's folder", destructive: true) { actions.delete(item) }
                // Plugin settings don't exist yet; the gear stays where they will open.
                iconButton("gearshape", testID: "slash-gear-\(key)", label: "Settings", help: "Plugin settings are not available yet", disabled: true) {}
            } else if item.kind == .mcp || item.kind == .skill {
                iconButton(
                    "gearshape", testID: "slash-gear-\(key)", label: "Manage",
                    help: item.editable ? "Open \(item.title) in the \(item.kind == .mcp ? "MCP" : "Skills") page" : "Built-in skills can't be edited",
                    disabled: !item.editable
                ) { actions.gear(item) }
            }
        }
    }

    private func iconButton(_ icon: String, testID: String, label: String, help: String, destructive: Bool = false, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        AtomButton(
            props: ButtonProps(style: "borderless", emphasis: 4, disabled: disabled, destructive: destructive),
            common: AtomCommon(testID: testID, label: label, help: help, width: 26, height: 26),
            action: action
        ) {
            AtomIcon(props: IconProps(name: icon, size: 12, weight: "medium", color: destructive ? "red" : "secondary"))
        }
    }

    private func itemHelp(_ item: SlashCommandItem) -> String {
        switch item.kind {
        case .mcp, .skill: "Mention \(item.title)"
        case .login: item.title
        case .createPlugin: item.detail
        case .plugin: "Open this plugin's editor"
        }
    }

    private func icon(_ item: SlashCommandItem) -> String {
        switch item.kind {
        case .mcp: ComposerMentionMenu.icon(.mcp)
        case .skill: ComposerMentionMenu.icon(.skill)
        case .login: "person.crop.circle"
        case .createPlugin: "plus"
        case .plugin: "puzzlepiece.extension"
        }
    }
}
