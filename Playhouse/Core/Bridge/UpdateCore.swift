#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation
#if canImport(Security)
import Security
#endif

/// The parts of the release system the CLI needs on its own, without the daemon:
/// the signed manifest, version order, checking a downloaded bundle, and the
/// installer that replaces the app. Compiled into the app, the CLI and the daemon
/// (see scripts/build-bridge.sh); the daemon's `UpdateManager` drives the rest.
///
/// Updates replace a signed macOS app bundle. On a platform without CryptoKit or the
/// Security framework, manifest and bundle verification always reject, so nothing installs;
/// a Linux build updates through its package manager instead.
package enum PlayhouseRelease {
    /// Info.plist key `scripts/release.sh` sets to "stable". A build without it is
    /// a development build: it never checks for, offers or installs an update.
    package static let channelKey = "PlayhouseReleaseChannel"
    package static let stableChannel = "stable"
    package static let repository = "Niryo/Playhouse"
    package static let manifestAssetName = "playhouse-release.json"
    /// GitHub serves the latest release's assets from its download CDN, which has
    /// no API rate limit, so many installs behind one address can all check.
    package static let feedURL = URL(string: "https://github.com/\(repository)/releases/latest/download/\(manifestAssetName)")!
    /// Used only when the feed above fails: the REST API names the same asset.
    package static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    /// Posted by the installer with the target bundle's `realPath` as its object;
    /// the app running from that bundle quits so it can be replaced.
    package static let quitNotification = "com.playhouse.app.update.quit"

    /// `path` with symlinks resolved, so /tmp/... and the /private/tmp/... a
    /// launched app reports as its bundle path name the same bundle.
    package static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    /// Shown when macOS refuses to let Playhouse replace its own app.
    package static let permissionAdvice = "Allow Playhouse in System Settings → Privacy & Security → App Management, or move it to a folder you can write to, then try again."
    /// Shown when the app runs from somewhere it can't replace itself.
    package static let moveToApplicationsMessage = "Move Playhouse to Applications to receive updates."

    package static func channel(of info: [String: Any]) -> String {
        (info[channelKey] as? String) == stableChannel ? stableChannel : "development"
    }

    package static func infoDictionary(ofBundle bundle: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// Where a download is unpacked before it replaces `target`: beside it, so
    /// the swap is a rename on one volume.
    package static func stagedBundle(for target: URL) -> URL {
        target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).update", isDirectory: true)
    }

    /// Where the replaced bundle waits until the new one proved it starts.
    package static func previousBundle(for target: URL) -> URL {
        target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).previous", isDirectory: true)
    }

    package static func launchedMarker(stateDirectory: URL, build: String) -> URL {
        stateDirectory.appendingPathComponent("launched-\(build)")
    }

    package static func installRecordURL(stateDirectory: URL) -> URL {
        stateDirectory.appendingPathComponent("last-install.json")
    }
}

