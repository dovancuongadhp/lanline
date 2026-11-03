import Foundation

struct ShellResult {
    var code: Int32
    var output: String
}

enum Shell {
    static func run(_ launchPath: String, _ args: [String]) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return ShellResult(code: 127, output: error.localizedDescription)
        }
        let deadline = Date().addingTimeInterval(8)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            return ShellResult(code: 124, output: "timeout \(launchPath)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return ShellResult(code: process.terminationStatus, output: String(data: data, encoding: .utf8) ?? "")
    }
}

final class Engine: @unchecked Sendable {
    let writesChanges: Bool
    private let lock = NSLock()
    private var holdUntil: Date?
    private var blockTether = true
    private var wasHolding = false
    private var disabledServices: [String] = []
    private var forcedOffCount = 0
    private var wifiDevice: String?
    private var wifiDeviceChecked = Date.distantPast
    private var pfToken: String?
    private var pfDevice: String?
    private var lastWritten: LockStatus?
    private var lastStatusWrite = Date.distantPast
    private var lastLogAt: [String: Date] = [:]

    init(writesChanges: Bool) {
        self.writesChanges = writesChanges
        if writesChanges {
            cleanupPreviousSession()
        }
    }

    func tick() {
        lock.lock()
        defer { lock.unlock() }
        reconcile()
    }

    func handle(command: String) -> String {
        let parts = command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .map(String.init)
        guard let verb = parts.first?.uppercased() else { return "ERR empty" }
        lock.lock()
        defer { lock.unlock() }
        switch verb {
        case "HOLD":
            blockTether = parts.count < 2 || parts[1] != "0"
            let starting = !isHolding
            holdUntil = Date().addingTimeInterval(2.5)
            if starting { forcedOffCount = 0 }
            return "OK"
        case "RELEASE":
            holdUntil = nil
            reconcile()
            return "OK"
        case "PING":
            return "OK"
        default:
            return "ERR lệnh không hỗ trợ"
        }
    }

    func releaseAll() {
        lock.lock()
        defer { lock.unlock() }
        holdUntil = nil
        clearPacketFilter()
        restoreTether()
        publish(holding: false, wifiOn: nil, message: "Đã thả khóa")
        log("Đã gỡ khóa")
    }

    func printDryRun() {
        let ports = Shell.run("/usr/sbin/networksetup", ["-listallhardwareports"])
        let device = ports.code == 0
            ? parseHardwarePorts(ports.output).first { portRole(name: $0.name, device: $0.device) == .wifi }?.device
            : nil
        var power = "không rõ"
        if let device {
            let result = Shell.run("/usr/sbin/networksetup", ["-getairportpower", device])
            if result.code == 0, let on = parseWifiPower(result.output) {
                power = on ? "On" : "Off"
            }
        }
        print("Wi‑Fi: \(device ?? "không có"), nguồn \(power)")
        print("Wi‑Fi chỉ bị khóa khi bật công tắc Khóa Wi‑Fi trong LanLock.")
    }

    private var isHolding: Bool {
        holdUntil.map { Date() < $0 } ?? false
    }

    private func reconcile() {
        let holding = isHolding
        var wifiOn: Bool?
        let releasing = !holding && wasHolding
        if holding {
            wifiOn = enforceWifi()
            if blockTether {
                disableTether()
            } else {
                restoreTether()
            }
        } else if releasing || !disabledServices.isEmpty || pfDevice != nil {
            clearPacketFilter()
            restoreTether()
            restoreWifiServices()
        }
        if holding != wasHolding {
            log(holding ? "Bắt đầu chặn mạng ngoài" : "Đã mở chặn. Wi‑Fi vẫn tắt, tự bật khi cần.")
            wasHolding = holding
        }
        let message = holding ? "Đang chặn mạng ngoài" : "Chưa chặn"
        publish(holding: holding, wifiOn: wifiOn, message: message)
    }

    private func enforceWifi() -> Bool? {
        if wifiDevice == nil || Date().timeIntervalSince(wifiDeviceChecked) > 5 {
            refreshWifiDevice()
        }
        guard let device = wifiDevice, isSafeInterfaceName(device) else { return nil }
        loadPacketBlock(device: device)
        disableWifiService()
        let power = Shell.run("/usr/sbin/networksetup", ["-getairportpower", device])
        guard power.code == 0, let on = parseWifiPower(power.output) else { return nil }
        guard on else { return false }
        let off = Shell.run("/usr/sbin/networksetup", ["-setairportpower", device, "off"])
        if off.code == 0 {
            forcedOffCount += 1
            log("Đã tắt Wi‑Fi")
            return false
        }
        logSometimes("wifi-off", "Không tắt được Wi‑Fi: \(oneLine(off.output))")
        return true
    }

    private func disableWifiService() {
        let services = Shell.run("/usr/sbin/networksetup", ["-listallnetworkservices"])
        guard services.code == 0 else { return }
        for service in parseServices(services.output) where service.enabled && isWifiService(service.name) {
            let result = Shell.run("/usr/sbin/networksetup", ["-setnetworkserviceenabled", service.name, "off"])
            if result.code == 0 {
                if !disabledServices.contains(service.name) {
                    disabledServices.append(service.name)
                    persist()
                    log("Đã tắt dịch vụ \(service.name)")
                }
            } else {
                logSometimes("wifi-service", "Không tắt được dịch vụ \(service.name): \(oneLine(result.output))")
            }
        }
    }

    private func isWifiService(_ name: String) -> Bool {
        let value = name.lowercased()
        return value == "wi-fi" || value == "wifi" || value == "airport" || value.contains("wi-fi")
    }

