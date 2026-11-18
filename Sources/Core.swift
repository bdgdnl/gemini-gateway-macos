import Foundation
import Darwin

struct GatewayError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func clientEnvironment(_ inherited: [String: String]) -> [String: String] {
    inherited.filter { key, _ in
        key != "NODE_OPTIONS" && key != "NODE_PATH" && !key.hasPrefix("ELECTRON_") && !key.hasPrefix("VSCODE_")
    }
}

// The destination host is fixed by Gateway. Validate the relative request target,
// rather than maintaining an incomplete list of Google's API versions/RPCs.
func isSafeAPITarget(_ target: String) -> Bool {
    guard target.hasPrefix("/"), !target.hasPrefix("//"), !target.contains("#"),
          !target.utf8.contains(where: { $0 <= 32 || $0 == 127 }) else { return false }
    let path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
    guard let decoded = path.removingPercentEncoding, !decoded.contains("\\"), !decoded.hasPrefix("//"),
          !decoded.utf8.contains(where: { $0 <= 31 || $0 == 127 }), !decoded.contains("://") else { return false }
    return !decoded.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
}

func apiOperationLabel(_ target: String) -> String {
    let path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
    // RPC names are static; do not include arguments, query strings, or resource IDs.
    if path.hasPrefix("/v1internal:") {
        let name = String(path.dropFirst("/v1internal:".count))
        if !name.isEmpty, name.count <= 80, name.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) { return name }
    }
    let segments = path.split(separator: "/")
    let idCollections: Set<String> = ["projects", "users", "accounts", "conversations", "trajectories", "instances", "sessions"]
    var labels: [String] = []
    for (i, segment) in segments.prefix(2).enumerated() {
        let version = segment.range(of: #"^v[0-9]+(?:internal|beta[0-9]*)?$"#, options: .regularExpression) != nil
        let staticName = segment.count <= 40 && segment.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45 })
        labels.append((i == 0 || !idCollections.contains(String(segments[i - 1]))) && (version || staticName) ? String(segment) : "<id>")
    }
    return "/" + labels.joined(separator: "/") + (segments.count > 2 ? "/…" : "")
}

