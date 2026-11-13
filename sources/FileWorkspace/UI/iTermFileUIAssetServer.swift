import Foundation
import Network
import CryptoKit
import Darwin

// Localization unneeded: HTTP/protocol fields and bundled resource identifiers.
final class iTermFileUIAssetServer {
    private struct Asset {
        let url: URL
        let bytes: Int
        let mime: String
        let device: dev_t
        let inode: ino_t
    }
    private final class Client {
        let connection: NWConnection
        var header = Data()
        var timer: DispatchWorkItem?
        var descriptor: Int32 = -1
        var remaining = 0
        var position: Int64 = 0
        var mediaOwner: String?
        init(_ connection: NWConnection) { self.connection = connection }
        deinit { if descriptor >= 0 { Darwin.close(descriptor) } }
    }
    private final class Media {
        let descriptor: Int32
        let size: Int
        let mime: String
        let owner: String
        init(descriptor: Int32, size: Int, mime: String, owner: String) {
            self.descriptor = descriptor; self.size = size; self.mime = mime; self.owner = owner
        }
        deinit { Darwin.close(descriptor) }
    }
    private let queue = DispatchQueue(label: "com.iterm2.file-ui.assets", qos: .utility)
    private let assets: [String: Asset]
    private let token = UUID().uuidString
    private var listener: NWListener?
    private var clients = [UUID: Client]()
    private var port: UInt16 = 0
    private var stopped = false
    private var media = [String: Media]()

