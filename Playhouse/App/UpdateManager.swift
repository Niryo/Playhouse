import Darwin
import Foundation

/// What the app shows about updates. `phase` is one of development, misplaced
/// (the app runs from somewhere it can't replace itself), upToDate, available,
/// downloading, ready, waiting (to install once no agent is running a turn and no
/// message is being written), installing or failed.
struct UpdateStatus: Codable, Equatable {
    var channel: String
    var currentVersion: String
    var currentBuild: String
    var phase: String
    var lastCheckedAt: Date?
    var available: ReleaseInfo?
    /// 0...1 while downloading.
    var progress: Double?
    /// While waiting: how many agents are still running a turn.
    var activeTurns: Int?
    /// While waiting: how many tasks and chats hold a message that wasn't sent.
    var unsentDrafts: Int?
    var error: String?
    var lastInstall: UpdateInstallRecord?
}

/// Who asked for an update check, which decides how it behaves.
enum UpdateCheckKind: String {
    /// Check Now, Check for Updates… or a plain `update check`: always reaches the
    /// feed and shows a failure.
    case manual
    /// The window's hourly check: reaches the feed at most once a day and fails quietly.
    case automatic
    /// The window's check when it opens: always reaches the feed and fails quietly.
    case launch
}

/// Checks for, downloads and installs Playhouse releases. Lives in the daemon,
/// so a window and the CLI share one download and one state; the installer
/// itself runs as its own process (see `ReleaseInstaller`). Development builds
/// never update: they report the development phase and refuse every action.
@MainActor
final class UpdateManager {
    private struct State: Codable {
        var lastCheckedAt: Date?
        var available: ReleaseInfo?
        var stagedVersion: String?
        var error: String?
        var installingSince: Date?
        /// The release being installed, kept for the notice's notes: the new
        /// version's launch check clears `available` before the installer
        /// writes its record.
        var installing: ReleaseInfo?
        /// Install as soon as no agent is running a turn and no message is being written.
        var installWhenIdle: Bool?
        /// How the app that asked to wait reopens; a later request starting the install may differ.
        var waitingRelaunchEnvironment: [String: String]?
    }

    /// A scheduled check reaches the network at most this often.
    static let automaticCheckInterval: TimeInterval = 24 * 60 * 60
    /// How often a waiting install looks for running agents.
    static let idleCheckInterval: Duration = .seconds(1)
    /// Downloads in progress, by state directory, so `status` can report them.
    private static var downloadProgress: [String: Double] = [:]
    /// Downloads that can still be canceled, by state directory.
    private static var downloadTasks: [String: Task<Void, Error>] = [:]
    /// State directories with a waiting install this daemon is watching.
    private static var idleWatches: Set<String> = []

    private let feedURL: URL
    /// GitHub's latest-release listing, read when the feed link fails; a test's
    /// own listing when it sets one, and none for a test feed without one.
    private let releaseAPIURL: URL?
    private let publicKey: String
    private let channel: String
    private let target: URL
    private let targetIsThisApp: Bool
    private let stateDirectory: URL
    private let runtimeScope: String?
    /// What the new version is opened with, so it runs like the app that asked.
    private let relaunchEnvironment: [String: String]
    /// Tasks and chats whose composer holds a message that wasn't sent; restarting
    /// would interrupt someone writing it, so an automatic install waits for them.
    private let unsentDrafts: @MainActor () -> Int

