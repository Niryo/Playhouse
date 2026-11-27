import Foundation
import PlayhouseCore
import PlayhouseUI

/// value, and the owner moves `selected`.
package struct AtomChoiceBar: PHView {
    package var props: ChoiceBarProps
    package var common = AtomCommon()
    package let onChange: (String) -> Void

    package var body: some PHView {
        PHHStack(spacing: 2) {
            PHForEach(props.options, id: \.value) { option in
                let isSelected = option.value == props.selected
                PHButton {
                    if !isSelected { onChange(option.value) }
                } label: {
                    PHText(verbatim: option.label)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(PHRoundedRectangle(cornerRadius: 5).fill(isSelected ? PHColor.accentColor.opacity(0.2) : PHColor.clear))
                        .contentShape(PHRectangle())
                }
                .buttonStyle(.plain)
                .plainButtonHoverPointer()
                .nativeHelp(option.label)
                .modifier(Applied(when: option.testID != nil) { $0.accessibilityIdentifier(option.testID ?? "") })
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(PHRoundedRectangle(cornerRadius: 7).fill(PHColor.primary.opacity(0.06)))
        .atomCommon(common, atom: .choiceBar, group: true)
    }

    package init(props: ChoiceBarProps, common: AtomCommon = AtomCommon(), onChange: @escaping (String) -> Void) {
        self.props = props
        self.common = common
        self.onChange = onChange
    }
}

/// A switch with no visible label. A click asks the owner to flip `isOn`
/// (`onToggle`); it shows whatever `isOn` it is given.
package struct AtomToggle: PHView {
    package var props: ToggleProps
    package var common = AtomCommon()
    package let onToggle: () -> Void

    package var body: some PHView {
        PHToggle(common.label ?? "", isOn: PHBinding(get: { props.isOn }, set: { if $0 != props.isOn { onToggle() } }))
            .toggleStyle(.switch)
            .controlSize(controlSize)
            .labelsHidden()
            .disabled(props.disabled == true)
            .buttonHoverPointer() // no-tooltip: the atom's help prop sets it, through atomCommon.
            .atomCommon(common, atom: .toggle)
    }

    private var controlSize: PHControlSize {
        switch props.size {
        case "mini": .mini
        case "small": .small
        default: .regular
        }
    }

    package init(props: ToggleProps, common: AtomCommon = AtomCommon(), onToggle: @escaping () -> Void) {
        self.props = props
        self.common = common
        self.onToggle = onToggle
    }
}

/// A rounded one-line text field. It edits its own copy of `text` so typing
/// never waits on the owner, reports each edit through `onChange`, and takes
/// the owner's `text` whenever that changes. Only real edits reach the owner:
/// ending editing as the field goes away (a popover closing) sets the same
/// text again, which must not undo a reset the owner just made. Return goes to `onSubmit` and
/// the Up and Down arrows to `onArrow` only when they are given; otherwise
/// the field handles those keys as usual.
package struct AtomTextField: PHView {
    package var props: TextFieldProps
    package var common = AtomCommon()
    package let onChange: (String) -> Void
    package var onSubmit: (() -> Void)?
    package var onArrow: ((String) -> Void)?
    @PHState private var text: String
    @PHFocusState private var isFocused: Bool

    package init(
        props: TextFieldProps, common: AtomCommon = AtomCommon(), onChange: @escaping (String) -> Void,
        onSubmit: (() -> Void)? = nil, onArrow: ((String) -> Void)? = nil
    ) {
        self.props = props
        self.common = common
        self.onChange = onChange
        self.onSubmit = onSubmit
        self.onArrow = onArrow
        _text = PHState(initialValue: props.text)
    }

    package var body: some PHView {
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

    @PHViewBuilder
    private var styledField: some PHView {
        let field = PHTextField(props.placeholder ?? "", text: PHBinding(get: { text }, set: { edited in
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
package struct AtomSegmented: PHView {
    package var props: SegmentedProps
    package var common = AtomCommon()
    package let onChange: (String) -> Void

    package var body: some PHView {
        PHPicker(common.label ?? "", selection: PHBinding(get: { props.selected }, set: { if $0 != props.selected { onChange($0) } })) {
            PHForEach(props.options, id: \.value) { option in
                PHText(verbatim: option.label).tag(option.value)
            }
        }
        .buttonHoverPointer()
        .pickerStyle(.segmented)
        .labelsHidden()
        .modifier(Applied(when: common.width == nil) { $0.fixedSize() })
        .disabled(props.disabled == true)
        .atomCommon(common, atom: .segmented)
    }

    package init(props: SegmentedProps, common: AtomCommon = AtomCommon(), onChange: @escaping (String) -> Void) {
        self.props = props
        self.common = common
        self.onChange = onChange
    }
}

/// A borderless pull-down menu labelled by an SF Symbol, text or both. The
/// common width and height frame the label, so they are the click target; a
/// separator sits between the item groups, and a checked item is marked.
package struct AtomMenu: PHView {
    package var props: MenuProps
    package var common = AtomCommon()
    package let onMenu: (String) -> Void

    package var body: some PHView {
        var label = common
        label.testID = nil
        label.label = nil
        label.help = nil
        let groups = props.items.filter { !$0.isEmpty }
        return PHMenu {
            PHForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { PHDivider() }
                PHForEach(group, id: \.id) { item in
                    PHButton(role: item.destructive == true ? .destructive : nil) { onMenu(item.id) } label: {
                        if item.checked == true {
                            PHLabel(item.title, icon: .checkmark)
                        } else if let icon = item.icon {
                            PHLabel(item.title, icon: PHIcon(named: icon))
                        } else {
                            PHText(verbatim: item.title)
                        }
                    }
                    .disabled(item.disabled == true)
                    .help(item.help ?? item.title)
                    .modifier(Applied(when: item.testID != nil) { $0.accessibilityIdentifier(item.testID ?? "") })
                }
            }
        } label: {
            PHHStack(spacing: 5) {
                if let icon = props.icon {
                    PHImage(icon: PHIcon(named: icon))
                        .atomFont(AtomFont.font(size: props.size, weight: props.weight))
                }
                if let badge = props.badgeIcon {
                    PHImage(icon: PHIcon(named: badge))
                        .atomFont(AtomFont.font(size: props.textSize, weight: props.textWeight))
                }
                if let text = props.text {
                    PHText(verbatim: text)
                        .atomFont(AtomFont.font(size: props.textSize, weight: props.textWeight))
                }
            }
            .foregroundStyle(AtomColor.style(props.color) ?? PHAnyShapeStyle(.secondary))
            .atomFrame(label)
            .contentShape(PHRectangle())
        }
        .menuStyle(.borderlessButton)
        .modifier(Applied(when: props.indicator != true) { $0.menuIndicator(.hidden) })
        .fixedSize()
        .disabled(props.disabled == true)
        .buttonHoverPointer() // no-tooltip: the atom's help prop sets it, through atomCommon.
        .atomCommon(common, atom: .menu, frame: false)
    }

    package init(props: MenuProps, common: AtomCommon = AtomCommon(), onMenu: @escaping (String) -> Void) {
        self.props = props
        self.common = common
        self.onMenu = onMenu
    }
}

/// The composer's message editor: AppKit's text view, which owns wrapping and
/// grows with its text up to a bounded height, under a placeholder. Focus is
/// the owner's: `props.focused` is what the editor shows, and the editor
/// reports its own changes through `onFocusChange`. An owner that doesn't
/// track focus always sees its `text` applied, as the conversation's draft is.
package struct AtomEditor: PHView {
    package var props: EditorProps
    package var common = AtomCommon()
    package let onChange: (String) -> Void
    package var onSubmit: () -> Void = {}
    package var onSteerSubmit: () -> Void = {}
    package var onFocusChange: (Bool) -> Void = { _ in }
    /// A pasted image reaches only native owners.
    package var onPasteImage: (Data) -> Void = { _ in }
    /// Escape reaches only native owners, and only those that set it.
    package var onCancel: (() -> Void)? = nil
    /// The selection reaches only native owners, such as the composer's plugins.
    package var onSelectionChange: (NSRange) -> Void = { _ in }
    /// The composer's `@` mentions reach only native owners.
    package var mentions = ChatEditorMentions()
    @PHState private var text: String
    @PHState private var height: CGFloat = 28

    package init(
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
        _text = PHState(initialValue: props.text)
    }

    package var body: some PHView {
        PHNativeChatEditor(
            text: PHBinding(get: { text }, set: { text = $0; onChange($0) }),
            height: $height,
            isFocused: PHBinding(get: { props.focused ?? false }, set: { if $0 != (props.focused ?? false) { onFocusChange($0) } }),
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
                PHText(verbatim: placeholder)
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
    package var withoutHint: AtomCommon {
        var copy = self
        copy.hint = nil
        return copy
    }
}

/// A popover over its anchor, open while `props.isPresented`. Native owners
/// give any SwiftUI content; a plugin's is every child after the anchor.
package struct AtomPopover<PHAnchor: PHView, Content: PHView>: PHView {
    package var props: PopoverProps
    package var common = AtomCommon()
    package let onDismiss: () -> Void
    @PHViewBuilder package var anchor: () -> PHAnchor
    @PHViewBuilder package var content: () -> Content

    package var body: some PHView {
        if props.hover == true {
            anchor()
                .background(PHHoverPopoverPresenter(
                    isPresented: props.isPresented,
                    delay: props.delay ?? PopoverProps.defaultHoverDelay,
                    edge: edge,
                    content: PHAnyView(paddedContent),
                    carryEnvironment: { content, environment in PHAnyView(content.atomHighlightEnvironment(from: environment)) }
                ))
                .atomCommon(layoutOnly, atom: .popover)
        } else {
            anchor()
                .popover(isPresented: PHBinding(get: { props.isPresented }, set: { if !$0 && props.isPresented { onDismiss() } }), arrowEdge: edge) {
                    paddedContent
                }
                .atomCommon(layoutOnly, atom: .popover)
        }
    }

    private var paddedContent: some PHView {
        content()
            .padding(CGFloat(props.inset ?? PopoverProps.defaultInset))
            .modifier(Applied(when: props.width != nil) { $0.frame(width: props.width.map { CGFloat($0) }) })
    }

    /// The anchor and the content keep their own accessibility, so the popover's
    /// `testID` only names it to a plugin's events. Its `width` is the content's,
    /// so it must not also size the anchor.
    private var layoutOnly: AtomCommon {
        var copy = common
        copy.width = nil
        copy.testID = nil
        copy.label = nil
        copy.value = nil
        copy.hint = nil
        return copy
    }

    private var edge: PHEdge {
        switch props.arrowEdge {
        case "bottom": .bottom
        case "leading": .leading
        case "trailing": .trailing
        default: .top
        }
    }

    package init(props: PopoverProps, common: AtomCommon = AtomCommon(), onDismiss: @escaping () -> Void, @PHViewBuilder anchor: @escaping () -> PHAnchor, @PHViewBuilder content: @escaping () -> Content) {
        self.props = props
        self.common = common
        self.onDismiss = onDismiss
        self.anchor = anchor
        self.content = content
    }
}
/// A discrete slider: an opaque-knob track drawn over an undrawn native slider
/// that takes the pointer and keyboard; SwiftUI represents it to accessibility.
package struct AtomStepSlider: PHView {
    package var props: StepSliderProps
    package var common = AtomCommon()
    package let onChange: (String) -> Void

    private var values: [String] { props.options.map(\.value) }
    private var selection: PHBinding<String> {
        PHBinding(get: { props.selected }, set: { if $0 != props.selected { onChange($0) } })
    }
    private var selectedLabel: String { props.options.first { $0.value == props.selected }?.label ?? props.selected }

    package var body: some PHView {
        PHGroup {
            if values.count > 1 {
                EffortStepSlider(selection: selection, choices: values)
                    .overlay { PHNativeEffortSlider(selection: selection, choices: values) }
                    .accessibilityRepresentation {
                        PHSlider(value: PHBinding(
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
                        PHText(verbatim: selectedLabel)
                            .accessibilityElement()
                            .accessibilityLabel(common.label ?? "")
                            .accessibilityValue(selectedLabel)
                            .modifier(Applied(when: common.testID != nil) { $0.accessibilityIdentifier(common.testID ?? "") })
                    }
            }
        }
        .atomHighlight(.stepSlider)
    }

    package init(props: StepSliderProps, common: AtomCommon = AtomCommon(), onChange: @escaping (String) -> Void) {
        self.props = props
        self.common = common
        self.onChange = onChange
    }
}

/// A leading column whose clicks and presses AppKit tells apart: a click
/// calls `onPress` and a press and hold calls `onLongPress`. It covers its
/// children, so it holds only the part of a row the press is for. It is one
/// accessibility container, so its identifier never replaces theirs.
package struct AtomPressArea<Content: PHView>: PHView {
    package var props = PressAreaProps()
    package var common = AtomCommon()
    package let onPress: () -> Void
    package let onLongPress: () -> Void
    @PHViewBuilder package var content: () -> Content

    package var body: some PHView {
        PHVStack(alignment: .leading, spacing: props.spacing.map { CGFloat($0) }, content: content)
            .overlay {
                PHPressArea(onClick: onPress, onLongPress: onLongPress)
            }
            .hoverCursor(props.pointer == true ? .pointingHand : nil, overAppKitControl: true)
            .atomCommon(common, atom: .pressArea, group: true)
    }

    package init(props: PressAreaProps = PressAreaProps(), common: AtomCommon = AtomCommon(), onPress: @escaping () -> Void, onLongPress: @escaping () -> Void, @PHViewBuilder content: @escaping () -> Content) {
        self.props = props
        self.common = common
        self.onPress = onPress
        self.onLongPress = onLongPress
        self.content = content
    }
}
/// Tracks the whole row independently of the views revealed above it. SwiftUI's
/// hover target can change when those views appear, producing exit/enter loops.
