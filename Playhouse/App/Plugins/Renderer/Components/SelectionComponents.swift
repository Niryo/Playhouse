import SwiftUI

/// A whole number stays an integer so JavaScript state shows `3`, not `3.0`.
func pluginNumber(_ value: Double) -> BridgeValue {
    value == value.rounded() && abs(value) < 1e15 ? .integer(Int(value)) : .decimal(value)
}

enum ToggleComponent: PluginComponent {
    static let type = "toggle"
    static let handlesOwnInput = true

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        let label = ctx.string("label") ?? ""
        let binding = Binding(get: { ctx.bool("value") }, set: { ctx.fire("onChange", value: .boolean($0)) })
        let toggle = Toggle(label, isOn: binding).nativeHelp(ctx.string("tooltip") ?? (label.isEmpty ? "Toggle" : label))
        return ctx.string("style") == "checkbox"
            ? AnyView(toggle.toggleStyle(.checkbox))
            : AnyView(toggle.toggleStyle(.switch))
    }
}

enum SegmentedComponent: PluginComponent {
    static let type = "segmented"
    static let handlesOwnInput = true

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        let binding = Binding(get: { ctx.string("value") ?? "" }, set: { ctx.fire("onChange", value: .string($0)) })
        return AnyView(
            Picker("", selection: binding) {
                ForEach(ctx.options, id: \.value) { option in
                    if let icon = option.icon {
                        Label(option.title, systemImage: icon).tag(option.value)
                    } else {
                        Text(option.title).tag(option.value)
                    }
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .nativeHelp(ctx.string("tooltip") ?? "Choose an option")
        )
    }
}

enum PickerComponent: PluginComponent {
    static let type = "picker"
    static let handlesOwnInput = true

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        let label = ctx.string("label") ?? ""
        let binding = Binding(get: { ctx.string("value") ?? "" }, set: { ctx.fire("onChange", value: .string($0)) })
        return AnyView(
            Picker(label, selection: binding) {
                ForEach(ctx.options, id: \.value) { option in
                    Text(option.title).tag(option.value)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .nativeHelp(ctx.string("tooltip") ?? (label.isEmpty ? "Choose an option" : label))
        )
    }
}

enum SliderComponent: PluginComponent {
    static let type = "slider"
    static let handlesOwnInput = true

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        AnyView(PluginSlider(ctx: ctx))
    }
}

private struct PluginSlider: View {
    let ctx: PluginRenderContext

    private var low: Double { ctx.number("min") ?? 0 }
    private var high: Double { max(ctx.number("max") ?? 100, low + 0.0001) }
    private var step: Double? { ctx.number("step").flatMap { $0 > 0 ? $0 : nil } }
    private var value: Double { min(max(ctx.number("value") ?? low, low), high) }

    private var binding: Binding<Double> {
        Binding(get: { value }, set: { ctx.fire("onChange", value: pluginNumber($0)) })
    }

    var body: some View {
        HStack(spacing: 8) {
            if let label = ctx.string("label") { Text(label) }
            if ctx.bool("ticks"), let step {
                StepTrack(value: binding, low: low, high: high, step: step)
            } else if let step {
                Slider(value: binding, in: low...high, step: step)
            } else {
                Slider(value: binding, in: low...high)
            }
            Text(pluginNumber(value).interpolatedText).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(minWidth: 180)
        .nativeHelp(ctx.string("tooltip") ?? ctx.string("label") ?? "Slider")
    }
}

/// The stepped look of the app's effort slider: a capsule track, a dot per step and a knob.
/// Accessibility sees an ordinary slider, as it does for the app's own.
private struct StepTrack: View {
    @Binding var value: Double
    let low: Double
    let high: Double
    let step: Double

    private var count: Int { max(Int(((high - low) / step).rounded()), 1) }
    private var position: Double { (value - low) / (high - low) }

    var body: some View {
        GeometryReader { proxy in
            let knob: CGFloat = 14
            let travel = max(proxy.size.width - knob, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.gray.opacity(0.3)).frame(height: 4).padding(.horizontal, knob / 2)
                Capsule().fill(WorkspaceTheme.accent).frame(width: travel * position + knob / 2, height: 4).padding(.leading, knob / 2)
                ForEach(0...count, id: \.self) { index in
                    Circle().fill(Color.gray.opacity(0.6)).frame(width: 4, height: 4)
                        .offset(x: knob / 2 - 2 + travel * CGFloat(index) / CGFloat(count))
                }
                Circle().fill(Color.white).frame(width: knob, height: knob)
                    .shadow(radius: 1)
                    .offset(x: travel * position)
            }
            .frame(height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let fraction = min(max((drag.location.x - knob / 2) / travel, 0), 1)
                let snapped = (fraction * Double(count)).rounded()
                let next = low + snapped * step
                if next != value { value = next }
            })
        }
        .frame(height: 20)
        .accessibilityRepresentation {
            Slider(value: $value, in: low...high, step: step)
        }
    }
}

enum DatePickerComponent: PluginComponent {
    static let type = "date-picker"
    static let handlesOwnInput = true

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        let components: DatePickerComponents = switch ctx.string("mode") {
        case "time": .hourAndMinute
        case "datetime": [.date, .hourAndMinute]
        default: .date
        }
        let binding = Binding(
            get: { ctx.string("value").flatMap(PluginDates.parse) ?? Date() },
            set: { ctx.fire("onChange", value: .string(PluginDates.format($0))) }
        )
        return AnyView(
            DatePicker(ctx.string("label") ?? "", selection: binding, displayedComponents: components)
                .fixedSize()
                .nativeHelp(ctx.string("tooltip") ?? ctx.string("label") ?? "Date")
        )
    }
}

enum PluginDates {
    static func parse(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: text) ?? fractional.date(from: text)
    }

    static func format(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
