import Foundation
import Observation

/// Checks that the open-source toolchain's Observation framework behaves as
/// on macOS: `withObservationTracking` fires `onChange` once for a tracked
/// property, not for an untracked one, and across nested observables.
@MainActor
public enum ObservationCheck {
    public static func run() -> [String: Bool] {
        let card = Samples.reference()
        let board = BoardModel(cards: [card])
        var results: [String: Bool] = [:]

        // onChange is @Sendable; a lock-free box is fine, everything runs on the main thread.
        final class Counter: @unchecked Sendable { var value = 0 }
        let fired = Counter()
        withObservationTracking { _ = card.title } onChange: { fired.value += 1 }
        card.statusMessage = "untracked change"
        results["untracked property does not fire"] = fired.value == 0
        card.title = "Renamed"
        results["tracked property fires"] = fired.value == 1
        card.title = "Renamed again"
        results["fires once per registration"] = fired.value == 1

        let nested = Counter()
        withObservationTracking { _ = board.cards.first?.cpu } onChange: { nested.value += 1 }
        board.cards[0].cpu = .init(fraction: 0.9, label: "CPU 90%")
        results["nested observable fires"] = nested.value == 1

        // A model mutated off the main actor would be a compile error under
        // Swift 6's checking, since the models are @MainActor.
        return results
    }

    public static func report() -> String {
        let results = run()
        let passed = results.values.allSatisfy { $0 }
        let detail = results.sorted { $0.key < $1.key }.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",")
        return "PERF {\"event\":\"observation_check\",\"passed\":\(passed),\(detail)}"
    }
}
