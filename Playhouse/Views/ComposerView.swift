import Foundation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI

/// What the conversation composer's box shows, already derived from the
/// conversation's state: plain values the native composer and the catalog's
/// JavaScript copy (catalog/Composer.js, as `Playhouse.props.composer`)
/// compose the same way. Notices, attached images, queued follow-ups and the
/// goal row stay native, above the box.
package struct ComposerModel: Codable, Equatable {
    /// A menu entry; `id` is what the action receives, `testID` the identifier.
    package struct Item: Codable, Equatable {
        package var id: String
        package var title: String
        package var checked: Bool
        package var icon: String?
        package var help: String
        package var testID: String

        package init(id: String, title: String, checked: Bool, icon: String? = nil, help: String, testID: String) {
            self.id = id
            self.title = title
            self.checked = checked
            self.icon = icon
            self.help = help
            self.testID = testID
        }
    }

    package struct Option: Codable, Equatable {
        package var value: String
        package var label: String

        package init(value: String, label: String) {
            self.value = value
            self.label = label
        }
    }

    /// The Plan or Goal button. While `on` it shows an orange highlight; the two
    /// are never on together.
    package struct ModeToggle: Codable, Equatable {
        package var on: Bool
        package var help: String

        package init(on: Bool, help: String) {
            self.on = on
            self.help = help
        }
    }

    /// The attach button, which opens a file panel. It takes images for now.
    package struct Attach: Codable, Equatable {
        package var disabled: Bool
        package var help: String

        package init(disabled: Bool, help: String) {
            self.disabled = disabled
            self.help = help
        }
    }

    /// The Start Implementing button of a finished plan; `unavailableReason` also
    /// shows beside it as a button that opens the repository picker.
    package struct StartImplementing: Codable, Equatable {
        package var disabled: Bool
        package var help: String
        package var value: String
        package var unavailableReason: String?
        /// secondary or orange, as the repository title is.
        package var reasonColor: String
        package var reasonDisabled: Bool

        package init(disabled: Bool, help: String, value: String, unavailableReason: String? = nil, reasonColor: String, reasonDisabled: Bool) {
            self.disabled = disabled
            self.help = help
            self.value = value
            self.unavailableReason = unavailableReason
            self.reasonColor = reasonColor
            self.reasonDisabled = reasonDisabled
        }
    }

    /// The installed providers to switch between, then the missing ones to install (`installItems`,
    /// in their own section). With none installed the menu itself is the Install AI provider
    /// button: an accent `color`, and only install entries.
    package struct ProviderMenu: Codable, Equatable {
        package var title: String
        package var value: String
        package var label: String
        package var help: String
        package var enabled: Bool
        package var items: [Item]
        package var installItems: [Item]? = nil
        package var color: String? = nil

        package init(title: String, value: String, label: String, help: String, enabled: Bool, items: [Item], installItems: [Item]? = nil, color: String? = nil) {
            self.title = title
            self.value = value
            self.label = label
            self.help = help
            self.enabled = enabled
            self.items = items
            self.installItems = installItems
            self.color = color
        }
    }

    /// The model button and its popover: the models and the reasoning effort slider.
    package struct ModelPicker: Codable, Equatable {
        package var name: String
        package var effort: String
        package var label: String
        package var open: Bool
        package var models: [Item]
        package var effortChoices: [Option]
        package var selectedEffort: String

        package init(name: String, effort: String, label: String, open: Bool, models: [Item], effortChoices: [Option], selectedEffort: String) {
            self.name = name
            self.effort = effort
            self.label = label
            self.open = open
            self.models = models
            self.effortChoices = effortChoices
            self.selectedEffort = selectedEffort
        }
    }

    package struct Schedule: Codable, Equatable {
        package var on: Bool
        package var help: String
        package var open: Bool

        package init(on: Bool, help: String, open: Bool) {
            self.on = on
            self.help = help
            self.open = open
        }
    }

    /// The control after the pickers. `kind` is stop, continue, schedule or send.
    package struct Primary: Codable, Equatable {
        package var kind: String
        package var disabled: Bool
        package var help: String
        package var label: String
        package var value: String
        package var testID: String

        package init(kind: String, disabled: Bool, help: String, label: String, value: String, testID: String) {
            self.kind = kind
            self.disabled = disabled
            self.help = help
            self.label = label
            self.value = value
            self.testID = testID
        }
    }

    /// The standalone chat's Send in parallel button beside Send: the draft goes to a new page
    /// that runs alongside the chat. Nil everywhere else.
    package struct ParallelSend: Codable, Equatable {
        package var disabled: Bool
        package var help: String

        package init(disabled: Bool, help: String) {
            self.disabled = disabled
            self.help = help
        }
    }

    /// Starts every accessibility identifier ("" in the conversation, "native-"
    /// on the catalog's native side, so the two never share one).
    package var prefix: String
    package var draft: String
    package var placeholder: String
    package var enabled: Bool
    package var autofocus: Bool
    package var focused: Bool
    package var focusRequest: Int
    package var editorHelp: String
    /// The Skills button leads the toolbar only where the conversation has no
    /// task sidebar (a standalone chat); a task's sidebar holds it instead.
    package var skills: Bool
    package var attach: Attach
    package var plan: ModeToggle
    /// The Optimized context button beside Plan; nil where the conversation has no context
    /// mode (the standalone chat). Independent of Plan and Goal.
    package var optimizedContext: ModeToggle? = nil
    /// Nil where the provider has no goals.
    package var goal: ModeToggle?
    package var startImplementing: StartImplementing?
    package var provider: ProviderMenu
    /// Nil while no provider is installed: the Install AI provider button stands alone.
    package var model: ModelPicker?
    /// Nil where the conversation can't be scheduled.
    package var schedule: Schedule?
    package var parallelSend: ParallelSend? = nil
    package var primary: Primary

    package init(prefix: String, draft: String, placeholder: String, enabled: Bool, autofocus: Bool, focused: Bool, focusRequest: Int, editorHelp: String, skills: Bool, attach: Attach, plan: ModeToggle, optimizedContext: ModeToggle? = nil, goal: ModeToggle? = nil, startImplementing: StartImplementing? = nil, provider: ProviderMenu, model: ModelPicker? = nil, schedule: Schedule? = nil, parallelSend: ParallelSend? = nil, primary: Primary) {
        self.prefix = prefix
        self.draft = draft
        self.placeholder = placeholder
        self.enabled = enabled
        self.autofocus = autofocus
        self.focused = focused
        self.focusRequest = focusRequest
        self.editorHelp = editorHelp
        self.skills = skills
        self.attach = attach
        self.plan = plan
        self.optimizedContext = optimizedContext
        self.goal = goal
        self.startImplementing = startImplementing
        self.provider = provider
        self.model = model
        self.schedule = schedule
        self.parallelSend = parallelSend
        self.primary = primary
    }
}

