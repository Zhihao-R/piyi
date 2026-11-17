import SwiftUI
import Library
import Canvas
import Tokens

/// A card's text; the detail view has only this one layout, getting finer top to bottom: source and time, title, a one-line description, key points, full text, transcript, tags.
/// For cards without visuals it's the whole thing; for cards with visuals it's the narrow column beside the visual (compact), one size smaller, without inline images
struct Reader: View {
    let store: Store
    let card: Card
    /// Other images (excluding the cover)
    let images: [String]
    var compact = false
    /// Laid-out full text and transcript (see DetailView.bodyText). An article's body isn't here: it's laid out paragraph by paragraph with its images
    let bodyText: NSAttributedString?
    let transcriptText: NSAttributedString?
    /// A citation clicked in the discussion: scroll to this passage and flash it
    let highlight: LongText.Highlight?
    /// Buttons at the right end of the source row: discuss, put on the table
    let discuss: DetailView.Action
    let follow: (URL) -> Void
    /// A timestamp clicked in the description or transcript: play from that second
    let seek: (Int) -> Void
    /// A key point clicked: scroll to the passage it's based on, video plays from that second
    let jump: (Passage) -> Void
    let refetch: () -> Void
    /// The text of a note you wrote changed: save it
    let rewrite: (String) -> Void
    /// The note's text as currently edited; nil means not touched yet
    @State private var draft: String?

    private var type: Reading.Scale { compact ? Reading.narrow : Reading.wide }
    /// Article: the body records image positions, images go back after their passage in the original
    private var isArticle: Bool { !compact && DetailView.isArticle(card) }
    /// A short line you wrote: the line itself is the content, no model-written title or paraphrase added
    private var isQuote: Bool { card.kind == .text && (card.text ?? "").count <= CardType.shortTextLimit }

    var body: some View {
        Group {
            if compact {
                ScrollView { column }
            } else {
                // Shrink to the content's height if it fits (a card with only a few lines doesn't stretch into a whole blank page); scroll only if it doesn't
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
                // The line you jotted down when collecting: says better than the model's description why you collected it
                if let note = card.note { Text(note).font(.system(size: type.lead)).lineSpacing(5).textSelection(.enabled) }
                status
            }
            if let summary = card.summary { Points(summary: summary, sources: sources, size: type.lead, jump: jump) }
            // Notes you wrote can be edited here too: opened from the library, search or discussion, no need to go back to their board. Not ones in Trash
            if card.form == .note, card.trashedAt == nil {
                NoteField(text: Binding(get: { draft ?? card.text ?? "" }, set: { draft = $0 }), type: type, highlight: highlight, commit: rewrite)
            } else if isArticle { article } else if let bodyText { LongText(bodyText, highlight: highlight, onLink: link) }
            if let transcriptText {
                VStack(alignment: .leading, spacing: type.gap / 2) {
                    // Platform subtitles and local transcription differ in reliability
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

    /// The passage each key point is based on, found again in the current original by its saved wording; a key point whose original changed and can't be found isn't clickable.
    /// This requires splitting the original, so compute it once in the background and keep it, not on every redraw
    @State private var sources: [Passage?] = []

    private func locate() async {
        let card = card
        sources = await Task.detached(priority: .userInitiated) {
            let passages = Passages.of(card)
            return (card.summaryAnchors ?? []).map { anchor in anchor.flatMap { Passages.find($0.quote, part: $0.part, among: passages) } }
        }.value
    }

    /// An article's body: cover, byline, then text and images in the original order
    @ViewBuilder private var article: some View {
        let (credits, body) = Passages.credits(in: card.body ?? "", for: card)
        // For articles without a separate cover, the cover is the first image, which appears in the body
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

    /// WeChat account · source (click to open the original or the original file) · date collected, with "Discuss" at the right end
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

    /// When this card is incomplete, say why: not fully fetched (can fetch again), understanding failed, waiting for a key
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

    /// Tags reduced to a line of gray text, main colors shrunk to small dots, both at the end
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

    /// Timestamp links are seek:seconds; other links open in the browser as usual
    private func link(_ url: URL) -> Bool {
        guard url.scheme == "seek", let seconds = Int(url.absoluteString.dropFirst("seek:".count)) else { return false }
        seek(seconds)
        return true
    }
}

/// The body of a note you wrote, directly editable. The text field holds the source, with markup faded and headings enlarged, the same look as writing on the canvas (see NoteEditor).
/// Saved on clicking elsewhere, pressing Esc, or closing detail view
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

    /// Grows downward as you write more: measured the same way as LongText
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
        /// The version already saved: don't save again if unchanged
        var saved = ""
        var flashed: UUID?

        init(style: Markdown.Style) { self.style = style }

        /// Restyle on every character change. Leave it alone while pinyin is still being chosen so the input method isn't interrupted
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

        /// Don't save when emptied: deleting cards belongs to the canvas, and having the card vanish here the moment all text is deleted would be too abrupt
        func save(_ view: NSTextView) {
            let text = view.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text != saved else { return }
            saved = text
            commit?(text)
        }

        /// Esc: done writing (press again to close detail view)
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            textView.window?.makeFirstResponder(nil)
            return true
        }
    }
}

/// Key points: one per line in a light-background block; lines starting with "· " are drawn as bullets, other lines (like "Based on the description only") as small explanatory text.
/// A key point whose basis can be found is a button that jumps to that passage in the original; a basis in the transcript shows its time at the end
private struct Points: View {
    let summary: String
    /// One-to-one with the lines starting with "· "
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

/// 1:02:03, 12:30: the time at the end of key points, the progress on the playback bar
func clockText(_ seconds: Int) -> String {
    seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
}

/// An image in the body: fills the column width, decoded in the background, a block of background color until it arrives
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
