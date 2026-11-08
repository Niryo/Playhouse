import Foundation

/// The atoms plugins compose UI from: exactly the pieces the task item is
/// built of. Each atom's props are a plain Decodable struct, decoded from a
/// create/update op's payload here and built directly by native SwiftUI code,
/// so both reach the same view (see `AtomRegistry` in Plugins/Atoms).
enum AtomType: String, CaseIterable, Sendable {
    case stack = "Stack"
    case text = "Text"
    case icon = "Icon"
    case label = "Label"
    case button = "Button"
    case link = "Link"
    case spinner = "Spinner"
    case spacer = "Spacer"
    case pillPicker = "PillPicker"
    case card = "Card"

    /// The events each atom raises; a plugin's handler for any other name is never called.
    var events: Set<String> {
        switch self {
        case .button: ["onPress"]
        case .pillPicker: ["onChange"]
        case .card: ["onPress", "onMenu"]
        case .stack, .text, .icon, .label, .link, .spinner, .spacer: []
        }
    }

    /// Whether the atom shows atom children. A Text holds only raw strings.
    var takesAtomChildren: Bool {
        switch self {
        case .stack, .button, .link, .card: true
        case .text, .icon, .label, .spinner, .spacer, .pillPicker: false
        }
    }

    /// Checks that `parent` shows a `child` node of that type (`PluginNode.textType` for raw strings).
    static func validateChild(parent: String, child: String) throws {
        if parent == "#root" { return }
        let isText = child == "#text"
        guard let atom = AtomType(rawValue: parent),
              isText ? atom == .text : atom.takesAtomChildren else {
            throw PluginTreeError(message: isText
                ? "<\(parent)> can't hold a string; put it in a <Text>."
                : "<\(parent)> can't hold <\(child)>.")
        }
    }

    var propKeys: Set<String> {
        switch self {
        case .stack: Self.keys(StackProps.CodingKeys.self)
        case .text: Self.keys(TextProps.CodingKeys.self)
        case .icon: Self.keys(IconProps.CodingKeys.self)
        case .label: Self.keys(LabelProps.CodingKeys.self)
        case .button: Self.keys(ButtonProps.CodingKeys.self)
        case .link: Self.keys(LinkProps.CodingKeys.self)
        case .spinner: Self.keys(SpinnerProps.CodingKeys.self)
        case .spacer: Self.keys(SpacerProps.CodingKeys.self)
        case .pillPicker: Self.keys(PillPickerProps.CodingKeys.self)
        case .card: Self.keys(CardProps.CodingKeys.self)
        }
    }

    private static func keys<Key: CodingKey & CaseIterable>(_: Key.Type) -> Set<String> {
        Set(Key.allCases.map(\.stringValue))
    }

