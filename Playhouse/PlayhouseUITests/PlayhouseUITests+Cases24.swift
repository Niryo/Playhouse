import AppKit
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import Network
import XCTest
import SQLite3
import Vision

extension PlayhouseUITests {
    // case-contract: test_external_git_edits_and_commit_refresh_workspace_changes | A newly created task branch with no branch or worktree changes starts with empty Viewed and Changes sections. External Git commits unique to the task branch and staged, unstaged, or untracked edits update the open task's Changes sidebar automatically; commits unique to the base branch are excluded. Fresh CLI connections report the same per-file inventory. When the base branch's local copy is stale behind its origin remote-tracking branch and the task branch has merged the newer upstream commits, those commits are excluded as well, so the inventory matches the pull request instead of the stale local branch. A local base branch that is ahead of its remote-tracking branch stays the base, so unpushed base commits merged into the task branch are not listed as task changes. While a merge is still open in the task's worktree, its files are held back and the sidebar shows a 'Merge in progress' notice naming the repository instead of the files the merge staged; the CLI reports the repository under mergingRepositories with empty sections, and aborting the merge lists the task's changes again.
    func test_external_git_edits_and_commit_refresh_workspace_changes() throws {
        let repository = runDirectory.appendingPathComponent("external-git", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let trackedFile = repository.appendingPathComponent("tracked.txt")
        try "Baseline.\n".write(to: trackedFile, atomically: true, encoding: .utf8)
        try runGit(repository, "init", "--initial-branch=main")
        try runGit(repository, "config", "user.name", "Playhouse UI Test")
        try runGit(repository, "config", "user.email", "playhouse-ui-test@example.invalid")
        try runGit(repository, "add", "tracked.txt")
        try runGit(repository, "commit", "-m", "Baseline")

        let created = try runCLI(["task", "create", "--title", "External Git", "--prompt", "Fixture task description."])
        let taskID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String)
        let added = try runCLI(["task", "repository", "add", taskID, "--repo", repository.path])
        let record = try XCTUnwrap(((added["result"] as? [String: Any])?["repositoryWorktrees"] as? [[String: Any]])?.first)
        XCTAssertEqual(record["branchFrom"] as? String, "main")
        let worktree = URL(fileURLWithPath: try XCTUnwrap(record["worktreePath"] as? String), isDirectory: true)

        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "External Git")
        XCTAssertTrue(element("workspace-changes-empty").waitToExist(timeout: 10))
        let initialInventory = try runCLI(["task", "changes", "list", taskID])["result"] as? [String: Any]
        XCTAssertEqual((initialInventory?["unviewed"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual((initialInventory?["viewed"] as? [[String: Any]])?.count, 0)

        let branchFile = worktree.appendingPathComponent("tracked.txt")
        try "Branch commit.\n".write(to: branchFile, atomically: true, encoding: .utf8)
        try runGit(worktree, "add", "tracked.txt")
        try runGit(worktree, "commit", "-m", "Task branch commit")
        let baseOnlyFile = repository.appendingPathComponent("base-only.txt")
        try "Base-only commit.\n".write(to: baseOnlyFile, atomically: true, encoding: .utf8)
        try runGit(repository, "add", "base-only.txt")
        try runGit(repository, "commit", "-m", "Base-only commit")

        XCTAssertTrue(element("workspace-change-unviewed-tracked.txt").waitToExist(timeout: 10))
        XCTAssertFalse(element("workspace-change-unviewed-base-only.txt").exists)
        let branchInventory = try runCLI(["task", "changes", "list", taskID])["result"] as? [String: Any]
        let branchEntries = branchInventory?["unviewed"] as? [[String: Any]] ?? []
        XCTAssertEqual(branchEntries.map { $0["path"] as? String }, ["tracked.txt"])
        XCTAssertEqual(branchEntries.first?["isUncommitted"] as? Bool, false)
        XCTAssertEqual(element("workspace-change-unviewed-tracked.txt").value as? String, "Committed, primary")

        try "Edited externally.\n".write(to: branchFile, atomically: true, encoding: .utf8)
        try "Untracked external file.\n".write(to: worktree.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(element("workspace-change-unviewed-untracked.txt").waitToExist(timeout: 10))
        XCTAssertTrue(element("workspace-change-unviewed-tracked.txt").waitToExist(timeout: 10))
        let dirty = try runCLI(["task", "changes", "list", taskID])["result"] as? [String: Any]
        XCTAssertEqual((dirty?["unviewed"] as? [[String: Any]])?.map { $0["path"] as? String }, ["tracked.txt", "untracked.txt"])
        XCTAssertTrue((dirty?["unviewed"] as? [[String: Any]])?.allSatisfy { $0["isUncommitted"] as? Bool == true } ?? false)
        XCTAssertEqual(element("workspace-change-unviewed-tracked.txt").value as? String, "Uncommitted, green")

        try runGit(worktree, "add", "tracked.txt", "untracked.txt")
        try runGit(worktree, "commit", "-m", "Second task branch commit")
        let committed = try runCLI(["task", "changes", "list", taskID])["result"] as? [String: Any]
        let committedEntries = committed?["unviewed"] as? [[String: Any]] ?? []
        XCTAssertEqual(committedEntries.map { $0["path"] as? String }, ["tracked.txt", "untracked.txt"])
        XCTAssertTrue(committedEntries.allSatisfy { $0["isUncommitted"] as? Bool == false })
        XCTAssertTrue(waitUntil({ self.element("workspace-change-unviewed-tracked.txt").value as? String == "Committed, primary" }, timeout: 10))
        XCTAssertFalse(committedEntries.contains { $0["path"] as? String == "base-only.txt" })
        attachScreenshot(named: "Branch changes exclude base-only commits and retain task commits")

        // Upstream moves ahead of a stale local base branch, and the task branch merges it.
        let origin = runDirectory.appendingPathComponent("external-git-origin.git", isDirectory: true)
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try runGit(origin, "init", "--bare", "--initial-branch=main")
        try runGit(repository, "remote", "add", "origin", origin.path)
        try runGit(repository, "push", "origin", "main")
        try "Upstream commit.\n".write(to: repository.appendingPathComponent("upstream-only.txt"), atomically: true, encoding: .utf8)
        try runGit(repository, "add", "upstream-only.txt")
        try runGit(repository, "commit", "-m", "Upstream commit")
        try runGit(repository, "push", "origin", "main")
        try runGit(repository, "reset", "--hard", "HEAD~1")
        try runGit(worktree, "merge", "--no-edit", "origin/main")
        // A file written after the merge only appears once the sidebar has rescanned the merged
        // branch, so waiting for its row proves the absence check below runs against fresh state.
        try "Written after the merge.\n".write(to: worktree.appendingPathComponent("post-merge.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(element("workspace-change-unviewed-post-merge.txt").waitToExist(timeout: 10))
        let staleBase = try runCLI(["task", "changes", "list", taskID])["result"] as? [String: Any]
        let staleBaseEntries = staleBase?["unviewed"] as? [[String: Any]] ?? []
        XCTAssertEqual(staleBaseEntries.map { $0["path"] as? String }, ["post-merge.txt", "tracked.txt", "untracked.txt"])
        XCTAssertFalse(element("workspace-change-unviewed-upstream-only.txt").exists)

        // A local base branch that is ahead of origin holds work the task was started from, so it stays the base.
        try runGit(repository, "merge", "--ff-only", "origin/main")
        try "Local only.\n".write(to: repository.appendingPathComponent("local-ahead.txt"), atomically: true, encoding: .utf8)
        try runGit(repository, "add", "local-ahead.txt")
        try runGit(repository, "commit", "-m", "Unpushed local base commit")
        try runGit(worktree, "merge", "--no-edit", "main")
        try "Written after the local merge.\n".write(to: worktree.appendingPathComponent("post-ahead.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(element("workspace-change-unviewed-post-ahead.txt").waitToExist(timeout: 10))
        let aheadBase = try runCLI(["task", "changes", "list", taskID])["result"] as? [String: Any]
        let aheadBaseEntries = aheadBase?["unviewed"] as? [[String: Any]] ?? []
        XCTAssertEqual(aheadBaseEntries.map { $0["path"] as? String }, ["post-ahead.txt", "post-merge.txt", "tracked.txt", "untracked.txt"])
        XCTAssertFalse(element("workspace-change-unviewed-local-ahead.txt").exists)
        XCTAssertTrue(element("workspace-change-unviewed-tracked.txt").exists)
        attachScreenshot(named: "Merged upstream commits are excluded when the local base branch is stale")

        // An open merge stages everything the merged branch brings in, so the repository's files are
        // held back until the merge is concluded rather than listed as task changes.
        let taskRepository = try XCTUnwrap(aheadBaseEntries.first?["repository"] as? String)
        try "Merged with the merge still open.\n".write(to: repository.appendingPathComponent("merging-in.txt"), atomically: true, encoding: .utf8)
        try runGit(repository, "add", "merging-in.txt")
        try runGit(repository, "commit", "-m", "Base commit merged without committing")
        try runGit(worktree, "merge", "--no-commit", "--no-ff", "main")
        let mergeNotice = element("workspace-changes-merge-in-progress")
        XCTAssertTrue(mergeNotice.waitToExist(timeout: 10))
        let mergingRepositoryLabel = URL(fileURLWithPath: taskRepository).pathComponents.suffix(2).joined(separator: "/")
        XCTAssertTrue(mergeNotice.label.contains(mergingRepositoryLabel), "The merge notice should name the merging repository: \(mergeNotice.label)")
        XCTAssertFalse(element("workspace-change-unviewed-tracked.txt").exists)
        XCTAssertFalse(element("workspace-change-unviewed-merging-in.txt").exists)
        let merging = try runCLI(["task", "changes", "list", taskID])["result"] as? [String: Any]
        XCTAssertEqual((merging?["unviewed"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual((merging?["viewed"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(merging?["mergingRepositories"] as? [String], [taskRepository])
        attachScreenshot(named: "An open merge hides the files it staged")

        try runGit(worktree, "merge", "--abort")
        XCTAssertTrue(element("workspace-change-unviewed-tracked.txt").waitToExist(timeout: 10))
        XCTAssertTrue(waitUntil({ !mergeNotice.exists }, timeout: 10))
        let aborted = try runCLI(["task", "changes", "list", taskID])["result"] as? [String: Any]
        XCTAssertEqual(aborted?["mergingRepositories"] as? [String], [])
        XCTAssertEqual(Set((aborted?["unviewed"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }), ["post-ahead.txt", "post-merge.txt", "tracked.txt", "untracked.txt"])
    }
    // case-contract: test_task_workspace_changes_over_limit_show_notice | A task whose worktree holds more than 1000 changed files still reports every one of them through fresh CLI connections, while the open task's Changes sidebar shows a 'Too many changes to list' notice naming the count instead of rendering the file list, so the window stays responsive. Bringing the count back under the limit lists the files again.
    func test_task_workspace_changes_over_limit_show_notice() throws {
        let repository = runDirectory.appendingPathComponent("many-changes", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try "Baseline.\n".write(to: repository.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try runGit(repository, "init", "--initial-branch=main")
        try runGit(repository, "config", "user.name", "Playhouse UI Test")
        try runGit(repository, "config", "user.email", "playhouse-ui-test@example.invalid")
        try runGit(repository, "add", "tracked.txt")
        try runGit(repository, "commit", "-m", "Baseline")

        let created = try runCLI(["task", "create", "--title", "Many changes", "--prompt", "Fixture task description."])
        let taskID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String)
        let added = try runCLI(["task", "repository", "add", taskID, "--repo", repository.path])
        let record = try XCTUnwrap(((added["result"] as? [String: Any])?["repositoryWorktrees"] as? [[String: Any]])?.first)
        let worktree = URL(fileURLWithPath: try XCTUnwrap(record["worktreePath"] as? String), isDirectory: true)
        let generated = worktree.appendingPathComponent("generated", isDirectory: true)
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
        for index in 0..<1001 {
            try "Generated \(index).\n".write(to: generated.appendingPathComponent(String(format: "file-%04d.txt", index)), atomically: true, encoding: .utf8)
        }

        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Many changes")
        let notice = element("workspace-changes-too-many")
        XCTAssertTrue(notice.waitToExist(timeout: 15))
        XCTAssertTrue(notice.label.contains("1001 changed files"), "The notice should name the count: \(notice.label)")
        XCTAssertFalse(element("workspace-changes-list").exists, "The file list must not render over the limit.")
        let inventory = try runCLI(["task", "changes", "list", taskID])["result"] as? [String: Any]
        XCTAssertEqual((inventory?["unviewed"] as? [[String: Any]])?.count, 1001, "The limit only affects the sidebar; the CLI still reports every file.")
        XCTAssertEqual((inventory?["viewed"] as? [[String: Any]])?.count, 0)
        attachScreenshot(named: "Over 1000 changed files shows a notice instead of the list")

        try FileManager.default.removeItem(at: generated.appendingPathComponent("file-1000.txt"))
        XCTAssertTrue(element("workspace-changes-list").waitToExist(timeout: 15))
        XCTAssertTrue(waitUntil({ !notice.exists }, timeout: 10))
        let underLimit = try runCLI(["task", "changes", "list", taskID])["result"] as? [String: Any]
        XCTAssertEqual((underLimit?["unviewed"] as? [[String: Any]])?.count, 1000)
        attachScreenshot(named: "At the limit the files are listed again")
    }
    // case-contract: test_task_terminal_opens_shell_in_task_worktree | Each task's sidebar ends in a command row whose buttons sit at its right edge; it holds a terminal button. The terminal only ever opens in the task's created repository worktree, never in its source repository or a context folder, and never creates a worktree itself: while the task's worktree is still pending, or the task has no repository, the button is disabled and the CLI reports terminal_unavailable without creating the worktree, and the button enables in the open conversation once the worktree is created. The CLI reports how the terminal starts: the account's executable login shell with -l in that worktree, with TERM=xterm-256color and PLAYHOUSE_TASK_ID set, and the same answer on a fresh CLI/XPC connection; running that shell in that folder prints the worktree path and the task ID. Clicking the button slides a terminal panel in from the window's right edge, floating over the conversation's right side without moving or resizing the conversation, whose shell runs in the task's worktree with the task ID in its environment and which uses macOS Terminal's Clear Dark ANSI palette (such as its blue, distinct from the emulator's own default) on a solid black background, switching to the Clear Light profile's white background and blue when the app's appearance turns light and back when it returns to dark; hiding the panel keeps the same shell, so reopening it reaches the same process. Dragging the panel's left border resizes it against the right edge, between a 320-point minimum and leaving 260 points of conversation uncovered, without resizing the conversation, and reopening the panel keeps the dragged width. Typing exit shows that the shell exited, and Restart starts a new shell, with a different process, in the same worktree. A task whose worktree no longer exists reports terminal_unavailable from the CLI, and the panel shows that error with a Try Again action that opens the shell once the worktree is back; an unknown task ID and the standalone chat's ID are not_found, and the standalone chat offers no terminal button.
    func test_task_terminal_opens_shell_in_task_worktree() throws {
        let repository = runDirectory.appendingPathComponent("terminal-repository", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try "Terminal fixture.\n".write(to: repository.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(repository, "init", "--initial-branch=main")
        try runGit(repository, "config", "user.name", "Playhouse UI Test")
        try runGit(repository, "config", "user.email", "playhouse-ui-test@example.invalid")
        try runGit(repository, "add", "README.md")
        try runGit(repository, "commit", "-m", "Baseline")
        let secondRepository = runDirectory.appendingPathComponent("terminal-second-repository", isDirectory: true)
        try FileManager.default.createDirectory(at: secondRepository, withIntermediateDirectories: true)
        try "Second fixture.\n".write(to: secondRepository.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(secondRepository, "init", "--initial-branch=main")
        try runGit(secondRepository, "config", "user.name", "Playhouse UI Test")
        try runGit(secondRepository, "config", "user.email", "playhouse-ui-test@example.invalid")
        try runGit(secondRepository, "add", "README.md")
        try runGit(secondRepository, "commit", "-m", "Baseline")

        // A task whose worktree is created: a titled task prepares it as soon as its repository is added.
        let created = try runCLI(["task", "create", "--title", "Terminal Task", "--prompt", "Fixture task description."])
        let taskID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String)
        let added = try runCLI(["task", "repository", "add", taskID, "--repo", repository.path])
        let record = try XCTUnwrap(((added["result"] as? [String: Any])?["repositoryWorktrees"] as? [[String: Any]])?.first)
        XCTAssertEqual(record["isPending"] as? Bool, false)
        let worktree = URL(fileURLWithPath: try XCTUnwrap(record["worktreePath"] as? String), isDirectory: true)
        let launch = try XCTUnwrap(try runCLI(["task", "terminal", taskID])["result"] as? [String: Any])
        XCTAssertEqual(launch["directory"] as? String, worktree.standardizedFileURL.path)
        XCTAssertEqual((launch["environment"] as? [String: String])?["PLAYHOUSE_TASK_ID"], taskID)

        // A task whose worktree is still pending: named and created only when the task starts.
        let pendingCreated = try runCLI([
            "task", "create", "--title", "Pending Terminal Task", "--prompt", "Fixture task description.", "--repo", repository.path
        ])
        let pendingTaskID = try XCTUnwrap((pendingCreated["result"] as? [String: Any])?["id"] as? String)
        let folder = runDirectory.appendingPathComponent("terminal-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try runCLI(["task", "create", "--title", "No Repository Terminal", "--prompt", "Fixture task description.", "--root", folder.path])

        launchApp(defaultParent: fixture.parent.path)
        let toggle = element("toggle-terminal-button")
        func worktreeRecord(_ id: String) throws -> [String: Any] {
            try XCTUnwrap(((try taskRecord(id: id))?["repositoryWorktrees"] as? [[String: Any]])?.first)
        }

        openTask(named: "Pending Terminal Task")
        XCTAssertTrue(toggle.waitToExist(timeout: 10))
        XCTAssertFalse(toggle.isEnabled, "The terminal button stays disabled until the task's worktree is created.")
        toggle.click()
        XCTAssertFalse(element("task-terminal-panel").exists, "A disabled button opens no panel.")
        XCTAssertEqual(try worktreeRecord(pendingTaskID)["isPending"] as? Bool, true, "Clicking it does not create the worktree.")
        attachScreenshot(named: "Terminal button disabled until the task's worktree exists")
        // Creating the worktree, as a task's start does, enables the button in the open conversation.
        _ = try runCLI(["task", "repository", "add", pendingTaskID, "--repo", secondRepository.path])
        XCTAssertEqual(try worktreeRecord(pendingTaskID)["isPending"] as? Bool, false)
        XCTAssertTrue(waitUntil({ toggle.isEnabled }, timeout: 10), "The button enables once the worktree exists.")

        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10))
        openTask(named: "No Repository Terminal")
        XCTAssertTrue(toggle.waitToExist(timeout: 10))
        XCTAssertFalse(toggle.isEnabled, "A task with no repository has no worktree, so no terminal.")

        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10))
        openTask(named: "Terminal Task")
        let sidebar = element("task-sidebar")
        let commandRow = element("sidebar-command-row")
        XCTAssertTrue(toggle.waitToExist(timeout: 10))
        XCTAssertTrue(toggle.isEnabled)
        XCTAssertTrue(commandRow.exists)
        XCTAssertEqual(toggle.value as? String, "Hidden")
        XCTAssertFalse(element("task-terminal-panel").exists, "The terminal stays hidden until the button opens it.")
        // The row's accessibility frame spans only its buttons, so placement is measured against the sidebar.
        XCTAssertTrue(commandRow.buttons["toggle-terminal-button"].exists, "The terminal button belongs to the command row.")
        XCTAssertTrue(element("workspace-changes-empty").waitToExist(timeout: 10))
        XCTAssertGreaterThan(toggle.frame.minY, element("workspace-changes-empty").frame.maxY, "The command row sits below the Changes list.")
        XCTAssertEqual(toggle.frame.maxY, sidebar.frame.maxY, accuracy: 10, "The command row is the sidebar's bottom row.")
        XCTAssertEqual(toggle.frame.maxX, sidebar.frame.maxX, accuracy: 14, "Command row buttons align to the right.")
        XCTAssertGreaterThan(toggle.frame.minX, sidebar.frame.midX, "The terminal button sits on the right half of the sidebar.")
        attachScreenshot(named: "Sidebar command row with the terminal button on the right")

        let window = app.windows.firstMatch
        // The whole conversation area, not its centered empty state, whose edges move with the window's width.
        let conversation = element("conversation-scroll-view")
        XCTAssertTrue(conversation.exists)
        XCTAssertTrue(element("empty-conversation").exists)
        XCTAssertGreaterThan(conversation.frame.maxX, window.frame.maxX - 470, "Before the panel opens, the conversation reaches into the space the panel will take.")
        let conversationFrameBefore = conversation.frame
        toggle.click()
        let panel = element("task-terminal-panel")
        XCTAssertTrue(panel.waitToExist(timeout: 5))
        XCTAssertTrue(waitUntil({ abs(panel.frame.maxX - window.frame.maxX) <= 2 }, timeout: 5), "The panel settles against the window's right edge.")
        XCTAssertGreaterThan(panel.frame.minX, sidebar.frame.maxX, "The panel opens on the right, leaving the sidebar in place.")
        XCTAssertLessThan(panel.frame.minX, conversation.frame.maxX, "The panel floats over the conversation's right side.")
        XCTAssertEqual(conversation.frame.minX, conversationFrameBefore.minX, accuracy: 1, "Opening the terminal does not move the conversation.")
        XCTAssertEqual(conversation.frame.width, conversationFrameBefore.width, accuracy: 1, "Opening the terminal does not resize the conversation.")
        XCTAssertEqual(toggle.value as? String, "Shown")
        assertText("task-terminal-title", equals: "Terminal")

        let terminal = element("task-terminal-view")
        XCTAssertTrue(terminal.waitToExist(timeout: 10))
        XCTAssertNotEqual(worktree.standardizedFileURL.path, repository.standardizedFileURL.path, "The terminal never opens in the source repository.")
        terminal.click()
        // `pwd -P` keeps the /private prefix that Foundation's symlink resolution drops for /tmp.
        let resolvedWorktree = try XCTUnwrap(realpath(worktree.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        terminal.typeText("cd . && printf 'dir=%s task=%s pid=%s;\\n' \"$(pwd -P)\" \"$PLAYHOUSE_TASK_ID\" \"$$\"\n")
        let expectedPrefix = "dir=\(resolvedWorktree) task=\(taskID) pid="
        var shellPID = ""
        XCTAssertTrue(waitUntil({
            guard let pid = self.terminalNumber(after: expectedPrefix, in: terminal) else { return false }
            shellPID = pid
            return true
        }, timeout: 20), "The shell runs in the task worktree with the task ID: \(String(reflecting: terminal.value as? String ?? ""))")
        // Clear Dark's ANSI blue #6D96B4 (the emulator's own is #492EE1) on a solid black
        // background. Clear Light: blue #5685A8 on 93%-opaque white, within the pixel tolerance.
        terminal.typeText("printf '\\033[44m%24s\\033[0m\\n' ''\n")
        XCTAssertTrue(waitUntil({
            self.screenshotContains(srgb: (0x6D, 0x96, 0xB4), in: terminal)
        }, timeout: 10), "ANSI blue renders in Clear Dark's blue.")
        XCTAssertFalse(screenshotContains(srgb: (0x49, 0x2E, 0xE1), in: terminal), "The emulator's own default blue is replaced.")
        XCTAssertTrue(screenshotContains(srgb: (0x00, 0x00, 0x00), in: terminal, tolerance: 3), "The terminal uses a black background.")
        attachScreenshot(named: "Terminal slid in from the right, running in the task worktree")

        _ = try runCLI(["settings", "set-appearance", "light"])
        XCTAssertTrue(waitUntil({
            self.screenshotContains(srgb: (0x56, 0x85, 0xA8), in: terminal)
                && !self.screenshotContains(srgb: (0x00, 0x00, 0x00), in: terminal, tolerance: 3)
        }, timeout: 10), "Light appearance switches the terminal to Clear Light's colors.")
        XCTAssertTrue(screenshotContains(srgb: (0xFF, 0xFF, 0xFF), in: terminal), "Clear Light uses a white background.")
        attachScreenshot(named: "Terminal in light appearance uses the Clear Light profile")
        _ = try runCLI(["settings", "set-appearance", "dark"])
        XCTAssertTrue(waitUntil({
            self.screenshotContains(srgb: (0x00, 0x00, 0x00), in: terminal, tolerance: 3)
        }, timeout: 10), "Returning to dark appearance restores the black background.")
        terminal.click()

        element("close-terminal-button").click()
        XCTAssertTrue(waitUntil({ !panel.exists }, timeout: 5), "Hide slides the panel away.")
        XCTAssertEqual(toggle.value as? String, "Hidden")
        toggle.click()
        XCTAssertTrue(terminal.waitToExist(timeout: 5))
        terminal.click()
        terminal.typeText("printf 'again=%s;\\n' \"$$\"\n")
        XCTAssertTrue(waitUntil({
            self.terminalNumber(after: "again=", in: terminal) == shellPID
        }, timeout: 20), "Reopening the panel reaches the same shell: \(String(reflecting: terminal.value as? String ?? ""))")
        attachScreenshot(named: "Reopened terminal keeps the same shell session")

        // Dragging the left border resizes the panel, within limits, and the width is remembered.
        let handle = element("terminal-resize-handle")
        XCTAssertTrue(handle.waitToExist(timeout: 5))
        XCTAssertEqual(handle.frame.midX, panel.frame.minX, accuracy: 6, "The resize handle is the panel's left border.")
        let widthBefore = panel.frame.width
        let conversationBeforeResize = conversation.frame
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.2, thenDragTo: handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: -50, dy: 0)))
        XCTAssertTrue(waitUntil({ abs(panel.frame.width - (widthBefore + 50)) <= 6 }, timeout: 5), "Dragging left widens the panel: \(panel.frame.width)")
        XCTAssertEqual(abs(panel.frame.maxX - window.frame.maxX), 0, accuracy: 2, "The panel stays against the right edge.")
        XCTAssertEqual(conversation.frame.width, conversationBeforeResize.width, accuracy: 1, "Resizing does not resize the conversation.")
        let widened = panel.frame.width
        attachScreenshot(named: "Terminal widened by dragging its left border")
        element("close-terminal-button").click()
        XCTAssertTrue(waitUntil({ !panel.exists }, timeout: 5))
        toggle.click()
        XCTAssertTrue(waitUntil({ panel.exists && abs(panel.frame.width - widened) <= 2 }, timeout: 5), "Reopening keeps the dragged width.")
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.2, thenDragTo: handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 900, dy: 0)))
        XCTAssertTrue(waitUntil({ abs(panel.frame.width - 320) <= 3 }, timeout: 5), "The panel stops at its minimum width: \(panel.frame.width)")
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.2, thenDragTo: handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: -3000, dy: 0)))
        XCTAssertTrue(waitUntil({ abs(panel.frame.minX - (sidebar.frame.maxX + 1 + 260)) <= 4 }, timeout: 5),
                      "The panel stops where 260 points of conversation stay uncovered: \(panel.frame.minX)")
        XCTAssertTrue(terminal.exists)
        terminal.click()

        terminal.typeText("exit\n")
        let exitStatus = element("task-terminal-exit-status")
        XCTAssertTrue(exitStatus.waitToExist(timeout: 10), "Exiting the shell is reported in the panel.")
        let exitText = exitStatus.value as? String ?? exitStatus.label
        XCTAssertTrue(exitText.hasPrefix("Shell exited"), exitText)
        attachScreenshot(named: "Terminal reports the shell exited and offers Restart")
        element("restart-terminal-button").click()
        XCTAssertTrue(waitUntil({ !exitStatus.exists }, timeout: 5), "Restart clears the exit report.")
        XCTAssertTrue(terminal.waitToExist(timeout: 5))
        terminal.click()
        terminal.typeText("printf 'dir=%s task=%s pid=%s;\\n' \"$(pwd -P)\" \"$PLAYHOUSE_TASK_ID\" \"$$\"\n")
        var restartedPID = ""
        XCTAssertTrue(waitUntil({
            guard let pid = self.terminalNumber(after: expectedPrefix, in: terminal) else { return false }
            restartedPID = pid
            return true
        }, timeout: 20), "The restarted shell runs in the task worktree: \(String(reflecting: terminal.value as? String ?? ""))")
        XCTAssertNotEqual(restartedPID, shellPID, "Restart starts a new shell process.")
        toggle.click()
        XCTAssertTrue(waitUntil({ !panel.exists }, timeout: 5), "The sidebar button also hides the panel.")

        // A worktree that is missing shows an error with Try Again, which recovers once it is back.
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10))
        // The terminal falls back to a task's next existing worktree, so every one is moved aside.
        let pendingWorktrees = try XCTUnwrap(
            (try taskRecord(id: pendingTaskID))?["repositoryWorktrees"] as? [[String: Any]]
        ).compactMap { $0["worktreePath"] as? String }
        XCTAssertEqual(pendingWorktrees.count, 2)
        let pendingWorktree = try XCTUnwrap(pendingWorktrees.first)
        for path in pendingWorktrees {
            try FileManager.default.moveItem(at: URL(fileURLWithPath: path, isDirectory: true), to: URL(fileURLWithPath: path + "-moved", isDirectory: true))
        }
        openTask(named: "Pending Terminal Task")
        XCTAssertTrue(toggle.waitToExist(timeout: 10))
        XCTAssertTrue(toggle.isEnabled)
        toggle.click()
        XCTAssertTrue(element("task-terminal-error").waitToExist(timeout: 10))
        let errorMessage = element("task-terminal-error-message")
        let errorText = errorMessage.value as? String ?? errorMessage.label
        XCTAssertTrue(errorText.contains("no longer exists"), errorText)
        XCTAssertFalse(terminal.exists, "No shell starts without the worktree.")
        attachScreenshot(named: "Terminal panel reports a missing worktree and offers Try Again")
        for path in pendingWorktrees {
            try FileManager.default.moveItem(at: URL(fileURLWithPath: path + "-moved", isDirectory: true), to: URL(fileURLWithPath: path, isDirectory: true))
        }
        element("retry-terminal-button").click()
        XCTAssertTrue(terminal.waitToExist(timeout: 10), "Try Again starts a shell once the worktree is back.")
        XCTAssertFalse(element("task-terminal-error").exists)
        XCTAssertNotEqual(pendingWorktree, repository.standardizedFileURL.path)
        let resolvedPendingWorktree = try XCTUnwrap(realpath(pendingWorktree, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        terminal.click()
        terminal.typeText("printf 'dir=%s pid=%s;\\n' \"$(pwd -P)\" \"$$\"\n")
        XCTAssertTrue(waitUntil({
            self.terminalNumber(after: "dir=\(resolvedPendingWorktree) pid=", in: terminal) != nil
        }, timeout: 20), "The retried shell runs in the task's worktree: \(String(reflecting: terminal.value as? String ?? ""))")
        attachScreenshot(named: "Try Again opens the shell once the worktree is back")

        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10))
        element("chat-sidebar-button").click()
        XCTAssertTrue(element("chat-sidebar").waitToExist(timeout: 10))
        XCTAssertTrue(element("message-composer").waitToExist(timeout: 10))
        XCTAssertFalse(toggle.exists, "The standalone chat has no task sidebar, so no terminal button.")
    }
    // case-contract: test_schedule_one_time_task_fires_when_due | A task whose conversation hasn't started is scheduled once (the composer's schedule hint, or schedule set --once); scheduling saves the prompt as the schedule's own payload without starting a turn, keeps the task in Backlog with a clock badge, and lists it in schedule list. Removing the schedule in the hint before Send turns the clock button off and returns Send to sending. A time in the past or a blank prompt is rejected with invalid_argument. A tick before the time does nothing; a tick 30 minutes after it, inside the one-hour grace period, sends the scheduled prompt to the provider, clears the schedule, and the task follows the ordinary board lifecycle. A second tick doesn't run it again, and a task that has started can't be scheduled. The app bundle carries the scheduler LaunchAgent (<bundle-id>.scheduler.plist running playhouse-cli schedule tick every 60 seconds), and a plain tick on the real clock fires a schedule that has come due.
    func test_schedule_one_time_task_fires_when_due() throws {
        let environment = try installClaudeFixture(named: "claude-fixture-ui-schedule-once")
        launchApp(defaultParent: fixture.parent.path)
        let taskID = try XCTUnwrap((try runCLI([
            "task", "create", "--title", "Scheduled once", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
        ])["result"] as? [String: Any])?["id"] as? String)
        openTask(named: "Scheduled once")
        replaceComposerText(with: "Tell me a story.")
        let send = element("send-message-button")
        XCTAssertEqual(send.label, "Send message", "Send sends until a schedule is set.")
        let scheduleButton = element("schedule-task-button")
        XCTAssertEqual(scheduleButton.value as? String, "Off")

        _ = openScheduleHint()
        XCTAssertTrue(element("schedule-date-picker").exists, "A one-time schedule picks a date and time.")
        XCTAssertFalse(element("schedule-title-field").exists, "Only a recurring schedule asks for a title.")
        attachScreenshot(named: "Schedule hint for a one-time run")
        element("schedule-done-button").click()
        XCTAssertTrue(waitForDisappearance(element("schedule-hint")))
        XCTAssertTrue(waitUntil({ send.label == "Schedule task" }, timeout: 5), "Send switches to schedule mode once the hint is done.")
        XCTAssertEqual(scheduleButton.value as? String, "On")
        XCTAssertNil(try taskRecord(id: taskID)?["schedule"] as? [String: Any], "Nothing is saved until Send confirms the schedule.")
        attachScreenshot(named: "Send in schedule mode with the schedule button on")

        _ = openScheduleHint()
        element("schedule-remove-button").click()
        XCTAssertTrue(waitForDisappearance(element("schedule-hint")))
        XCTAssertTrue(waitUntil({ send.label == "Send message" }, timeout: 5), "Removing the schedule returns Send to sending.")
        XCTAssertEqual(scheduleButton.value as? String, "Off")
        attachScreenshot(named: "Removing the schedule turns the clock off and Send back to sending")
        _ = openScheduleHint()
        element("schedule-done-button").click()
        XCTAssertTrue(waitUntil({ send.label == "Schedule task" }, timeout: 5))

        send.click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10), "Scheduling returns to the board.")
        let badge = element("task-schedule-badge-\(taskID)")
        XCTAssertTrue(badge.waitToExist(timeout: 10), "A one-time scheduled task stays on the board with a clock badge.")
        let record = try XCTUnwrap(taskRecord(id: taskID))
        XCTAssertEqual(record["status"] as? String, "Backlog")
        let schedule = try XCTUnwrap(record["schedule"] as? [String: Any])
        XCTAssertEqual(schedule["kind"] as? String, "once")
        XCTAssertEqual(schedule["prompt"] as? String, "Tell me a story.")
        XCTAssertEqual(claudeFixturePrompts(), [], "Scheduling starts no turn.")
        attachScreenshot(named: "Board shows the scheduled task with its clock badge")

        assertCLIError(
            try runCLI(["schedule", "set", taskID, "--prompt", "Tell me a story.", "--once", scheduleISO(Date().addingTimeInterval(-300))], expectedStatus: 2),
            code: "invalid_argument"
        )
        assertCLIError(
            try runCLI(["schedule", "set", taskID, "--prompt", "  ", "--once", scheduleISO(Date().addingTimeInterval(7200))], expectedStatus: 2),
            code: "invalid_argument"
        )
        let fireAt = try XCTUnwrap(scheduleDate(schedule["scheduledAt"] as? String))
        let early = try XCTUnwrap(try runCLI(["schedule", "tick", "--now", scheduleISO(fireAt.addingTimeInterval(-600))], extraEnvironment: environment)["result"] as? [String: Any])
        XCTAssertEqual((early["fired"] as? [Any])?.count, 0, "Nothing runs before its time.")
        let due = try XCTUnwrap(try runCLI(["schedule", "tick", "--now", scheduleISO(fireAt.addingTimeInterval(1800))], extraEnvironment: environment)["result"] as? [String: Any])
        XCTAssertEqual((due["fired"] as? [[String: Any]])?.compactMap { $0["taskID"] as? String }, [taskID], "A run 30 minutes late is inside the grace period.")
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["status"] as? String) == "Review" }, timeout: 60), "The fired task follows the ordinary board lifecycle.")
        XCTAssertTrue(waitForDisappearance(badge, timeout: 10), "Firing clears the schedule badge.")
        XCTAssertTrue(claudeFixturePrompts().contains("Tell me a story."), "The scheduled prompt reaches the provider.")
        attachScreenshot(named: "The scheduled task ran and moved on the board")
        let again = try XCTUnwrap(try runCLI(["schedule", "tick", "--now", scheduleISO(fireAt.addingTimeInterval(2400))], extraEnvironment: environment)["result"] as? [String: Any])
        XCTAssertEqual((again["fired"] as? [Any])?.count, 0, "A run happens once.")
        assertCLIError(
            try runCLI(["schedule", "set", taskID, "--prompt", "Again", "--once", scheduleISO(fireAt.addingTimeInterval(86400))], expectedStatus: 1),
            code: "invalid_transition"
        )

