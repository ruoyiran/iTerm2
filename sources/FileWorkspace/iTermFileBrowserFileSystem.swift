// Foundation-only filesystem helpers. Technical error codes are localized by the native caller.
import Foundation
import Darwin

func fileBrowserError(_ code: Int) -> NSError {
    NSError(domain: "iTermFileBrowser", code: code)
}

struct FileBrowserIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: mode_t
    let size: Int64
    var directory: Bool { mode & S_IFMT == S_IFDIR }
    var regular: Bool { mode & S_IFMT == S_IFREG }
    var symlink: Bool { mode & S_IFMT == S_IFLNK }
    static func read(_ path: String) throws -> FileBrowserIdentity {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return FileBrowserIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), mode: info.st_mode, size: info.st_size)
    }
    func sameItem(_ other: FileBrowserIdentity) -> Bool {
        device == other.device && inode == other.inode && mode & S_IFMT == other.mode & S_IFMT
    }
}

struct FileBrowserRoot {
    let display: String
    let canonical: String
    let identity: FileBrowserIdentity
    init(_ path: String) throws {
        guard (path as NSString).isAbsolutePath, !path.contains("\0"),
              URL(fileURLWithPath: path).standardizedFileURL.path == path else { throw fileBrowserError(2) }
        display = path
        canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        identity = try FileBrowserIdentity.read(canonical)
        guard identity.directory else { throw fileBrowserError(2) }
    }
    func relative(_ path: String) throws -> String {
        guard !path.contains("\0"), URL(fileURLWithPath: path).standardizedFileURL.path == path,
              path == display || path.hasPrefix(display == "/" ? "/" : display + "/") else { throw fileBrowserError(2) }
        return path == display ? "" : String(path.dropFirst(display == "/" ? 1 : display.count + 1))
    }
    /// Walk every parent without following a directory link. Leaf links are identities, never targets.
    func checked(_ path: String, directory: Bool = false, writableParent: Bool = false) throws -> String {
        let relative = try relative(path)
        let parts = relative.split(separator: "/").map(String.init)
        var current = canonical
        guard identity.sameItem(try FileBrowserIdentity.read(current)) else { throw fileBrowserError(9) }
        for part in directory ? parts : Array(parts.dropLast()) {
            current = (current as NSString).appendingPathComponent(part)
            let identity = try FileBrowserIdentity.read(current)
            guard identity.directory, !identity.symlink else { throw fileBrowserError(2) }
        }
        if writableParent {
            let parent = directory ? current : ((canonical as NSString).appendingPathComponent(relative) as NSString).deletingLastPathComponent
            let permissions = try FileBrowserIdentity.read(parent).mode
            guard permissions & 0o222 != 0, permissions & 0o111 != 0, access(parent, W_OK | X_OK) == 0 else {
                throw fileBrowserError(4)
            }
        }
        return relative.isEmpty ? canonical : (canonical as NSString).appendingPathComponent(relative)
    }
    /// Stable descriptors prevent directory replacement between path validation and native IO.
    func openDirectory(_ path: String) throws -> Int32 {
        let relative = try relative(path)
        var descriptor = open(canonical, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0, UInt64(info.st_dev) == identity.device,
                  UInt64(info.st_ino) == identity.inode else { throw fileBrowserError(9) }
            for part in relative.split(separator: "/") {
                let next = openat(descriptor, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard next >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                close(descriptor); descriptor = next
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }
    func children(_ path: String) throws -> [(String, FileBrowserIdentity, Bool)] {
        let descriptor = try openDirectory(path)
        guard let stream = fdopendir(descriptor) else { close(descriptor); throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { closedir(stream) }
        var result = [(String, FileBrowserIdentity, Bool)]()
        errno = 0
        while let pointer = readdir(stream) {
            let name = withUnsafePointer(to: &pointer.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingUTF8: $0) }
            }
            guard let name, name != ".", name != ".." else { continue }
            var info = stat()
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { errno = 0; continue }
            result.append((name, FileBrowserIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino),
                                                    mode: info.st_mode, size: info.st_size), info.st_flags & UInt32(UF_HIDDEN) != 0))
            errno = 0
        }
        guard errno == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return result
    }
    func withParent<T>(_ path: String, _ body: (Int32, String) throws -> T) throws -> T {
        guard try !relative(path).isEmpty else { throw fileBrowserError(2) }
        let descriptor = try openDirectory((path as NSString).deletingLastPathComponent)
        defer { close(descriptor) }
        return try body(descriptor, (path as NSString).lastPathComponent)
    }
    func destination(inDirectory directory: String, name: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"),
              name.utf8.count <= 255 else { throw fileBrowserError(2) }
        _ = try checked(directory, directory: true, writableParent: true)
        let path = (directory as NSString).appendingPathComponent(name)
        let target = try checked(path)
        var info = stat()
        if lstat(target, &info) == 0 { throw fileBrowserError(3) }
        guard errno == ENOENT else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return path
    }
}

