import Foundation
import GRDB

/// 资料库：卡片、画板、摆放记录和文件的唯一持有者。
/// 读写都走数据库自己的队列，调用方用 async 版本时不会占住主线程。
public final class Store: Sendable {
    public let db: DatabasePool
    public let files: FileStore
    /// 资料库目录：数据库、文件、缩略图、本机模型都在这里
    public let root: URL

    /// ~/Library/Application Support/Collage
    public static var defaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: "Collage", directoryHint: .isDirectory)
    }

    public init(root: URL = Store.defaultRoot) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root
        files = try FileStore(root: root)
        db = try DatabasePool(path: root.appending(path: "library.sqlite").path)
        try Schema.migrator.migrate(db)
    }

    public enum Failure: Error, Equatable {
        /// 往画板里放的入口会让画板嵌套成环
        case cycle
    }
}