func verifyChildStayedRunning(_ process: Process, grace: TimeInterval = 1.5) throws {
    let deadline = Date().addingTimeInterval(grace)
    while Date() < deadline {
        if !process.isRunning {
            throw GatewayError("Приложение завершилось при запуске (код \(process.terminationStatus)). Окно не было открыто.")
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    guard process.isRunning else { throw GatewayError("Приложение завершилось при запуске (код \(process.terminationStatus)).") }
}

struct ProxyRoute {
    let url: URL?
    let usesAmneziaWG: Bool
    init(_ text: String) throws {
        usesAmneziaWG = text == "amneziawg"
        if text == "direct" || usesAmneziaWG { url = nil; return }
        guard let u = URL(string: text), let scheme = u.scheme?.lowercased(),
              ["http", "socks5", "socks5h"].contains(scheme),
              let host = u.host, !host.isEmpty, let port = u.port, (1...65535).contains(port),
              u.user == nil, u.password == nil, u.query == nil, u.fragment == nil,
              u.path.isEmpty || u.path == "/" else {
            throw GatewayError("Нужен адрес локального прокси: socks5://127.0.0.1:10808 или http://127.0.0.1:10809. Без логина и пароля.")
        }
        url = u
    }
    var curlValue: String { url?.absoluteString.replacingOccurrences(of: "socks5://", with: "socks5h://") ?? "" }
    var selection: String { url?.absoluteString ?? (usesAmneziaWG ? "amneziawg" : "direct") }
    var label: String { url?.absoluteString ?? (usesAmneziaWG ? "AmneziaWG" : "Системный VPN (прямой маршрут)") }
    func vpnInterface() throws -> String? { usesAmneziaWG ? try AmneziaVPN.interface() : nil }
}

func configureSocket(_ fd: Int32, seconds: Int = 30) {
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
    var timeout = timeval(tv_sec: seconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
}

func connectSocket(_ host: String, _ port: Int, timeout: Int32 = 4, interface: String? = nil) throws -> Int32 {
    let interfaceIndex = interface.map { if_nametoindex($0) }
    if interfaceIndex == 0 { throw GatewayError("VPN-интерфейс недоступен. Повторно подключите AmneziaWG.") }
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM; hints.ai_protocol = IPPROTO_TCP
    var head: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &head) == 0, let first = head else {
        throw GatewayError("Не удалось разрешить имя сервера.")
    }
    defer { freeaddrinfo(first) }
    var current: UnsafeMutablePointer<addrinfo>? = first
    while let item = current {
        let a = item.pointee
        let fd = socket(a.ai_family, a.ai_socktype, a.ai_protocol)
        if fd >= 0 {
            if var index = interfaceIndex {
                let family = a.ai_family == AF_INET6 ? IPPROTO_IPV6 : IPPROTO_IP
                let option = a.ai_family == AF_INET6 ? IPV6_BOUND_IF : IP_BOUND_IF
                guard setsockopt(fd, family, option, &index, socklen_t(MemoryLayout.size(ofValue: index))) == 0 else { close(fd); current = a.ai_next; continue }
            }
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            let result = Darwin.connect(fd, a.ai_addr, a.ai_addrlen)
            var ready = result == 0
            if !ready && errno == EINPROGRESS {
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&p, 1, timeout * 1000) > 0 {
                    var error: Int32 = 0; var length = socklen_t(MemoryLayout.size(ofValue: error))
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
                    ready = error == 0
                }
            }
            _ = fcntl(fd, F_SETFL, flags)
            if ready { configureSocket(fd); return fd }
            close(fd)
        }
        current = a.ai_next
    }
    throw GatewayError(interface == nil ? "Сервер или прокси недоступен. Проверьте выбранное подключение." : "Сервер недоступен через туннель AmneziaWG. Обычный маршрут не использовался.")
}

func sendAll(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var sent = 0
        while sent < data.count {
            let n = Darwin.send(fd, base.advanced(by: sent), data.count - sent, 0)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw GatewayError("Соединение закрыто клиентом.") }
            sent += n
        }
    }
}

final class SocketReader {
    let fd: Int32
    var pending = Data()
    init(_ fd: Int32) { self.fd = fd }
    func exact(_ count: Int) throws -> Data {
        guard count >= 0, count <= 64 * 1024 * 1024 else { throw GatewayError("Слишком большой запрос.") }
        while pending.count < count {
            var bytes = [UInt8](repeating: 0, count: min(65536, count - pending.count))
            let n = recv(fd, &bytes, bytes.count, 0)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw GatewayError("Неполный запрос или таймаут.") }
            pending.append(contentsOf: bytes.prefix(n))
        }
        let result = pending.prefix(count); pending.removeFirst(count); return Data(result)
    }
    func line(limit: Int = 16384) throws -> String {
        var data = Data()
        while !data.suffix(2).elementsEqual([13, 10]) {
            guard data.count < limit else { throw GatewayError("Слишком большой заголовок.") }
            data.append(try exact(1))
        }
        return String(decoding: data.dropLast(2), as: UTF8.self)
    }
}