func fileBrowserReadText(_ path: String, root: FileBrowserRoot, maximumBytes: Int) throws -> String {
    return try root.withParent(path) { parent, name in
    var initial = stat()
    guard fstatat(parent, name, &initial, AT_SYMLINK_NOFOLLOW) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    let identity = FileBrowserIdentity(device: UInt64(initial.st_dev), inode: UInt64(initial.st_ino), mode: initial.st_mode, size: initial.st_size)
    guard identity.regular, identity.mode & 0o444 != 0, identity.size <= maximumBytes else { throw fileBrowserError(5) }
    // O_NONBLOCK prevents an externally swapped FIFO from ever blocking the worker.
    let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
          UInt64(info.st_dev) == identity.device, UInt64(info.st_ino) == identity.inode,
          info.st_size <= maximumBytes else { throw fileBrowserError(5) }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let count = read(descriptor, &buffer, min(buffer.count, maximumBytes + 1 - data.count))
        if count < 0 { if errno == EINTR { continue }; throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        if count == 0 { break }
        data.append(contentsOf: buffer.prefix(count))
        guard data.count <= maximumBytes else { throw fileBrowserError(5) }
    }
    let bytes = [UInt8](data.prefix(3))
    let encoding: String.Encoding
    let skip: Int
    if bytes.starts(with: [0xff, 0xfe]) { encoding = .utf16LittleEndian; skip = 2 }
    else if bytes.starts(with: [0xfe, 0xff]) { encoding = .utf16BigEndian; skip = 2 }
    else { encoding = .utf8; skip = bytes == [0xef, 0xbb, 0xbf] ? 3 : 0 }
    guard let text = String(data: data.dropFirst(skip), encoding: encoding),
          !text.unicodeScalars.contains(where: { $0.value == 0 || ($0.value < 32 && ![9, 10, 13, 12].contains($0.value)) }) else {
        throw fileBrowserError(5)
    }
    return text
    }
}

