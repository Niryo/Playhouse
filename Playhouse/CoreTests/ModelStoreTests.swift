import Foundation
import XCTest
@testable import PlayhouseCore

/// The task store's working model: one object per row, pending edits until `save()`, saves
/// that write only changed properties, and merges of other writers' rows.
// The store types are main-actor bound; Linux XCTest can only run test methods of a class
// that isn't, so each test hops to the main actor to run its check.
final class ModelStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ModelStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func testInsertSaveAndFetchReturnTheSameObject() async throws { try await checkInsertSaveAndFetchReturnTheSameObject() }
    func testSavesWriteOnlyChangedPropertiesSoWritersDontUndoEachOther() async throws { try await checkSavesWriteOnlyChangedPropertiesSoWritersDontUndoEachOther() }
    func testRefreshMergesNewerRowsAndKeepsPendingEdits() async throws { try await checkRefreshMergesNewerRowsAndKeepsPendingEdits() }
    func testDeletesReachOtherContextsAndQueries() async throws { try await checkDeletesReachOtherContextsAndQueries() }
    func testFetchFiltersSortsAndPages() async throws { try await checkFetchFiltersSortsAndPages() }
    func testAStoreMissingAColumnFailsToRead() async throws { try await checkAStoreMissingAColumnFailsToRead() }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var storeURL: URL { directory.appendingPathComponent(PlayhouseStore.storeFileName) }

    @MainActor private func checkInsertSaveAndFetchReturnTheSameObject() throws {
        let context = PlayhouseModelContext(container: try PlayhouseModelContainer(storeURL: storeURL))
        let task = BoardTask(title: "First", workspaceRootPaths: ["/tmp/a"])
        context.insert(task)
        XCTAssertTrue(context.hasChanges)
        XCTAssertEqual(try context.fetch(ModelFetch<BoardTask>()).map(\.id), [task.id], "A pending insert is fetched.")
        try context.save()
        XCTAssertFalse(context.hasChanges)
        let fetched = try context.fetch(ModelFetch<BoardTask>(.equals("id", task.id)))
        XCTAssertTrue(fetched.first === task, "A row is one object for the context's life.")
        XCTAssertEqual(fetched.first?.workspaceRootPaths, ["/tmp/a"])
    }

    @MainActor private func checkSavesWriteOnlyChangedPropertiesSoWritersDontUndoEachOther() throws {
        let first = PlayhouseModelContext(container: try PlayhouseModelContainer(storeURL: storeURL))
        let second = PlayhouseModelContext(container: try PlayhouseModelContainer(storeURL: storeURL))
        let task = BoardTask(title: "Shared")
        first.insert(task)
        try first.save()

        let copy = try XCTUnwrap(second.fetch(ModelFetch<BoardTask>(.equals("id", task.id))).first)
        task.title = "Renamed by the app"
        copy.statusMessage = "Written by the daemon"
        try first.save()
        try second.save()

        let reader = PlayhouseModelContext(container: try PlayhouseModelContainer(storeURL: storeURL))
        let stored = try XCTUnwrap(reader.fetch(ModelFetch<BoardTask>(.equals("id", task.id))).first)
        XCTAssertEqual(stored.title, "Renamed by the app")
        XCTAssertEqual(stored.statusMessage, "Written by the daemon")
    }

    @MainActor private func checkRefreshMergesNewerRowsAndKeepsPendingEdits() throws {
        let first = PlayhouseModelContext(container: try PlayhouseModelContainer(storeURL: storeURL))
        let second = PlayhouseModelContext(container: try PlayhouseModelContainer(storeURL: storeURL))
        let task = BoardTask(title: "Before")
        first.insert(task)
        try first.save()
        let copy = try XCTUnwrap(second.fetch(ModelFetch<BoardTask>(.equals("id", task.id))).first)
        copy.savedPrompt = "Unsaved draft"
        let revisionBefore = second.changeRevision

        task.title = "After"
        try first.save()
        second.refreshFromStore()

        XCTAssertEqual(copy.title, "After", "Another writer's change merges into an unchanged property.")
        XCTAssertEqual(copy.savedPrompt, "Unsaved draft", "A pending edit survives the merge.")
        XCTAssertGreaterThan(second.changeRevision, revisionBefore, "Queries run again after a merge.")
        try second.save()
        let reader = PlayhouseModelContext(container: try PlayhouseModelContainer(storeURL: storeURL))
        let stored = try XCTUnwrap(reader.fetch(ModelFetch<BoardTask>(.equals("id", task.id))).first)
        XCTAssertEqual(stored.title, "After")
        XCTAssertEqual(stored.savedPrompt, "Unsaved draft")
    }

    @MainActor private func checkDeletesReachOtherContextsAndQueries() throws {
        let first = PlayhouseModelContext(container: try PlayhouseModelContainer(storeURL: storeURL))
        let second = PlayhouseModelContext(container: try PlayhouseModelContainer(storeURL: storeURL))
        let kept = BoardTask(title: "Kept")
        let removed = BoardTask(title: "Removed")
        first.insert(kept)
        first.insert(removed)
        try first.save()
        let query = ModelQuery<BoardTask>(ModelFetch(.notEquals("statusRawValue", TaskStatus.done.rawValue), sortBy: [("createdAt", false)]))
        XCTAssertEqual(Set(query.results(in: second).map(\.title)), ["Kept", "Removed"])

        first.delete(removed)
        try first.save()
        second.refreshFromStore()
        XCTAssertEqual(query.results(in: second).map(\.title), ["Kept"])
        XCTAssertEqual(try second.fetch(ModelFetch<BoardTask>()).map(\.title), ["Kept"])
    }

    @MainActor private func checkFetchFiltersSortsAndPages() throws {
        let context = PlayhouseModelContext(container: try PlayhouseModelContainer(storeURL: storeURL))
        for index in 0..<5 {
            let task = BoardTask(title: "Done \(index)", status: .done)
            task.createdAt = Date(timeIntervalSinceReferenceDate: Double(index))
            context.insert(task)
        }
        context.insert(BoardTask(title: "Active"))
        try context.save()
        let page = try context.fetch(ModelFetch<BoardTask>(
            .equals("statusRawValue", TaskStatus.done.rawValue), sortBy: [("createdAt", false)], limit: 2, offset: 1
        ))
        XCTAssertEqual(page.map(\.title), ["Done 3", "Done 2"])
    }

    @MainActor private func checkAStoreMissingAColumnFailsToRead() throws {
        let container = try PlayhouseModelContainer(storeURL: storeURL)
        try container.pool.write { db in try db.execute(sql: "ALTER TABLE board_tasks DROP COLUMN progressLabel") }
        let context = PlayhouseModelContext(container: container)
        XCTAssertThrowsError(try context.fetch(ModelFetch<BoardTask>()))
    }
}
