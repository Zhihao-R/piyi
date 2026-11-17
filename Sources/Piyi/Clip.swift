import AppKit
import Library

/// Cards in and out of the clipboard: one item per card. Piyi itself reads its placement (size, crop, rotation, position), and pasting adds the same card again;
/// other apps read the original file, URL or text
enum Clip {
    static let type = NSPasteboard.PasteboardType("piyi.placement")

    struct Original: Sendable { let title: String, file: URL }

    /// text: full text of a text card; file: the original file for other apps (see export)
    static func item(for card: BoardItem, text: String?, file: URL?) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        if let data = try? JSONEncoder().encode(card.placement) { item.setData(data, forType: type) }
        guard case .card(let face) = card.face else { return item }
        if let file { item.setString(file.absoluteString, forType: .fileURL) }
        else if let url = face.url { item.setString(url, forType: .string) }
        else if let text { item.setString(text, forType: .string) }
        return item
    }

    static func placements(in pasteboard: NSPasteboard) -> [Placement] {
        (pasteboard.pasteboardItems ?? []).compactMap { $0.data(forType: type) }.compactMap { try? JSONDecoder().decode(Placement.self, from: $0) }
    }

    /// Files in the library are named by content fingerprint, which looks like gibberish elsewhere: copy one to a temp folder, named after the card title.
    /// On APFS a copy is a clone, taking no space or time; editing it elsewhere doesn't touch the original in the library. The previous copies are cleared first
    static func export(_ originals: [Int64: Original]) async -> [Int64: URL] {
        await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default, folder = manager.temporaryDirectory.appending(path: "piyi-clip")
            try? manager.removeItem(at: folder)
            var named = [Int64: URL]()
            for (card, original) in originals {
                // One subfolder per card: duplicate titles don't collide
                let target = folder.appending(path: "\(card)").appending(path: name(original.title, ext: original.file.pathExtension))
                do {
                    try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try manager.copyItem(at: original.file, to: target)
                    named[card] = target
                } catch {
                    named[card] = original.file
                }
            }
            return named
        }.value
    }

    /// Title as file name: path characters replaced, too-long ones truncated; with no title it's "Piyi"
    static func name(_ title: String, ext: String) -> String {
        let clean = title.components(separatedBy: CharacterSet(charactersIn: "/:\n")).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let stem = clean.isEmpty ? "片羽" : String(clean.prefix(60))
        return ext.isEmpty ? stem : stem + "." + ext
    }
}
