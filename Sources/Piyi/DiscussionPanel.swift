import SwiftUI
import Library
import Intelligence
import Canvas
import Tokens

/// Discussion bar: docked at the window's right, collapsible. Top to bottom: title row, table, conversation, suggested questions, input field.
/// Minimal copy: no usage hints, secondary buttons are icons only with explanations on hover
struct DiscussionPanel: View {
    let model: AppModel
    @State private var targeted = false

    private var discussions: DiscussionModel { model.discussions }

    var body: some View {
        VStack(spacing: 0) {
            header
            DeskStrip(model: model)
            Divider()
            ChatList(model: model)
            InputBar(discussions: discussions)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(targeted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.clear)).padding(6))
        .animation(.spring(Motion.lift), value: targeted)
        // Cards dragged from the canvas: put on the table
        .dropDestination(for: String.self) { strings, _ in
            guard let cards = model.draggedCards(strings) else { return false }
            discussions.place(cards)
            return true
        } isTargeted: { targeted = $0 && model.dragging }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(discussions.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer()
            Button { discussions.newDiscussion() } label: { Image(systemName: "square.and.pencil").frame(width: 28, height: 28) }
                .help("新讨论")
            Button { discussions.isOpen = false } label: { Image(systemName: "sidebar.trailing").frame(width: 28, height: 28) }
                .help("收起")
        }
        .buttonStyle(.hoverIcon)
        .foregroundStyle(.secondary)
        .padding(.leading, 16).padding(.trailing, 10).frame(height: 44)
    }
}

/// Table: small card strips, translucent if in Trash; hover shows an x to take it off the table, click opens detail view. "+" is the @ card pick
private struct DeskStrip: View {
    let model: AppModel

    var body: some View {
        let discussions = model.discussions
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(discussions.desk, id: \.id) { card in
                    DeskChip(card: card) { model.detail = card.id } remove: { discussions.takeOff(card.id!) }
                }
                Button { model.discussions.picking = true } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26)
                }
                .buttonStyle(.hoverIcon)
                .foregroundStyle(.secondary)
                .help("引用卡片")
            }
            .padding(.horizontal, 12)
        }
        .scrollIndicators(.never)
        .frame(height: 40)
        .animation(.spring(Motion.lift), value: discussions.desk.map(\.id))
    }
}

private struct DeskChip: View {
    let card: Card
    let open: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(card.displayTitle).lineLimit(1).frame(maxWidth: 150, alignment: .leading)
            if hovering {
                Button(action: remove) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 18, height: 18) }
                    .buttonStyle(.hoverIcon)
                    .foregroundStyle(.secondary)
                    .help("取消引用")
            }
        }
        .font(.system(size: 12))
        .padding(.leading, 10).padding(.trailing, hovering ? 4 : 10).frame(height: Chrome.chipHeight)
        .background(hovering ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary), in: Capsule())
        .opacity(card.trashedAt == nil ? 1 : 0.4)
        .contentShape(Capsule())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .animation(.spring(Motion.lift), value: hovering)
    }
}

// MARK: Conversation

private struct ChatList: View {
    let model: AppModel

