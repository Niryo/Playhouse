#if canImport(SwiftUI)
import SwiftUI
import PlayhouseCore

private struct ModelContextKey: EnvironmentKey {
    static let defaultValue: PlayhouseModelContext? = nil
}

extension EnvironmentValues {
    /// The task store's main context, set on the window's root view by `modelContainer(_:)`.
    package var modelContext: PlayhouseModelContext {
        guard let context = installedModelContext else {
            preconditionFailure("A view read the task store before modelContainer(_:) set it.")
        }
        return context
    }

    /// What `modelContainer(_:)` writes. It is separate from `modelContext` because SwiftUI reads
    /// an environment key path before it writes it, and the parent environment has no context yet.
    fileprivate var installedModelContext: PlayhouseModelContext? {
        get { self[ModelContextKey.self] }
        set { self[ModelContextKey.self] = newValue }
    }
}

extension View {
    /// Gives this view hierarchy the container's main context, as SwiftData's modifier of the same name did.
    @MainActor package func modelContainer(_ container: PlayhouseModelContainer) -> some View {
        environment(\.installedModelContext, container.mainContext)
    }
}
#endif
