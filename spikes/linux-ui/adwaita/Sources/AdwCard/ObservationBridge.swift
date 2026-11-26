import Adwaita
import CardHarness
import Foundation
import Observation

/// Adwaita for Swift has no Observation support: views only update when one
/// of its own `@State` values changes. This bridge tracks every @Observable
/// read a card makes while building its body; when any of them changes it
/// schedules ONE refresh (coalesced to the next main-loop turn) by bumping a
/// root `@State` revision. Meta then re-evaluates the whole view tree, which
/// is also what happens on any other state change in this library.
enum ObservationBridge {
    /// Set by the root view: bumps its `@State` revision.
    static var refresh: () -> Void = {}
    private static var scheduled = false
    static var refreshCount = 0

    static func track<T>(_ read: () -> T) -> T {
        withObservationTracking(read) {
            // onChange runs synchronously inside the mutation, on the mutating thread (main here).
            MainActor.assumeIsolated { schedule() }
        }
    }

    static func schedule() {
        guard !scheduled else { return }
        scheduled = true
        after(0) {
            scheduled = false
            refreshCount += 1
            refresh()
        }
    }
}