/// What the composer's controls do. The native composer sets each; the
/// catalog's native copy leaves them as no-ops.
package struct ComposerActions {
    package var change: (String) -> Void = { _ in }
    package var submit: () -> Void = {}
    package var steer: () -> Void = {}
    package var focusChange: (Bool) -> Void = { _ in }
    package var pasteImage: (Data) -> Void = { _ in }
    /// The editor's selected range, in UTF-16 offsets.
    package var selectionChange: (NSRange) -> Void = { _ in }
    package var openSkills: () -> Void = {}
    package var attach: () -> Void = {}
    /// Turns Plan mode on (and Goal off) or off.
    package var togglePlan: () -> Void = {}
    /// Turns optimized context on or off.
    package var toggleOptimizedContext: () -> Void = {}
    /// Turns goal entry on (and Plan mode off) or off.
    package var toggleGoal: () -> Void = {}
    package var startImplementing: () -> Void = {}
    package var showRepositoryPicker: () -> Void = {}
    /// A provider's raw value.
    package var provider: (String) -> Void = { _ in }
    package var toggleModelPicker: () -> Void = {}
    package var dismissModelPicker: () -> Void = {}
    package var selectModel: (String) -> Void = { _ in }
    package var selectEffort: (String) -> Void = { _ in }
    package var toggleSchedule: () -> Void = {}
    package var dismissSchedule: () -> Void = {}
    package var sendInParallel: () -> Void = {}
    package var primary: () -> Void = {}

    package init(change: @escaping (String) -> Void = { _ in }, submit: @escaping () -> Void = {}, steer: @escaping () -> Void = {}, focusChange: @escaping (Bool) -> Void = { _ in }, pasteImage: @escaping (Data) -> Void = { _ in }, selectionChange: @escaping (NSRange) -> Void = { _ in }, openSkills: @escaping () -> Void = {}, attach: @escaping () -> Void = {}, togglePlan: @escaping () -> Void = {}, toggleOptimizedContext: @escaping () -> Void = {}, toggleGoal: @escaping () -> Void = {}, startImplementing: @escaping () -> Void = {}, showRepositoryPicker: @escaping () -> Void = {}, provider: @escaping (String) -> Void = { _ in }, toggleModelPicker: @escaping () -> Void = {}, dismissModelPicker: @escaping () -> Void = {}, selectModel: @escaping (String) -> Void = { _ in }, selectEffort: @escaping (String) -> Void = { _ in }, toggleSchedule: @escaping () -> Void = {}, dismissSchedule: @escaping () -> Void = {}, sendInParallel: @escaping () -> Void = {}, primary: @escaping () -> Void = {}) {
        self.change = change
        self.submit = submit
        self.steer = steer
        self.focusChange = focusChange
        self.pasteImage = pasteImage
        self.selectionChange = selectionChange
        self.openSkills = openSkills
        self.attach = attach
        self.togglePlan = togglePlan
        self.toggleOptimizedContext = toggleOptimizedContext
        self.toggleGoal = toggleGoal
        self.startImplementing = startImplementing
        self.showRepositoryPicker = showRepositoryPicker
        self.provider = provider
        self.toggleModelPicker = toggleModelPicker
        self.dismissModelPicker = dismissModelPicker
        self.selectModel = selectModel
        self.selectEffort = selectEffort
        self.toggleSchedule = toggleSchedule
        self.dismissSchedule = dismissSchedule
        self.sendInParallel = sendInParallel
        self.primary = primary
    }
}

