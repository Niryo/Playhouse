import Darwin
import Foundation

/// `proc_pid_rusage`'s `ri_user_time`/`ri_system_time` are raw Mach absolute
/// time ticks, not pre-converted nanoseconds — on this machine (M2 Pro) the
/// tick:nanosecond ratio is 125:3 (~41.7x), confirmed empirically against
/// `ps`'s own %CPU/TIME accounting for a known 100%-busy process. Scaling by
/// this ratio is required on every machine, since the ratio isn't 1:1 even
/// on current Apple Silicon.
private let machTimebaseRatio: (numerator: UInt64, denominator: UInt64) = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return (UInt64(info.numer), UInt64(info.denom))
}()

/// Cumulative user+system CPU time consumed by `pid` since it started, in
/// nanoseconds. Returns `nil` if the process no longer exists or its
/// resource usage can't be read (e.g. already reaped, or owned by another
/// user).
func cumulativeCPUTimeNanoseconds(pid: pid_t) -> UInt64? {
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) { pointer -> Int32 in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rusagePointer in
            proc_pid_rusage(pid, RUSAGE_INFO_V4, rusagePointer)
        }
    }
    guard result == 0 else { return nil }
    let rawTicks = usage.ri_user_time + usage.ri_system_time
    return rawTicks * machTimebaseRatio.numerator / machTimebaseRatio.denominator
}

/// Direct child process IDs of `pid`, via libproc's two-call sizing pattern.
func childProcessIDs(of pid: pid_t) -> [pid_t] {
    let count = proc_listchildpids(pid, nil, 0)
    guard count > 0 else { return [] }
    var buffer = [pid_t](repeating: 0, count: Int(count))
    let bufferSize = Int32(count) * Int32(MemoryLayout<pid_t>.size)
    let actual = proc_listchildpids(pid, &buffer, bufferSize)
    guard actual > 0 else { return [] }
    return Array(buffer.prefix(Int(actual)))
}

/// Every descendant of `pid` (breadth-first, excluding `pid` itself),
/// capped at `limit` to guard against a pathologically large or
/// cyclic-looking tree (e.g. from racing PID reuse).
func descendantProcessIDs(of pid: pid_t, limit: Int = 2000) -> [pid_t] {
    var discovered: [pid_t] = []
    var frontier: [pid_t] = [pid]
    var seen: Set<pid_t> = [pid]
    while !frontier.isEmpty, discovered.count < limit {
        var next: [pid_t] = []
        for parent in frontier {
            for child in childProcessIDs(of: parent) where !seen.contains(child) {
                seen.insert(child)
                discovered.append(child)
                next.append(child)
            }
        }
        frontier = next
    }
    return discovered
}

/// A point-in-time reading of cumulative CPU time across a process tree.
struct ProcessTreeCPUSample: Equatable {
    var rootPID: pid_t
    var timestamp: Date
    var totalCPUNanoseconds: UInt64

    /// Sums cumulative CPU time over `rootPID` and all of its current
    /// descendants. Returns `nil` only if the root itself can no longer be
    /// read (i.e. the task's process has exited); individual descendants
    /// that can't be read (already exited between the tree walk and the
    /// read) are simply skipped rather than failing the whole sample.
    ///
    /// Known approximation: a subprocess that starts and exits entirely
    /// between two samples contributes no time to either sample, slightly
    /// undercounting short-lived descendant churn. This mirrors the same
    /// imprecision Activity Monitor has for fast-churning process trees.
    static func capture(rootPID: pid_t) -> ProcessTreeCPUSample? {
        guard let rootTime = cumulativeCPUTimeNanoseconds(pid: rootPID) else { return nil }
        var total = rootTime
        for descendant in descendantProcessIDs(of: rootPID) {
            total += cumulativeCPUTimeNanoseconds(pid: descendant) ?? 0
        }
        return ProcessTreeCPUSample(rootPID: rootPID, timestamp: Date(), totalCPUNanoseconds: total)
    }
}

/// Converts two samples of the same process tree into an Activity
/// Monitor-style CPU percentage: 100% means one fully busy core, and the
/// result is uncapped since a tree with several busy subprocesses can
/// legitimately exceed 100% across multiple cores.
func cpuPercent(previous: ProcessTreeCPUSample, current: ProcessTreeCPUSample) -> Double {
    let wallSeconds = current.timestamp.timeIntervalSince(previous.timestamp)
    guard wallSeconds > 0, current.totalCPUNanoseconds >= previous.totalCPUNanoseconds else { return 0 }
    let cpuSeconds = Double(current.totalCPUNanoseconds - previous.totalCPUNanoseconds) / 1_000_000_000
    return (cpuSeconds / wallSeconds) * 100
}

/// Tracks the last CPU sample per task/thread so successive polls can be
/// diffed into a percentage. All sampling happens in the process that owns
/// the real PIDs (the bridge daemon), never in the GUI process.
actor TaskCPUUsageSampler {
    static let shared = TaskCPUUsageSampler()

    private var lastSampleByThreadID: [String: ProcessTreeCPUSample] = [:]

    /// Returns the CPU percentage attributable to `rootPID`'s process tree
    /// since the previous sample for `threadID`, or `nil` if this is the
    /// first sample for that thread (no delta yet) or the root process no
    /// longer exists (in which case any stale prior sample is cleared). A
    /// thread whose root process changed (a Codex task's app-server stopped
    /// while idle and a new one started) starts over with a new baseline.
    func sample(threadID: String, rootPID: pid_t) -> Double? {
        guard let current = ProcessTreeCPUSample.capture(rootPID: rootPID) else {
            lastSampleByThreadID.removeValue(forKey: threadID)
            return nil
        }
        defer { lastSampleByThreadID[threadID] = current }
        guard let previous = lastSampleByThreadID[threadID], previous.rootPID == rootPID else { return nil }
        return cpuPercent(previous: previous, current: current)
    }

    func forget(threadID: String) {
        lastSampleByThreadID.removeValue(forKey: threadID)
    }
}