/// Bounded, cancellable owned child. Pipes are drained without blocking and every exit is reaped.
func fileBrowserGit(_ arguments: [String], root: String, input: Data? = nil,
                    isCancelled: @escaping () -> Bool = { false }, timeout: TimeInterval = 2) throws -> (Int32, Data) {
    guard !isCancelled() else { throw fileBrowserError(1) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
#if FILE_BROWSER_TESTING
    process.executableURL = FileBrowserFaultGate.gitExecutable ?? process.executableURL
#endif
    process.arguments = ["-c", "core.fsmonitor=false", "-C", root] + arguments
    var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    environment["GIT_TERMINAL_PROMPT"] = "0"
    process.environment = environment; process.standardError = FileHandle.nullDevice
    let output = Pipe(); let stdin = Pipe()
    process.standardOutput = output; process.standardInput = stdin
    try process.run()
    defer {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        try? output.fileHandleForReading.close(); try? stdin.fileHandleForWriting.close()
    }
    try? output.fileHandleForWriting.close(); try? stdin.fileHandleForReading.close()
    let readFD = output.fileHandleForReading.fileDescriptor
    let writeFD = stdin.fileHandleForWriting.fileDescriptor
    guard fcntl(readFD, F_SETFL, O_NONBLOCK) != -1, fcntl(writeFD, F_SETFL, O_NONBLOCK) != -1,
          fcntl(writeFD, F_SETNOSIGPIPE, 1) != -1 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
#if FILE_BROWSER_TESTING
    FileBrowserFaultGate.gitStarted?(process)
#endif
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeout) * 1_000_000_000)
    let input = input ?? Data()
    var position = 0; var inputClosed = false; var eof = false; var result = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        guard !isCancelled() else { throw fileBrowserError(1) }
        guard DispatchTime.now().uptimeNanoseconds < deadline else { throw fileBrowserError(11) }
        if !inputClosed {
            if position < input.count {
                let count = input.withUnsafeBytes { bytes in
                    write(writeFD, bytes.baseAddress!.advanced(by: position), min(65536, input.count - position))
                }
                if count > 0 { position += count }
                else if count < 0 && errno != EAGAIN && errno != EINTR { position = input.count }
            }
            if position == input.count { try? stdin.fileHandleForWriting.close(); inputClosed = true }
        }
        while !eof {
            guard !isCancelled() else { throw fileBrowserError(1) }
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw fileBrowserError(11) }
            let count = read(readFD, &buffer, buffer.count)
            if count > 0 {
                result.append(contentsOf: buffer.prefix(count))
                guard result.count <= 32 * 1024 * 1024 else { throw fileBrowserError(8) }
            } else if count == 0 { eof = true }
            else if errno == EINTR { continue }
            else if errno == EAGAIN { break }
            else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
        if !process.isRunning && eof { return (process.terminationStatus, result) }
        var descriptors = [pollfd(fd: eof ? -1 : readFD, events: Int16(POLLIN), revents: 0),
                           pollfd(fd: inputClosed ? -1 : writeFD, events: Int16(POLLOUT), revents: 0)]
        _ = poll(&descriptors, nfds_t(descriptors.count), 20)
    }
}

/// Glob matching uses dynamic programming with a finite work budget, never regex backtracking.
struct FileBrowserGlob {
    enum Token { case literal(Character), one, star, recursive, directory }
    let tokens: [Token]
    init(_ pattern: String) throws {
        guard pattern.utf8.count <= 2048 else { throw fileBrowserError(6) }
        let chars = Array(pattern); var index = 0; var tokens = [Token]()
        while index < chars.count {
            if chars[index] == "*" {
                if index + 1 < chars.count && chars[index + 1] == "*" {
                    index += 1
                    if index + 1 < chars.count && chars[index + 1] == "/" { tokens.append(.directory); index += 1 }
                    else { tokens.append(.recursive) }
                } else { tokens.append(.star) }
            } else if chars[index] == "?" { tokens.append(.one) }
            else { tokens.append(.literal(chars[index])) }
            index += 1
        }
        self.tokens = tokens
    }
    func matches(_ path: String, isCancelled: () -> Bool, remainingWork: inout Int) throws -> Bool {
        guard path.utf8.count <= 32768 else { throw fileBrowserError(6) }
        let chars = Array(path)
        var previous = [Bool](repeating: false, count: chars.count + 1); previous[0] = true
        for token in tokens {
            guard !isCancelled() else { throw fileBrowserError(1) }
            guard remainingWork >= chars.count + 1 else { throw fileBrowserError(6) }
            remainingWork -= chars.count + 1
            var next = [Bool](repeating: false, count: previous.count)
            var reachable = false
            for offset in 0...chars.count {
                if offset & 255 == 0, isCancelled() { throw fileBrowserError(1) }
                switch token {
                case .literal(let char): if offset > 0 { next[offset] = previous[offset - 1] && chars[offset - 1] == char }
                case .one: if offset > 0 { next[offset] = previous[offset - 1] && chars[offset - 1] != "/" }
                case .star: next[offset] = previous[offset] || (offset > 0 && next[offset - 1] && chars[offset - 1] != "/")
                case .recursive: next[offset] = previous[offset] || (offset > 0 && next[offset - 1])
                case .directory:
                    if offset > 0 { reachable = reachable || previous[offset - 1] }
                    next[offset] = previous[offset] || (offset > 0 && chars[offset - 1] == "/" && reachable)
                }
            }
            previous = next
        }
        return previous[chars.count]
    }
}
func fileBrowserGlob(_ pattern: String) throws -> FileBrowserGlob { try FileBrowserGlob(pattern) }