    private func loadPacketBlock(device: String) {
        guard isSafeInterfaceName(device) else { return }
        ensurePfEnabled()
        if pfDevice == device { return }
        let rule = "block drop quick on \(device) all\n"
        do {
            try Data(rule.utf8).write(to: URL(fileURLWithPath: Paths.pfRule), options: .atomic)
        } catch {
            log("Không ghi được rule pf: \(error.localizedDescription)")
            return
        }
        let loaded = Shell.run("/sbin/pfctl", ["-a", "com.apple/lanlock", "-f", Paths.pfRule])
        if loaded.code == 0 {
            pfDevice = device
            log("Đã chặn gói tin trên \(device)")
        } else {
            logSometimes("pf", "pfctl không nạp được rule: \(oneLine(loaded.output))")
        }
    }

    private func ensurePfEnabled() {
        if pfToken != nil { return }
        if let text = try? String(contentsOfFile: Paths.pfToken, encoding: .utf8) {
            let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                pfToken = token
                return
            }
        }
        let result = Shell.run("/sbin/pfctl", ["-E"])
        guard let token = parsePfToken(result.output) else {
            logSometimes("pf-enable", "pfctl -E không trả token: \(oneLine(result.output))")
            return
        }
        pfToken = token
        try? Data(token.utf8).write(to: URL(fileURLWithPath: Paths.pfToken), options: .atomic)
    }

    private func refreshWifiDevice() {
        let result = Shell.run("/usr/sbin/networksetup", ["-listallhardwareports"])
        wifiDeviceChecked = Date()
        guard result.code == 0 else { return }
        wifiDevice = parseHardwarePorts(result.output)
            .first { portRole(name: $0.name, device: $0.device) == .wifi }?
            .device
    }

    private func disableTether() {
        let services = Shell.run("/usr/sbin/networksetup", ["-listallnetworkservices"])
        guard services.code == 0 else { return }
        for service in parseServices(services.output) where service.enabled && isTetherService(service.name) {
            let result = Shell.run("/usr/sbin/networksetup", ["-setnetworkserviceenabled", service.name, "off"])
            if result.code == 0 {
                if !disabledServices.contains(service.name) {
                    disabledServices.append(service.name)
                    persist()
                    log("Đã tắt \(service.name)")
                }
            } else {
                logSometimes("tether-\(service.name)", "Không tắt được \(service.name): \(oneLine(result.output))")
            }
        }
    }

    private func restoreTether() {
        restoreServices(disabledServices.filter(isTetherService))
    }

    private func restoreWifiServices() {
        restoreServices(disabledServices.filter(isWifiService))
    }

    private func restoreServices(_ names: [String]) {
        guard !names.isEmpty else { return }
        for name in names {
            let result = Shell.run("/usr/sbin/networksetup", ["-setnetworkserviceenabled", name, "on"])
            if result.code == 0 {
                log("Đã bật lại \(name)")
            } else {
                log("Không bật lại được \(name): \(oneLine(result.output))")
            }
            disabledServices.removeAll { $0 == name }
        }
        persist()
    }

    private func cleanupPreviousSession() {
        clearPacketFilter()
        if let state = readState() {
            for device in state.downedDevices where isSafeInterfaceName(device) {
                _ = Shell.run("/sbin/ifconfig", [device, "up"])
            }
            disabledServices = state.disabledServices
        }
        restoreTether()
        restoreWifiServices()
    }

    private func clearPacketFilter() {
        _ = Shell.run("/sbin/pfctl", ["-a", "com.apple/lanlock", "-F", "all"])
        if let text = try? String(contentsOfFile: Paths.pfToken, encoding: .utf8) {
            let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                _ = Shell.run("/sbin/pfctl", ["-X", token])
            }
        }
        try? FileManager.default.removeItem(atPath: Paths.pfToken)
        try? FileManager.default.removeItem(atPath: Paths.pfRule)
        pfToken = nil
        pfDevice = nil
    }

    private func readState() -> PersistentState? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Paths.stateFile)) else { return nil }
        return try? JSONDecoder().decode(PersistentState.self, from: data)
    }

    private func persist() {
        guard writesChanges else { return }
        let state = PersistentState(pauseUntil: nil, disabledServices: disabledServices, downedDevices: [])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(atPath: Paths.supportDir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: Paths.stateFile), options: .atomic)
    }

    private func publish(holding: Bool, wifiOn: Bool?, message: String) {
        guard writesChanges else { return }
        let status = LockStatus(
            holding: holding,
            wifiDevice: wifiDevice,
            wifiOn: wifiOn,
            blockTether: blockTether,
            blockedServices: disabledServices,
            forcedOffCount: forcedOffCount,
            message: message,
            updatedAt: Date().timeIntervalSince1970
        )
        let changed: Bool
        if var previous = lastWritten {
            previous.updatedAt = 0
            var current = status
            current.updatedAt = 0
            changed = previous != current
        } else {
            changed = true
        }
        if !changed && Date().timeIntervalSince(lastStatusWrite) < 1 { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(status) else { return }
        try? data.write(to: URL(fileURLWithPath: Paths.statusFile), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: Paths.statusFile)
        lastWritten = status
        lastStatusWrite = Date()
    }

    private func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardOutput.write(Data("\(stamp) \(message)\n".utf8))
    }

    private func logSometimes(_ key: String, _ message: String) {
        let now = Date()
        if let last = lastLogAt[key], now.timeIntervalSince(last) < 30 { return }
        lastLogAt[key] = now
        log(message)
    }

    private func oneLine(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
