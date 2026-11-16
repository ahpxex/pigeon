import Darwin
import Foundation

/// HTTP/1.1 over a unix domain socket — the transport behind the `pigeon`
/// CLI (RemoteControl). One request per connection: `POST /cli` with
/// `{"argv": [...], "cwd": "..."}`, answered by ControlCommands.
///
/// Trust boundary: the socket file is 0600 and every peer's uid must
/// equal ours (getpeereid). A unix socket is unreachable from browsers,
/// so none of the TCP-side defenses (token, Host, Origin) apply. The
/// peer's pid is resolved too, so commands can refuse callers running
/// inside this Pigeon instance's own terminals (an agent approving its
/// own tool request).
final class ControlServer {
    enum ServerError: LocalizedError {
        case system(String)

        var errorDescription: String? {
            switch self {
            case .system(let message): return "Remote control socket: \(message)"
            }
        }
    }

    private let socketPath: String
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "pigeon.control-server")

    private static let maxRequestBytes = 1 << 20

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    deinit { stop() }

    func start() throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            throw ServerError.system("path too long: \(socketPath)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
            buffer[pathBytes.count] = 0
        }

        try FileManager.default.createDirectory(
            atPath: (socketPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        // A socket file left by a previous run of this variant (one app
        // instance per bundle id, so it can't be live).
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.system("socket(): \(errnoString())") }

        // Created 0600 from the start: no window where another user could
        // connect before a chmod.
        let oldMask = umask(0o177)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(oldMask)
        guard bound == 0 else {
            let message = errnoString()
            close(fd)
            throw ServerError.system("bind(\(socketPath)): \(message)")
        }
        guard listen(fd, 16) == 0 else {
            let message = errnoString()
            close(fd)
            unlink(socketPath)
            throw ServerError.system("listen(): \(message)")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
        Ghostty.logger.info("remote control listening on \(self.socketPath)")
    }

    func stop() {
        guard let source = acceptSource else { return }
        acceptSource = nil
        listenFD = -1
        source.cancel()
        unlink(socketPath)
    }

    // MARK: Connections

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }
            configure(client)
            guard let peer = Self.peer(of: client), peer.uid == getuid() else {
                close(client)
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async {
                self.serve(client, peerPID: peer.pid)
            }
        }
    }

    private func configure(_ fd: Int32) {
        // macOS hands accepted sockets the listener's O_NONBLOCK; reads
        // here are blocking with a timeout.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func peer(of fd: Int32) -> (uid: uid_t, pid: pid_t)? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 else { return nil }
        return (uid, pid)
    }

    private func serve(_ fd: Int32, peerPID: pid_t) {
        guard let request = Self.readRequest(fd) else {
            Self.writeResponse(fd, status: 400, body: "pigeon: malformed request\n")
            return
        }
        guard request.method == "POST", request.path == "/cli",
              let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let argv = json["argv"] as? [String]
        else {
            Self.writeResponse(fd, status: 404, body: "pigeon: unknown endpoint\n")
            return
        }
        let cwd = json["cwd"] as? String
        let insidePigeon = ProcessAncestry.isDescendant(peerPID, of: getpid())
        Task { @MainActor in
            let response = await ControlCommands.run(
                argv: argv, cwd: cwd, callerInsidePigeon: insidePigeon)
            DispatchQueue.global(qos: .userInitiated).async {
                Self.writeResponse(fd, status: response.status, body: response.body)
            }
        }
    }

    private struct Request {
        var method: String
        var path: String
        var body: Data
    }

    private static func readRequest(_ fd: Int32) -> Request? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count <= Self.maxRequestBytes {
            switch parse(data) {
            case .complete(let request): return request
            case .invalid: return nil
            case .incomplete: break
            }
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { return nil }
            data.append(buffer, count: count)
        }
        return nil
    }

    private enum Parse {
        case incomplete
        case invalid
        case complete(Request)
    }

    private static func parse(_ data: Data) -> Parse {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8)
        else { return .invalid }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].components(separatedBy: " ")
        guard parts.count >= 2 else { return .invalid }
        var contentLength = 0
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2, pair[0].lowercased() == "content-length" {
                guard let length = Int(pair[1].trimmingCharacters(in: .whitespaces)),
                      (0...maxRequestBytes).contains(length)
                else { return .invalid }
                contentLength = length
            }
        }
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= contentLength else { return .incomplete }
        return .complete(Request(
            method: parts[0], path: parts[1],
            body: data.subdata(in: bodyStart..<(bodyStart + contentLength))))
    }

    private static func writeResponse(_ fd: Int32, status: Int, body: String) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 409: reason = "Conflict"
        default: reason = "Error"
        }
        let bodyData = Data(body.utf8)
        var response = Data((
            "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/plain; charset=utf-8\r\n"
                + "Content-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n").utf8)
        response.append(bodyData)
        response.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
        close(fd)
    }
}

private func errnoString() -> String {
    String(cString: strerror(errno))
}

/// Parent-process walk via sysctl(KERN_PROC_PID).
enum ProcessAncestry {
    /// sysctl(KERN_PROC_PID) works for every process, including root-owned
    /// ones like /usr/bin/login (proc_name() fails for those).
    private static func info(of pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        return info
    }

    static func parent(of pid: pid_t) -> pid_t? {
        info(of: pid)?.kp_eproc.e_ppid
    }

    static func name(of pid: pid_t) -> String? {
        guard var info = info(of: pid) else { return nil }
        return withUnsafeBytes(of: &info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// Whether a pty's foreground process group is a program the tab's
    /// shell started, rather than the shell itself. The surface's process
    /// tree is app → [login] → shell → program: count the hops from the
    /// group leader up to the app, not counting login.
    static func isShellJob(foregroundGroup leader: pid_t, app: pid_t) -> Bool {
        var hops = 0
        var current = leader
        for _ in 0..<64 {
            if current == app { return hops >= 2 }
            guard current > 1, let process = info(of: current) else { return false }
            let parent = process.kp_eproc.e_ppid
            guard parent != current else { return false }
            if name(of: current) != "login" { hops += 1 }
            current = parent
        }
        return false
    }

    /// Whether `pid` is `ancestor` or runs (transitively) under it.
    static func isDescendant(_ pid: pid_t, of ancestor: pid_t) -> Bool {
        var current = pid
        for _ in 0..<64 {
            if current == ancestor { return true }
            guard current > 1, let parent = parent(of: current), parent != current else {
                return false
            }
            current = parent
        }
        return false
    }
}
