import AppKit
import Library

/// 卡片进出剪贴板：每张卡一项。拼贴自己认它的摆放（大小、裁剪、旋转、位置），粘贴是同一张卡再放一份；
/// 别的 App 认原文件、网址或文字
enum Clip {
    static let type = NSPasteboard.PasteboardType("collage.placement")

    struct Original: Sendable { let title: String, file: URL }

    /// text：文字卡的全文；file：给别的 App 的原文件（见 export）
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

    /// 资料库里的文件按内容指纹起名，拿到别处是一串乱码：拷贝一份到临时文件夹，用卡片标题起名。
    /// APFS 上拷贝是克隆，不占空间、不费时；在别处改它也碰不到资料库里的原件。上一次拷贝的先清掉
    static func export(_ originals: [Int64: Original]) async -> [Int64: URL] {
        await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default, folder = manager.temporaryDirectory.appending(path: "collage-clip")
            try? manager.removeItem(at: folder)
            var named = [Int64: URL]()
            for (card, original) in originals {
                // 每张一个子文件夹：标题重了也不撞名
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

    /// 标题做文件名：路径符号换掉，太长的截断；没有标题叫「拼贴」
    static func name(_ title: String, ext: String) -> String {
        let clean = title.components(separatedBy: CharacterSet(charactersIn: "/:\n")).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let stem = clean.isEmpty ? "拼贴" : String(clean.prefix(60))
        return ext.isEmpty ? stem : stem + "." + ext
    }
}
