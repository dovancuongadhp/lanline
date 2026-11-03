import Foundation

enum SelfTest {
    static func run() -> Bool {
        var failed = 0
        failed += expect(portRole(name: "Wi-Fi", device: "en0") == .wifi, "Wi-Fi là wifi")
        failed += expect(portRole(name: "iPhone USB", device: "en8") == .tether, "iPhone USB là tether")
        failed += expect(portRole(name: "Bluetooth PAN", device: "en9") == .tether, "Bluetooth PAN là tether")
        failed += expect(portRole(name: "Thunderbolt Bridge", device: "bridge0") == .ignored, "Thunderbolt Bridge bị bỏ")
        failed += expect(portRole(name: "Ethernet Adapter (en5)", device: "en5") == .ordinary, "Ethernet Adapter là cổng thường")
        failed += expect(portRole(name: "AX88179A", device: "en7") == .ordinary, "USB LAN là cổng thường")

        let idle = InterfaceFacts(statusActive: false, media: "none")
        let copper = InterfaceFacts(statusActive: true, media: "autoselect (1000baseT <full-duplex>)", addresses: ["10.0.0.2"])
        let display = InterfaceFacts(statusActive: true, media: "autoselect <full-duplex>")
        let wifiUp = InterfaceFacts(statusActive: true, media: "autoselect", addresses: ["192.168.1.20"])
        let phone = InterfaceFacts(statusActive: true, media: "autoselect (100baseTX <full-duplex>)", addresses: ["172.20.10.2"])

        failed += expect(!isLanTrigger(port: HardwarePort(name: "Wi-Fi", device: "en0"), facts: wifiUp), "Wi-Fi đang dùng không phải LAN")
        failed += expect(!isLanTrigger(port: HardwarePort(name: "Ethernet Adapter (en5)", device: "en5"), facts: idle), "Ethernet chưa cắm cáp không khóa")
        failed += expect(isLanTrigger(port: HardwarePort(name: "Ethernet Adapter (en5)", device: "en5"), facts: copper), "Ethernet có link thì khóa")
        failed += expect(isLanTrigger(port: HardwarePort(name: "AX88179A", device: "en7"), facts: copper), "USB LAN có link thì khóa")
        failed += expect(!isLanTrigger(port: HardwarePort(name: "Thunderbolt 1", device: "en1"), facts: display), "Màn hình Thunderbolt không khóa")
        failed += expect(isLanTrigger(port: HardwarePort(name: "Thunderbolt 1", device: "en1"), facts: copper), "Thunderbolt có Ethernet thật thì khóa")
        failed += expect(!isLanTrigger(port: HardwarePort(name: "iPhone USB", device: "en8"), facts: phone), "iPhone không được tính là cáp LAN")
        failed += expect(!isLanTrigger(port: HardwarePort(name: "Thunderbolt Bridge", device: "bridge0"), facts: copper), "Bridge không khóa")

        let ports = parseHardwarePorts("""
        Hardware Port: Ethernet Adapter (en4)
        Device: en4
        Ethernet Address: aa:bb:cc:dd:ee:01

        Hardware Port: Wi-Fi
        Device: en0
        Ethernet Address: aa:bb:cc:dd:ee:02

        VLAN Configurations
        ===================
        """)
        failed += expect(ports.count == 2 && ports[1].device == "en0", "Phân tích hardware port")

        let ifaces = parseInterfaces("""
        lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
        \tinet 127.0.0.1 netmask 0xff000000
        en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        \tinet 192.168.1.20 netmask 0xffffff00 broadcast 192.168.1.255
        \tmedia: autoselect
        \tstatus: active
        en5: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        \tmedia: none
        \tstatus: inactive
        """)
        failed += expect(ifaces["en0"]?.statusActive == true && ifaces["en0"]?.addresses == ["192.168.1.20"], "en0 active có IP")
        failed += expect(ifaces["en5"]?.statusActive == false && ifaces["en5"]?.media == "none", "en5 inactive")
        failed += expect(ifaces["lo0"]?.addresses.isEmpty == true, "bỏ địa chỉ loopback")

        let services = parseServices("""
        An asterisk (*) denotes that a network service is disabled.
        *iPhone USB
        Wi-Fi
        Bluetooth PAN
        AX88179A
        *x52-local
        """)
        failed += expect(services.first { $0.name == "iPhone USB" }?.enabled == false, "iPhone đang tắt")
        failed += expect(services.first { $0.name == "Bluetooth PAN" }?.enabled == true, "Bluetooth PAN đang bật")
        failed += expect(!isTetherService("AX88179A") && !isTetherService("x52-local") && !isTetherService("Wi-Fi"), "LAN và VPN không phải tether")
        failed += expect(isTetherService("iPhone USB") && isTetherService("Bluetooth PAN"), "Nhận diện tether")
        failed += expect(parseWifiPower("Wi-Fi Power (en0): On") == true, "Đọc nguồn Wi-Fi On")
        failed += expect(parseWifiPower("Wi-Fi Power (en0): Off") == false, "Đọc nguồn Wi-Fi Off")
        failed += expect(parsePfToken("No ALTQ support\nToken : 3181439846958614074\n") == "3181439846958614074", "Đọc token pf")
        failed += expect(isSafeInterfaceName("en0") && isSafeInterfaceName("en12") && !isSafeInterfaceName("en0;reboot") && !isSafeInterfaceName("bridge0"), "Tên cổng an toàn")

        if failed == 0 {
            print("self-test: ok")
            return true
        }
        print("self-test: \(failed) lỗi")
        return false
    }

    private static func expect(_ condition: Bool, _ label: String) -> Int {
        if condition { return 0 }
        print("FAIL \(label)")
        return 1
    }
}
