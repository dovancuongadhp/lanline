import Darwin
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--self-test") {
    exit(SelfTest.run() ? 0 : 1)
}

if arguments.contains("--dry-run") {
    Engine(writesChanges: false).printDryRun()
    exit(0)
}

if arguments.contains("--status") {
    let url = URL(fileURLWithPath: Paths.statusFile)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        fputs("Chưa có trạng thái. Dịch vụ khóa có thể chưa chạy.\n", stderr)
        exit(1)
    }
    print(text)
    exit(0)
}

if arguments.contains("--release") {
    if geteuid() != 0 {
        fputs("Cần quyền root: sudo lanlockd --release\n", stderr)
        exit(1)
    }
    Engine(writesChanges: true).releaseAll()
    exit(0)
}

if geteuid() != 0 {
    fputs("LanLock cần quyền root. Cài bằng sudo ./install.sh\n", stderr)
    exit(1)
}

setbuf(stdout, nil)
let engine = Engine(writesChanges: true)
Server.start(engine: engine)
var ticks = 0
while true {
    if ticks % 8 == 0, !installedAppStillPresent() {
        engine.releaseAll()
        try? FileManager.default.removeItem(atPath: "/Library/LaunchDaemons/com.lanlock.daemon.plist")
        try? FileManager.default.removeItem(atPath: Paths.supportDir)
        _ = Shell.run("/bin/launchctl", ["bootout", "system/com.lanlock.daemon"])
        exit(0)
    }
    engine.tick()
    ticks += 1
    Thread.sleep(forTimeInterval: 0.35)
}

func installedAppStillPresent() -> Bool {
    var url = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    url.deleteLastPathComponent()
    guard url.lastPathComponent == "MacOS" else { return true }
    url.deleteLastPathComponent()
    guard url.lastPathComponent == "Contents" else { return true }
    url.deleteLastPathComponent()
    guard url.pathExtension == "app" else { return true }
    return FileManager.default.fileExists(atPath: url.path)
}
