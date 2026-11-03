import Darwin
import Foundation

enum Server {
    static func start(engine: Engine) {
        signal(SIGPIPE, SIG_IGN)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            fputs("Không tạo được socket\n", stderr)
            exit(1)
        }
        unlink(Paths.socket)
        guard var addr = unixAddress(Paths.socket) else {
            fputs("Đường dẫn socket quá dài\n", stderr)
            exit(1)
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if bound != 0 {
            fputs("Không bind được \(Paths.socket): \(String(cString: strerror(errno)))\n", stderr)
            exit(1)
        }
        if listen(fd, 8) != 0 {
            fputs("Không listen được socket\n", stderr)
            exit(1)
        }
        chmod(Paths.socket, 0o666)

        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { continue }
                var buffer = [UInt8](repeating: 0, count: 256)
                let count = buffer.withUnsafeMutableBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return read(client, base, raw.count)
                }
                let text = count > 0 ? String(decoding: buffer.prefix(count), as: UTF8.self) : ""
                let response = engine.handle(command: text) + "\n"
                _ = response.withCString { pointer in
                    write(client, pointer, strlen(pointer))
                }
                close(client)
            }
        }
    }
}
