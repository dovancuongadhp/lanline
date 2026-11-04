import AppKit
import LocalAuthentication
import Security
import SwiftUI

final class PanelModel: ObservableObject, @unchecked Sendable {
    static let shared = PanelModel()

    @Published var rows: [ShownNetwork] = []
    @Published var wifiOn: Bool?
    @Published var forcedOffCount = 0
    @Published var blockedServices: [String] = []
    @Published var daemonOK = true
    @Published var notice: String?
    @Published var lockEnabled = false {
        didSet {
            lock.lock()
            lockFlag = lockEnabled
            lock.unlock()
        }
    }
    @Published var showMenuBar: Bool {
        didSet { UserDefaults.standard.set(showMenuBar, forKey: "showMenuBar") }
    }
    @Published var blockTether: Bool {
        didSet {
            UserDefaults.standard.set(blockTether, forKey: "blockTether")
            lock.lock()
            tetherFlag = blockTether
            lock.unlock()
        }
    }

    func requestChange(to enabled: Bool) {
        if enabled || !lockEnabled {
            lockEnabled = enabled
            return
        }
        authenticate(reason: "Mở chặn mạng ngoài") { [weak self] ok in
            guard ok else { return }
            self?.lockEnabled = false
        }
    }

    func authenticate(reason: String, completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        context.localizedCancelTitle = "Huỷ"
        context.localizedFallbackTitle = "Dùng mật khẩu"
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            NSApp.activate()
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                DispatchQueue.main.async { completion(success) }
            }
            return
        }
        DispatchQueue.main.async {
            completion(self.authenticateAdmin())
        }
    }

    private func authenticateAdmin() -> Bool {
        var authorization: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authorization) == errAuthorizationSuccess,
              let authorization else { return false }
        defer { AuthorizationFree(authorization, [.destroyRights]) }
        return "system.privilege.admin".withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                let flags: AuthorizationFlags = [.interactionAllowed, .extendRights]
                return AuthorizationCopyRights(authorization, &rights, nil, flags, nil) == errAuthorizationSuccess
            }
        }
    }

    private let lock = NSLock()
    private var lockFlag = false
    private var tetherFlag: Bool
    private var stopped = false
    private var started = false

    private init() {
        let tether = UserDefaults.standard.object(forKey: "blockTether") as? Bool ?? true
        blockTether = tether
        tetherFlag = tether
        let menu = UserDefaults.standard.object(forKey: "showMenuBar") as? Bool ?? true
        showMenuBar = menu
    }

    func startIfNeeded() {
        lock.lock()
        let shouldStart = !started
        started = true
        lock.unlock()
        guard shouldStart else { return }
        Thread.detachNewThread { [weak self] in
            self?.loop()
        }
    }

    func stopAndRelease() {
        lock.lock()
        stopped = true
        lock.unlock()
        _ = ControlClient.send("RELEASE")
    }

    private func loop() {
        _ = ControlClient.send("RELEASE")
        var tick = 0
        var wasLocking = false
        while !isStopped() {
            let locking = wantsLock()
            var reply = "OK"
            if locking {
                reply = ControlClient.send("HOLD \(wantsTetherBlock() ? "1" : "0")")
                wasLocking = true
            } else if wasLocking {
                reply = ControlClient.send("RELEASE")
                wasLocking = false
            }
            let status = tick % 2 == 0 ? readStatus() : nil
            let snapshot = tick % 2 == 0 ? readNetworks() : nil
            let fresh = status.map { Date().timeIntervalSince1970 - $0.updatedAt < 5 } ?? false
            DispatchQueue.main.async {
                if locking {
                    self.daemonOK = reply == "OK"
                    self.notice = reply == "OK" ? nil : "Dịch vụ khóa chưa chạy, nên Wi‑Fi vẫn bật được."
                } else {
                    self.daemonOK = fresh || reply == "OK"
                    self.notice = nil
                }
                if let snapshot {
                    self.rows = snapshot
                }
                if let status {
                    self.wifiOn = status.wifiOn
                    self.forcedOffCount = status.forcedOffCount
                    self.blockedServices = status.blockedServices
                }
            }
            tick += 1
            Thread.sleep(forTimeInterval: 0.45)
        }
    }

    private func isStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func wantsLock() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return lockFlag
    }

    private func wantsTetherBlock() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tetherFlag
    }

    private func readStatus() -> LockStatus? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Paths.statusFile)) else { return nil }
        return try? JSONDecoder().decode(LockStatus.self, from: data)
    }

    private func readNetworks() -> [ShownNetwork] {
        let ports = command("/usr/sbin/networksetup", ["-listallhardwareports"])
        let interfaces = command("/sbin/ifconfig", ["-a"])
        return shownNetworks(portsText: ports, ifconfigText: interfaces)
    }

    private func command(_ path: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

@main
struct LanLockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var model = PanelModel.shared

    init() {
        PanelModel.shared.startIfNeeded()
    }

    var body: some Scene {
        Window("Chặn mạng ngoài", id: "main") {
            MainWindow(model: model, appDelegate: appDelegate)
        }
        .defaultSize(width: 520, height: 300)
        .windowResizability(.contentSize)
    }
}

