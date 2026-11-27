#if canImport(SwiftUI)
import SwiftUI
import PlayhouseCore

extension TaskProgressType {
    /// The icon a card shows beside the progress report.
    package var icon: PHIcon {
        switch self {
        case .planning: .map
        case .searching: .magnifyingglass
        case .building: .hammer
        case .running: .playFill
        case .testing: .checkmarkSeal
        case .reviewing: .eye
        case .writing: .pencilLine
        case .committing: .arrowTriangleBranch
        }
    }
}

extension TaskStatus {
    package var accent: Color { Color(red: accentRGB.red, green: accentRGB.green, blue: accentRGB.blue) }
}

extension TokenUsageHeatmap {
    package static func color(totalTokens: Int, max: Int) -> Color {
        let hsb = hsb(totalTokens: totalTokens, max: max)
        return Color(hue: hsb.hue, saturation: hsb.saturation, brightness: hsb.brightness)
    }
}

extension CPUUsageHeatmap {
    package static let gradient = LinearGradient(
        colors: gradientStops.map { Color(hue: $0.hue, saturation: $0.saturation, brightness: $0.brightness) },
        startPoint: .bottom,
        endPoint: .top
    )
}
#endif