    init(request: BridgeRequest, storeDirectory: String?, runtimeScope: String?, unsentDrafts: @escaping @MainActor () -> Int) {
        // Tests point a test build at a local feed, key and install location.
        let overrides = BridgeContract.isTestBundle(PlayhouseAppIdentity.applicationIdentifier)
            ? request.arguments.compactMapValues(\.string)
            : [:]
        let ownBundle = Bundle.main.bundleURL.standardizedFileURL
        target = overrides["__updateTargetApp"].map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL } ?? ownBundle
        targetIsThisApp = target.resolvingSymlinksInPath().path == ownBundle.resolvingSymlinksInPath().path
        let targetInfo = PlayhouseRelease.infoDictionary(ofBundle: target) ?? Bundle.main.infoDictionary ?? [:]
        channel = PlayhouseRelease.channel(of: targetInfo)
        feedURL = overrides["__updateFeedURL"].flatMap(URL.init(string:)) ?? PlayhouseRelease.feedURL
        releaseAPIURL = overrides["__updateReleaseAPIURL"].flatMap(URL.init(string:))
            ?? (overrides["__updateFeedURL"] == nil ? PlayhouseRelease.latestReleaseAPIURL : nil)
        publicKey = overrides["__updatePublicKey"] ?? ReleaseSigningKey.publicKey
        relaunchEnvironment = Self.relaunchEnvironment(for: request, target: targetInfo)
        let root = storeDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        stateDirectory = root.appendingPathComponent("Updates", isDirectory: true)
        self.runtimeScope = runtimeScope
        self.unsentDrafts = unsentDrafts
    }

    private var isDevelopment: Bool { channel != PlayhouseRelease.stableChannel }
    private var stateURL: URL { stateDirectory.appendingPathComponent("state.json") }
    private var targetInfo: [String: Any] { PlayhouseRelease.infoDictionary(ofBundle: target) ?? [:] }
    private var currentVersion: String { targetInfo["CFBundleShortVersionString"] as? String ?? "" }

    /// A copy macOS runs from a translocated or read-only folder can't be
    /// replaced, so it doesn't update until it is moved to Applications.
    private var isMisplaced: Bool {
        let folder = target.deletingLastPathComponent().path
        return target.path.contains("/AppTranslocation/") || access(folder, W_OK) != 0
    }

    private var activeTurnCount: Int {
        ConversationRuntimeSnapshot.current(dataDirectory: runtimeScope).activeThreadIDs.count
    }

    func status() -> UpdateStatus {
        let state = loadState()
        var status = UpdateStatus(
            channel: channel,
            currentVersion: currentVersion,
            currentBuild: targetInfo["CFBundleVersion"] as? String ?? "",
            phase: "upToDate",
            lastCheckedAt: state.lastCheckedAt,
            available: state.available,
            error: state.error,
            lastInstall: loadInstallRecord()
        )
        let progress = Self.downloadProgress[stateDirectory.path]
        if isDevelopment {
            status.phase = "development"
            status.available = nil
        } else if isMisplaced, state.installingSince == nil {
            status.phase = "misplaced"
            status.available = nil
            status.error = PlayhouseRelease.moveToApplicationsMessage
        } else if let since = state.installingSince, Date().timeIntervalSince(since) < 10 * 60 {
            status.phase = "installing"
        } else if let progress {
            status.phase = "downloading"
            status.progress = progress
        } else if state.error != nil {
            status.phase = "failed"
        } else if let available = state.available, isStaged(available) {
            status.phase = state.installWhenIdle == true ? "waiting" : "ready"
            if state.installWhenIdle == true {
                status.activeTurns = activeTurnCount
                status.unsentDrafts = unsentDrafts()
            }
        } else if state.available != nil {
            status.phase = "available"
        }
        return status
    }

    /// Asks the release feed for the latest release and remembers it if it is
    /// newer than the installed version and runs on this Mac. See `UpdateCheckKind` for when
    /// each kind reaches the network and whether it records a failure.
    func check(_ kind: UpdateCheckKind) async throws -> UpdateStatus {
        try requireReleaseBuild()
        var state = loadState()
        if kind == .automatic, let last = state.lastCheckedAt, Date().timeIntervalSince(last) < Self.automaticCheckInterval {
            return status()
        }
        do {
            let release = try ReleaseManifestVerifier.verify(try await fetchManifest(), publicKey: publicKey)
            state.lastCheckedAt = Date()
            guard let offered = PlayhouseVersion(release.version),
                  let installed = PlayhouseVersion(currentVersion), offered > installed,
                  release.runsOnThisMac else {
                state.available = nil
                state.stagedVersion = nil
                state.error = nil
                try saveState(state)
                return status()
            }
            if state.available?.version != release.version {
                state.stagedVersion = nil
                state.installWhenIdle = nil
            }
            state.available = release
            state.error = nil
            try saveState(state)
            return status()
        } catch {
            state.lastCheckedAt = Date()
            // A scheduled check fails quietly; the next one tries again.
            if kind == .manual { state.error = error.localizedDescription }
            try? saveState(state)
            throw error
        }
    }

    /// Downloads the offered release, checks it against its signed manifest and
    /// Playhouse's signing certificate, and unpacks it beside the installed app.
    func download(onProgress: @escaping (Double) -> Void) async throws -> UpdateStatus {
        try requireReleaseBuild()
        var state = loadState()
        guard let release = state.available else {
            throw BridgeCommandError(code: "no_update", message: "No update is available. Check for updates first.")
        }
        if isStaged(release) { return status() }
        let key = stateDirectory.path
        guard Self.downloadProgress[key] == nil else {
            throw BridgeCommandError(code: "update_busy", message: "Playhouse \(release.version) is already downloading.")
        }
        Self.downloadProgress[key] = 0
        defer { Self.downloadProgress[key] = nil }
        state.error = nil
        state.stagedVersion = nil
        state.installWhenIdle = nil
        try saveState(state)

        let work = stateDirectory.appendingPathComponent("download", isDirectory: true)
        do {
            try? FileManager.default.removeItem(at: work)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            guard let assetURL = URL(string: release.asset.url) else {
                throw ReleaseVerificationError.rejected("The release's download address isn't valid.")
            }
            let archive = work.appendingPathComponent("release.zip")
            let fetch = Task {
                try await ReleaseDownload.fetch(assetURL, to: archive) { fraction in
                    guard Self.downloadProgress[key] != nil else { return }
                    Self.downloadProgress[key] = fraction
                    onProgress(fraction)
                }
            }
            Self.downloadTasks[key] = fetch
            do {
                try await fetch.value
                Self.downloadTasks[key] = nil
            } catch {
                Self.downloadTasks[key] = nil
                guard fetch.isCancelled else { throw error }
                throw BridgeCommandError(code: "update_cancelled", message: "The download of Playhouse \(release.version) was canceled.")
            }
            let target = target
            let staged = PlayhouseRelease.stagedBundle(for: target)
            try await Task.detached {
                try Self.unpackAndVerify(archive: archive, release: release, work: work, target: target, staged: staged)
            }.value
            state.stagedVersion = release.version
            try saveState(state)
            // The result reports the staged release, not the finished download.
            Self.downloadProgress[key] = nil
            return status()
        } catch {
            Self.downloadProgress[key] = nil
            // A canceled download leaves the release offered, not failed.
            state.error = (error as? BridgeCommandError)?.code == "update_cancelled" ? nil : error.localizedDescription
            try? saveState(state)
            throw error
        }
    }

    /// Stops the download in progress; the release stays offered.
    func cancelDownload() throws -> UpdateStatus {
        try requireReleaseBuild()
        let key = stateDirectory.path
        guard let download = Self.downloadTasks[key] else {
            throw BridgeCommandError(code: "no_download", message: "No update is downloading.")
        }
        download.cancel()
        Self.downloadTasks[key] = nil
        Self.downloadProgress[key] = nil
        return status()
    }

    /// Starts the installer for a downloaded release. With `whenIdle`, while any
    /// agent is running a turn or a message is being written it waits instead: the
    /// daemon starts the install itself once none is, and the status reports the wait. The installer
    /// quits the app, stops this daemon, swaps the bundle and opens the new version.
    func install(whenIdle: Bool) throws -> [String: BridgeValue] {
        try requireReleaseBuild()
        var state = loadState()
        // An installer that is still running hasn't written its record yet.
        if let since = state.installingSince, Date().timeIntervalSince(since) < 10 * 60, loadInstallRecord() == nil {
            throw BridgeCommandError(code: "update_busy", message: "Playhouse is already installing an update.")
        }
        guard let release = state.available, isStaged(release) else {
            throw BridgeCommandError(code: "no_update", message: "No downloaded update is ready to install.")
        }
        let activeTurns = activeTurnCount
        let drafts = unsentDrafts()
        if whenIdle, activeTurns > 0 || drafts > 0 {
            state.installWhenIdle = true
            state.waitingRelaunchEnvironment = relaunchEnvironment
            try saveState(state)
            resumeWaitingInstall()
            return [
                "started": .boolean(false),
                "activeTurns": .integer(activeTurns),
                "unsentDrafts": .integer(drafts),
                "status": try BridgeValue.encoding(status()),
            ]
        }
        let reopenEnvironment = state.installWhenIdle == true ? state.waitingRelaunchEnvironment ?? relaunchEnvironment : relaunchEnvironment
        state.installWhenIdle = nil
        state.waitingRelaunchEnvironment = nil
        let staged = PlayhouseRelease.stagedBundle(for: target)
        // The staged copy sat beside the app since the download; check it again.
        do {
            _ = try ReleaseBundleVerifier.verify(candidate: staged, replacing: target, expectedVersion: release.version)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            state.stagedVersion = nil
            state.error = error.localizedDescription
            try? saveState(state)
            throw error
        }
        var arguments = [
            "update", "apply",
            "--staged", staged.path,
            "--target", target.path,
            "--state-dir", stateDirectory.path,
        ]
        if targetIsThisApp {
            // The daemon to stop before the swap is this one.
            arguments += ["--service-name", AgentRunService.name]
            if let socketPath = ProcessInfo.processInfo.environment["PLAYHOUSE_BRIDGE_SOCKET_PATH"] {
                arguments += ["--socket-path", socketPath]
            }
        }
        for (name, value) in reopenEnvironment.sorted(by: { $0.key < $1.key }) {
            arguments += ["--relaunch-env", "\(name)=\(value)"]
        }
        let installer = staged.appendingPathComponent("Contents/MacOS/playhouse-cli")
        try? FileManager.default.removeItem(at: PlayhouseRelease.installRecordURL(stateDirectory: stateDirectory))
        let processID = try Self.spawnDetached(installer.path, arguments: arguments)
        Self.reapInstaller(processID, stateDirectory: stateDirectory, fromVersion: currentVersion, toVersion: release.version)
        state.installingSince = Date()
        state.installing = release
        try saveState(state)
        return ["started": .boolean(true), "installerPID": .integer(Int(processID)), "status": try BridgeValue.encoding(status())]
    }

    /// Watches a waiting install while this daemon runs and starts it once no
    /// agent is running a turn and no message is being written. Every update request calls this, so a daemon
    /// started after the wait began picks it up.
    func resumeWaitingInstall() {
        let key = stateDirectory.path
        guard !Self.idleWatches.contains(key), loadState().installWhenIdle == true else { return }
        Self.idleWatches.insert(key)
        BridgeBackgroundWork.start { [self] in
            defer { Self.idleWatches.remove(key) }
            while true {
                try? await Task.sleep(for: Self.idleCheckInterval)
                guard loadState().installWhenIdle == true else { return }
                guard activeTurnCount == 0, unsentDrafts() == 0 else { continue }
                PlayhouseDiagnostics.record("update.install_when_idle", fields: ["state": key])
                do {
                    _ = try install(whenIdle: false)
                } catch {
                    PlayhouseDiagnostics.record("update.install_when_idle_failed", fields: PlayhouseDiagnostics.errorFields(error))
                    var state = loadState()
                    state.installWhenIdle = nil
                    state.error = state.error ?? error.localizedDescription
                    try? saveState(state)
                }
                return
            }
        }
    }

    /// The new version opens in the same data folder and bridge service as the
    /// app that asked for the update; a test build also keeps its test settings.
    /// A normal install sets none of these, so it opens like any app.
    private static func relaunchEnvironment(for request: BridgeRequest, target info: [String: Any]) -> [String: String] {
        var environment: [String: String] = [:]
        if let dataDirectory = request.dataDirectory { environment["PLAYHOUSE_DATA_DIRECTORY"] = dataDirectory }
        let application = info["PlayhouseApplicationBundleIdentifier"] as? String ?? info["CFBundleIdentifier"] as? String ?? ""
        if AgentRunService.name != BridgeContract.serviceName(forApplication: application) {
            environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"] = AgentRunService.name
        }
        if let socketPath = ProcessInfo.processInfo.environment["PLAYHOUSE_BRIDGE_SOCKET_PATH"] {
            environment["PLAYHOUSE_BRIDGE_SOCKET_PATH"] = socketPath
        }
        if BridgeContract.isTestBundle(PlayhouseAppIdentity.applicationIdentifier) {
            if let suite = request.defaultsSuite { environment["PLAYHOUSE_E2E_DEFAULTS_SUITE"] = suite }
            for (name, value) in request.environment ?? [:] where name.hasPrefix("PLAYHOUSE_E2E_") { environment[name] = value }
        }
        return environment
    }

    /// The app reports that it started. The installer waits for this before it
    /// keeps a new version. The answer carries the last install while its notice
    /// is shown (for a day, until it is opened), so the app can say what changed.
    func markLaunched() throws -> UpdateStatus {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        FileManager.default.createFile(atPath: PlayhouseRelease.launchedMarker(stateDirectory: stateDirectory, build: build).path, contents: nil)
        var state = loadState()
        var result = status()
        // The installer writes its record only after this launch, and the
        // launch check that follows clears the offer; keep the release for its
        // notes now. An install started by a version without `installing`
        // still has the offer at this point.
        if state.installingSince != nil, state.installing == nil, state.available?.version == currentVersion {
            state.installing = state.available
            try saveState(state)
        }
        if var record = result.lastInstall {
            if state.installingSince != nil {
                // The installer doesn't know the notes; keep the release's for the notice.
                if record.notes == nil, let release = state.installing ?? state.available, release.version == record.toVersion {
                    record.notes = release.notes
                    saveInstallRecord(record)
                }
                state.installingSince = nil
                state.installing = nil
                state.installWhenIdle = nil
                if record.status == "installed" {
                    state.available = nil
                    state.stagedVersion = nil
                }
                try saveState(state)
                result = status()
            }
            result.lastInstall = record.isNoticeShown ? record : nil
        }
        return result
    }

    /// The app opened or dismissed the last install's notice; it isn't shown again.
    func dismissNotice() throws -> UpdateStatus {
        if var record = loadInstallRecord(), !record.acknowledged {
            record.acknowledged = true
            saveInstallRecord(record)
        }
        return status()
    }

    private func requireReleaseBuild() throws {
        guard !isDevelopment else {
            throw BridgeCommandError(code: "development_build", message: "This is a development build of Playhouse; it updates from source, not from releases.")
        }
        guard !isMisplaced else {
            throw BridgeCommandError(code: "update_location", message: "Playhouse runs from \(target.deletingLastPathComponent().path), which it can't replace. \(PlayhouseRelease.moveToApplicationsMessage)")
        }
    }

    private func isStaged(_ release: ReleaseInfo) -> Bool {
        loadState().stagedVersion == release.version
            && PlayhouseRelease.infoDictionary(ofBundle: PlayhouseRelease.stagedBundle(for: target))?["CFBundleShortVersionString"] as? String == release.version
    }

    private func fetchManifest() async throws -> Data {
        do {
            return try await ReleaseDownload.data(from: feedURL)
        } catch {
            // The release's asset list names the same file when the download link fails.
            if let releaseAPIURL, let manifest = try? await Self.manifestThroughReleaseList(releaseAPIURL) {
                return manifest
            }
            throw error
        }
    }

    private static func manifestThroughReleaseList(_ listingURL: URL) async throws -> Data {
        struct Release: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: String }
            let assets: [Asset]
        }
        let listing = try await ReleaseDownload.data(from: listingURL)
        guard let asset = try JSONDecoder().decode(Release.self, from: listing).assets
            .first(where: { $0.name == PlayhouseRelease.manifestAssetName }),
              let url = URL(string: asset.browser_download_url) else {
            throw BridgeCommandError(code: "update_unreachable", message: "The latest release has no \(PlayhouseRelease.manifestAssetName).")
        }
        return try await ReleaseDownload.data(from: url)
    }

    nonisolated private static func unpackAndVerify(archive: URL, release: ReleaseInfo, work: URL, target: URL, staged: URL) throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int) ?? -1
        guard size == release.asset.size else {
            throw ReleaseVerificationError.rejected("The download is \(size) bytes, not the \(release.asset.size) its release lists.")
        }
        guard try ReleaseManifestVerifier.sha256(ofFile: archive) == release.asset.sha256.lowercased() else {
            throw ReleaseVerificationError.rejected("The download's checksum doesn't match its signed release.")
        }
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, unpacked.path]
        ditto.standardOutput = FileHandle.nullDevice
        ditto.standardError = FileHandle.nullDevice
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw ReleaseVerificationError.rejected("The download isn't a readable archive.") }
        guard let app = try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw ReleaseVerificationError.rejected("The download has no Playhouse app in it.")
        }
        _ = try ReleaseBundleVerifier.verify(candidate: app, replacing: target, expectedVersion: release.version)
        try? FileManager.default.removeItem(at: staged)
        do {
            try FileManager.default.moveItem(at: app, to: staged)
        } catch {
            throw BridgeCommandError(code: "update_failed", message: "Playhouse can't write beside \(target.path): \(error.localizedDescription)")
        }
    }

    /// Waits for the installer while this daemon lives (it usually stops the
    /// daemon first). An installer that exits without recording a result, such
    /// as a release whose command-line tool can't run, gets a failed record, so
    /// the app reports it instead of waiting.
    private static func reapInstaller(_ processID: pid_t, stateDirectory: URL, fromVersion: String, toVersion: String) {
        Thread.detachNewThread {
            var status: Int32 = 0
            guard waitpid(processID, &status, 0) == processID else { return }
            let recordURL = PlayhouseRelease.installRecordURL(stateDirectory: stateDirectory)
            guard !FileManager.default.fileExists(atPath: recordURL.path) else { return }
            let exited = status & 0x7f == 0
            let reason = exited ? "exit \((status >> 8) & 0xff)" : "signal \(status & 0x7f)"
            let record = UpdateInstallRecord(
                status: "failed",
                fromVersion: fromVersion,
                toVersion: toVersion,
                message: "The installer in Playhouse \(toVersion) didn't run (\(reason)); \(fromVersion) is unchanged.",
                finishedAt: Date()
            )
            if let data = try? BridgeFraming.encoder.encode(record) {
                try? data.write(to: recordURL, options: .atomic)
            }
        }
    }

    /// Starts `executable` in its own session with no inherited descriptors, so
    /// it outlives this daemon, which it stops.
    private static func spawnDetached(_ executable: String, arguments: [String]) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor in Int32(0)...2 {
            posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", descriptor == 0 ? O_RDONLY : O_WRONLY, 0)
        }
        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer { envp.forEach { free($0) } }
        var processID: pid_t = 0
        let result = posix_spawn(&processID, executable, &actions, &attributes, argv, envp)
        guard result == 0 else {
            throw BridgeCommandError(code: "update_failed", message: "Couldn't start the installer: \(String(cString: strerror(result))).")
        }
        return processID
    }

    private func loadState() -> State {
        guard let data = try? Data(contentsOf: stateURL) else { return State() }
        return (try? BridgeFraming.decoder.decode(State.self, from: data)) ?? State()
    }

    private func saveState(_ state: State) throws {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try BridgeFraming.encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    private func saveInstallRecord(_ record: UpdateInstallRecord) {
        if let data = try? BridgeFraming.encoder.encode(record) {
            try? data.write(to: PlayhouseRelease.installRecordURL(stateDirectory: stateDirectory), options: .atomic)
        }
    }

    private func loadInstallRecord() -> UpdateInstallRecord? {
        guard let data = try? Data(contentsOf: PlayhouseRelease.installRecordURL(stateDirectory: stateDirectory)) else { return nil }
        return try? BridgeFraming.decoder.decode(UpdateInstallRecord.self, from: data)
    }
}

