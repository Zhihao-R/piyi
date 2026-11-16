// 扩展的中转程序：由浏览器启动，stdin/stdout 连扩展，Unix socket 连 App。
// 扩展送来的「收集」都先写进收件箱再回话：App 开着就叫它去看，没开（每秒重连一次）就等它打开时补收。
// stdout 是给浏览器的通道，日志只能写 stderr。
import Darwin
import Foundation
import Synchronization
import Wire

signal(SIGPIPE, SIG_IGN)

let directory = Bridge.directory
let fromBrowser = Channel(fd: STDIN_FILENO)
let toBrowser = Channel(fd: STDOUT_FILENO)

/// 连着的 App，和扩展的招呼（每次连上 App 都重发一遍，App 才知道扩展是哪一版）
let link = Mutex<(app: Channel?, hello: Data?)>((nil, nil))

func log(_ text: String) {
    FileHandle.standardError.write(Data("piyi-relay: \(text)\n".utf8))
}

/// 启动我们的浏览器叫什么："…/Google Chrome.app/Contents/MacOS/Google Chrome" → "Google Chrome"
func browserName() -> String {
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(getppid(), &path, UInt32(path.count)) > 0 else { return String(localized: "浏览器") }
    let bytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).lastPathComponent
}

func saveToInbox(_ message: Data) throws {
    Bridge.prepare(directory)
    // 先写到别的名字，写完再改成 .json：App 只读 .json，不会读到写了一半的
    let inbox = Bridge.inbox(in: directory)
    let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString)"
    try message.write(to: inbox.appending(path: name + ".part"))
    try FileManager.default.moveItem(at: inbox.appending(path: name + ".part"), to: inbox.appending(path: name + ".json"))
}

// App 一侧：连上就把 App 发来的每一行转给扩展，断了就回去重连
let browser = browserName()
Thread.detachNewThread {
    while true {
        guard let app = connectSocket(Bridge.socket(in: directory)) else { sleep(1); continue }
        app.writeLine(Message(.relay, browser: browser).encoded)
        link.withLock {
            $0.app = app
            if let hello = $0.hello { app.writeLine(hello) }
        }
        log("已连上 App")
        while let line = app.readLine() {
            // 超过上限浏览器会直接断开连接：丢掉，回 App 一条失败
            guard line.count <= Bridge.maxMessageToBrowser else {
                log("App 发来的消息 \(line.count) 字节，超过浏览器 1 MB 上限，已丢弃")
                app.writeLine(Message(.result, id: Message.decode(line)?.id, ok: false,
                                      error: String(localized: "消息 \(line.count) 字节，超过浏览器 1 MB 上限，中转程序已丢弃")).encoded)
                continue
            }
            toBrowser.writeFrame(line)
        }
        link.withLock { $0.app = nil }
        app.close()
        log("App 断开，重连中")
    }
}

// 扩展一侧：浏览器关掉 stdin 就退出
while let frame = fromBrowser.readFrame() {
    let message = Message.decode(frame)
    guard message?.type == .collect else {
        link.withLock {
            if message?.type == .hello { $0.hello = frame }
            $0.app?.writeLine(frame)
        }
        continue
    }
    // 收集先落到磁盘上再回话，没存下就照实说；App 开着就告诉它来了哪一条（内容它自己从收件箱读），查过重由它再回扩展一声
    do {
        try saveToInbox(frame)
    } catch {
        log("收件箱写不进：\(error)")
        toBrowser.writeFrame(Message(.collected, id: message?.id, ok: false, say: String(localized: "没存下：\(error.localizedDescription)")).encoded)
        continue
    }
    let queued = link.withLock {
        $0.app?.writeLine(Message(.collect, id: message?.id).encoded)
        return $0.app == nil
    }
    toBrowser.writeFrame(Message(.collected, id: message?.id, ok: true, queued: queued, say: queued ? String(localized: "已存下，片羽打开后收进") : nil).encoded)
}
exit(0)
