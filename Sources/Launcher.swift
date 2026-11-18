import Foundation
import AppKit
import CryptoKit
import CoreServices

let supportDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Gemini Gateway", isDirectory: true)

func runTool(_ executable: String, _ arguments: [String]) throws {
    let p = Process(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
    p.standardOutput = FileHandle.nullDevice
    let error = Pipe(); p.standardError = error
    try p.run()
    let details = error.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    guard p.terminationStatus == 0 else {
        throw GatewayError("\(URL(fileURLWithPath: executable).lastPathComponent): \(String(decoding: details.prefix(1500), as: UTF8.self))")
    }
}

enum DesktopCopy {
    static func patchASAR(_ archive: Data, endpoint: String) throws -> (Data, String) {
        func word(_ index: Int) -> Int {
            Int(archive[index]) | Int(archive[index + 1]) << 8 | Int(archive[index + 2]) << 16 | Int(archive[index + 3]) << 24
        }
        guard archive.count > 16 else { throw GatewayError("Повреждённый ASAR.") }
        let headerSize = word(4), jsonSize = word(12), base = headerSize + 8
        guard jsonSize > 0, jsonSize <= headerSize, 16 + jsonSize <= base, base <= archive.count,
              var tree = try JSONSerialization.jsonObject(with: archive.subdata(in: 16..<(16 + jsonSize))) as? [String: Any],
              var files = tree["files"] as? [String: Any], var dist = files["dist"] as? [String: Any],
              var distFiles = dist["files"] as? [String: Any], var node = distFiles["lsDefaults.js"] as? [String: Any],
              let offsetText = node["offset"] as? String, let offset = Int(offsetText), let count = node["size"] as? Int,
              offset >= 0, count > 0, offset <= archive.count - base, count <= archive.count - base - offset else {
            throw GatewayError("Эта версия Antigravity Desktop не поддерживается: не найден lsDefaults.js. Оригинал не изменён.")
        }
        let range = (base + offset)..<(base + offset + count)
        let original = archive.subdata(in: range)
        let old = "'https://daily-cloudcode-pa.googleapis.com'"
        let new = "'\(endpoint)'"
        let text = String(decoding: original, as: UTF8.self)
        guard text.components(separatedBy: old).count == 2, new.utf8.count <= old.utf8.count else {
            throw GatewayError("Неизвестный формат Desktop: безопасная замена адреса невозможна.")
        }
        let patched = Data(text.replacingOccurrences(of: old, with: new + String(repeating: " ", count: old.utf8.count - new.utf8.count)).utf8)
        guard patched.count == original.count else { throw GatewayError("Размер ASAR изменился неожиданно.") }
        var payload = archive.subdata(in: base..<archive.count)
        payload.replaceSubrange(offset..<(offset + count), with: patched)
        if var integrity = node["integrity"] as? [String: Any] {
            guard integrity["algorithm"] as? String == "SHA256", let blockSize = integrity["blockSize"] as? Int, blockSize > 0 else { throw GatewayError("Неизвестная схема целостности ASAR.") }
            integrity["hash"] = SHA256.hash(data: patched).map { String(format: "%02x", $0) }.joined()
            integrity["blocks"] = stride(from: 0, to: patched.count, by: blockSize).map { start in
                SHA256.hash(data: patched.subdata(in: start..<min(start + blockSize, patched.count))).map { String(format: "%02x", $0) }.joined()
            }
            node["integrity"] = integrity
        }
        distFiles["lsDefaults.js"] = node; dist["files"] = distFiles; files["dist"] = dist; tree["files"] = files
        let json = try JSONSerialization.data(withJSONObject: tree, options: [.sortedKeys, .withoutEscapingSlashes])
        let padding = (4 - (json.count % 4)) % 4
        var result = Data()
        func appendWord(_ v: Int) { var little = UInt32(v).littleEndian; withUnsafeBytes(of: &little) { result.append(contentsOf: $0) } }
        appendWord(4); appendWord(8 + json.count + padding); appendWord(4 + json.count + padding); appendWord(json.count)
        result.append(json); result.append(Data(repeating: 0, count: padding)); result.append(payload)
        return (result, SHA256.hash(data: json).map { String(format: "%02x", $0) }.joined())
    }
    static func prepare(source: URL, endpoint: String, log: (String) -> Void) throws -> URL {
        let fm = FileManager.default
        let root = supportDirectory.appendingPathComponent("Desktop", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = root.appendingPathComponent("Antigravity.app", isDirectory: true)
        let sourceArchive = source.appendingPathComponent("Contents/Resources/app.asar")
        let sourceData = try Data(contentsOf: sourceArchive)
        let sourceHash = SHA256.hash(data: sourceData).map { String(format: "%02x", $0) }.joined()
        let marker = root.appendingPathComponent("source.sha256")
        let previous = try? String(contentsOf: marker, encoding: .utf8)
        if previous != sourceHash || !fm.fileExists(atPath: destination.path) {
            log("Готовлю отдельную копию Desktop. Оригинал не меняется…")
            let fresh = root.appendingPathComponent("Preparing-\(UUID().uuidString).app")
            defer { try? fm.removeItem(at: fresh) }
            do { try runTool("/bin/cp", ["-cR", source.path, fresh.path]) }
            catch { try? fm.removeItem(at: fresh); try runTool("/usr/bin/ditto", [source.path, fresh.path]) }
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: fresh, to: destination)
            try sourceHash.write(to: marker, atomically: true, encoding: .utf8)
        }
        let (patched, hash) = try patchASAR(sourceData, endpoint: endpoint)
        try patched.write(to: destination.appendingPathComponent("Contents/Resources/app.asar"), options: .atomic)
        let infoPath = destination.appendingPathComponent("Contents/Info.plist")
        guard var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoPath), format: nil) as? [String: Any] else { throw GatewayError("Не удалось прочитать Info.plist.") }
        if var integrities = info["ElectronAsarIntegrity"] as? [String: Any] {
            integrities["Resources/app.asar"] = ["algorithm": "SHA256", "hash": hash]; info["ElectronAsarIntegrity"] = integrities
        }
        // Separate identity: the private copy must not become the handler of the original's links.
        info["CFBundleIdentifier"] = "local.geminigateway.desktop"
        info["CFBundleDisplayName"] = "Antigravity · Gateway"
        info.removeValue(forKey: "CFBundleURLTypes")
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: infoPath, options: .atomic)
        // Sign only our private copy. No global security settings or original signatures change.
        try runTool("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", destination.path])
        try runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", destination.path])
        // The local copy no longer has the vendor's signature. Remove inherited download
        // quarantine only from that copy; the original and global Gatekeeper stay intact.
        try runTool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", destination.path])
        return destination
    }
}

