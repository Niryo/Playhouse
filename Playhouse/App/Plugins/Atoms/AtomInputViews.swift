import SwiftUI

/// value, and the owner moves `selected`.
struct AtomChoiceBar: View {
    var props: ChoiceBarProps
    var common = AtomCommon()
    let onChange: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(props.options, id: \.value) { option in
                let isSelected = option.value == props.selected
                Button {
                    if !isSelected { onChange(option.value) }
                } label: {
                    Text(verbatim: option.label)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .buttonHoverPointer()
                .nativeHelp(option.label)
                .modifier(Applied(when: option.testID != nil) { $0.accessibilityIdentifier(option.testID ?? "") })
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
        .atomCommon(common, atom: .choiceBar, group: true)
    }
}

/// A switch with no visible label. A click asks the owner to flip `isOn`
/// (`onToggle`); it shows whatever `isOn` it is given.
struct AtomToggle: View {
    var props: ToggleProps
    var common = AtomCommon()
    let onToggle: () -> Void

    var body: some View {
        Toggle(common.label ?? "", isOn: Binding(get: { props.isOn }, set: { if $0 != props.isOn { onToggle() } }))
            .toggleStyle(.switch)
            .controlSize(controlSize)
            .labelsHidden()
            .disabled(props.disabled == true)
            .buttonHoverPointer() // no-tooltip: the atom's help prop sets it, through atomCommon.
            .atomCommon(common, atom: .toggle)
    }

    private var controlSize: ControlSize {
        switch props.size {
        case "mini": .mini
        case "small": .small
        default: .regular
        }
    }
}

/// A rounded one-line text field. It edits its own copy of `text` so typing
/// never waits on the owner, reports each edit through `onChange`, and takes
/// the owner's `text` whenever that changes. Only real edits reach the owner:
/// ending editing as the field goes away (a popover closing) sets the same
/// text again, which must not undo a reset the owner just made. Return goes to `onSubmit` and
/// the Up and Down arrows to `onArrow` only when they are given; otherwise
/// the field handles those keys as usual.
struct AtomTextField: View {
    var props: TextFieldProps
    var common = AtomCommon()
    let onChange: (String) -> Void
    var onSubmit: (() -> Void)?
    var onArrow: ((String) -> Void)?
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(
        props: TextFieldProps, common: AtomCommon = AtomCommon(), onChange: @escaping (String) -> Void,
        onSubmit: (() -> Void)? = nil, onArrow: ((String) -> Void)? = nil
    ) {
        self.props = props
        self.common = common
        self.onChange = onChange
        self.onSubmit = onSubmit
        self.onArrow = onArrow
        _text = State(initialValue: props.text)
    }

    var body: some View {
        styledField
            .focused($isFocused)
            .defaultFocus($isFocused, props.autoFocus == true)
            .onKeyPress { press in
                switch press.key {
                case .downArrow, .upArrow:
                    guard let onArrow else { return .ignored }
                    onArrow(press.key == .downArrow ? "down" : "up")
                    return .handled
                case .return:
                    guard let onSubmit else { return .ignored }
                    onSubmit()
                    return .handled
                default:
                    return .ignored
                }
            }
            .onChange(of: props.text) { _, owned in
                if owned != text { text = owned }
            }
            .atomCommon(common, atom: .textField)
    }

    @ViewBuilder
    private var styledField: some View {
        let field = TextField(props.placeholder ?? "", text: Binding(get: { text }, set: { edited in
            guard edited != text else { return }
            text = edited
            onChange(edited)
        }))
        if props.style == "plain" {
            field.textFieldStyle(.plain)
        } else {
            field.textFieldStyle(.roundedBorder)
        }
    }
}

/// A segmented control showing `selected`; choosing a segment calls
/// `onChange` with its value. Without a `width` it fits its segments.
struct AtomSegmented: View {
    var props: SegmentedProps
    var common = AtomCommon()
    let onChange: (String) -> Void

