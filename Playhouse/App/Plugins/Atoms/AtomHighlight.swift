import SwiftUI

/// Debug overlay that outlines every atom view, so the UI already migrated to
/// plugin atoms is easy to tell from plain SwiftUI. Release builds compile the
/// modifiers to nothing, leaving the view tree unchanged.
#if DEBUG
extension View {
    /// Outlines this atom when "Highlight Native Atoms" is on.
    func atomHighlight(_ atom: AtomType) -> some View {
        modifier(AtomHighlightModifier(atom: atom))
    }

    /// Supplies the highlight flag to the atoms below, from the app storage
    /// in its environment, so apply it inside `defaultAppStorage`.
    func atomHighlightRoot() -> some View {
        modifier(AtomHighlightRootModifier())
    }

    /// Carries the highlight flag from `environment` to content hosted outside
    /// this view tree, such as an `NSPopover`.
    func atomHighlightEnvironment(from environment: EnvironmentValues) -> some View {
        self.environment(\.highlightNativeAtoms, environment.highlightNativeAtoms)
    }
}
#else
extension View {
    /// Returns `Self`, not `some View`, so release view types are unchanged.
    @inline(__always) func atomHighlight(_ atom: AtomType) -> Self { self }
    @inline(__always) func atomHighlightRoot() -> Self { self }
    @inline(__always) func atomHighlightEnvironment(from environment: EnvironmentValues) -> Self { self }
}
#endif

#if DEBUG
enum AtomHighlight {
    static let defaultsKey = "highlightNativeAtoms"
}

private struct HighlightNativeAtomsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var highlightNativeAtoms: Bool {
        get { self[HighlightNativeAtomsKey.self] }
        set { self[HighlightNativeAtomsKey.self] = newValue }
    }
}

private struct AtomHighlightRootModifier: ViewModifier {
    @AppStorage(AtomHighlight.defaultsKey) private var enabled = false

    func body(content: Content) -> some View {
        content.environment(\.highlightNativeAtoms, enabled)
    }
}

struct AtomHighlightMenuItem: View {
    @AppStorage(AtomHighlight.defaultsKey) private var enabled = false

    var body: some View {
        Toggle("Highlight Native Atoms", isOn: $enabled)
    }
}

private struct AtomHighlightModifier: ViewModifier {
    let atom: AtomType
    @Environment(\.highlightNativeAtoms) private var enabled

    @ViewBuilder
    func body(content: Content) -> some View {
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
private struct AtomHighlightOverlay: ViewModifier {
    let atom: AtomType
    @State private var hovering = false
    @Environment(\.controlActiveState) private var controlActiveState

    func body(content: Content) -> some View {
        let color: Color = atom.isContainer ? .orange : .green
        content
            .overlay {
                Rectangle()
                    .strokeBorder(color.opacity(0.8), lineWidth: 1)
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityLabel(atom.rawValue)
                    .accessibilityIdentifier(atom.isContainer ? "atom-highlight-container" : "atom-highlight-leaf")
            }
            .overlay(alignment: .topLeading) {
                if hovering, controlActiveState != .inactive {
                    Text(atom.rawValue)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .background(color, in: RoundedRectangle(cornerRadius: 2))
                        .fixedSize()
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("atom-hover-label")
                }
            }
            .onHover { hovering = $0 }
    }
}
#endif
