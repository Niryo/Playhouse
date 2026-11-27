import Foundation


/// The terminal panel's width, which the user sets by dragging its left border.
package enum TerminalPanelLayout {
    package static let widthKey = "terminalPanelWidth"
    package static let defaultWidth: CGFloat = 460
    package static let minimumWidth: CGFloat = 320
    /// The conversation keeps at least this much of the space the panel floats over.
    package static let minimumUncovered: CGFloat = 260
    /// Each shell in a multi-repository split keeps at least this height.
    package static let minimumPaneHeight: CGFloat = 90

    package static func clampedWidth(_ width: CGFloat, available: CGFloat) -> CGFloat {
        let maximum = max(minimumWidth, available - minimumUncovered)
        return min(max(width, minimumWidth), maximum)
    }
}