    var body: some View {
        Picker(common.label ?? "", selection: Binding(get: { props.selected }, set: { if $0 != props.selected { onChange($0) } })) {
            ForEach(props.options, id: \.value) { option in
                Text(verbatim: option.label).tag(option.value)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .modifier(Applied(when: common.width == nil) { $0.fixedSize() })
        .disabled(props.disabled == true)
        .atomCommon(common, atom: .segmented)
    }
}

/// A borderless pull-down menu labelled by an SF Symbol, text or both. The
/// common width and height frame the label, so they are the click target; a
/// separator sits between the item groups, and a checked item is marked.
struct AtomMenu: View {
    var props: MenuProps
    var common = AtomCommon()
    let onMenu: (String) -> Void

    var body: some View {
        var label = common
        label.testID = nil
        label.label = nil
        label.help = nil
        let groups = props.items.filter { !$0.isEmpty }
        return Menu {
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider() }
                ForEach(group, id: \.id) { item in
                    Button(role: item.destructive == true ? .destructive : nil) { onMenu(item.id) } label: {
                        if item.checked == true {
                            Label(item.title, systemImage: "checkmark")
                        } else if let icon = item.icon {
                            Label(item.title, systemImage: icon)
                        } else {
                            Text(verbatim: item.title)
                        }
                    }
                    .disabled(item.disabled == true)
                    .buttonHoverPointer()
                    .help(item.help ?? item.title)
                    .modifier(Applied(when: item.testID != nil) { $0.accessibilityIdentifier(item.testID ?? "") })
                }
            }
        } label: {
            HStack(spacing: 5) {
                if let icon = props.icon {
                    Image(systemName: icon)
                        .atomFont(AtomFont.font(size: props.size, weight: props.weight))
                }
                if let badge = props.badgeIcon {
                    Image(systemName: badge)
                        .atomFont(AtomFont.font(size: props.textSize, weight: props.textWeight))
                }
                if let text = props.text {
                    Text(verbatim: text)
                        .atomFont(AtomFont.font(size: props.textSize, weight: props.textWeight))
                }
            }
            .foregroundStyle(AtomColor.style(props.color) ?? AnyShapeStyle(.secondary))
            .atomFrame(label)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .modifier(Applied(when: props.indicator != true) { $0.menuIndicator(.hidden) })
        .fixedSize()
        .disabled(props.disabled == true)
        .buttonHoverPointer() // no-tooltip: the atom's help prop sets it, through atomCommon.
        .atomCommon(common, atom: .menu, frame: false)
    }
}

/// The composer's message editor: AppKit's text view, which owns wrapping and
/// grows with its text up to a bounded height, under a placeholder. Focus is
/// the owner's: `props.focused` is what the editor shows, and the editor
/// reports its own changes through `onFocusChange`. An owner that doesn't
/// track focus always sees its `text` applied, as the conversation's draft is.
struct AtomEditor: View {
    var props: EditorProps
    var common = AtomCommon()
    let onChange: (String) -> Void
    var onSubmit: () -> Void = {}
    var onSteerSubmit: () -> Void = {}
    var onFocusChange: (Bool) -> Void = { _ in }
    /// A pasted image reaches only native owners.
    var onPasteImage: (Data) -> Void = { _ in }
    /// Escape reaches only native owners, and only those that set it.
    var onCancel: (() -> Void)? = nil
    /// The selection reaches only native owners, such as the composer's plugins.
    var onSelectionChange: (NSRange) -> Void = { _ in }
    /// The composer's `@` mentions reach only native owners.
    var mentions = ChatEditorMentions()
    @State private var text: String
    @State private var height: CGFloat = 28

