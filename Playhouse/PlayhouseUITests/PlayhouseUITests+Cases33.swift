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
    /// A stable 0.1.0 copy of this test build and a signed feed offering 0.2.0, served over
    /// HTTP on 127.0.0.1 (see scripts/make-update-fixture.py), plus the environment pointing
    /// the app at them. The archive takes `servedSeconds` to send; `release` options
    /// (architecture, minimum-system) say what the release runs on. `feed` is the served folder.
    func makeUpdateFixture(
        tamper: String? = nil,
        root: String = "update-fixture",
        servedSeconds: Double = 0,
        release: [String: String] = [:]
    ) throws -> (installedApp: URL, feed: URL, environment: [String: String]) {
        let fixtureRoot = runDirectory.appendingPathComponent(root)
        let process = Process()
        process.executableURL = try directPython3()
        var arguments: [String] = [repositoryRoot.appendingPathComponent("scripts/make-update-fixture.py").path,
                                   "--source-app", appBundle.path,
                                   "--root", fixtureRoot.path,
                                   "--base-url", try serveUpdateFeed(fixtureRoot.appendingPathComponent("feed"), seconds: servedSeconds)]
        // scripts/test-ui.sh staged these apps outside the sandbox; see make-update-fixture.py.
        arguments += ["--apps", WorkspaceFixture.root.appendingPathComponent("update-apps").path]
        if let tamper { arguments += ["--tamper", tamper] }
        var environment = ProcessInfo.processInfo.environment
        environment["PLAYHOUSE_RELEASE_TOOL_CACHE"] = WorkspaceFixture.root.appendingPathComponent("release-tool").path
        process.environment = environment
        for (option, value) in release.sorted(by: { $0.key < $1.key }) { arguments += ["--\(option)", value] }
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        var errorData = Data()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errorData = errors.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "The update fixture failed: \(String(decoding: errorData, as: UTF8.self))")
        let made = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: String])
        let installed = URL(fileURLWithPath: try XCTUnwrap(made["installedApp"]), isDirectory: true)
        let feed = URL(fileURLWithPath: try XCTUnwrap(made["feed"]), isDirectory: true)
        return (installed, feed, [
            "PLAYHOUSE_E2E_UPDATE_FEED_URL": try XCTUnwrap(made["feedURL"]),
            "PLAYHOUSE_E2E_UPDATE_API_URL": try XCTUnwrap(made["releaseAPIURL"]),
            "PLAYHOUSE_E2E_UPDATE_PUBLIC_KEY": try XCTUnwrap(made["publicKey"]),
            "PLAYHOUSE_E2E_UPDATE_TARGET_APP": installed.path,
        ])
    }

    /// A python3 that runs itself. The runner is sandboxed, so /usr/bin/python3, which
    /// goes through xcrun, refuses to start ("cannot be used within an App Sandbox").
    func directPython3() throws -> URL {
        var candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3",
                          "/Library/Developer/CommandLineTools/usr/bin/python3"]
        if let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
            candidates.append(developer + "/usr/bin/python3")
        }
        candidates.append("/Applications/Xcode_26.5.app/Contents/Developer/usr/bin/python3")
        candidates.append("/Applications/Xcode.app/Contents/Developer/usr/bin/python3")
        let path = try XCTUnwrap(candidates.first { FileManager.default.isExecutableFile(atPath: $0) },
                                 "No python3 outside xcrun in \(candidates).")
        return URL(fileURLWithPath: path)
    }

    /// Serves a fixture feed folder over HTTP on 127.0.0.1 until the case ends; returns its address.
    func serveUpdateFeed(_ directory: URL, seconds: Double) throws -> String {
        let server = Process()
        server.executableURL = try directPython3()
        server.arguments = ["-u", repositoryRoot.appendingPathComponent("scripts/serve-update-feed.py").path,
                            "--directory", directory.path, "--seconds", String(seconds)]
        let output = Pipe()
        server.standardOutput = output
        let errorLog = runDirectory.appendingPathComponent("serve-update-feed-\(UUID().uuidString.prefix(8)).log")
        FileManager.default.createFile(atPath: errorLog.path, contents: nil)
        server.standardError = try FileHandle(forWritingTo: errorLog)
        try server.run()
        addTeardownBlock {
            server.terminate()
            server.waitUntilExit()
        }
        var line = Data()
        while !line.contains(UInt8(ascii: "\n")) {
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { break }
            line.append(chunk)
        }
        guard let started = (try? JSONSerialization.jsonObject(with: line)) as? [String: Int] else {
            server.waitUntilExit()
            let errors = (try? String(contentsOf: errorLog, encoding: .utf8)) ?? ""
            XCTFail("The feed server didn't start (exit \(server.terminationStatus)): \(errors)")
            throw CocoaError(.fileReadUnknown)
        }
        return "http://127.0.0.1:\(try XCTUnwrap(started["port"]))/"
    }

    /// Playhouse ▸ Check for Updates…, with the app menu left open.
    func openCheckForUpdatesMenuItem() -> XCUIElement {
        app.activate()
        let appMenu = app.menuBars.menuBarItems.element(boundBy: 1)
        appMenu.click()
        let item = appMenu.menuItems["Check for Updates…"]
        XCTAssertTrue(item.waitToExist(timeout: 5), "The app menu has Check for Updates….")
        return item
    }

    func bundleVersion(of app: URL) -> String? {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        return info?["CFBundleShortVersionString"] as? String
    }

    /// The version the app's own command-line tool reports.
    func installedCLIVersion(of app: URL) throws -> String? {
        let process = Process()
        process.executableURL = app.appendingPathComponent("Contents/MacOS/playhouse-cli")
        process.arguments = ["version"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["result"] as? [String: Any])?["version"] as? String
    }

    func updateStatus(_ environment: [String: String]) throws -> [String: Any] {
        try XCTUnwrap(try runCLI(["update", "status"], extraEnvironment: environment)["result"] as? [String: Any])
    }

    /// The update status, or nil while no daemon answers. The sandboxed runner can't start a
    /// daemon, so a poll that lands while the installer has stopped it must not fail the case.
    func runningUpdateStatus(_ environment: [String: String]) -> [String: Any]? {
        (try? runCLI(["update", "status"], expectedStatus: nil, extraEnvironment: environment))?["result"] as? [String: Any]
    }

    func openUpdateSettings() -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        let window = settingsWindow
        XCTAssertTrue(window.waitToExist(timeout: 10), "Settings did not open.")
        let summary = window.descendants(matching: .any).matching(identifier: "update-settings-summary").firstMatch
        XCTAssertTrue(summary.waitToExist(timeout: 10), "Settings should have an Updates section.")
        return window
    }

    func settingsText(_ window: XCUIElement, _ identifier: String) -> String {
        let element = window.descendants(matching: .any).matching(identifier: identifier).firstMatch
        return pluginText(element)
    }

    // case-contract: test_update_check_offers_signed_release_on_release_builds | A development build reports the development phase and refuses to check, download or install, and its Check for Updates menu item is disabled, so it never updates itself. A stable build checks the signed release feed: before a check it is up to date with no offer; a check offers the newer release with its version, release date and notes, shown as a compact Update button at the trailing end of the window's title bar whose tooltip names them, which a fresh read still reports, and finds it through the release's asset list (GitHub's latest-release API) when the feed link fails; the daily automatic check does not reach the feed again within a day, even when the feed is gone, while a manual check from the app menu then reports the failure; and turning daily checks off is saved and makes an automatic check a no-op. A newer release built for another architecture or needing a newer macOS is not offered. An app in a folder it can't write to says to move Playhouse to Applications, refuses to check, and doesn't offer even a release it already found, so no update button shows.
    func test_update_check_offers_signed_release_on_release_builds() throws {
        launchApp(defaultParent: fixture.parent.path)
        XCTAssertFalse(element("update-pill").waitToExist(timeout: 3), "A development build never offers an update.")
        var settings = openUpdateSettings()
        XCTAssertEqual(settingsText(settings, "update-settings-summary"), "This is a development build. It updates from source, not from releases.")
        XCTAssertFalse(settings.descendants(matching: .any).matching(identifier: "update-check-now-button").firstMatch.exists)
        attachScreenshot(named: "Development build: Settings says it updates from source")
        let disabledCheckItem = openCheckForUpdatesMenuItem()
        XCTAssertFalse(disabledCheckItem.isEnabled, "A development build can't check for updates.")
        attachRegionScreenshot([app.menuBars.menuBarItems.element(boundBy: 1), disabledCheckItem], named: "Development build: Check for Updates… is disabled", padding: 40)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual((try updateStatus([:]))["phase"] as? String, "development")
        for command in ["check", "download", "install"] {
            assertCLIError(try runCLI(["update", command], expectedStatus: 1), code: "development_build")
        }
        XCTAssertTrue(terminateAppAndWait(app))

        let update = try makeUpdateFixture()
        XCTAssertEqual((try updateStatus(update.environment))["phase"] as? String, "upToDate", "Nothing is offered before a check.")
        // The window's automatic check at launch finds the release, here through the release's
        // asset list (GitHub's latest-release API) because the feed link fails.
        var brokenLink = update.environment
        brokenLink["PLAYHOUSE_E2E_UPDATE_FEED_URL"] = try XCTUnwrap(update.environment["PLAYHOUSE_E2E_UPDATE_FEED_URL"])
            .replacingOccurrences(of: "playhouse-release.json", with: "missing.json")
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: brokenLink)
        let pill = element("update-pill")
        XCTAssertTrue(pill.waitToExist(timeout: 30), "A stable build should show the update button once its check finds 0.2.0.")
        XCTAssertEqual(pill.label, "Update to 0.2.0")
        XCTAssertEqual(pill.value as? String, "available")
        XCTAssertTrue(pill.isHittable)
        // It sits on the window's top border: in the title bar at its trailing end, above the board header.
        let window = app.windows.firstMatch
        let archiveButton = element("done-archive-button")
        XCTAssertLessThan(pill.frame.maxY, archiveButton.frame.minY, "The update button sits above the board header.")
        XCTAssertLessThan(pill.frame.minY - window.frame.minY, 30, "The update button sits in the title bar.")
        XCTAssertGreaterThan(pill.frame.maxX, window.frame.maxX - 40, "The update button sits at the title bar's trailing end.")
        XCTAssertLessThanOrEqual(pill.frame.height, 24, "The update button is a compact title-bar pill.")
        var shownText = ""
        XCTAssertTrue(waitUntil({
            shownText = self.recognizedWords(in: pill.screenshot())
            return shownText == "update"
        }, timeout: 5), "The button reads just Update; its label and tooltip carry the version, not its text: \(shownText)")
        assertNativeHelpText(for: pill, equals: "Playhouse 0.2.0, released November 18, 2026")
        assertNativeHelpText(for: pill, equals: "Faster boards and a new update button.")
        XCTAssertFalse(nativeHelpTextIsVisible("Click to download"), "The tooltip names the release and its notes only.")
        attachScreenshot(named: "Update button and its tooltip in the title bar")
        attachElementScreenshot(pill, named: "Update button close-up")
        var checked: [String: Any] = [:]
        XCTAssertTrue(waitUntil({
            checked = (try? self.updateStatus(update.environment)) ?? [:]
            return checked["lastCheckedAt"] is String
        }, timeout: 5), "The check that found the release should be recorded.")
        XCTAssertEqual((checked["available"] as? [String: Any])?["notes"] as? String, "Faster boards and a new update button.")
        let lastChecked = try XCTUnwrap(checked["lastCheckedAt"] as? String)

        // Relaunched within the day with the feed gone, the window keeps the offer without asking again.
        XCTAssertTrue(terminateAppAndWait(app))
        let manifest = update.feed.appendingPathComponent("playhouse-release.json")
        let signedManifest = try Data(contentsOf: manifest)
        try FileManager.default.removeItem(at: manifest)
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: update.environment)
        XCTAssertTrue(element("update-pill").waitToExist(timeout: 20), "The stored offer should still show.")
        // The stored offer shows before the window's automatic check runs; give it time to (wrongly) run.
        XCTAssertFalse(waitUntil({ (try? self.updateStatus(update.environment))?["lastCheckedAt"] as? String != lastChecked }, timeout: 5),
                       "The automatic check must not run again within a day.")
        settings = openUpdateSettings()
        XCTAssertEqual(settingsText(settings, "update-current-version"), "Playhouse 0.1.0")
        XCTAssertEqual(settingsText(settings, "update-settings-summary"), "Playhouse 0.2.0 is available.")
        let checkItem = openCheckForUpdatesMenuItem()
        XCTAssertTrue(checkItem.isEnabled, "A stable build can check for updates from the app menu.")
        checkItem.click()
        XCTAssertTrue(waitUntil({ (try? self.updateStatus(update.environment))?["phase"] as? String == "failed" }, timeout: 15),
                      "A manual check with the feed gone should fail.")
        let checkError = try XCTUnwrap((try updateStatus(update.environment))["error"] as? String)
        XCTAssertFalse(checkError.isEmpty)
        XCTAssertTrue(waitUntil({ self.settingsText(settings, "update-settings-summary") == checkError }, timeout: 10),
                      "Settings should show why the check failed: \(checkError)")
        attachScreenshot(named: "Settings after a manual check failed")

        let toggle = settings.descendants(matching: .any).matching(identifier: "update-auto-check-toggle").firstMatch
        XCTAssertEqual(toggle.value as? Int, 1)
        toggle.click()
        XCTAssertTrue(waitUntil({ (try? self.updateStatus(update.environment))?["autoCheck"] as? Bool == false }, timeout: 10),
                      "Turning daily checks off should be saved.")
        XCTAssertTrue(waitUntil({ toggle.value as? Int == 0 }, timeout: 5))
        attachScreenshot(named: "Settings with daily update checks turned off")
        try Data("{}".utf8).write(to: dataDirectory.appendingPathComponent("Updates/state.json"))
        let skipped = try XCTUnwrap(try runCLI(["update", "check", "--automatic", "true"], extraEnvironment: update.environment)["result"] as? [String: Any])
        XCTAssertNil(skipped["lastCheckedAt"], "An automatic check must not run while daily checks are off.")
        XCTAssertEqual(skipped["phase"] as? String, "upToDate")
        XCTAssertTrue(terminateAppAndWait(app))

        // A newer release this Mac can't run is not offered.
        let intel = try makeUpdateFixture(root: "update-fixture-intel", release: ["architecture": "x86_64"])
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: intel.environment)
        settings = openUpdateSettings()
        settings.descendants(matching: .any).matching(identifier: "update-check-now-button").firstMatch.click()
        XCTAssertTrue(waitUntil({ self.settingsText(settings, "update-settings-summary").hasPrefix("Up to date.") }, timeout: 15),
                      "An Intel-only release is not offered on Apple silicon.")
        XCTAssertNil((try updateStatus(intel.environment))["available"])
        attachScreenshot(named: "Settings: up to date when the newer release is Intel-only")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertFalse(element("update-pill").waitToExist(timeout: 2), "An Intel-only release is never offered.")
        try Data("{}".utf8).write(to: dataDirectory.appendingPathComponent("Updates/state.json"))
        let future = try makeUpdateFixture(root: "update-fixture-future-macos", release: ["minimum-system": "99.0"])
        let unsupported = try XCTUnwrap(try runCLI(["update", "check"], extraEnvironment: future.environment)["result"] as? [String: Any])
        XCTAssertEqual(unsupported["phase"] as? String, "upToDate", "A release for a future macOS is not offered.")
        XCTAssertNil(unsupported["available"])
        XCTAssertTrue(terminateAppAndWait(app))

        // An app in a folder it can't write to, as when run from a disk image, can't replace itself,
        // so even a release it already found isn't offered.
        try signedManifest.write(to: manifest)
        XCTAssertEqual((try XCTUnwrap(try runCLI(["update", "check"], extraEnvironment: update.environment)["result"] as? [String: Any]))["phase"] as? String,
                       "available")
        let installedFolder = update.installedApp.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: installedFolder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedFolder.path) }
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: update.environment)
        settings = openUpdateSettings()
        XCTAssertTrue(waitUntil({ self.settingsText(settings, "update-settings-summary") == "Move Playhouse to Applications to receive updates." }, timeout: 15),
                      "Settings should say to move Playhouse to Applications.")
        XCTAssertFalse(settings.descendants(matching: .any).matching(identifier: "update-check-now-button").firstMatch.exists)
        attachScreenshot(named: "Settings asks to move Playhouse to Applications")
        let misplaced = try updateStatus(update.environment)
        XCTAssertEqual(misplaced["phase"] as? String, "misplaced")
        XCTAssertNil(misplaced["available"])
        assertCLIError(try runCLI(["update", "check"], expectedStatus: 1, extraEnvironment: update.environment), code: "update_location")
        XCTAssertFalse(openCheckForUpdatesMenuItem().isEnabled, "An app that can't replace itself can't check for updates.")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10))
        XCTAssertFalse(element("update-pill").waitToExist(timeout: 3), "An app that can't replace itself shows no update button.")
        attachScreenshot(named: "Board header without an update button when Playhouse can't replace itself")
    }

    // case-contract: test_update_rejects_tampered_release | A release whose manifest is signed by another key is refused at check time, so nothing is offered and the failure is shown with the signature reason. A release whose archive grew after signing is offered but refused at download for its size, and one with a changed byte of the same size is refused for its checksum: each time nothing is staged beside the installed app, the failure is shown with its reason, installing reports there is nothing ready, and the installed app is untouched.
    func test_update_rejects_tampered_release() throws {
        var update = try makeUpdateFixture(tamper: "signature")
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: update.environment)
        let settings = openUpdateSettings()
        settings.descendants(matching: .any).matching(identifier: "update-check-now-button").firstMatch.click()
        XCTAssertTrue(waitUntil({ (try? self.updateStatus(update.environment))?["phase"] as? String == "failed" }, timeout: 15))
        XCTAssertTrue(waitUntil({ self.settingsText(settings, "update-settings-summary").localizedCaseInsensitiveContains("signature") }, timeout: 10),
                      "Settings should say the release's signature was refused.")
        XCTAssertNil((try updateStatus(update.environment))["available"])
        attachScreenshot(named: "A release signed by another key is refused")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertFalse(element("update-pill").waitToExist(timeout: 2), "A refused release is never offered.")
        attachScreenshot(named: "Board header without an update button after the refused release")
        XCTAssertTrue(terminateAppAndWait(app))

        for (tamper, reason) in [("archive", "bytes"), ("checksum", "checksum")] {
            try FileManager.default.removeItem(at: dataDirectory.appendingPathComponent("Updates"))
            update = try makeUpdateFixture(tamper: tamper)
            launchApp(defaultParent: fixture.parent.path, environmentOverrides: update.environment)
            let pill = element("update-pill")
            XCTAssertTrue(pill.waitToExist(timeout: 30))
            XCTAssertEqual(pill.label, "Update to 0.2.0")
            pill.click()
            XCTAssertTrue(waitUntil({ pill.label == "Update failed" }, timeout: 30), "A changed archive (\(tamper)) should fail its download check.")
            XCTAssertEqual(pill.value as? String, "failed")
            assertNativeHelpText(for: pill, equals: "Click to try again.")
            attachScreenshot(named: "Update failed after the archive's \(reason) didn't match its signed release")
            let status = try updateStatus(update.environment)
            let error = status["error"] as? String ?? ""
            XCTAssertTrue(error.contains(reason), "\(status)")
            let settings = openUpdateSettings()
            XCTAssertTrue(waitUntil({ self.settingsText(settings, "update-settings-summary") == error }, timeout: 10),
                          "Settings should show why the download was refused: \(error)")
            attachScreenshot(named: "Settings shows the \(reason) reason for the refused download")
            XCTAssertFalse(FileManager.default.fileExists(atPath: update.installedApp.deletingLastPathComponent().appendingPathComponent(".Playhouse.app.update").path))
            assertCLIError(try runCLI(["update", "install"], expectedStatus: 1, extraEnvironment: update.environment), code: "no_update")
            XCTAssertEqual(bundleVersion(of: update.installedApp), "0.1.0")
            XCTAssertTrue(terminateAppAndWait(app))
        }
    }

    // case-contract: test_update_download_reports_progress_and_cancels | Downloading a checked release from a feed served over HTTP reports its progress while it runs, rising to the whole archive, and a second download meanwhile is refused as busy. Canceling stops it, keeps the release offered without a failure, and leaves nothing staged or half-downloaded; canceling with no download running is refused. A check when the feed is gone is reported as unreachable and shown as a failed update that keeps the release offered. Retrying once the feed is back downloads and stages the release with progress rising to the whole archive, and a half-written message then holds the restart: it waits to restart into the staged release while the installed app stays the old version.
    func test_update_download_reports_progress_and_cancels() throws {
        // Slow enough that the download is still running while it is inspected and canceled.
        let update = try makeUpdateFixture(servedSeconds: 40)
        XCTAssertTrue(try XCTUnwrap(update.environment["PLAYHOUSE_E2E_UPDATE_FEED_URL"]).hasPrefix("http://127.0.0.1:"))
        let staged = update.installedApp.deletingLastPathComponent().appendingPathComponent(".Playhouse.app.update")
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: update.environment)
        let pill = element("update-pill")
        XCTAssertTrue(pill.waitToExist(timeout: 30), "The window's check finds 0.2.0 on the served feed.")
        XCTAssertEqual(pill.label, "Update to 0.2.0")
        assertCLIError(try runCLI(["update", "cancel"], expectedStatus: 1, extraEnvironment: update.environment), code: "no_download")

        // The download reports how far it got while it runs; clicking again cancels it and keeps the offer.
        pill.click()
        XCTAssertTrue(waitUntil({ pill.label.hasPrefix("Downloading ") && pill.label != "Downloading 0%" }, timeout: 15),
                      "The button should show how far the download got: \(pill.label)")
        XCTAssertEqual(pill.value as? String, "downloading")
        XCTAssertTrue(pill.isEnabled, "A running download can be canceled.")
        let downloading = try updateStatus(update.environment)
        XCTAssertEqual(downloading["phase"] as? String, "downloading")
        let progress = try XCTUnwrap(downloading["progress"] as? Double)
        XCTAssertTrue(progress > 0 && progress < 1, "\(downloading)")
        assertCLIError(try runCLI(["update", "download"], expectedStatus: 1, extraEnvironment: update.environment), code: "update_busy")
        attachScreenshot(named: "Downloading the update with its progress")
        attachElementScreenshot(pill, named: "Downloading button close-up")
        assertNativeHelpText(for: pill, equals: "Click to cancel.")
        XCTAssertEqual(pill.value as? String, "downloading", "The download should still be running when it is canceled.")
        pill.click()
        XCTAssertTrue(waitUntil({ pill.label == "Update to 0.2.0" }, timeout: 15), "Canceling should offer the release again.")
        XCTAssertEqual(pill.value as? String, "available")
        let canceled = try updateStatus(update.environment)
        XCTAssertEqual(canceled["phase"] as? String, "available")
        XCTAssertNil(canceled["error"], "A canceled download isn't a failure.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "A canceled download stages nothing.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent("Updates/download").path))
        attachScreenshot(named: "Update offered again after canceling the download")

        // A feed that isn't there is reported as unreachable, and the release stays offered to retry.
        let manifest = update.feed.appendingPathComponent("playhouse-release.json")
        let signed = try Data(contentsOf: manifest)
        try FileManager.default.removeItem(at: manifest)
        let settings = openUpdateSettings()
        let checkItem = openCheckForUpdatesMenuItem()
        XCTAssertTrue(checkItem.isEnabled)
        checkItem.click()
        XCTAssertTrue(waitUntil({ (try? self.updateStatus(update.environment))?["phase"] as? String == "failed" }, timeout: 15),
                      "A check with the feed gone should fail.")
        let error = try XCTUnwrap((try updateStatus(update.environment))["error"] as? String)
        XCTAssertTrue(waitUntil({ self.settingsText(settings, "update-settings-summary") == error }, timeout: 10),
                      "Settings should show why the check failed: \(error)")
        assertCLIError(try runCLI(["update", "check"], expectedStatus: 1, extraEnvironment: update.environment), code: "update_unreachable")
        attachScreenshot(named: "Settings after the served feed went away")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitUntil({ pill.label == "Update failed" }, timeout: 10), "The button should say the update failed: \(pill.label)")
        XCTAssertEqual(pill.value as? String, "failed")
        assertNativeHelpText(for: pill, equals: "Click to try again.")
        attachScreenshot(named: "Update failed, click to try again")

        // Retrying once the feed is back downloads the release; a half-written message then holds the restart.
        try signed.write(to: manifest)
        let drafted = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Update download waits for a draft", "--prompt", "Fixture task description.", "--root", fixture.primary.path,
        ])["result"] as? [String: Any])
        let draftedID = try XCTUnwrap(drafted["id"] as? String)
        XCTAssertEqual((try runCLI(["task", "draft", draftedID, "--text", "Half-written message"])["result"] as? [String: Any])?["hasUnsentDraft"] as? Bool, true)
        pill.click()
        XCTAssertTrue(waitUntil({ pill.label.hasPrefix("Downloading ") }, timeout: 15), "Clicking Update failed retries the download.")
        XCTAssertTrue(waitUntil({ pill.value as? String == "waiting" }, timeout: 90), "The finished download should wait for the half-written message.")
        XCTAssertEqual(pill.label, "Restart to update")
        assertNativeHelpText(for: pill, equals: "message is being written")
        attachScreenshot(named: "Downloaded update waiting for a half-written message")
        let waiting = try updateStatus(update.environment)
        XCTAssertEqual(waiting["phase"] as? String, "waiting")
        XCTAssertEqual(waiting["unsentDrafts"] as? Int, 1)
        XCTAssertNil(waiting["error"])
        XCTAssertNil(waiting["lastInstall"])
        XCTAssertEqual(bundleVersion(of: staged), "0.2.0")
        XCTAssertEqual(bundleVersion(of: update.installedApp), "0.1.0")
        assertCLIError(try runCLI(["update", "cancel"], expectedStatus: 1, extraEnvironment: update.environment), code: "no_download")
    }

    // case-contract: test_update_install_replaces_app_cli_and_daemon | Downloading a checked release reports progress and stages it beside the installed app, ready to restart. Installing swaps the whole bundle in place, so the app, its command-line tool and its bridge daemon are the new version; the running daemon is stopped and the next request starts a new one; the staged and previous copies are cleaned up; the app is told it was updated, with the release notes, until the notice is opened, which saves it as seen, or a day has passed; the offer is gone, and checking the same feed again reports it up to date.
    func test_update_install_replaces_app_cli_and_daemon() throws {
        let update = try makeUpdateFixture()
        XCTAssertEqual((try runCLI(["update", "check"], extraEnvironment: update.environment)["result"] as? [String: Any])?["phase"] as? String, "available")
        let download = try startCLIProcess(["update", "download"], extraEnvironment: update.environment)
        let (downloaded, events) = try finishCLIProcessCapturingEvents(download)
        XCTAssertEqual((downloaded["result"] as? [String: Any])?["phase"] as? String, "ready")
        let progress = events.filter { $0["type"] as? String == "update_progress" }.compactMap { ($0["payload"] as? [String: Any])?["progress"] as? Double }
        XCTAssertEqual(progress.last, 1, "The download should report progress up to 1: \(events)")
        let staged = update.installedApp.deletingLastPathComponent().appendingPathComponent(".Playhouse.app.update")
        XCTAssertEqual(bundleVersion(of: staged), "0.2.0")
        XCTAssertEqual(bundleVersion(of: update.installedApp), "0.1.0")
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: update.environment)
        let pill = element("update-pill")
        XCTAssertTrue(pill.waitToExist(timeout: 30))
        XCTAssertEqual(pill.label, "Restart to update", "A downloaded release is ready to restart into.")
        XCTAssertEqual(pill.value as? String, "ready")
        assertNativeHelpText(for: pill, equals: "restart into it")
        var shownText = ""
        XCTAssertTrue(waitUntil({ shownText = self.recognizedWords(in: pill.screenshot()); return shownText.contains("restart to update") }, timeout: 5), "The title-bar button grows to show its longer text in full: \(shownText)")
        attachScreenshot(named: "Restart to update with the release downloaded")
        attachElementScreenshot(pill, named: "Restart to update button close-up")
        let daemonBefore = try XCTUnwrap((try runCLI(["status"])["result"] as? [String: Any])?["processID"] as? Int)
        pill.click()
        // The window watches the installer, which updates the copy this test installed.
        let notice = element("update-notice")
        XCTAssertTrue(notice.waitToExist(timeout: 90), "The window should say the update installed.")
        XCTAssertEqual(notice.label, "Updated to 0.2.0")
        XCTAssertEqual(notice.value as? String, "installed")
        XCTAssertFalse(element("update-pill").exists, "The offer is gone once the update installed.")
        XCTAssertTrue(waitUntil({ shownText = self.recognizedWords(in: notice.screenshot()); return shownText.contains("updated to 0 2 0") }, timeout: 5), "The notice shows its text in full in the title bar: \(shownText)")
        attachScreenshot(named: "Updated to 0.2.0 notice after the install")
        attachElementScreenshot(notice, named: "Updated to 0.2.0 notice close-up")

        XCTAssertEqual(bundleVersion(of: update.installedApp), "0.2.0")
        XCTAssertEqual(try installedCLIVersion(of: update.installedApp), "0.2.0")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: update.installedApp.appendingPathComponent("Contents/MacOS/playhouse-daemon").path))
        let parent = update.installedApp.deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent(".Playhouse.app.update").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent(".Playhouse.app.previous").path))
        let daemonAfter = try XCTUnwrap((try runCLI(["status"])["result"] as? [String: Any])?["processID"] as? Int)
        XCTAssertNotEqual(daemonAfter, daemonBefore, "The installer should stop the old daemon so a new one starts.")
        XCTAssertTrue(waitUntil({ kill(pid_t(daemonBefore), 0) != 0 }, timeout: 25), "The old daemon exits.")

        let status = try updateStatus(update.environment)
        XCTAssertEqual(status["currentVersion"] as? String, "0.2.0")
        XCTAssertEqual(status["phase"] as? String, "upToDate")
        XCTAssertEqual((status["lastInstall"] as? [String: Any])?["acknowledged"] as? Bool, false, "The notice shows until it is opened.")
        let launched = try XCTUnwrap(try runCLI(["update", "launched"], extraEnvironment: update.environment)["result"] as? [String: Any])
        XCTAssertEqual((launched["lastInstall"] as? [String: Any])?["notes"] as? String, "Faster boards and a new update button.",
                       "Until it is opened, the notice comes back with the release's notes.")
        assertNativeHelpText(for: notice, equals: "Click to see what's new.")
        notice.click()
        let notesTitle = app.descendants(matching: .any).matching(identifier: "update-notes-title").firstMatch
        XCTAssertTrue(notesTitle.waitToExist(timeout: 10), "Clicking the notice shows what's new.")
        XCTAssertEqual(pluginText(notesTitle), "What's new in Playhouse 0.2.0")
        XCTAssertEqual(pluginText(app.descendants(matching: .any).matching(identifier: "update-notes-body").firstMatch),
                       "Faster boards and a new update button.")
        attachScreenshot(named: "What's new in Playhouse 0.2.0")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil({ !notesTitle.exists && !notice.exists }, timeout: 5), "Closing the notes dismisses the notice.")
        XCTAssertTrue(waitUntil({ ((try? self.updateStatus(update.environment))?["lastInstall"] as? [String: Any])?["acknowledged"] as? Bool == true }, timeout: 10),
                      "The opened notice is saved as seen.")
        XCTAssertNil(try XCTUnwrap(try runCLI(["update", "launched"], extraEnvironment: update.environment)["result"] as? [String: Any])["lastInstall"],
                     "An opened notice isn't shown again.")
        XCTAssertFalse(element("update-pill").waitToExist(timeout: 2), "Nothing is offered once the update is installed and its notice dismissed.")
        attachScreenshot(named: "Board header after dismissing the update notice")
        let settings = openUpdateSettings()
        settings.descendants(matching: .any).matching(identifier: "update-check-now-button").firstMatch.click()
        XCTAssertTrue(waitUntil({ self.settingsText(settings, "update-settings-summary").hasPrefix("Up to date.") }, timeout: 15),
                      "Checking the same feed again should report it up to date.")
        XCTAssertEqual(settingsText(settings, "update-current-version"), "Playhouse 0.2.0")
        attachScreenshot(named: "Settings reports Playhouse 0.2.0 up to date")
        XCTAssertTrue(terminateAppAndWait(app))

        // An unopened notice from more than a day ago isn't shown when the window opens.
        let recordFile = dataDirectory.appendingPathComponent("Updates/last-install.json")
        var record = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: recordFile)) as? [String: Any])
        record["acknowledged"] = false
        record["finishedAt"] = "2026-01-01T00:00:00Z"
        try JSONSerialization.data(withJSONObject: record).write(to: recordFile)
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: update.environment)
        XCTAssertTrue(element("board-title").waitToExist(timeout: 20))
        XCTAssertTrue(waitUntil({ (try? self.updateStatus(update.environment))?["lastInstall"] != nil }, timeout: 5),
                      "The old install is still on record.")
        XCTAssertFalse(element("update-notice").waitToExist(timeout: 5), "A notice older than a day isn't shown.")
        attachScreenshot(named: "Board header without a notice a day after the install")
    }

    // case-contract: test_update_install_rolls_back_broken_release | A release whose bridge daemon doesn't run passes download verification but fails the installer's health check after the swap, so the installer puts the previous version back: the installed app, command-line tool and daemon are the old version again, nothing is left staged, and the app is told that the update didn't install and why until that is dismissed, while the release stays offered. A release whose command-line tool doesn't run can't start its own installer, so the install is reported as failed until dismissed and the installed app is untouched.
    func test_update_install_rolls_back_broken_release() throws {
        let update = try makeUpdateFixture(tamper: "broken")
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: update.environment)
        let pill = element("update-pill")
        XCTAssertTrue(pill.waitToExist(timeout: 30))
        pill.click()
        let notice = element("update-notice")
        XCTAssertTrue(notice.waitToExist(timeout: 90), "The window should say the update didn't install.")
        XCTAssertEqual(notice.label, "Update didn't install")
        XCTAssertEqual(notice.value as? String, "rolledBack")
        assertNativeHelpText(for: notice, equals: "so 0.1.0 was put back.")
        assertNativeHelpText(for: notice, equals: "bridge daemon")
        attachScreenshot(named: "Update didn't install notice after the rollback")

        XCTAssertEqual(bundleVersion(of: update.installedApp), "0.1.0")
        XCTAssertEqual(try installedCLIVersion(of: update.installedApp), "0.1.0")
        let parent = update.installedApp.deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent(".Playhouse.app.update").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent(".Playhouse.app.previous").path))
        let updater = try String(contentsOf: dataDirectory.appendingPathComponent("Updates/Updater.log"), encoding: .utf8)
        XCTAssertTrue(updater.contains("rolling back"), updater)
        let status = try updateStatus(update.environment)
        XCTAssertEqual(status["currentVersion"] as? String, "0.1.0")
        XCTAssertEqual((status["lastInstall"] as? [String: Any])?["status"] as? String, "rolledBack")
        XCTAssertEqual(((try runCLI(["update", "launched"], extraEnvironment: update.environment)["result"] as? [String: Any])?["lastInstall"] as? [String: Any])?["status"] as? String,
                       "rolledBack", "The rollback is shown until it is dismissed.")
        assertNativeHelpText(for: notice, equals: "Click to dismiss.")

        notice.click()
        XCTAssertTrue(waitUntil({ !notice.exists }, timeout: 5), "Clicking the notice dismisses it.")
        XCTAssertNil(try XCTUnwrap(try runCLI(["update", "launched"], extraEnvironment: update.environment)["result"] as? [String: Any])["lastInstall"],
                     "A dismissed rollback isn't shown again.")
        XCTAssertTrue(pill.waitToExist(timeout: 10), "Dismissing the notice shows the release still on offer.")
        XCTAssertEqual(pill.label, "Update to 0.2.0")
        XCTAssertEqual(pill.value as? String, "available")
        attachScreenshot(named: "Release still offered after the rollback notice is dismissed")
        XCTAssertTrue(terminateAppAndWait(app))

        // A release whose command-line tool can't run can't start its own installer.
        try FileManager.default.removeItem(at: dataDirectory.appendingPathComponent("Updates"))
        let unrunnable = try makeUpdateFixture(tamper: "installer")
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: unrunnable.environment)
        let relaunchedPill = element("update-pill")
        XCTAssertTrue(relaunchedPill.waitToExist(timeout: 30))
        relaunchedPill.click()
        let failedNotice = element("update-notice")
        XCTAssertTrue(failedNotice.waitToExist(timeout: 90), "The window should say the update didn't install.")
        XCTAssertEqual(failedNotice.label, "Update didn't install")
        XCTAssertEqual(failedNotice.value as? String, "failed")
        assertNativeHelpText(for: failedNotice, equals: "0.1.0 is unchanged.")
        attachScreenshot(named: "Update didn't install notice when the release's installer can't run")
        XCTAssertEqual(bundleVersion(of: unrunnable.installedApp), "0.1.0")
        XCTAssertEqual(try installedCLIVersion(of: unrunnable.installedApp), "0.1.0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: unrunnable.installedApp.deletingLastPathComponent().appendingPathComponent(".Playhouse.app.previous").path))
        XCTAssertEqual(((try runCLI(["update", "launched"], extraEnvironment: unrunnable.environment)["result"] as? [String: Any])?["lastInstall"] as? [String: Any])?["status"] as? String,
                       "failed", "The failure is shown until it is dismissed.")
        failedNotice.click()
        XCTAssertTrue(waitUntil({ !failedNotice.exists }, timeout: 5), "Clicking the notice dismisses it.")
        XCTAssertNil(try XCTUnwrap(try runCLI(["update", "launched"], extraEnvironment: unrunnable.environment)["result"] as? [String: Any])["lastInstall"],
                     "A dismissed failure isn't shown again.")
    }

    // case-contract: test_update_waits_for_running_agents_before_installing | While an agent is running a turn and a message typed in another task is unsent, installing a downloaded release once agents are idle doesn't start the installer: it reports one running agent and one message being written, the update is saved as waiting with Restart to update and a tooltip giving both reasons, and the installed app stays the old version. A task's unsent description that was never typed in the composer doesn't hold it. When the turn finishes the half-written message still holds the install; once it is cleared, the daemon installs the release by itself without another request, the turn's answer is kept once, and the installed app and its command-line tool are the new version.
    func test_update_waits_for_running_agents_before_installing() throws {
        let executable = WorkspaceFixture.root.appendingPathComponent("claude-fixture-reattach").path
        claudeFixtureExecutable = executable
        clearReattachMarkers(executable)
        let update = try makeUpdateFixture()
        let task = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Update waits for agents", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(task["id"] as? String)
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: update.environment)
        let pill = element("update-pill")
        XCTAssertTrue(pill.waitToExist(timeout: 30))
        XCTAssertEqual(pill.label, "Update to 0.2.0")

        let sender = try startCLIProcess(["conversation", "send", taskID, "--message", "Keep working while an update waits."])
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: executable + ".reattach-ready") }, timeout: 20), "The turn should be running.")
        XCTAssertTrue(waitUntil({
            !((((try? self.runCLI(["conversation", "runtime"]))?["result"] as? [String: Any])?["activeThreadIDs"] as? [Any]) ?? []).isEmpty
        }, timeout: 15), "The turn is active.")
        // A message typed in another task but not sent holds the install too. That task's
        // unsent description was never typed in the composer, so it doesn't.
        let drafted = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Update waits for drafts", "--prompt", "Unsent description.", "--root", fixture.primary.path,
        ])["result"] as? [String: Any])
        let draftedID = try XCTUnwrap(drafted["id"] as? String)
        openTask(named: "Update waits for drafts")
        let composer = element("message-composer")
        XCTAssertTrue(composer.waitToExist(timeout: 10))
        composer.click()
        composer.typeKey("a", modifierFlags: .command)
        composer.typeText("Half-written message")
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: draftedID)?["savedPrompt"] as? String) == "Half-written message" }, timeout: 10),
                      "The typed message is saved as the task's unsent draft.")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10))
        pill.click()
        XCTAssertTrue(waitUntil({ pill.value as? String == "waiting" }, timeout: 60), "The downloaded update should wait for the running agent.")
        XCTAssertEqual(pill.label, "Restart to update")
        assertNativeHelpText(for: pill, equals: "1 agent is still working and a message is being written")
        attachScreenshot(named: "Restart to update waiting for a running agent and a half-written message")
        attachElementScreenshot(pill, named: "Restart to update waiting close-up")
        // Longer than the daemon's idle check: it keeps waiting while the agent works.
        Thread.sleep(forTimeInterval: 3)
        let waiting = try updateStatus(update.environment)
        XCTAssertEqual(waiting["phase"] as? String, "waiting")
        XCTAssertEqual(waiting["activeTurns"] as? Int, 1)
        XCTAssertEqual(waiting["unsentDrafts"] as? Int, 1)
        XCTAssertNil(waiting["lastInstall"])
        XCTAssertEqual(bundleVersion(of: update.installedApp), "0.1.0")
        XCTAssertEqual(bundleVersion(of: update.installedApp.deletingLastPathComponent().appendingPathComponent(".Playhouse.app.update")), "0.2.0")
        XCTAssertEqual(pill.value as? String, "waiting")

        touch(executable + ".reattach-release")
        let (sent, _) = try finishCLIProcessCapturingEvents(sender)
        XCTAssertEqual(sent["ok"] as? Bool, true)
        // The turn is over, but the half-written message still holds the install.
        XCTAssertTrue(waitUntil({ (try? self.updateStatus(update.environment))?["activeTurns"] as? Int == 0 }, timeout: 20),
                      "The finished turn no longer holds the install.")
        Thread.sleep(forTimeInterval: 3)
        let drafting = try updateStatus(update.environment)
        XCTAssertEqual(drafting["phase"] as? String, "waiting", "\(drafting)")
        XCTAssertEqual(drafting["unsentDrafts"] as? Int, 1)
        XCTAssertEqual(bundleVersion(of: update.installedApp), "0.1.0")
        XCTAssertEqual(pill.value as? String, "waiting")
        assertNativeHelpText(for: pill, equals: "A message is being written, so Playhouse restarts by itself when no message has been edited for 10 minutes.")
        attachScreenshot(named: "Restart to update waiting for a half-written message")
        openTask(named: "Update waits for drafts")
        XCTAssertTrue(composer.waitToExist(timeout: 10))
        composer.click()
        composer.typeKey("a", modifierFlags: .command)
        composer.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: draftedID)?["hasUnsentDraft"] as? Bool) == false }, timeout: 10),
                      "Clearing the message leaves no unsent draft.")
        element("back-to-board-button").click()
        // Nothing is clicked again: the daemon installs once nothing holds it.
        let notice = element("update-notice")
        XCTAssertTrue(notice.waitToExist(timeout: 90), "The window should say the update installed once the agent finished.")
        XCTAssertEqual(notice.label, "Updated to 0.2.0")
        XCTAssertEqual(notice.value as? String, "installed")
        attachScreenshot(named: "Updated to 0.2.0 after the running agent finished")
        XCTAssertEqual(bundleVersion(of: update.installedApp), "0.2.0")
        XCTAssertEqual(try installedCLIVersion(of: update.installedApp), "0.2.0")
        let diagnostics = try String(contentsOf: dataDirectory.appendingPathComponent("Diagnostics.jsonl"), encoding: .utf8)
        XCTAssertTrue(diagnostics.contains("update.install_when_idle"), "The daemon started the install by itself.")
        XCTAssertEqual(try historyTexts(taskID: taskID).filter { $0 == "After restart." }.count, 1)
        let after = try updateStatus(update.environment)
        XCTAssertNotEqual(after["phase"] as? String, "waiting")
        XCTAssertNil(after["activeTurns"])
    }

    // case-contract: test_update_installs_over_its_own_app_and_daemon | The installed app's own command-line tool accepts its bundle with verify-bundle and refuses a copy changed after signing. Updating the app a request comes from, with no test target, stops that app's own bridge daemon on its private service and installs over it, so the app, its command-line tool and the next daemon on that service report the new version; a daemon another service started from the old bundle reports that it was replaced on disk and is retired by the next request, which starts one from the new bundle (the visible suite's sandboxed runner can't start a daemon itself, so only the headless suite starts one on another service). With the app's window running, the installer asks it to quit, the app quits by itself rather than being stopped, and the installer reopens the new version in the same data folder and bridge service, where it says it was updated; the headless suite runs no window, so nothing is reopened.
    func test_update_installs_over_its_own_app_and_daemon() throws {
        let update = try makeUpdateFixture()
        let ownCLI = update.installedApp.appendingPathComponent("Contents/MacOS/playhouse-cli")
        // No test target: the update replaces the app the window runs from.
        var environment = update.environment.filter { $0.key != "PLAYHOUSE_E2E_UPDATE_TARGET_APP" }
        environment.merge(restartServiceEnvironment()) { _, new in new }
        defer { _ = try? runCLI(["daemon", "shutdown"], extraEnvironment: environment, cli: ownCLI) }
        let verified = try XCTUnwrap(try runCLI(["update", "verify-bundle", "--bundle", update.installedApp.path, "--version", "0.1.0"], cli: ownCLI)["result"] as? [String: Any])
        XCTAssertEqual(verified["version"] as? String, "0.1.0")
        let altered = runDirectory.appendingPathComponent("altered/Playhouse.app")
        try FileManager.default.createDirectory(at: altered.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: update.installedApp, to: altered)
        try Data("changed".utf8).write(to: altered.appendingPathComponent("Contents/Resources/added-after-signing.txt"))
        assertCLIError(try runCLI(["update", "verify-bundle", "--bundle", altered.path], expectedStatus: 1, cli: ownCLI), code: "update_rejected")

        launchApp(defaultParent: fixture.parent.path, environmentOverrides: environment, appURL: update.installedApp)
        let pill = element("update-pill")
        XCTAssertTrue(pill.waitToExist(timeout: 30), "The installed 0.1.0 copy should offer 0.2.0.")
        XCTAssertEqual(pill.label, "Update to 0.2.0")
        attachScreenshot(named: "Installed 0.1.0 copy offers 0.2.0")
        let before = try XCTUnwrap(try runCLI(["daemon", "info"], extraEnvironment: environment, cli: ownCLI)["result"] as? [String: Any])
        XCTAssertEqual(before["appVersion"] as? String, "0.1.0")
        XCTAssertEqual(before["replacedOnDisk"] as? Bool, false)
        let daemonBefore = try XCTUnwrap(before["processID"] as? Int)

        pill.click()
        // The installer quits this window, swaps the bundle and opens the new version.
        XCTAssertTrue(waitUntil({ self.bundleVersion(of: update.installedApp) == "0.2.0" }, timeout: 90), "The bundle should be replaced.")
        var record: [String: Any] = [:]
        XCTAssertTrue(waitUntil({
            record = self.runningUpdateStatus(environment)?["lastInstall"] as? [String: Any] ?? [:]
            return !record.isEmpty
        }, timeout: 90), "The installer should record its result once the reopened app starts the next daemon.")
        XCTAssertEqual(record["status"] as? String, "installed", "\(record)")
        let log = try String(contentsOf: dataDirectory.appendingPathComponent("Updates/Updater.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("asking the running app to quit"), log)
        XCTAssertFalse(log.contains("didn't quit"), "The app should quit when the installer asks, not be stopped: \(log)")
        XCTAssertTrue(log.contains("stopping the bridge daemon (\(daemonBefore))"), log)
        XCTAssertTrue(log.contains("opening \(update.installedApp.path) on bridge service \(try XCTUnwrap(environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"]))"), log)
        app = XCUIApplication(url: update.installedApp)
        let notice = element("update-notice")
        XCTAssertTrue(notice.waitToExist(timeout: 60), "The reopened app should say it was updated.")
        XCTAssertEqual(notice.label, "Updated to 0.2.0")
        XCTAssertEqual(notice.value as? String, "installed")
        XCTAssertTrue(element("board-title").exists, "The reopened app shows the same board.")
        attachScreenshot(named: "Reopened as 0.2.0 after updating itself")
        XCTAssertEqual(try installedCLIVersion(of: update.installedApp), "0.2.0")
        XCTAssertNotEqual(kill(pid_t(daemonBefore), 0), 0, "The installer stops the daemon of the app it replaces.")
        let after = try XCTUnwrap(try runCLI(["daemon", "info"], extraEnvironment: environment, cli: ownCLI)["result"] as? [String: Any])
        XCTAssertEqual(after["appVersion"] as? String, "0.2.0")
        XCTAssertEqual(after["replacedOnDisk"] as? Bool, false)
        XCTAssertTrue(terminateAppAndWait(app))
    }

    // case-contract: test_update_restart_now_keeps_claude_turn_running | Restarting to update while a Claude Code turn is running doesn't wait for it: with the update waiting for the agent, installing now starts the installer, a second install while it runs is refused as busy, and the installer stops the app's own bridge daemon and installs over it; with the window running, the app quits by itself when the installer asks rather than being stopped. The send that was waiting on the stopped daemon fails as unavailable, the Claude Code process keeps running, the next daemon is the new version and reattaches the same run; when that daemon is stopped in turn, it refuses new requests as exiting instead of dropping them and logs each one, the CLI and the window's update check send them again to the daemon that follows (the headless suite runs no window, so only the CLI's are sent), and that daemon takes the same run back; and when the turn finishes its answer is kept once and the task settles through its outcome.
    func test_update_restart_now_keeps_claude_turn_running() throws {
        try assertRestartNowKeepsTurnRunning(provider: "claude")
    }

    // case-contract: test_update_restart_now_keeps_codex_turn_running | Restarting to update while a Codex turn is running doesn't wait for it: with the update waiting for the agent, installing now starts the installer, a second install while it runs is refused as busy, and the installer stops the app's own bridge daemon and installs over it; with the window running, the app quits by itself when the installer asks rather than being stopped. The send that was waiting on the stopped daemon fails as unavailable, the shared Codex app-server keeps running, the next daemon is the new version and reconnects to the same server; when that daemon is stopped in turn, it refuses new requests as exiting instead of dropping them and logs each one, the CLI and the window's update check send them again to the daemon that follows (the headless suite runs no window, so only the CLI's are sent), and that daemon takes the same server back; and when the turn finishes its answer is kept once and the task settles through its outcome.
    func test_update_restart_now_keeps_codex_turn_running() throws {
        try assertRestartNowKeepsTurnRunning(provider: "codex")
    }

    /// While a daemon stops it refuses new requests as exiting rather than dropping them, the CLI
    /// and the window send them again to the daemon that follows, and that daemon takes the agent back once.
    func assertDaemonExitRefusesAndHandsOver(environment: [String: String], cli: URL, provider: String, agent: [String: Any]) throws {
        let socketPath = bridgeSocketPath(service: try XCTUnwrap(environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"]))
        let daemon = try XCTUnwrap((try runCLI(["daemon", "info"], extraEnvironment: environment, cli: cli)["result"] as? [String: Any])?["processID"] as? Int)
        let checkedBefore = try updateStatus(environment)["lastCheckedAt"] as? String
        let settings = openUpdateSettings()
        let checkNow = settings.descendants(matching: .any).matching(identifier: "update-check-now-button").firstMatch
        XCTAssertTrue(checkNow.waitToExist(timeout: 10))
        func daemonLog() -> String { (try? String(contentsOfFile: socketPath + ".log", encoding: .utf8)) ?? "" }
        func shutdownRequests() -> Int { daemonLog().components(separatedBy: "shutdown requested").count - 1 }
        func refusals(_ command: String) -> Int { daemonLog().components(separatedBy: "refused \(command): exiting").count - 1 }
        let windowRefusals = refusals("update.check")
        // An open connection keeps the stopping daemon draining for its full two seconds.
        let holder = connectBridgeSocket(socketPath)
        XCTAssertGreaterThanOrEqual(holder, 0, "The daemon should accept a connection.")
        Thread.sleep(forTimeInterval: 0.2)
        let requested = shutdownRequests()
        let stopper = try startCLIProcess(["daemon", "shutdown"], extraEnvironment: environment, cli: cli)
        XCTAssertTrue(waitUntil({ shutdownRequests() > requested }, timeout: 20), "The daemon should log the shutdown request.")
        // The window's own request reaches the stopping daemon too.
        checkNow.click()
        var refusal: [String: Any]?
        XCTAssertTrue(waitUntil({
            refusal = self.rawBridgeResponse(socketPath: socketPath, command: "daemon.info")
            return (refusal?["error"] as? [String: Any])?["code"] as? String == "daemon_exiting"
        }, timeout: 1.5), "A stopping daemon should refuse new requests as exiting: \(String(describing: refusal))")
        XCTAssertEqual(refusal?["ok"] as? Bool, false)
        XCTAssertGreaterThanOrEqual(refusals("daemon.info"), 1, "The daemon logs the requests it refuses.")
        let status = try runCLI(["status"], extraEnvironment: environment, cli: cli)
        if holder >= 0 { Darwin.close(holder) }
        let next = try XCTUnwrap((status["result"] as? [String: Any])?["processID"] as? Int)
        XCTAssertNotEqual(next, daemon, "The refused request is answered by the next daemon.")
        XCTAssertTrue(waitUntil({ kill(pid_t(daemon), 0) != 0 }, timeout: 25), "The stopped daemon exits.")
        XCTAssertEqual(try finishCLIProcess(stopper)["ok"] as? Bool, true)
        XCTAssertGreaterThan(refusals("update.check"), windowRefusals, "The window's check reached the stopping daemon and was refused.")
        XCTAssertTrue(waitUntil({
            guard let checked = self.runningUpdateStatus(environment)?["lastCheckedAt"] as? String else { return false }
            return checked != checkedBefore
        }, timeout: 30), "The window sends its refused check again, and the next daemon runs it.")
        XCTAssertTrue(waitUntil({ self.settingsText(settings, "update-settings-summary").hasPrefix("Up to date.") }, timeout: 10),
                      "The window shows the retried check's answer, not an error: \(settingsText(settings, "update-settings-summary"))")
        attachScreenshot(named: "\(provider): the window's check answered by the next daemon")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10))
        XCTAssertEqual(agentManifest(kind: provider, service: environment)?.manifest["process"] as? NSDictionary, agent as NSDictionary,
                       "The next daemon takes the same agent back.")
        XCTAssertTrue(agentIsAlive(agent))
    }

    /// A service's bridge socket, named as `BridgeContract.socketURL` names it.
    func bridgeSocketPath(service: String) -> String {
        let digest = SHA256.hash(data: Data(service.utf8)).map { String(format: "%02x", $0) }.joined()
        return "/tmp/playhouse-bridge/\(getuid())/\(digest.prefix(32)).sock"
    }

    /// An open connection to a bridge socket, or -1.
    func connectBridgeSocket(_ path: String) -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return -1 }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.prefix(raw.count - 1).enumerated() { raw[index] = byte }
        }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            Darwin.close(descriptor)
            return -1
        }
        return descriptor
    }

    /// Sends one request over a new bridge connection, without the CLI's retries, and returns its response.
    func rawBridgeResponse(socketPath: String, command: String) -> [String: Any]? {
        let descriptor = connectBridgeSocket(socketPath)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        guard let payload = try? JSONSerialization.data(withJSONObject: [
            "version": 1, "id": UUID().uuidString, "command": command, "arguments": [String: Any](),
        ]) else { return nil }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        guard frame.withUnsafeBytes({ Darwin.write(descriptor, $0.baseAddress, frame.count) }) == frame.count else { return nil }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            while buffer.count >= 4 {
                let size = Int(buffer.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
                guard buffer.count >= 4 + size else { break }
                let message = try? JSONSerialization.jsonObject(with: buffer.subdata(in: 4..<(4 + size))) as? [String: Any]
                buffer = Data(buffer.dropFirst(4 + size))
                if message?["kind"] as? String == "response" { return message?["value"] as? [String: Any] }
            }
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            guard count > 0 else { return nil }
            buffer.append(chunk, count: count)
        }
    }

    /// Clicks Restart to update in the installed app's window while a provider turn runs on its daemon.
    func assertRestartNowKeepsTurnRunning(provider: String) throws {
        let executable = WorkspaceFixture.root.appendingPathComponent("\(provider)-fixture-reattach").path
        if provider == "codex" { codexFixtureExecutable = executable } else { claudeFixtureExecutable = executable }
        clearReattachMarkers(executable)
        let update = try makeUpdateFixture()
        let ownCLI = update.installedApp.appendingPathComponent("Contents/MacOS/playhouse-cli")
        var environment = update.environment.filter { $0.key != "PLAYHOUSE_E2E_UPDATE_TARGET_APP" }
        environment.merge(restartServiceEnvironment(provider == "codex" ? ["PLAYHOUSE_E2E_CODEX_SERVER_IDLE_SECONDS": "3"] : [:])) { _, new in new }
        defer {
            _ = try? runCLI(["daemon", "shutdown"], extraEnvironment: environment, cli: ownCLI)
            stopSurvivingAgents()
        }
        let task = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Restart now with \(provider)", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", provider,
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(task["id"] as? String)
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: environment, appURL: update.installedApp)
        let pill = element("update-pill")
        XCTAssertTrue(pill.waitToExist(timeout: 30), "The installed 0.1.0 copy should offer 0.2.0.")
        XCTAssertEqual(pill.label, "Update to 0.2.0")

        let sender = try startCLIProcess(["conversation", "send", taskID, "--message", "Keep working through the update."], extraEnvironment: environment, cli: ownCLI)
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: executable + ".reattach-ready") }, timeout: 20), "The turn should be running.")
        XCTAssertTrue(waitUntil({
            !((((try? self.runCLI(["conversation", "runtime"], extraEnvironment: environment, cli: ownCLI))?["result"] as? [String: Any])?["activeThreadIDs"] as? [Any]) ?? []).isEmpty
        }, timeout: 15), "The turn is active.")
        let agent = try XCTUnwrap(agentManifest(kind: provider, service: environment)?.manifest["process"] as? [String: Any])
        let before = try XCTUnwrap(try runCLI(["daemon", "info"], extraEnvironment: environment, cli: ownCLI)["result"] as? [String: Any])
        XCTAssertEqual(before["appVersion"] as? String, "0.1.0")
        let daemonBefore = try XCTUnwrap(before["processID"] as? Int)

        pill.click()
        XCTAssertTrue(waitUntil({ pill.value as? String == "waiting" }, timeout: 60), "The downloaded update should wait for the running agent.")
        XCTAssertEqual(pill.label, "Restart to update")
        assertNativeHelpText(for: pill, equals: "running agents keep working")
        attachScreenshot(named: "\(provider): Restart to update while the agent works")
        pill.click()
        XCTAssertTrue(waitUntil({ self.runningUpdateStatus(environment)?["phase"] as? String == "installing" }, timeout: 20), "Restarting now starts the installer.")
        assertCLIError(try runCLI(["update", "install"], expectedStatus: 1, extraEnvironment: environment, cli: ownCLI), code: "update_busy")
        XCTAssertTrue(waitUntil({ self.bundleVersion(of: update.installedApp) == "0.2.0" }, timeout: 90), "The bundle should be replaced.")
        var record: [String: Any] = [:]
        XCTAssertTrue(waitUntil({
            record = self.runningUpdateStatus(environment)?["lastInstall"] as? [String: Any] ?? [:]
            return !record.isEmpty
        }, timeout: 90), "The installer should record its result once the reopened app starts the next daemon.")
        XCTAssertEqual(record["status"] as? String, "installed", "\(record)")
        let log = try String(contentsOf: dataDirectory.appendingPathComponent("Updates/Updater.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("stopping the bridge daemon (\(daemonBefore))"), log)
        XCTAssertTrue(log.contains("asking the running app to quit"), log)
        XCTAssertFalse(log.contains("didn't quit"), "The app should quit when the installer asks, not be stopped: \(log)")
        XCTAssertTrue(log.contains("opening \(update.installedApp.path) on bridge service \(try XCTUnwrap(environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"]))"), log)
        XCTAssertNotEqual(kill(pid_t(daemonBefore), 0), 0, "The installer stops the daemon running the turn.")
        assertCLIError(try finishCLIProcess(sender, expectedStatus: 69), code: "service_unavailable")
        XCTAssertTrue(agentIsAlive(agent), "The agent keeps working through the update.")

        app = XCUIApplication(url: update.installedApp)
        let notice = element("update-notice")
        XCTAssertTrue(notice.waitToExist(timeout: 60), "The reopened app should say it was updated.")
        XCTAssertEqual(notice.label, "Updated to 0.2.0")
        XCTAssertEqual(try installedCLIVersion(of: update.installedApp), "0.2.0")
        XCTAssertEqual((try runCLI(["daemon", "info"], extraEnvironment: environment, cli: ownCLI)["result"] as? [String: Any])?["appVersion"] as? String, "0.2.0")
        XCTAssertEqual(agentManifest(kind: provider, service: environment)?.manifest["process"] as? NSDictionary, agent as NSDictionary,
                       "The new daemon reattaches the same agent process.")
        XCTAssertEqual((try runCLI(["task", "get", taskID], extraEnvironment: environment, cli: ownCLI)["result"] as? [String: Any])?["status"] as? String, "In Progress")
        attachScreenshot(named: "\(provider): reopened as 0.2.0 with the agent still working")
        try assertDaemonExitRefusesAndHandsOver(environment: environment, cli: ownCLI, provider: provider, agent: agent)

        touch(executable + ".reattach-release")
        XCTAssertTrue(waitForStatus(taskID, "Waiting Response", environment: environment, timeout: 40), "The turn settles through its outcome.")
        XCTAssertFalse((try taskRecord(id: taskID)?["statusMessage"] as? String ?? "").contains("restarting"))
        let joined = try historyTexts(taskID: taskID, environment: environment).joined(separator: "\n")
        XCTAssertEqual(joined.components(separatedBy: "After restart.").count - 1, 1, joined)
        attachScreenshot(named: "\(provider): the agent's turn finished after the update")
        XCTAssertTrue(terminateAppAndWait(app))
    }
}
