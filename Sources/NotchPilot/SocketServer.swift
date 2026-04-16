import Foundation
import Darwin

/// A minimal line-delimited JSON Unix-socket server.
///
/// Each incoming connection is expected to write one JSON object terminated
/// by a newline. The server invokes `onRequest` on a background queue; the
/// handler either replies with a `Response` (written back + newline) or with
/// `nil` (connection is simply closed). The hook script uses the reply for
/// blocking events like `PermissionRequest` and ignores it for fire-and-
/// forget events like `PreToolUse`.
///
/// `@unchecked Sendable`: `onRequest` is set once at startup and thereafter
/// only read from the accept/handler queues, and `OutgoingBuffer` guards its
/// mutable state with an `NSLock`. The compiler can't statically prove
/// that, so we take the escape hatch.
final class SocketServer: @unchecked Sendable {

    struct Request {
        let payload: [String: Any]
    }

    struct Response {
        let payload: [String: Any]
    }

    typealias Handler = @Sendable (Request, @escaping @Sendable (Response?) -> Void) -> Void

    var onRequest: Handler?
    /// Called on the main actor when the hook process disconnects before
    /// the server has sent a reply — meaning the user answered in the
    /// terminal and Claude Code killed the hook. The payload is the
    /// original request so HookBridge can match and clean up.
    var onClientDisconnect: (@Sendable ([String: Any]) -> Void)?

    private var serverFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "notchpilot.socket.accept")
    private let handlerQueue = DispatchQueue(
        label: "notchpilot.socket.handler",
        attributes: .concurrent
    )

    enum SocketError: Error, CustomStringConvertible {
        case systemCall(String, Int32)

        var description: String {
            switch self {
            case let .systemCall(name, err):
                return "\(name) failed: \(String(cString: strerror(err)))"
            }
        }
    }

    func start(at path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )

        // Scrub any leftover socket file from a previous run.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketError.systemCall("socket", errno)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        path.withCString { cPath in
            let len = min(strlen(cPath), 103)
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                _ = memcpy(raw.baseAddress, cPath, len)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { addrPtr -> Int32 in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            close(fd)
            throw SocketError.systemCall("bind", err)
        }

        // Lock to owner only — this socket is a private channel.
        chmod(path, 0o600)

        guard listen(fd, 16) == 0 else {
            let err = errno
            close(fd)
            throw SocketError.systemCall("listen", err)
        }

        serverFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in
            self?.acceptLoop()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        acceptSource = source
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        serverFD = -1
    }

    private func acceptLoop() {
        var clientAddr = sockaddr_un()
        var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { addrPtr -> Int32 in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.accept(serverFD, sockPtr, &clientLen)
            }
        }
        guard clientFD >= 0 else { return }

        handlerQueue.async { [weak self] in
            self?.handleClient(fd: clientFD)
        }
    }

    private func handleClient(fd: Int32) {
        defer { close(fd) }

        guard let lineData = readLineData(fd: fd),
              !lineData.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
        else {
            return
        }

        let request = Request(payload: json)

        let sema = DispatchSemaphore(value: 0)
        let outgoing = OutgoingBuffer()

        onRequest?(request) { response in
            if let response = response,
               var data = try? JSONSerialization.data(withJSONObject: response.payload) {
                data.append(0x0A)
                outgoing.set(data)
            }
            sema.signal()
        }

        // Poll in a loop: wait up to 500ms on the semaphore, then check
        // if the hook process is still alive by polling the client FD.
        // If the user answered in the terminal, Claude Code kills the
        // hook → the FD gets a HUP → we clean up the pending permission.
        let deadline = DispatchTime.now() + 120
        var answered = false
        while DispatchTime.now() < deadline {
            if sema.wait(timeout: .now() + .milliseconds(500)) == .success {
                answered = true
                break
            }
            // Check if the hook process disconnected
            var pfd = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            let pollResult = poll(&pfd, 1, 0)
            if pollResult > 0 {
                let revents = Int32(pfd.revents)
                if (revents & Int32(POLLHUP)) != 0 || (revents & Int32(POLLERR)) != 0 {
                    // Hook died — user answered in terminal
                    onClientDisconnect?(request.payload)
                    return
                }
                // POLLIN with 0 bytes = EOF = disconnected
                if (revents & Int32(POLLIN)) != 0 {
                    var peek: UInt8 = 0
                    let n = recv(fd, &peek, 1, MSG_PEEK | MSG_DONTWAIT)
                    if n == 0 {
                        onClientDisconnect?(request.payload)
                        return
                    }
                }
            }
        }

        if !answered { return }

        if let data = outgoing.get() {
            _ = data.withUnsafeBytes { ptr -> Int in
                write(fd, ptr.baseAddress, data.count)
            }
        }
    }

    private final class OutgoingBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?
        func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
        func get() -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    }

    private func readLineData(fd: Int32, maxBytes: Int = 1 << 20) -> Data? {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while out.count < maxBytes {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            for i in 0..<n {
                if buf[i] == 0x0A {
                    return out
                }
                out.append(buf[i])
            }
        }
        return out.isEmpty ? nil : out
    }
}
