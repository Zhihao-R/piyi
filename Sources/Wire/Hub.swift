import Foundation
import Synchronization

/// App 这一端：在 socket 上等各浏览器的中转程序连上来，替 App 发抓取请求、收结果，听中转程序说收件箱里来了新的。
/// 每条连接一条线程阻塞读；状态都在锁里，任何线程都能调用
public final class Hub: Sendable {
    /// 一个连上的浏览器（装了扩展、扩展正在跑）
    public struct Browser: Sendable, Equatable {
        /// 启动中转程序的浏览器：Google Chrome、Microsoft Edge、Arc……
        public var name: String
        /// 扩展报来的版本，App 据此判断要不要让它重新加载
        public var version: String?
    }

    public enum Event: Sendable {
        /// 连上的浏览器有变化（连上、断开、扩展报了版本）
        case browsers([Browser])
        /// 收件箱里可能有新的：浏览器里刚点了「收进拼贴」，或者中转程序刚连上（它没连上的那段时间收的都存在那里）
        case arrived
    }

    public enum Failure: LocalizedError {
        case noBrowser, disconnected, timedOut, page(String)
        public var errorDescription: String? {
            switch self {
            case .noBrowser: "没有连上的浏览器"
            case .disconnected: "浏览器在抓取途中断开了"
            case .timedOut: "浏览器读这个网页超时了"
            case .page(let why): why
            }
        }
    }

    private final class Connection: Sendable {
        let channel: Channel
        let browser: Mutex<Browser>
        init(_ channel: Channel, _ browser: Browser) { self.channel = channel; self.browser = Mutex(browser) }
    }

    private struct State {
        var connections: [Connection] = []
        var pending: [String: (connection: Connection, reply: CheckedContinuation<Message, Error>)] = [:]
        var server: Int32?
    }

    private let directory: URL
    private let state = Mutex(State())
    private let onEvent: @Sendable (Event) -> Void

    public init(directory: URL = Bridge.directory, onEvent: @escaping @Sendable (Event) -> Void) {
        self.directory = directory
        self.onEvent = onEvent
    }

    public var browsers: [Browser] { state.withLock { $0.connections.map { $0.browser.withLock { $0 } } } }

    /// 开始监听
    public func start() throws {
        Bridge.prepare(directory)
        guard let server = listenSocket(Bridge.socket(in: directory)) else { throw CocoaError(.fileWriteNoPermission) }
        state.withLock { $0.server = server }
        Thread.detachNewThread { [self] in
            while true {
                let fd = accept(server, nil, nil)
                if fd < 0 { if errno == EINTR { continue } else { return } }
                Thread.detachNewThread { [self] in serve(Channel(fd: fd)) }
            }
        }
    }

    /// 停止监听，断开所有中转程序（它们会每秒重连，App 下次打开就连上）
    public func stop() {
        let (server, connections) = state.withLock { s in
            defer { s.server = nil; s.connections = [] }
            return (s.server, s.connections)
        }
        if let server { close(server) }
        for connection in connections { shutdown(connection.channel.fd, SHUT_RDWR) }
        unlink(Bridge.socket(in: directory))
    }

    /// 让一个连上的浏览器在后台打开网址、读出页面：优先叫 prefer 这个（你的默认浏览器，登录状态在那里），没连上就用最近连上的
    public func fetch(_ url: URL, scroll: Bool, prefer: String? = nil, timeout: Duration = .seconds(75)) async throws -> Message {
        try await ask(Message(.fetch, url: url.absoluteString, scroll: scroll), prefer: prefer, timeout: timeout)
    }

    /// 让一个连上的浏览器带着登录状态请求网址（不开标签页），交回响应原文。挑浏览器的规则和 fetch 一样
    public func request(_ url: URL, prefer: String? = nil, timeout: Duration = .seconds(20)) async throws -> String {
        try await ask(Message(.request, url: url.absoluteString), prefer: prefer, timeout: timeout).body ?? ""
    }

    /// 发一个请求给扩展，等它回 result（按编号对上）
    private func ask(_ request: Message, prefer: String?, timeout: Duration) async throws -> Message {
        let id = UUID().uuidString
        var message = request
        message.id = id
        let sent = message
        return try await withThrowingTaskGroup(of: Message.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { reply in
                    // 挑连接和登记等回复在同一把锁里：挑中的连接不会在这之间断开、留下一个没人回的请求
                    let connection = self.state.withLock { s -> Connection? in
                        guard let c = s.connections.last(where: { $0.browser.withLock { $0.name } == prefer }) ?? s.connections.last else { return nil }
                        s.pending[id] = (c, reply)
                        return c
                    }
                    guard let connection else { return reply.resume(throwing: Failure.noBrowser) }
                    connection.channel.writeLine(sent.encoded)
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw Failure.timedOut
            }
            defer { group.cancelAll() }
            do {
                let result = try await group.next()!
                guard result.ok == true else { throw Failure.page(result.error ?? "浏览器没读到这个网页") }
                return result
            } catch {
                // 超时：等着的那一半还挂着，替它收尾
                state.withLock { $0.pending.removeValue(forKey: id) }?.reply.resume(throwing: error)
                throw error
            }
        }
    }

    /// 发给某个浏览器里的扩展（让它重新加载之类）；browser 为 nil 时发给所有连着的（按编号回话，不认识这个编号的扩展不理会）
    public func send(_ message: Message, to browser: String? = nil) {
        let targets = state.withLock { $0.connections.filter { browser == nil || $0.browser.withLock { $0.name } == browser } }
        for connection in targets { connection.channel.writeLine(message.encoded) }
    }

    // MARK: 一条连接

    private func serve(_ channel: Channel) {
        guard let first = channel.readLine().flatMap(Message.decode), first.type == .relay else { return channel.close() }
        let connection = Connection(channel, Browser(name: first.browser ?? "浏览器"))
        changed { $0.connections.append(connection) }
        onEvent(.arrived)
        while let line = channel.readLine() {
            guard let message = Message.decode(line) else { continue }
            switch message.type {
            case .hello:
                changed { _ in connection.browser.withLock { $0.version = message.version } }
            case .result:
                state.withLock { $0.pending.removeValue(forKey: message.id ?? "") }?.reply.resume(returning: message)
            case .collect:
                onEvent(.arrived)
            default:
                break
            }
        }
        let orphans = changed { s in
            s.connections.removeAll { $0 === connection }
            let mine = s.pending.filter { $0.value.connection === connection }
            for id in mine.keys { s.pending.removeValue(forKey: id) }
            return mine.values.map(\.reply)
        }
        for reply in orphans { reply.resume(throwing: Failure.disconnected) }
        channel.close()
    }

    /// 改连接列表，改完把最新的浏览器列表报给 App
    @discardableResult
    private func changed<T>(_ change: (inout State) -> T) -> T {
        let (result, browsers) = state.withLock { s in
            let result = change(&s)
            return (result, s.connections.map { $0.browser.withLock { $0 } })
        }
        onEvent(.browsers(browsers))
        return result
    }
}
