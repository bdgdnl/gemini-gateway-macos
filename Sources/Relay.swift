import Foundation
import Darwin

// FileHandle.read(upToCount:) can wait to fill its buffer on macOS pipes.
// One POSIX read forwards each available piece immediately, preserving SSE latency.
private func readPipe(_ stream: FileHandle, count: Int) throws -> Data? {
    var bytes = [UInt8](repeating: 0, count: count)
    while true {
        let n = Darwin.read(stream.fileDescriptor, &bytes, count)
        if n < 0 && errno == EINTR { continue }
        if n < 0 { throw GatewayError("Поток ответа недоступен.") }
        if n == 0 { return nil }
        return Data(bytes.prefix(n))
    }
}

final class Gateway {
    let route: ProxyRoute
    let token: String
    let preferredPort: Int
    let upstream: String
    let patchEnabled: Bool
    let log: (String) -> Void
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var sockets = Set<Int32>()
    private var processes: [Process] = []
    private var diagnostics: [String] = []
    private var stopped = false
    private let slots = DispatchSemaphore(value: 32)
    private(set) var port = 0
    var endpoint: String { "http://127.0.0.1:\(port)/\(token)" }
    var proxyEndpoint: String { "http://127.0.0.1:\(port)" }
    init(route: ProxyRoute, patch: Bool = true, upstream: String = "https://daily-cloudcode-pa.googleapis.com", address: GatewayAddress? = nil, log: @escaping (String) -> Void) {
        self.route = route; self.patchEnabled = patch; self.upstream = upstream; self.log = log
        token = address?.token ?? String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).lowercased()
        preferredPort = address?.port ?? 0
    }
    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw GatewayError("Не удалось создать локальный сокет.") }
        configureSocket(fd)
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        var addr = sockaddr_in(); addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = UInt16(preferredPort).bigEndian
        let result = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0, listen(fd, 64) == 0 else { close(fd); throw GatewayError("Локальный порт занят. Завершите другую копию Gateway; адрес работающего клиента не будет изменён.") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        port = Int(UInt16(bigEndian: addr.sin_port)); listener = fd
        DispatchQueue.global().async { [self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { break }
                configureSocket(client)
                guard slots.wait(timeout: .now()) == .success else { close(client); continue }
                lock.lock(); let active = !stopped; if active { sockets.insert(client) }; lock.unlock()
                guard active else { close(client); slots.signal(); break }
                DispatchQueue.global().async { [self] in
                    defer { lock.lock(); sockets.remove(client); close(client); lock.unlock(); slots.signal() }
                    handle(client)
                }
            }
        }
        log("Шлюз готов. Маршрут: \(route.label)")
    }
    func stop() {
        lock.lock(); stopped = true
        if listener >= 0 { shutdown(listener, SHUT_RDWR); close(listener); listener = -1 }
        for fd in sockets { shutdown(fd, SHUT_RDWR) }
        for p in processes where p.isRunning { p.terminate() }
        lock.unlock()
    }
    private func record(_ event: String) {
        lock.lock(); diagnostics.append(event)
        if diagnostics.count > 40 { diagnostics.removeFirst(diagnostics.count - 40) }
        lock.unlock()
        log(event)
    }
    private func reply(_ fd: Int32, _ code: Int, _ text: String) {
        let body = (try? JSONSerialization.data(withJSONObject: ["message": text])) ?? Data()
        try? sendAll(fd, Data("HTTP/1.1 \(code) Gateway\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8) + body)
    }
    private func handle(_ fd: Int32) {
        do {
            let request = try HTTPRequest.read(SocketReader(fd))
            guard request.header("origin") == nil, request.header("sec-fetch-site") != "cross-site" else { reply(fd, 403, "Browser requests are not allowed"); return }
            if request.method == "CONNECT" {
                do { try tunnel(fd, request.target) }
                catch { reply(fd, 503, "Selected connection is unavailable"); record(error.localizedDescription) }
                return
            }
            let hosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
            guard hosts.contains(request.header("host")?.lowercased() ?? "") else { reply(fd, 403, "Invalid Host"); return }
            guard request.target.hasPrefix("/\(token)/") else { log("Локальный API: неверный адрес клиента (HTTP 404). Перезапустите клиент через Gateway."); reply(fd, 404, "Not found"); return }
            let path = String(request.target.dropFirst(token.count + 1))
            if path == "/health", request.method == "GET" { reply(fd, 200, "ready"); return }
            if path == "/diagnostics", request.method == "GET" {
                lock.lock(); let events = diagnostics; lock.unlock()
                let data = try JSONSerialization.data(withJSONObject: ["events": events])
                try sendAll(fd, Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8) + data)
                return
            }
            guard isSafeAPITarget(path) else { record("Локальный API: некорректный путь (HTTP 404); аргументы скрыты."); reply(fd, 404, "Invalid API path"); return }
            guard ["GET", "POST", "HEAD", "PUT", "PATCH", "DELETE", "OPTIONS"].contains(request.method) else {
                record("Локальный API: неподдерживаемый метод для \(apiOperationLabel(path)) (HTTP 405).")
                reply(fd, 405, "Unsupported HTTP method"); return
            }
            guard request.method != "HEAD" || request.body.isEmpty else { reply(fd, 400, "HEAD request must not contain a body"); return }
            try relay(fd, request, path)
        } catch { reply(fd, 400, "Invalid or incomplete request") }
    }
    private func tunnel(_ client: Int32, _ target: String) throws {
        let parts = target.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1] == "443", parts[0].contains("."),
              parts[0].utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }),
              !parts[0].hasSuffix(".local"), !parts[0].hasSuffix(".localhost"),
              parts[0].utf8.contains(where: { (65...90).contains($0) || (97...122).contains($0) }) else { reply(client, 403, "Only public HTTPS hostnames are allowed"); return }
        let host = String(parts[0])
        let remote: Int32
        if let proxy = route.url {
            remote = try connectSocket(proxy.host!, proxy.port!)
            do {
                if proxy.scheme == "http" {
                    try sendAll(remote, Data("CONNECT \(host):443 HTTP/1.1\r\nHost: \(host):443\r\n\r\n".utf8))
                    let r = SocketReader(remote); let status = try r.line()
                    guard status.split(separator: " ").dropFirst().first == "200" else { throw GatewayError("Прокси отказал в соединении.") }
                    var total = 0
                    while true { let line = try r.line(); total += line.count; guard total < 65536 else { throw GatewayError("Слишком большие заголовки прокси.") }; if line.isEmpty { break } }
                } else {
                    let r = SocketReader(remote)
                    try sendAll(remote, Data([5, 1, 0])); guard try r.exact(2) == Data([5, 0]) else { throw GatewayError("SOCKS5 требует авторизацию.") }
                    let name = Data(host.utf8); guard name.count < 256 else { throw GatewayError("Неверное имя.") }
                    try sendAll(remote, Data([5, 1, 0, 3, UInt8(name.count)]) + name + Data([1, 187]))
                    let head = try r.exact(4); guard head[0] == 5, head[1] == 0 else { throw GatewayError("SOCKS5 отказал в соединении.") }
                    switch head[3] {
                    case 1: _ = try r.exact(6)
                    case 4: _ = try r.exact(18)
                    case 3: let count = Int(try r.exact(1)[0]); _ = try r.exact(count + 2)
                    default: throw GatewayError("Неверный ответ SOCKS5.")
                    }
                }
            } catch { close(remote); throw error }
        } else { remote = try connectSocket(host, 443, interface: route.vpnInterface()) }
        lock.lock(); let active = !stopped; if active { sockets.insert(remote) }; lock.unlock()
        guard active else { close(remote); return }
        defer { lock.lock(); sockets.remove(remote); close(remote); lock.unlock() }
        configureSocket(remote, seconds: 600); configureSocket(client, seconds: 600)
        try sendAll(client, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
        let group = DispatchGroup()
        func copy(_ from: Int32, _ to: Int32) {
            var bytes = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = recv(from, &bytes, bytes.count, 0)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { break }
                do { try sendAll(to, Data(bytes.prefix(count))) } catch { break }
            }
            shutdown(to, SHUT_WR)
        }
        group.enter(); DispatchQueue.global().async { copy(client, remote); group.leave() }
        copy(remote, client); shutdown(client, SHUT_RDWR); shutdown(remote, SHUT_RDWR); group.wait()
    }
    private func relay(_ client: Int32, _ request: HTTPRequest, _ path: String) throws {
        let interface: String?
        do { interface = try route.vpnInterface() }
        catch { reply(client, 503, "VPN tunnel is unavailable"); record(error.localizedDescription); return }
        let operation = apiOperationLabel(path)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.lowercased().contains("proxy") || key == "CURL_HOME" { environment.removeValue(forKey: key) }
        environment["CURL_HOME"] = "/dev/null"; process.environment = environment
        // -q must be first: ignore ~/.curlrc. Credentials/headers go through stdin, never argv.
        process.arguments = ["-q", "--config", "-", "--silent", "--show-error", "--no-buffer", "--include", "--suppress-connect-headers", "--connect-timeout", "12", "--max-time", "600", "--proto", upstream.hasPrefix("http://127.0.0.1:") ? "=http" : "=https", "--proxy", route.curlValue, "--noproxy", "", "--request", request.method, "--url", upstream + path]
        if request.method == "HEAD" { process.arguments! += ["--head"] }
        if let interface = interface { process.arguments! += ["--interface", "if!" + interface] }
        func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\t", with: "\\t") + "\"" }
        var config = "header = \"Accept-Encoding: identity\"\nheader = \"Expect:\"\n"
        let blocked = Set(["host", "connection", "proxy-connection", "proxy-authorization", "content-length", "transfer-encoding", "accept-encoding", "expect", "trailer", "upgrade", "te"])
        let connectionTokens = Set((request.header("connection") ?? "").lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        for (key, value) in request.headers where !blocked.contains(key.lowercased()) && !connectionTokens.contains(key.lowercased()) {
            config += "header = \(quoted(key + ": " + value))\n"
        }
        // An owner-only FIFO carries the body in memory: no regular payload file on disk.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-gateway-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temp) }
        var bodyPath: String?
        if !request.body.isEmpty {
            let file = temp.appendingPathComponent("body")
            guard mkfifo(file.path, 0o600) == 0 else { throw GatewayError("Не удалось создать канал запроса.") }
            bodyPath = file.path
            config += "data-binary = \(quoted("@" + file.path))\n"
        }
        lock.lock()
        if stopped { lock.unlock(); return }
        do { try process.run(); processes.append(process); lock.unlock() } catch { lock.unlock(); throw error }
        let bodyWriter = DispatchGroup()
        if let bodyPath = bodyPath {
            bodyWriter.enter()
            DispatchQueue.global().async {
                var fd: Int32 = -1
                let deadline = Date().addingTimeInterval(15)
                while process.isRunning && Date() < deadline {
                    fd = open(bodyPath, O_WRONLY | O_NONBLOCK)
                    if fd >= 0 { break }
                    if errno != ENXIO && errno != EINTR { break }
                    usleep(10000)
                }
                guard fd >= 0 else { bodyWriter.leave(); return }
                defer { close(fd); bodyWriter.leave() }
                request.body.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    var sent = 0
                    while sent < raw.count && process.isRunning {
                        let n = Darwin.write(fd, base.advanced(by: sent), raw.count - sent)
                        if n > 0 { sent += n; continue }
                        if errno == EINTR { continue }
                        if errno != EAGAIN { return }
                        var wait = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        _ = poll(&wait, 1, 250)
                    }
                }
            }
        }
        defer {
            if process.isRunning { process.terminate() }; process.waitUntilExit()
            bodyWriter.wait()
            lock.lock(); processes.removeAll { $0 === process }; lock.unlock()
        }
        let configData = Data(config.utf8)
        DispatchQueue.global().async {
            try? input.fileHandleForWriting.write(contentsOf: configData); try? input.fileHandleForWriting.close()
        }
        let stream = output.fileHandleForReading
        var buffer = Data(); let delimiter = Data([13, 10, 13, 10])
        var headerText = ""; var status = 0
        while true {
            guard let chunk = try readPipe(stream, count: 1), !chunk.isEmpty else {
                process.waitUntilExit()
                reply(client, 502, "Upstream connection failed; check selected connection"); record("\(operation): нет ответа Google (curl \(process.terminationStatus)). Проверьте \(route.label)."); return
            }
            buffer.append(chunk)
            guard buffer.count <= 65536 else { reply(client, 502, "Invalid upstream headers"); return }
            if buffer.suffix(4) == delimiter {
                headerText = String(decoding: buffer.dropLast(4), as: UTF8.self)
                let line = headerText.components(separatedBy: "\r\n")[0]
                status = Int(line.split(separator: " ").dropFirst().first ?? "") ?? 0
                if status >= 100 && status < 200 { buffer.removeAll(); continue }
                break
            }
        }
        record("\(operation): Google HTTP \(status) (\(request.method)).")
        let shouldPatch = patchEnabled && request.method != "HEAD" && path.split(separator: "?")[0] == "/v1internal:loadCodeAssist" && (200..<300).contains(status)
        var response = "HTTP/1.1 \(status) Upstream\r\nConnection: close\r\nCache-Control: no-store\r\n"
        let responseLines = headerText.components(separatedBy: "\r\n").dropFirst()
        for line in responseLines {
            let key = line.split(separator: ":", maxSplits: 1).first?.lowercased() ?? ""
            if key == "content-length" && request.method != "HEAD" { continue }
            if ["transfer-encoding", "connection", "keep-alive", "cache-control", "trailer", "upgrade", "proxy-authenticate"].contains(key) { continue }
            if shouldPatch && ["content-encoding", "etag", "content-md5"].contains(key) { continue }
            response += line + "\r\n"
        }
        var started = false
        do {
            if shouldPatch {
                var data = Data()
                while let chunk = try readPipe(stream, count: 65536), !chunk.isEmpty {
                    data.append(chunk); guard data.count <= 8 * 1024 * 1024 else { throw GatewayError("Слишком большой ответ доступности.") }
                }
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw GatewayError("Ответ Google оборвался.") }
                let encoding = responseLines.first { $0.lowercased().hasPrefix("content-encoding:") }?.lowercased() ?? ""
                guard encoding.isEmpty || encoding.hasSuffix("identity") else { throw GatewayError("Google вернул неожиданное сжатие.") }
                let patched = patchedEligibility(data)
                try sendAll(client, Data((response + "Content-Length: \(patched.count)\r\n\r\n").utf8)); started = true
                try sendAll(client, patched)
                log("loadCodeAssist: HTTP \(status), обработан ответ доступности.")
            } else {
                try sendAll(client, Data((response + "\r\n").utf8)); started = true
                var errorSample = Data()
                while let chunk = try readPipe(stream, count: 65536), !chunk.isEmpty {
                    if status >= 400 && errorSample.count < 65536 { errorSample.append(chunk.prefix(65536 - errorSample.count)) }
                    try sendAll(client, chunk)
                }
                process.waitUntilExit()
                if status >= 400, let summary = serviceErrorSummary(errorSample) { record(summary) }
                if path.contains("GenerateContent") || status >= 400 { log("API: HTTP \(status)\(process.terminationStatus == 0 ? "" : ", поток оборвался").") }
            }
        } catch {
            if !started { reply(client, 502, "Upstream response failed") }
            log("Ответ прерван. Проверьте маршрут; содержимое запроса не записывалось.")
        }
    }
}