struct FileBrowserTrashReceipt {
    let path: String?
    let error: NSError?
}

/// Keep native NSURL file-reference identity through the Objective-C Foundation boundary.
/// Swift URL bridging resolves these references to paths, reopening a directory-link race.
func fileBrowserTrash(_ path: String, root: FileBrowserRoot, expected: FileBrowserIdentity) throws -> FileBrowserTrashReceipt {
    try root.withParent(path) { parent, name in
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              UInt64(info.st_dev) == expected.device, UInt64(info.st_ino) == expected.inode else { throw fileBrowserError(9) }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(parent, F_GETPATH, &buffer) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let parentPath = String(cString: buffer)
        let original = NSURL(fileURLWithPath: (parentPath as NSString).appendingPathComponent(name))
        guard let reference = original.perform(NSSelectorFromString("fileReferenceURL"))?.takeUnretainedValue() as? NSURL,
              reference.isFileReferenceURL(),
              let fileURL = reference.perform(NSSelectorFromString("filePathURL"))?.takeUnretainedValue() as? NSURL,
              let referencePath = fileURL.path, expected.sameItem(try FileBrowserIdentity.read(referencePath)) else {
            throw fileBrowserError(9)
        }
#if FILE_BROWSER_TESTING
        FileBrowserFaultGate.trashInput?(reference)
#endif
        let manager = FileManager.default
        let selector = NSSelectorFromString("trashItemAtURL:resultingItemURL:error:")
        typealias Trash = @convention(c) (AnyObject, Selector, NSURL, AutoreleasingUnsafeMutablePointer<NSURL?>?,
                                         AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool
        let trash = unsafeBitCast(manager.method(for: selector), to: Trash.self)
        var resulting: NSURL?; var error: NSError?
        guard trash(manager, selector, reference, &resulting, &error) else { throw error ?? fileBrowserError(10) }
        // From this point deletion committed. No throwing receipt/identity lookup can erase its mapping.
        var receiptPath = resulting?.path
#if FILE_BROWSER_TESTING
        if FileBrowserFaultGate.receiptPathUnavailable { receiptPath = nil }
#endif
        var receiptError: NSError? = receiptPath == nil ? fileBrowserError(10) : nil
#if FILE_BROWSER_TESTING
        do { try FileBrowserFaultGate.trashReceipt?(resulting) } catch { receiptError = error as NSError }
#endif
        return FileBrowserTrashReceipt(path: receiptPath, error: receiptError)
    }
}

#if FILE_BROWSER_TESTING
// Fault gates are compiled only into the standalone real-filesystem regression runner.
enum FileBrowserFaultGate {
    static var committed: ((String, String?, String?) throws -> Void)?
    static var trashInput: ((NSURL) -> Void)?
    static var trashReceipt: ((NSURL?) throws -> Void)?
    static var receiptPathUnavailable = false
    static var gitExecutable: URL?
    static var gitStarted: ((Process) -> Void)?
}
#endif
