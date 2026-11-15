import Foundation
import Synchronization

/// 一个阻塞读写的文件描述符：socket、stdin、stdout 都用它。读只在一条线程上做，写可以多条线程同时来
public final class Channel: @unchecked Sendable {
    public let fd: Int32
    private let writing = Mutex(())
    private var buffer = Data()

    public init(fd: Int32) { self.fd = fd }

    /// 浏览器协议的一帧：读到 nil 表示对面关了
    public func readFrame() -> Data? {
        guard let header = readExactly(4) else { return nil }
        let length = header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        return readExactly(Int(length))
    }

    public func writeFrame(_ body: Data) {
        var length = UInt32(body.count).littleEndian
        write(Data(bytes: &length, count: 4) + body)
    }

    public func readLine() -> Data? {
        var scanned = 0  // 已经找过的部分不再重找，几 MB 的整页 HTML 才不会越读越慢
        while true {
            if let newline = buffer[(buffer.startIndex + scanned)...].firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return Data(line)
            }
            scanned = buffer.count
            guard fill() else { return nil }
        }
    }

    public func writeLine(_ body: Data) { write(body + [0x0A]) }

    public func close() { Darwin.close(fd) }

    private func readExactly(_ count: Int) -> Data? {
        while buffer.count < count { guard fill() else { return nil } }
        let chunk = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(chunk)
    }

    private func fill() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let n = Darwin.read(fd, &chunk, chunk.count)
        guard n > 0 else { return false }
        buffer.append(contentsOf: chunk[..<n])
        return true
    }

    private func write(_ data: Data) {
        writing.withLock { _ in
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n <= 0 { return }
                    offset += n
                }
            }
        }
    }
}

extension sockaddr_un {
    init(path: String) {
        self.init()
        sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &sun_path) { raw in raw.copyBytes(from: Array(path.utf8.prefix(raw.count - 1))) }
    }
}

/// 连上一个 Unix socket；连不上返回 nil
public func connectSocket(_ path: String) -> Channel? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un(path: path)
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 }
    }
    if connected { return Channel(fd: fd) }
    close(fd)
    return nil
}

/// 在 path 上监听；socket 一创建就只有当前用户能连，不留 chmod 之前的空档
func listenSocket(_ path: String) -> Int32? {
    unlink(path)
    let mask = umask(0o077)
    defer { umask(mask) }
    let server = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un(path: path)
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 }
    }
    guard bound, listen(server, 8) == 0 else { close(server); return nil }
    return server
}
