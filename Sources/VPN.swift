import Foundation

enum AmneziaVPN {
    private static func command(_ arguments: [String]) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil"); p.arguments = arguments
        let output = Pipe(); p.standardOutput = output; p.standardError = FileHandle.nullDevice
        try p.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw GatewayError("macOS не смогла проверить подключение AmneziaWG.") }
        return String(decoding: data, as: UTF8.self)
    }
    static func connectedService(in list: String) -> String? {
        let pattern = #"\(Connected\)\s+([0-9A-Fa-f-]{36})\s+VPN\s+\(org\.amnezia\.awg\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern), let match = expression.firstMatch(in: list, range: NSRange(list.startIndex..., in: list)), let range = Range(match.range(at: 1), in: list) else { return nil }
        return String(list[range])
    }
    static func tunnelInterface(in status: String) -> String? {
        guard status.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) == "Connected" else { return nil }
        let pattern = #"(?m)^\s*InterfaceName\s*:\s*(utun[0-9]+)\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern), let match = expression.firstMatch(in: status, range: NSRange(status.startIndex..., in: status)), let range = Range(match.range(at: 1), in: status) else { return nil }
        return String(status[range])
    }
    static func interface() throws -> String {
        guard let service = connectedService(in: try command(["--nc", "list"])),
              let interface = tunnelInterface(in: try command(["--nc", "status", service])) else {
            throw GatewayError("AmneziaWG не подключён. Откройте AmneziaWG, включите туннель и повторите проверку.")
        }
        return interface
    }
}
