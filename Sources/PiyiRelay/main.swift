// The extension's relay: launched by the browser, talks to the extension over stdin/stdout and to the app over a Unix socket.
// Every "collect" from the extension is written to the inbox before replying: if the app is open it's told to look; if not (reconnecting every second), it's picked up when the app opens.
// stdout is the channel to the browser, so logs can only go to stderr.
import Darwin
import Foundation
import Synchronization
import Wire

signal(SIGPIPE, SIG_IGN)

let directory = Bridge.directory
let fromBrowser = Channel(fd: STDIN_FILENO)
let toBrowser = Channel(fd: STDOUT_FILENO)

/// The connected app, and the extension's hello (resent every time the app connects, so the app knows the extension's version)
let link = Mutex<(app: Channel?, hello: Data?)>((nil, nil))

func log(_ text: String) {
    FileHandle.standardError.write(Data("piyi-relay: \(text)\n".utf8))
}

/// The name of the browser that launched us: "…/Google Chrome.app/Contents/MacOS/Google Chrome" → "Google Chrome"
func browserName() -> String {
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(getppid(), &path, UInt32(path.count)) > 0 else { return String(localized: "浏览器") }
    let bytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).lastPathComponent
}

func saveToInbox(_ message: Data) throws {
    Bridge.prepare(directory)
    // Write under another name first and rename to .json when done: the app only reads .json, so it never reads a half-written file
    let inbox = Bridge.inbox(in: directory)
    let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString)"
    try message.write(to: inbox.appending(path: name + ".part"))
    try FileManager.default.moveItem(at: inbox.appending(path: name + ".part"), to: inbox.appending(path: name + ".json"))
}

// App side: once connected, forward every line from the app to the extension; when disconnected, go back to reconnecting
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
            // Over the limit the browser just drops the connection: discard it and send the app a failure
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

// Extension side: exit when the browser closes stdin
while let frame = fromBrowser.readFrame() {
    let message = Message.decode(frame)
    guard message?.type == .collect else {
        link.withLock {
            if message?.type == .hello { $0.hello = frame }
            $0.app?.writeLine(frame)
        }
        continue
    }
    // A collect lands on disk before replying, and if it wasn't saved we say so; if the app is open, tell it which one arrived (it reads the content from the inbox itself), and after checking for duplicates it replies to the extension
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
