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

    static let kqueueReaderFlag = "--kqueue-stdin-reader"

    /// One newline-terminated line of `bytes` characters.
    static func line(bytes: Int) -> Data { Data(repeating: UInt8(ascii: "x"), count: bytes) + Data([0x0A]) }

    /// "written", the write error, or "timed out" while the writer is still busy after `timeout`,
    /// so a writer stuck in a blocking write fails the check instead of hanging the suite.
    static func writeLine(_ writer: AgentInputWriter, _ line: Data, timeout: TimeInterval = 5) -> String {
        let outcome = Locked<String?>(nil)
        writer.enqueue(line) { error in outcome.mutate { $0 = error.map { "\($0)" } ?? "written" } }
        _ = waitUntil(timeout) { outcome.value != nil }
        return outcome.value ?? "timed out"
    }

    /// Reads stdin the way Bun and Node do: waits in kevent() for it to be readable, then reads.
    /// Prints "line <n> <length>" for each line, so a test sees what arrived and in what order.
    static func runKqueueStdinReader() -> Never {
        let queue = kqueue()
        var change = kevent(ident: 0, filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil)
        _ = kevent(queue, &change, 1, nil, 0, nil)
        var pending = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var count = 0
        while true {
            var event = kevent()
            guard kevent(queue, nil, 0, &event, 1, nil) == 1 else { continue }
            let read = Darwin.read(0, &buffer, buffer.count)
            if read <= 0 { exit(0) }
            pending.append(contentsOf: buffer[0..<read])
            while let newline = pending.firstIndex(of: 0x0A) {
                count += 1
                print("line \(count) \(newline)")
                fflush(stdout)
                pending.removeSubrange(0...newline)
            }
        }
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
        if CommandLine.arguments.contains(kqueueReaderFlag) { runKqueueStdinReader() }
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

        // Agent input: Claude Code's runtime reads stdin only once kqueue reports it readable,
        // and macOS doesn't report a FIFO readable while one oversized write() is pending. This
        // test binary, run as a kqueue reader, stands in for it.
        let inputFIFO = "\(base)/input.in"
        mkfifo(inputFIFO, 0o600)
        let kqueueReader = try AgentRunHost.spawn(
            executable: CommandLine.arguments[0], arguments: [kqueueReaderFlag],
            environment: [:], workingDirectory: base,
            stdin: .path(inputFIFO, flags: O_RDWR),
            stdout: .path("\(base)/input.out", flags: O_WRONLY | O_CREAT | O_APPEND),
            stderr: .path("/dev/null", flags: O_WRONLY)
        )
        let inputWriter = AgentInputWriter(path: inputFIFO)
        let readerLines: () -> [String] = {
            ((try? String(contentsOfFile: "\(base)/input.out", encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        expect(writeLine(inputWriter, line(bytes: 10)), "written", "A short line is written")
        expect(waitUntil { readerLines().count == 1 }, true, "The kqueue reader takes a short line")
        usleep(500_000) // The reader goes idle in kevent(), like Claude Code after `initialize`.
        expect(writeLine(inputWriter, line(bytes: 200_000)), "written", "A 200 KB line reaches an idle kqueue reader")
        let ordered = Locked<[String]>([])
        for bytes in [70_000, 5, 300_000] {
            inputWriter.enqueue(line(bytes: bytes)) { error in ordered.mutate { $0.append(error.map { "\($0)" } ?? "written") } }
        }
        _ = waitUntil(5) { ordered.value.count == 3 && readerLines().count == 5 }
        expect(ordered.value, ["written", "written", "written"], "Queued lines of any size are all written")
        expect(readerLines(), ["line 1 10", "line 2 200000", "line 3 70000", "line 4 5", "line 5 300000"],
               "Every line arrives whole, in the order it was queued")
        inputWriter.close()
        expect(writeLine(inputWriter, line(bytes: 10)), "closed", "A closed writer refuses lines")
        await AgentRunHost.terminate(kqueueReader)

        // An agent that never reads its input fails the line after the stall time, not never,
        // and the writer refuses the lines after a line that may have been cut off.
        let stalledFIFO = "\(base)/stalled.in"
        mkfifo(stalledFIFO, 0o600)
        let nonReader = try AgentRunHost.spawn(
            executable: "/bin/sleep", arguments: ["60"], environment: [:], workingDirectory: base,
            stdin: .path(stalledFIFO, flags: O_RDWR),
            stdout: .path("/dev/null", flags: O_WRONLY), stderr: .path("/dev/null", flags: O_WRONLY)
        )
        let stalledWriter = AgentInputWriter(path: stalledFIFO, stallTimeout: 1)
        let stallStarted = Date()
        expect(writeLine(stalledWriter, line(bytes: 200_000)), "stalled(seconds: 1)", "A line the agent never reads fails as stalled")
        expect(Date().timeIntervalSince(stallStarted) < 4, true, "A stalled line fails within its stall time")
        expect(writeLine(stalledWriter, line(bytes: 10)), "stalled(seconds: 1)", "Lines after a stalled line are refused")
        await AgentRunHost.terminate(nonReader)

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