/// The composer's box, composed only of plugin atoms: the editor, then the
/// attach button, the Skills button, the Plan and Goal buttons, Start Implementing, the provider menu, the
/// model button with its popover, the schedule button and the send, stop,
/// continue or schedule control. What sits above the editor (`header`) and
/// the schedule popover's content are native and handed in.
package struct ComposerView<Header: PHView, ScheduleContent: PHView>: PHView {
    package let model: ComposerModel
    package var actions = ComposerActions()
    @PHViewBuilder package var header: () -> Header
    @PHViewBuilder package var scheduleContent: () -> ScheduleContent
    /// Installed plugins' entries (and Add Plugin mode's placeholder) beside
    /// the Skills button; native, and absent from the catalog's copy.
    package var pluginActions: PHAnyView? = nil
    /// The editor's `@` mentions; native, and absent from the catalog's copy.
    package var mentions = ChatEditorMentions()
    /// The Skills, Plan mode and stop buttons' keyboard shortcuts; the catalog's copy takes none.
    package var keyboardShortcuts = false

    package var body: some PHView {
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
    private var toolbar: some PHView {
        ComposerToolbarLayout(spacing: 12) {
            AtomStack(props: StackProps(axis: "h", spacing: 12)) {
                attachButton
                if model.skills {
                    SkillsButton(testID: prefix + "open-skills-button", shortcut: shortcut(AppShortcut.skills), action: actions.openSkills)
                }
                if let pluginActions {
                    pluginActions
                }
                modeToggle(model.plan, testID: "conversation-plan-button", label: "Plan mode", shortcut: shortcut(AppShortcut.planMode), action: actions.togglePlan) { on in
                    AtomIcon(props: IconProps(name: PHIcon.lightbulbMax.name, size: 13, weight: "medium", color: Self.modeColor(on)))
                }
                if let optimized = model.optimizedContext {
                    modeToggle(optimized, testID: "conversation-optimized-context-button", label: "Optimized context", action: actions.toggleOptimizedContext) { on in
                        AtomIcon(props: IconProps(name: PHIcon.gaugeOpenWithLinesNeedle33percentAndArrowtriangleFrom0percentTo50percent.name, size: 14, weight: "medium", color: Self.modeColor(on)))
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
                if let picker = model.model {
                    modelPicker(picker)
                }
                if let schedule = model.schedule {
                    scheduleButton(schedule)
                }
                AtomStack(props: StackProps(axis: "h", spacing: 5)) {
                    primary
                    if let parallelSend = model.parallelSend {
                        parallelSendButton(parallelSend)
                    }
                }
            }
        }
    }

    private var attachButton: some PHView {
        AtomButton(
            props: ButtonProps(disabled: model.attach.disabled),
            common: AtomCommon(testID: prefix + "composer-attach-button", label: "Attach files", help: model.attach.help),
            action: actions.attach
        ) {
            AtomPanel(props: PanelProps(fillOpacity: 0, cornerRadius: 13), common: AtomCommon(width: 26, height: 26, padding: 0)) {
                AtomIcon(props: IconProps(name: PHIcon.paperclip.name, size: 13, weight: "medium", color: "secondary"))
            }
        }
    }

    /// A Plan or Goal button: its icon, on an orange highlight while the mode is on.
    private func modeToggle<Icon: PHView>(
        _ toggle: ComposerModel.ModeToggle, testID: String, label: String, shortcut: String? = nil, action: @escaping () -> Void, @PHViewBuilder icon: (Bool) -> Icon
    ) -> some PHView {
        let icon = icon(toggle.on)
        return AtomButton(
            props: ButtonProps(shortcut: shortcut),
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

    private func shortcut(_ spec: String) -> String? { keyboardShortcuts ? spec : nil }

    private func menuItem(_ item: ComposerModel.Item) -> MenuProps.Item {
        MenuProps.Item(id: item.id, title: item.title, help: item.help, testID: prefix + item.testID, checked: item.checked, icon: item.checked ? nil : item.icon)
    }

    @PHViewBuilder
    private func startImplementing(_ start: ComposerModel.StartImplementing) -> some PHView {
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
                AtomLabel(props: LabelProps(text: "No repository", icon: PHIcon.exclamationmarkTriangleFill.name, size: 11, weight: "semibold", color: start.reasonColor))
            }
        }
    }

    private var providerMenu: some PHView {
        let provider = model.provider
        return AtomMenu(
            props: MenuProps(
                color: provider.color ?? "secondary", text: provider.title, textSize: 12, textWeight: "medium",
                indicator: true, disabled: !provider.enabled,
                items: [provider.items.map(menuItem), (provider.installItems ?? []).map(menuItem)].filter { !$0.isEmpty }
            ),
            common: AtomCommon(testID: prefix + "conversation-provider-menu", label: provider.label, value: provider.value, help: provider.help),
            onMenu: actions.provider
        )
    }

    private func modelPicker(_ picker: ComposerModel.ModelPicker) -> some PHView {
        ComposerModelPicker(
            picker: picker, prefix: prefix,
            toggle: actions.toggleModelPicker, dismiss: actions.dismissModelPicker,
            selectModel: actions.selectModel, selectEffort: actions.selectEffort
        )
    }

    private func scheduleButton(_ schedule: ComposerModel.Schedule) -> some PHView {
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
                        AtomIcon(props: IconProps(name: schedule.on ? PHIcon.clockFill.name : "clock", size: 12, weight: "medium", color: schedule.on ? "accent" : "secondary"))
                    }
                }
            },
            content: scheduleContent
        )
    }

    @PHViewBuilder
    private var primary: some PHView {
        let primary = model.primary
        AtomButton(
            props: ButtonProps(disabled: primary.disabled, shortcut: primary.kind == "stop" ? shortcut(AppShortcut.stopResponse) : nil),
            common: AtomCommon(testID: prefix + primary.testID, label: primary.label, value: primary.value.isEmpty ? nil : primary.value, help: primary.help),
            action: actions.primary
        ) {
            switch primary.kind {
            case "stop":
                primaryIcon(PHIcon.stopFill.name, fill: "primary", opacity: 0.72, size: 11, radius: 9)
            case "continue":
                primaryIcon(PHIcon.playFill.name, fill: "accent", opacity: 1, size: 11, radius: 9)
            case "schedule":
                AtomPanel(
                    props: PanelProps(fill: "accent", fillOpacity: 1, cornerRadius: 15.5),
                    common: AtomCommon(height: 31, padding: 0, paddingX: 12, opacity: primary.disabled ? 0.45 : 1)
                ) {
                    AtomLabel(props: LabelProps(text: "Schedule", icon: PHIcon.clock.name, size: 12, weight: "semibold", color: "white"))
                }
            default:
                primaryIcon(PHIcon.arrowUp.name, fill: "accent", opacity: 1, size: 13, radius: 15.5, dimmed: primary.disabled)
            }
        }
    }

    private func parallelSendButton(_ parallelSend: ComposerModel.ParallelSend) -> some PHView {
        AtomButton(
            props: ButtonProps(disabled: parallelSend.disabled),
            common: AtomCommon(testID: prefix + "composer-send-in-parallel-button", label: "Send in parallel", help: parallelSend.help),
            action: actions.sendInParallel
        ) {
            AtomPanel(
                props: PanelProps(fill: "accent", fillOpacity: 0.14, cornerRadius: 13),
                common: AtomCommon(width: 26, height: 26, padding: 0, opacity: parallelSend.disabled ? 0.45 : 1)
            ) {
                AtomIcon(props: IconProps(asset: "ParallelSendIcon", color: "accent"), common: AtomCommon(width: 15, height: 15))
            }
        }
    }

    private func primaryIcon(_ name: String, fill: String, opacity: Double, size: Double, radius: Double, dimmed: Bool = false) -> some PHView {
        AtomPanel(
            props: PanelProps(fill: fill, fillOpacity: opacity, cornerRadius: radius),
            common: AtomCommon(width: 31, height: 31, padding: 0, opacity: dimmed ? 0.45 : 1)
        ) {
            AtomIcon(props: IconProps(name: name, size: size, weight: "bold", color: "white"))
        }
    }

    package init(model: ComposerModel, actions: ComposerActions = ComposerActions(), @PHViewBuilder header: @escaping () -> Header, @PHViewBuilder scheduleContent: @escaping () -> ScheduleContent, pluginActions: PHAnyView? = nil, mentions: ChatEditorMentions = ChatEditorMentions(), keyboardShortcuts: Bool = false) {
        self.model = model
        self.actions = actions
        self.header = header
        self.scheduleContent = scheduleContent
        self.pluginActions = pluginActions
        self.mentions = mentions
        self.keyboardShortcuts = keyboardShortcuts
    }
}

