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

    // case-contract: test_update_check_offers_signed_release_on_release_builds | A development build reports the development phase and refuses to check, download or install, and its Check for Updates menu item is disabled, so it never updates itself. A stable build checks the signed release feed: before a check it is up to date with no offer; a check offers the newer release with its version, release date and notes, shown as a compact Update button at the trailing end of the window's title bar whose tooltip names them, which a fresh read still reports, and finds it through the release's asset list (GitHub's latest-release API) when the feed link fails; the window's check at every launch reaches the feed even within a day, and with the feed gone fails quietly, keeping the offer and the Update button with no error, while the hourly automatic check does not reach the feed again within a day, and a manual check from the app menu then reports the failure; a newer release published within the day is missed by the hourly check but offered at the next launch, where the Update button names it. Update checks can't be turned off: Settings has no daily-check toggle. A newer release built for another architecture or needing a newer macOS is not offered. An app in a folder it can't write to says to move Playhouse to Applications, refuses to check, and doesn't offer even a release it already found, so no update button shows.
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

        // Relaunched within the day with the feed gone, the window's check at launch still asks the
        // feed; it fails quietly, so the offer and its button stay and no error is shown.
        XCTAssertTrue(terminateAppAndWait(app))
        let manifest = update.feed.appendingPathComponent("playhouse-release.json")
        let signedManifest = try Data(contentsOf: manifest)
        try FileManager.default.removeItem(at: manifest)
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: update.environment)
        XCTAssertTrue(element("update-pill").waitToExist(timeout: 20), "The stored offer should still show.")
        var relaunched: [String: Any] = [:]
        XCTAssertTrue(waitUntil({
            relaunched = (try? self.updateStatus(update.environment)) ?? [:]
            return relaunched["lastCheckedAt"] as? String != lastChecked
        }, timeout: 15), "The check at launch should reach the feed even within a day.")
        XCTAssertEqual(relaunched["phase"] as? String, "available")
        XCTAssertNil(relaunched["error"], "A failed check at launch must stay quiet.")
        XCTAssertEqual(element("update-pill").label, "Update to 0.2.0", "The offer keeps its button after a quiet failed check.")
        attachScreenshot(named: "Relaunch within a day with the feed gone: the Update button stays")
        attachElementScreenshot(element("update-pill"), named: "Update to 0.2.0 button kept after a quiet failed launch check")
        // The hourly automatic check after it doesn't reach the feed again within the day.
        let launchChecked = try XCTUnwrap(relaunched["lastCheckedAt"] as? String)
        let hourly = try XCTUnwrap(try runCLI(["update", "check", "--automatic", "true"], extraEnvironment: update.environment)["result"] as? [String: Any])
        XCTAssertEqual(hourly["lastCheckedAt"] as? String, launchChecked, "The hourly check must not run again within a day.")
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

        // Update checks can't be turned off.
        XCTAssertFalse(settings.descendants(matching: .any).matching(identifier: "update-auto-check-toggle").firstMatch.exists,
                       "Settings has no daily-check toggle.")
        XCTAssertNil((try updateStatus(update.environment))["autoCheck"])
        // Scroll the Updates section into view for its screenshot: Check Now, then the summary, no toggle.
        let updatesSummary = settings.descendants(matching: .any).matching(identifier: "update-settings-summary").firstMatch
        let settingsScroll = settings.scrollViews.firstMatch
        for _ in 0..<8 {
            guard updatesSummary.frame.maxY > settings.frame.maxY - 8 else { break }
            settingsScroll.scroll(byDeltaX: 0, deltaY: -300)
            _ = waitForStableFrame(updatesSummary, timeout: 2)
        }
        XCTAssertLessThanOrEqual(updatesSummary.frame.maxY, settings.frame.maxY, "The Updates section should be in view.")
        attachScreenshot(named: "Settings Updates section: Check Now and no daily-check toggle")
        XCTAssertTrue(terminateAppAndWait(app))

        // A newer release published within the day: the hourly check misses it, and the next
        // launch offers it on the Update button.
        let newer = try makeUpdateFixture(root: "update-fixture-newer", release: ["release": "0.3.0"])
        let missed = try XCTUnwrap(try runCLI(["update", "check", "--automatic", "true"], extraEnvironment: newer.environment)["result"] as? [String: Any])
        XCTAssertEqual((missed["available"] as? [String: Any])?["version"] as? String, "0.2.0",
                       "The hourly check must not reach the feed within the day.")
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: newer.environment)
        let newerPill = element("update-pill")
        XCTAssertTrue(waitUntil({ newerPill.exists && newerPill.label == "Update to 0.3.0" }, timeout: 30),
                      "The launch check should offer the release published within the day.")
        let offered = try updateStatus(newer.environment)
        XCTAssertEqual(offered["phase"] as? String, "available")
        XCTAssertEqual((offered["available"] as? [String: Any])?["version"] as? String, "0.3.0")
        XCTAssertNil(offered["error"])
        assertNativeHelpText(for: newerPill, equals: "Playhouse 0.3.0, released November 18, 2026")
        attachScreenshot(named: "Relaunch within a day: the Update button offers the newer 0.3.0")
        attachElementScreenshot(newerPill, named: "Update to 0.3.0 button close-up")
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

    // case-contract: test_update_notice_keeps_notes_from_older_installer | An update started by a version that didn't keep the release it was installing still shows its notes: when the new version reports its launch before the installer has recorded a result, it keeps the offered release, so after its launch check finds nothing newer and clears the offer and the installer then records the install, the Updated notice carries the release's notes and What's new shows them.
    func test_update_notice_keeps_notes_from_older_installer() throws {
        let update = try makeUpdateFixture()
        XCTAssertEqual((try runCLI(["update", "check"], extraEnvironment: update.environment)["result"] as? [String: Any])?["phase"] as? String, "available")
        XCTAssertEqual((try runCLI(["update", "download"], extraEnvironment: update.environment)["result"] as? [String: Any])?["phase"] as? String, "ready")
        XCTAssertEqual((try runCLI(["update", "install"], extraEnvironment: update.environment)["result"] as? [String: Any])?["started"] as? Bool, true)
        // The installer stops the daemon, which this sandboxed runner can't restart, so
        // its record is read from disk until the window starts the next one.
        let updates = dataDirectory.appendingPathComponent("Updates")
        let recordFile = updates.appendingPathComponent("last-install.json")
        var heldRecord = Data()
        XCTAssertTrue(waitUntil({
            heldRecord = (try? Data(contentsOf: recordFile)) ?? Data()
            return ((try? JSONSerialization.jsonObject(with: heldRecord)) as? [String: Any])?["status"] as? String == "installed"
        }, timeout: 90), "The installer should record the install.")
        // Recreate a relaunch after an install that an older version started: the installer
        // hasn't recorded a result yet, and the state doesn't name the release being installed.
        try FileManager.default.removeItem(at: recordFile)
        let stateFile = updates.appendingPathComponent("state.json")
        var state = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: stateFile)) as? [String: Any])
        XCTAssertEqual((state.removeValue(forKey: "installing") as? [String: Any])?["version"] as? String, "0.2.0",
                       "The installing version keeps the release it installs.")
        try JSONSerialization.data(withJSONObject: state).write(to: stateFile)

        // The window reports its launch, then its launch check clears the offer.
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: update.environment)
        XCTAssertTrue(element("board-title").waitToExist(timeout: 20))
        XCTAssertTrue(waitUntil({
            guard let status = self.runningUpdateStatus(update.environment), status["lastCheckedAt"] != nil else { return false }
            return status["available"] == nil
        }, timeout: 30), "The launch check finds nothing newer than 0.2.0 and clears the offer.")
        XCTAssertFalse(element("update-notice").exists, "Nothing is recorded before the installer finishes.")
        try heldRecord.write(to: recordFile)
        let notice = element("update-notice")
        XCTAssertTrue(notice.waitToExist(timeout: 30), "The window should say the update installed once it is recorded.")
        XCTAssertEqual(notice.label, "Updated to 0.2.0")
        notice.click()
        let notesBody = app.descendants(matching: .any).matching(identifier: "update-notes-body").firstMatch
        XCTAssertTrue(notesBody.waitToExist(timeout: 10), "Clicking the notice shows what's new.")
        XCTAssertEqual(pluginText(notesBody), "Faster boards and a new update button.", "The notice keeps the release's notes.")
        attachScreenshot(named: "What's new after an install an older version started")
        attachElementScreenshot(notesBody, named: "What's new notes close-up after an older version's install")
        XCTAssertTrue(terminateAppAndWait(app))
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

    // case-contract: test_update_installs_over_its_own_app_and_daemon | The installed app's own command-line tool accepts its bundle with verify-bundle and refuses a copy changed after signing. Updating the app a request comes from, with no test target, stops that app's own bridge daemon on its private service and installs over it, so the app, its command-line tool and the next daemon on that service report the new version; a daemon another service started from the old bundle reports that it was replaced on disk and is retired by the next request, which starts one from the new bundle (the visible suite's sandboxed runner can't start a daemon itself, so only the headless suite starts one on another service). With the app's window running, the installer asks it to quit, the app quits by itself rather than being stopped, and the installer reopens the new version in the same data folder and bridge service, where it says it was updated and its What's new shows the release's notes, although its launch check found nothing newer and cleared the offer before the installer recorded the result; the headless suite runs no window, so nothing is reopened, and it makes that launch check from the command line before reading the notice.
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
        // The reopened window's launch check ran before the installer recorded the result
        // and cleared the offer; the notice still opens the release's notes.
        XCTAssertNil((try XCTUnwrap(runningUpdateStatus(environment)))["available"], "The reopened version's launch check cleared the offer.")
        if !notice.isHittable {
            // The installer opens the new version without the test's launch arguments, so macOS
            // may place its window partly past the VM's screen; zoom it to fit before clicking.
            app.menuBars.menuBarItems["Window"].click()
            let zoom = app.menuItems["Zoom"]
            if zoom.waitToExist(timeout: 2) {
                zoom.click()
            } else {
                app.typeKey("z", modifierFlags: [.command, .option])
            }
            app.activate()
            XCTAssertTrue(waitUntil({ notice.isHittable }, timeout: 5), "The reopened window fits the screen after zooming.")
        }
        notice.click()
        let notesBody = app.descendants(matching: .any).matching(identifier: "update-notes-body").firstMatch
        XCTAssertTrue(notesBody.waitToExist(timeout: 10), "Clicking the notice shows what's new.")
        XCTAssertEqual(pluginText(app.descendants(matching: .any).matching(identifier: "update-notes-title").firstMatch), "What's new in Playhouse 0.2.0")
        XCTAssertEqual(pluginText(notesBody), "Faster boards and a new update button.", "The reopened app shows the release's notes.")
        attachScreenshot(named: "Reopened 0.2.0 shows what's new")
        attachElementScreenshot(notesBody, named: "What's new notes close-up")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(try installedCLIVersion(of: update.installedApp), "0.2.0")
        XCTAssertNotEqual(kill(pid_t(daemonBefore), 0), 0, "The installer stops the daemon of the app it replaces.")
        let after = try XCTUnwrap(try runCLI(["daemon", "info"], extraEnvironment: environment, cli: ownCLI)["result"] as? [String: Any])
        XCTAssertEqual(after["appVersion"] as? String, "0.2.0")
        XCTAssertEqual(after["replacedOnDisk"] as? Bool, false)
        XCTAssertTrue(terminateAppAndWait(app))
    }

    // case-contract: test_update_restart_now_keeps_claude_turn_running | Restarting to update while a Claude Code turn is running doesn't wait for it: with the update waiting for the agent, installing now starts the installer, a second install while it runs is refused as busy, and the installer stops the app's own bridge daemon and installs over it; with the window running, the app quits by itself when the installer asks rather than being stopped. The send that was waiting on the stopped daemon fails as unavailable, the Claude Code process keeps running, the next daemon is the new version and reattaches the same run; when that daemon is stopped in turn, it refuses new requests as exiting instead of dropping them and logs each one, gives up its socket before it exits so callers already queued on it are refused rather than dropped, and the daemon that follows starts only once it has exited, the CLI and the window's update check send them again to the daemon that follows (the headless suite runs no window, so only the CLI's are sent), and that daemon takes the same run back; and when the turn finishes its answer is kept once and the task settles through its outcome.
    func test_update_restart_now_keeps_claude_turn_running() throws {
        try assertRestartNowKeepsTurnRunning(provider: "claude")
    }

    // case-contract: test_update_restart_now_keeps_codex_turn_running | Restarting to update while a Codex turn is running doesn't wait for it: with the update waiting for the agent, installing now starts the installer, a second install while it runs is refused as busy, and the installer stops the app's own bridge daemon and installs over it; with the window running, the app quits by itself when the installer asks rather than being stopped. The send that was waiting on the stopped daemon fails as unavailable, the shared Codex app-server keeps running, the next daemon is the new version and reconnects to the same server; when that daemon is stopped in turn, it refuses new requests as exiting instead of dropping them and logs each one, gives up its socket before it exits so callers already queued on it are refused rather than dropped, and the daemon that follows starts only once it has exited, the CLI and the window's update check send them again to the daemon that follows (the headless suite runs no window, so only the CLI's are sent), and that daemon takes the same server back; and when the turn finishes its answer is kept once and the task settles through its outcome.
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
        func socketReleases() -> Int { daemonLog().components(separatedBy: "released the socket, exiting").count - 1 }
        let released = socketReleases()
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
        XCTAssertEqual(socketReleases(), released + 1, "The stopping daemon gives up its socket before it exits, so callers queued on it are refused rather than dropped.")
        let log = daemonLog()
        let lastListening = log.range(of: "listening at", options: .backwards)?.lowerBound
        let lastRelease = log.range(of: "released the socket, exiting", options: .backwards)?.lowerBound
        XCTAssertTrue(lastListening != nil && lastRelease != nil && lastListening! > lastRelease!, "The next daemon starts only after the stopping daemon has exited.")
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