enum ClientLauncher {
    static func environment(endpoint: String?) -> [String: String] {
        var environment = clientEnvironment(ProcessInfo.processInfo.environment)
        if let endpoint = endpoint, let u = URL(string: endpoint), let port = u.port, u.host == "127.0.0.1", u.scheme == "http" {
            let proxy = "http://127.0.0.1:\(port)"
            for key in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy", "AG_LS_PROXY"] { environment[key] = proxy }
            environment["CLOUD_CODE_URL"] = endpoint
            environment["NO_PROXY"] = "localhost,127.0.0.1,::1"; environment["no_proxy"] = "localhost,127.0.0.1,::1"
        }
        return environment
    }
    static func launch(ide: Bool, gateway: Gateway, log: @escaping (String) -> Void) throws {
        let source = URL(fileURLWithPath: ide ? "/Applications/Antigravity IDE.app" : "/Applications/Antigravity.app")
        guard FileManager.default.fileExists(atPath: source.path) else { throw GatewayError("Приложение не найдено: \(source.path)") }
        let profile = supportDirectory.appendingPathComponent(ide ? "IDE Profile" : "Desktop Profile", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let app: URL
        if ide {
            app = source
            let user = profile.appendingPathComponent("User", isDirectory: true)
            try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
            let settings = user.appendingPathComponent("settings.json")
            var values: [String: Any] = [:]
            if FileManager.default.fileExists(atPath: settings.path) {
                guard let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any] else { throw GatewayError("Настройки отдельного IDE-профиля не являются JSON. Исправьте их и повторите.") }
                values = parsed
            }
            values["jetski.cloudCodeUrl"] = gateway.endpoint
            values["http.proxy"] = gateway.proxyEndpoint
            values["http.proxyStrictSSL"] = true
            try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]).write(to: settings, options: .atomic)
        } else {
            let privatePath = supportDirectory.appendingPathComponent("Desktop/Antigravity.app").path
            if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == privatePath }) {
                if GatewaySession.desktopAddress()?.endpoint == gateway.endpoint {
                    running.activate(options: [.activateIgnoringOtherApps]); log("Соединение открытого Desktop восстановлено."); return
                }
                throw GatewayError("Сначала завершите запущенную копию Antigravity · Gateway через ⌘Q, затем запустите её заново.")
            }
            app = try DesktopCopy.prepare(source: source, endpoint: gateway.endpoint, log: log)
        }
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
        guard let name = info?["CFBundleExecutable"] as? String else { throw GatewayError("Не найден исполняемый файл приложения.") }
        let p = Process(); p.executableURL = app.appendingPathComponent("Contents/MacOS/\(name)")
        p.arguments = ["--user-data-dir=\(profile.path)", "--proxy-server=\(gateway.proxyEndpoint)", "--proxy-bypass-list=<local>;localhost;127.0.0.1;::1"]
        p.environment = environment(endpoint: gateway.endpoint); p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run()
        try verifyChildStayedRunning(p)
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            guard p.isRunning else { throw GatewayError("Приложение завершилось до открытия окна (код \(p.terminationStatus)).") }
            if let running = NSRunningApplication(processIdentifier: p.processIdentifier), running.isFinishedLaunching {
                running.activate(options: [.activateIgnoringOtherApps]); break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        p.terminationHandler = { process in
            if process.terminationStatus != 0 { log("\(ide ? "IDE" : "Desktop") завершился с кодом \(process.terminationStatus).") }
        }
        // Retain Process while the client lives, without retaining or logging its output.
        ClientProcesses.shared.add(p)
        log("\(ide ? "IDE" : "Desktop") запущен в отдельном профиле. При первом запуске войдите в Google.")
    }
    static func forwardLogin(_ url: URL) throws {
        let ide = url.scheme == "antigravity-ide"
        let app = ide ? URL(fileURLWithPath: "/Applications/Antigravity IDE.app") : supportDirectory.appendingPathComponent("Desktop/Antigravity.app")
        let profile = supportDirectory.appendingPathComponent(ide ? "IDE Profile" : "Desktop Profile")
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
        guard let name = info?["CFBundleExecutable"] as? String else { throw GatewayError("Не удалось передать ответ авторизации.") }
        let p = Process(); p.executableURL = app.appendingPathComponent("Contents/MacOS/\(name)")
        p.arguments = ["--user-data-dir=\(profile.path)"] + (ide ? ["--open-url", url.absoluteString] : [url.absoluteString])
        p.environment = environment(endpoint: GatewaySession.load()?.endpoint)
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); ClientProcesses.shared.add(p)
    }
}

