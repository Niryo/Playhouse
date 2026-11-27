import Foundation
import XCTest
@testable import PlayhouseCore

/// The process and file calls each kernel answers its own way (libproc on macOS, /proc on Linux).
final class POSIXTests: XCTestCase {
    func testDescribesThisProcess() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let summary = try XCTUnwrap(POSIX.processSummary(pid: pid))
        XCTAssertEqual(summary.userID, getuid())
        XCTAssertEqual(summary.parentPID, getppid())
        XCTAssertFalse(summary.name.isEmpty)
        let start = try XCTUnwrap(POSIX.processStartMicroseconds(pid: pid))
        XCTAssertEqual(POSIX.processStartMicroseconds(pid: pid), start, "The start time names this process from one read to the next.")
        XCTAssertFalse(POSIX.isZombie(pid: pid))
        XCTAssertTrue(POSIX.allProcessIDs().contains(pid))
        XCTAssertTrue(POSIX.childProcessIDs(of: getppid()).contains(pid))
        XCTAssertNotNil(POSIX.cumulativeCPUTimeNanoseconds(pid: pid))
        XCTAssertEqual(
            POSIX.workingDirectory(pid: pid).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path
        )
        XCTAssertNotNil(POSIX.currentExecutablePath())
    }

    func testFileLockRunsTheBodyAndReleases() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("posix-lock-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertEqual(try POSIX.withExclusiveFileLock(at: path) { 7 }, 7)
        XCTAssertEqual(try POSIX.withExclusiveFileLock(at: path) { 8 }, 8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(POSIX.isSymbolicLink(path))
    }

    func testAbbreviatesTheHomeFolder() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(POSIX.abbreviatingHome(home + "/Projects"), "~/Projects")
        XCTAssertEqual(POSIX.abbreviatingHome("/opt/tools"), "/opt/tools")
    }
}
