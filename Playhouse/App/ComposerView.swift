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

    /// The Plan or Goal button. While `on` it shows an orange highlight; the two
    /// are never on together.
    struct ModeToggle: Codable, Equatable {
        var on: Bool
        var help: String
    }

    /// The attach button, which opens a file panel. It takes images for now.
    struct Attach: Codable, Equatable {
        var disabled: Bool
        var help: String
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
    /// The Skills button leads the toolbar only where the conversation has no
    /// task sidebar (a standalone chat); a task's sidebar holds it instead.
    var skills: Bool
    var attach: Attach
    var plan: ModeToggle
    /// The Optimized context button beside Plan; nil where the conversation has no context
    /// mode (the standalone chat). Independent of Plan and Goal.
    var optimizedContext: ModeToggle? = nil
    /// Nil where the provider has no goals.
    var goal: ModeToggle?
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
    var attach: () -> Void = {}
    /// Turns Plan mode on (and Goal off) or off.
    var togglePlan: () -> Void = {}
    /// Turns optimized context on or off.
    var toggleOptimizedContext: () -> Void = {}
    /// Turns goal entry on (and Plan mode off) or off.
    var toggleGoal: () -> Void = {}
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
/// attach button, the Skills button, the Plan and Goal buttons, Start Implementing, the provider menu, the
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

    /// The actions, then the provider, model and send at the trailing edge: one row where both fit,
    /// otherwise the second group on a row of its own, so a narrow box (the chat sidebar) never
    /// grows past its container.
    private var toolbar: some View {
        ComposerToolbarLayout(spacing: 12) {
            AtomStack(props: StackProps(axis: "h", spacing: 12)) {
                attachButton
                if model.skills {
                    SkillsButton(testID: prefix + "open-skills-button", action: actions.openSkills)
                }
                if let pluginActions {
                    pluginActions
                }
                modeToggle(model.plan, testID: "conversation-plan-button", label: "Plan mode", action: actions.togglePlan) { on in
                    AtomIcon(props: IconProps(name: "lightbulb.max", size: 13, weight: "medium", color: Self.modeColor(on)))
                }
                if let optimized = model.optimizedContext {
                    modeToggle(optimized, testID: "conversation-optimized-context-button", label: "Optimized context", action: actions.toggleOptimizedContext) { on in
                        AtomIcon(props: IconProps(name: "gauge.open.with.lines.needle.33percent.and.arrowtriangle.from.0percent.to.50percent", size: 14, weight: "medium", color: Self.modeColor(on)))
                    }
                }
                if let goal = model.goal {
                    modeToggle(goal, testID: "conversation-goal-button", label: "Goal", action: actions.toggleGoal) { on in
                        AtomIcon(props: IconProps(asset: "GoalIcon", color: Self.modeColor(on)), common: AtomCommon(width: 15, height: 15))
                    }
                }
                if let start = model.startImplementing {
                    startImplementing(start)
                }
            }
            AtomStack(props: StackProps(axis: "h", spacing: 12)) {
                providerMenu
                modelPicker
                if let schedule = model.schedule {
                    scheduleButton(schedule)
                }
                primary
            }
        }
    }

    private var attachButton: some View {
        AtomButton(
            props: ButtonProps(disabled: model.attach.disabled),
            common: AtomCommon(testID: prefix + "composer-attach-button", label: "Attach files", help: model.attach.help),
            action: actions.attach
        ) {
            AtomPanel(props: PanelProps(fillOpacity: 0, cornerRadius: 13), common: AtomCommon(width: 26, height: 26, padding: 0)) {
                AtomIcon(props: IconProps(name: "paperclip", size: 13, weight: "medium", color: "secondary"))
            }
        }
    }

    /// A Plan or Goal button: its icon, on an orange highlight while the mode is on.
    private func modeToggle<Icon: View>(
        _ toggle: ComposerModel.ModeToggle, testID: String, label: String, action: @escaping () -> Void, @ViewBuilder icon: (Bool) -> Icon
    ) -> some View {
        let icon = icon(toggle.on)
        return AtomButton(
            common: AtomCommon(testID: prefix + testID, label: label, value: toggle.on ? "On" : "Off", help: toggle.help),
            action: action
        ) {
            AtomPanel(
                props: PanelProps(fill: "orange", fillOpacity: toggle.on ? 0.18 : 0, cornerRadius: 13),
                common: AtomCommon(width: 26, height: 26, padding: 0)
            ) {
                icon
            }
        }
    }

    private static func modeColor(_ on: Bool) -> String { on ? "orange" : "secondary" }

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

/// The composer's toolbar: its actions at the leading edge and its controls at the trailing edge,
/// with at least the gap a spacer between two spaced items keeps. They share one row only while
/// both fit at their natural widths; squeezing them into one row instead wrapped the model
/// button's name a few letters to a line and still made the box wider than a narrow chat.
private struct ComposerToolbarLayout: Layout {
    var spacing: CGFloat
    var rowSpacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let oneRow = oneRowWidth(subviews)
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? oneRow
        if oneRow <= width {
            return CGSize(width: width, height: subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0)
        }
        let row = ProposedViewSize(width: width, height: nil)
        let rows = subviews.map { $0.sizeThatFits(row) }
        return CGSize(width: max(width, rows[0].width, rows[1].width), height: rows[0].height + rowSpacing + rows[1].height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        if oneRowWidth(subviews) <= bounds.width {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
            subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: .unspecified)
        } else {
            let row = ProposedViewSize(width: bounds.width, height: nil)
            let actionsHeight = subviews[0].sizeThatFits(row).height
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading, proposal: row)
            subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.minY + actionsHeight + rowSpacing), anchor: .topTrailing, proposal: row)
        }
    }

    private func oneRowWidth(_ subviews: Subviews) -> CGFloat {
        subviews[0].sizeThatFits(.unspecified).width + 2 * spacing + subviews[1].sizeThatFits(.unspecified).width
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

/// The pieces the composer's suggestion menus (`@` mentions and `/` commands) are built from,
/// so both share one look: a floating panel, section headers, a list that keeps the
/// highlighted row in view, and rows where only the highlighted one draws a surface.
enum ComposerSuggestionMenu {
    static let width: CGFloat = 460
    static let inset: CGFloat = 8
    static let rowHeight: CGFloat = 32
    static let headerHeight: CGFloat = 30
    static let maxListHeight: CGFloat = 360

    /// The floating panel the menu sits in.
    struct Panel<Content: View>: View {
        let testID: String
        let label: String
        let value: String
        @ViewBuilder let content: Content

        var body: some View {
            AtomPanel(
                props: PanelProps(spacing: 0, fill: "panel", fillOpacity: 1, cornerRadius: 18, stroke: "primary", strokeOpacity: 0.1),
                common: AtomCommon(testID: testID, label: label, value: value, width: Double(width), padding: Double(inset))
            ) {
                content
            }
            .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
        }
    }

    /// A section's title, with an optional note at its end.
    struct Header: View {
        let text: String
        let testID: String
        var note: String? = nil
        var noteTestID: String? = nil

        var body: some View {
            AtomStack(props: StackProps(axis: "h", spacing: 6), common: AtomCommon(height: Double(headerHeight), fillWidth: true, paddingX: 12)) {
                AtomText(
                    props: TextProps(text: text, size: 12, weight: "medium", color: "secondary", lineLimit: 1, truncation: "tail"),
                    common: AtomCommon(testID: testID)
                )
                AtomSpacer(props: SpacerProps(minLength: 6))
                if let note {
                    AtomText(props: TextProps(text: note, size: 12, color: "tertiary", lineLimit: 1), common: AtomCommon(testID: noteTestID))
                }
            }
        }
    }

    /// The line shown instead of rows when there are none.
    struct Empty: View {
        let text: String
        let testID: String

        var body: some View {
            AtomText(props: TextProps(text: text, size: 13, color: "tertiary"), common: AtomCommon(testID: testID, fillWidth: true, paddingX: 12, paddingY: 8))
        }
    }

    /// The rows, scrolling past `maxListHeight` and following the highlighted row's id.
    struct List<ID: Hashable, Content: View>: View {
        /// The rows' and headers' natural height.
        let contentHeight: CGFloat
        let selectedID: ID?
        @ViewBuilder let content: Content

        var body: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) { content }
                        .hoverRevealScrollers()
                }
                .frame(height: min(contentHeight, maxListHeight))
                .onChange(of: selectedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    /// A row's surface: only the highlighted row draws one; a fill on every row read as a stack of cards.
    struct RowSurface<Content: View>: View {
        let selected: Bool
        var opacity: Double = 1
        @ViewBuilder let content: Content

        var body: some View {
            AtomStack(
                props: StackProps(axis: "h", spacing: 10, fill: selected ? "primary" : nil, fillOpacity: selected ? 0.09 : nil, cornerRadius: 9),
                common: AtomCommon(minHeight: Double(rowHeight), fillWidth: true, paddingX: 12, opacity: opacity)
            ) {
                content
            }
        }
    }

    /// A row's icon, title and detail.
    struct RowLabel: View {
        let icon: String
        let title: String
        let detail: String
        var detailColor = "secondary"

        var body: some View {
            AtomStack(props: StackProps(axis: "h", spacing: 10), common: AtomCommon(minHeight: Double(rowHeight), fillWidth: true)) {
                AtomIcon(props: IconProps(name: icon, size: 13, weight: "regular", color: "secondary"), common: AtomCommon(width: 18))
                AtomText(props: TextProps(text: title, size: 13, color: "primary", lineLimit: 1, truncation: "tail"))
                    .layoutPriority(1)
                if !detail.isEmpty {
                    AtomText(props: TextProps(text: detail, size: 13, color: detailColor, lineLimit: 1, truncation: "tail"))
                }
                AtomSpacer(props: SpacerProps(minLength: 0))
            }
        }
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

    private struct Section: Identifiable {
        let id: String
        let title: String
        /// The header's identifier: the menu's title for a single list, the kind's section otherwise.
        let testID: String
        /// Each row with its index in `items`, which is the keyboard order.
        let rows: [(index: Int, item: MentionItem)]
    }

    var body: some View {
        ComposerSuggestionMenu.Panel(testID: "mention-menu", label: "Mentions", value: title) {
            if items.isEmpty {
                ComposerSuggestionMenu.Header(text: title, testID: "mention-menu-title")
                ComposerSuggestionMenu.Empty(text: isLoading ? "Loading…" : "Nothing to mention matches “\(query)”", testID: "mention-menu-empty")
            } else {
                let sections = sections
                ComposerSuggestionMenu.List(
                    contentHeight: sections.reduce(0) { $0 + ComposerSuggestionMenu.headerHeight + CGFloat($1.rows.count) * ComposerSuggestionMenu.rowHeight },
                    selectedID: items.indices.contains(selectedIndex) ? items[selectedIndex].id : nil
                ) {
                    ForEach(sections) { section in
                        ComposerSuggestionMenu.Header(text: section.title, testID: section.testID)
                        ForEach(section.rows, id: \.item.id) { row in
                            self.row(row.item, selected: row.index == selectedIndex).id(row.item.id)
                        }
                    }
                }
            }
        }
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
            ComposerSuggestionMenu.RowSurface(selected: selected) {
                ComposerSuggestionMenu.RowLabel(icon: Self.icon(item.kind), title: item.title, detail: item.detail)
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

/// What the `/` menu's rows do: choosing a row (by its keyboard index) and pressing a
/// button at the end of a list item's row.
struct ComposerSlashActions {
    var choose: (Int) -> Void
    var press: (PluginCommandItem, PluginCommandButton) -> Void
}

/// The `/` command menu above the composer: the matching commands, or a command's own
/// list as its plugin returned it, the highlighted row first in keyboard order. A command
/// that can't run now is listed disabled with why. Rows are plugin atoms, as in the
/// mention menu; the host draws every plugin's list the same way.
struct ComposerSlashMenu: View {
    let menu: SlashCommandMenu
    /// The listed command's entry, for its icon.
    let command: SlashCommandEntry?
    let isLoading: Bool
    let selectedIndex: Int
    let actions: ComposerSlashActions

    private var items: [PluginCommandItem] { menu.list?.items ?? [] }
    private var rowCount: Int { menu.command == nil ? menu.commands.count : items.count }

    var body: some View {
        ComposerSuggestionMenu.Panel(testID: "slash-menu", label: "Commands", value: title) {
            ComposerSuggestionMenu.Header(
                text: title, testID: "slash-menu-title",
                note: menu.list?.pending, noteTestID: "slash-menu-checking"
            )
            if rowCount == 0 {
                ComposerSuggestionMenu.Empty(text: emptyText, testID: "slash-menu-empty")
            } else {
                ComposerSuggestionMenu.List(contentHeight: CGFloat(rowCount) * ComposerSuggestionMenu.rowHeight, selectedID: selectedIndex < rowCount ? selectedIndex : nil) {
                    if menu.command == nil {
                        ForEach(Array(menu.commands.enumerated()), id: \.element.id) { index, entry in
                            commandRow(entry, index: index).id(index)
                        }
                    } else {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            itemRow(item, index: index).id(index)
                        }
                    }
                }
            }
        }
    }

    private var title: String {
        guard menu.command != nil else { return menu.query.isEmpty ? "Commands" : "Commands matching “/\(menu.query)”" }
        return menu.list?.title ?? "/" + (menu.command ?? "")
    }

    private var emptyText: String {
        if isLoading { return "Loading…" }
        guard menu.command != nil else { return "No command matches “/\(menu.query)”" }
        return menu.filter.isEmpty ? (menu.list?.empty ?? "No items") : "\(menu.list?.noMatch ?? "No item matches") “\(menu.filter)”"
    }

    private func commandRow(_ entry: SlashCommandEntry, index: Int) -> some View {
        let selected = index == selectedIndex
        return AtomButton(
            props: ButtonProps(disabled: !entry.enabled, selected: selected),
            common: AtomCommon(
                testID: "slash-command-\(entry.name)", label: "/" + entry.name,
                value: entry.enabled ? entry.detail : entry.disabledReason, help: entry.disabledReason ?? entry.detail
            ),
            action: { actions.choose(index) }
        ) {
            ComposerSuggestionMenu.RowSurface(selected: selected, opacity: entry.enabled ? 1 : 0.6) {
                ComposerSuggestionMenu.RowLabel(
                    icon: entry.icon, title: "/" + entry.name, detail: entry.disabledReason ?? entry.detail,
                    detailColor: entry.enabled ? "secondary" : "tertiary"
                )
            }
        }
    }

    private func itemRow(_ item: PluginCommandItem, index: Int) -> some View {
        let selected = index == selectedIndex
        return ComposerSuggestionMenu.RowSurface(selected: selected) {
            AtomButton(
                props: ButtonProps(selected: selected),
                common: AtomCommon(testID: "slash-item-\(item.id)", label: item.title, value: item.detail, help: item.help ?? item.title),
                action: { actions.choose(index) }
            ) {
                ComposerSuggestionMenu.RowLabel(icon: item.icon ?? command?.icon ?? "command", title: item.title, detail: item.detail ?? "")
            }
            ForEach(item.buttons ?? []) { button in
                buttonView(button, item: item)
            }
        }
    }

    /// One of an item's buttons, `slash-<button>-<item>`: a small bordered button with
    /// its text, or a borderless icon.
    @ViewBuilder
    private func buttonView(_ button: PluginCommandButton, item: PluginCommandItem) -> some View {
        let testID = "slash-\(button.id)-\(item.id)"
        if button.style == "bordered" {
            AtomButton(
                props: ButtonProps(style: "bordered", disabled: button.disabled == true, controlSize: "small", destructive: button.destructive == true),
                common: AtomCommon(testID: testID, label: button.label, help: button.help ?? button.label),
                action: { actions.press(item, button) }
            ) {
                AtomLabel(props: LabelProps(text: button.text ?? button.label, icon: button.icon ?? "circle", size: 11, weight: "medium"))
            }
        } else {
            iconButton(
                button.icon ?? "ellipsis", testID: testID, label: button.label, help: button.help ?? button.label,
                destructive: button.destructive == true, disabled: button.disabled == true
            ) { actions.press(item, button) }
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
}
