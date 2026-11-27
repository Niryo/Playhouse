import Foundation
import GRDB
import XCTest
@testable import PlayhouseCore

/// The one-time move of real SwiftData stores (see Fixtures/swiftdata-stores/README.md).
// The store types are main-actor bound; Linux XCTest can only run test methods of a class
// that isn't, so each test hops to the main actor to run its check.
final class SwiftDataStoreMigrationTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func testMigratesEveryRowOfACurrentStore() async throws { try await checkMigratesEveryRowOfACurrentStore() }
    func testSkipsASecondRowWithAnIDAlreadyCopied() async throws { try await checkSkipsASecondRowWithAnIDAlreadyCopied() }
    func testMigratesALegacyStoreFromBeforeLaterColumns() async throws { try await checkMigratesALegacyStoreFromBeforeLaterColumns() }
    func testAnUnreadableStoreLeavesNoDestination() async throws { try await checkAnUnreadableStoreLeavesNoDestination() }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fixture(_ path: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/swiftdata-stores/\(path)", withExtension: nil))
    }

    @MainActor private func checkMigratesEveryRowOfACurrentStore() throws {
        let source = directory.appendingPathComponent("Playhouse-v2.store")
        try FileManager.default.copyItem(at: try fixture("current/Playhouse-v2.store"), to: source)
        let sourceBytes = try Data(contentsOf: source)
        let destination = directory.appendingPathComponent(PlayhouseStore.storeFileName)

        let summary = try SwiftDataStoreMigration.migrate(from: source, to: destination)
        XCTAssertEqual(summary, SwiftDataStoreMigration.Summary(boardTasks: 8, standaloneChats: 3, skippedRows: 0))
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes, "The SwiftData store stays as it was.")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".") }, [], "No staging file is left.")

        let context = PlayhouseModelContext(container: try PlayhouseModelContainer(storeURL: destination))
        let tasks = try context.fetch(ModelFetch<BoardTask>())
        let byTitle = Dictionary(uniqueKeysWithValues: tasks.map { ($0.title, $0) })
        let running = try XCTUnwrap(byTitle["Task in In Progress"])
        XCTAssertEqual(running.status, .inProgress)
        XCTAssertEqual(running.inProgressStartedAt, Date(timeIntervalSinceReferenceDate: 815000000.25))
        XCTAssertEqual(running.totalInProgressSeconds, 12.5)
        XCTAssertEqual(running.codexThreadID, "thread-fixture-1")
        XCTAssertEqual(running.totalCacheReadTokens, 5000)
        XCTAssertEqual(running.conversationContextModeRawValue, "optimized")
        XCTAssertEqual(try byTitle["Plain task"].flatMap(\.draftImageDataURLsData).map { try JSONDecoder().decode([String].self, from: $0) }?.count, 1)
        XCTAssertEqual(byTitle["Task in Done"]?.pastRepositoryWorktrees.first?.pullRequestNumber, 42)
        XCTAssertEqual(byTitle["Task in Review"]?.pullRequestAutoMerge, true)
        XCTAssertEqual(byTitle["Weekly check"]?.scheduleKind, .recurring)
        XCTAssertEqual(byTitle["Weekly check"]?.schedulePaused, true)
        XCTAssertEqual(byTitle["Backlog with repository"]?.repositoryWorktrees.first?.repositoryPath, "/tmp/ph-fixture-repo")

        let chats = try context.fetch(ModelFetch<StandaloneChat>())
        let chat = try XCTUnwrap(chats.first { $0.title == "Chat" })
        XCTAssertEqual(chats.first { $0.title == "Parallel bubble" }?.parallelOfChatID, chat.id)
        XCTAssertEqual(chats.first { $0.title == "Weather plugin" }?.authoredPluginID, "weather-widget")
        XCTAssertEqual(chat.savedPrompt, "Chat draft")
    }

    @MainActor private func checkSkipsASecondRowWithAnIDAlreadyCopied() throws {
        let source = directory.appendingPathComponent("Playhouse-v2.store")
        try FileManager.default.copyItem(at: try fixture("current/Playhouse-v2.store"), to: source)
        // SwiftData never made ids unique, so a store can hold two rows with one id.
        try DatabaseQueue(path: source.path).write { db in
            try db.execute(sql: """
                INSERT INTO ZBOARDTASK (Z_PK, Z_ENT, Z_OPT, ZID, ZTITLE)
                SELECT (SELECT max(Z_PK) + 1 FROM ZBOARDTASK), Z_ENT, Z_OPT, ZID, 'Duplicate of plain task'
                FROM ZBOARDTASK WHERE ZTITLE = 'Plain task'
                """)
        }
        let destination = directory.appendingPathComponent(PlayhouseStore.storeFileName)
        let summary = try SwiftDataStoreMigration.migrate(from: source, to: destination)
        XCTAssertEqual(summary, SwiftDataStoreMigration.Summary(boardTasks: 8, standaloneChats: 3, skippedRows: 1))
        let context = PlayhouseModelContext(container: try PlayhouseModelContainer(storeURL: destination))
        let titles = try context.fetch(ModelFetch<BoardTask>()).map(\.title)
        XCTAssertTrue(titles.contains("Plain task"), "The first row with the id is the one kept.")
        XCTAssertFalse(titles.contains("Duplicate of plain task"))
    }

    @MainActor private func checkMigratesALegacyStoreFromBeforeLaterColumns() throws {
        let source = directory.appendingPathComponent("Playhouse.store")
        try FileManager.default.copyItem(at: try fixture("legacy-pending-prompt/Playhouse.store"), to: source)
        let destination = directory.appendingPathComponent(PlayhouseStore.storeFileName)
        XCTAssertEqual(try SwiftDataStoreMigration.migrate(from: source, to: destination).boardTasks, 1)
        let context = PlayhouseModelContext(container: try PlayhouseModelContainer(storeURL: destination))
        let task = try XCTUnwrap(context.fetch(ModelFetch<BoardTask>()).first)
        XCTAssertEqual(task.id, UUID(uuidString: "948A506B-0AE6-47E4-A99E-EAE60CDDDAFB"))
        XCTAssertEqual(task.savedPrompt, "Keep this draft through the store repair.")
        XCTAssertNil(task.pendingSubmittedPrompt, "A column the store never had keeps its default.")
        XCTAssertFalse(task.hasUnsentDraft)
        XCTAssertEqual(task.totalInProgressSeconds, 0)
    }

    @MainActor private func checkAnUnreadableStoreLeavesNoDestination() throws {
        let source = directory.appendingPathComponent("Playhouse.store")
        try Data("Not a SQLite database".utf8).write(to: source)
        let destination = directory.appendingPathComponent(PlayhouseStore.storeFileName)
        XCTAssertThrowsError(try SwiftDataStoreMigration.migrate(from: source, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: source), Data("Not a SQLite database".utf8))
    }
}