    init(
        props: EditorProps, common: AtomCommon = AtomCommon(), onChange: @escaping (String) -> Void,
        onSubmit: @escaping () -> Void = {}, onSteerSubmit: @escaping () -> Void = {},
        onFocusChange: @escaping (Bool) -> Void = { _ in }, onPasteImage: @escaping (Data) -> Void = { _ in },
        onCancel: (() -> Void)? = nil,
        onSelectionChange: @escaping (NSRange) -> Void = { _ in },
        mentions: ChatEditorMentions = ChatEditorMentions()
    ) {
        self.props = props
        self.mentions = mentions
        self.onCancel = onCancel
        self.common = common
        self.onChange = onChange
        self.onSubmit = onSubmit
        self.onSteerSubmit = onSteerSubmit
        self.onFocusChange = onFocusChange
        self.onPasteImage = onPasteImage
        self.onSelectionChange = onSelectionChange
        _text = State(initialValue: props.text)
    }

    var body: some View {
        NativeChatEditor(
            text: Binding(get: { text }, set: { text = $0; onChange($0) }),
            height: $height,
            isFocused: Binding(get: { props.focused ?? false }, set: { if $0 != (props.focused ?? false) { onFocusChange($0) } }),
            focusRequest: props.focusRequest ?? 0,
            isEnabled: props.enabled != false,
            autofocusOnAppear: props.autofocus == true,
            accessibilityHelp: common.hint ?? "",
            inputTestID: props.inputTestID,
            inputLabel: props.inputLabel,
            onSubmit: onSubmit,
            onSteerSubmit: onSteerSubmit,
            onPasteImage: onPasteImage,
            onCancel: onCancel,
            onSelectionChange: onSelectionChange,
            mentions: mentions
        )
        .frame(height: height)
        .overlay(alignment: .topLeading) {
            if props.text.isEmpty, let placeholder = props.placeholder {
                Text(verbatim: placeholder)
                    .font(.system(size: 15))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.top, 4)
                    .allowsHitTesting(false)
                    .modifier(Applied(when: props.placeholderTestID != nil) { $0.accessibilityIdentifier(props.placeholderTestID ?? "") })
            }
        }
        .onChange(of: props.text) { _, owned in
            if owned != text { text = owned }
        }
        .disabled(props.enabled == false)
        .atomCommon(common.withoutHint, atom: .editor)
    }
}

extension AtomCommon {
    /// The editor takes the hint as its text view's accessibility help, so the
    /// container must not repeat it.
    var withoutHint: AtomCommon {
        var copy = self
        copy.hint = nil
        return copy
    }
}

/// A popover over its anchor, open while `props.isPresented`. Native owners
/// give any SwiftUI content; a plugin's is every child after the anchor.
struct AtomPopover<Anchor: View, Content: View>: View {
    var props: PopoverProps
    var common = AtomCommon()
    let onDismiss: () -> Void
    @ViewBuilder var anchor: () -> Anchor
    @ViewBuilder var content: () -> Content

    var body: some View {
        anchor()
            .popover(isPresented: Binding(get: { props.isPresented }, set: { if !$0 && props.isPresented { onDismiss() } }), arrowEdge: edge) {
                content()
                    .padding(CGFloat(props.inset ?? PopoverProps.defaultInset))
                    .modifier(Applied(when: props.width != nil) { $0.frame(width: props.width.map { CGFloat($0) }) })
            }
            .atomCommon(layoutOnly, atom: .popover)
    }

    /// The anchor and the content keep their own accessibility, so the popover's
    /// `testID` only names it to a plugin's events.
    private var layoutOnly: AtomCommon {
        var copy = common
        copy.testID = nil
        copy.label = nil
        copy.value = nil
        copy.hint = nil
        return copy
    }

    private var edge: Edge {
        switch props.arrowEdge {
        case "bottom": .bottom
        case "leading": .leading
        case "trailing": .trailing
        default: .top
        }
    }
}

/// A discrete slider: an opaque-knob track drawn over an undrawn native slider
/// that takes the pointer and keyboard; SwiftUI represents it to accessibility.
struct AtomStepSlider: View {
    var props: StepSliderProps
    var common = AtomCommon()
    let onChange: (String) -> Void

