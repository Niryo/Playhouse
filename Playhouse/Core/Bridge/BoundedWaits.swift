import Foundation

// Waits with a bound, shared by operations that must never hang on work they don't own, such as
// deleting a task whose turn won't stop. Foundation only, so scripts/unit can test it alone.

@MainActor
package enum TaskOperationLockGate {
    private struct Waiter {
        let id = UUID()
        let continuation: CheckedContinuation<Bool, Never>
    }
    private static var heldKeys: Set<String> = []
    private static var waiters: [String: [Waiter]] = [:]

    package static func acquire(_ key: String) async {
        _ = await acquire(key, timeout: nil)
    }

    /// Takes the key, waiting at most `timeout` (forever when nil) for the holder to release
    /// it. False when the wait timed out; the key is then not held by the caller.
    package static func acquire(_ key: String, timeout: Duration?) async -> Bool {
        guard heldKeys.contains(key) else {
            heldKeys.insert(key)
            return true
        }
        return await withCheckedContinuation { continuation in
            let waiter = Waiter(continuation: continuation)
            waiters[key, default: []].append(waiter)
            guard let timeout else { return }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                guard var pending = waiters[key], let index = pending.firstIndex(where: { $0.id == waiter.id }) else { return }
                pending.remove(at: index)
                waiters[key] = pending.isEmpty ? nil : pending
                waiter.continuation.resume(returning: false)
            }
        }
    }

    package static func isHeld(_ key: String) -> Bool {
        heldKeys.contains(key)
    }

    package static func release(_ key: String) {
        guard var pending = waiters[key], !pending.isEmpty else {
            heldKeys.remove(key)
            return
        }
        let next = pending.removeFirst()
        waiters[key] = pending.isEmpty ? nil : pending
        next.continuation.resume(returning: true)
    }
}

@MainActor
package enum BoundedWait {
    private final class Once<Value> {
        var continuation: CheckedContinuation<Value, Never>?

        func resume(returning value: Value) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    /// `operation`'s result, or nil when `timeout` passes first. The operation keeps running
    /// after a timeout; its result is then dropped.
    package static func result<T>(within timeout: Duration, _ operation: @escaping @MainActor () async -> T) async -> T? {
        let once = Once<T?>()
        return await withCheckedContinuation { continuation in
            once.continuation = continuation
            Task { @MainActor in once.resume(returning: await operation()) }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                once.resume(returning: nil)
            }
        }
    }
}