    /// Checks a create/update op: a known atom, only its own events, only its
    /// own and the common props, each of the right type.
    static func validate(type: String, props: [String: PluginValue], events: [String]) throws {
        guard let atom = AtomType(rawValue: type) else {
            throw PluginTreeError(message: "Unknown atom <\(type)>.")
        }
        if let unknown = events.sorted().first(where: { !atom.events.contains($0) }) {
            throw PluginTreeError(message: "<\(type)> has no event \"\(unknown)\".")
        }
        let allowed = atom.propKeys.union(AtomCommon.keys)
        if let unknown = props.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw PluginTreeError(message: "<\(type)> has no prop \"\(unknown)\".")
        }
        do {
            _ = try AtomCommon.decode(props)
            switch atom {
            case .stack: _ = try StackProps.decode(props)
            case .text: _ = try TextProps.decode(props)
            case .icon: _ = try IconProps.decode(props)
            case .label: _ = try LabelProps.decode(props)
            case .button: _ = try ButtonProps.decode(props)
            case .link: _ = try LinkProps.decode(props)
            case .spinner: _ = try SpinnerProps.decode(props)
            case .spacer: _ = try SpacerProps.decode(props)
            case .pillPicker: _ = try PillPickerProps.decode(props)
            case .card: _ = try CardProps.decode(props)
            }
        } catch let error as DecodingError {
            throw PluginTreeError(message: "<\(type)> has an invalid prop: \(Self.describe(error))")
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .keyNotFound(_, let context), .dataCorrupted(let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }
}

protocol AtomPropsDecodable: Decodable {}

extension AtomPropsDecodable {
    static func decode(_ props: [String: PluginValue]) throws -> Self {
        let data = try JSONEncoder().encode(PluginValue.object(props))
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

/// Props every atom takes: accessibility, tooltip and frame.
struct AtomCommon: AtomPropsDecodable, Equatable {
    /// The accessibility identifier.
    var testID: String?
    /// The accessibility label, value and hint.
    var label: String?
    var value: String?
    var hint: String?
    /// The hover tooltip.
    var help: String?
    var width: Double?
    var height: Double?
    var minWidth: Double?
    var minHeight: Double?
    /// Stretch to the available width, content leading.
    var fillWidth: Bool?
    var padding: Double?
    /// Extra horizontal padding, inside `padding`.
    var paddingX: Double?
    /// Let clicks through to whatever is behind (the card's open button).
    var passThrough: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case testID, label, value, hint, help, width, height, minWidth, minHeight, fillWidth, padding, paddingX, passThrough
    }

    static let keys = Set(CodingKeys.allCases.map(\.stringValue))
}

/// A row or column. `axis` is "h" or "v" (default); `align` is leading,
/// center or trailing for a column and top, center or bottom for a row.
/// `group` makes it one accessibility container for its children.
struct StackProps: AtomPropsDecodable, Equatable {
    var axis: String?
    var spacing: Double?
    var align: String?
    var group: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable { case axis, spacing, align, group }
}

/// A string, from `text` or the atom's raw string children. Weights: regular,
/// medium, semibold, bold; designs: default, monospaced.
struct TextProps: AtomPropsDecodable, Equatable {
    var text: String?
    var size: Double?
    var weight: String?
    var design: String?
    var color: String?
    var lineLimit: Int?
    var tracking: Double?
    var lineSpacing: Double?
    /// Grow vertically to fit instead of truncating.
    var wrap: Bool?
    /// Animate digit changes.
    var numeric: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case text, size, weight, design, color, lineLimit, tracking, lineSpacing, wrap, numeric
    }
}

/// An SF Symbol (`name`) or a template image from the app's assets (`asset`).
struct IconProps: AtomPropsDecodable, Equatable {
    var name: String?
    var asset: String?
    var size: Double?
    var weight: String?
    var color: String?

    enum CodingKeys: String, CodingKey, CaseIterable { case name, asset, size, weight, color }
}

/// An SF Symbol beside a string.
struct LabelProps: AtomPropsDecodable, Equatable {
    var text: String
    var icon: String
    var size: Double?
    var weight: String?
    var color: String?

    enum CodingKeys: String, CodingKey, CaseIterable { case text, icon, size, weight, color }
}

/// A button whose label is its children. `style` is plain (default) or
/// borderless; `emphasis` is the padding of the hover capsule, if any, and
/// `overhang` lets that capsule spill past the button's layout size.
struct ButtonProps: AtomPropsDecodable, Equatable {
    var style: String?
    var emphasis: Double?
    var overhang: Bool?
    var disabled: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable { case style, emphasis, overhang, disabled }
}

/// Opens `url` in the browser; its label is its children.
struct LinkProps: AtomPropsDecodable, Equatable {
    var url: String
    var emphasis: Double?

    enum CodingKeys: String, CodingKey, CaseIterable { case url, emphasis }
}

/// An indeterminate progress spinner; `size` is small (default) or mini.
struct SpinnerProps: AtomPropsDecodable, Equatable {
    var size: String?

    enum CodingKeys: String, CodingKey, CaseIterable { case size }
}

struct SpacerProps: AtomPropsDecodable, Equatable {
    var minLength: Double?

    enum CodingKeys: String, CodingKey, CaseIterable { case minLength }
}

/// A capsule showing the selected option that expands into all of them when
/// clicked. `onChange` receives the chosen option's value.
struct PillPickerProps: AtomPropsDecodable, Equatable {
    struct Option: Codable, Equatable {
        var value: String
        var label: String
        var help: String?
        var testID: String?
    }

    var options: [Option]
    var selected: String

    enum CodingKeys: String, CodingKey, CaseIterable { case options, selected }
}

/// The task item's surface: a rounded, bordered card that is one big button
/// (`onPress`), with a right-click menu (`onMenu` receives the item's id) and
/// an optional usage meter along its leading edge (`meter`, 0...1).
struct CardProps: AtomPropsDecodable, Equatable {
    struct MenuItem: Codable, Equatable {
        var id: String
        var title: String
        var icon: String?
        var destructive: Bool?
        var testID: String?
    }

    var menu: [MenuItem]?
    var meter: Double?
    var meterLabel: String?
    var meterTestID: String?

    enum CodingKeys: String, CodingKey, CaseIterable { case menu, meter, meterLabel, meterTestID }
}
