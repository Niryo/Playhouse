import Foundation
import XCTest

final class PlayhouseBridgeTests: XCTestCase {
    func testTaskWorkspaceSettingsAndConversationBridge() throws {
        let productsDirectory = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let appBundle = productsDirectory.appendingPathComponent("Playhouse.app", isDirectory: true)
        let cli = appBundle.appendingPathComponent("Contents/MacOS/playhouse-cli")
        // The bridge daemon and CLI ship flat in Contents/MacOS and resolve
        // their identity from the app's own Info.plist via `Bundle.main` (no
        // separate XPC bundle/Info.plist anymore).
        let serviceInfo = appBundle.appendingPathComponent("Contents/Info.plist")
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bridgeTestScript = repositoryRoot.appendingPathComponent("scripts/test-bridge.py")
        let contractURL = repositoryRoot.appendingPathComponent("Playhouse/BridgeTests/BridgeTestContracts.json")
        let fixtureRoot = URL(fileURLWithPath: "/tmp/playhouse-bridge-workspaces", isDirectory: true)
        let dataRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("Playhouse-BridgeTest-\(UUID().uuidString)", isDirectory: true)
        let ownerMarker = dataRoot.appendingPathComponent(".playhouse-bridge-test-owner")
        let ownerContents = "Playhouse Xcode bridge test owns this data (v1).\n"

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: cli.path), "The Xcode scheme must build the app-bundled CLI.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bridgeTestScript.path))
        let contractData = try Data(contentsOf: contractURL)
        let contracts = try XCTUnwrap(JSONSerialization.jsonObject(with: contractData) as? [[String: Any]])
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        try ownerContents.write(to: ownerMarker, atomically: true, encoding: .utf8)
        defer {
            if (try? String(contentsOf: ownerMarker, encoding: .utf8)) == ownerContents {
                try? FileManager.default.removeItem(at: dataRoot)
            }
        }

        let plistData = try Data(contentsOf: serviceInfo)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        )
        let serviceIdentifier = try XCTUnwrap(plist["CFBundleIdentifier"] as? String) + ".bridge"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            bridgeTestScript.path,
            "--cli", cli.path,
            "--fixture-root", fixtureRoot.path,
            "--data-root", dataRoot.appendingPathComponent("data", isDirectory: true).path,
            "--service-name", serviceIdentifier,
        ]
        process.environment = ProcessInfo.processInfo.environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let combinedOutput = output + "\n" + errorOutput
        let attachment = XCTAttachment(string: combinedOutput)
        attachment.name = "Real CLI/XPC bridge assertions"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertEqual(process.terminationStatus, 0, combinedOutput)
        let summaryLine = combinedOutput
            .components(separatedBy: .newlines)
            .first { $0.hasPrefix("Bridge suite: total=") }
        XCTAssertNotNil(summaryLine, combinedOutput)
        let summaryParts = (summaryLine ?? "").split(separator: " ")
        func summaryCount(_ field: String) -> Int {
            guard let part = summaryParts.first(where: { $0.hasPrefix("\(field)=") }) else { return -1 }
            let value = part.dropFirst(field.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: ","))
            return Int(value) ?? -1
        }

        let total = summaryCount("total")
        XCTAssertEqual(total, contracts.count, combinedOutput)
        XCTAssertEqual(summaryCount("passed"), total, combinedOutput)
        XCTAssertEqual(summaryCount("skipped"), 0, combinedOutput)
    }
}