enum MenuGlyph {
    static func image(locked: Bool) -> NSImage {
        let side: CGFloat = 16
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let path = shieldPath(in: rect.insetBy(dx: 2.2, dy: 1.6))
            NSColor.black.set()
            if locked {
                path.fill()
            } else {
                path.lineWidth = 1.35
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func shieldPath(in rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.maxY - rect.height * 0.16))
        path.curve(
            to: NSPoint(x: rect.midX, y: rect.maxY),
            controlPoint1: NSPoint(x: rect.minX + rect.width * 0.08, y: rect.maxY),
            controlPoint2: NSPoint(x: rect.midX - rect.width * 0.22, y: rect.maxY)
        )
        path.curve(
            to: NSPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.16),
            controlPoint1: NSPoint(x: rect.midX + rect.width * 0.22, y: rect.maxY),
            controlPoint2: NSPoint(x: rect.maxX - rect.width * 0.08, y: rect.maxY)
        )
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.46))
        path.curve(
            to: NSPoint(x: rect.midX, y: rect.minY),
            controlPoint1: NSPoint(x: rect.maxX, y: rect.midY - rect.height * 0.02),
            controlPoint2: NSPoint(x: rect.midX + rect.width * 0.18, y: rect.minY + rect.height * 0.12)
        )
        path.curve(
            to: NSPoint(x: rect.minX, y: rect.maxY - rect.height * 0.46),
            controlPoint1: NSPoint(x: rect.midX - rect.width * 0.18, y: rect.minY + rect.height * 0.12),
            controlPoint2: NSPoint(x: rect.minX, y: rect.midY - rect.height * 0.02)
        )
        path.close()
        return path
    }
}