// Route OAuth callbacks into our isolated profiles, then restore the user's previous handlers.
// Callback URLs are forwarded only in memory; they are never logged or saved.
enum LoginRouting {
    static let identifier = "local.geminigateway.mac"
    static var timer: Timer?
    static var active = Set<String>()
    static func current(_ scheme: String) -> String? {
        guard let url = URL(string: scheme + "://gateway-handler-probe"), let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        return Bundle(url: app)?.bundleIdentifier
    }
    static func claim(_ scheme: String) throws {
        let key = "previous-handler-" + scheme
        if !active.contains(scheme) {
            let previous = current(scheme)
            if previous != identifier { UserDefaults.standard.set(previous ?? (scheme == "antigravity" ? "com.google.antigravity" : "com.google.antigravity-ide"), forKey: key) }
            guard LSRegisterURL(Bundle.main.bundleURL as CFURL, true) == noErr else { throw GatewayError("Не удалось зарегистрировать обработчик входа в Google.") }
            active.insert(scheme)
        }
        guard LSSetDefaultHandlerForURLScheme(scheme as CFString, identifier as CFString) == noErr else { throw GatewayError("macOS не разрешила направить ответ авторизации в Gateway.") }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                for scheme in active where current(scheme) != identifier {
                    _ = LSSetDefaultHandlerForURLScheme(scheme as CFString, identifier as CFString)
                }
            }
        }
    }
    static func restore() {
        timer?.invalidate(); timer = nil
        for scheme in ["antigravity", "antigravity-ide"] {
            let key = "previous-handler-" + scheme
            if let previous = UserDefaults.standard.string(forKey: key) {
                let handler = current(scheme)
                if handler == identifier || handler == "local.geminigateway.desktop" { _ = LSSetDefaultHandlerForURLScheme(scheme as CFString, previous as CFString) }
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        active.removeAll()
    }
}

final class ClientProcesses {
    static let shared = ClientProcesses()
    private let lock = NSLock(); private var items: [Process] = []
    func add(_ p: Process) { lock.lock(); items.removeAll { !$0.isRunning }; items.append(p); lock.unlock() }
}
