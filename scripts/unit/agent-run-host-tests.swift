import Darwin
import Foundation

// Focused unit checks of Playhouse/App/AgentRunHost.swift, compiled together with it and run
// by scripts/test-e2e.sh before the bridge suite. They pin the process identity, spawn
// isolation, ownership lock, sweep, socket path, manifest and line-tailing rules that let an
// agent outlive its daemon; the bridge cases `test_codex_turn_reattaches_after_daemon_restart`
// and `test_claude_turn_reattaches_after_daemon_restart` cover the same rules end to end.

@main
struct AgentRunHostTests {
    static var failures: [String] = []
    static var checks = 0

    static func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        checks += 1
        if actual != expected { failures.append("\(message): expected \(expected), got \(actual)") }
    }

    static func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(20_000)
        }
        return condition()
    }

    static func main() async throws {
        let base = "/tmp/playhouse-agent-run-host-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        // Identity: this process is alive; a different start time or a missing pid is not.
        let me = AgentProcessIdentity.current(pid: getpid())
        expect(me != nil, true, "The current process has an identity")
        expect(me?.isAlive, true, "The current process is alive")
        if let me {
            expect(AgentProcessIdentity(pid: me.pid, startTime: me.startTime + 1).isAlive, false,
                   "A different start time names a different process")
        }
        expect(AgentProcessIdentity(pid: 99_999_999, startTime: 1).isAlive, false, "A missing pid is not alive")

        // Spawn: own session, only stdio inherited, cwd applied, survives SIGTERM to our group.
        // A high descriptor, so it can't collide with the one `ls /dev/fd` opens for itself.
        let opened = open("\(base)/leaked", O_RDWR | O_CREAT, 0o600)
        let leaked = dup2(opened, 77)
        close(opened)
        let script = "echo \"$$ $(ps -o sess= -p $$) $(pwd -P)\"; ls /dev/fd | tr '\\n' ' '; sleep 30"
        let identity = try AgentRunHost.spawn(
            executable: "/bin/sh", arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: base,
            stdin: .path("/dev/null", flags: O_RDONLY),
            stdout: .path("\(base)/out", flags: O_WRONLY | O_CREAT | O_APPEND),
            stderr: .path("\(base)/err", flags: O_WRONLY | O_CREAT | O_APPEND)
        )
        expect(identity.isAlive, true, "A spawned agent is alive")
        expect(getsid(identity.pid), identity.pid, "A spawned agent leads its own session")
        expect(getpgid(identity.pid), identity.pid, "A spawned agent leads its own process group")
        _ = waitUntil { ((try? String(contentsOfFile: "\(base)/out", encoding: .utf8)) ?? "").contains("\n") }
        let output = (try? String(contentsOfFile: "\(base)/out", encoding: .utf8)) ?? ""
        expect(output.contains(("/private" + base)), true, "A spawned agent starts in its working directory")
        let descriptors = output.split(separator: "\n").dropFirst().first.map { $0.split(separator: " ").compactMap { Int($0) } } ?? []
        expect(descriptors.contains(Int(leaked)), false, "A spawned agent inherits no descriptor beyond its standard streams")
        close(leaked)

        // Exit watching reaps a child and reports once; terminate stops the whole group.
        let exited = Locked<Int>(0)
        let source = AgentRunHost.onExit(identity) { _ in exited.mutate { $0 += 1 } }
        await AgentRunHost.terminate(identity, grace: 1)
        expect(identity.isAlive, false, "Terminate stops a live agent")
        expect(waitUntil { exited.value == 1 }, true, "Exit is reported once")
        _ = source
        // Terminate never signals a pid whose identity no longer matches.
        await AgentRunHost.terminate(AgentProcessIdentity(pid: getpid(), startTime: 1))
        expect(me?.isAlive, true, "Terminate ignores a stale identity, even one naming a live pid")
        // A process that already exited still reports its exit.
        let quick = try AgentRunHost.spawn(
            executable: "/usr/bin/true", arguments: [], environment: [:], workingDirectory: base,
            stdin: .path("/dev/null", flags: O_RDONLY), stdout: .path("/dev/null", flags: O_WRONLY), stderr: .path("/dev/null", flags: O_WRONLY)
        )
        usleep(200_000)
        let quickExit = Locked<Int32?>(nil)
        let quickSource = AgentRunHost.onExit(quick) { status in quickExit.mutate { $0 = status } }
        expect(waitUntil { quickExit.value != nil }, true, "An agent that exited before it was watched still reports its exit")
        _ = quickSource

        // A FIFO stdin the child also holds open never reaches EOF when its writer goes away.
        let fifo = "\(base)/agent.in"
        mkfifo(fifo, 0o600)
        let reader = try AgentRunHost.spawn(
            executable: "/bin/sh", arguments: ["-c", "while IFS= read -r line; do echo \"got:$line\"; done; echo EOF"],
            environment: ["PATH": "/usr/bin:/bin"], workingDirectory: base,
            stdin: .path(fifo, flags: O_RDWR),
            stdout: .path("\(base)/fifo.out", flags: O_WRONLY | O_CREAT | O_APPEND),
            stderr: .path("/dev/null", flags: O_WRONLY)
        )
        for message in ["one", "two"] {
            let writer = open(fifo, O_WRONLY | O_NONBLOCK)
            _ = fcntl(writer, F_SETFL, fcntl(writer, F_GETFL) & ~O_NONBLOCK)
            _ = "\(message)\n".withCString { write(writer, $0, strlen($0)) }
            close(writer)
            usleep(100_000)
        }
        _ = waitUntil { ((try? String(contentsOfFile: "\(base)/fifo.out", encoding: .utf8)) ?? "").contains("got:two") }
        let fifoOutput = (try? String(contentsOfFile: "\(base)/fifo.out", encoding: .utf8)) ?? ""
        expect(fifoOutput, "got:one\ngot:two\n", "A FIFO child reads every writer's lines and never sees EOF between writers")
        expect(reader.isAlive, true, "A FIFO child survives its writer closing")
        await AgentRunHost.terminate(reader)

        // Ownership lock: exclusive, also within one process, and released when the holder dies.
        let lockPath = "\(base)/run.owner.lock"
        let first = try AgentOwnershipLock.tryAcquire(path: lockPath)
        expect(first != nil, true, "A free lock is acquired")
        expect(try AgentOwnershipLock.tryAcquire(path: lockPath) == nil, true, "A held lock is refused to a second holder")
        expect(AgentOwnershipLock.isHeld(path: lockPath), true, "A held lock reports as held")
        first?.release()
        expect(AgentOwnershipLock.isHeld(path: lockPath), false, "A released lock is free")
        let holder = try AgentRunHost.spawn(
            executable: "/usr/bin/python3",
            arguments: ["-c", "import fcntl,os,sys,time; f=open(sys.argv[1],'a'); fcntl.flock(f, fcntl.LOCK_EX); open(sys.argv[2],'w').close(); time.sleep(30)", lockPath, "\(base)/locked"],
            environment: ["PATH": "/usr/bin:/bin"], workingDirectory: base,
            stdin: .path("/dev/null", flags: O_RDONLY), stdout: .path("/dev/null", flags: O_WRONLY), stderr: .path("/dev/null", flags: O_WRONLY)
        )
        _ = waitUntil { FileManager.default.fileExists(atPath: "\(base)/locked") }
        expect(try AgentOwnershipLock.tryAcquire(path: lockPath) == nil, true, "Another process's lock is refused")
        kill(holder.pid, SIGKILL)
        _ = waitUntil { !holder.isAlive }
        AgentRunHost.reapIfChild(holder.pid)
        let afterDeath = try await AgentOwnershipLock.acquire(path: lockPath, timeout: 3)
        expect(afterDeath.path, lockPath, "The kernel frees a dead holder's lock")
        afterDeath.release()

        // Sweep: finds a process whose stdout is inside a run folder, not one writing elsewhere.
        let runs = "\(base)/provider-runs"
        try FileManager.default.createDirectory(atPath: "\(runs)/r1", withIntermediateDirectories: true)
        let inside = try AgentRunHost.spawn(
            executable: "/bin/sleep", arguments: ["30"], environment: [:], workingDirectory: base,
            stdin: .path("/dev/null", flags: O_RDONLY),
            stdout: .path("\(runs)/r1/agent.out", flags: O_WRONLY | O_CREAT | O_APPEND),
            stderr: .path("/dev/null", flags: O_WRONLY)
        )
        let outside = try AgentRunHost.spawn(
            executable: "/bin/sleep", arguments: ["30"], environment: [:], workingDirectory: base,
            stdin: .path("/dev/null", flags: O_RDONLY),
            stdout: .path("\(base)/elsewhere.out", flags: O_WRONLY | O_CREAT | O_APPEND),
            stderr: .path("/dev/null", flags: O_WRONLY)
        )
        let swept = AgentProcessSweep.processes(withStandardStreamsUnder: [runs]).map(\.identity)
        expect(swept.contains(inside), true, "The sweep finds an agent writing into a run folder")
        expect(swept.contains(outside), false, "The sweep ignores a process writing elsewhere")
        await AgentRunHost.terminate(inside)
        await AgentRunHost.terminate(outside)

        // Socket path: a short path is kept, a long one moves to a private per-user folder.
        expect(AgentSocketPath.resolve(preferred: "/tmp/x.sock", fileName: "x.sock"), "/tmp/x.sock", "A short socket path is kept")
        let long = "/tmp/" + String(repeating: "d", count: 120) + "/k.sock"
        let resolved = AgentSocketPath.resolve(preferred: long, fileName: "k.sock")
        expect(resolved, "/tmp/playhouse-codex/\(getuid())/k.sock", "A long socket path moves to the per-user folder")
        expect(resolved.utf8.count <= AgentSocketPath.maximumLength, true, "The fallback socket path fits sun_path")
        var info = stat()
        stat("/tmp/playhouse-codex/\(getuid())", &info)
        expect(info.st_mode & 0o777, 0o700, "The fallback socket folder is private")

        // Manifest: atomic replace, never a partial file, no temporary left behind.
        struct Sample: Codable, Equatable { var value: Int }
        let manifest = URL(fileURLWithPath: "\(base)/m/run.json")
        try AgentManifestFile.write(Sample(value: 1), to: manifest)
        try AgentManifestFile.write(Sample(value: 2), to: manifest)
        expect(AgentManifestFile.read(Sample.self, from: manifest), Sample(value: 2), "A manifest reads back its last write")
        expect((try? FileManager.default.contentsOfDirectory(atPath: "\(base)/m"))?.count, 1, "An atomic write leaves no temporary file")

        // LineTailer: complete lines only, end offsets, resume from an offset.
        var tailer = LineTailer()
        var lines = tailer.append(Data("a\nbb\ncc".utf8))
        expect(lines.map { String(decoding: $0.line, as: UTF8.self) }, ["a", "bb"], "Only complete lines are emitted")
        expect(lines.map(\.endOffset), [2, 5], "Each line carries the offset just past it")
        expect(tailer.consumedOffset, 5, "The partial tail is not consumed")
        lines = tailer.append(Data("c\n\nd\n".utf8))
        expect(lines.map { String(decoding: $0.line, as: UTF8.self) }, ["ccc", "", "d"], "A buffered tail joins its newline")
        expect(lines.map(\.endOffset), [9, 10, 12], "Offsets continue across reads")
        let log = "\(base)/agent.out"
        try Data("x\nyy\nz".utf8).write(to: URL(fileURLWithPath: log))
        let descriptor = open(log, O_RDONLY)
        var resumed = LineTailer(offset: 2)
        expect(resumed.read(from: descriptor).map { String(decoding: $0.line, as: UTF8.self) }, ["yy"], "Reading resumes at a committed offset")
        expect(resumed.consumedOffset, 5, "A partial last line waits for more")
        close(descriptor)

        if failures.isEmpty {
            print("agent-run-host unit tests: \(checks) checks passed")
        } else {
            for failure in failures { print("FAIL: \(failure)") }
            print("agent-run-host unit tests: \(failures.count) of \(checks) checks failed")
            exit(1)
        }
    }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ body: (inout Value) -> Void) { lock.lock(); body(&stored); lock.unlock() }
}