enum DaemonSetup {
    static func ensure() {
        if ControlClient.send("PING") == "OK" { return }
        let app = Bundle.main.bundleURL
        guard app.path.hasPrefix("/Applications/") else {
            let alert = NSAlert()
            alert.messageText = "Kéo LanLock vào Applications"
            alert.informativeText = "App cần nằm trong thư mục Ứng dụng thì mới chặn được Wi‑Fi. Xóa app ở đó là gỡ được."
            alert.runModal()
            return
        }
        let executable = app.appendingPathComponent("Contents/MacOS/lanlockd").path
        guard FileManager.default.isExecutableFile(atPath: executable) else { return }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        <key>Label</key><string>com.lanlock.daemon</string>
        <key>ProgramArguments</key>
        <array><string>\(executable)</string></array>
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key><true/>
        <key>ThrottleInterval</key><integer>2</integer>
        <key>StandardOutPath</key><string>/Library/Logs/LanLock/daemon.log</string>
        <key>StandardErrorPath</key><string>/Library/Logs/LanLock/daemon.log</string>
        </dict>
        </plist>
        """
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        let plistURL = directory.appendingPathComponent("com.lanlock.daemon.plist")
        let scriptURL = directory.appendingPathComponent("lanlock-install.sh")
        let script = """
        #!/bin/bash
        set -e
        mkdir -p /Library/Logs/LanLock
        cp \(shellQuoted(plistURL.path)) /Library/LaunchDaemons/com.lanlock.daemon.plist
        chown root:wheel /Library/LaunchDaemons/com.lanlock.daemon.plist
        chmod 644 /Library/LaunchDaemons/com.lanlock.daemon.plist
        launchctl bootout system/com.lanlock.daemon >/dev/null 2>&1 || true
        launchctl bootstrap system /Library/LaunchDaemons/com.lanlock.daemon.plist
        launchctl enable system/com.lanlock.daemon || true
        launchctl kickstart -k system/com.lanlock.daemon
        """
        try? plist.data(using: .utf8)?.write(to: plistURL)
        try? script.data(using: .utf8)?.write(to: scriptURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let source = "do shell script \"bash \(shellQuoted(scriptURL.path))\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

final class StatusBarController: NSObject, NSMenuDelegate {
    static let shared = StatusBarController()
    private var item: NSStatusItem?
    private let menu = NSMenu()
    var reopen: () -> Void = {}

    override init() {
        super.init()
        menu.delegate = self
    }

    func sync() {
        let model = PanelModel.shared
        guard model.showMenuBar else {
            remove()
            return
        }
        if item == nil {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        }
        let button = item?.button
        button?.image = MenuGlyph.image(locked: model.lockEnabled)
        button?.imageScaling = .scaleNone
        button?.toolTip = model.lockEnabled ? "Đang chặn mạng ngoài" : "Chưa chặn mạng ngoài"
        item?.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let rows = PanelModel.shared.rows
        if rows.isEmpty {
            let empty = NSMenuItem(title: "Chưa có địa chỉ IP", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for row in rows {
                let ip = row.addresses.isEmpty ? "không có IP" : row.addresses.joined(separator: ", ")
                let entry = NSMenuItem(title: "\(row.name)   \(ip)", action: nil, keyEquivalent: "")
                entry.isEnabled = false
                menu.addItem(entry)
            }
        }
        menu.addItem(.separator())
        menu.addItem(checkedItem("Chặn mạng ngoài", checked: PanelModel.shared.lockEnabled, action: #selector(toggleLock)))
        menu.addItem(menuItem("Hiện bảng điều khiển", action: #selector(showPanel)))
    }

    private func remove() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }

    private func menuItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        return entry
    }

    private func checkedItem(_ title: String, checked: Bool, action: Selector) -> NSMenuItem {
        let entry = menuItem(title, action: action)
        entry.state = checked ? .on : .off
        return entry
    }

    @objc private func toggleLock() {
        let model = PanelModel.shared
        model.requestChange(to: !model.lockEnabled)
    }

    @objc private func showPanel() { reopen() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var reopen: () -> Void = {}

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        StatusBarController.shared.reopen = { [weak self] in self?.reopen() }
        StatusBarController.shared.sync()
        DaemonSetup.ensure()
        DispatchQueue.main.async {
            self.reopen()
            for window in NSApp.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate()
        }
    }

    private var allowQuit = false
    private var promptingQuit = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if allowQuit { return .terminateNow }
        if promptingQuit { return .terminateLater }
        promptingQuit = true
        PanelModel.shared.authenticate(reason: "Thoát LanLock") { ok in
            self.promptingQuit = false
            if ok { self.allowQuit = true }
            NSApp.reply(toApplicationShouldTerminate: ok)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { reopen() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        PanelModel.shared.stopAndRelease()
    }
}

struct MainWindow: View {
    @ObservedObject var model: PanelModel
    var appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ControlPanel(model: model)
            .onAppear {
                appDelegate.reopen = {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                StatusBarController.shared.reopen = { [appDelegate] in
                    appDelegate.reopen()
                }
                StatusBarController.shared.sync()
            }
            .onChange(of: model.lockEnabled) { _, _ in
                StatusBarController.shared.sync()
            }
            .onChange(of: model.showMenuBar) { _, _ in
                StatusBarController.shared.sync()
            }
    }
}

struct ControlPanel: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            networkList
            Toggle(isOn: $model.blockTether) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cũng tắt mạng iPhone và Bluetooth PAN")
                    Text("Chỉ áp dụng khi đang chặn mạng ngoài.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle("Hiện icon trên menu bar", isOn: $model.showMenuBar)
            if model.lockEnabled {
                Text(model.forcedOffCount == 0
                    ? "Wi‑Fi đã bị tắt và gói tin trên cổng đó bị chặn."
                    : "Đã tắt lại Wi‑Fi \(model.forcedOffCount) lần. Gói tin vẫn bị chặn nên không ra mạng.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = model.notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Tắt công tắc phải dùng mật khẩu hoặc vân tay. Thoát chỉ bằng Command–Q, cũng phải xác nhận. Đóng cửa sổ chỉ giấu bảng.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Tác giả: Đỗ Văn Cường")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(20)
        .frame(width: 520, alignment: .topLeading)
        .fixedSize(horizontal: true, vertical: true)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { fitWindow(to: proxy.size) }
                    .onChange(of: proxy.size) { _, size in fitWindow(to: size) }
            }
        }
    }

    private func fitWindow(to size: CGSize) {
        guard size.width > 200, size.height > 120 else { return }
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.title == "Chặn mạng ngoài" }) else { return }
            window.styleMask.remove(.resizable)
            let current = window.contentRect(forFrameRect: window.frame).size
            guard abs(current.width - size.width) > 1 || abs(current.height - size.height) > 1 else { return }
            window.setContentSize(size)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: model.lockEnabled ? "lock.shield.fill" : "shield")
                .font(.title)
                .foregroundStyle(model.lockEnabled ? Color.red : Color.secondary)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Chặn mạng ngoài")
                    .font(.title2.bold())
                Text(model.lockEnabled
                    ? "Đang bật, để khỏi bật nhầm Wi‑Fi khi đang dùng mạng nội bộ."
                    : "Tắt. Bật lên khi đang cắm mạng nội bộ, để Wi‑Fi không ra internet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: lockBinding)
                .toggleStyle(.switch)
                .controlSize(.large)
                .labelsHidden()
        }
    }

    private var lockBinding: Binding<Bool> {
        Binding(
            get: { model.lockEnabled },
            set: { model.requestChange(to: $0) }
        )
    }

    private var networkList: some View {
        GroupBox("Mạng hiện tại") {
            if model.rows.isEmpty {
                Text("Chưa thấy địa chỉ IP nào.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.rows) { row in
                        networkRow(row)
                        if row.id != model.rows.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func networkRow(_ row: ShownNetwork) -> some View {
        let ip = row.addresses.isEmpty ? "không có IP" : row.addresses.joined(separator: ", ")
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                Text(row.device)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(ip)
                .font(.body.monospaced())
                .foregroundStyle(row.addresses.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
            if !row.addresses.isEmpty {
                Button("Chép") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ip, forType: .string)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 6)
    }
}
