import Darwin
import Foundation

// Keep this file free of other app types: scripts/test-e2e.sh compiles it on
// its own with scripts/unit/codex-cpu-attribution-tests.swift.

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

/// Every descendant of `pid` (breadth-first, excluding `pid` itself) paired
/// with its parent, capped at `limit` to guard against a pathologically
/// large or cyclic-looking tree (e.g. from racing PID reuse). Breadth-first
/// order guarantees a parent always appears before its children.
func descendantProcessTree(of pid: pid_t, limit: Int = 2000) -> [(pid: pid_t, parentPID: pid_t)] {
    var discovered: [(pid: pid_t, parentPID: pid_t)] = []
    var frontier: [pid_t] = [pid]
    var seen: Set<pid_t> = [pid]
    while !frontier.isEmpty, discovered.count < limit {
        var next: [pid_t] = []
        for parent in frontier {
            for child in childProcessIDs(of: parent) where !seen.contains(child) {
                seen.insert(child)
                discovered.append((child, parent))
                next.append(child)
            }
        }
        frontier = next
    }
    return discovered
}

func descendantProcessIDs(of pid: pid_t, limit: Int = 2000) -> [pid_t] {
    descendantProcessTree(of: pid, limit: limit).map(\.pid)
}

/// A process's PID plus its start time, so a recycled PID is never mistaken
/// for the process that held it at the previous sample.
struct ProcessInstance: Hashable {
    var pid: pid_t
    var startSeconds: UInt64
    var startMicroseconds: UInt64
}

/// The process's identity and short name (`p_name`, up to 32 bytes) via
/// `PROC_PIDTBSDINFO`, or `nil` once it has exited.
func processBSDInfo(pid: pid_t) -> (instance: ProcessInstance, name: String)? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    let name = withUnsafeBytes(of: info.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    let command = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    return (ProcessInstance(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec),
            name.isEmpty ? command : name)
}

/// The process's current working directory via `PROC_PIDVNODEPATHINFO`, as
/// the kernel reports it (already canonical: `/tmp` reads `/private/tmp`).
func processWorkingDirectory(pid: pid_t) -> String? {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
    let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    return path.isEmpty ? nil : path
}

/// Splits the processes under one shared `codex app-server` between the
/// Codex tasks whose turns are running on it. Every Codex task shares that
/// one process, so its PID alone says nothing about which task is busy; the
/// command subprocesses it spawns, however, run in the turn's `cwd`, which
/// is the task's worktree. The rules, in order:
///
/// - With exactly one turn-active thread on the app-server, every process
///   under it — the app-server itself and long-lived helpers such as
///   `codex-code-mode-host` included — belongs to that thread: no other
///   thread has a turn that could be using them.
/// - With several, the app-server and any `codex*`-named descendant (its
///   helpers, or the native binary under an npm `node` launcher) are shared
///   overhead and left unattributed: their working directory is just the
///   app-server's launch directory, i.e. whichever task first started it.
/// - Any other process belongs to the thread whose workspace root contains
///   its working directory, compared by whole path components after
///   resolving symlinks (so `/tmp/x` matches `/private/tmp/x/sub`, and
///   `/foo/bar` never claims `/foo/bar2`). The longest matching root wins;
///   a tie between two threads (two tasks sharing one folder) is ambiguous
///   and left unattributed rather than double-counted.
/// - A process whose directory matches no root inherits its parent's
///   attribution, so a tool that `chdir`s away mid-command still counts for
///   the task whose shell started it. A shell that itself `cd`s outside
///   every worktree, though, is unattributed along with everything it runs.
enum CodexProcessAttribution {
    struct Process: Equatable {
        var pid: pid_t
        var parentPID: pid_t
        var name: String
        var workingDirectory: String?
    }

    /// The thread owning each process, by PID. Processes left out are
    /// unattributed.
    static func attribute(rootPID: pid_t, descendants: [Process], rootsByThreadID: [String: [String]]) -> [pid_t: String] {
        guard !rootsByThreadID.isEmpty else { return [:] }
        if rootsByThreadID.count == 1, let threadID = rootsByThreadID.keys.first {
            var all = [rootPID: threadID]
            for process in descendants { all[process.pid] = threadID }
            return all
        }
        let canonicalRoots = rootsByThreadID.mapValues { $0.map(canonicalComponents) }
        var owners: [pid_t: String] = [:]
        for process in descendants {
            if isSharedCodexProcess(name: process.name) { continue }
            if let directory = process.workingDirectory,
               let owner = owningThread(components: canonicalComponents(directory), canonicalRoots: canonicalRoots) {
                owners[process.pid] = owner
            } else if let inherited = owners[process.parentPID] {
                owners[process.pid] = inherited
            }
        }
        return owners
    }

    /// The thread whose root contains `workingDirectory`, by the
    /// longest-component-prefix rule above.
    static func owningThread(workingDirectory: String, rootsByThreadID: [String: [String]]) -> String? {
        owningThread(components: canonicalComponents(workingDirectory),
                     canonicalRoots: rootsByThreadID.mapValues { $0.map(canonicalComponents) })
    }

    static func isSharedCodexProcess(name: String) -> Bool {
        name.lowercased().hasPrefix("codex")
    }

    private static func owningThread(components: [String], canonicalRoots: [String: [[String]]]) -> String? {
        var best: (threadID: String, length: Int)?
        var tied = false
        for (threadID, roots) in canonicalRoots {
            for root in roots where !root.isEmpty && root.count <= components.count && Array(components.prefix(root.count)) == root {
                if let current = best, current.length > root.count { continue }
                if let current = best, current.length == root.count {
                    if current.threadID != threadID { tied = true }
                    continue
                }
                best = (threadID, root.count)
                tied = false
            }
        }
        return tied ? nil : best?.threadID
    }

