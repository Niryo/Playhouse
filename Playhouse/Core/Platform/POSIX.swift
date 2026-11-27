#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// The process, signal, socket and file calls Playhouse makes below Foundation, in one place for
/// both C libraries: Darwin on macOS and Glibc on Linux. Code outside this file doesn't import
/// either or qualify a call with `Darwin.`; it calls `POSIX`. The calls whose answer only one
/// kernel gives (libproc's process table, `LOCAL_PEERPID`) are written here once per platform.
package enum POSIX {
    /// The calling thread's last C library error.
    package static var errorNumber: Int32 { errno }

    package static func posixError(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    // MARK: C library calls, named as in C

#if canImport(Darwin)
    @discardableResult package static func close(_ descriptor: Int32) -> Int32 { Darwin.close(descriptor) }
    @discardableResult package static func chmod(_ path: String, _ mode: mode_t) -> Int32 { Darwin.chmod(path, mode) }
    @discardableResult package static func fcntl(_ descriptor: Int32, _ command: Int32) -> Int32 { Darwin.fcntl(descriptor, command) }
    @discardableResult package static func fcntl(_ descriptor: Int32, _ command: Int32, _ value: Int32) -> Int32 { Darwin.fcntl(descriptor, command, value) }
    @discardableResult package static func fcntl(_ descriptor: Int32, _ command: Int32, _ pointer: UnsafeMutableRawPointer) -> Int32 { Darwin.fcntl(descriptor, command, pointer) }
    @discardableResult package static func open(_ path: String, _ flags: Int32) -> Int32 { Darwin.open(path, flags) }
    @discardableResult package static func open(_ path: String, _ flags: Int32, _ mode: mode_t) -> Int32 { Darwin.open(path, flags, mode) }
    @discardableResult package static func read(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int { Darwin.read(descriptor, buffer, count) }
    @discardableResult package static func write(_ descriptor: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int { Darwin.write(descriptor, buffer, count) }
    @discardableResult package static func kill(_ pid: pid_t, _ signal: Int32) -> Int32 { Darwin.kill(pid, signal) }
    @discardableResult package static func shutdown(_ descriptor: Int32, _ how: Int32) -> Int32 { Darwin.shutdown(descriptor, how) }
    @discardableResult package static func setsockopt(_ descriptor: Int32, _ level: Int32, _ option: Int32, _ value: UnsafeRawPointer?, _ length: socklen_t) -> Int32 { Darwin.setsockopt(descriptor, level, option, value, length) }
    @discardableResult package static func connect(_ descriptor: Int32, _ address: UnsafePointer<sockaddr>?, _ length: socklen_t) -> Int32 { Darwin.connect(descriptor, address, length) }
    @discardableResult package static func bind(_ descriptor: Int32, _ address: UnsafePointer<sockaddr>?, _ length: socklen_t) -> Int32 { Darwin.bind(descriptor, address, length) }
    @discardableResult package static func listen(_ descriptor: Int32, _ backlog: Int32) -> Int32 { Darwin.listen(descriptor, backlog) }
    @discardableResult package static func accept(_ descriptor: Int32, _ address: UnsafeMutablePointer<sockaddr>?, _ length: UnsafeMutablePointer<socklen_t>?) -> Int32 { Darwin.accept(descriptor, address, length) }
#else
    @discardableResult package static func close(_ descriptor: Int32) -> Int32 { Glibc.close(descriptor) }
    @discardableResult package static func chmod(_ path: String, _ mode: mode_t) -> Int32 { Glibc.chmod(path, mode) }
    @discardableResult package static func fcntl(_ descriptor: Int32, _ command: Int32) -> Int32 { Glibc.fcntl(descriptor, command) }
    @discardableResult package static func fcntl(_ descriptor: Int32, _ command: Int32, _ value: Int32) -> Int32 { Glibc.fcntl(descriptor, command, value) }
    @discardableResult package static func fcntl(_ descriptor: Int32, _ command: Int32, _ pointer: UnsafeMutableRawPointer) -> Int32 { Glibc.fcntl(descriptor, command, pointer) }
    @discardableResult package static func open(_ path: String, _ flags: Int32) -> Int32 { Glibc.open(path, flags) }
    @discardableResult package static func open(_ path: String, _ flags: Int32, _ mode: mode_t) -> Int32 { Glibc.open(path, flags, mode) }
    @discardableResult package static func read(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int { Glibc.read(descriptor, buffer, count) }
    @discardableResult package static func write(_ descriptor: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int { Glibc.write(descriptor, buffer, count) }
    @discardableResult package static func kill(_ pid: pid_t, _ signal: Int32) -> Int32 { Glibc.kill(pid, signal) }
    @discardableResult package static func shutdown(_ descriptor: Int32, _ how: Int32) -> Int32 { Glibc.shutdown(descriptor, how) }
    @discardableResult package static func setsockopt(_ descriptor: Int32, _ level: Int32, _ option: Int32, _ value: UnsafeRawPointer?, _ length: socklen_t) -> Int32 { Glibc.setsockopt(descriptor, level, option, value, length) }
    @discardableResult package static func connect(_ descriptor: Int32, _ address: UnsafePointer<sockaddr>?, _ length: socklen_t) -> Int32 { Glibc.connect(descriptor, address, length) }
    @discardableResult package static func bind(_ descriptor: Int32, _ address: UnsafePointer<sockaddr>?, _ length: socklen_t) -> Int32 { Glibc.bind(descriptor, address, length) }
    @discardableResult package static func listen(_ descriptor: Int32, _ backlog: Int32) -> Int32 { Glibc.listen(descriptor, backlog) }
    @discardableResult package static func accept(_ descriptor: Int32, _ address: UnsafeMutablePointer<sockaddr>?, _ length: UnsafeMutablePointer<socklen_t>?) -> Int32 { Glibc.accept(descriptor, address, length) }
#endif

    // MARK: Files

    package static func isSymbolicLink(_ path: String) -> Bool {
        var metadata = stat()
        return lstat(path, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFLNK
    }

    package static func isRegularFile(_ path: String) -> Bool {
        var metadata = stat()
        return lstat(path, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFREG
    }

    /// Runs `body` while holding an exclusive `fcntl` lock on the file at `path`, waiting for it.
    /// The kernel releases the lock if the process dies, so a leftover file never blocks anyone.
    package static func withExclusiveFileLock<T>(at path: String, _ body: () throws -> T) throws -> T {
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw posixError() }
        defer { _ = close(descriptor) }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard fcntl(descriptor, F_SETLKW, &lock) == 0 else { throw posixError() }
        return try body()
    }

    /// Exchanges two paths atomically. False when this platform can't, or either is missing.
    package static func swapFiles(_ source: String, _ destination: String) -> Bool {
        #if canImport(Darwin)
        let renameSwap: UInt32 = 0x0000_0002 // RENAME_SWAP
        return renamex_np(source, destination, renameSwap) == 0
        #else
        // renameat2's RENAME_EXCHANGE, which Glibc declares only with _GNU_SOURCE.
        return false
        #endif
    }

    /// Whether the file at `path` carries the extended attribute `name`.
    package static func hasExtendedAttribute(_ path: String, _ name: String) -> Bool {
        #if canImport(Darwin)
        return getxattr(path, name, nil, 0, 0, 0) >= 0
        #else
        // Linux has no quarantine attribute, the only one Playhouse asks about.
        return false
        #endif
    }

    /// Stops writes to a closed pipe from raising SIGPIPE on this descriptor, so they fail
    /// with EPIPE instead. Linux has no per-descriptor switch; there the process ignores SIGPIPE.
    package static func disableSIGPIPE(onFile descriptor: Int32) {
        #if canImport(Darwin)
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        #endif
    }

    // MARK: Sockets

    /// A new Unix-domain stream socket.
    package static func unixStreamSocket() -> Int32 {
        #if canImport(Darwin)
        return socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        return socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
    }

    /// The same as `disableSIGPIPE(onFile:)`, for a socket.
    package static func disableSIGPIPE(onSocket descriptor: Int32) {
        #if canImport(Darwin)
        var on: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    /// The process at the other end of a connected Unix-domain socket.
    package static func peerProcessID(ofSocket descriptor: Int32) -> pid_t? {
        #if canImport(Darwin)
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else { return nil }
        return pid
        #else
        // SO_PEERCRED (17) fills a `struct ucred { pid_t pid; uid_t uid; gid_t gid; }`, both of
        // which Glibc declares only with _GNU_SOURCE.
        var credentials: (pid: pid_t, uid: uid_t, gid: gid_t) = (0, 0, 0)
        var size = socklen_t(MemoryLayout<(pid_t, uid_t, gid_t)>.size)
        guard getsockopt(descriptor, SOL_SOCKET, 17, &credentials, &size) == 0, credentials.pid > 0 else { return nil }
        return credentials.pid
        #endif
    }

    // MARK: Processes

    /// `posix_spawn`'s attribute and file-action objects: opaque pointers in Darwin, structs in Glibc.
    #if canImport(Darwin)
    package typealias SpawnAttributes = posix_spawnattr_t?
    package typealias SpawnFileActions = posix_spawn_file_actions_t?
    #else
    package typealias SpawnAttributes = posix_spawnattr_t
    package typealias SpawnFileActions = posix_spawn_file_actions_t
    #endif

    /// Storage for `posix_spawnattr_init` and `posix_spawn_file_actions_init` to fill.
    package static func spawnAttributes() -> SpawnAttributes {
        #if canImport(Darwin)
        nil
        #else
        posix_spawnattr_t()
        #endif
    }

    package static func spawnFileActions() -> SpawnFileActions {
        #if canImport(Darwin)
        nil
        #else
        posix_spawn_file_actions_t()
        #endif
    }

    /// `posix_spawn` flags for a child in its own session that inherits no descriptors beyond
    /// those its file actions set up.
    package static var detachedSpawnFlags: Int16 {
        #if canImport(Darwin)
        Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)
        #else
        // Glibc has no CLOEXEC_DEFAULT; Playhouse opens its descriptors close-on-exec.
        // POSIX_SPAWN_SETSID (0x80), which Glibc declares only with _GNU_SOURCE.
        Int16(0x80)
        #endif
    }

    /// This process's executable.
    package static func currentExecutablePath() -> String? {
        #if canImport(Darwin)
        var size = UInt32(MAXPATHLEN)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return String(cString: buffer)
        #else
        return try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")
        #endif
    }

    /// Every process ID the kernel lists.
    package static func allProcessIDs() -> [pid_t] {
        #if canImport(Darwin)
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let actual = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return Array(pids.prefix(Int(max(0, actual))))
        #else
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? []
        return entries.compactMap { pid_t($0) }
        #endif
    }

    /// Direct child process IDs of `pid`.
    package static func childProcessIDs(of pid: pid_t) -> [pid_t] {
        #if canImport(Darwin)
        let count = proc_listchildpids(pid, nil, 0)
        guard count > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: Int(count))
        let bufferSize = Int32(count) * Int32(MemoryLayout<pid_t>.size)
        let actual = proc_listchildpids(pid, &buffer, bufferSize)
        guard actual > 0 else { return [] }
        return Array(buffer.prefix(Int(actual)))
        #else
        return allProcessIDs().filter { processSummary(pid: $0)?.parentPID == pid }
        #endif
    }

    /// What the kernel says about one live process.
    package struct ProcessSummary {
        package var parentPID: pid_t
        package var userID: uid_t
        /// When it started, as seconds and microseconds; with the pid it names one process
        /// even after the pid is reused.
        package var startSeconds: UInt64
        package var startMicroseconds: UInt64
        /// The short name (`p_name`), or the command when the name is empty.
        package var name: String
    }

    package static func processSummary(pid: pid_t) -> ProcessSummary? {
        #if canImport(Darwin)
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let name = withUnsafeBytes(of: info.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let command = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return ProcessSummary(
            parentPID: pid_t(bitPattern: info.pbi_ppid), userID: info.pbi_uid,
            startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec,
            name: name.isEmpty ? command : name
        )
        #else
        // /proc/<pid>/stat: "pid (comm) state ppid ... starttime(22nd field, clock ticks)".
        guard let line = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let nameStart = line.firstIndex(of: "("), let nameEnd = line.lastIndex(of: ")") else { return nil }
        let name = String(line[line.index(after: nameStart)..<nameEnd])
        let fields = line[line.index(after: nameEnd)...].split(separator: " ")
        guard fields.count > 19, let parent = pid_t(fields[1]), let ticks = UInt64(fields[19]) else { return nil }
        var metadata = stat()
        let userID: uid_t = lstat("/proc/\(pid)", &metadata) == 0 ? metadata.st_uid : uid_t.max
        let hertz = UInt64(max(1, sysconf(Int32(_SC_CLK_TCK))))
        return ProcessSummary(
            parentPID: parent, userID: userID, startSeconds: ticks / hertz,
            startMicroseconds: (ticks % hertz) * 1_000_000 / hertz, name: name
        )
        #endif
    }

    /// When the process started, in microseconds since 1970, or nil when there is none. With the
    /// pid it identifies one process across a reused pid; the value is stored, so it must stay
    /// the same for a process from one call (and one daemon) to the next.
    package static func processStartMicroseconds(pid: pid_t) -> Int64? {
        #if canImport(Darwin)
        guard let info = kinfo(pid: pid) else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec)
        #else
        guard let summary = processSummary(pid: pid) else { return nil }
        return Int64(summary.startSeconds) * 1_000_000 + Int64(summary.startMicroseconds)
        #endif
    }

    /// Whether `pid` has exited but not been reaped by its parent.
    package static func isZombie(pid: pid_t) -> Bool {
        #if canImport(Darwin)
        guard let info = kinfo(pid: pid) else { return false }
        return info.kp_proc.p_stat == SZOMB
        #else
        guard let line = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let nameEnd = line.lastIndex(of: ")") else { return false }
        return line[line.index(after: nameEnd)...].split(separator: " ").first == "Z"
        #endif
    }

    #if canImport(Darwin)
    private static func kinfo(pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    /// `proc_pid_rusage`'s `ri_user_time`/`ri_system_time` are raw Mach absolute
    /// time ticks, not pre-converted nanoseconds — on this machine (M2 Pro) the
    /// tick:nanosecond ratio is 125:3 (~41.7x), confirmed empirically against
    /// `ps`'s own %CPU/TIME accounting for a known 100%-busy process. Scaling by
    /// this ratio is required on every machine, since the ratio isn't 1:1 even
    /// on current Apple Silicon.
    private static let machTimebaseRatio: (numerator: UInt64, denominator: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()
    #endif

    /// Cumulative user+system CPU time `pid` has used since it started, in nanoseconds, or nil
    /// when it has exited or belongs to another user.
    package static func cumulativeCPUTimeNanoseconds(pid: pid_t) -> UInt64? {
        #if canImport(Darwin)
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rusagePointer in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rusagePointer)
            }
        }
        guard result == 0 else { return nil }
        let rawTicks = usage.ri_user_time + usage.ri_system_time
        return rawTicks * machTimebaseRatio.numerator / machTimebaseRatio.denominator
        #else
        // utime and stime, the 14th and 15th fields of /proc/<pid>/stat, in clock ticks.
        guard let line = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let nameEnd = line.lastIndex(of: ")") else { return nil }
        let fields = line[line.index(after: nameEnd)...].split(separator: " ")
        guard fields.count > 12, let user = UInt64(fields[11]), let system = UInt64(fields[12]) else { return nil }
        let hertz = UInt64(max(1, sysconf(Int32(_SC_CLK_TCK))))
        return (user + system) * 1_000_000_000 / hertz
        #endif
    }

    /// The process's current working directory, as the kernel reports it.
    package static func workingDirectory(pid: pid_t) -> String? {
        #if canImport(Darwin)
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
        #else
        return try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/cwd")
        #endif
    }

    /// The file a process has open as `descriptor`, or nil when it isn't a file.
    package static func openFilePath(pid: pid_t, descriptor: Int32) -> String? {
        #if canImport(Darwin)
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        guard proc_pidfdinfo(pid, descriptor, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvip.vip_path) { raw in
            let bytes = raw.bindMemory(to: CChar.self)
            guard let base = bytes.baseAddress, base.pointee != 0 else { return nil }
            return String(cString: base)
        }
        #else
        guard let path = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/fd/\(descriptor)"),
              path.hasPrefix("/") else { return nil }
        return path
        #endif
    }

    /// The executable a process runs.
    package static func executablePath(pid: pid_t) -> String? {
        #if canImport(Darwin)
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
        #else
        return try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/exe")
        #endif
    }

    /// A file's last modification time, in seconds since 1970.
    package static func modificationTime(_ info: stat) -> Double {
        #if canImport(Darwin)
        Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        #else
        Double(info.st_mtim.tv_sec) + Double(info.st_mtim.tv_nsec) / 1_000_000_000
        #endif
    }

    // MARK: Foundation differences

    /// Runs `body` in an autorelease pool where Foundation has them (Apple platforms).
    package static func withAutoreleasePool<T>(_ body: () throws -> T) rethrows -> T {
        #if canImport(Darwin)
        try autoreleasepool(invoking: body)
        #else
        try body()
        #endif
    }

    /// `path` with the home folder written as `~`.
    package static func abbreviatingHome(_ path: String) -> String {
        #if canImport(Darwin)
        (path as NSString).abbreviatingWithTildeInPath
        #else
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
        #endif
    }

    /// Whether a number from `JSONSerialization` or a property list is a Boolean.
    package static func isBoolean(_ number: NSNumber) -> Bool {
        #if canImport(Darwin)
        CFGetTypeID(number) == CFBooleanGetTypeID()
        #else
        String(cString: number.objCType) == "c" && (number.int8Value == 0 || number.int8Value == 1)
            && type(of: number) == type(of: NSNumber(value: true))
        #endif
    }

    /// Whether a number holds a floating-point value rather than an integer.
    package static func isFloatingPoint(_ number: NSNumber) -> Bool {
        #if canImport(Darwin)
        CFNumberIsFloatType(number)
        #else
        ["f", "d"].contains(String(cString: number.objCType))
        #endif
    }
}

/// Calls a handler once when a process exits. On macOS a dispatch process source reports the
/// exit; a platform without one reports only a process already gone when watching starts (a
/// Linux port watches a pidfd here).
package final class ProcessExitWatch: @unchecked Sendable {
    #if canImport(Darwin)
    private let source: DispatchSourceProcess
    #endif

    package init(pid: pid_t, queue: DispatchQueue, handler: @escaping @Sendable () -> Void) {
        #if canImport(Darwin)
        source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler(handler: handler)
        source.resume()
        #endif
    }

    package func cancel() {
        #if canImport(Darwin)
        source.cancel()
        #endif
    }
}

/// Calls a handler when a file open as `descriptor` grows or is written. On a platform without
/// a dispatch file-system source it never fires, so callers back it with a slow poll.
package final class FileWriteWatch: @unchecked Sendable {
    #if canImport(Darwin)
    private let source: DispatchSourceFileSystemObject
    #endif

    package init(descriptor: Int32, queue: DispatchQueue, handler: @escaping @Sendable () -> Void) {
        #if canImport(Darwin)
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.extend, .write], queue: queue)
        source.setEventHandler(handler: handler)
        source.resume()
        #endif
    }

    package func cancel() {
        #if canImport(Darwin)
        source.cancel()
        #endif
    }
}
