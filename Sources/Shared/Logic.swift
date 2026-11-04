import Foundation

enum Paths {
    static let statusFile = "/var/run/lanlock.status.json"
    static let socket = "/var/run/lanlock.sock"
    static let pfRule = "/var/run/lanlock.pf"
    static let pfToken = "/var/run/lanlock.pftoken"
    static let supportDir = "/Library/Application Support/LanLock"
    static let stateFile = "/Library/Application Support/LanLock/state.json"
}

struct HardwarePort: Equatable, Sendable {
    var name: String
    var device: String
}

enum PortRole: Equatable, Sendable {
    case wifi
    case tether
    case ignored
    case ordinary
}

struct InterfaceFacts: Equatable, Sendable {
    var statusActive: Bool
    var media: String
    var addresses: [String] = []
    var hasInet: Bool { !addresses.isEmpty }
}

struct NetworkService: Equatable, Sendable {
    var name: String
    var enabled: Bool
}

struct LockStatus: Codable, Equatable, Sendable {
    var holding: Bool
    var wifiDevice: String?
    var wifiOn: Bool?
    var blockTether: Bool
    var blockedServices: [String]
    var forcedOffCount: Int
    var message: String
    var updatedAt: TimeInterval
}

struct ShownNetwork: Equatable, Sendable, Identifiable {
    var id: String { device }
    var name: String
    var device: String
    var addresses: [String]
    var active: Bool
}

struct PersistentState: Codable, Equatable, Sendable {
    var pauseUntil: TimeInterval?
    var disabledServices: [String]
    var downedDevices: [String]
}

func normalizedServiceName(_ name: String) -> String {
    var value = name.lowercased()
    for dash in ["\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2212}", "\u{FE63}", "\u{FF0D}"] {
        value = value.replacingOccurrences(of: dash, with: "-")
    }
    return value
}

func isWifiServiceName(_ name: String) -> Bool {
    let value = normalizedServiceName(name)
    return value == "wi-fi" || value == "wifi" || value == "airport" || value.contains("wi-fi")
}

func portRole(name: String, device: String) -> PortRole {
    let port = normalizedServiceName(name)
    let iface = device.lowercased()
    if port == "wi-fi" || port == "wifi" || port == "airport" || port.contains("wi-fi") {
        return .wifi
    }
    if port.contains("iphone") || port.contains("ipad") || port.contains("apple mobile") {
        return .tether
    }
    if port.contains("bluetooth") {
        return .tether
    }
    if port.contains("bridge") || iface.hasPrefix("bridge") {
        return .ignored
    }
    if iface.hasPrefix("awdl") || iface.hasPrefix("llw") || iface.hasPrefix("utun")
        || iface == "lo0" || iface.hasPrefix("ap") || iface.hasPrefix("anpi")
    {
        return .ignored
    }
    return .ordinary
}

func isSafeInterfaceName(_ name: String) -> Bool {
    guard name.hasPrefix("en") else { return false }
    let suffix = name.dropFirst(2)
    return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
}

func isLanTrigger(port: HardwarePort, facts: InterfaceFacts?) -> Bool {
    guard portRole(name: port.name, device: port.device) == .ordinary else { return false }
    guard isSafeInterfaceName(port.device) else { return false }
    guard let facts, facts.statusActive else { return false }
    return facts.media.lowercased().contains("base")
}

func isTetherService(_ name: String) -> Bool {
    let value = name.lowercased()
    if value.contains("iphone") || value.contains("ipad") || value.contains("apple mobile") {
        return true
    }
    return value.contains("bluetooth pan")
}