struct HTTPRequest {
    let method: String
    let target: String
    let headers: [(String, String)]
    let body: Data
    func header(_ key: String) -> String? { headers.first { $0.0.lowercased() == key.lowercased() }?.1 }
    static func read(_ reader: SocketReader) throws -> HTTPRequest {
        let first = try reader.line().split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0" else { throw GatewayError("Неверный HTTP-запрос.") }
        var headers: [(String, String)] = []; var total = 0
        while true {
            let line = try reader.line(); total += line.utf8.count
            guard total < 65536 else { throw GatewayError("Слишком большие заголовки.") }
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw GatewayError("Неверный заголовок.") }
            let key = String(line[..<colon]); let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.utf8.allSatisfy({ $0 > 32 && $0 < 127 }), !value.contains("\r"), !value.contains("\n") else { throw GatewayError("Неверный заголовок.") }
            headers.append((key, value))
        }
        let lengths = headers.filter { $0.0.lowercased() == "content-length" }
        let transfers = headers.filter { $0.0.lowercased() == "transfer-encoding" }
        guard lengths.count <= 1, transfers.count <= 1, lengths.isEmpty || transfers.isEmpty else { throw GatewayError("Неоднозначная длина запроса.") }
        if headers.contains(where: { $0.0.lowercased() == "expect" }) {
            try sendAll(reader.fd, Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
        }
        var body = Data()
        if let transfer = transfers.first {
            guard transfer.1.lowercased() == "chunked" else { throw GatewayError("Неподдерживаемое кодирование запроса.") }
            while true {
                let line = try reader.line()
                guard let sizeText = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first, !sizeText.isEmpty else { throw GatewayError("Пустой chunk.") }
                guard let size = Int(sizeText, radix: 16), size >= 0, size <= 64 * 1024 * 1024 - body.count else { throw GatewayError("Неверный chunk.") }
                if size == 0 {
                    var trailerSize = 0
                    while true { let trailer = try reader.line(); trailerSize += trailer.count; guard trailerSize < 16384 else { throw GatewayError("Слишком большие trailers.") }; if trailer.isEmpty { break } }
                    break
                }
                body.append(try reader.exact(size))
                guard try reader.exact(2) == Data([13, 10]) else { throw GatewayError("Неверный chunk.") }
            }
        } else if let length = lengths.first {
            guard let count = Int(length.1), count >= 0 else { throw GatewayError("Неверная длина запроса.") }
            body = try reader.exact(count)
        }
        return HTTPRequest(method: String(first[0]), target: String(first[1]), headers: headers, body: body)
    }
}

func patchedEligibility(_ data: Data) -> Data {
    guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object["error"] == nil else { return data }
    let keys = ["ineligibleTiers", "ineligible_tiers", "inexigibleTiers", "inexigible_tiers"]
    var tier: [String: Any]?
    for key in keys {
        if let entries = object[key] as? [[String: Any]], tier == nil { tier = entries.first?["tier"] as? [String: Any] }
        object.removeValue(forKey: key)
    }
    if object["currentTier"] == nil || object["currentTier"] is NSNull {
        object["currentTier"] = tier ?? ["id": "free-tier", "name": "FREE_TIER", "description": "Antigravity Free Tier", "isDefault": true]
    }
    if (object["allowedTiers"] as? [Any])?.isEmpty != false { object["allowedTiers"] = [object["currentTier"]!] }
    return (try? JSONSerialization.data(withJSONObject: object)) ?? data
}

// Summarise service errors without copying arbitrary server text, prompts, or tokens into diagnostics.
func serviceErrorSummary(_ data: Data) -> String? {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let error = root["error"] as? [String: Any], let message = error["message"] as? String else { return nil }
    let lower = message.lowercased()
    if lower.contains("location") || lower.contains("region") || lower.contains("country") {
        return "Google отклонил регион. Выберите другой сервер подключения в Happ."
    }
    if lower.contains("quota") || lower.contains("rate limit") { return "Google сообщил об ограничении квоты или частоты запросов." }
    if lower.contains("model") && (lower.contains("not found") || lower.contains("not supported") || lower.contains("not available")) {
        return "Выбранная модель недоступна этому API или аккаунту."
    }
    if lower.contains("project") { return "Google отклонил конфигурацию проекта аккаунта." }
    if lower.contains("invalid json") || lower.contains("unknown name") || lower.contains("invalid value") { return "Формат запроса не соответствует API Google." }
    if lower.contains("token") || lower.contains("unauthenticated") { return "Google не принял авторизацию; требуется повторный вход." }
    if lower.contains("permission") { return "Google отказал аккаунту в доступе." }
    if let status = error["status"] as? String, ["INVALID_ARGUMENT", "PERMISSION_DENIED", "UNAUTHENTICATED", "RESOURCE_EXHAUSTED", "NOT_FOUND", "UNAVAILABLE"].contains(status) { return "Google: \(status)." }
    return "Google вернул ошибку без распознанной категории."
}
