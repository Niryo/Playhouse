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

    var body: some View {
        AtomPanel(
            props: PanelProps(spacing: 10, fill: "panel", fillOpacity: 1, cornerRadius: 21, stroke: "primary", strokeOpacity: 0.1),
            common: AtomCommon(padding: 13)
        ) {
            header()
            AtomEditor(
                props: EditorProps(
                    text: model.draft, placeholder: model.placeholder, placeholderTestID: prefix + "composer-placeholder",
                    enabled: model.enabled, autofocus: model.autofocus, focused: model.focused, focusRequest: model.focusRequest
                ),
                common: AtomCommon(testID: prefix + "message-composer-scroll-view", hint: model.editorHelp),
                onChange: actions.change, onSubmit: actions.submit, onSteerSubmit: actions.steer,
                onFocusChange: actions.focusChange, onPasteImage: actions.pasteImage
            )
            toolbar
        }
    }

    private var toolbar: some View {
        AtomStack(props: StackProps(axis: "h", spacing: 12)) {
            SkillsButton(testID: prefix + "open-skills-button", action: actions.openSkills)
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
            AtomPanel(props: PanelProps(fill: "accent", fillOpacity: 1, cornerRadius: 15.5), common: AtomCommon(height: 31, paddingX: 11)) {
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
        let picker = model.model
        return AtomPopover(
            props: PopoverProps(isPresented: picker.open, arrowEdge: "top", width: 320),
            common: AtomCommon(testID: prefix + "model-picker-popover"),
            onDismiss: actions.dismissModelPicker,
            anchor: {
                AtomButton(
                    common: AtomCommon(
                        testID: prefix + "model-picker-menu", label: picker.label, value: picker.name,
                        help: "Choose a model and reasoning effort", opacity: 0.82
                    ),
                    action: actions.toggleModelPicker
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
                            common: AtomCommon(testID: prefix + option.testID, help: option.help),
                            action: { actions.selectModel(option.id) }
                        ) {
                            AtomStack(props: StackProps(axis: "h"), common: AtomCommon(minHeight: 32, fillWidth: true)) {
                                AtomText(props: TextProps(text: option.title))
                                AtomSpacer(props: SpacerProps())
                                if option.checked {
                                    AtomIcon(props: IconProps(name: "checkmark", size: 12, weight: "semibold"))
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
                        onChange: actions.selectEffort
                    )
                }
            }
        )
    }

    private static func title(of value: String, in options: [ComposerModel.Option]) -> String {
        options.first { $0.value == value }?.label ?? value
    }

    private func scheduleButton(_ schedule: ComposerModel.Schedule) -> some View {
        AtomPopover(
            props: PopoverProps(isPresented: schedule.open, arrowEdge: "top"),
            common: AtomCommon(testID: prefix + "schedule-popover"),
            onDismiss: actions.dismissSchedule,
            anchor: {
                AtomButton(
                    common: AtomCommon(testID: prefix + "schedule-task-button", label: "Schedule", value: schedule.on ? "On" : "Off", help: schedule.help),
                    action: actions.toggleSchedule
                ) {
                    AtomPanel(
                        props: PanelProps(fill: "accent", fillOpacity: schedule.on ? 0.14 : 0, cornerRadius: 13),
                        common: AtomCommon(width: 26, height: 26)
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
                    common: AtomCommon(height: 31, paddingX: 12, opacity: primary.disabled ? 0.45 : 1)
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
            common: AtomCommon(width: 31, height: 31, opacity: dimmed ? 0.45 : 1)
        ) {
            AtomIcon(props: IconProps(name: name, size: size, weight: "bold", color: "white"))
        }
    }
}

extension ComposerView where Header == EmptyView, ScheduleContent == EmptyView {
    init(model: ComposerModel, actions: ComposerActions = ComposerActions()) {
        self.init(model: model, actions: actions, header: { EmptyView() }, scheduleContent: { EmptyView() })
    }
}