    var body: some View {
        let d = model.discussions
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if d.events.isEmpty && !d.isRunning {
                        empty
                    }
                    ForEach(d.events) { event in row(event) }
                    if d.isRunning, let current = d.current {
                        let text = d.writing[current] ?? ""
                        if text.isEmpty { Waiting() } else { AnswerBody(text: text, citations: [], streaming: true, discussions: d) }
                    } else if d.isUnfinished {
                        HStack(spacing: 8) {
                            Text("没答完").foregroundStyle(.secondary)
                            Button { d.retry() } label: { Text("重试").padding(.horizontal, 8).frame(height: 24) }.buttonStyle(.hover)
                        }
                        .font(.system(size: 12))
                    }
                    if d.isTooLong {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("这段讨论太长了").foregroundStyle(.secondary)
                            Button { d.startOver() } label: { Text("带着引用的卡开新讨论").padding(.horizontal, 10).frame(height: Chrome.chipHeight) }
                                .buttonStyle(.chip)
                        }
                        .font(.system(size: 12))
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: d.events.count) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: d.current.flatMap { d.writing[$0] }) { proxy.scrollTo("end", anchor: .bottom) }
        }
        .frame(maxHeight: .infinity)
    }

    /// Nothing said yet: with cards on the table, write one line of ground rules and list earlier discussions about these cards; an empty table gets just one line
    @ViewBuilder private var empty: some View {
        let d = model.discussions
        VStack(alignment: .leading, spacing: 10) {
            if d.desk.isEmpty { Text("还没有引用卡片").foregroundStyle(.tertiary) }
            if !d.earlier.isEmpty { Line(String(localized: "之前聊过")) }
            ForEach(d.earlier) { summary in
                Button { d.open(summary.id) } label: {
                    Label(summary.discussion.displayName, systemImage: "bubble.left.and.bubble.right").lineLimit(1)
                        .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                }
                .buttonStyle(.hoverRow)
                .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .padding(.top, 8)
    }

    @ViewBuilder private func row(_ event: DiscussionEvent) -> some View {
        let d = model.discussions
        switch event.what {
        case .question(let text):
            Text(text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: InputBar.corner))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 32)
        case .answer(let answer):
            AnswerView(answer: answer, discussions: d)
        case .result(let result):
            VStack(alignment: .leading, spacing: 6) {
                Line(result.label)
                if case .cards(let cards)? = result.shown {
                    ForEach(cards, id: \.self) { card in
                        HStack(spacing: 8) {
                            Button { model.detail = card } label: {
                                Text(d.titles[card] ?? String(localized: "卡 \(card)")).lineLimit(1)
                                    .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                            }
                            .buttonStyle(.hoverRow)
                            if d.onDesk(card) {
                                Text("已引用").foregroundStyle(.tertiary).padding(.horizontal, 10)
                            } else {
                                Button { d.place([card]) } label: { Text("引用").padding(.horizontal, 10).frame(height: 24) }
                                    .buttonStyle(.hover)
                            }
                        }
                        .font(.system(size: 12))
                    }
                }
            }
        case .placed(let mention): Line(String(localized: "引用 · \(mention.title)"))
        case .removed(let mention): Line(String(localized: "取消引用 · \(mention.title)"))
        case .calls, .renamed: EmptyView()
        }
    }
}

/// Gray text in the conversation: put on the table, taken off the table, which tool was used
private struct Line: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.system(size: 12)).foregroundStyle(.tertiary) }
}

/// An answer: hovering shows "Save as Note" and "Copy"; after copying it turns into a check for a moment
private struct AnswerView: View {
    let answer: Answer
    let discussions: DiscussionModel
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            AnswerBody(text: answer.text, citations: answer.citations, streaming: false, discussions: discussions)
            HStack(spacing: 2) {
                Button { discussions.collect(answer) } label: { Image(systemName: "note.text.badge.plus").frame(width: 24, height: 24) }
                    .help("收成文字卡")
                Button {
                    discussions.copy(answer)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(Motion.notice / 2)); copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").contentTransition(.symbolEffect(.replace)).frame(width: 24, height: 24)
                }
                .help("拷贝")
            }
            .buttonStyle(.hoverIcon)
            .padding(.leading, -6)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.fade, value: hovering)
    }
}

/// The answer body: rendered Markdown, citations drawn as small gray numbers. Hover shows the original wording and source; click opens that passage on the canvas
private struct AnswerBody: View {
    let text: String
    let citations: [Citation]
    let streaming: Bool
    let discussions: DiscussionModel

    var body: some View {
        LongText(AnswerText.attributed(text, citations: citations, streaming: streaming) { discussions.titles[$0] }) { link in
            guard link.scheme == "cite", let i = Int(link.absoluteString.dropFirst("cite:".count)), citations.indices.contains(i) else { return false }
            discussions.open(citations[i])
            return true
        }
    }
}

@MainActor enum AnswerText {
    static let style = Markdown.Style(body: 13, lineSpacing: 5) { ink in
        switch ink {
        case .primary: NSColor.labelColor
        case .secondary: NSColor.secondaryLabelColor
        case .faint: NSColor.tertiaryLabelColor
        case .link: NSColor.linkColor
        }
    }

