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

/// No shell, standard Git ignore machinery (tracked files remain visible). Input/output are NUL-delimited.
func fileBrowserGit(_ arguments: [String], root: String, input: Data? = nil) throws -> (Int32, Data) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-c", "core.fsmonitor=false", "-C", root] + arguments
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    process.environment = environment
    process.standardError = FileHandle.nullDevice
    let output = Pipe(); process.standardOutput = output
    let stdin = Pipe()
    process.standardInput = input == nil ? FileHandle.nullDevice : stdin
    try process.run()
    if let input {
        DispatchQueue.global(qos: .utility).async {
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
        }
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, data)
}

func fileBrowserGlob(_ pattern: String) throws -> NSRegularExpression {
    guard pattern.utf8.count <= 2048 else { throw fileBrowserError(6) }
    var result = "^"; let chars = Array(pattern); var index = 0
    while index < chars.count {
        let char = chars[index]
        if char == "*" {
            if index + 1 < chars.count && chars[index + 1] == "*" {
                index += 1
                if index + 1 < chars.count && chars[index + 1] == "/" { result += "(?:.*/)?"; index += 1 }
                else { result += ".*" }
            } else { result += "[^/]*" }
        } else if char == "?" { result += "[^/]" }
        else { result += NSRegularExpression.escapedPattern(for: String(char)) }
        index += 1
    }
    return try NSRegularExpression(pattern: result + "$")
}

/// Isolate the captured item in a private, unpredictable directory before invoking path-based macOS Trash.
/// An unrelated parent replacement then yields a missing staging path instead of an outside target.
func fileBrowserTrash(_ path: String, root: FileBrowserRoot, expected: FileBrowserIdentity) throws -> String {
    try root.withParent(path) { parent, name in
        let staging = ".file-browser-trash-" + UUID().uuidString
        guard mkdirat(parent, staging, 0o700) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { unlinkat(parent, staging, AT_REMOVEDIR) } // Only the empty service-owned directory.
        let stagingFD = openat(parent, staging, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard stagingFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(stagingFD) }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              UInt64(info.st_dev) == expected.device, UInt64(info.st_ino) == expected.inode else { throw fileBrowserError(9) }
        guard renameatx_np(parent, name, stagingFD, name, UInt32(RENAME_EXCL)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        do {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(stagingFD, F_GETPATH, &buffer) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            let stagingPath = String(cString: buffer)
            let stagedURL = URL(fileURLWithPath: stagingPath).appendingPathComponent(name)
            let actual = try FileBrowserIdentity.read(stagedURL.path)
            guard expected.sameItem(actual) else { throw fileBrowserError(9) }
            var resulting: NSURL?
            try FileManager.default.trashItem(at: stagedURL, resultingItemURL: &resulting)
            guard let restoredPath = resulting?.path else { throw fileBrowserError(10) }
            return restoredPath
        } catch {
            // Restore the exact isolated item on a normal native Trash error, never overwrite a new file.
            if renameatx_np(stagingFD, name, parent, name, UInt32(RENAME_EXCL)) != 0 {
                var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                if fcntl(stagingFD, F_GETPATH, &buffer) == 0 {
                    let retainedPath = (String(cString: buffer) as NSString).appendingPathComponent(name)
                    throw NSError(domain: "iTermFileBrowser", code: 10,
                                  userInfo: ["retainedPath": retainedPath, NSUnderlyingErrorKey: error])
                }
            }
            throw error
        }
    }
}
