import SwiftUI
import Library
import Canvas
import Tokens

/// 一张卡的文字，放大查看里只有这一种版式，从上到下越来越细：出处和时间、标题、一句描述、要点、全文、转录、标签。
/// 没有画面的卡整块是它；有画面的卡，它是画面旁边的窄栏（compact），字小一号，不排配图
struct Reader: View {
    let store: Store
    let card: Card
    /// 其余图片（不含封面）
    let images: [String]
    var compact = false
    /// 排好的全文和转录（见 DetailView.bodyText）。文章的正文不在这里：它带着配图一段段排
    let bodyText: NSAttributedString?
    let transcriptText: NSAttributedString?
    /// 讨论里点了引用：滚到这一段闪一下
    let highlight: LongText.Highlight?
    /// 出处那一行右端的按钮：讨论、放上桌
    let discuss: DetailView.Action
    let follow: (URL) -> Void
    /// 点了简介、转录里的时间点：从那一秒播
    let seek: (Int) -> Void
    /// 点了一条要点：滚到它依据的那一段，视频从那一秒播
    let jump: (Passage) -> Void
    let refetch: () -> Void
    /// 你写的文字卡改了字：存下来
    let rewrite: (String) -> Void
    /// 文字卡正改到的样子；nil 是还没动过
    @State private var draft: String?

    private var type: Reading.Scale { compact ? Reading.narrow : Reading.wide }
    /// 文章：正文里记着配图位置，图回到原文那一段之后
    private var isArticle: Bool { !compact && DetailView.isArticle(card) }
    /// 你写的短句：这句话本身就是内容，不再配模型起的标题和转述
    private var isQuote: Bool { card.kind == .text && (card.text ?? "").count <= CardType.shortTextLimit }