    /// Citations are first replaced with private-use placeholder characters and swapped back to small numbers after Markdown rendering: layout never touches them, and the numbers don't fall under Markdown rules
    static func attributed(_ text: String, citations: [Citation], streaming: Bool, title: (Int64) -> String?) -> NSAttributedString {
        var order: [String] = [], source = ""
        for piece in Citations.pieces(text, streaming: streaming) {
            switch piece {
            case .text(let t): source += t
            case .cite(let ref):
                if !order.contains(ref) { order.append(ref) }
                source += "\u{E000}\(ref)\u{E001}"
            }
        }
        let out = NSMutableAttributedString(attributedString: Markdown.rendered(source, style: style))
        let marks = try! NSRegularExpression(pattern: "\u{E000}([^\u{E001}]*)\u{E001}")
        for match in marks.matches(in: out.string, range: NSRange(location: 0, length: out.length)).reversed() {
            let ref = (out.string as NSString).substring(with: match.range(at: 1))
            let number = (order.firstIndex(of: ref) ?? 0) + 1
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium), .baselineOffset: 5, .foregroundColor: NSColor.secondaryLabelColor,
            ]
            if let paragraph = out.attribute(.paragraphStyle, at: match.range.location, effectiveRange: nil) { attributes[.paragraphStyle] = paragraph }
            if let i = citations.firstIndex(where: { $0.ref == ref }) {
                attributes[.link] = URL(string: "cite:\(i)")!
                attributes[.toolTip] = tip(citations[i], title: title)
            }
            // A non-breaking narrow space before the number: the number never wraps to the next line alone
            out.replaceCharacters(in: match.range, with: NSAttributedString(string: "\u{202F}\(number)", attributes: attributes))
        }
        return out
    }

    /// Hover popup: the saved original wording and the source (card name, timestamp)
    static func tip(_ c: Citation, title: (Int64) -> String?) -> String {
        let source = [c.card.flatMap(title), c.seconds.map { Transcript.stamp(Double($0)) }].compactMap { $0 }.joined(separator: " · ")
        return quoted(c.quote) + (source.isEmpty ? "" : "\n\(source)")
    }
}

// MARK: Input

private struct InputBar: View {
    @Bindable var discussions: DiscussionModel
    @State private var text = ""
    @State private var matches: [Card] = []
    @FocusState private var focused: Bool

    /// Text typed after the last @ in the input field: picking cards
    private var atQuery: String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        let query = text[text.index(after: at)...]
        return query.contains(where: \.isWhitespace) ? nil : String(query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if atQuery != nil, !matches.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(matches, id: \.id) { card in
                        Button { pick(card) } label: {
                            Text(card.displayTitle).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).frame(height: 28)
                        }
                        .buttonStyle(.hoverRow)
                    }
                }
                .font(.system(size: 12))
                .padding(4)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: Self.corner))
            } else if !discussions.isRunning, !discussions.suggestions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(discussions.suggestions, id: \.self) { s in
                        Button { discussions.send(s) } label: { Text(s).padding(.horizontal, 10).frame(height: Chrome.chipHeight) }
                            .buttonStyle(.chip)
                            .font(.system(size: 12))
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 6) {
                TextField("问点什么", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit(submit)
                    .onKeyPress(.escape) {
                        guard atQuery != nil, let at = text.lastIndex(of: "@") else { return .ignored }
                        text = String(text[..<at])
                        return .handled
                    }
                    .padding(.vertical, 4)
                Button {
                    discussions.isRunning ? discussions.stop() : submit()
                } label: {
                    Image(systemName: discussions.isRunning ? "stop.circle.fill" : "arrow.up.circle.fill").font(.system(size: 20))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.hoverIcon)
                .foregroundStyle(discussions.isRunning || !text.trimmingCharacters(in: .whitespaces).isEmpty ? .primary : .tertiary)
                .help(discussions.isRunning ? "停止" : "发送")
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: Self.corner))
        }
        .padding(12)
        .task(id: atQuery) {
            guard let query = atQuery else { return matches = [] }
            matches = await discussions.cards(matching: query)
        }
        .onChange(of: discussions.picking) {
            guard discussions.picking else { return }
            discussions.picking = false
            if atQuery == nil { text += "@" }
            focused = true
        }
    }

    /// The only corner radius for blocks in the discussion bar: questions, the @ card pick list, the input field
    static let corner: CGFloat = 12

    private func submit() {
        if atQuery != nil, let first = matches.first { return pick(first) }
        guard !discussions.isRunning, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        discussions.send(text)
        text = ""
    }

    private func pick(_ card: Card) {
        if let at = text.lastIndex(of: "@") { text = String(text[..<at]) }
        discussions.place([card.id!])
    }
}
