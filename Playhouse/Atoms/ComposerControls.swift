import Foundation
import PlayhouseCore
import PlayhouseUI

/// The composer's `@` mentions, for native owners only: the handles its editor colors,
/// an edit that inserts a chosen mention, and the keys an open mention menu takes.
package struct ChatEditorMentions {
    package var handles: Set<String> = []
    package var edit: ChatEditorEdit? = nil
    /// Returns whether the menu took the key; the editor handles it otherwise.
    package var onKey: ((ChatEditorKey) -> Bool)? = nil
    /// Every time the editor starts or stops editing, unlike `isFocused`, which reports only
    /// changes from the owner's value.
    package var onEditingChange: (Bool) -> Void = { _ in }

    package init(handles: Set<String> = [], edit: ChatEditorEdit? = nil, onKey: ((ChatEditorKey) -> Bool)? = nil, onEditingChange: @escaping (Bool) -> Void = { _ in }) {
        self.handles = handles
        self.edit = edit
        self.onKey = onKey
        self.onEditingChange = onEditingChange
    }
}

/// Replaces `range` (UTF-16) with `text` once per `id`, leaving the caret after it, as typing would.
package struct ChatEditorEdit: Equatable {
    package let id: Int
    package let range: NSRange
    package let text: String

    package init(id: Int, range: NSRange, text: String) {
        self.id = id
        self.range = range
        self.text = text
    }
}

package enum ChatEditorKey {
    case up, down, accept, dismiss
}

package struct EffortStepSlider: PHView {
    @PHBinding package var selection: String
    package let choices: [String]

    private let knobDiameter: CGFloat = 20
    private let trackHeight: CGFloat = 6

    private var selectedIndex: Int { choices.firstIndex(of: selection) ?? 0 }
    private var stepCount: Int { max(choices.count - 1, 1) }

    package var body: some PHView {
        PHGeometryReader { proxy in
            let travel = max(proxy.size.width - knobDiameter, 1)
            let knobX = travel * CGFloat(selectedIndex) / CGFloat(stepCount)
            PHZStack(alignment: .leading) {
                PHCapsule()
                    .fill(PHColor.primary.opacity(0.2))
                    .frame(height: trackHeight)
                PHCapsule()
                    .fill(PHColor.accentColor)
                    .frame(width: knobX + knobDiameter / 2, height: trackHeight)
                PHForEach(choices.indices, id: \.self) { index in
                    PHCircle()
                        .fill(PHColor.primary.opacity(0.35))
                        .frame(width: 4, height: 4)
                        .offset(x: travel * CGFloat(index) / CGFloat(stepCount) + knobDiameter / 2 - 2)
                }
                PHCircle()
                    .fill(PHColor.white)
                    .frame(width: knobDiameter, height: knobDiameter)
                    .offset(x: knobX)
            }
            .frame(width: proxy.size.width, height: knobDiameter, alignment: .leading)
            .contentShape(PHRectangle())
            .gesture(PHDragGesture(minimumDistance: 0).onChanged { value in
                guard !choices.isEmpty else { return }
                let fraction = (value.location.x - knobDiameter / 2) / travel
                let index = min(Int((min(max(fraction, 0), 1) * CGFloat(stepCount)).rounded()), choices.count - 1)
                selection = choices[index]
            })
        }
        .frame(height: knobDiameter)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { moveSelection(by: -1) }
        .onKeyPress(.rightArrow) { moveSelection(by: 1) }
    }

    private func moveSelection(by delta: Int) -> PHKeyPress.Result {
        guard !choices.isEmpty else { return .ignored }
        selection = choices[min(max(selectedIndex + delta, 0), choices.count - 1)]
        return .handled
    }

    package init(selection: PHBinding<String>, choices: [String]) {
        _selection = selection
        self.choices = choices
    }
}