// MARK: - Script plugins' background halves

extension PlayhouseUITests {
    static let serviceFocusPluginSource = #"""
function Panel() {
  var props = Playhouse.useProps();
  var state = props.state || {};
  return h(Stack, { spacing: 4 },
    h(Text, { testID: "service-focused" }, "focused " + (state.focused || 0)),
    h(Text, { testID: "service-heard" }, "heard " + (state.heard || []).join(",")),
    h(Text, { testID: "service-active" }, "service " + Playhouse.service.active));
}
Playhouse.service.on("app.focus", async function (event) {
  var state = Playhouse.props.state || {};
  await Playhouse.setState("focused", (state.focused || 0) + 1);
});
// No guard against its own writes: a service never hears those, so this can't loop.
Playhouse.service.on("plugin.stateChanged", async function (event) {
  var heard = (Playhouse.props.state || {}).heard || [];
  await Playhouse.setState("heard", heard.concat([event.payload.pluginID + ":" + event.key]));
});
Playhouse.render(h(Panel));
"""#
    static let serviceQuietPluginSource = #"""
Playhouse.service.on("app.focus", function () { return Playhouse.setState("focused", true); });
Playhouse.service.on("task.statusChanged", function (event) { return Playhouse.setState("moved", event.to); });
Playhouse.service.on("plugin.stateChanged", function (event) {
  if (event.key !== "heard") return Playhouse.setState("heard", event.payload.pluginID + ":" + event.key);
});
"""#
    // Writes the other plugin's state whenever its own "ball" changes, so two of them would
    // wake each other forever if a chain of events had no end.
    static let servicePingPongSource = #"""
Playhouse.service.on("plugin.stateChanged", async function (event) {
  if (event.key !== "ball") return;
  var self = Playhouse.props.plugin.id;
  var hits = ((Playhouse.props.state || {}).hits || 0) + 1;
  await Playhouse.setState("hits", hits);
  await Playhouse.bridge("plugin.state.set", { pluginID: self === "ping-service" ? "pong-service" : "ping-service", key: "ball", value: hits });
});
"""#
    static let serviceHeadlessHandlersSource = #"""
Playhouse.service.on("app.focus", async function () {
  var tasks = await Playhouse.bridge("task.list", {});
  await Playhouse.setState("tasks", tasks.tasks.length);
  try { await Playhouse.ui.close(); } catch (error) { await Playhouse.setState("ui", error.code); }
  try { await Playhouse.bridge("plugin.services", {}); } catch (error) { await Playhouse.setState("internal", error.code); }
  try {
    var answer = await Playhouse.mcp.call("mcp__claude_ai_Slack__slack_read_user_profile", { user: "U1" });
    await Playhouse.setState("mcp", answer.content[0].text);
  } catch (error) { await Playhouse.setState("mcp", error.code); }
  try {
    var run = await Playhouse.agent.run({ prompt: "Summarize", context: { kind: "probe" } });
    await Playhouse.setState("run", run.runID);
  } catch (error) { await Playhouse.setState("run", error.code); }
});
Playhouse.service.on("agent.finished", async function (e) {
  await Playhouse.setState("finished", { status: e.status, kind: e.context.kind, title: e.result.title, runID: e.runID, same: e.payload.runID === e.runID });
});
Playhouse.service.on("task.statusChanged", function () { throw new Error("The move handler broke."); });
Playhouse.render(h(Text, { testID: "never" }, "never rendered"));
"""#
    static let servicePopoverCallsSource = #"""
function Calls() {
  var result = React.useState("idle");
  function call() {
    Playhouse.mcp.call("mcp__claude_ai_Slack__slack_read_user_profile", {}).then(
      function (answer) { result[1]("mcp " + answer.content[0].text); },
      function (error) { result[1]("mcp " + error.code); });
  }
  function run() {
    Playhouse.agent.run({ prompt: "Go", context: { kind: "ui" } }).then(
      function (answer) { result[1]("run " + answer.runID); },
      function (error) { result[1]("run " + error.code); });
  }
  var off = Playhouse.service.on("app.focus", function () { result[1]("service handler ran in the UI"); });
  return h(Stack, {},
    h(Button, { testID: "call-mcp", onPress: call }, h(Text, {}, "MCP")),
    h(Button, { testID: "call-agent", onPress: run }, h(Text, {}, "Agent")),
    h(Text, { testID: "call-result" }, result[0] + (Playhouse.service.active ? " (service)" : "")));
}
Playhouse.render(h(Calls));
"""#
    static let serviceMcpPluginSource = #"""
Playhouse.service.on("app.focus", async function () {
  var answer = await Playhouse.mcp.call("mcp__claude_ai_Slack__slack_search_public_and_private", { query: "to:me", channel_types: "im" });
  await Playhouse.setState("people", answer.content.map(function (block) { return block.text; }));
  // Not in the manifest's mcpTools: refused before Claude Code is asked.
  try { await Playhouse.mcp.call("mcp__claude_ai_Slack__slack_read_user_profile", {}); } catch (error) { await Playhouse.setState("denied", error.code); }
});
function People() {
  var people = (Playhouse.useProps().state || {}).people || [];
  return h(Text, { testID: "mcp-people" }, people.length ? people.join(", ") : "nobody yet");
}
Playhouse.render(h(People));
"""#
    static let serviceCodexMcpPluginSource = #"""
Playhouse.service.on("app.focus", async function () {
  var answer = await Playhouse.mcp.call("mcp__claude_ai_Slack__slack_search_public_and_private", { query: "to:me" }, { provider: "codex" });
  await Playhouse.setState("people", answer.content.map(function (block) { return block.text; }));
});
function People() {
  var people = (Playhouse.useProps().state || {}).people || [];
  return h(Text, { testID: "mcp-people" }, people.length ? people.join(", ") : "nobody yet");
}
Playhouse.render(h(People));
"""#
    static let serviceSlowPluginSource = #"""
Playhouse.service.on("task.statusChanged", async function (event) {
  await Playhouse.setState("before", event.to);
  await Playhouse.mcp.call("mcp__claude_ai_Slack__slack_read_channel", { channel_id: "D1" });
  await Playhouse.setState("after", event.to);
});
"""#
    static let serviceListenerPluginSource = #"""
Playhouse.service.on("agent.finished", function (e) { return Playhouse.setState("finished", e.runID); });
"""#
    static let serviceAgentPluginSource = #"""
var TASK_SCHEMA = { type: "object", properties: { title: { type: "string" }, prompt: { type: "string" }, nothingNew: { type: "boolean" } }, required: ["title", "prompt", "nothingNew"] };
function onCreate(userId) {
  var jobs = (Playhouse.props.state || {}).jobs || {};
  // The plugin's "provider" setting picks the agent; each has its own model names.
  var provider = (Playhouse.props.state || {}).provider;
  Playhouse.agent.run({ prompt: "Read the DMs of " + userId + " and draft a task.", provider: provider, model: provider === "codex" ? "gpt-5.5" : provider === "opencode" ? "fixture/fast" : "opus",
    allowedTools: ["mcp__claude_ai_Slack__slack_read_channel", "mcp__claude_ai_Slack__slack_read_thread"],
    jsonSchema: TASK_SCHEMA, context: { kind: "slack-task", userId: userId } })
    .then(function (r) { var next = Object.assign({}, jobs); next[userId] = r.runID; return Playhouse.setState("jobs", next); });
}
function DMs() {
  var state = Playhouse.useProps().state || {};
  var finished = state.finished;
  return h(Stack, { spacing: 6 },
    h(Button, { style: "bordered", testID: "dm-create-U7", onPress: function () { onCreate("U7"); } }, h(Text, {}, "Create task for Dana")),
    h(Text, { testID: "dm-job" }, (state.jobs || {}).U7 ? "running" : "no job"),
    h(Text, { testID: "dm-finished" }, finished ? finished.status + " " + finished.userId + " " + (finished.error || finished.title || "") : "not finished"));
}
Playhouse.service.on("agent.finished", async function (e) {
  if (e.context.kind !== "slack-task") return;
  var title = null;
  if (e.status === "done" && !e.result.nothingNew) {
    var created = await Playhouse.bridge("task.create", { title: e.result.title, prompt: e.result.prompt, roots: [], repositories: [] });
    title = created.title;
  } else if (e.status !== "done") {
    // A run that didn't finish is put on the board, so the user sees it.
    await Playhouse.bridge("task.create", { title: "Slack task " + e.status + " for " + e.context.userId + (e.error ? ": " + e.error : ""),
      prompt: "Draft the Slack task for " + e.context.userId + " again.", roots: [], repositories: [] });
  }
  var jobs = Object.assign({}, (Playhouse.props.state || {}).jobs || {});
  if (jobs[e.context.userId] === e.runID) delete jobs[e.context.userId];
  await Playhouse.setState("jobs", jobs);
  await Playhouse.setState("finished", { status: e.status, userId: e.context.userId, runID: e.runID, error: e.error, title: title });
});
Playhouse.render(h(DMs));
"""#

    func pluginState(_ pluginID: String, environment: [String: String] = [:]) throws -> [String: Any] {
        try XCTUnwrap((try runCLI(["plugin", "state", "--id", pluginID], extraEnvironment: environment)["result"] as? [String: Any])?["state"] as? [String: Any])
    }

    /// Makes the app inactive and active again, as the user coming back to it does: the window raises app.focus.
    func refocusApp() {
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        XCTAssertTrue(waitUntil({ self.app.state != .runningForeground }, timeout: 5), "Another app comes to the front.")
        app.activate()
        XCTAssertTrue(waitUntil({ self.app.state == .runningForeground }, timeout: 5), "Playhouse comes back to the front.")
    }

    // case-contract: test_plugin_service_events_targeting_and_state | A plugin.json may list "events" (app events from PluginEvent's names, agent.finished included) for a background half next to any presentation, and a headless plugin is valid with only events; an unknown or repeated event, an mcpTools entry that isn't mcp__<server>__<tool>, or a headless plugin with neither commands nor events is reported in its errors. `plugin service --file` runs the script's Playhouse.service.on handlers headlessly in a fresh service runtime per event, where Playhouse.render does nothing: bridge calls are answered, ui calls are refused as unavailable, plugin.services is refused as invalid_argument, mcp.call and agent.run are unavailable unless --mock answers them (also by tool), agent.finished is injected with a fake result whose fields and context reach the handler beside payload, an unknown event is invalid_argument, and the report lists each event's handler count, the bridge calls, the state written and a throwing handler's error (exit 1). In a mounted UI (plugin render) Playhouse.service.on does nothing and mcp.call or agent.run is unavailable unless mocked. In the daemon, app.focus (from the window's activation or plugin event) wakes only the enabled plugins whose manifest lists it, collapsing quick repeats into one trailing run after the cooldown; a plugin's state change is targeted at it, so its own service hears a change made elsewhere while another plugin's service doesn't, and a service never hears its own writes, so a handler that saves on every change doesn't loop; two services that each write the other's state whenever their own changes stop after a bounded chain of events, each running four times for the eight events a chain may reach, instead of waking each other for as long as the daemon lives; the service writes state that the popover shows from its props, and a disabled plugin's service isn't woken by a focus that still reaches an enabled one.
    func test_plugin_service_events_targeting_and_state() throws {
        try writeInstalledPlugin("bad-events", source: Self.serviceQuietPluginSource, placement: "composerActions", presentation: "headless",
                                 extra: ["events": ["app.focus", "app.focus", "nope"], "mcpTools": ["slack_read"]])
        try writeInstalledPlugin("bare-headless", source: Self.serviceQuietPluginSource, placement: "composerActions", presentation: "headless")
        try writeInstalledPlugin("headless-service", source: Self.serviceQuietPluginSource, placement: "composerActions", presentation: "headless",
                                 extra: ["events": ["task.statusChanged", "agent.finished"], "mcpTools": ["mcp__claude_ai_Slack__slack_read_channel"]])
        try writeInstalledPlugin("focus-service", source: Self.serviceFocusPluginSource, placement: "mainSidebar", presentation: "popover",
                                 name: "Focus Service", icon: "bolt", extra: ["events": ["app.focus", "plugin.stateChanged"]])
        try writeInstalledPlugin("other-service", source: Self.serviceQuietPluginSource, placement: "mainSidebar", presentation: "popover",
                                 name: "Other Service", icon: "moon", extra: ["events": ["plugin.stateChanged", "task.statusChanged"]])
        try writeInstalledPlugin("focus-control", source: Self.serviceFocusPluginSource, placement: "mainSidebar", presentation: "popover",
                                 name: "Focus Control", icon: "bolt.circle", extra: ["events": ["app.focus"]])
        let cooldown = ["PLAYHOUSE_E2E_PLUGIN_SERVICE_COOLDOWN_SECONDS": "5"]
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: cooldown)
        let listed = try XCTUnwrap((try runCLI(["plugin", "refresh"])["result"] as? [String: Any])?["plugins"] as? [[String: Any]])
        func plugin(_ id: String) throws -> [String: Any] { try XCTUnwrap(listed.first { $0["id"] as? String == id }) }
        let badErrors = try plugin("bad-events")["errors"] as? [String] ?? []
        XCTAssertEqual(try plugin("bad-events")["valid"] as? Bool, false)
        XCTAssertTrue(badErrors.contains { $0.contains(#"Unknown event "nope""#) } && badErrors.contains { $0.contains("app.focus is listed twice") }
                      && badErrors.contains { $0.contains(#""slack_read" in "mcpTools""#) }, "\(badErrors)")
        XCTAssertTrue((try plugin("bare-headless")["errors"] as? [String] ?? []).contains { $0.contains(#"an event in "events""#) })
        XCTAssertEqual(try plugin("headless-service")["valid"] as? Bool, true, "A headless plugin with only events is valid.")
        XCTAssertEqual(try plugin("headless-service")["events"] as? [String], ["task.statusChanged", "agent.finished"])

        // Headless runs of a file, with faked provider calls.
        let file = dataDirectory.appendingPathComponent("service-handlers.js")
        try Self.serviceHeadlessHandlersSource.write(to: file, atomically: true, encoding: .utf8)
        let finished = #"agent.finished:{"runID":"run-1","status":"done","result":{"title":"Reply to Dana"},"error":null,"context":{"kind":"slack-task","userId":"U7"}}"#
        let report = try XCTUnwrap(try runCLI(["plugin", "service", "--file", file.path, "--event", "app.focus", "--event", finished])["result"] as? [String: Any])
        XCTAssertEqual((report["errors"] as? [Any])?.count, 0, "\(report)")
        let state = try XCTUnwrap(report["state"] as? [String: Any])
        XCTAssertEqual(state["ui"] as? String, "unavailable", "A background half has no window.")
        XCTAssertEqual(state["mcp"] as? String, "unavailable", "mcp.call is faked headlessly.")
        XCTAssertEqual(state["run"] as? String, "unavailable")
        XCTAssertEqual(state["internal"] as? String, "invalid_argument", "Only the daemon delivers events to background halves.")
        let heardFinish = try XCTUnwrap(state["finished"] as? [String: Any])
        XCTAssertEqual(heardFinish["kind"] as? String, "slack-task")
        XCTAssertEqual(heardFinish["same"] as? Bool, true, "The injected result's fields sit beside payload.")
        let mocked = try XCTUnwrap(try runCLI(["plugin", "service", "--file", file.path, "--event", "app.focus",
                                               "--mock", #"mcp.call:mcp__claude_ai_Slack__slack_read_user_profile={"content":[{"type":"text","text":"Nir"}]}"#,
                                               "--mock", #"agent.run={"runID":"run-mocked"}"#])["result"] as? [String: Any])
        XCTAssertEqual((mocked["state"] as? [String: Any])?["mcp"] as? String, "Nir")
        XCTAssertEqual((mocked["state"] as? [String: Any])?["run"] as? String, "run-mocked")
        let broken = try runCLI(["plugin", "service", "--file", file.path, "--event", #"task.statusChanged:{"taskID":"t","from":"Backlog","to":"Review"}"#], expectedStatus: 1)
        XCTAssertTrue(((broken["result"] as? [String: Any])?["errors"] as? [String] ?? []).contains { $0.contains("The move handler broke.") })
        XCTAssertEqual(((try runCLI(["plugin", "service", "--file", file.path, "--event", "app.nope"], expectedStatus: 2))["error"] as? [String: Any])?["code"] as? String, "invalid_argument")
        // A mounted UI's provider calls need a mock too, and its service.on does nothing.
        let popover = dataDirectory.appendingPathComponent("popover-calls.js")
        try Self.servicePopoverCallsSource.write(to: popover, atomically: true, encoding: .utf8)
        func callResult(_ options: [String]) throws -> String {
            let rendered = try XCTUnwrap(try runCLI(["plugin", "render", "--file", popover.path] + options)["result"] as? [String: Any])
            return try XCTUnwrap(pluginTreeText(rendered["tree"], testID: "call-result"))
        }
        XCTAssertEqual(try callResult(["--event", "call-mcp:onPress", "--event", "@app.focus"]), "mcp unavailable")
        XCTAssertEqual(try callResult(["--event", "call-agent:onPress", "--mock", #"agent.run={"runID":"run-ui"}"#]), "run run-ui")
        let services = try XCTUnwrap((try runCLI(["plugin", "services"])["result"] as? [String: Any])?["services"] as? [[String: Any]])
        XCTAssertEqual(Set(services.compactMap { $0["pluginID"] as? String }), ["focus-service", "other-service", "focus-control", "headless-service"],
                       "Only valid, enabled plugins with events have a background half.")

        func focusCount(_ id: String = "focus-service") -> Int { ((try? pluginState(id))?["focused"] as? Int) ?? 0 }
        // The launch's own focus may run first; once any trailing run is over, start from a known count.
        refocusApp()
        XCTAssertTrue(waitUntil({ focusCount() >= 1 }, timeout: 20), "The window's focus reaches the service.")
        // A trailing run restarts the cooldown, so wait until the count holds still past one.
        var base = focusCount()
        for _ in 0..<6 {
            RunLoop.current.run(until: Date().addingTimeInterval(5.5))
            let now = focusCount()
            if now == base { break }
            base = now
        }
        XCTAssertNil(try pluginState("other-service")["focused"], "A plugin whose manifest doesn't list app.focus isn't woken by it.")
        XCTAssertNil(try pluginState("headless-service")["focused"])
        // Two quick activations: one run at once, one trailing run after the cooldown, no more.
        // Each must reach the daemon as its own app.focus, or the collapse below can't be judged.
        func focusTimeline() -> [String] {
            ((try? diagnosticEvents()) ?? []).compactMap { event in
                let kind = event["event"] as? String
                guard event["name"] as? String == "app.focus",
                      kind == "plugin.event.published" || (kind == "plugin.service.handled" && event["pluginID"] as? String == "focus-service")
                else { return nil }
                return "\(kind ?? "") \(event["timestamp"] ?? "")"
            }
        }
        let publishedBefore = focusTimeline().filter { $0.hasPrefix("plugin.event.published") }.count
        refocusApp()
        refocusApp()
        XCTAssertTrue(waitUntil({ focusTimeline().filter { $0.hasPrefix("plugin.event.published") }.count >= publishedBefore + 2 }, timeout: 10),
                      "Each quick activation publishes app.focus: \(focusTimeline())")
        XCTAssertTrue(waitUntil({ self.focusCountIs(base + 2, of: "focus-service") }, timeout: 20),
                      "Quick repeats collapse into one trailing run: \(focusCount()) from \(base), \(focusTimeline())")
        RunLoop.current.run(until: Date().addingTimeInterval(6))
        XCTAssertEqual(focusCount(), base + 2, "Two activations in one cooldown run the service twice, not more.")
        let entry = element("plugin-entry-focus-service")
        XCTAssertTrue(entry.waitToExist(timeout: 10), "The popover plugin has its sidebar button.")
        entry.click()
        let focused = element("service-focused")
        XCTAssertTrue(waitUntil({ focused.exists && self.pluginText(focused) == "focused \(focusCount())" }, timeout: 10), "The popover shows the service's state: \(pluginText(focused))")
        XCTAssertEqual(pluginText(element("service-active")), "service false", "Playhouse.service.on does nothing in the mounted UI.")
        attachScreenshot(named: "The popover shows the focus count its background half saved")
        // A state change is targeted at its plugin: its own service hears it and the open popover re-renders.
        _ = try runCLI(["plugin", "state", "--id", "focus-service", "--key", "note", "--value", #""hello""#])
        let heard = element("service-heard")
        XCTAssertTrue(waitUntil({ self.pluginText(heard) == "heard focus-service:note" }, timeout: 15), "The service heard its own state change: \(pluginText(heard))")
        attachElementScreenshot(element("plugin-surface-focus-service"), named: "The service's reaction to its state change reaches the open popover")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(try pluginState("focus-service")["heard"] as? [String], ["focus-service:note"], "A service never hears its own writes, so it doesn't loop.")
        XCTAssertNil(try pluginState("other-service")["heard"], "Another plugin's state change doesn't wake this service.")
        // Two services that keep waking each other stop once their chain of events is long enough.
        for pinger in ["ping-service", "pong-service"] {
            try writeInstalledPlugin(pinger, source: Self.servicePingPongSource, placement: "composerActions", presentation: "headless",
                                     extra: ["events": ["plugin.stateChanged"]])
        }
        _ = try runCLI(["plugin", "state", "--id", "ping-service", "--key", "ball", "--value", "0"])
        func hits(_ id: String) -> Int? { (try? pluginState(id))?["hits"] as? Int }
        XCTAssertTrue(waitUntil({ hits("ping-service") == 4 && hits("pong-service") == 4 }, timeout: 30),
                      "Each service runs four times in the chain: \(String(describing: hits("ping-service"))), \(String(describing: hits("pong-service")))")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual([hits("ping-service"), hits("pong-service")], [4, 4], "The chain ends rather than looping for as long as the daemon lives.")
        // A move reaches the plugins that list it.
        _ = try runCLI(["plugin", "event", "task.statusChanged", "--payload", #"{"taskID":"t-1","from":"Backlog","to":"Review"}"#])
        XCTAssertTrue(waitUntil({ (try? self.pluginState("other-service"))?["moved"] as? String == "Review" }, timeout: 15))
        XCTAssertTrue(waitUntil({ (try? self.pluginState("headless-service"))?["moved"] as? String == "Review" }, timeout: 15))
        XCTAssertNil(try pluginState("other-service")["focused"], "Still never woken by focus.")
        app.typeKey(.escape, modifierFlags: [])
        // Disabled, its service isn't woken, while the same focus reaches an enabled plugin.
        _ = try runCLI(["plugin", "disable", "--id", "focus-service"])
        XCTAssertTrue(waitForDisappearance(entry, timeout: 10), "Disabling the plugin removes its button.")
        let before = focusCount()
        let control = focusCount("focus-control")
        RunLoop.current.run(until: Date().addingTimeInterval(5.5))
        refocusApp()
        XCTAssertTrue(waitUntil({ focusCount("focus-control") > control }, timeout: 15), "The focus reaches an enabled plugin.")
        RunLoop.current.run(until: Date().addingTimeInterval(6))
        XCTAssertEqual(focusCount(), before, "A disabled plugin's service isn't woken.")
    }

    func focusCountIs(_ count: Int, of pluginID: String) -> Bool {
        ((try? pluginState(pluginID))?["focused"] as? Int) == count
    }

    /// The text of the atom with `testID` in a `plugin render` tree.
    func pluginTreeText(_ tree: Any?, testID: String) -> String? {
        guard let node = tree as? [String: Any] else { return nil }
        let children = node["children"] as? [[String: Any]] ?? []
        if (node["props"] as? [String: Any])?["testID"] as? String == testID {
            return children.filter { $0["type"] as? String == "#text" }.compactMap { $0["text"] as? String }.joined()
        }
        return children.lazy.compactMap { self.pluginTreeText($0, testID: testID) }.first
    }

    // case-contract: test_plugin_mcp_call_warm_session_and_allowlist | mcp.call (CLI mcp call, Playhouse.mcp.call) calls a fully qualified MCP tool through Claude Code's mcp_call control request with result_not_for_model and no model turn, answering the tool's {content, structuredContent, isError}; a burst of calls reuses one warm Claude Code session, which shuts down once idle, so the next call starts another. A tool Claude Code can't reach fails as tool_failed with its message, a tool slower than the call's timeout as timeout, a name that isn't mcp__<server>__<tool> is invalid_argument, a Claude Code that doesn't advertise mcp_call_result_not_for_model_v1 or no Claude Code at all is unavailable, and a plugin whose manifest lists mcpTools is refused any other tool as permission_denied, both from the CLI and from its own Playhouse.mcp.call, which sends its plugin id. An installed plugin's background half calls mcp.call on app.focus in the daemon and saves the result in its state, which its popover shows. A task move doesn't wait for a script handler stuck on a slow tool, which still finishes; a handler past the service timeout is given up on with its runtime and reported in diagnostics.
    func test_plugin_mcp_call_warm_session_and_allowlist() throws {
        let environment = try installClaudeFixture(named: "claude-fixture-ui-mcp")
        let executable = try XCTUnwrap(environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"])
        let profile = "mcp__claude_ai_Slack__slack_read_user_profile", search = "mcp__claude_ai_Slack__slack_search_public_and_private"
        try JSONSerialization.data(withJSONObject: [
            profile: ["content": [["type": "text", "text": "Nir Yosef"]]],
            search: ["content": [["type": "text", "text": "Dana"], ["type": "text", "text": "Omri"]], "structuredContent": ["count": 2], "isError": false],
        ]).write(to: URL(fileURLWithPath: executable + ".mcp-results"))
        // The window starts Claude Code sessions of its own (models, MCP status), so the
        // direct calls' sessions are told apart by the process each call reached.
        func sessions() -> Int { Set(jsonLines(executable + ".mcp-calls").compactMap { ($0 as? [String: Any])?["pid"] as? Int }).count }
        try writeInstalledPlugin("slack-reader", source: Self.serviceMcpPluginSource, placement: "mainSidebar", presentation: "popover",
                                 name: "Slack Reader", icon: "bubble.left", extra: ["events": ["app.focus"], "mcpTools": [search]])
        try writeInstalledPlugin("slow-service", source: Self.serviceSlowPluginSource, placement: "composerActions", presentation: "headless",
                                 extra: ["events": ["task.statusChanged"]])
        launchApp(defaultParent: fixture.parent.path)
        _ = try runCLI(["plugin", "refresh"])

        // The window's focus wakes the background half, which calls the tool with no model turn.
        refocusApp()
        XCTAssertTrue(waitUntil({ ((try? self.pluginState("slack-reader"))?["people"] as? [String]) == ["Dana", "Omri"] }, timeout: 30), "The service saves the tool's result.")
        let entry = element("plugin-entry-slack-reader")
        XCTAssertTrue(entry.waitToExist(timeout: 10))
        entry.click()
        let people = element("mcp-people")
        XCTAssertTrue(waitUntil({ people.exists && self.pluginText(people) == "Dana, Omri" }, timeout: 10), "The popover shows what the service read: \(pluginText(people))")
        attachScreenshot(named: "The popover shows the people its background half read with mcp.call")
        attachElementScreenshot(element("plugin-surface-slack-reader"), named: "Slack DMs read by mcp.call, with no model turn")
        app.typeKey(.escape, modifierFlags: [])
        let calls = jsonLines(executable + ".mcp-calls").compactMap { $0 as? [String: Any] }
        XCTAssertEqual(calls.last?["tool"] as? String, search)
        XCTAssertEqual(calls.last?["resultNotForModel"] as? Bool, true)
        XCTAssertTrue(waitUntil({ (try? self.pluginState("slack-reader"))?["denied"] as? String == "permission_denied" }, timeout: 15),
                      "Playhouse.mcp.call sends the plugin's id, so its mcpTools refuse an unlisted tool.")

        // More calls reuse the warm session.
        let answer = try XCTUnwrap(try runCLI(["mcp", "call", "--tool", profile, "--arguments", #"{"user":"U1"}"#])["result"] as? [String: Any])
        XCTAssertEqual(((answer["content"] as? [[String: Any]])?.first)?["text"] as? String, "Nir Yosef")
        XCTAssertEqual(sessions(), 1, "A burst of calls starts Claude Code once.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: executable + ".history"), "No model turn ran.")
        let failed = try runCLI(["mcp", "call", "--tool", "mcp__linear__list_issues"], expectedStatus: 1)
        XCTAssertEqual((failed["error"] as? [String: Any])?["code"] as? String, "tool_failed")
        XCTAssertTrue(((failed["error"] as? [String: Any])?["message"] as? String ?? "").contains("MCP server not connected: linear"))
        _ = try runCLI(["mcp", "call", "--tool", "slack_read"], expectedStatus: 2)
        let denied = try runCLI(["mcp", "call", "--tool", profile, "--plugin", "slack-reader"], expectedStatus: 1)
        XCTAssertEqual((denied["error"] as? [String: Any])?["code"] as? String, "permission_denied", "A plugin's mcpTools catch a tool it didn't list.")

        // Idle, the session shuts down; the next call starts Claude Code again.
        _ = try runCLI(["mcp", "call", "--tool", profile], extraEnvironment: ["PLAYHOUSE_E2E_MCP_SESSION_IDLE_SECONDS": "1"])
        let pid = try XCTUnwrap((jsonLines(executable + ".mcp-calls").last as? [String: Any])?["pid"] as? Int)
        XCTAssertTrue(waitUntil({ kill(pid_t(pid), 0) != 0 }, timeout: 15), "The idle session's Claude Code exits.")
        _ = try runCLI(["mcp", "call", "--tool", profile])
        XCTAssertEqual(sessions(), 2, "After the idle shutdown, a call starts a new session.")

        // A slow tool: mcp.call's timeout, a move that doesn't wait for script handlers, and the handlers' own timeout.
        let channel = "mcp__claude_ai_Slack__slack_read_channel"
        try JSONSerialization.data(withJSONObject: [
            profile: ["content": [["type": "text", "text": "Nir Yosef"]]], channel: ["content": [["type": "text", "text": "hi"]]],
        ]).write(to: URL(fileURLWithPath: executable + ".mcp-results"))
        try JSONSerialization.data(withJSONObject: [channel: 4]).write(to: URL(fileURLWithPath: executable + ".mcp-call-delay"))
        let timedOut = try runCLI(["mcp", "call", "--tool", channel, "--timeout", "1"], expectedStatus: 1)
        XCTAssertEqual((timedOut["error"] as? [String: Any])?["code"] as? String, "timeout")
        let moved = try XCTUnwrap((try runCLI(["task", "create", "--title", "Slow plugin move", "--prompt", "Fixture task description.", "--root", fixture.primary.path])["result"] as? [String: Any])?["id"] as? String)
        let started = Date()
        _ = try runCLI(["plugin", "event", "task.statusChanged", "--payload", #"{"taskID":"\#(moved)","from":"In Progress","to":"Review"}"#])
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "A move waits for the built-ins' reactions, not for script handlers.")
        XCTAssertTrue(waitUntil({ (try? self.pluginState("slow-service"))?["after"] as? String == "Review" }, timeout: 30), "The slow handler still finishes.")
        _ = try runCLI(["plugin", "event", "task.statusChanged", "--payload", #"{"taskID":"\#(moved)","from":"Review","to":"Done"}"#],
                       extraEnvironment: ["PLAYHOUSE_E2E_PLUGIN_SERVICE_TIMEOUT_SECONDS": "1"])
        XCTAssertTrue(waitUntil({ (try? self.pluginState("slow-service"))?["before"] as? String == "Done" }, timeout: 15), "The handler starts.")
        XCTAssertTrue(waitUntil({
            ((try? self.diagnosticEvents()) ?? []).contains { $0["event"] as? String == "plugin.service.failed" && ($0["errors"] as? String ?? "").contains("didn't finish within 1 seconds") }
        }, timeout: 15), "The timed-out handlers are reported in diagnostics.")
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        XCTAssertEqual(try pluginState("slow-service")["after"] as? String, "Review", "A handler past its timeout is given up on, with its runtime.")

        // A Claude Code that can't call tools directly.
        let unsupported = try installClaudeFixture(named: "claude-fixture-ui-no-mcp-call")
        let refused = try runCLI(["mcp", "call", "--tool", profile], expectedStatus: 1, extraEnvironment: unsupported)
        XCTAssertEqual((refused["error"] as? [String: Any])?["code"] as? String, "unavailable")
        XCTAssertTrue(((refused["error"] as? [String: Any])?["message"] as? String ?? "").contains("can't call MCP tools directly"))
        let none = try runCLI(["mcp", "call", "--tool", profile], expectedStatus: 1, extraEnvironment: ["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": "none"])
        XCTAssertEqual((none["error"] as? [String: Any])?["code"] as? String, "unavailable")
    }

    // case-contract: test_plugin_agent_run_finishes_and_recovers | agent.run (CLI agent run, Playhouse.agent.run from the popover, which fills pluginID from props and passes its model, allowed tools, JSON schema and context) starts a non-persisted Claude Code run in the daemon with the given prompt, model, allowed tools and JSON schema and returns its runID at once; agent runs lists it as running, and nothing is heard while it runs. When it ends, only that plugin's background half hears agent.finished with {runID, status, result, error, context}, never another plugin that listens for agent.finished: done with the schema's structured output as result, which the plugin's handler uses to create a board task, failed with Claude Code's error or after the run timeout, or cancelled after agent cancel (an unknown run is not_found); the run then leaves agent runs. A run cut off by its daemon dying, which it outlives, is reported failed with the error "interrupted" by the next daemon, with its context intact, and its orphaned Claude Code process is stopped; deleting a plugin stops its runs with no event. agent.run is refused for a plugin that doesn't list agent.finished or a missing prompt (invalid_argument), an unknown plugin (not_found) and a disabled plugin (unavailable).
    func test_plugin_agent_run_finishes_and_recovers() throws {
        let environment = try installClaudeFixture(named: "claude-fixture-ui-agent")
        let executable = try XCTUnwrap(environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"])
        try JSONSerialization.data(withJSONObject: ["title": "Reply to Dana", "prompt": "Answer Dana's question.", "nothingNew": false])
            .write(to: URL(fileURLWithPath: executable + ".agent-output"))
        let hold = URL(fileURLWithPath: executable + ".agent-hold")
        addTeardownBlock { try? FileManager.default.removeItem(at: hold) }
        try writeInstalledPlugin("slack-dms", source: Self.serviceAgentPluginSource, placement: "mainSidebar", presentation: "popover",
                                 name: "Slack DMs", icon: "bubble.left.and.bubble.right", extra: ["events": ["agent.finished"]])
        try writeInstalledPlugin("deaf-plugin", source: Self.serviceAgentPluginSource, placement: "mainSidebar", presentation: "popover",
                                 name: "Deaf Plugin", icon: "ear", extra: ["events": ["app.focus"]])
        try writeInstalledPlugin("listener-plugin", source: Self.serviceListenerPluginSource, placement: "composerActions", presentation: "headless",
                                 extra: ["events": ["agent.finished"]])
        // Its own daemon, so killing it leaves the UI runner's shared one alone.
        let daemon = ["PLAYHOUSE_BRIDGE_SERVICE_NAME": "\(serviceName!).agents-\(UUID().uuidString.prefix(8))"]
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: daemon)
        _ = try runCLI(["plugin", "refresh"], extraEnvironment: daemon)
        func finished() -> [String: Any]? { (try? pluginState("slack-dms", environment: daemon))?["finished"] as? [String: Any] }
        func agentRuns() throws -> [[String: Any]] {
            try XCTUnwrap((try runCLI(["agent", "runs"], extraEnvironment: daemon)["result"] as? [String: Any])?["runs"] as? [[String: Any]])
        }
        func runs() -> [[String: Any]] { jsonLines(executable + ".agent-runs").compactMap { $0 as? [String: Any] } }
        let schema = #"{"type":"object","properties":{"title":{"type":"string"}},"required":["title"]}"#
        func run(_ plugin: String = "slack-dms", user: String, expectedStatus: Int32 = 0, extra: [String: String] = [:]) throws -> [String: Any] {
            try runCLI(["agent", "run", "--plugin", plugin, "--prompt", "Draft a task for \(user).", "--model", "opus",
                        "--allowed-tool", "mcp__claude_ai_Slack__slack_read_channel", "--json-schema", schema,
                        "--context", #"{"kind":"slack-task","userId":"\#(user)"}"#], expectedStatus: expectedStatus, extraEnvironment: daemon.merging(extra) { _, new in new })
        }
        func code(_ response: [String: Any]) -> String? { (response["error"] as? [String: Any])?["code"] as? String }
        XCTAssertEqual(code(try run("deaf-plugin", user: "U1", expectedStatus: 2)), "invalid_argument", "A plugin must list agent.finished to run an agent.")
        XCTAssertEqual(code(try run("no-such-plugin", user: "U1", expectedStatus: 3)), "not_found")
        XCTAssertEqual(code(try runCLI(["agent", "run", "--plugin", "slack-dms", "--prompt", "  "], expectedStatus: 2, extraEnvironment: daemon)), "invalid_argument", "A prompt is required.")
        // The popover's Playhouse.agent.run fills its plugin id and passes every option.
        let pressed = try XCTUnwrap(try runCLI(["plugin", "render", "--plugin", "slack-dms", "--event", "dm-create-U7:onPress", "--mock", #"agent.run={"runID":"run-popover"}"#],
                                               extraEnvironment: daemon)["result"] as? [String: Any])
        let popoverCall = try XCTUnwrap((pressed["hostCalls"] as? [[String: Any]])?.first { $0["name"] as? String == "agent.run" }?["arguments"] as? [String: Any])
        XCTAssertEqual(popoverCall["pluginID"] as? String, "slack-dms")
        XCTAssertEqual(popoverCall["model"] as? String, "opus")
        XCTAssertEqual(popoverCall["allowedTools"] as? [String], ["mcp__claude_ai_Slack__slack_read_channel", "mcp__claude_ai_Slack__slack_read_thread"])
        XCTAssertEqual((popoverCall["context"] as? [String: Any])?["userId"] as? String, "U7")
        XCTAssertEqual((popoverCall["jsonSchema"] as? [String: Any])?["required"] as? [String], ["title", "prompt", "nothingNew"])
        _ = try runCLI(["plugin", "state", "--id", "slack-dms", "--key", "jobs", "--value", "null"], extraEnvironment: daemon)
        _ = try runCLI(["plugin", "disable", "--id", "deaf-plugin"], extraEnvironment: daemon)
        XCTAssertEqual(((try run("deaf-plugin", user: "U1", expectedStatus: 1))["error"] as? [String: Any])?["code"] as? String, "unavailable", "A disabled plugin can't run an agent.")
        func boardCard(_ title: String) -> XCUIElement? {
            guard let id = (try? taskRecord(named: title))??["id"] as? String else { return nil }
            return element("task-card-\(id)")
        }

        // The popover's button starts the run; its background half creates the task when it ends.
        try Data().write(to: hold)
        let entry = element("plugin-entry-slack-dms")
        XCTAssertTrue(entry.waitToExist(timeout: 10), "The popover plugin has its sidebar button.")
        entry.click()
        let create = element("dm-create-U7")
        XCTAssertTrue(create.waitToExist(timeout: 10))
        create.click()
        let job = element("dm-job")
        XCTAssertTrue(waitUntil({ self.pluginText(job) == "running" }, timeout: 15), "agent.run answers at once with its runID: \(pluginText(job))")
        let listed = try agentRuns()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?["running"] as? Bool, true)
        XCTAssertEqual((listed.first?["context"] as? [String: Any])?["userId"] as? String, "U7")
        let runID = try XCTUnwrap(listed.first?["runID"] as? String)
        XCTAssertTrue(waitUntil({ !runs().isEmpty }, timeout: 15), "The agent started.")
        XCTAssertNil(finished(), "Nothing is heard while the agent runs.")
        XCTAssertEqual(runs().last?["model"] as? String, "opus")
        XCTAssertEqual(runs().last?["allowedTools"] as? String, "mcp__claude_ai_Slack__slack_read_channel,mcp__claude_ai_Slack__slack_read_thread")
        XCTAssertEqual(runs().last?["persisted"] as? Bool, false)
        attachElementScreenshot(element("plugin-surface-slack-dms"), named: "The popover started an agent run, which is still running")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForDisappearance(element("plugin-surface-slack-dms"), timeout: 10), "Closing the popover doesn't stop the run.")
        try FileManager.default.removeItem(at: hold)
        XCTAssertTrue(waitUntil({ finished()?["status"] as? String == "done" }, timeout: 30), "The plugin's service hears agent.finished.")
        XCTAssertEqual(finished()?["runID"] as? String, runID)
        XCTAssertEqual(finished()?["title"] as? String, "Reply to Dana")
        let card = try XCTUnwrap(try taskRecord(named: "Reply to Dana"), "The service created the task from the structured result.")
        XCTAssertTrue(element("task-card-\(try XCTUnwrap(card["id"] as? String))").waitToExist(timeout: 15), "The new task is on the board.")
        entry.click()
        let result = element("dm-finished")
        XCTAssertTrue(waitUntil({ self.pluginText(result) == "done U7 Reply to Dana" }, timeout: 10), "The reopened popover shows the result: \(pluginText(result))")
        XCTAssertEqual(pluginText(job), "no job")
        attachScreenshot(named: "The agent's result created a task, and the popover shows it")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(try agentRuns().count, 0)

        // Failed, cancelled, and cut off with the daemon.
        try Data().write(to: URL(fileURLWithPath: executable + ".agent-fail"))
        let failedID = try XCTUnwrap((try run(user: "U8")["result"] as? [String: Any])?["runID"] as? String)
        XCTAssertTrue(waitUntil({ finished()?["runID"] as? String == failedID }, timeout: 30))
        XCTAssertEqual(finished()?["status"] as? String, "failed")
        XCTAssertEqual(finished()?["error"] as? String, "The fixture agent failed on purpose.")
        XCTAssertNotNil(try taskRecord(named: "Slack task failed for U8: The fixture agent failed on purpose."), "The service files the failed run on the board.")
        try FileManager.default.removeItem(at: URL(fileURLWithPath: executable + ".agent-fail"))
        try Data().write(to: hold)
        let cancelledID = try XCTUnwrap((try run(user: "U9")["result"] as? [String: Any])?["runID"] as? String)
        XCTAssertEqual(code(try runCLI(["agent", "cancel", "--plugin", "slack-dms", "--run", "agent-run-nope"], expectedStatus: 3, extraEnvironment: daemon)), "not_found")
        _ = try runCLI(["agent", "cancel", "--plugin", "slack-dms", "--run", cancelledID], extraEnvironment: daemon)
        XCTAssertTrue(waitUntil({ finished()?["runID"] as? String == cancelledID }, timeout: 30))
        XCTAssertEqual(finished()?["status"] as? String, "cancelled")
        // Past its timeout, a run is stopped and fails.
        let timedID = try XCTUnwrap((try run(user: "U12", extra: ["PLAYHOUSE_E2E_PLUGIN_AGENT_TIMEOUT_SECONDS": "1"])["result"] as? [String: Any])?["runID"] as? String)
        XCTAssertTrue(waitUntil({ finished()?["runID"] as? String == timedID }, timeout: 30), "The timed-out run is reported.")
        XCTAssertEqual(finished()?["status"] as? String, "failed")
        XCTAssertEqual(finished()?["error"] as? String, "The agent didn't finish within 1 seconds.")
        XCTAssertNil(try pluginState("listener-plugin", environment: daemon)["finished"], "Another plugin listening for agent.finished never hears slack-dms's runs.")
        let interruptedID = try XCTUnwrap((try run(user: "U10")["result"] as? [String: Any])?["runID"] as? String)
        func pid(of user: String) -> Int? { runs().first { ($0["prompt"] as? String ?? "").contains(user) }?["pid"] as? Int }
        XCTAssertTrue(waitUntil({ pid(of: "U10") != nil }, timeout: 15), "The U10 agent started.")
        let orphan = try XCTUnwrap(pid(of: "U10"))
        let firstPID = try XCTUnwrap(try daemonProcessID(environment: daemon))
        kill(pid_t(firstPID), SIGKILL)
        XCTAssertEqual(kill(pid_t(orphan), 0), 0, "The agent outlives its daemon.")
        XCTAssertTrue(waitUntil({ ((try? self.daemonProcessID(environment: daemon)) ?? firstPID) != firstPID }, timeout: 20), "A fresh daemon takes over.")
        // The service files it on the board (a test store's settings can't be read back across daemons).
        // The new daemon checks the store on its first event or listing.
        _ = try agentRuns()
        let interruptedTitle = "Slack task failed for U10: interrupted"
        XCTAssertTrue(waitUntil({ boardCard(interruptedTitle)?.exists == true }, timeout: 30), "The next daemon reports the cut-off run, with its context, and the board shows it.")
        XCTAssertFalse(try agentRuns().contains { $0["runID"] as? String == interruptedID }, "The cut-off run left the list.")
        XCTAssertTrue(waitUntil({ kill(pid_t(orphan), 0) != 0 }, timeout: 10), "The orphaned agent is stopped.")
        attachElementScreenshot(try XCTUnwrap(boardCard(interruptedTitle)), named: "A run cut off with its daemon is reported as interrupted")

        // Deleting the plugin stops its runs, with no event.
        _ = try run(user: "U11")
        XCTAssertTrue(waitUntil({ pid(of: "U11") != nil }, timeout: 15), "The U11 agent started.")
        let last = try XCTUnwrap(pid(of: "U11"))
        _ = try runCLI(["plugin", "delete", "--id", "slack-dms"], extraEnvironment: daemon)
        XCTAssertEqual(try agentRuns().count, 0)
        XCTAssertTrue(waitUntil({ kill(pid_t(last), 0) != 0 }, timeout: 10), "The deleted plugin's agent is stopped.")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertNil(try taskRecord(named: "Slack task cancelled for U11: The run was cancelled."), "A deleted plugin hears nothing of its stopped run.")
    }
}

// MARK: - Script plugins' background work on Codex

extension PlayhouseUITests {
    /// A copy of the Codex app-server fixture under this case's data folder, owned by this case.
    func installCodexFixture(named name: String) throws -> [String: String] {
        let executable = dataDirectory.appendingPathComponent(name)
        try copyFixtureFile(at: WorkspaceFixture.root.appendingPathComponent("codex-fixture-ui"), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data("Playhouse test owns this Codex protocol fixture (v1).\n".utf8).write(to: dataDirectory.appendingPathComponent(".playhouse-codex-fixture-owner"))
        codexFixtureExecutable = executable.path
        return ["PLAYHOUSE_E2E_CODEX_EXECUTABLE": executable.path]
    }

    // case-contract: test_plugin_mcp_call_codex | mcp.call with provider codex (CLI mcp call --provider codex, Playhouse.mcp.call with {provider: "codex"}) calls the tool through the shared Codex app-server's mcpServer/tool/call on one ephemeral, read-only thread that a burst of calls reuses and that is released (thread/unsubscribe) once idle, with no turn, answering the tool's {content, structuredContent, isError}. A tool Codex can't reach fails as tool_failed with its message, one slower than the call's timeout as timeout, a Codex without mcpServer/tool/call or no Codex at all is unavailable, and a plugin's mcpTools refuse any other tool as permission_denied. A plugin's background half calls it on app.focus and saves the result in its state, which its popover shows.
    func test_plugin_mcp_call_codex() throws {
        let environment = try installCodexFixture(named: "codex-fixture-ui-mcp")
        let executable = try XCTUnwrap(environment["PLAYHOUSE_E2E_CODEX_EXECUTABLE"])
        let profile = "mcp__claude_ai_Slack__slack_read_user_profile", search = "mcp__claude_ai_Slack__slack_search_public_and_private"
        try JSONSerialization.data(withJSONObject: [
            profile: ["content": [["type": "text", "text": "Nir Yosef"]]],
            search: ["content": [["type": "text", "text": "Dana"], ["type": "text", "text": "Omri"]], "structuredContent": ["count": 2], "isError": false],
        ]).write(to: URL(fileURLWithPath: executable + ".mcp-results"))
        func lines(_ suffix: String) -> [[String: Any]] { jsonLines(executable + suffix).compactMap { $0 as? [String: Any] } }
        func code(_ response: [String: Any]) -> String? { (response["error"] as? [String: Any])?["code"] as? String }
        try writeInstalledPlugin("codex-reader", source: Self.serviceCodexMcpPluginSource, placement: "mainSidebar", presentation: "popover",
                                 name: "Codex Reader", icon: "bubble.left", extra: ["events": ["app.focus"], "mcpTools": [search]])
        launchApp(defaultParent: fixture.parent.path)
        _ = try runCLI(["plugin", "refresh"])

        // The window's focus wakes the background half, which calls the tool through Codex with no turn.
        refocusApp()
        XCTAssertTrue(waitUntil({ ((try? self.pluginState("codex-reader"))?["people"] as? [String]) == ["Dana", "Omri"] }, timeout: 30), "The service saves the Codex tool's result.")
        let entry = element("plugin-entry-codex-reader")
        XCTAssertTrue(entry.waitToExist(timeout: 10))
        entry.click()
        let people = element("mcp-people")
        XCTAssertTrue(waitUntil({ people.exists && self.pluginText(people) == "Dana, Omri" }, timeout: 10), "The popover shows what the service read: \(pluginText(people))")
        attachScreenshot(named: "The popover shows the people its background half read through Codex")
        attachElementScreenshot(element("plugin-surface-codex-reader"), named: "Slack DMs read by Codex's mcpServer/tool/call")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(lines(".mcp-calls").last?["server"] as? String, "claude_ai_Slack")
        XCTAssertEqual(lines(".mcp-calls").last?["tool"] as? String, "slack_search_public_and_private")

        let answer = try XCTUnwrap(try runCLI(["mcp", "call", "--provider", "codex", "--tool", profile, "--arguments", #"{"user":"U1"}"#])["result"] as? [String: Any])
        XCTAssertEqual(((answer["content"] as? [[String: Any]])?.first)?["text"] as? String, "Nir Yosef")
        XCTAssertEqual((lines(".mcp-calls").last?["arguments"] as? [String: Any])?["user"] as? String, "U1")
        XCTAssertEqual(lines(".ephemeral-threads").count, 1, "A burst of calls reuses one ephemeral thread.")
        XCTAssertEqual(lines(".ephemeral-threads").first?["sandbox"] as? String, "read-only")
        XCTAssertEqual(Set(lines(".mcp-calls").compactMap { $0["threadId"] as? String }).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: executable + ".turn-starts"), "No turn ran.")
        let warm = try XCTUnwrap(lines(".ephemeral-threads").first?["threadId"] as? String)
        _ = try runCLI(["mcp", "call", "--provider", "codex", "--tool", profile], extraEnvironment: ["PLAYHOUSE_E2E_MCP_SESSION_IDLE_SECONDS": "1"])
        XCTAssertTrue(waitUntil({ lines(".unsubscribed").contains { $0["threadId"] as? String == warm } }, timeout: 15), "The idle thread is released.")
        _ = try runCLI(["mcp", "call", "--provider", "codex", "--tool", profile])
        XCTAssertEqual(lines(".ephemeral-threads").count, 2, "After the release, a call starts a new thread.")
        let failed = try runCLI(["mcp", "call", "--provider", "codex", "--tool", "mcp__linear__list_issues"], expectedStatus: 1)
        XCTAssertEqual(code(failed), "tool_failed")
        XCTAssertTrue(((failed["error"] as? [String: Any])?["message"] as? String ?? "").contains("MCP server not connected: linear"))
        XCTAssertEqual(code(try runCLI(["mcp", "call", "--provider", "codex", "--tool", profile, "--plugin", "codex-reader"], expectedStatus: 1)), "permission_denied")

        let channel = "mcp__claude_ai_Slack__slack_read_channel"
        try JSONSerialization.data(withJSONObject: [channel: ["content": [["type": "text", "text": "hi"]]]]).write(to: URL(fileURLWithPath: executable + ".mcp-results"))
        try JSONSerialization.data(withJSONObject: [channel: 4]).write(to: URL(fileURLWithPath: executable + ".mcp-call-delay"))
        XCTAssertEqual(code(try runCLI(["mcp", "call", "--provider", "codex", "--tool", channel, "--timeout", "1"], expectedStatus: 1)), "timeout")

        let unsupported = try installCodexFixture(named: "codex-fixture-ui-no-mcp-call")
        let refused = try runCLI(["mcp", "call", "--provider", "codex", "--tool", profile], expectedStatus: 1, extraEnvironment: unsupported)
        XCTAssertEqual(code(refused), "unavailable")
        XCTAssertTrue(((refused["error"] as? [String: Any])?["message"] as? String ?? "").contains("can't call MCP tools directly"))
        XCTAssertEqual(code(try runCLI(["mcp", "call", "--provider", "codex", "--tool", profile], expectedStatus: 1, extraEnvironment: ["PLAYHOUSE_E2E_CODEX_EXECUTABLE": "none"])), "unavailable")
        XCTAssertEqual(code(try runCLI(["mcp", "call", "--provider", "gemini", "--tool", profile], expectedStatus: 2)), "invalid_argument")
    }

    // case-contract: test_plugin_agent_run_codex | agent.run with provider codex (CLI agent run --provider codex, Playhouse.agent.run from the popover with the plugin's provider) starts one turn on an ephemeral, read-only Codex thread of the shared app-server with no approvals, the prompt, the model and the JSON schema as outputSchema, and returns its runID at once; agent runs lists it as a running Codex run, and its thread is released (thread/unsubscribe) when the turn ends. When it ends, only that plugin's background half hears agent.finished: done with the final message parsed as the schema's structured output, which the plugin's handler uses to create a board task, failed with Codex's error, when the message isn't JSON for the schema, or after the run timeout, or cancelled after agent cancel, which interrupts the turn. A run cut off by its daemon dying is reported failed with the error "interrupted" by the next daemon, which also interrupts the orphaned turn on the app-server that outlived it. With no Codex installed, agent.run with provider codex is unavailable.
    func test_plugin_agent_run_codex() throws {
        let environment = try installCodexFixture(named: "codex-fixture-ui-agent")
        let executable = try XCTUnwrap(environment["PLAYHOUSE_E2E_CODEX_EXECUTABLE"])
        let output = URL(fileURLWithPath: executable + ".agent-output")
        let answer = try JSONSerialization.data(withJSONObject: ["title": "Reply to Omri", "prompt": "Answer Omri's question.", "nothingNew": false])
        try answer.write(to: output)
        let hold = URL(fileURLWithPath: executable + ".agent-hold")
        addTeardownBlock { try? FileManager.default.removeItem(at: hold) }
        try writeInstalledPlugin("slack-dms", source: Self.serviceAgentPluginSource, placement: "mainSidebar", presentation: "popover",
                                 name: "Slack DMs", icon: "bubble.left.and.bubble.right", extra: ["events": ["agent.finished"]])
        try writeInstalledPlugin("listener-plugin", source: Self.serviceListenerPluginSource, placement: "composerActions", presentation: "headless",
                                 extra: ["events": ["agent.finished"]])
        // Its own daemon, so killing it leaves the UI runner's shared one alone.
        let daemon = ["PLAYHOUSE_BRIDGE_SERVICE_NAME": "\(serviceName!).codex-agents-\(UUID().uuidString.prefix(8))"]
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: daemon)
        _ = try runCLI(["plugin", "refresh"], extraEnvironment: daemon)
        func finished() -> [String: Any]? { (try? pluginState("slack-dms", environment: daemon))?["finished"] as? [String: Any] }
        func runs() -> [[String: Any]] { jsonLines(executable + ".agent-runs").compactMap { $0 as? [String: Any] } }
        func interrupts() -> Int { ((try? String(contentsOfFile: executable + ".methods", encoding: .utf8)) ?? "").components(separatedBy: "\n").filter { $0 == "turn/interrupt" }.count }
        func code(_ response: [String: Any]) -> String? { (response["error"] as? [String: Any])?["code"] as? String }
        let schema = #"{"type":"object","properties":{"title":{"type":"string"}},"required":["title"]}"#
        func run(_ user: String, extra: [String: String] = [:]) throws -> String {
            try XCTUnwrap((try runCLI(["agent", "run", "--plugin", "slack-dms", "--provider", "codex", "--prompt", "Draft a task for \(user).", "--model", "gpt-5.5",
                                       "--json-schema", schema, "--context", #"{"kind":"slack-task","userId":"\#(user)"}"#],
                                      extraEnvironment: daemon.merging(extra) { _, new in new })["result"] as? [String: Any])?["runID"] as? String)
        }
        func boardCard(_ title: String) -> XCUIElement? {
            guard let id = (try? taskRecord(named: title))??["id"] as? String else { return nil }
            return element("task-card-\(id)")
        }

        // The popover's button runs the agent on the plugin's provider; its background half creates the task.
        _ = try runCLI(["plugin", "state", "--id", "slack-dms", "--key", "provider", "--value", #""codex""#], extraEnvironment: daemon)
        try Data().write(to: hold)
        let entry = element("plugin-entry-slack-dms")
        XCTAssertTrue(entry.waitToExist(timeout: 10), "The popover plugin has its sidebar button.")
        entry.click()
        let create = element("dm-create-U7")
        XCTAssertTrue(create.waitToExist(timeout: 10))
        create.click()
        let job = element("dm-job")
        XCTAssertTrue(waitUntil({ self.pluginText(job) == "running" }, timeout: 15), "agent.run answers at once with its runID: \(pluginText(job))")
        let listed = try XCTUnwrap((try runCLI(["agent", "runs"], extraEnvironment: daemon)["result"] as? [String: Any])?["runs"] as? [[String: Any]])
        XCTAssertEqual(listed.first?["provider"] as? String, "codex")
        XCTAssertEqual(listed.first?["running"] as? Bool, true)
        let runID = try XCTUnwrap(listed.first?["runID"] as? String)
        XCTAssertTrue(waitUntil({ !runs().isEmpty }, timeout: 15), "The Codex turn started.")
        XCTAssertEqual(runs().last?["model"] as? String, "gpt-5.5")
        XCTAssertEqual(runs().last?["sandbox"] as? String, "readOnly")
        XCTAssertEqual(runs().last?["approvalPolicy"] as? String, "never")
        XCTAssertEqual(((runs().last?["outputSchema"] as? [String: Any])?["required"] as? [String]), ["title", "prompt", "nothingNew"])
        XCTAssertTrue((runs().last?["threadId"] as? String ?? "").hasPrefix("ephemeral-"), "The run has an ephemeral thread of its own.")
        XCTAssertNil(finished(), "Nothing is heard while the agent runs.")
        attachElementScreenshot(element("plugin-surface-slack-dms"), named: "The popover started a Codex agent run, which is still running")
        app.typeKey(.escape, modifierFlags: [])
        try FileManager.default.removeItem(at: hold)
        XCTAssertTrue(waitUntil({ finished()?["status"] as? String == "done" }, timeout: 30), "The plugin's service hears agent.finished.")
        XCTAssertEqual(finished()?["runID"] as? String, runID)
        XCTAssertEqual(finished()?["title"] as? String, "Reply to Omri")
        XCTAssertTrue(waitUntil({ boardCard("Reply to Omri")?.exists == true }, timeout: 15), "The new task is on the board.")
        let runThread = try XCTUnwrap(runs().first?["threadId"] as? String)
        XCTAssertTrue(waitUntil({ jsonLines(executable + ".unsubscribed").contains { ($0 as? [String: Any])?["threadId"] as? String == runThread } }, timeout: 15),
                      "The finished run's thread is released.")
        entry.click()
        let result = element("dm-finished")
        XCTAssertTrue(waitUntil({ self.pluginText(result) == "done U7 Reply to Omri" }, timeout: 10), "The reopened popover shows the result: \(pluginText(result))")
        attachScreenshot(named: "The Codex agent's result created a task, and the popover shows it")
        app.typeKey(.escape, modifierFlags: [])

        // Failed, unparsable, cancelled and timed out.
        try Data().write(to: URL(fileURLWithPath: executable + ".agent-fail"))
        let failedID = try run("U8")
        XCTAssertTrue(waitUntil({ finished()?["runID"] as? String == failedID }, timeout: 30))
        XCTAssertEqual(finished()?["status"] as? String, "failed")
        XCTAssertEqual(finished()?["error"] as? String, "The fixture agent failed on purpose.")
        try FileManager.default.removeItem(at: URL(fileURLWithPath: executable + ".agent-fail"))
        try Data("not json".utf8).write(to: output)
        let unparsedID = try run("U9")
        XCTAssertTrue(waitUntil({ finished()?["runID"] as? String == unparsedID }, timeout: 30))
        XCTAssertEqual(finished()?["status"] as? String, "failed")
        XCTAssertEqual(finished()?["error"] as? String, "Codex returned no structured output for the JSON schema.")
        try answer.write(to: output)
        try Data().write(to: hold)
        var before = interrupts()
        let cancelledID = try run("U10")
        _ = try runCLI(["agent", "cancel", "--plugin", "slack-dms", "--run", cancelledID], extraEnvironment: daemon)
        XCTAssertTrue(waitUntil({ finished()?["runID"] as? String == cancelledID }, timeout: 30))
        XCTAssertEqual(finished()?["status"] as? String, "cancelled")
        XCTAssertGreaterThan(interrupts(), before, "Cancelling interrupts the Codex turn.")
        let timedID = try run("U11", extra: ["PLAYHOUSE_E2E_PLUGIN_AGENT_TIMEOUT_SECONDS": "1"])
        XCTAssertTrue(waitUntil({ finished()?["runID"] as? String == timedID }, timeout: 30))
        XCTAssertEqual(finished()?["status"] as? String, "failed")
        XCTAssertEqual(finished()?["error"] as? String, "The agent didn't finish within 1 seconds.")
        XCTAssertNil(try pluginState("listener-plugin", environment: daemon)["finished"], "Another plugin never hears slack-dms's runs.")

        // Cut off with its daemon; the app-server outlives it, and the next daemon interrupts the orphaned turn.
        before = interrupts()
        _ = try run("U12")
        XCTAssertTrue(waitUntil({ runs().contains { ($0["prompt"] as? String ?? "").contains("U12") } }, timeout: 15), "The U12 turn started.")
        let firstPID = try XCTUnwrap(try daemonProcessID(environment: daemon))
        kill(pid_t(firstPID), SIGKILL)
        XCTAssertTrue(waitUntil({ ((try? self.daemonProcessID(environment: daemon)) ?? firstPID) != firstPID }, timeout: 20), "A fresh daemon takes over.")
        _ = try runCLI(["agent", "runs"], extraEnvironment: daemon)
        // The service files it on the board (a test store's settings can't be read back across daemons).
        let interruptedTitle = "Slack task failed for U12: interrupted"
        XCTAssertTrue(waitUntil({ boardCard(interruptedTitle)?.exists == true }, timeout: 30), "The next daemon reports the cut-off run, and the board shows it.")
        XCTAssertTrue(waitUntil({ interrupts() > before }, timeout: 15), "The next daemon interrupts the orphaned Codex turn.")
        attachElementScreenshot(try XCTUnwrap(boardCard(interruptedTitle)), named: "A Codex run cut off with its daemon is reported as interrupted")
        XCTAssertEqual(code(try runCLI(["agent", "run", "--plugin", "slack-dms", "--provider", "codex", "--prompt", "Go."], expectedStatus: 1,
                                       extraEnvironment: daemon.merging(["PLAYHOUSE_E2E_CODEX_EXECUTABLE": "none"]) { _, new in new })), "unavailable")
    }

    // case-contract: test_provider_install_from_composer | With no CLI installed, providers list reports Claude Code, Codex CLI and OpenCode missing with their official curl installers, and the composer shows an Install AI provider button whose menu lists Claude, Codex and OpenCode instead of the provider picker, with no model and effort picker beside it. Installing Codex runs its installer once; Codex is then listed as installed and runs the task's turn without a restart, and the provider menu shows Codex with an Add Claude entry, with the model and effort picker back beside it. A new task whose default provider (Claude) is missing starts on the installed Codex instead, without changing the saved default. A failing installer reports its output and leaves Claude missing; adding Claude again installs it and switches the task to Claude, and adding OpenCode then installs it the same way and switches the task to OpenCode, leaving nothing to add. Installing a provider that is already installed doesn't rerun its installer, and an unknown provider is rejected.
    func test_provider_install_from_composer() throws {
        // The installer fixture installs each provider's CLI fixture into this folder, where the
        // provider executables point; until it runs, both providers read as not installed.
        let directory = dataDirectory.appendingPathComponent("provider-install", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("Playhouse bridge tests own this deterministic fixture (v1).\n".utf8).write(to: directory.appendingPathComponent(".playhouse-bridge-fixture"))
        let installer = directory.appendingPathComponent("provider-installer")
        try copyFixtureFile(at: WorkspaceFixture.root.appendingPathComponent("provider-installer-fixture"), to: installer)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installer.path)
        try copyFixtureFile(at: WorkspaceFixture.root.appendingPathComponent("codex-fixture-ui"), to: directory.appendingPathComponent("codex.payload"))
        try copyFixtureFile(at: WorkspaceFixture.root.appendingPathComponent("claude-fixture-ui"), to: directory.appendingPathComponent("claude.payload"))
        try copyFixtureFile(at: WorkspaceFixture.root.appendingPathComponent("opencode-fixture-ui"), to: directory.appendingPathComponent("opencode.payload"))
        codexFixtureExecutable = directory.appendingPathComponent("codex").path
        claudeFixtureExecutable = directory.appendingPathComponent("claude").path
        openCodeFixtureExecutable = directory.appendingPathComponent("opencode").path
        let installerEnvironment = ["PLAYHOUSE_E2E_PROVIDER_INSTALLER": installer.path]
        let installs = directory.appendingPathComponent("installs.log")
        func installLog() -> [String] {
            ((try? String(contentsOf: installs, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        func statuses() throws -> [String: [String: Any]] {
            let listed = try XCTUnwrap(try runCLI(["providers", "list"])["result"] as? [[String: Any]])
            return Dictionary(uniqueKeysWithValues: listed.compactMap { status in (status["provider"] as? String).map { ($0, status) } })
        }
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: installerEnvironment)
        let missing = try statuses()
        XCTAssertEqual(missing["claude"]?["isInstalled"] as? Bool, false)
        XCTAssertEqual(missing["codex"]?["isInstalled"] as? Bool, false)
        XCTAssertEqual(missing["claude"]?["installCommand"] as? String, "curl -fsSL https://claude.ai/install.sh | bash")
        XCTAssertEqual(missing["codex"]?["installCommand"] as? String, "curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh")
        XCTAssertEqual(missing["opencode"]?["isInstalled"] as? Bool, false)
        XCTAssertEqual(missing["opencode"]?["installCommand"] as? String, "curl -fsSL https://opencode.ai/v2/install | bash")

        openNewTaskConversation()
        var installTaskID = try taskID(named: "Untitled task")
        let providerMenu = element("conversation-provider-menu")
        XCTAssertTrue(waitUntil({ providerMenu.exists && providerMenu.label == "Install AI provider" }, timeout: 15),
                      "With no provider installed the provider picker becomes Install AI provider: \(providerMenu.label)")
        XCTAssertFalse(element("provider-capabilities-notice").exists, "No grey provider notice explains a missing CLI.")
        let modelPicker = element("model-picker-menu")
        XCTAssertFalse(modelPicker.exists, "With no provider installed the model and effort picker is hidden.")
        attachRegionScreenshot([providerMenu, element("send-message-button")], named: "Install AI provider stands alone, with no model and effort picker")
        providerMenu.click()
        let installClaude = app.menuItems["conversation-provider-install-claude"]
        let installCodex = app.menuItems["conversation-provider-install-codex"]
        let installOpenCode = app.menuItems["conversation-provider-install-opencode"]
        XCTAssertTrue(installClaude.waitToExist(timeout: 5) && installCodex.exists && installOpenCode.exists, "Install AI provider lists Claude, Codex and OpenCode.")
        XCTAssertEqual(installClaude.title, "Claude")
        XCTAssertEqual(installCodex.title, "Codex")
        XCTAssertEqual(installOpenCode.title, "OpenCode")
        XCTAssertFalse(app.menuItems["conversation-provider-codex"].exists, "Nothing to switch to before an install.")
        attachScreenshot(named: "Install AI provider lists the providers to install")
        attachRegionScreenshot([installClaude, installCodex, installOpenCode], named: "Install AI provider menu: Claude, Codex and OpenCode")
        installCodex.click()
        XCTAssertTrue(waitUntil({ providerMenu.label == "Provider: Codex" && providerMenu.isEnabled }, timeout: 30),
                      "Installing Codex makes it the task's provider: \(providerMenu.label)")
        XCTAssertEqual(installLog(), ["codex"])
        XCTAssertEqual(try statuses()["codex"]?["isInstalled"] as? Bool, true)
        XCTAssertEqual(try statuses()["claude"]?["isInstalled"] as? Bool, false)
        XCTAssertEqual(try taskRecord(id: installTaskID)?["conversationProvider"] as? String, "codex")
        XCTAssertTrue(modelPicker.waitToExist(timeout: 10), "Once Codex is installed the model and effort picker is back.")

        providerMenu.click()
        XCTAssertTrue(app.menuItems["conversation-provider-codex"].waitToExist(timeout: 5), "The menu lists the installed Codex.")
        XCTAssertFalse(app.menuItems["conversation-provider-claude"].exists, "Claude isn't offered to switch to while it's missing.")
        XCTAssertEqual(installClaude.title, "Add Claude")
        attachScreenshot(named: "Provider menu shows Codex and Add Claude")
        attachRegionScreenshot([app.menuItems["conversation-provider-codex"], installClaude], named: "Provider menu: Codex, then Add Claude")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])

        // The installed Codex runs the turn, with no restart.
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Untitled task", prompt: "Hello from a freshly installed Codex.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("codex.history").path), "The installed Codex ran the turn.")
        attachScreenshot(named: "Installed Codex answers the turn")

        // A new task whose default provider is missing starts on the installed one, and the
        // saved default stays.
        _ = try runCLI(["settings", "set-default-provider", "claude"])
        let firstTaskID = installTaskID
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10))
        openNewTaskConversation()
        installTaskID = try XCTUnwrap(try tasksFromBoardList().compactMap { $0["id"] as? String }.first { $0 != firstTaskID })
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: installTaskID)?["conversationProvider"] as? String) == "codex" }, timeout: 15),
                      "A new task on the missing Claude should move to the installed Codex.")
        XCTAssertTrue(waitUntil({ providerMenu.label == "Provider: Codex" && providerMenu.isEnabled }, timeout: 10), providerMenu.label)
        let keptDefault = try XCTUnwrap(try runCLI(["settings", "get"])["result"] as? [String: Any])
        XCTAssertEqual(keptDefault["defaultProvider"] as? String, "claude", "Moving to the installed provider isn't the user's choice of default.")
        attachScreenshot(named: "A new task on a missing default starts on the installed Codex")

        // A failing installer reports its output and leaves Claude missing.
        try "curl: (6) Could not resolve host: claude.ai\n".write(to: directory.appendingPathComponent("claude.install-fails"), atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil({ providerMenu.isEnabled }, timeout: 10))
        providerMenu.click()
        XCTAssertTrue(installClaude.waitToExist(timeout: 5))
        installClaude.click()
        let error = element("codex-chat-error")
        XCTAssertTrue(waitUntil({ error.exists && error.label.contains("Could not resolve host: claude.ai") }, timeout: 20), "The installer's failure is shown: \(error.label)")
        XCTAssertTrue(error.label.contains("Couldn't install Claude Code"))
        XCTAssertEqual(providerMenu.label, "Provider: Codex", "A failed install keeps the task's provider.")
        XCTAssertEqual(try statuses()["claude"]?["isInstalled"] as? Bool, false)
        attachScreenshot(named: "A failed Claude install shows the installer's error")
        attachRegionScreenshot([error, providerMenu], named: "The installer's error above the composer")

        try FileManager.default.removeItem(at: directory.appendingPathComponent("claude.install-fails"))
        _ = try runCLI(["settings", "set-default-provider", "codex"])
        providerMenu.click()
        XCTAssertTrue(installClaude.waitToExist(timeout: 5))
        installClaude.click()
        XCTAssertTrue(waitUntil({ providerMenu.label == "Provider: Claude" }, timeout: 30), "Adding Claude installs it and switches to it: \(providerMenu.label)")
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: installTaskID)?["conversationProvider"] as? String) == "claude" }, timeout: 10))
        XCTAssertEqual(installLog(), ["codex", "claude", "claude"])
        XCTAssertFalse(error.exists, "A successful install clears the error.")
        let chosenDefault = try XCTUnwrap(try runCLI(["settings", "get"])["result"] as? [String: Any])
        XCTAssertEqual(chosenDefault["defaultProvider"] as? String, "claude")
        providerMenu.click()
        XCTAssertTrue(installOpenCode.waitToExist(timeout: 5), "OpenCode is still offered to add.")
        XCTAssertEqual(installOpenCode.title, "Add OpenCode")
        installOpenCode.click()
        XCTAssertTrue(waitUntil({ providerMenu.label == "Provider: OpenCode" }, timeout: 30), "Adding OpenCode installs it and switches to it: \(providerMenu.label)")
        XCTAssertEqual(installLog(), ["codex", "claude", "claude", "opencode"])
        providerMenu.click()
        XCTAssertTrue(app.menuItems["conversation-provider-claude"].waitToExist(timeout: 5) && app.menuItems["conversation-provider-codex"].exists
                      && app.menuItems["conversation-provider-opencode"].exists)
        XCTAssertFalse(installClaude.exists || installCodex.exists || installOpenCode.exists, "With every provider installed there is nothing to add.")
        attachScreenshot(named: "Every provider installed and OpenCode selected")
        attachRegionScreenshot([app.menuItems["conversation-provider-claude"], app.menuItems["conversation-provider-codex"], app.menuItems["conversation-provider-opencode"]], named: "Provider menu with every provider installed")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])

        _ = try runCLI(["providers", "install", "codex"], extraEnvironment: installerEnvironment)
        XCTAssertEqual(installLog(), ["codex", "claude", "claude", "opencode"], "An installed provider isn't installed again.")
        let unknown = try runCLI(["providers", "install", "gemini"], expectedStatus: 2, extraEnvironment: installerEnvironment)
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? String, "invalid_argument")
    }
}