/// The composer's toolbar: its actions at the leading edge and its controls at the trailing edge,
/// with at least the gap a spacer between two spaced items keeps. They share one row only while
/// both fit at their natural widths; squeezing them into one row instead wrapped the model
/// button's name a few letters to a line and still made the box wider than a narrow chat.
private struct ComposerToolbarLayout: PHLayout {
    var spacing: CGFloat
    var rowSpacing: CGFloat = 10

    func sizeThatFits(proposal: PHProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let oneRow = oneRowWidth(subviews)
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? oneRow
        if oneRow <= width {
            return CGSize(width: width, height: subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0)
        }
        let row = PHProposedViewSize(width: width, height: nil)
        let rows = subviews.map { $0.sizeThatFits(row) }
        return CGSize(width: max(width, rows[0].width, rows[1].width), height: rows[0].height + rowSpacing + rows[1].height)
    }

    func placeSubviews(in bounds: CGRect, proposal: PHProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        if oneRowWidth(subviews) <= bounds.width {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
            subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: .unspecified)
        } else {
            let row = PHProposedViewSize(width: bounds.width, height: nil)
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
package struct ComposerModelPicker: PHView {
    package let picker: ComposerModel.ModelPicker
    package var prefix = ""
    package let toggle: () -> Void
    package let dismiss: () -> Void
    package let selectModel: (String) -> Void
    package let selectEffort: (String) -> Void

    package var body: some PHView {
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
                        AtomIcon(props: IconProps(name: PHIcon.chevronDown.name, size: 9, weight: "semibold", color: "tertiary"))
                    }
                }
            },
            content: {
                AtomStack(props: StackProps(axis: "v", spacing: 0, align: "leading"), common: AtomCommon(padding: 13, paddingX: 5)) {
                    PHForEach(picker.models, id: \.id) { option in
                        AtomButton(
                            common: AtomCommon(testID: prefix + option.testID, value: option.checked ? "Selected" : "Not selected", help: option.help),
                            action: { selectModel(option.id) }
                        ) {
                            AtomStack(props: StackProps(axis: "h"), common: AtomCommon(minHeight: 32, fillWidth: true)) {
                                AtomText(props: TextProps(text: option.title))
                                AtomSpacer(props: SpacerProps())
                                if option.checked {
                                    AtomIcon(props: IconProps(name: PHIcon.checkmark.name, size: 12, weight: "semibold"), common: AtomCommon(testID: prefix + option.testID + "-checked"))
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

    package init(picker: ComposerModel.ModelPicker, prefix: String = "", toggle: @escaping () -> Void, dismiss: @escaping () -> Void, selectModel: @escaping (String) -> Void, selectEffort: @escaping (String) -> Void) {
        self.picker = picker
        self.prefix = prefix
        self.toggle = toggle
        self.dismiss = dismiss
        self.selectModel = selectModel
        self.selectEffort = selectEffort
    }
}

extension ComposerView where Header == PHEmptyView, ScheduleContent == PHEmptyView {
    package init(model: ComposerModel, actions: ComposerActions = ComposerActions()) {
        self.init(model: model, actions: actions, header: { PHEmptyView() }, scheduleContent: { PHEmptyView() })
    }
}

/// The pieces the composer's suggestion menus (`@` mentions and `/` commands) are built from,
/// so both share one look: a floating panel, section headers, a list that keeps the
/// highlighted row in view, and rows where only the highlighted one draws a surface.
package enum ComposerSuggestionMenu {
    package static let width: CGFloat = 460
    package static let inset: CGFloat = 8
    package static let rowHeight: CGFloat = 32
    package static let headerHeight: CGFloat = 30
    package static let maxListHeight: CGFloat = 360

    /// The floating panel the menu sits in.
    package struct Panel<Content: PHView>: PHView {
        package let testID: String
        package let label: String
        package let value: String
        @PHViewBuilder package let content: Content

        package var body: some PHView {
            // A Panel (a grouped leading column with a surface) that also casts a shadow.
            AtomStack(
                props: StackProps(
                    axis: "v", spacing: 0, align: "leading", group: true, fill: "panel", fillOpacity: 1, cornerRadius: 18,
                    stroke: "primary", strokeOpacity: 0.1, shadow: 16, shadowOpacity: 0.22, shadowY: 6
                ),
                common: AtomCommon(testID: testID, label: label, value: value, width: Double(width), padding: Double(inset)),
                atom: .panel
            ) {
                content
            }
        }

        package init(testID: String, label: String, value: String, @PHViewBuilder content: () -> Content) {
            self.testID = testID
            self.label = label
            self.value = value
            self.content = content()
        }
    }

    /// A section's title, with an optional note at its end.
    package struct Header: PHView {
        package let text: String
        package let testID: String
        package var note: String? = nil
        package var noteTestID: String? = nil

        package var body: some PHView {
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

        package init(text: String, testID: String, note: String? = nil, noteTestID: String? = nil) {
            self.text = text
            self.testID = testID
            self.note = note
            self.noteTestID = noteTestID
        }
    }

    /// The line shown instead of rows when there are none.
    package struct Empty: PHView {
        package let text: String
        package let testID: String

        package var body: some PHView {
            AtomText(props: TextProps(text: text, size: 13, color: "tertiary"), common: AtomCommon(testID: testID, fillWidth: true, paddingX: 12, paddingY: 8))
        }

        package init(text: String, testID: String) {
            self.text = text
            self.testID = testID
        }
    }

    /// The rows, scrolling past `maxListHeight` and following the highlighted row's id.
    package struct List<ID: Hashable, Content: PHView>: PHView {
        /// The rows' and headers' natural height.
        package let contentHeight: CGFloat
        package let selectedID: ID?
        @PHViewBuilder package let content: Content

        package var body: some PHView {
            PHScrollViewReader { proxy in
                AtomStack(common: AtomCommon(height: Double(min(contentHeight, maxListHeight)))) {
                    AtomScroll(props: ScrollProps(directContent: true)) {
                        AtomStack(props: StackProps(spacing: 0, align: "leading")) { content }
                            .hoverRevealScrollers()
                    }
                }
                .onChange(of: selectedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }

        package init(contentHeight: CGFloat, selectedID: ID?, @PHViewBuilder content: () -> Content) {
            self.contentHeight = contentHeight
            self.selectedID = selectedID
            self.content = content()
        }
    }

    /// A row's surface: only the highlighted row draws one; a fill on every row read as a stack of cards.
    package struct RowSurface<Content: PHView>: PHView {
        package let selected: Bool
        package var opacity: Double = 1
        @PHViewBuilder package let content: Content

        package var body: some PHView {
            AtomStack(
                props: StackProps(axis: "h", spacing: 10, fill: selected ? "primary" : nil, fillOpacity: selected ? 0.09 : nil, cornerRadius: 9),
                common: AtomCommon(minHeight: Double(rowHeight), fillWidth: true, paddingX: 12, opacity: opacity)
            ) {
                content
            }
        }

        package init(selected: Bool, opacity: Double = 1, @PHViewBuilder content: () -> Content) {
            self.selected = selected
            self.opacity = opacity
            self.content = content()
        }
    }

    /// A row's icon, title and detail.
    package struct RowLabel: PHView {
        package let icon: String
        package let title: String
        package let detail: String
        package var detailColor = "secondary"

        package var body: some PHView {
            AtomStack(props: StackProps(axis: "h", spacing: 10), common: AtomCommon(minHeight: Double(rowHeight), fillWidth: true)) {
                AtomIcon(props: IconProps(name: icon, size: 13, weight: "regular", color: "secondary"), common: AtomCommon(width: 18))
                AtomText(props: TextProps(text: title, size: 13, color: "primary", lineLimit: 1, truncation: "tail"), common: AtomCommon(layoutPriority: 1))
                if !detail.isEmpty {
                    AtomText(props: TextProps(text: detail, size: 13, color: detailColor, lineLimit: 1, truncation: "tail"))
                }
                AtomSpacer(props: SpacerProps(minLength: 0))
            }
        }

        package init(icon: String, title: String, detail: String, detailColor: String = "secondary") {
            self.icon = icon
            self.title = title
            self.detail = detail
            self.detailColor = detailColor
        }
    }
}

/// The `@` mention menu above the composer: the suggestions for what follows the `@`, the
/// highlighted one first in keyboard order. Browsing everything groups the rows under a header
/// per kind; recent mentions and a query's matches are one list under one header. Rows and
/// headers are plugin atoms; the list is a native scroll view so the highlighted row stays in
/// view as the arrow keys move it. It holds at most 80 rows, so it builds them all.
package struct ComposerMentionMenu: PHView {
    package let query: String
    package let items: [MentionItem]
    /// Whether `items` are the recent mentions an empty query shows.
    package let showsRecent: Bool
    package let isLoading: Bool
    package let selectedIndex: Int
    package let select: (MentionItem) -> Void

    private struct Section: Identifiable {
        let id: String
        let title: String
        /// The header's identifier: the menu's title for a single list, the kind's section otherwise.
        let testID: String
        /// Each row with its index in `items`, which is the keyboard order.
        let rows: [(index: Int, item: MentionItem)]
    }

    package var body: some PHView {
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
                    PHForEach(sections) { section in
                        ComposerSuggestionMenu.Header(text: section.title, testID: section.testID)
                        PHForEach(section.rows, id: \.item.id) { row in
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

    private func row(_ item: MentionItem, selected: Bool) -> some PHView {
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

    package static func icon(_ kind: MentionKind) -> String {
        switch kind {
        case .skill: PHIcon.sparkles.name
        case .mcp: PHIcon.serverRack.name
        case .agent: PHIcon.personCropCircle.name
        case .repository: PHIcon.folder.name
        case .task: PHIcon.checklist.name
        }
    }

    package init(query: String, items: [MentionItem], showsRecent: Bool, isLoading: Bool, selectedIndex: Int, select: @escaping (MentionItem) -> Void) {
        self.query = query
        self.items = items
        self.showsRecent = showsRecent
        self.isLoading = isLoading
        self.selectedIndex = selectedIndex
        self.select = select
    }
}

/// What the `/` menu's rows do: choosing a row (by its keyboard index) and pressing a
/// button at the end of a list item's row.
package struct ComposerSlashActions {
    package var choose: (Int) -> Void
    package var press: (PluginCommandItem, PluginCommandButton) -> Void

    package init(choose: @escaping (Int) -> Void, press: @escaping (PluginCommandItem, PluginCommandButton) -> Void) {
        self.choose = choose
        self.press = press
    }
}

/// The `/` command menu above the composer: the matching commands, or a command's own
/// list as its plugin returned it, the highlighted row first in keyboard order. A command
/// that can't run now is listed disabled with why. Rows are plugin atoms, as in the
/// mention menu; the host draws every plugin's list the same way.
package struct ComposerSlashMenu: PHView {
    package let menu: SlashCommandMenu
    /// The listed command's entry, for its icon.
    package let command: SlashCommandEntry?
    package let isLoading: Bool
    package let selectedIndex: Int
    package let actions: ComposerSlashActions

    private var items: [PluginCommandItem] { menu.list?.items ?? [] }
    private var rowCount: Int { menu.command == nil ? menu.commands.count : items.count }

    package var body: some PHView {
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
                        PHForEach(Array(menu.commands.enumerated()), id: \.element.id) { index, entry in
                            commandRow(entry, index: index).id(index)
                        }
                    } else {
                        PHForEach(Array(items.enumerated()), id: \.element.id) { index, item in
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

    private func commandRow(_ entry: SlashCommandEntry, index: Int) -> some PHView {
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

    private func itemRow(_ item: PluginCommandItem, index: Int) -> some PHView {
        let selected = index == selectedIndex
        return ComposerSuggestionMenu.RowSurface(selected: selected) {
            AtomButton(
                props: ButtonProps(selected: selected),
                common: AtomCommon(testID: "slash-item-\(item.id)", label: item.title, value: item.detail, help: item.help ?? item.title),
                action: { actions.choose(index) }
            ) {
                ComposerSuggestionMenu.RowLabel(icon: item.icon ?? command?.icon ?? PHIcon.command.name, title: item.title, detail: item.detail ?? "")
            }
            PHForEach(item.buttons ?? []) { button in
                buttonView(button, item: item)
            }
        }
    }

    /// One of an item's buttons, `slash-<button>-<item>`: a small bordered button with
    /// its text, or a borderless icon.
    @PHViewBuilder
    private func buttonView(_ button: PluginCommandButton, item: PluginCommandItem) -> some PHView {
        let testID = "slash-\(button.id)-\(item.id)"
        if button.style == "bordered" {
            AtomButton(
                props: ButtonProps(style: "bordered", disabled: button.disabled == true, controlSize: "small", destructive: button.destructive == true),
                common: AtomCommon(testID: testID, label: button.label, help: button.help ?? button.label),
                action: { actions.press(item, button) }
            ) {
                AtomLabel(props: LabelProps(text: button.text ?? button.label, icon: button.icon ?? PHIcon.circle.name, size: 11, weight: "medium"))
            }
        } else {
            iconButton(
                button.icon ?? "ellipsis", testID: testID, label: button.label, help: button.help ?? button.label,
                destructive: button.destructive == true, disabled: button.disabled == true
            ) { actions.press(item, button) }
        }
    }

    private func iconButton(_ icon: String, testID: String, label: String, help: String, destructive: Bool = false, disabled: Bool = false, action: @escaping () -> Void) -> some PHView {
        AtomButton(
            props: ButtonProps(style: "borderless", emphasis: 4, disabled: disabled, destructive: destructive),
            common: AtomCommon(testID: testID, label: label, help: help, width: 26, height: 26),
            action: action
        ) {
            AtomIcon(props: IconProps(name: icon, size: 12, weight: "medium", color: destructive ? "red" : "secondary"))
        }
    }

    package init(menu: SlashCommandMenu, command: SlashCommandEntry?, isLoading: Bool, selectedIndex: Int, actions: ComposerSlashActions) {
        self.menu = menu
        self.command = command
        self.isLoading = isLoading
        self.selectedIndex = selectedIndex
        self.actions = actions
    }
}
