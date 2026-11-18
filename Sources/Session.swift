import Foundation
import AppKit

struct GatewayAddress: Codable {
    let port: Int
    let token: String
    init(endpoint: String) throws {
        guard let u = URL(string: endpoint), u.scheme == "http", u.host == "127.0.0.1",
              let p = u.port, (1024...65535).contains(p), u.user == nil, u.password == nil,
              u.query == nil, u.fragment == nil, u.path.count == 11, u.path.hasPrefix("/") else {
            throw GatewayError("Некорректный адрес сохранённого шлюза.")
        }
        let t = String(u.path.dropFirst())
        guard t.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw GatewayError("Некорректный ключ локального адреса.") }
        port = p; token = t
    }
    var endpoint: String { "http://127.0.0.1:\(port)/\(token)" }
}

struct GatewaySession: Codable {
    let endpoint: String
    let route: String
    let patch: Bool
    var resume: Bool
    static var file: URL { supportDirectory.appendingPathComponent("session.json") }
    static func load() -> GatewaySession? {
        guard let data = try? Data(contentsOf: file), let session = try? JSONDecoder().decode(GatewaySession.self, from: data),
              (try? GatewayAddress(endpoint: session.endpoint)) != nil, (try? ProxyRoute(session.route)) != nil else { return nil }
        return session
    }
    func save() throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: Self.file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file.path)
    }
    static func remember(_ gateway: Gateway) throws {
        try GatewaySession(endpoint: gateway.endpoint, route: gateway.route.selection, patch: gateway.patchEnabled, resume: true).save()
    }
    // Migration from v1.0: recover only the address in our own private app, never an arbitrary endpoint.
    static func desktopAddress() -> GatewayAddress? {
        let file = supportDirectory.appendingPathComponent("Desktop/Antigravity.app/Contents/Resources/app.asar")
        guard let data = try? Data(contentsOf: file), data.count > 16 else { return nil }
        func word(_ i: Int) -> Int { (0..<4).reduce(0) { $0 | Int(data[i + $1]) << (8 * $1) } }
        let base = word(4) + 8, length = word(12)
        guard length > 0, length <= data.count - 16, base <= data.count,
              let tree = try? JSONSerialization.jsonObject(with: data.subdata(in: 16..<(16 + length))) as? [String: Any],
              let files = tree["files"] as? [String: Any], let dist = files["dist"] as? [String: Any],
              let children = dist["files"] as? [String: Any], let entry = children["lsDefaults.js"] as? [String: Any],
              let off = entry["offset"] as? String, let offset = Int(off), let size = entry["size"] as? Int,
              offset >= 0, size >= 0, offset <= data.count - base, size <= data.count - base - offset else { return nil }
        let text = String(decoding: data.subdata(in: (base + offset)..<(base + offset + size)), as: UTF8.self)
        let marker = "exports.LS_CLOUD_CODE_ENDPOINT = '"
        guard let start = text.range(of: marker)?.upperBound, let end = text[start...].firstIndex(of: "'") else { return nil }
        return try? GatewayAddress(endpoint: String(text[start..<end]))
    }
    static var desktopRunning: NSRunningApplication? {
        let path = supportDirectory.appendingPathComponent("Desktop/Antigravity.app").path
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == path }
    }
    static var ideRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.path == "/Applications/Antigravity IDE.app" }
    }
}