/// A semantic version, major.minor.patch.
package struct PlayhouseVersion: Comparable, CustomStringConvertible {
    package let major: Int
    package let minor: Int
    package let patch: Int

    package init?(_ text: String) {
        let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 3, let major = parts[0], let minor = parts[1], let patch = parts[2],
              major >= 0, minor >= 0, patch >= 0 else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    package var description: String { "\(major).\(minor).\(patch)" }

    package static func < (lhs: PlayhouseVersion, rhs: PlayhouseVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// What a release offers, as its maintainer signed it.
package struct ReleaseInfo: Codable, Equatable {
    package struct Asset: Codable, Equatable {
        package var name: String
        package var url: String
        package var size: Int
        package var sha256: String

        package init(name: String, url: String, size: Int, sha256: String) {
            self.name = name
            self.url = url
            self.size = size
            self.sha256 = sha256
        }
    }

    package var version: String
    package var build: String
    package var commit: String?
    package var publishedAt: String?
    package var minimumSystemVersion: String?
    /// The CPU the release was built for, `arm64`.
    package var architecture: String?
    package var notes: String
    package var asset: Asset

    /// Whether this Mac can run the release: its architecture and macOS version.
    package var runsOnThisMac: Bool {
        if let architecture, architecture != Self.machineArchitecture { return false }
        guard let minimum = minimumSystemVersion else { return true }
        let parts = minimum.split(separator: ".").map { Int($0) ?? 0 }
        let required = OperatingSystemVersion(
            majorVersion: parts.first ?? 0,
            minorVersion: parts.count > 1 ? parts[1] : 0,
            patchVersion: parts.count > 2 ? parts[2] : 0
        )
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(required)
    }

    package static var machineArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    /// The day the release was published, for people to read.
    package var publishedDay: String? {
        guard let publishedAt, let date = ISO8601DateFormatter().date(from: publishedAt) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter.string(from: date)
    }

    package init(version: String, build: String, commit: String? = nil, publishedAt: String? = nil, minimumSystemVersion: String? = nil, architecture: String? = nil, notes: String, asset: Asset) {
        self.version = version
        self.build = build
        self.commit = commit
        self.publishedAt = publishedAt
        self.minimumSystemVersion = minimumSystemVersion
        self.architecture = architecture
        self.notes = notes
        self.asset = asset
    }
}

/// `playhouse-release.json`: the release info as base64 JSON bytes and an
/// Ed25519 signature over exactly those bytes, so nothing depends on how JSON
/// is re-encoded.
package struct SignedReleaseManifest: Codable {
    package var payload: String
    package var signature: String

    package init(payload: String, signature: String) {
        self.payload = payload
        self.signature = signature
    }
}

package struct ReleaseVerificationError: LocalizedError {
    package let code: String
    package let message: String
    package var errorDescription: String? { message }

    package static func rejected(_ message: String) -> ReleaseVerificationError {
        ReleaseVerificationError(code: "update_rejected", message: message)
    }

    package init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

package enum ReleaseManifestVerifier {
    /// The release info, only if `publicKey` signed it.
    package static func verify(_ data: Data, publicKey: String) throws -> ReleaseInfo {
        #if canImport(CryptoKit)
        guard !publicKey.isEmpty, let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            throw ReleaseVerificationError(code: "update_unavailable", message: "This build has no release signing key, so it can't verify updates.")
        }
        #endif
        guard let manifest = try? JSONDecoder().decode(SignedReleaseManifest.self, from: data),
              let payload = Data(base64Encoded: manifest.payload),
              let signature = Data(base64Encoded: manifest.signature) else {
            throw ReleaseVerificationError.rejected("The release manifest isn't readable.")
        }
        #if canImport(CryptoKit)
        guard key.isValidSignature(signature, for: payload) else {
            throw ReleaseVerificationError.rejected("The release manifest's signature doesn't match Playhouse's release key.")
        }
        #else
        throw ReleaseVerificationError(code: "update_unavailable", message: "This platform installs Playhouse updates through its package manager.")
        #endif
        guard let info = try? JSONDecoder().decode(ReleaseInfo.self, from: payload) else {
            throw ReleaseVerificationError.rejected("The signed release manifest isn't readable.")
        }
        guard PlayhouseVersion(info.version) != nil else {
            throw ReleaseVerificationError.rejected("The release version \(info.version) isn't a semantic version.")
        }
        guard info.asset.sha256.count == 64, info.asset.size > 0 else {
            throw ReleaseVerificationError.rejected("The release manifest doesn't describe its download.")
        }
        return info
    }

    package static func sha256(ofFile url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Hashing.SHA256Hasher()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Checks an unpacked app bundle before it may replace the installed one.
package enum ReleaseBundleVerifier {
    package struct Summary {
        package var bundleIdentifier: String
        package var version: String
        package var build: String

        package init(bundleIdentifier: String, version: String, build: String) {
            self.bundleIdentifier = bundleIdentifier
            self.version = version
            self.build = build
        }
    }

    package static let requiredExecutables = ["playhouse-cli", "playhouse-daemon"]

    /// `candidate` must be a valid stable Playhouse build of `expectedVersion`
    /// (when given), for the same bundle identifier as `installed`, signed by the
    /// same certificate. Ad-hoc signatures pass only in a test build replacing an
    /// ad-hoc test build, which is what the bridge and UI fixtures produce.
    package static func verify(candidate: URL, replacing installed: URL, expectedVersion: String?) throws -> Summary {
        guard let info = PlayhouseRelease.infoDictionary(ofBundle: candidate) else {
            throw ReleaseVerificationError.rejected("The download has no Playhouse app in it.")
        }
        guard let installedInfo = PlayhouseRelease.infoDictionary(ofBundle: installed) else {
            throw ReleaseVerificationError(code: "update_failed", message: "Playhouse isn't installed at \(installed.path).")
        }
        let identifier = info["CFBundleIdentifier"] as? String ?? ""
        guard !identifier.isEmpty, identifier == installedInfo["CFBundleIdentifier"] as? String else {
            throw ReleaseVerificationError.rejected("The download is a different app (\(identifier)).")
        }
        guard PlayhouseRelease.channel(of: info) == PlayhouseRelease.stableChannel else {
            throw ReleaseVerificationError.rejected("The download isn't a Playhouse release build.")
        }
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        if let expectedVersion, version != expectedVersion {
            throw ReleaseVerificationError.rejected("The download is version \(version), not \(expectedVersion).")
        }
        let executableName = info["CFBundleExecutable"] as? String ?? "Playhouse"
        let macOS = candidate.appendingPathComponent("Contents/MacOS", isDirectory: true)
        for name in [executableName] + requiredExecutables
        where !FileManager.default.isExecutableFile(atPath: macOS.appendingPathComponent(name).path) {
            throw ReleaseVerificationError.rejected("The download is missing \(name).")
        }
        let certificate = try leafCertificate(ofValidBundle: candidate)
        let installedCertificate = try? leafCertificate(ofValidBundle: installed)
        switch (certificate, installedCertificate) {
        case let (candidate?, installed?) where candidate == installed:
            break
        case (nil, nil) where BridgeContract.isTestBundle(identifier):
            break
        default:
            throw ReleaseVerificationError.rejected("The download isn't signed with Playhouse's release certificate.")
        }
        return Summary(bundleIdentifier: identifier, version: version, build: info["CFBundleVersion"] as? String ?? "")
    }

    /// The SHA-256 of the signing certificate, or nil for an ad-hoc signature;
    /// throws when the bundle's signature, or any code nested in it, is broken.
    package static func leafCertificate(ofValidBundle bundle: URL) throws -> String? {
        #if !canImport(Security)
        throw ReleaseVerificationError.rejected("This platform can't check an app bundle's code signature.")
        #else
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            throw ReleaseVerificationError.rejected("The download's code signature can't be read.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(staticCode, flags, nil)
        guard status == errSecSuccess else {
            throw ReleaseVerificationError.rejected("The download's code signature is invalid (\(status)).")
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else {
            throw ReleaseVerificationError.rejected("The download's code signature can't be read.")
        }
        guard let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        let data = SecCertificateCopyData(leaf) as Data
        return Hashing.sha256(data).map { String(format: "%02x", $0) }.joined()
        #endif
    }
}

/// What the last install did, for the app to show after it restarts.
package struct UpdateInstallRecord: Codable, Equatable {
    package var status: String
    package var fromVersion: String
    package var toVersion: String
    package var message: String?
    package var finishedAt: Date
    /// The installed release's notes, which the app shows when its notice is opened.
    package var notes: String?
    /// The notice was opened or dismissed, so the app no longer shows it.
    package var acknowledged = false

    /// The app shows an install's notice for a day, until it is opened.
    package static let noticeLifetime: TimeInterval = 24 * 60 * 60

    package var isNoticeShown: Bool {
        !acknowledged && Date().timeIntervalSince(finishedAt) < Self.noticeLifetime
    }

    package init(status: String, fromVersion: String, toVersion: String, message: String? = nil, finishedAt: Date, notes: String? = nil, acknowledged: Bool = false) {
        self.status = status
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.message = message
        self.finishedAt = finishedAt
        self.notes = notes
        self.acknowledged = acknowledged
    }
}

/// Replaces an installed Playhouse with a staged one. Runs as `playhouse-cli
/// update apply` from the staged bundle, in its own session, so it outlives the
/// app and the daemon it stops.
package struct ReleaseInstaller {
    package struct Options {
        package var staged: URL
        package var target: URL
        package var stateDirectory: URL
        package var serviceName: String?
        package var socketPath: String?
        /// Environment the new version opens with, as the app that asked ran.
        package var relaunchEnvironment: [String: String] = [:]
        package var appQuitTimeout: TimeInterval = 60
        package var launchTimeout: TimeInterval = 60

        package init(staged: URL, target: URL, stateDirectory: URL, serviceName: String? = nil, socketPath: String? = nil, relaunchEnvironment: [String: String] = [:], appQuitTimeout: TimeInterval = 60, launchTimeout: TimeInterval = 60) {
            self.staged = staged
            self.target = target
            self.stateDirectory = stateDirectory
            self.serviceName = serviceName
            self.socketPath = socketPath
            self.relaunchEnvironment = relaunchEnvironment
            self.appQuitTimeout = appQuitTimeout
            self.launchTimeout = launchTimeout
        }
    }

    package let options: Options

    private var logURL: URL { options.stateDirectory.appendingPathComponent("Updater.log") }

    package func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) updater[\(getpid())]: \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        try? FileManager.default.createDirectory(at: options.stateDirectory, withIntermediateDirectories: true)
        if let handle = FileHandle(forWritingAtPath: logURL.path) ?? {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            return FileHandle(forWritingAtPath: logURL.path)
        }() {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        }
    }

    /// Installs, verifies the result, and puts the old version back if the new
    /// one doesn't start. Returns the record it saved.
    @discardableResult
    package func run() -> UpdateInstallRecord {
        let target = options.target.standardizedFileURL
        let staged = options.staged.standardizedFileURL
        let fromVersion = PlayhouseRelease.infoDictionary(ofBundle: target)?["CFBundleShortVersionString"] as? String ?? ""
        let stagedInfo = PlayhouseRelease.infoDictionary(ofBundle: staged) ?? [:]
        let toVersion = stagedInfo["CFBundleShortVersionString"] as? String ?? ""
        let toBuild = stagedInfo["CFBundleVersion"] as? String ?? ""
        log("installing \(toVersion) (\(toBuild)) over \(fromVersion) at \(target.path)")

        func finish(_ status: String, _ message: String?) -> UpdateInstallRecord {
            let record = UpdateInstallRecord(status: status, fromVersion: fromVersion, toVersion: toVersion, message: message, finishedAt: Date())
            log("\(status)\(message.map { ": \($0)" } ?? "")")
            if let data = try? BridgeFraming.encoder.encode(record) {
                try? data.write(to: PlayhouseRelease.installRecordURL(stateDirectory: options.stateDirectory), options: .atomic)
            }
            return record
        }

        do {
            _ = try ReleaseBundleVerifier.verify(candidate: staged, replacing: target, expectedVersion: nil)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            return finish("failed", error.localizedDescription)
        }

        let appWasRunning = quitRunningApps(of: target)

        let previous = PlayhouseRelease.previousBundle(for: target)
        try? FileManager.default.removeItem(at: previous)
        guard swap(staged, target) else {
            let code = errno
            var message = "Couldn't replace \(target.path): \(String(cString: strerror(code)))."
            if code == EPERM || code == EACCES {
                // macOS's App Management protection, or a folder this user can't write.
                message += " " + PlayhouseRelease.permissionAdvice
            }
            if appWasRunning { launch(target) }
            return finish("failed", message)
        }
        // Stopped only now, so a client that retries while it exits starts the
        // new version's daemon, not the old one again.
        stopDaemon(of: target)
        // The staged path now holds the old version.
        guard rename(staged.path, previous.path) == 0 else {
            let reason = String(cString: strerror(errno))
            if swap(staged, target) {
                try? FileManager.default.removeItem(at: staged)
                if appWasRunning { launch(target) }
                return finish("failed", "Couldn't set the previous version aside (\(reason)), so \(fromVersion) was kept.")
            }
            return finish("failed", "Couldn't set the previous version aside (\(reason)); \(toVersion) is installed and \(fromVersion) is at \(staged.path).")
        }
        log("replaced the bundle; previous version kept at \(previous.path)")

        let relaunch = appWasRunning
        var problem = healthProblem(of: target, expectedVersion: toVersion)
        if problem == nil, relaunch {
            let marker = PlayhouseRelease.launchedMarker(stateDirectory: options.stateDirectory, build: toBuild)
            try? FileManager.default.removeItem(at: marker)
            launch(target)
            if !waitForFile(marker, timeout: options.launchTimeout) {
                problem = "the new version didn't finish starting within \(Int(options.launchTimeout)) seconds"
                _ = quitRunningApps(of: target)
            }
        }

        if let problem {
            log("rolling back: \(problem)")
            stopDaemon(of: target)
            if swap(previous, target) {
                try? FileManager.default.removeItem(at: previous)
                if relaunch { launch(target) }
                return finish("rolledBack", "Playhouse \(toVersion) didn't start (\(problem)), so \(fromVersion) was put back.")
            }
            return finish("failed", "Playhouse \(toVersion) didn't start (\(problem)) and \(fromVersion) couldn't be put back: \(String(cString: strerror(errno))).")
        }
        try? FileManager.default.removeItem(at: previous)
        return finish("installed", nil)
    }

    /// Exchanges two paths atomically; a missing destination is a plain rename.
    private func swap(_ source: URL, _ destination: URL) -> Bool {
        if FileManager.default.fileExists(atPath: destination.path) {
            return POSIX.swapFiles(source.path, destination.path)
        }
        return rename(source.path, destination.path) == 0
    }

    /// Asks the app running from `target` to quit, waits, and kills it if it
    /// doesn't. Returns whether one was running.
    private func quitRunningApps(of target: URL) -> Bool {
        let executableName = PlayhouseRelease.infoDictionary(ofBundle: target)?["CFBundleExecutable"] as? String ?? "Playhouse"
        let executable = target.appendingPathComponent("Contents/MacOS/\(executableName)").path
        let running = Self.processes(runningExecutable: executable)
        guard !running.isEmpty else { return false }
        log("asking the running app to quit (\(running.map(String.init).joined(separator: ", ")))")
        #if os(macOS)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(PlayhouseRelease.quitNotification),
            object: PlayhouseRelease.realPath(target.path),
            userInfo: nil,
            deliverImmediately: true
        )
        #endif
        for processID in running where !BridgeDaemonLauncher.waitForExit(processID, timeout: options.appQuitTimeout) {
            log("the app (\(processID)) didn't quit within \(Int(options.appQuitTimeout)) seconds, so it was stopped")
        }
        return true
    }

    /// Stops the daemon serving `target`'s app without starting one. Agents with
    /// work keep running and the next daemon takes them back.
    private func stopDaemon(of target: URL) {
        let info = PlayhouseRelease.infoDictionary(ofBundle: target) ?? [:]
        let application = info["PlayhouseApplicationBundleIdentifier"] as? String ?? info["CFBundleIdentifier"] as? String ?? ""
        let serviceName = options.serviceName ?? BridgeContract.serviceName(forApplication: application)
        let socketPath = options.socketPath ?? BridgeContract.socketURL(forServiceName: serviceName).path
        guard let connection = try? BridgeSocketConnection.connect(to: socketPath) else { return }
        defer { connection.close() }
        guard let response = try? BridgeDaemonLauncher.request(BridgeRequest(command: "daemon.shutdown"), over: connection),
              let processID = response.result?.object?["processID"]?.int else { return }
        log("stopping the bridge daemon (\(processID))")
        BridgeDaemonLauncher.waitForExit(pid_t(processID), timeout: BridgeDaemonLauncher.daemonExitTimeout)
    }

    /// The installed CLI and daemon must both start and report the version that
    /// was installed.
    private func healthProblem(of target: URL, expectedVersion: String) -> String? {
        let macOS = target.appendingPathComponent("Contents/MacOS")
        let checks: [(executable: String, arguments: [String], name: String)] = [
            ("playhouse-cli", ["version"], "command-line tool"),
            ("playhouse-daemon", ["--version"], "bridge daemon"),
        ]
        for check in checks {
            let process = Process()
            process.executableURL = macOS.appendingPathComponent(check.executable)
            process.arguments = check.arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return "its \(check.name) doesn't start (\(error.localizedDescription))" }
            let deadline = Date().addingTimeInterval(20)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning {
                process.terminate()
                return "its \(check.name) didn't answer"
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let lastLine = String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
            let reported = (try? BridgeFraming.decoder.decode(BridgeResponse.self, from: Data(lastLine.utf8)))?.result
                ?? (try? BridgeFraming.decoder.decode(BridgeValue.self, from: Data(lastLine.utf8)))
            guard process.terminationStatus == 0, reported?.object?["version"]?.string == expectedVersion else {
                return "its \(check.name) failed (exit \(process.terminationStatus))"
            }
        }
        return nil
    }

    private func launch(_ target: URL) {
        log("opening \(target.path) on bridge service \(options.relaunchEnvironment["PLAYHOUSE_BRIDGE_SERVICE_NAME"] ?? "(its default)")")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = options.relaunchEnvironment.sorted(by: { $0.key < $1.key }).flatMap { ["--env", "\($0.key)=\($0.value)"] }
            + [target.path]
        try? process.run()
        process.waitUntilExit()
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    /// The processes whose executable is `path`, compared by real path: the kernel
    /// reports /private/tmp/... where Foundation's symlink resolution gives /tmp/....
    package static func processes(runningExecutable path: String) -> [pid_t] {
        let realPath = PlayhouseRelease.realPath
        let path = realPath(path)
        var matches: [pid_t] = []
        for processID in POSIX.allProcessIDs() where processID > 0 && processID != getpid() {
            guard let executable = POSIX.executablePath(pid: processID) else { continue }
            if realPath(executable) == path { matches.append(processID) }
        }
        return matches
    }
}
