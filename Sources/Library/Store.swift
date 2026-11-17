import Foundation
import GRDB

/// The library: sole owner of cards, boards, placements and files.
/// Reads and writes go through the database's own queue, so callers using the async versions don't block the main thread.
public final class Store: Sendable {
    public let db: DatabasePool
    public let files: FileStore
    /// Library folder: the database, files, thumbnails and local models all live here
    public let root: URL

    /// ~/Library/Application Support/Piyi
    public static var defaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: "Piyi", directoryHint: .isDirectory)
    }

    public init(root: URL = Store.defaultRoot) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root
        files = try FileStore(root: root)
        db = try DatabasePool(path: root.appending(path: "library.sqlite").path)
        try Schema.migrator.migrate(db)
    }

    public enum Failure: Error, Equatable {
        /// The entry put on a board would make boards nest in a cycle
        case cycle
    }
}
