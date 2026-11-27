import Foundation

// Focused unit checks of Playhouse/Core/Bridge/BoundedWaits.swift, compiled together with it and run by
// scripts/test-e2e.sh before the bridge suite. They pin the bounded waits that keep deleting a
// task from hanging on a turn that won't stop; the bridge cases
// `test_claude_delete_stops_live_turn_immediately` and `test_codex_delete_stops_live_turn_immediately`
// cover the delete itself end to end.

@main
@MainActor
struct BoundedWaitsTests {
    static var failures: [String] = []
    static var checks = 0

    static func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        checks += 1
        if actual != expected { failures.append("\(message): expected \(expected), got \(actual)") }
    }

    static func elapsed(since start: ContinuousClock.Instant) -> Duration { ContinuousClock.now - start }

    static func main() async {
        await lockGateTimesOutWhileHeld()
        await lockGateHandsOverBeforeTimeout()
        await timedOutWaiterNeverTakesTheKey()
        await untimedAcquireStillWaits()
        await resultReturnsFastValue()
        await resultGivesUpOnSlowOperation()
        if failures.isEmpty {
            print("Bounded wait unit checks passed: \(checks) checks.")
        } else {
            for failure in failures { print("FAIL: \(failure)") }
            exit(1)
        }
    }

    static func lockGateTimesOutWhileHeld() async {
        let key = "held-\(UUID().uuidString)"
        expect(await TaskOperationLockGate.acquire(key, timeout: .seconds(1)), true, "A free key is taken at once")
        let start = ContinuousClock.now
        expect(await TaskOperationLockGate.acquire(key, timeout: .milliseconds(100)), false, "A held key times out")
        expect(elapsed(since: start) < .seconds(2), true, "The timed-out wait ends near its timeout")
        expect(TaskOperationLockGate.isHeld(key), true, "A timed-out wait leaves the holder's key held")
        TaskOperationLockGate.release(key)
        expect(TaskOperationLockGate.isHeld(key), false, "Releasing with no waiters frees the key")
    }

    static func lockGateHandsOverBeforeTimeout() async {
        let key = "handover-\(UUID().uuidString)"
        _ = await TaskOperationLockGate.acquire(key, timeout: nil)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            TaskOperationLockGate.release(key)
        }
        expect(await TaskOperationLockGate.acquire(key, timeout: .seconds(5)), true, "A release within the timeout hands the key over")
        expect(TaskOperationLockGate.isHeld(key), true, "The waiter now holds the key")
        TaskOperationLockGate.release(key)
        expect(TaskOperationLockGate.isHeld(key), false, "The new holder's release frees the key")
    }

    static func timedOutWaiterNeverTakesTheKey() async {
        let key = "abandoned-\(UUID().uuidString)"
        _ = await TaskOperationLockGate.acquire(key, timeout: nil)
        expect(await TaskOperationLockGate.acquire(key, timeout: .milliseconds(50)), false, "The waiter times out")
        TaskOperationLockGate.release(key)
        expect(TaskOperationLockGate.isHeld(key), false, "A waiter that gave up is never handed the key")
    }

    static func untimedAcquireStillWaits() async {
        let key = "untimed-\(UUID().uuidString)"
        await TaskOperationLockGate.acquire(key)
        var acquired = false
        let waiter = Task { @MainActor in
            await TaskOperationLockGate.acquire(key)
            acquired = true
        }
        try? await Task.sleep(for: .milliseconds(200))
        expect(acquired, false, "A wait without a timeout keeps waiting for the holder")
        TaskOperationLockGate.release(key)
        await waiter.value
        expect(acquired, true, "The untimed waiter takes the key once it is released")
        TaskOperationLockGate.release(key)
    }

    static func resultReturnsFastValue() async {
        let value = await BoundedWait.result(within: .seconds(5)) { () async -> Int in
            try? await Task.sleep(for: .milliseconds(20))
            return 7
        }
        expect(value, 7, "An operation that finishes in time returns its value")
    }

    static func resultGivesUpOnSlowOperation() async {
        let start = ContinuousClock.now
        var finished = false
        let value = await BoundedWait.result(within: .milliseconds(100)) { () async -> Int in
            try? await Task.sleep(for: .seconds(1))
            finished = true
            return 7
        }
        expect(value, nil, "An operation that outlasts the timeout returns nil")
        expect(elapsed(since: start) < .milliseconds(900), true, "The wait ends at the timeout, not when the operation does")
        expect(finished, false, "The result is reported before the slow operation ends")
        try? await Task.sleep(for: .seconds(1.2))
        expect(finished, true, "The operation keeps running after the timeout")
    }
}
