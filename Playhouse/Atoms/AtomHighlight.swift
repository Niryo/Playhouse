import Foundation
import PlayhouseCore
import PlayhouseUI

/// Debug overlay that outlines every atom view, so the UI already migrated to
/// plugin atoms is easy to tell from plain SwiftUI. Release builds compile the
/// modifiers to nothing, leaving the view tree unchanged.
#if DEBUG
extension PHView {
    /// Outlines this atom when "Highlight Native Atoms" is on.
    package func atomHighlight(_ atom: AtomType) -> some PHView {
        modifier(AtomHighlightModifier(atom: atom))
    }

    /// Supplies the highlight flag to the atoms below, from the app storage
    /// in its environment, so apply it inside `defaultAppStorage`.
    package func atomHighlightRoot() -> some PHView {
        modifier(AtomHighlightRootModifier())
    }

    /// Carries the highlight flag from `environment` to content hosted outside
    /// this view tree, such as an `NSPopover`.
    package func atomHighlightEnvironment(from environment: PHEnvironmentValues) -> some PHView {
        self.environment(\.highlightNativeAtoms, environment.highlightNativeAtoms)
    }
}
#else
extension PHView {
    /// Returns `Self`, not `some View`, so release view types are unchanged.
    @inline(__always) package func atomHighlight(_ atom: AtomType) -> Self { self }
    @inline(__always) package func atomHighlightRoot() -> Self { self }
    @inline(__always) package func atomHighlightEnvironment(from environment: PHEnvironmentValues) -> Self { self }
}
#endif

#if DEBUG
package enum AtomHighlight {
    package static let defaultsKey = "highlightNativeAtoms"
}

private struct HighlightNativeAtomsKey: PHEnvironmentKey {
    static let defaultValue = false
}

extension PHEnvironmentValues {
    package var highlightNativeAtoms: Bool {
        get { self[HighlightNativeAtomsKey.self] }
        set { self[HighlightNativeAtomsKey.self] = newValue }
    }
}

private struct AtomHighlightRootModifier: PHViewModifier {
    @PHAppStorage(AtomHighlight.defaultsKey) private var enabled = false

    func body(content: Content) -> some PHView {
        content.environment(\.highlightNativeAtoms, enabled)
    }
}

package struct AtomHighlightMenuItem: PHView {
    @PHAppStorage(AtomHighlight.defaultsKey) private var enabled = false

    package var body: some PHView {
        PHToggle("Highlight Native Atoms", isOn: $enabled)
            // no-pointer: a Debug menu-bar item, not a control in the window.
    }

    package init() {}
}

private struct AtomHighlightModifier: PHViewModifier {
    let atom: AtomType
    @PHEnvironment(\.highlightNativeAtoms) private var enabled

    @PHViewBuilder
    func body(content: Content) -> some PHView {
        if enabled {
            content.modifier(AtomHighlightOverlay(atom: atom))
        } else {
            content
        }
    }
}

/// Containers are orange and leaves green, so a composite built from atoms
/// reads apart from a native view holding a single atom. The outline also
/// names the atom and its role to accessibility (Accessibility Inspector, UI
/// tests). Toggling the flag resets atom view state below it, since the
/// modifier only wraps the content while on. A background window doesn't name
/// the atom under the pointer: hover tracking also reports a pointer over another
/// window in front, so an atom behind it would otherwise show its label.
private struct AtomHighlightOverlay: PHViewModifier {
    let atom: AtomType
    @PHState private var hovering = false
    @PHEnvironment(\.controlActiveState) private var controlActiveState

    func body(content: Content) -> some PHView {
        let color: PHColor = atom.isContainer ? .orange : .green
        content
            .overlay {
                PHRectangle()
                    .strokeBorder(color.opacity(0.8), lineWidth: 1)
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityLabel(atom.rawValue)
                    .accessibilityIdentifier(atom.isContainer ? "atom-highlight-container" : "atom-highlight-leaf")
            }
            .overlay(alignment: .topLeading) {
                if hovering, controlActiveState != .inactive {
                    PHText(atom.rawValue)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .background(color, in: PHRoundedRectangle(cornerRadius: 2))
                        .fixedSize()
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("atom-hover-label")
                }
            }
            .phOnHover { hovering = $0 }
    }
}
#endif