/// Fetches release files from GitHub or, in tests, from a feed served on 127.0.0.1.
enum ReleaseDownload {
    static func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Playhouse", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BridgeCommandError(code: "update_unreachable", message: "The release feed answered \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        return data
    }

    static func fetch(_ url: URL, to destination: URL, onProgress: @escaping @MainActor (Double) -> Void) async throws {
        // A delegate-driven task: the async `download(from:)` doesn't report progress
        // to the session's delegate.
        let delegate = DownloadDelegate(destination: destination, onProgress: onProgress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        await onProgress(1)
    }

    /// Reports how far a download got and moves the finished file into place.
    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let destination: URL
        let onProgress: @MainActor (Double) -> Void
        var continuation: CheckedContinuation<Void, Error>?
        private var failure: Error?
        private var lastReported = -1.0

        init(destination: URL, onProgress: @escaping @MainActor (Double) -> Void) {
            self.destination = destination
            self.onProgress = onProgress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            // The finished download reports 1 once the file is in place.
            let fraction = min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0.99)
            guard fraction - lastReported >= 0.02 else { return }
            lastReported = fraction
            let onProgress = onProgress
            Task { @MainActor in onProgress(fraction) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // The file at `location` is removed once this returns.
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                failure = BridgeCommandError(code: "update_unreachable", message: "The release download answered \(status).")
                return
            }
            do {
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                failure = error
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error = error ?? failure {
                continuation?.resume(throwing: error)
            } else {
                continuation?.resume()
            }
            continuation = nil
        }
    }
}