    /// Path components of `path` after resolving symlinks. A path that no
    /// longer exists can't be resolved, so it is only standardized, with
    /// macOS's `/tmp`, `/var` and `/etc` symlinks into `/private` applied.
    static func canonicalComponents(_ path: String) -> [String] {
        var canonical: String
        if let resolved = realpath(path, nil) {
            canonical = String(cString: resolved)
            free(resolved)
        } else {
            canonical = URL(fileURLWithPath: path).standardizedFileURL.path
            for alias in ["/tmp", "/var", "/etc"] where canonical == alias || canonical.hasPrefix(alias + "/") {
                canonical = "/private" + canonical
            }
        }
        return canonical.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
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
    /// longer exists (in which case any stale prior sample is cleared).
    func sample(threadID: String, rootPID: pid_t) -> Double? {
        guard let current = ProcessTreeCPUSample.capture(rootPID: rootPID) else {
            lastSampleByThreadID.removeValue(forKey: threadID)
            return nil
        }
        defer { lastSampleByThreadID[threadID] = current }
        guard let previous = lastSampleByThreadID[threadID] else { return nil }
        return cpuPercent(previous: previous, current: current)
    }

    func forget(threadID: String) {
        lastSampleByThreadID.removeValue(forKey: threadID)
    }

    /// The previous reading of one shared Codex app-server's tree: each
    /// process's cumulative CPU time and which threads were turn-active.
    private struct CodexAppServerSample {
        var root: ProcessInstance
        var timestamp: Date
        var cpuByProcess: [ProcessInstance: UInt64]
        var threadIDs: Set<String>
    }

    private var lastCodexSampleByRootPID: [pid_t: CodexAppServerSample] = [:]

    /// CPU percentages for the turn-active Codex threads on the app-server
    /// `rootPID`, split by `CodexProcessAttribution`. One tree walk per call.
    ///
    /// Unlike the Claude path's whole-tree sum, this diffs each process
    /// against its own previous reading, because the attributed set changes
    /// between samples (commands come and go, and helpers switch between
    /// owned and shared as other threads start or finish): a process seen
    /// for the first time contributes all of its CPU time, since it started
    /// after the previous walk.
    ///
    /// A thread gets a value only once it was also turn-active at the
    /// previous sample, matching the Claude path's "first sample is a
    /// baseline" semantics. After that it always gets one, `0` when none of
    /// the tree is attributable to it, so its bar stays visible (and empty)
    /// rather than disappearing while its turn runs.
    func sampleCodexAppServer(rootPID: pid_t, rootsByThreadID: [String: [String]]) -> [String: Double] {
        // App-servers that exited or were replaced since their last sample.
        lastCodexSampleByRootPID = lastCodexSampleByRootPID.filter { pid, sample in
            pid == rootPID || processBSDInfo(pid: pid)?.instance == sample.root
        }
        guard !rootsByThreadID.isEmpty, let root = processBSDInfo(pid: rootPID) else {
            lastCodexSampleByRootPID.removeValue(forKey: rootPID)
            return [:]
        }
        let attributeByDirectory = rootsByThreadID.count > 1
        var descendants: [CodexProcessAttribution.Process] = []
        var instanceByPID: [pid_t: ProcessInstance] = [rootPID: root.instance]
        for (pid, parentPID) in descendantProcessTree(of: rootPID) {
            guard let info = processBSDInfo(pid: pid) else { continue }
            instanceByPID[pid] = info.instance
            descendants.append(CodexProcessAttribution.Process(
                pid: pid, parentPID: parentPID, name: info.name,
                workingDirectory: attributeByDirectory ? processWorkingDirectory(pid: pid) : nil
            ))
        }
        let owners = CodexProcessAttribution.attribute(rootPID: rootPID, descendants: descendants, rootsByThreadID: rootsByThreadID)
        var cpuByProcess: [ProcessInstance: UInt64] = [:]
        for (pid, instance) in instanceByPID {
            if let time = cumulativeCPUTimeNanoseconds(pid: pid) { cpuByProcess[instance] = time }
        }
        let current = CodexAppServerSample(
            root: root.instance, timestamp: Date(), cpuByProcess: cpuByProcess, threadIDs: Set(rootsByThreadID.keys)
        )
        defer { lastCodexSampleByRootPID[rootPID] = current }
        guard let previous = lastCodexSampleByRootPID[rootPID], previous.root == root.instance else { return [:] }
        let wallSeconds = current.timestamp.timeIntervalSince(previous.timestamp)
        guard wallSeconds > 0 else { return [:] }

        var nanosecondsByThreadID: [String: UInt64] = [:]
        for (pid, threadID) in owners {
            guard let instance = instanceByPID[pid], let time = cpuByProcess[instance] else { continue }
            let earlier = previous.cpuByProcess[instance] ?? 0
            nanosecondsByThreadID[threadID, default: 0] += time >= earlier ? time - earlier : 0
        }
        var result: [String: Double] = [:]
        for threadID in current.threadIDs.intersection(previous.threadIDs) {
            let cpuSeconds = Double(nanosecondsByThreadID[threadID] ?? 0) / 1_000_000_000
            result[threadID] = (cpuSeconds / wallSeconds) * 100
        }
        return result
    }
}