    private var values: [String] { props.options.map(\.value) }
    private var selection: Binding<String> {
        Binding(get: { props.selected }, set: { if $0 != props.selected { onChange($0) } })
    }
    private var selectedLabel: String { props.options.first { $0.value == props.selected }?.label ?? props.selected }

    var body: some View {
        Group {
            if values.count > 1 {
                EffortStepSlider(selection: selection, choices: values)
                    .overlay { EffortAccessibilitySlider(selection: selection, choices: values) }
                    .accessibilityRepresentation {
                        Slider(value: Binding(
                            get: { Double(values.firstIndex(of: props.selected) ?? 0) },
                            set: { selection.wrappedValue = values[min(max(Int($0.rounded()), 0), values.count - 1)] }
                        ), in: 0...Double(values.count - 1), step: 1)
                        .accessibilityLabel(common.label ?? "")
                        .accessibilityValue(selectedLabel)
                        .modifier(Applied(when: common.testID != nil) { $0.accessibilityIdentifier(common.testID ?? "") })
                    }
            } else {
                EffortStepSlider(selection: selection, choices: values)
                    .accessibilityRepresentation {
                        Text(verbatim: selectedLabel)
                            .accessibilityElement()
                            .accessibilityLabel(common.label ?? "")
                            .accessibilityValue(selectedLabel)
                            .modifier(Applied(when: common.testID != nil) { $0.accessibilityIdentifier(common.testID ?? "") })
                    }
            }
        }
        .atomHighlight(.stepSlider)
    }
}

/// A leading column whose clicks and presses AppKit tells apart: a click
/// calls `onPress` and a press and hold calls `onLongPress`. It covers its
/// children, so it holds only the part of a row the press is for. It is one
/// accessibility container, so its identifier never replaces theirs.
struct AtomPressArea<Content: View>: View {
    var props = PressAreaProps()
    var common = AtomCommon()
    let onPress: () -> Void
    let onLongPress: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: props.spacing.map { CGFloat($0) }, content: content)
            .overlay {
                PressAreaView(showsPointingHand: props.pointer == true, onClick: onPress, onLongPress: onLongPress)
            }
            .atomCommon(common, atom: .pressArea, group: true)
    }
}

/// AppKit's own mouse tracking tells a click from a press and hold: SwiftUI's
/// long-press gesture raced against a tap could stay tracking after a click
/// opened the editor, and the window then ignored every click until it was
/// minimized.
struct PressAreaView: NSViewRepresentable {
    let showsPointingHand: Bool
    let onClick: () -> Void
    let onLongPress: () -> Void

    func makeNSView(context: Context) -> PressView { PressView() }

    func updateNSView(_ view: PressView, context: Context) {
        view.onClick = onClick
        view.onLongPress = onLongPress
        if view.showsPointingHand != showsPointingHand {
            view.showsPointingHand = showsPointingHand
            view.window?.invalidateCursorRects(for: view)
        }
    }

    final class PressView: NSView {
        static let holdDuration: TimeInterval = 0.45
        var onClick: () -> Void = {}
        var onLongPress: () -> Void = {}
        var showsPointingHand = false

        override func isAccessibilityElement() -> Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            if showsPointingHand { addCursorRect(bounds, cursor: .pointingHand) }
        }

        /// Tracks the press to its mouse-up here, so no gesture state outlives it.
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            let deadline = Date(timeIntervalSinceNow: Self.holdDuration)
            var held = false
            while true {
                let next = window.nextEvent(
                    matching: [.leftMouseUp, .leftMouseDragged],
                    until: held ? .distantFuture : deadline,
                    inMode: .eventTracking,
                    dequeue: true
                )
                guard let next else {
                    held = true
                    onLongPress()
                    continue
                }
                guard next.type == .leftMouseUp else { continue }
                if !held, bounds.contains(convert(next.locationInWindow, from: nil)) { onClick() }
                return
            }
        }
    }
}

/// Tracks the whole row independently of the views revealed above it. SwiftUI's
/// hover target can change when those views appear, producing exit/enter loops.