    init(resourceDirectory: URL) throws {
        let root = resourceDirectory.resolvingSymlinksInPath().standardizedFileURL
        let manifestURL = root.appendingPathComponent("manifest.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: manifestURL.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 1024 * 1024 else { throw fileUIError(1) }
        let data = try Data(contentsOf: manifestURL)
        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              manifest["version"] as? Int == 1,
              let files = manifest["files"] as? [[String: Any]], files.count <= 2048 else { throw fileUIError(1) }
        var entries = [String: Asset](), total = 0
        for entry in files {
            guard let path = entry["path"] as? String, Self.safePath(path), entries[path] == nil,
                  let bytes = entry["bytes"] as? Int, bytes >= 0, bytes <= 32 * 1024 * 1024,
                  let digest = entry["sha256"] as? String,
                  let mime = entry["mime"] as? String, !mime.contains("\r"), !mime.contains("\n") else { throw fileUIError(1) }
            let url = root.appendingPathComponent(path)
            guard url.resolvingSymlinksInPath().path == url.path, url.path.hasPrefix(root.path + "/") else { throw fileUIError(1) }
            let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw fileUIError(1) }
            defer { Darwin.close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size == bytes else { throw fileUIError(1) }
            var hash = SHA256(), buffer = [UInt8](repeating: 0, count: 65536), count = 0
            while true {
                let n = Darwin.read(fd, &buffer, buffer.count)
                guard n >= 0 else { throw fileUIError(1) }
                if n == 0 { break }
                count += n; guard count <= bytes else { throw fileUIError(1) }
                hash.update(data: Data(buffer.prefix(n)))
            }
            guard count == bytes, hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest else { throw fileUIError(1) }
            total += bytes; guard total <= 128 * 1024 * 1024 else { throw fileUIError(1) }
            entries[path] = Asset(url: url, bytes: bytes, mime: mime, device: info.st_dev, inode: info.st_ino)
        }
        assets = entries
    }
    func start(completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self = self, !self.stopped, self.listener == nil else {
                DispatchQueue.main.async { completion(.failure(fileUIError(2))) }; return
            }
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                let listener = try NWListener(using: parameters, on: .any)
                self.listener = listener
                var completed = false
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self = self else { return }
                    switch state {
                    case .ready:
                        guard !completed, let port = listener?.port?.rawValue else { return }
                        completed = true; self.port = port
                        let url = URL(string: "http://127.0.0.1:\(port)/\(self.token)/index.html")!
                        DispatchQueue.main.async { completion(.success(url)) }
                    case .failed(let error):
                        guard !completed else { return }; completed = true
                        DispatchQueue.main.async { completion(.failure(error)) }
                    case .cancelled:
                        guard !completed else { return }; completed = true
                        DispatchQueue.main.async { completion(.failure(fileUIError(2))) }
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: self.queue)
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }
    func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.stopped = true; self.listener?.cancel(); self.listener = nil
            for id in Array(self.clients.keys) { self.finish(id) }
            self.media.removeAll()
        }
    }
    func registerMedia(path: String, owner: String, completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self, !self.stopped, self.port != 0 else {
                DispatchQueue.main.async { completion(.failure(fileUIError(2))) }; return
            }
            do {
                let url = URL(fileURLWithPath: path).standardizedFileURL
                let content = try FileContentService(rootDirectory: url.deletingLastPathComponent().path)
                let item = try content.withFile(url.path) { descriptor, info -> Media in
                    let duplicate = dup(descriptor)
                    guard duplicate >= 0 else { throw fileUIError(7) }
                    _ = fcntl(duplicate, F_SETFD, FD_CLOEXEC)
                    return Media(descriptor: duplicate, size: Int(info.st_size), mime: FileContentService.mimeType(path), owner: owner)
                }
                self.revokeMediaOnQueue(owner: owner)
                let key = "media/" + UUID().uuidString
                self.media[key] = item
                let endpoint = URL(string: "http://127.0.0.1:\(self.port)/\(self.token)/\(key)")!
                DispatchQueue.main.async { completion(.success(endpoint)) }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }
    func revokeMedia(owner: String) { queue.async { [weak self] in self?.revokeMediaOnQueue(owner: owner) } }
    private func revokeMediaOnQueue(owner: String) {
        for key in media.keys.filter({ media[$0]?.owner == owner }) { media.removeValue(forKey: key) }
        for id in clients.keys.filter({ clients[$0]?.mediaOwner == owner }) { finish(id) }
    }
    deinit { listener?.cancel(); clients.values.forEach { $0.timer?.cancel(); $0.connection.cancel() } }
    private static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0") &&
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private func accept(_ connection: NWConnection) {
        guard !stopped, clients.count < 16 else { connection.cancel(); return }
        let id = UUID(), client = Client(connection); clients[id] = client
        connection.start(queue: queue)
        deadline(id, seconds: 5); receive(id)
    }
    private func deadline(_ id: UUID, seconds: Double) {
        guard let client = clients[id] else { return }
        client.timer?.cancel()
        let timer = DispatchWorkItem { [weak self] in self?.finish(id) }; client.timer = timer
        queue.asyncAfter(deadline: .now() + seconds, execute: timer)
    }
    private func receive(_ id: UUID) {
        guard let client = clients[id] else { return }
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 8193 - client.header.count) { [weak self] data, _, complete, error in
            guard let self = self, let client = self.clients[id] else { return }
            if let data = data { client.header.append(data) }
            guard client.header.count <= 8192 else { self.respond(id, code: 431); return }
            if let end = client.header.range(of: Data("\r\n\r\n".utf8)) {
                guard end.upperBound == client.header.count else { self.respond(id, code: 400); return }
                self.handle(id); return
            }
            if complete || error != nil { self.finish(id) } else { self.receive(id) }
        }
    }
    private func handle(_ id: UUID) {
        guard let client = clients[id], let text = String(data: client.header, encoding: .utf8) else { respond(id, code: 400); return }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[2] == "HTTP/1.1", first[1].hasPrefix("/"), first[1].utf8.count <= 2048 else { respond(id, code: 400); return }
        let method = String(first[0]); guard method == "GET" || method == "HEAD" else { respond(id, code: 405); return }
        var headers = [String: String]()
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { respond(id, code: 400); return }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil, !key.contains(" "), !key.contains("\t") else { respond(id, code: 400); return }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["host"] == "127.0.0.1:\(port)" else { respond(id, code: 403); return }
        guard headers["transfer-encoding"] == nil, headers["upgrade"] == nil,
              headers["content-length"] == nil || headers["content-length"] == "0" else { respond(id, code: 400); return }
        let raw = String(first[1].split(separator: "?", maxSplits: 1)[0])
        guard !raw.lowercased().contains("%2f"), !raw.lowercased().contains("%5c"),
              let path = raw.removingPercentEncoding, path.hasPrefix("/\(token)/") else { respond(id, code: 404); return }
        let key = String(path.dropFirst(token.count + 2))
        if let item = media[key] { serveMedia(id, item: item, method: method, range: headers["range"]); return }
        guard headers["range"] == nil else { respond(id, code: 400); return }
        guard Self.safePath(key), let asset = assets[key] else { respond(id, code: 404); return }
        let fd = Darwin.open(asset.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        var info = stat()
        guard fd >= 0, fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size == asset.bytes,
              info.st_dev == asset.device, info.st_ino == asset.inode else { if fd >= 0 { Darwin.close(fd) }; respond(id, code: 404); return }
        client.descriptor = fd; client.remaining = method == "HEAD" ? 0 : asset.bytes
        deadline(id, seconds: 15)
        respond(id, code: 200, length: asset.bytes, mime: asset.mime, body: method != "HEAD")
    }
    private func serveMedia(_ id: UUID, item: Media, method: String, range: String?) {
        guard let client = clients[id] else { return }
        let start: Int, end: Int
        if let range {
            let parts = range.hasPrefix("bytes=") ? String(range.dropFirst(6)).split(separator: "-", omittingEmptySubsequences: false) : []
            guard parts.count == 2, !range.contains(","), item.size > 0 else { respond(id, code: 416, extra: "Content-Range: bytes */\(item.size)\r\n"); return }
            if parts[0].isEmpty {
                guard let suffix = Int(parts[1]), suffix > 0 else { respond(id, code: 416); return }
                start = max(0, item.size - suffix); end = item.size - 1
            } else {
                guard let first = Int(parts[0]), first >= 0, first < item.size,
                      parts[1].isEmpty || Int(parts[1]) != nil else { respond(id, code: 416, extra: "Content-Range: bytes */\(item.size)\r\n"); return }
                start = first; end = min(item.size - 1, Int(parts[1]) ?? item.size - 1)
                guard end >= start else { respond(id, code: 416); return }
            }
        } else { start = 0; end = item.size - 1 }
        let descriptor = dup(item.descriptor)
        guard descriptor >= 0 else { respond(id, code: 404); return }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        client.descriptor = descriptor; client.position = Int64(start); client.mediaOwner = item.owner
        let length = max(0, end - start + 1)
        client.remaining = method == "HEAD" ? 0 : length
        let extra = "Accept-Ranges: bytes\r\n" + (range == nil ? "" : "Content-Range: bytes \(start)-\(end)/\(item.size)\r\n")
        deadline(id, seconds: 60)
        respond(id, code: range == nil ? 200 : 206, length: length, mime: item.mime, body: method != "HEAD", extra: extra)
    }
    private func respond(_ id: UUID, code: Int, length: Int = 0, mime: String = "text/plain", body: Bool = false, extra: String = "") {
        guard let client = clients[id] else { return }
        let csp = "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; worker-src 'self' blob:; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; media-src 'self' blob:; font-src 'self'; connect-src 'self'; object-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'"
        let header = "HTTP/1.1 \(code) Response\r\nContent-Length: \(length)\r\nContent-Type: \(mime)\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: \(csp)\r\nCache-Control: no-store\r\n" + extra + "\r\n"
        client.connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil, body else { self?.finish(id); return }; self?.sendBody(id)
        })
    }
    private func sendBody(_ id: UUID) {
        guard let client = clients[id] else { return }
        guard client.remaining > 0 else { finish(id); return }
        var buffer = [UInt8](repeating: 0, count: min(65536, client.remaining))
        let count = Darwin.pread(client.descriptor, &buffer, buffer.count, client.position)
        guard count > 0 else { finish(id); return }
        client.remaining -= count
        client.position += Int64(count)
        client.connection.send(content: Data(buffer.prefix(count)), completion: .contentProcessed { [weak self] error in
            if error != nil { self?.finish(id) } else { self?.sendBody(id) }
        })
    }
    private func finish(_ id: UUID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.timer?.cancel(); client.connection.cancel()
    }
}