        let bundleIdentifier = try XCTUnwrap(Bundle(url: appBundle)?.bundleIdentifier)
        let agentURL = appBundle.appendingPathComponent("Contents/Library/LaunchAgents/\(bundleIdentifier).scheduler.plist")
        let agent = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(contentsOf: agentURL), format: nil) as? [String: Any])
        XCTAssertEqual(agent["Label"] as? String, "\(bundleIdentifier).scheduler")
        XCTAssertEqual(agent["BundleProgram"] as? String, "Contents/MacOS/playhouse-cli")
        XCTAssertEqual(agent["ProgramArguments"] as? [String], ["playhouse-cli", "schedule", "tick"])
        XCTAssertEqual(agent["StartInterval"] as? Int, 60, "The agent ticks every minute while the app is closed.")

        let soonID = try XCTUnwrap((try runCLI([
            "task", "create", "--title", "Due on the real clock", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
        ])["result"] as? [String: Any])?["id"] as? String)
        let soon = Date().addingTimeInterval(3)
        _ = try runCLI(["schedule", "set", soonID, "--prompt", "Tell me a story.", "--once", scheduleISO(soon)])
        Thread.sleep(forTimeInterval: max(0, soon.timeIntervalSinceNow) + 1)
        let real = try XCTUnwrap(try runCLI(["schedule", "tick"], extraEnvironment: environment)["result"] as? [String: Any])
        XCTAssertEqual((real["fired"] as? [[String: Any]])?.compactMap { $0["taskID"] as? String }, [soonID], "A plain tick uses the real clock.")
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: soonID)?["status"] as? String) == "Review" }, timeout: 60))
    }
    // case-contract: test_schedule_missed_beyond_grace_is_blocked | A scheduled run more than one hour late is not started. A one-time task lands in Blocked with a 'Missed scheduled run' message and its prompt kept as an unsent draft, and sending that draft starts it. A recurring schedule ticked a week late creates exactly one Blocked run task linked to its schedule, skips the older missed occurrences, and moves its next run into the future. A due run whose provider can't start lands in Blocked saying the scheduled run couldn't start, with its prompt kept as the draft.
    func test_schedule_missed_beyond_grace_is_blocked() throws {
        let environment = try installClaudeFixture(named: "claude-fixture-ui-schedule-missed")
        launchApp(defaultParent: fixture.parent.path)
        let taskID = try XCTUnwrap((try runCLI([
            "task", "create", "--title", "Missed once", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
        ])["result"] as? [String: Any])?["id"] as? String)
        let fireAt = Date().addingTimeInterval(3600)
        _ = try runCLI(["schedule", "set", taskID, "--prompt", "Tell me a story.", "--once", scheduleISO(fireAt)])
        let late = try XCTUnwrap(try runCLI(["schedule", "tick", "--now", scheduleISO(fireAt.addingTimeInterval(7200))], extraEnvironment: environment)["result"] as? [String: Any])
        XCTAssertEqual((late["dropped"] as? [[String: Any]])?.compactMap { $0["taskID"] as? String }, [taskID])
        let message = element("task-status-message-\(taskID)")
        XCTAssertTrue(message.waitToExist(timeout: 10), "The missed task shows why it's blocked.")
        XCTAssertTrue(accessibleLabelOrValue(of: message).hasPrefix("Missed scheduled run"))
        XCTAssertTrue(element("column-blocked").buttons["task-card-\(taskID)"].waitToExist(timeout: 10), "A missed run lands in Blocked.")
        XCTAssertEqual(claudeFixturePrompts(), [], "A missed run starts no turn.")
        attachScreenshot(named: "A missed one-time run waits in Blocked")

        openTask(named: "Missed once")
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ (composer.value as? String) == "Tell me a story." }, timeout: 10), "The missed prompt waits in the composer.")
        attachScreenshot(named: "The missed prompt waits in the composer")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["status"] as? String) == "Review" }, timeout: 60), "Sending the draft runs the task.")
        XCTAssertTrue(claudeFixturePrompts().contains("Tell me a story."))

        element("back-to-board-button").click()
        let templateID = try XCTUnwrap((try runCLI([
            "task", "create", "--title", "Weekly template", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
        ])["result"] as? [String: Any])?["id"] as? String)
        let template = try XCTUnwrap(try runCLI([
            "schedule", "set", templateID, "--prompt", "Tell me a story.", "--repeat", "weekly", "--weekday", "mon", "--time", "09:00", "--title", "Weekly report",
        ])["result"] as? [String: Any])
        let nextRun = try XCTUnwrap(scheduleDate((template["schedule"] as? [String: Any])?["scheduledAt"] as? String))
        let weekLate = nextRun.addingTimeInterval(7 * 86400 + 7200)
        let missed = try XCTUnwrap(try runCLI(["schedule", "tick", "--now", scheduleISO(weekLate)], extraEnvironment: environment)["result"] as? [String: Any])
        let dropped = try XCTUnwrap(missed["dropped"] as? [[String: Any]])
        XCTAssertEqual(dropped.count, 1, "Missed occurrences collapse into one run.")
        let runID = try XCTUnwrap(dropped.first?["taskID"] as? String)
        XCTAssertTrue(element("column-blocked").buttons["task-card-\(runID)"].waitToExist(timeout: 10), "The missed recurring run is a Blocked board task.")
        let run = try XCTUnwrap(taskRecord(id: runID))
        XCTAssertEqual(run["title"] as? String, "Weekly report")
        XCTAssertEqual(run["scheduleSourceTaskID"] as? String, templateID)
        XCTAssertEqual(run["savedPrompt"] as? String, "Tell me a story.", "The missed run keeps the prompt as its draft.")
        XCTAssertEqual(run["hasUnsentDraft"] as? Bool, true)
        let refreshed = try XCTUnwrap(taskRecord(id: templateID)?["schedule"] as? [String: Any])
        XCTAssertGreaterThan(try XCTUnwrap(scheduleDate(refreshed["scheduledAt"] as? String)), weekLate, "The next run moves into the future.")
        attachScreenshot(named: "A recurring run missed by a week lands once in Blocked")

        let failingID = try XCTUnwrap((try runCLI([
            "task", "create", "--title", "Provider missing", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
        ])["result"] as? [String: Any])?["id"] as? String)
        let failingAt = Date().addingTimeInterval(3600)
        _ = try runCLI(["schedule", "set", failingID, "--prompt", "Tell me a story.", "--once", scheduleISO(failingAt)])
        let unstarted = try XCTUnwrap(try runCLI(
            ["schedule", "tick", "--now", scheduleISO(failingAt.addingTimeInterval(300))],
            extraEnvironment: ["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": "none"]
        )["result"] as? [String: Any])
        XCTAssertEqual((unstarted["fired"] as? [[String: Any]])?.compactMap { $0["taskID"] as? String }, [failingID])
        let failedMessage = element("task-status-message-\(failingID)")
        XCTAssertTrue(waitUntil({ failedMessage.exists && self.accessibleLabelOrValue(of: failedMessage).hasPrefix("The scheduled run couldn't start") }, timeout: 30),
                      "A run whose provider can't start says so on its Blocked card.")
        XCTAssertTrue(element("column-blocked").buttons["task-card-\(failingID)"].exists)
        let failed = try XCTUnwrap(taskRecord(id: failingID))
        XCTAssertEqual(failed["savedPrompt"] as? String, "Tell me a story.")
        XCTAssertEqual(failed["hasUnsentDraft"] as? Bool, true, "The prompt waits as the draft for a retry.")
        attachScreenshot(named: "A scheduled run that couldn't start waits in Blocked")
    }
    // case-contract: test_schedule_recurring_template_hidden_and_spawns_runs | A recurring schedule needs a title, and a weekday when it repeats weekly; once confirmed, its template is absent from the board and task list but listed by schedule list and on the Scheduled Tasks page. A due tick creates a new board task with the schedule's title and context folders, linked by scheduleSourceTaskID, sends the prompt, records the run on the template and advances its next run by one day. A paused schedule doesn't fire, Run now starts a run immediately, and clearing the schedule turns the template into an ordinary Backlog task.
    func test_schedule_recurring_template_hidden_and_spawns_runs() throws {
        let environment = try installClaudeFixture(named: "claude-fixture-ui-schedule-recurring")
        launchApp(defaultParent: fixture.parent.path)
        let templateID = try XCTUnwrap((try runCLI([
            "task", "create", "--title", "Recurring template", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
        ])["result"] as? [String: Any])?["id"] as? String)
        openTask(named: "Recurring template")
        replaceComposerText(with: "Tell me a story.")
        _ = openScheduleHint()
        selectSkillsTab("Recurring", picker: "schedule-kind-picker")
        let title = element("schedule-title-field")
        XCTAssertTrue(title.waitToExist(timeout: 5), "A recurring schedule asks for a title.")
        XCTAssertTrue(element("schedule-repeat-picker").exists)
        title.click()
        title.typeKey("a", modifierFlags: .command)
        title.typeKey(.delete, modifierFlags: [])
        XCTAssertFalse(element("schedule-done-button").isEnabled, "A recurring schedule needs a title.")
        title.typeText("Daily standup")
        XCTAssertTrue(waitUntil({ self.element("schedule-done-button").isEnabled }, timeout: 5))
        attachScreenshot(named: "Schedule hint for a recurring task with its title")
        element("schedule-done-button").click()
        let send = element("send-message-button")
        XCTAssertTrue(waitUntil({ send.label == "Schedule task" }, timeout: 5))
        send.click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10))
        XCTAssertTrue(waitUntil({ ((try? self.taskRecord(id: templateID)?["schedule"] as? [String: Any])?["kind"] as? String) == "recurring" }, timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(element("task-card-\(templateID)").exists, "A recurring template isn't a board task.")
        let boardTasks = ((try runCLI(["task", "list"])["result"] as? [String: Any])?["tasks"] as? [[String: Any]]) ?? []
        XCTAssertFalse(boardTasks.contains { $0["id"] as? String == templateID }, "A recurring template isn't in task list.")
        attachScreenshot(named: "Board after scheduling a recurring task shows no template card")
        assertCLIError(
            try runCLI(["schedule", "set", templateID, "--prompt", "Tell me a story.", "--repeat", "weekly", "--title", "Standup"], expectedStatus: 2),
            code: "invalid_argument"
        )

        element("scheduled-tasks-button").click()
        XCTAssertTrue(element("scheduled-tasks-page").waitToExist(timeout: 10), "The sidebar button opens the Scheduled Tasks page.")
        // The page slides in over the board; clicks before it settles land on the board.
        XCTAssertTrue(waitForStableFrame(element("scheduled-tasks-page")), "The Scheduled Tasks page should finish sliding in.")
        let row = element("scheduled-task-row-\(templateID)")
        XCTAssertTrue(row.waitToExist(timeout: 10))
        XCTAssertEqual(accessibleLabelOrValue(of: element("scheduled-task-title-\(templateID)")), "Daily standup")
        XCTAssertTrue(accessibleLabelOrValue(of: element("scheduled-task-summary-\(templateID)")).hasPrefix("Every day at 09:00"))
        attachScreenshot(named: "Scheduled Tasks page lists the recurring task")

        let template = try XCTUnwrap(taskRecord(id: templateID)?["schedule"] as? [String: Any])
        let firstRun = try XCTUnwrap(scheduleDate(template["scheduledAt"] as? String))
        let fired = try XCTUnwrap(try runCLI(["schedule", "tick", "--now", scheduleISO(firstRun.addingTimeInterval(600))], extraEnvironment: environment)["result"] as? [String: Any])
        let runID = try XCTUnwrap((fired["fired"] as? [[String: Any]])?.first?["taskID"] as? String)
        XCTAssertNotEqual(runID, templateID, "Each run is a new task.")
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: runID)?["status"] as? String) == "Review" }, timeout: 60))
        let run = try XCTUnwrap(taskRecord(id: runID))
        XCTAssertEqual(run["title"] as? String, "Daily standup")
        XCTAssertEqual(run["scheduleSourceTaskID"] as? String, templateID)
        XCTAssertEqual(run["contextFolders"] as? [String], try taskRecord(id: templateID)?["contextFolders"] as? [String], "A run takes the schedule's context folders.")
        XCTAssertTrue(claudeFixturePrompts().contains("Tell me a story."))
        let advanced = try XCTUnwrap(scheduleDate((taskRecord(id: templateID)?["schedule"] as? [String: Any])?["scheduledAt"] as? String))
        XCTAssertEqual(advanced.timeIntervalSince(firstRun), 86400, accuracy: 3600, "A daily schedule advances by one day.")

        let active = element("scheduled-task-active-\(templateID)")
        XCTAssertTrue(active.waitToExist(timeout: 5))
        active.click()
        XCTAssertTrue(waitUntil({ ((try? self.taskRecord(id: templateID)?["schedule"] as? [String: Any])?["paused"] as? Bool) == true }, timeout: 10), "The row's switch pauses the schedule.")
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("scheduled-task-summary-\(templateID)")).hasSuffix("Paused") }, timeout: 5))
        let nextRun = try XCTUnwrap(scheduleDate((taskRecord(id: templateID)?["schedule"] as? [String: Any])?["scheduledAt"] as? String))
        let quiet = try XCTUnwrap(try runCLI(["schedule", "tick", "--now", scheduleISO(nextRun.addingTimeInterval(600))], extraEnvironment: environment)["result"] as? [String: Any])
        XCTAssertEqual((quiet["fired"] as? [Any])?.count, 0, "A paused schedule doesn't fire.")
        active.click()
        XCTAssertTrue(waitUntil({ ((try? self.taskRecord(id: templateID)?["schedule"] as? [String: Any])?["paused"] as? Bool) == false }, timeout: 10))
        attachScreenshot(named: "Scheduled Tasks page after pausing and resuming")

        clickScheduledTaskMenuItem(taskID: templateID, item: "scheduled-task-run-now-\(templateID)", title: "Run Now")
        XCTAssertTrue(waitUntil({
            let runs = ((try? self.runCLI(["task", "list"])["result"] as? [String: Any])?["tasks"] as? [[String: Any]]) ?? []
            return runs.filter { $0["scheduleSourceTaskID"] as? String == templateID }.count == 2
        }, timeout: 20), "Run Now starts another run.")

        element("scheduled-tasks-back-button").click()
        XCTAssertTrue(waitForDisappearance(element("scheduled-tasks-page"), timeout: 5))
        XCTAssertTrue(element("task-card-\(runID)").waitToExist(timeout: 10), "A run is followed on the board.")
        attachScreenshot(named: "Recurring runs appear on the board as ordinary tasks")
        _ = try runCLI(["schedule", "clear", templateID])
        XCTAssertTrue(element("task-card-\(templateID)").waitToExist(timeout: 10), "Clearing the schedule puts the task on the board.")
    }
    // case-contract: test_scheduled_task_edit_and_page_management | The Scheduled Tasks sidebar button opens the Scheduled Tasks page, whose New Task (header, or the button on the empty page) opens a task conversation with the schedule hint already open on Recurring. Opening a scheduled task shows its confirmed prompt with the schedule button on and Send in schedule mode, and its hint shows the saved repeat, day and time; changing its title and repeat in the hint and confirming with Send persists across fresh CLI reads, keeps the time, and starts no turn. Deleting a schedule removes it from schedule list and from the page. Sending a one-time scheduled task by hand ends its schedule, so a later tick sends nothing more; a recurring template rejects a send with invalid_transition; and clearing a schedule keeps its prompt as the task's draft.
    func test_scheduled_task_edit_and_page_management() throws {
        let environment = try installClaudeFixture(named: "claude-fixture-ui-schedule-edit")
        launchApp(defaultParent: fixture.parent.path)
        element("scheduled-tasks-button").click()
        XCTAssertTrue(element("scheduled-tasks-page").waitToExist(timeout: 10))
        // The page slides in over the board; clicks before it settles land on the board.
        XCTAssertTrue(waitForStableFrame(element("scheduled-tasks-page")), "The Scheduled Tasks page should finish sliding in.")
        XCTAssertTrue(element("scheduled-tasks-empty").exists, "An empty page says so plainly.")
        XCTAssertTrue(element("scheduled-tasks-empty-new-task-button").exists, "The empty page offers New Task.")
        attachScreenshot(named: "Scheduled Tasks page with no schedules")

        // The empty-state button and the header button both open the same conversation with the hint on Recurring.
        element("scheduled-tasks-empty-new-task-button").click()
        XCTAssertTrue(element("schedule-hint").waitToExist(timeout: 10), "The empty-state New Task opens the conversation with the schedule hint open.")
        XCTAssertTrue(element("schedule-title-field").waitToExist(timeout: 5), "The empty-state New Task starts on Recurring.")
        attachScreenshot(named: "Empty-state New Task opens the schedule hint")
        closeScheduleHintAndReturnToPage()

        element("scheduled-new-task-button").click()
        XCTAssertTrue(element("schedule-hint").waitToExist(timeout: 10), "New Task opens the conversation with the schedule hint open.")
        let title = element("schedule-title-field")
        XCTAssertTrue(title.waitToExist(timeout: 5), "The hint starts on Recurring.")
        attachScreenshot(named: "New Task from the page opens with the schedule hint")
        title.click()
        title.typeText("Morning summary")
        element("schedule-done-button").click()
        XCTAssertTrue(waitForDisappearance(element("schedule-hint")))
        replaceComposerText(with: "Summarize the week.")
        let send = element("send-message-button")
        XCTAssertTrue(waitUntil({ send.label == "Schedule task" }, timeout: 5))
        send.click()

        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "scheduled-task-row-")).firstMatch
        XCTAssertTrue(row.waitToExist(timeout: 10), "Scheduling from the page returns to the page with the new row.")
        let listed = try XCTUnwrap((try runCLI(["schedule", "list"])["result"] as? [String: Any])?["tasks"] as? [[String: Any]])
        XCTAssertEqual(listed.count, 1)
        let taskID = try XCTUnwrap(listed.first?["id"] as? String)
        XCTAssertEqual(listed.first?["title"] as? String, "Morning summary")

        // A non-default schedule, so reopening proves the hint loads what was saved.
        _ = try runCLI(["schedule", "set", taskID, "--prompt", "Summarize the week.", "--repeat", "weekly", "--weekday", "fri", "--time", "17:15", "--title", "Morning summary"])
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("scheduled-task-summary-\(taskID)")).hasPrefix("Fridays at 17:15") }, timeout: 10))
        element("scheduled-task-open-\(taskID)").click()
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ (composer.value as? String) == "Summarize the week." }, timeout: 10), "Editing shows the confirmed prompt.")
        XCTAssertEqual(element("schedule-task-button").value as? String, "On")
        XCTAssertEqual(send.label, "Schedule task", "Send stays in schedule mode while editing.")
        attachScreenshot(named: "Editing a scheduled task keeps Send in schedule mode")
        _ = openScheduleHint()
        XCTAssertEqual(title.value as? String, "Morning summary")
        XCTAssertTrue(accessibleLabelOrValue(of: element("schedule-summary")).hasPrefix("Fridays at 17:15"), "The hint shows the saved repeat, day and time.")
        title.click()
        title.typeKey("a", modifierFlags: .command)
        title.typeText("Weekday summary")
        let repeatPicker = element("schedule-repeat-picker")
        repeatPicker.click()
        let weekdays = app.menuItems["Weekdays"]
        XCTAssertTrue(weekdays.waitToExist(timeout: 5))
        weekdays.click()
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("schedule-summary")).hasPrefix("Weekdays at 17:15") }, timeout: 5))
        attachScreenshot(named: "Hint edited to a new title and repeat")
        element("schedule-done-button").click()
        XCTAssertTrue(waitForDisappearance(element("schedule-hint")))
        send.click()
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["title"] as? String) == "Weekday summary" }, timeout: 10), "Confirming with Send saves the edit.")
        let edited = try XCTUnwrap(taskRecord(id: taskID))
        let recurrence = try XCTUnwrap((edited["schedule"] as? [String: Any])?["recurrence"] as? [String: Any])
        XCTAssertEqual(recurrence["preset"] as? String, "weekdays")
        XCTAssertEqual(recurrence["hour"] as? Int, 17, "The edit keeps the time.")
        XCTAssertEqual(recurrence["minute"] as? Int, 15)
        XCTAssertNil(edited["claudeSessionID"] as? String)
        XCTAssertNil(edited["codexThreadID"] as? String, "Editing a schedule starts no turn.")
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("scheduled-task-title-\(taskID)")) == "Weekday summary" }, timeout: 10))
        attachScreenshot(named: "Scheduled Tasks page after editing the title and repeat")

        assertCLIError(
            try runCLI(["conversation", "send", taskID, "--message", "Run the template."], expectedStatus: 1, extraEnvironment: environment),
            code: "invalid_transition"
        )
        XCTAssertEqual(claudeFixturePrompts(), [], "A recurring template never runs itself.")

        clickScheduledTaskMenuItem(taskID: taskID, item: "scheduled-task-delete-\(taskID)", title: "Delete…")
        let confirm = element("confirm-delete-scheduled-task-button")
        let confirmButton = confirm.waitToExist(timeout: 5) ? confirm : app.buttons["Delete"]
        confirmButton.click()
        XCTAssertTrue(waitForDisappearance(element("scheduled-task-row-\(taskID)"), timeout: 10), "Deleting removes the row.")
        XCTAssertEqual(((try runCLI(["schedule", "list"])["result"] as? [String: Any])?["tasks"] as? [Any])?.count, 0)
        XCTAssertTrue(element("scheduled-tasks-empty").waitToExist(timeout: 5))
        attachScreenshot(named: "Scheduled Tasks page after deleting the schedule")
        element("scheduled-tasks-empty-new-task-button").click()
        XCTAssertTrue(element("schedule-hint").waitToExist(timeout: 10), "The empty-state New Task still opens the schedule hint on an empty page.")
        XCTAssertTrue(element("schedule-title-field").waitToExist(timeout: 5), "The empty-state New Task starts on Recurring after a deletion too.")
        attachScreenshot(named: "Empty page New Task after deleting the schedule")
        closeScheduleHintAndReturnToPage()
        element("scheduled-new-task-button").click()
        XCTAssertTrue(element("schedule-hint").waitToExist(timeout: 10), "The header New Task still opens the schedule hint on an empty page.")
        XCTAssertTrue(element("schedule-title-field").waitToExist(timeout: 5), "The header New Task starts on Recurring after a deletion too.")
        attachScreenshot(named: "Header New Task after deleting the schedule opens the schedule hint")
        closeScheduleHintAndReturnToPage()

        // A one-time schedule removed in the hint: Send runs the task now and ends the schedule.
        let onceID = try XCTUnwrap((try runCLI([
            "task", "create", "--title", "Sent by hand", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
        ])["result"] as? [String: Any])?["id"] as? String)
        let onceAt = Date().addingTimeInterval(3600)
        _ = try runCLI(["schedule", "set", onceID, "--prompt", "Tell me a story.", "--once", scheduleISO(onceAt)])
        let onceRow = element("scheduled-task-open-\(onceID)")
        XCTAssertTrue(onceRow.waitToExist(timeout: 10), "The page lists the new one-time schedule.")
        onceRow.click()
        XCTAssertTrue(waitUntil({ (composer.value as? String) == "Tell me a story." }, timeout: 10))
        _ = openScheduleHint()
        element("schedule-remove-button").click()
        XCTAssertTrue(waitUntil({ send.label == "Send message" }, timeout: 5))
        send.click()
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: onceID)?["status"] as? String) == "Review" }, timeout: 60), "Send runs the task now.")
        XCTAssertNil(try taskRecord(id: onceID)?["schedule"] as? [String: Any], "Sending by hand ends a one-time schedule.")
        let sent = claudeFixturePrompts().count
        let later = try XCTUnwrap(try runCLI(["schedule", "tick", "--now", scheduleISO(onceAt.addingTimeInterval(300))], extraEnvironment: environment)["result"] as? [String: Any])
        XCTAssertEqual((later["fired"] as? [Any])?.count, 0, "A started task's schedule sends nothing more.")
        XCTAssertEqual(claudeFixturePrompts().count, sent)

        let clearedID = try XCTUnwrap((try runCLI([
            "task", "create", "--title", "Cleared schedule", "--prompt", "Fixture task description.", "--root", fixture.primary.path,
        ])["result"] as? [String: Any])?["id"] as? String)
        _ = try runCLI(["schedule", "set", clearedID, "--prompt", "Keep this prompt.", "--once", scheduleISO(onceAt)])
        let cleared = try XCTUnwrap(try runCLI(["schedule", "clear", clearedID])["result"] as? [String: Any])
        XCTAssertEqual(cleared["savedPrompt"] as? String, "Keep this prompt.", "Clearing a schedule keeps its prompt as the draft.")
        XCTAssertEqual(cleared["hasUnsentDraft"] as? Bool, true)
        if element("back-to-board-button").exists { element("back-to-board-button").click() }
        // A task opened from the Scheduled Tasks page returns to that page, which covers the board.
        if element("scheduled-tasks-back-button").waitToExist(timeout: 3) { element("scheduled-tasks-back-button").click() }
        XCTAssertTrue(waitForDisappearance(element("scheduled-tasks-page")), "The Scheduled Tasks page should close before opening another task.")
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10), "The board should show before opening the cleared-schedule task.")
        openTask(named: "Cleared schedule")
        XCTAssertTrue(waitUntil({
            (self.element("message-composer").value as? String) == "Keep this prompt."
        }, timeout: 10), "Clearing a schedule keeps its prompt as the composer draft.")
        attachScreenshot(named: "Cleared schedule keeps its prompt as the composer draft")
        element("back-to-board-button").click()
    }
}
