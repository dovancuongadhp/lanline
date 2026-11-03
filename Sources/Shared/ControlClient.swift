import Darwin
import Foundation

enum ControlClient {
    static func send(_ command: String) -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            return "ERR không mở được socket (\(String(cString: strerror(errno))))"
        }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard var addr = unixAddress(Paths.socket) else {
            return "ERR đường dẫn socket quá dài"
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            return "ERR dịch vụ khóa chưa chạy"
        }

        var payload = command
        if !payload.hasSuffix("\n") { payload.append("\n") }
        let written = payload.withCString { pointer -> Int in
            write(fd, pointer, strlen(pointer))
        }
        if written < 0 {
            return "ERR không gửi được lệnh"
        }

        var buffer = [UInt8](repeating: 0, count: 512)
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return read(fd, base, raw.count)
        }
        if count <= 0 {
            return "ERR không nhận được trả lời"
        }
        return String(decoding: buffer.prefix(count), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

func unixAddress(_ path: String) -> sockaddr_un? {
    let maxPath = 104
    guard path.utf8.count < maxPath else { return nil }
    var addr = sockaddr_un()
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    addr.sun_family = sa_family_t(AF_UNIX)
    let copied = path.withCString { source -> Bool in
        withUnsafeMutablePointer(to: &addr.sun_path) { destination in
            destination.withMemoryRebound(to: CChar.self, capacity: maxPath) { pointer in
                strncpy(pointer, source, maxPath - 1)
                pointer[maxPath - 1] = 0
                return true
            }
        }
    }
    return copied ? addr : nil
}
