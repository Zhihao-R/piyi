import Foundation
import Library

/// 随 App 带的示例数据
enum Seed {
    private struct Item: Decodable {
        /// image（馆藏图片）、quote（引文）、link（事先下载好封面的链接）、file（示例文件）、url（交给网页抽取）
        var kind: String
        var file: String?
        var text: String?
        var title: String?
        var source: String?
        var url: String?
        var createdAt: Double
        /// 在示例画板上的摆放：左上角、宽高（世界坐标）和旋转（度）。没写高度就按卡片自己的比例算；都没写就自动排
        var x: Double?
        var y: Double?
        var width: Double?
        var height: Double?
        var rotation: Double?
        /// 界面不是中文时换上的英文版：引文、随手记、中文文件
        var en: Variant?
    }

    private struct Variant: Decodable {
        var text: String?
        var source: String?
        var file: String?
    }


    /// 一张示例卡在画板上的位置
    struct Spot: Sendable {
        var origin: CGPoint
        var width: CGFloat
        var height: CGFloat?
        /// 弧度
        var rotation: CGFloat
    }

    /// 打包成 .app 后资源包在 Contents/Resources 里；swift run 时在编译目录里
    static var directory: URL? {
        let name = "Collage_Collage.bundle"
        for base in [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap({ $0 }) {
            if let bundle = Bundle(url: base.appending(path: name)), let url = bundle.url(forResource: "Seed", withExtension: nil) { return url }
        }
        return nil
    }

    private static var items: [Item] {
        guard let dir = directory, let data = try? Data(contentsOf: dir.appending(path: "manifest.json")) else { return [] }
        return (try? JSONDecoder().decode([Item].self, from: data)) ?? []
    }

    /// 新装用户的示例：和你拖进来的东西走同一条收集流程，各自带着在示例画板上的位置
    static func sources() -> [(source: Source, spot: Spot?)] {
        guard let dir = directory else { return [] }
        return items.compactMap { original in
            var item = original
            if !interfaceIsChinese, let en = item.en {
                item.text = en.text ?? item.text
                item.source = en.source ?? item.source
                item.file = en.file ?? item.file
                // 换了文字的卡按英文的长短重新算高度
                if en.text != nil { item.height = nil }
            }
            return source(item, in: dir).map { ($0, spot(item)) }
        }
    }

    private static func spot(_ item: Item) -> Spot? {
        guard let x = item.x, let y = item.y, let width = item.width else { return nil }
        return Spot(origin: CGPoint(x: x, y: y), width: width, height: item.height.map { CGFloat($0) }, rotation: (item.rotation ?? 0) * .pi / 180)
    }

    private static func source(_ item: Item, in dir: URL) -> Source? {
        switch item.kind {
        case "image":
            guard let file = item.file, let data = try? Data(contentsOf: dir.appending(path: "images/" + file)) else { return nil }
            // 馆藏原名放进出处，标题留给理解起中文名
            var m = FileExtractor.image(data)
            m.source = [item.title, item.source].compactMap { $0 }.joined(separator: " · ")
            m.sourceURL = item.url
            return .ready(m)
        case "quote":
            var m = FileExtractor.text(item.text ?? "")
            m.source = item.source
            return .ready(m)
        case "link":
            var m = Material(kind: .web)
            m.title = item.title
            m.source = item.source
            m.url = item.url
            m.images = [item.file.flatMap { try? Data(contentsOf: dir.appending(path: "images/" + $0)) }].compactMap { $0 }
            return .ready(m)
        case "file":
            return item.file.map { .file(dir.appending(path: "files/" + $0)) }
        case "url":
            return item.url.flatMap(URL.init(string:)).map(Source.url)
        default:
            return nil
        }
    }

    /// 「示例」画板是哪一个，老资料库关一次它的自动分拣时用
    static var board: Int64? {
        get { UserDefaults.standard.object(forKey: "sampleBoard") as? Int64 }
        set { UserDefaults.standard.set(newValue, forKey: "sampleBoard") }
    }

    /// 有自动分拣之前建好的示例画板，已经关过一次自动分拣
    static var sortingClosed: Bool {
        get { UserDefaults.standard.bool(forKey: "sampleSortingClosed") }
        set { UserDefaults.standard.set(newValue, forKey: "sampleSortingClosed") }
    }
}