    var body: some View {
        Group {
            if compact {
                ScrollView { column }
            } else {
                // 放得下就收到内容那么高（只有几行字的卡不撑成一整面空白），放不下才滚
                ViewThatFits(in: .vertical) {
                    column
                    ScrollView { column }
                }
            }
        }
        .background(Palette.page.color)
        .task(id: card.summaryAnchors) { await locate() }
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: type.gap) {
            VStack(alignment: .leading, spacing: type.gap / 2) {
                eyebrow
                if !isQuote {
                    Text(card.displayTitle).font(.system(size: type.title, weight: .bold, design: .serif)).lineSpacing(4).textSelection(.enabled)
                    if let caption = card.caption { Text(caption).font(.system(size: type.lead)).lineSpacing(5).foregroundStyle(.secondary) }
                }
                // 收的时候你自己随手写的那句话：比模型的描述更说明你为什么收它
                if let note = card.note { Text(note).font(.system(size: type.lead)).lineSpacing(5).textSelection(.enabled) }
                status
            }
            if let summary = card.summary { Points(summary: summary, sources: sources, size: type.lead, jump: jump) }
            // 你写的文字卡在这里也能改：从资料库、搜索、讨论里点开的，不用回到它所在的画板。废纸篓里的不改
            if card.form == .note, card.trashedAt == nil {
                NoteField(text: Binding(get: { draft ?? card.text ?? "" }, set: { draft = $0 }), type: type, highlight: highlight, commit: rewrite)
            } else if isArticle { article } else if let bodyText { LongText(bodyText, highlight: highlight, onLink: link) }
            if let transcriptText {
                VStack(alignment: .leading, spacing: type.gap / 2) {
                    // 平台的字幕和本机转出来的，可信程度不同
                    Text(card.original == nil ? "字幕" : "转录").font(.caption).tracking(2).foregroundStyle(.tertiary)
                    LongText(transcriptText, highlight: highlight, onLink: link)
                }
            }
            footer
        }
        .frame(maxWidth: compact ? .infinity : Reading.column, alignment: .leading)
        .padding(type.padding)
        .frame(maxWidth: .infinity)
    }

    /// 每条要点依据的那一段，按存下的原话在现在的原文里找回；原文改过、找不回的那条不能点。
    /// 要把原文切一遍，在后台算一次存着，不在每次重画时算
    @State private var sources: [Passage?] = []

    private func locate() async {
        let card = card
        sources = await Task.detached(priority: .userInitiated) {
            let passages = Passages.of(card)
            return (card.summaryAnchors ?? []).map { anchor in anchor.flatMap { Passages.find($0.quote, part: $0.part, among: passages) } }
        }.value
    }

    /// 文章的正文：封面、署名，然后文字和配图按原文的顺序
    @ViewBuilder private var article: some View {
        let (credits, body) = Passages.credits(in: card.body ?? "", for: card)
        // 没有单独封面的文章，封面就是第一张配图，在正文里会出现
        if let cover = card.cover, cover != images.first { Picture(store: store, name: cover) }
        if !credits.isEmpty { Text(credits.joined(separator: "　")).font(.caption).foregroundStyle(.tertiary) }
        ForEach(Array(Article.segments(body, images: images.count).enumerated()), id: \.offset) { _, segment in
            switch segment {
            case .text(let text):
                LongText(text: text, font: .systemFont(ofSize: type.body), lineSpacing: type.lineSpacing, paragraphSpacing: type.paragraphSpacing, highlight: highlight)
            case .image(let k): Picture(store: store, name: images[k])
            }
        }
    }

    /// 公众号 · 出处（点了打开原文或原文件） · 收藏的日子，右端是「讨论」
    private var eyebrow: some View {
        let url = card.url.flatMap(URL.init(string:)), file = card.original.map(store.files.url(of:))
        let source = card.source ?? url?.host() ?? (file == nil ? nil : String(localized: "原文件"))
        return HStack(spacing: 6) {
            if let format = card.format { Text(displayed(format)); Text("·") }
            if let source {
                if let target = url ?? file {
                    Button(source + " ↗") { follow(target) }.buttonStyle(.plain).foregroundStyle(.secondary).help(url == nil ? "用默认应用打开" : "打开原文")
                } else {
                    Text(source)
                }
                Text("·")
            }
            Text(card.collectedAt.formatted(Calendar.current.isDate(card.collectedAt, equalTo: .now, toGranularity: .year)
                                            ? .dateTime.month().day() : .dateTime.year().month().day()))
                .layoutPriority(1)
            Spacer(minLength: 12)
            Button(discuss.title, action: discuss.run).buttonStyle(.plain).foregroundStyle(.secondary).disabled(!discuss.enabled).layoutPriority(2)
        }
        .lineLimit(1)
        .font(.caption)
        .foregroundStyle(.tertiary)
    }

    /// 这张卡不完整时说一句为什么：没抓全（可以重新抓取）、理解失败、等密钥
    @ViewBuilder private var status: some View {
        if let partial = card.partial {
            HStack(spacing: 8) {
                Text(partial.reason).foregroundStyle(Palette.warning.color)
                Button("重新抓取", action: refetch).buttonStyle(.link)
            }
            .font(.callout)
        } else if let error = card.understandError {
            Text("理解失败：\(error)").font(.callout).foregroundStyle(Palette.warning.color)
        } else if card.understanding == .waitingKey {
            Text("等待密钥：在设置里填上后，自动生成标题、描述和要点").font(.callout).foregroundStyle(.secondary)
        }
    }

    /// 标签降成一行灰字，主色缩成小圆点，都放在文末
    @ViewBuilder private var footer: some View {
        let swatches = DetailView.swatches(card.colors) ?? []
        if !card.tags.isEmpty || !swatches.isEmpty {
            HStack(alignment: .top, spacing: 16) {
                Text(card.tags.joined(separator: " · ")).font(.caption).foregroundStyle(.tertiary).lineSpacing(4)
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    ForEach(swatches, id: \.self) { Circle().fill(Color(hex: $0)).frame(width: 10, height: 10) }
                }
            }
            .padding(.top, type.gap / 2)
            .overlay(alignment: .top) { Divider() }
        }
    }

    /// 时间点的链接是 seek:秒数；别的链接照常用浏览器打开
    private func link(_ url: URL) -> Bool {
        guard url.scheme == "seek", let seconds = Int(url.absoluteString.dropFirst("seek:".count)) else { return false }
        seek(seconds)
        return true
    }
}

