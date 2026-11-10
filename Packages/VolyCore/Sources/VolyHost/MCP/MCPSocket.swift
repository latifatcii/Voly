import Darwin
import Foundation

/// Where a running Voly listens for AI agent requests.
///
/// A Unix-domain socket in the user's own Library, mode 0600: nothing is
/// reachable over the network, and other users on the Mac can't connect.
public enum MCPEndpoint {
    public static var socketPath: String {
        VolyInjectionCoordinator.defaultSupportDirectory.appendingPathComponent("mcp.sock").path
    }
}

public enum MCPSocketError: Error, Equatable, LocalizedError {
    case pathTooLong(String)
    case system(operation: String, code: Int32)
    /// Another process is already listening there.
    case inUse(String)
    case closed
    case messageTooLarge

    public var errorDescription: String? {
        switch self {
        case .pathTooLong(let path): return "Socket path is too long: \(path)"
        case .system(let operation, let code): return "\(operation) failed: \(String(cString: strerror(code)))"
        case .inUse(let path): return "Another Voly is already listening on \(path)."
        case .closed: return "The connection was closed."
        case .messageTooLarge: return "The message is too large."
        }
    }
}

enum UnixSocket {
    static func open() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MCPSocketError.system(operation: "socket", code: errno) }
        // A peer that went away must be an error on write, not a signal.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw MCPSocketError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func connect(to path: String) throws -> Int32 {
        let fd = try open()
        let result = try withAddress(path) { Darwin.connect(fd, $0, $1) }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw MCPSocketError.system(operation: "connect", code: code)
        }
        return fd
    }

    static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw MCPSocketError.system(operation: "write", code: errno)
                }
                offset += written
            }
        }
    }
}

/// Reads newline-terminated messages off a file descriptor.
final class LineReader {
    private let fd: Int32
    private let limit: Int
    private var buffer = Data()
    /// Bytes at the front of `buffer` already known to hold no newline, so
    /// a multi-megabyte line (a screenshot) is searched once, not once per
    /// chunk read.
    private var searched = 0

    init(fd: Int32, limit: Int) {
        self.fd = fd
        self.limit = limit
    }

    /// The next line without its newline; nil at end of stream.
    func next() throws -> Data? {
        var chunk = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            if let newline = nextNewline() {
                let line = buffer.subdata(in: 0..<newline)
                buffer.removeSubrange(0...newline)
                searched = 0
                return line
            }
            guard buffer.count <= limit else { throw MCPSocketError.messageTooLarge }
            let count = read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw MCPSocketError.system(operation: "read", code: errno)
            }
            if count == 0 {
                // End of stream; a last line without a newline still counts.
                guard !buffer.isEmpty else { return nil }
                defer {
                    buffer.removeAll()
                    searched = 0
                }
                return buffer
            }
            chunk.withUnsafeBufferPointer { buffer.append($0.baseAddress!, count: count) }
        }
    }

    private func nextNewline() -> Int? {
        let found: Int? = buffer.withUnsafeBytes { bytes in
            guard bytes.count > searched, let base = bytes.baseAddress,
                  let hit = memchr(base + searched, 0x0A, bytes.count - searched)
            else { return nil }
            return base.distance(to: UnsafeRawPointer(hit))
        }
        if found == nil { searched = buffer.count }
        return found
    }
}

/// Accepts connections on a Unix-domain socket and answers each line of
/// JSON with the line the handler returns for it.
public final class MCPSocketListener: @unchecked Sendable {
    public typealias Handler = @Sendable (Data) async -> Data?

    private static let maxRequestSize = 8 << 20

    public let path: String
    private let handler: Handler
    private let lock = NSLock()
    private var source: DispatchSourceRead?
    private var connections: Set<Int32> = []
    private let queue = DispatchQueue(label: "com.latifatci.Voly.mcp.accept")

    public init(path: String = MCPEndpoint.socketPath, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return source != nil
    }

    public func start() throws {
        guard !isRunning else { return }
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        // A socket file can outlive a crashed Voly; only a live listener
        // makes the path taken.
        if let probe = try? UnixSocket.connect(to: path) {
            close(probe)
            throw MCPSocketError.inUse(path)
        }
        unlink(path)

        let fd = try UnixSocket.open()
        let bound = try UnixSocket.withAddress(path) { bind(fd, $0, $1) }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw MCPSocketError.system(operation: "bind", code: code)
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw MCPSocketError.system(operation: "listen", code: code)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending(on: fd) }
        source.setCancelHandler { close(fd) }
        lock.lock()
        self.source = source
        lock.unlock()
        source.resume()
    }

    public func stop() {
        lock.lock()
        let source = self.source
        self.source = nil
        let open = connections
        lock.unlock()
        guard let source else { return }
        source.cancel()
        unlink(path)
        // Wakes the threads blocked reading from their clients.
        for fd in open { shutdown(fd, SHUT_RDWR) }
    }

    private func acceptPending(on listener: Int32) {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            // The socket file's mode already keeps other users out; this
            // holds even if someone loosens it.
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
                close(fd)
                continue
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            lock.lock()
            connections.insert(fd)
            lock.unlock()
            Thread.detachNewThread { [weak self] in
                self?.serve(fd)
                self?.lock.lock()
                self?.connections.remove(fd)
                self?.lock.unlock()
                close(fd)
            }
        }
    }

    /// One client: requests are answered strictly in the order they arrive.
    private func serve(_ fd: Int32) {
        let reader = LineReader(fd: fd, limit: Self.maxRequestSize)
        while let line = try? reader.next() {
            guard line.contains(where: { !Self.whitespace.contains($0) }) else { continue }
            let handler = self.handler
            let reply = ReplyBox()
            let done = DispatchSemaphore(value: 0)
            Task {
                reply.value = await handler(line)
                done.signal()
            }
            done.wait()
            guard var data = reply.value else { continue }
            data.append(0x0A)
            do { try UnixSocket.write(data, to: fd) } catch { return }
        }
    }

    static let whitespace: Set<UInt8> = [0x20, 0x09, 0x0D, 0x0A]

    private final class ReplyBox: @unchecked Sendable {
        var value: Data?
    }
}

/// The other end: one request, one reply, one short-lived connection.
public enum MCPSocketClient {
    private static let maxReplySize = 96 << 20

    public static func isListening(at path: String) -> Bool {
        guard let fd = try? UnixSocket.connect(to: path) else { return false }
        close(fd)
        return true
    }

    public static func roundTrip(_ line: Data, path: String, timeout: TimeInterval = 180) throws -> Data {
        let fd = try UnixSocket.connect(to: path)
        defer { close(fd) }
        var limit = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        var message = line
        message.append(0x0A)
        try UnixSocket.write(message, to: fd)
        guard let reply = try LineReader(fd: fd, limit: maxReplySize).next() else { throw MCPSocketError.closed }
        return reply
    }
}
