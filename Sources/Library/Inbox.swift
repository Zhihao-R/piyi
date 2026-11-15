import Foundation

/// 收件箱：一个文件夹。所有入口（拖进和粘贴到画布、快捷键、服务菜单、浏览器扩展、手机）都先把要收的东西存成这里的文件，
/// 再说「收下了」；卡存进资料库之后才删文件。中途退出或崩溃，文件还在，下次再收一遍，已经存好的由查重认出来。
/// 本机的入口共用一个文件夹，手机的在 iCloud 里另有一个，做法相同，只是文件的写法不同（read）
public actor Inbox {
    /// 从画布收的东西要落回的地方：哪个画板（nil 是只进资料库）、世界坐标里的哪一点
    public struct Spot: Codable, Sendable, Equatable {
        public var board: Int64?
        public var x: Double
        public var y: Double

        public init(board: Int64?, x: Double, y: Double) { (self.board, self.x, self.y) = (board, x, y) }
    }

    /// 一次收的东西：一个或几个文件。id 是存它的入口起的编号，收完按它回话；编号相同的文件是同一次收的
    public struct Arrival: Sendable {
        public var files: [URL]
        public var id: String?
        public var sources: [Source]
        public var spot: Spot?

        public init(file: URL, id: String? = nil, sources: [Source], spot: Spot? = nil) {
            (files, self.id, self.sources, self.spot) = ([file], id, sources, spot)
        }
    }

    /// 读一个文件；不是给这里的、还读不到的（没写完、没从 iCloud 下载完）返回 nil，留到下次
    public typealias Read = @Sendable (URL) -> Arrival?

    public nonisolated let folder: URL
    private let read: Read
    /// 交给收集、还没删掉的文件：再看文件夹时跳过，免得收两遍
    private var collecting: Set<URL> = []

    public init(folder: URL, read: @escaping Read = Inbox.entry) {
        self.folder = folder
        self.read = read
    }

    /// 文件夹里还没收的，按存进来的先后、一次收的归成一份，各自交给 collect；哪一份报存进了资料库，就删哪一份的文件。
    /// 一份没存好不连累别的
    public func drain(_ collect: @escaping @Sendable (Arrival) async -> Bool) async {
        let keys: Set<URLResourceKey> = [.creationDateKey, .isRegularFileKey]
        // 只读文件：隐藏文件（同步中的临时文件、.DS_Store）和子文件夹都不碰
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)) ?? [])
            .map { $0.standardizedFileURL }
            .filter { !collecting.contains($0) }
            .compactMap { file in (try? file.resourceValues(forKeys: keys)).flatMap { $0.isRegularFile == true ? (file, $0.creationDate ?? .distantPast) : nil } }
            .sorted { ($0.1, $0.0.lastPathComponent) < ($1.1, $1.0.lastPathComponent) }
            .map(\.0)
        var arrivals: [Arrival] = []
        for one in files.compactMap(read) {
            if let id = one.id, let i = arrivals.firstIndex(where: { $0.id == id }) {
                arrivals[i].files += one.files
                arrivals[i].sources += one.sources
            } else {
                arrivals.append(one)
            }
        }
        collecting.formUnion(arrivals.flatMap(\.files))
        await withTaskGroup(of: (Arrival, Bool).self) { group in
            for arrival in arrivals { group.addTask { (arrival, await collect(arrival)) } }
            for await (arrival, saved) in group {
                if saved {
                    for file in arrival.files {
                        NSFileCoordinator().coordinate(writingItemAt: file, options: .forDeleting, error: nil) { try? FileManager.default.removeItem(at: $0) }
                    }
                }
                collecting.subtract(arrival.files)
            }
        }
    }

    // MARK: 本机收件箱的文件

    /// 本机收件箱里的一个文件：一条 JSON。扩展收的由中转程序原样存下（字段和 Wire 的 Message 同名），App 自己收的由 put 存
    struct Entry: Codable {
        var id: String?
        /// 收的网址；和 html、image、imageURL、text 一起出现时是所在的网页
        var url: String?
        /// 渲染好的整页
        var html: String?
        var text: String?
        /// 图片本身
        var image: Data?
        /// 只知道图片的地址
        var imageURL: String?
        /// 你电脑上的文件：只记路径，文件本身已经在磁盘上
        var file: String?
        /// 和网址一起带来的那句话
        var note: String?
        /// 从画布收的：要落回哪里
        var spot: Spot?

        /// 优先级和扩展右键菜单一致：图，文字，整页
        var source: Source? {
            let url = url.flatMap(URL.init(string:))
            if let file { return .file(URL(fileURLWithPath: file)) }
            if let image { return .image(image, page: url) }
            if let address = imageURL.flatMap(URL.init(string:)) { return .imageAt(address, page: url) }
            if let text {
                guard let url else { return .text(text) }
                // 网页上选中的一段话：和粘贴的文字一样收成文字卡，多一个出处
                var m = FileExtractor.text(text)
                m.sourceURL = url.absoluteString
                m.source = url.host()
                return .ready(m)
            }
            guard let url else { return nil }
            if let html { return .rendered(RenderedPage(url: url, html: html)) }
            return note.map { .mentioned(url, in: $0) } ?? .url(url)
        }

        /// 剪贴板、拖放、服务菜单里收得到的几种
        init?(_ source: Source, id: String, spot: Spot?) {
            (self.id, self.spot) = (id, spot)
            switch source {
            case .file(let url): file = url.path
            case .url(let address): url = address.absoluteString
            case .mentioned(let address, let words): (url, note) = (address.absoluteString, words)
            case .image(let data, let page): (image, url) = (data, page?.absoluteString)
            case .imageAt(let address, let page): (imageURL, url) = (address.absoluteString, page?.absoluteString)
            case .text(let words): text = words
            case .rendered, .ready: return nil
            }
        }
    }

    /// 读本机收件箱的一个文件。只认写完改好名的 .json：存的时候先写到别的名字
    public static let entry: Read = { file in
        guard file.pathExtension == "json", let data = try? Data(contentsOf: file),
              let entry = try? JSONDecoder().decode(Entry.self, from: data), let source = entry.source else { return nil }
        return Arrival(file: file, id: entry.id, sources: [source], spot: entry.spot)
    }

    /// 存进本机收件箱，一样东西一个文件，都记上同一个编号；spot 是从画布收的要落回的地方
    public func put(_ sources: [Source], id: String, spot: Spot? = nil) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for entry in sources.compactMap({ Entry($0, id: id, spot: spot) }) {
            // 文件名以毫秒时间开头，和中转程序存的一样
            let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString)"
            try JSONEncoder().encode(entry).write(to: folder.appending(path: name + ".part"))
            try FileManager.default.moveItem(at: folder.appending(path: name + ".part"), to: folder.appending(path: name + ".json"))
        }
    }
}
