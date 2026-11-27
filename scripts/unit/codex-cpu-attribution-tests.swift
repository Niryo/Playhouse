import Darwin
import Foundation

// Focused unit checks of `CodexProcessAttribution`, compiled together with
// Playhouse/Core/Providers/ProcessCPUSampler.swift and run by scripts/test-e2e.sh before
// the bridge suite. They pin the working-directory -> task rules without a
// live app-server; the bridge case `test_task_cpu_usage_attributes_codex_load_by_worktree`
// covers the same rules end to end against real processes.

@main
struct CodexCPUAttributionTests {
    static var failures: [String] = []
    static var checks = 0

    static func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        checks += 1
        if actual != expected { failures.append("\(message): expected \(expected), got \(actual)") }
    }

    static func main() throws {
        // Real directories under /tmp, so realpath() resolves the /tmp ->
        // /private/tmp symlink exactly as it does for a task worktree there.
        let base = "/tmp/playhouse-cpu-attribution-\(UUID().uuidString)"
        let fileManager = FileManager.default
        for directory in ["foo/bar/src", "foo/bar2/src", "repo/nested/deep", "repo/other", "shared", "elsewhere"] {
            try fileManager.createDirectory(atPath: "\(base)/\(directory)", withIntermediateDirectories: true)
        }
        defer { try? fileManager.removeItem(atPath: base) }
        let kernelBase = "/private" + base

        // /tmp normalization and whole-component prefix matching.
        let siblings = ["a": ["\(base)/foo/bar"], "b": ["\(base)/foo/bar2"]]
        expect(CodexProcessAttribution.owningThread(workingDirectory: "\(kernelBase)/foo/bar/src", rootsByThreadID: siblings), "a",
               "A /private/tmp working directory matches its /tmp worktree root")
        expect(CodexProcessAttribution.owningThread(workingDirectory: "\(kernelBase)/foo/bar2/src", rootsByThreadID: siblings), "b",
               "/foo/bar never claims /foo/bar2")
        expect(CodexProcessAttribution.owningThread(workingDirectory: "\(kernelBase)/foo/bar", rootsByThreadID: siblings), "a",
               "The worktree root itself belongs to its task")
        expect(CodexProcessAttribution.owningThread(workingDirectory: "\(kernelBase)/foo", rootsByThreadID: siblings), nil,
               "A parent of every root belongs to no task")

        // Longest root wins when one task's root nests inside another's.
        let nested = ["outer": ["\(base)/repo"], "inner": ["\(base)/repo/nested"]]
        expect(CodexProcessAttribution.owningThread(workingDirectory: "\(kernelBase)/repo/nested/deep", rootsByThreadID: nested), "inner",
               "The longest containing root wins")
        expect(CodexProcessAttribution.owningThread(workingDirectory: "\(kernelBase)/repo/other", rootsByThreadID: nested), "outer",
               "The outer root keeps paths outside the nested one")

        // A secondary runtime root counts the same as the cwd root.
        let multiRoot = ["a": ["\(base)/foo/bar", "\(base)/repo/other"], "b": ["\(base)/foo/bar2"]]
        expect(CodexProcessAttribution.owningThread(workingDirectory: "\(kernelBase)/repo/other", rootsByThreadID: multiRoot), "a",
               "Any of a task's workspace roots attributes to it")

        // Two tasks sharing one folder is ambiguous.
        let tied = ["a": ["\(base)/shared"], "b": ["\(base)/shared/"]]
        expect(CodexProcessAttribution.owningThread(workingDirectory: "\(kernelBase)/shared", rootsByThreadID: tied), nil,
               "Two tasks with the same root are left unattributed")

        // Paths that no longer exist still get /tmp -> /private/tmp applied.
        let missing = "/tmp/playhouse-cpu-attribution-missing-\(UUID().uuidString)"
        expect(CodexProcessAttribution.owningThread(workingDirectory: "/private\(missing)/sub", rootsByThreadID: ["a": [missing], "b": [base]]), "a",
               "A missing /tmp root still matches its /private/tmp spelling")
        expect(CodexProcessAttribution.owningThread(workingDirectory: "\(missing)/../\(URL(fileURLWithPath: missing).lastPathComponent)/sub",
                                                    rootsByThreadID: ["a": [missing], "b": [base]]), "a",
               "Dot-dot components are standardized before matching")

        // Tree attribution with several turn-active threads.
        let appServer: pid_t = 100
        let tree: [CodexProcessAttribution.Process] = [
            .init(pid: 101, parentPID: 100, name: "codex-code-mode-host", workingDirectory: "\(kernelBase)/foo/bar"),
            .init(pid: 102, parentPID: 101, name: "python3", workingDirectory: nil),
            .init(pid: 103, parentPID: 100, name: "zsh", workingDirectory: "\(kernelBase)/foo/bar/src"),
            .init(pid: 104, parentPID: 103, name: "sleep", workingDirectory: nil),
            .init(pid: 105, parentPID: 103, name: "make", workingDirectory: "\(kernelBase)/elsewhere"),
            .init(pid: 106, parentPID: 100, name: "zsh", workingDirectory: "\(kernelBase)/foo/bar2"),
            .init(pid: 107, parentPID: 100, name: "zsh", workingDirectory: "\(kernelBase)/elsewhere"),
            .init(pid: 108, parentPID: 107, name: "cc", workingDirectory: nil),
            .init(pid: 109, parentPID: 100, name: "codex", workingDirectory: "\(kernelBase)/foo/bar2"),
        ]
        let owners = CodexProcessAttribution.attribute(rootPID: appServer, descendants: tree, rootsByThreadID: siblings)
        expect(owners[appServer], nil, "The shared app-server is overhead when several threads are active")
        expect(owners[101], nil, "codex-code-mode-host is shared overhead even though its cwd is a task root")
        expect(owners[102], nil, "A helper's directory-less child inherits the helper's shared status")
        expect(owners[103], "a", "A command shell belongs to the task owning its cwd")
        expect(owners[104], "a", "A child with an unreadable cwd inherits its parent's task")
        expect(owners[105], "a", "A child that chdir'd outside every root still counts for its shell's task")
        expect(owners[106], "b", "A second task's shell belongs to the second task")
        expect(owners[107], nil, "A shell that cd'd outside every worktree is not attributed")
        expect(owners[108], nil, "Its children are not attributed either")
        expect(owners[109], nil, "A codex-named descendant (npm launcher's native binary) is shared overhead")

        // With exactly one turn-active thread, everything is that thread's.
        let single = CodexProcessAttribution.attribute(rootPID: appServer, descendants: tree, rootsByThreadID: ["a": ["\(base)/foo/bar"]])
        expect(single.count, tree.count + 1, "One active thread owns the whole tree, the app-server included")
        expect(Set(single.values), ["a"], "Every process goes to the single active thread")
        let rootless = CodexProcessAttribution.attribute(rootPID: appServer, descendants: tree, rootsByThreadID: ["a": []])
        expect(rootless[appServer], "a", "A single active thread still starting (no roots yet) owns the tree")

        expect(CodexProcessAttribution.attribute(rootPID: appServer, descendants: tree, rootsByThreadID: [:]), [:],
               "No active thread means nothing is attributed")

        // The libproc readers agree with the kernel for this process.
        let ownDirectory = processWorkingDirectory(pid: getpid())
        expect(ownDirectory.map { CodexProcessAttribution.canonicalComponents($0) },
               CodexProcessAttribution.canonicalComponents(fileManager.currentDirectoryPath),
               "PROC_PIDVNODEPATHINFO reports this process's cwd")
        expect(processBSDInfo(pid: getpid())?.instance.pid, getpid(), "PROC_PIDTBSDINFO identifies this process")

        if failures.isEmpty {
            print("Codex CPU attribution unit checks passed (\(checks) checks).")
        } else {
            for failure in failures { FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8)) }
            exit(1)
        }
    }
}
