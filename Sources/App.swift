import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    let proxy = NSTextField(string: "socks5://127.0.0.1:10808")
    let mode = NSPopUpButton(frame: .zero, pullsDown: false)
    let modeHint = NSTextField(wrappingLabelWithString: "")
    let status = NSTextField(labelWithString: "Выберите маршрут, затем запустите Antigravity.")
    let output = NSTextView()
    let patch = NSButton(checkboxWithTitle: "Обход региональной проверки клиента", target: nil, action: nil)
    var gateway: Gateway?
    var busy = false
    var buttons: [NSButton] = []
    var statusItem: NSStatusItem!
    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        NSApp.setActivationPolicy(.regular)
        LoginRouting.restore()
        let main = NSMenu(); let appMenu = NSMenu(); let item = NSMenuItem(); item.submenu = appMenu; main.addItem(item)
        appMenu.addItem(withTitle: "Показать Gemini Gateway", action: #selector(show), keyEquivalent: "0").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Завершить Gemini Gateway", action: #selector(quit), keyEquivalent: "q").target = self
        let edit = NSMenuItem(title: "Правка", action: nil, keyEquivalent: ""); let editMenu = NSMenu(title: "Правка"); edit.submenu = editMenu
        for (title, action, key) in [("Вырезать", "cut:", "x"), ("Копировать", "copy:", "c"), ("Вставить", "paste:", "v"), ("Выбрать всё", "selectAll:", "a")] { editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key) }
        main.addItem(edit); NSApp.mainMenu = main
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: "Gemini Gateway")
        let tray = NSMenu(); tray.addItem(withTitle: "Показать окно", action: #selector(show), keyEquivalent: "").target = self
        tray.addItem(withTitle: "Завершить шлюз", action: #selector(quit), keyEquivalent: "").target = self; statusItem.menu = tray
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 690, height: 690), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Gemini Gateway"; window.center(); window.delegate = self; window.isReleasedWhenClosed = false
        let content = NSView(); window.contentView = content
        window.appearance = NSAppearance(named: .aqua)
        content.wantsLayer = true; content.layer?.backgroundColor = NSColor(calibratedWhite: 0.96, alpha: 1).cgColor
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)])
        let title = NSTextField(labelWithString: "Gemini через ваш VPN")
        title.font = .systemFont(ofSize: 25, weight: .semibold); stack.addArrangedSubview(title)
        let subtitle = NSTextField(wrappingLabelWithString: "Один локальный шлюз для Antigravity Desktop и IDE. При первом запуске потребуется вход в Google в отдельном профиле.")
        subtitle.textColor = .secondaryLabelColor; stack.addArrangedSubview(subtitle)
        subtitle.widthAnchor.constraint(equalToConstant: 638).isActive = true
        proxy.placeholderString = "socks5://127.0.0.1:10808 или direct"; proxy.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        mode.addItems(withTitles: ["Happ / HTTP / SOCKS5", "AmneziaWG", "Другой системный VPN"])
        mode.target = self; mode.action = #selector(modeChanged)
        let modes = NSStackView(); modes.spacing = 10
        modes.addArrangedSubview(NSTextField(labelWithString: "Маршрут:")); modes.addArrangedSubview(mode)
        modes.addArrangedSubview(button("Открыть AmneziaWG", #selector(openAmnezia)))
        stack.addArrangedSubview(modes)
        selectMode(for: UserDefaults.standard.string(forKey: "proxy") ?? "socks5://127.0.0.1:10808")
        proxy.translatesAutoresizingMaskIntoConstraints = false; proxy.widthAnchor.constraint(equalToConstant: 638).isActive = true
        stack.addArrangedSubview(proxy)
        modeHint.font = .systemFont(ofSize: 11); modeHint.textColor = .secondaryLabelColor
        modeHint.widthAnchor.constraint(equalToConstant: 638).isActive = true; stack.addArrangedSubview(modeHint)
        let actions = NSStackView(); actions.spacing = 10
        actions.addArrangedSubview(button("Найти Happ", #selector(detect)))
        actions.addArrangedSubview(button("Проверить маршрут", #selector(testRoute)))
        actions.addArrangedSubview(button("Применить маршрут", #selector(applyRoute)))
        stack.addArrangedSubview(actions)
        patch.state = .on; stack.addArrangedSubview(patch)
        let launches = NSStackView(); launches.spacing = 10
        launches.addArrangedSubview(button("Открыть Desktop", #selector(desktop)))
        launches.addArrangedSubview(button("Открыть IDE", #selector(ide)))
        launches.addArrangedSubview(button("Остановить шлюз", #selector(stop)))
        stack.addArrangedSubview(launches)
        status.font = .systemFont(ofSize: 12, weight: .medium); status.lineBreakMode = .byWordWrapping; status.maximumNumberOfLines = 2
        stack.addArrangedSubview(status)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        output.isEditable = false; output.isSelectable = true; output.font = .monospacedSystemFont(ofSize: 11, weight: .regular); output.textContainerInset = NSSize(width: 10, height: 10)
        output.backgroundColor = .textBackgroundColor; output.textColor = .textColor
        output.frame = NSRect(x: 0, y: 0, width: 638, height: 140)
        output.isVerticallyResizable = true; output.isHorizontallyResizable = false
        output.autoresizingMask = [.width]
        output.minSize = NSSize(width: 0, height: 140)
        output.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        output.textContainer?.widthTracksTextView = true
        output.textContainer?.containerSize = NSSize(width: 638, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = output; scroll.translatesAutoresizingMaskIntoConstraints = false; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 638).isActive = true; stack.addArrangedSubview(scroll)
        let note = NSTextField(wrappingLabelWithString: "Шлюз должен оставаться запущенным. Крестик скрывает окно; выход — через меню. Запросы и токены не сохраняются. Desktop работает из отдельной копии; исходное приложение не изменяется.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor; stack.addArrangedSubview(note)
        note.widthAnchor.constraint(equalToConstant: 638).isActive = true
        show()
        log("Готово. Выберите Happ или AmneziaWG и проверьте подключение.")
        if CommandLine.arguments.contains("--ui-smoke-test"), let i = CommandLine.arguments.firstIndex(of: "--ui-smoke-test"), i + 1 < CommandLine.arguments.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if let view = self.window.contentView {
                    view.layoutSubtreeIfNeeded()
                    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1])) }
                    }
                }
                NSApp.terminate(nil)
            }
        } else if CommandLine.arguments.contains("--open-desktop") { desktop() }
        else if !resumeIfNeeded(), UserDefaults.standard.string(forKey: "proxy") == nil { detect() }
    }
    @discardableResult
    func resumeIfNeeded() -> Bool {
        let saved = GatewaySession.load()
        let desktop = GatewaySession.desktopRunning != nil
        let ide = GatewaySession.ideRunning
        guard (saved?.resume == true && (desktop || ide)) || (saved == nil && desktop) else { return false }
        let text = saved?.route ?? UserDefaults.standard.string(forKey: "proxy") ?? "socks5://127.0.0.1:10808"
        let patchWanted = saved?.patch ?? true
        selectMode(for: text); patch.state = patchWanted ? .on : .off
        work {
            _ = try self.ensureGateway(route: ProxyRoute(text), patchWanted: patchWanted)
            var failure: Error?
            DispatchQueue.main.sync {
                do {
                    if desktop { try LoginRouting.claim("antigravity") }
                    if ide && saved != nil { try LoginRouting.claim("antigravity-ide") }
                } catch { failure = error }
            }
            if let error = failure { throw error }
            return "Соединение открытого клиента восстановлено. Можно повторить запрос в чат."
        }
        return true
    }
    func ensureGateway(route: ProxyRoute, patchWanted: Bool) throws -> Gateway {
        if let existing = gateway {
            guard existing.route.label == route.label, existing.patchEnabled == patchWanted else {
                throw GatewayError("Чтобы сменить маршрут, сначала остановите шлюз.")
            }
            return existing
        }
        _ = try route.vpnInterface()
        // A surviving Desktop retains its command-line endpoint. Rebind that exact address.
        let address = (GatewaySession.desktopRunning != nil ? GatewaySession.desktopAddress() : nil)
            ?? GatewaySession.load().flatMap { try? GatewayAddress(endpoint: $0.endpoint) }
        let g = Gateway(route: route, patch: patchWanted, address: address, log: log)
        try g.start()
        do { try GatewaySession.remember(g) } catch { g.stop(); throw error }
        gateway = g; UserDefaults.standard.set(route.selection, forKey: "proxy")
        return g
    }
    func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action); b.bezelStyle = .rounded; buttons.append(b); return b
    }
    func log(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
            self.output.textStorage?.append(NSAttributedString(string: "\(formatter.string(from: Date()))  \(message)\n"))
            if self.output.string.count > 24000 { self.output.textStorage?.deleteCharacters(in: NSRange(location: 0, length: min(6000, self.output.textStorage!.length))) }
            self.output.scrollToEndOfDocument(nil)
        }
    }
    func work(_ operation: @escaping () throws -> String) {
        guard !busy else { return }; busy = true; buttons.forEach { $0.isEnabled = false }; proxy.isEnabled = false; mode.isEnabled = false; patch.isEnabled = false
        status.stringValue = "Выполняется…"
        DispatchQueue.global().async {
            let result: String
            do { result = try operation() } catch { result = error.localizedDescription }
            DispatchQueue.main.async { self.busy = false; self.buttons.forEach { $0.isEnabled = true }; self.mode.isEnabled = true; self.proxy.isEnabled = self.mode.indexOfSelectedItem == 0; self.patch.isEnabled = true; self.status.stringValue = result; self.log(result) }
        }
    }
    @objc func show() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func selectedRouteText() -> String {
        if mode.indexOfSelectedItem == 1 { return "amneziawg" }
        if mode.indexOfSelectedItem == 2 { return "direct" }
        return proxy.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func selectMode(for route: String) {
        mode.selectItem(at: route == "amneziawg" ? 1 : route == "direct" ? 2 : 0)
        if route != "direct" && route != "amneziawg" { proxy.stringValue = route }
        modeChanged()
    }
    @objc func modeChanged() {
        proxy.isEnabled = mode.indexOfSelectedItem == 0 && !busy
        proxy.isHidden = mode.indexOfSelectedItem != 0
        if mode.indexOfSelectedItem == 1 {
            modeHint.stringValue = "Включите туннель в AmneziaWG; Happ не требуется. Для открытого клиента нажмите «Применить маршрут»."
        } else if mode.indexOfSelectedItem == 2 {
            modeHint.stringValue = "Используются текущие системные маршруты macOS. Сначала подключите свой VPN."
        } else { modeHint.stringValue = "Для Happ обычно SOCKS5 на 10808. При смене маршрута нажмите «Применить маршрут»." }
    }
    @objc func openAmnezia() {
        let url = URL(fileURLWithPath: "/Applications/AmneziaWG.app")
        guard FileManager.default.fileExists(atPath: url.path) else { log("AmneziaWG не найден в /Applications."); return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if error != nil { self.log("Не удалось открыть AmneziaWG. Откройте его из папки «Программы».") }
        }
    }
    @objc func applyRoute() {
        let text = selectedRouteText(); let patchWanted = patch.state == .on
        work {
            let route = try ProxyRoute(text); _ = try route.vpnInterface()
            if let existing = self.gateway, existing.route.selection == route.selection, existing.patchEnabled == patchWanted { return "Маршрут уже активен: \(route.label)." }
            let old = self.gateway
            old?.stop(); self.gateway = nil
            do { _ = try self.ensureGateway(route: route, patchWanted: patchWanted) }
            catch {
                if let old = old { _ = try? self.ensureGateway(route: old.route, patchWanted: old.patchEnabled) }
                throw error
            }
            return "Маршрут применён: \(route.label). Повторите запрос в открытом Antigravity."
        }
    }
    @objc func detect() {
        work {
            let candidates = [(10808, "socks5"), (10809, "http"), (2080, "socks5"), (7890, "http"), (1080, "socks5"), (2081, "http")]
            for (port, scheme) in candidates {
                guard let fd = try? connectSocket("127.0.0.1", port, timeout: 1) else { continue }
                defer { close(fd) }
                configureSocket(fd, seconds: 2)
                if scheme == "socks5" {
                    guard (try? sendAll(fd, Data([5, 1, 0]))) != nil, (try? SocketReader(fd).exact(2)) == Data([5, 0]) else { continue }
                } else {
                    configureSocket(fd, seconds: 2)
                    guard (try? sendAll(fd, Data("CONNECT www.google.com:443 HTTP/1.1\r\nHost: www.google.com:443\r\n\r\n".utf8))) != nil,
                          let line = try? SocketReader(fd).line(), line.contains(" 200 ") else { continue }
                }
                let value = "\(scheme)://127.0.0.1:\(port)"
                DispatchQueue.main.async { self.selectMode(for: value) }
                return "Найден локальный \(scheme.uppercased())-прокси: порт \(port). Проверьте маршрут перед запуском."
            }
            throw GatewayError("Локальный прокси не найден. Включите Happ либо задайте адрес вручную.")
        }
    }
    @objc func testRoute() {
        let text = selectedRouteText()
        work {
            let route = try ProxyRoute(text)
            let interface = try route.vpnInterface()
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            p.arguments = ["-q", "--silent", "--output", "/dev/null", "--write-out", "%{http_code}", "--connect-timeout", "7", "--max-time", "15", "--proxy", route.curlValue, "--noproxy", "", "--proto", "=https", "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"]
            if let interface = interface { p.arguments! += ["--interface", "if!" + interface] }
            let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
            try p.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            let code = String(decoding: data, as: UTF8.self)
            guard p.terminationStatus == 0, ["400", "401", "403", "404", "405", "200"].contains(code) else { throw GatewayError("Google недоступен через \(route.label) (curl \(p.terminationStatus)). Проверьте VPN и DNS.") }
            return "\(route.label)\(interface.map { " (\($0))" } ?? ""): Google HTTP \(code), TLS работает. Доступность Gemini проверяется запросом в чат."
        }
    }
    @objc func desktop() { launch(ide: false) }
    @objc func ide() { launch(ide: true) }
    func launch(ide: Bool) {
        let text = selectedRouteText(); let patchWanted = patch.state == .on
        work {
            let route = try ProxyRoute(text)
            if let g = self.gateway, g.route.label != route.label || g.patchEnabled != patchWanted {
                throw GatewayError("Сначала нажмите «Применить маршрут». Клиент закрывать не требуется.")
            }
            _ = try self.ensureGateway(route: route, patchWanted: patchWanted)
            var routingError: Error?
            DispatchQueue.main.sync { do { try LoginRouting.claim(ide ? "antigravity-ide" : "antigravity") } catch { routingError = error } }
            if let error = routingError { throw error }
            try ClientLauncher.launch(ide: ide, gateway: self.gateway!, log: self.log)
            return "\(ide ? "IDE" : "Desktop") запущен. Шлюз активен; окно можно закрыть."
        }
    }
    @objc func stop() {
        guard !busy else { return }
        if gateway != nil {
            let alert = NSAlert(); alert.messageText = "Остановить шлюз?"; alert.informativeText = "Запущенные через него приложения потеряют соединение. Их можно закрыть и запустить заново через Gateway."
            alert.addButton(withTitle: "Остановить"); alert.addButton(withTitle: "Отмена")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        gateway?.stop(); gateway = nil
        if var saved = GatewaySession.load() { saved.resume = false; try? saved.save() }
        LoginRouting.restore(); status.stringValue = "Шлюз остановлен."; log("Шлюз остановлен.")
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if busy { return .terminateCancel }
        if gateway != nil {
            let alert = NSAlert(); alert.messageText = "Завершить Gemini Gateway?"; alert.informativeText = "Соединения запущенных через шлюз приложений будут закрыты."
            alert.addButton(withTitle: "Завершить"); alert.addButton(withTitle: "Отмена")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        gateway?.stop(); LoginRouting.restore(); return .terminateNow
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where ["antigravity", "antigravity-ide"].contains(url.scheme ?? "") {
            guard gateway != nil else { log("Для входа сначала запустите приложение кнопкой в Gateway и повторите авторизацию."); show(); continue }
            do { try ClientLauncher.forwardLogin(url); log("Ответ авторизации передан приложению.") }
            catch { log("Не удалось передать ответ авторизации. Повторите вход из приложения.") }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); return false }
}

@main
struct GatewayProgram {
static func main() {
let args = CommandLine.arguments
if args.contains("--client-start-test") {
    guard args.count >= 3 else { exit(2) }
    let p = Process(); p.executableURL = URL(fileURLWithPath: args[2]); p.arguments = Array(args.dropFirst(3))
    p.environment = clientEnvironment(ProcessInfo.processInfo.environment)
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    do { try p.run(); try verifyChildStayedRunning(p, grace: 0.3); p.terminate(); p.waitUntilExit(); print("running") }
    catch { print("failed"); exit(3) }
} else if args.contains("--vpn-status-test") {
    guard args.count == 4 else { exit(2) }
    do {
        let list = try String(contentsOfFile: args[2], encoding: .utf8)
        let status = try String(contentsOfFile: args[3], encoding: .utf8)
        guard AmneziaVPN.connectedService(in: list) != nil, let interface = AmneziaVPN.tunnelInterface(in: status) else { exit(3) }
        print(interface)
    } catch { exit(2) }
} else if args.contains("--socket-bind-test") {
    guard args.count == 4, let port = Int(args[2]), (1024...65535).contains(port) else { exit(2) }
    do { let fd = try connectSocket("127.0.0.1", port, interface: args[3]); close(fd) } catch { exit(3) }
} else if args.contains("--serve-test") {
    // Test harness is opt-in and accepts only a loopback upstream. Never used by the GUI.
    guard let index = args.firstIndex(of: "--upstream"), index + 1 < args.count,
          let u = URL(string: args[index + 1]), u.scheme == "http", u.host == "127.0.0.1", u.port != nil else { exit(2) }
    let proxyIndex = args.firstIndex(of: "--proxy")
    guard let route = try? ProxyRoute(proxyIndex.flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "direct") else { exit(2) }
    signal(SIGPIPE, SIG_IGN)
    let address: GatewayAddress?
    if let i = args.firstIndex(of: "--resume-endpoint") {
        guard i + 1 < args.count, let parsed = try? GatewayAddress(endpoint: args[i + 1]) else { exit(2) }
        address = parsed
    } else { address = nil }
    let g = Gateway(route: route, upstream: args[index + 1], address: address, log: { _ in })
    do {
        try g.start(); print(g.endpoint); fflush(stdout)
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        term.setEventHandler { g.stop(); exit(0) }; term.resume()
        withExtendedLifetime(term) { RunLoop.main.run() }
    } catch { exit(3) }
} else if args.contains("--prepare-desktop-test") {
    guard args.count == 4 else { exit(2) }
    do { let app = try DesktopCopy.prepare(source: URL(fileURLWithPath: args[2]), endpoint: args[3], log: { print($0) }); print(app.path) }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(3) }
} else if args.contains("--patch-asar-test") {
    guard args.count == 5 else { exit(2) }
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
        let (patched, hash) = try DesktopCopy.patchASAR(data, endpoint: args[4])
        try patched.write(to: URL(fileURLWithPath: args[3])); print(hash)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(3) }
} else {
    let application = NSApplication.shared
    let delegate = AppDelegate(); application.delegate = delegate; application.run()
}
}
}