/// 你写的文字卡的正文，能直接改。文本框里是原文，标记变淡、标题变大，和画布上写字时同一种样子（见 NoteEditor）。
/// 点到别处、按 Esc、关掉放大查看时存
private struct NoteField: NSViewRepresentable {
    @Binding var text: String
    let type: Reading.Scale
    var highlight: LongText.Highlight?
    let commit: (String) -> Void

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(usingTextLayoutManager: false)
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator
        view.string = text
        context.coordinator.saved = text
        context.coordinator.restyle(view)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        let coordinator = context.coordinator
        (coordinator.edited, coordinator.commit) = ({ text = $0 }, commit)
        if let highlight, coordinator.flashed != highlight.id {
            coordinator.flashed = highlight.id
            DispatchQueue.main.async { LongText.flash(highlight.text, in: view) }
        }
    }

    /// 写多了往下长：量法和 LongText 一样
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, let container = view.textContainer, let layout = view.layoutManager else { return nil }
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let height = ceil(layout.usedRect(for: container).height)
        if view.bounds.width > 0 { container.size = NSSize(width: view.bounds.width, height: .greatestFiniteMagnitude) }
        return CGSize(width: width, height: max(height, type.body + type.lineSpacing))
    }

    static func dismantleNSView(_ view: NSTextView, coordinator: Coordinator) { coordinator.save(view) }

    func makeCoordinator() -> Coordinator { Coordinator(style: DetailView.markdown(type)) }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        let style: Markdown.Style
        var edited: ((String) -> Void)?
        var commit: ((String) -> Void)?
        /// 已经存下的那一版：没变就不再存
        var saved = ""
        var flashed: UUID?

        init(style: Markdown.Style) { self.style = style }

        /// 每改一个字重新上一遍样式。拼音还没选字时不动，免得打断输入法
        func restyle(_ view: NSTextView) {
            guard let storage = view.textStorage, !view.hasMarkedText() else { return }
            let styled = Markdown.styled(storage.string, style: style)
            storage.beginEditing()
            styled.enumerateAttributes(in: NSRange(location: 0, length: styled.length)) { attributes, range, _ in
                storage.setAttributes(attributes, range: range)
            }
            storage.endEditing()
            view.typingAttributes = Markdown.styled(" ", style: style).attributes(at: 0, effectiveRange: nil)
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            restyle(view)
            edited?(view.string)
        }

        func textDidEndEditing(_ notification: Notification) {
            if let view = notification.object as? NSTextView { save(view) }
        }

        /// 写空了不存：删卡是画布上的事，在这里字一删光卡就没了太突然
        func save(_ view: NSTextView) {
            let text = view.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text != saved else { return }
            saved = text
            commit?(text)
        }

        /// Esc：写完（再按一次才关放大查看）
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            textView.window?.makeFirstResponder(nil)
            return true
        }
    }
}

/// 要点：浅底方块里一行一条，「· 」开头的行画成圆点，其余的行（如「仅根据简介」）当小字说明。
/// 找得到依据的那条是个按钮，点了跳到原文那一段；转录里的依据在末尾标出时间
private struct Points: View {
    let summary: String
    /// 和「· 」开头的行一一对应
    let sources: [Passage?]
    let size: Double
    let jump: (Passage) -> Void

    var body: some View {
        let lines = summary.components(separatedBy: "\n")
        let notes = lines.filter { !$0.hasPrefix("· ") }, points = lines.filter { $0.hasPrefix("· ") }.map { String($0.dropFirst(2)) }
        return VStack(alignment: .leading, spacing: 10) {
            Text("要点").font(.caption).tracking(2).foregroundStyle(.tertiary)
            ForEach(notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(points.enumerated()), id: \.offset) { i, point in
                if let source = sources.indices.contains(i) ? sources[i] : nil {
                    Button { jump(source) } label: { row(point, time: source.seconds) }
                        .buttonStyle(HoverButton(shape: RoundedRectangle(cornerRadius: 6)))
                        .help(source.seconds == nil ? "看原文这一段" : "从这里播")
                } else {
                    row(point, time: nil).textSelection(.enabled)
                }
            }
        }
        .padding(size + 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func row(_ point: String, time: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(.tertiary).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
            (Text(point) + Text(time.map { "　" + clockText($0) } ?? "").foregroundStyle(.tertiary).monospacedDigit())
                .font(.system(size: size)).lineSpacing(5).multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

/// 1:02:03、12:30：要点末尾的时间、播放条上的进度
func clockText(_ seconds: Int) -> String {
    seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
}

/// 正文里的一张图：铺满栏宽，在后台解码，没到之前留一块底色
private struct Picture: View {
    let store: Store
    let name: String
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(.quaternary).aspectRatio(16 / 9, contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: name) { image = await DetailView.decode(store.files.url(of: name), maxPixel: 1400) }
    }
}