func parseHardwarePorts(_ text: String) -> [HardwarePort] {
    var ports: [HardwarePort] = []
    var name: String?
    var device: String?
    func flush() {
        if let name, let device, !name.isEmpty, !device.isEmpty {
            ports.append(HardwarePort(name: name, device: device))
        }
        name = nil
        device = nil
    }
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("VLAN Configurations") {
            flush()
            break
        }
        if line.hasPrefix("Hardware Port:") {
            flush()
            name = String(line.dropFirst("Hardware Port:".count)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("Device:") {
            device = String(line.dropFirst("Device:".count)).trimmingCharacters(in: .whitespaces)
        } else if line.isEmpty {
            flush()
        }
    }
    flush()
    return ports
}

func parseInterfaces(_ text: String) -> [String: InterfaceFacts] {
    var map: [String: InterfaceFacts] = [:]
    var current: String?
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(raw)
        if let name = interfaceName(from: line) {
            current = name
            if map[name] == nil {
                map[name] = InterfaceFacts(statusActive: false, media: "")
            }
            continue
        }
        guard let current else { continue }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var facts = map[current] ?? InterfaceFacts(statusActive: false, media: "")
        if trimmed.hasPrefix("status:") {
            let value = trimmed.dropFirst("status:".count).trimmingCharacters(in: .whitespaces)
            facts.statusActive = value == "active"
        } else if trimmed.hasPrefix("media:") {
            facts.media = trimmed.dropFirst("media:".count).trimmingCharacters(in: .whitespaces)
        } else if trimmed.hasPrefix("inet ") {
            let parts = trimmed.split(separator: " ")
            if parts.count >= 2 {
                let address = String(parts[1])
                if address != "127.0.0.1" && !facts.addresses.contains(address) {
                    facts.addresses.append(address)
                }
            }
        }
        map[current] = facts
    }
    return map
}

func shownNetworks(portsText: String, ifconfigText: String) -> [ShownNetwork] {
    let ports = parseHardwarePorts(portsText)
    let ifaces = parseInterfaces(ifconfigText)
    var rows: [ShownNetwork] = []
    var seen = Set<String>()
    for port in ports {
        let role = portRole(name: port.name, device: port.device)
        if role == .ignored { continue }
        seen.insert(port.device)
        let facts = ifaces[port.device]
        let addresses = facts?.addresses ?? []
        if role != .wifi && role != .tether && addresses.isEmpty { continue }
        rows.append(ShownNetwork(
            name: port.name,
            device: port.device,
            addresses: addresses,
            active: facts?.statusActive ?? false
        ))
    }
    let extras = ifaces.keys.filter { device in
        !seen.contains(device) && !(ifaces[device]?.addresses.isEmpty ?? true) && !isBackgroundInterface(device)
    }.sorted()
    for device in extras {
        let facts = ifaces[device]!
        rows.append(ShownNetwork(name: device, device: device, addresses: facts.addresses, active: facts.statusActive))
    }
    return rows.sorted { lhs, rhs in
        let left = networkRank(lhs)
        let right = networkRank(rhs)
        if left != right { return left < right }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}

func isBackgroundInterface(_ name: String) -> Bool {
    let value = name.lowercased()
    let prefixes = ["lo", "awdl", "llw", "anpi", "gif", "stf", "bridge", "pktap", "ipsec", "ap"]
    return prefixes.contains { value.hasPrefix($0) }
}

private func networkRank(_ row: ShownNetwork) -> Int {
    switch portRole(name: row.name, device: row.device) {
    case .wifi: return 0
    case .tether: return 1
    default: return 2
    }
}

func parseServices(_ text: String) -> [NetworkService] {
    var services: [NetworkService] = []
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty || line.hasPrefix("An asterisk") {
            continue
        }
        if line.hasPrefix("*") {
            let name = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                services.append(NetworkService(name: name, enabled: false))
            }
        } else {
            services.append(NetworkService(name: line, enabled: true))
        }
    }
    return services
}

func parseWifiPower(_ text: String) -> Bool? {
    if text.contains(": On") { return true }
    if text.contains(": Off") { return false }
    return nil
}

func parsePfToken(_ text: String) -> String? {
    for raw in text.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        for prefix in ["Token :", "Token:"] {
            if line.hasPrefix(prefix) {
                let token = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                if !token.isEmpty { return String(token) }
            }
        }
    }
    return nil
}

private func interfaceName(from line: String) -> String? {
    guard let first = line.first, !first.isWhitespace else { return nil }
    guard let colon = line.firstIndex(of: ":") else { return nil }
    let name = String(line[..<colon])
    guard !name.isEmpty else { return nil }
    guard name.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
    return name
}
