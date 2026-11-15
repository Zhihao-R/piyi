import AppKit
import Library
import Tokens

/// 正在写的那张文字卡：画布上只有它临时盖一个真的文本框（开发规矩第一条），写完就拿掉，卡片回到一张画好的图。
/// 文本框里是原文，标记变淡、标题变大，字号和卡片上一样。卡片多大文本框就多大，不自动长：写多了在框里滚动，卡片大小由你拉
@MainActor
final class NoteEditor: NSView, NSTextViewDelegate {
    /// 改的是哪条摆放；nil 是新写的，写完才进资料库
    let placement: Int64?
    /// 改之前的文字和底色；新写的为 nil
    let original: Note?
    /// 世界坐标里的框，就是卡片的框
    let world: CGRect
    let rotation: CGFloat
    let textView = NSTextView(usingTextLayoutManager: false)
    private let scroller = NSScrollView()
    /// 写字时的撤销记录：写着字时 ⌘Z 撤字，写完才轮到画板的撤销
    let history = UndoManager()
    /// 文本框失去焦点（点了别处、按了 Esc）
    var onEnd: (() -> Void)?
    private var scale: CGFloat = 0

    override var isFlipped: Bool { true }

    init(placement: Int64?, original: Note?, frame: CGRect, rotation: CGFloat) {
        (self.placement, self.original, world, self.rotation) = (placement, original, frame, rotation)
        super.init(frame: .zero)
        wantsLayer = true
        layer!.backgroundColor = Palette.tint(original?.tint).now.cg
        // 写着的卡是拿起来的样子
        layer!.shadowOpacity = Float(CardShape.lift.opacity)
        textView.delegate = self
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.insertionPointColor = Self.color(Palette.ink.now)
        textView.string = original?.text ?? ""
        textView.isVerticallyResizable = true
        textView.autoresizingMask = .width
        textView.textContainer?.widthTracksTextView = true
        scroller.documentView = textView
        scroller.drawsBackground = false
        scroller.hasVerticalScroller = true
        scroller.autohidesScrollers = true
        scroller.scrollerStyle = .overlay
        addSubview(scroller)
    }
    required init?(coder: NSCoder) { fatalError() }

    var text: String { textView.string }

    /// 按镜头摆到卡片的位置上：center 是卡片中心在视图里的位置（AppKit 坐标，y 向上）
    func layout(center: CGPoint, scale: CGFloat) {
        let size = CGSize(width: world.width * scale, height: world.height * scale)
        frameCenterRotation = 0
        frame = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        frameCenterRotation = -rotation * 180 / .pi
        let p = Self.padding * scale
        scroller.frame = bounds.insetBy(dx: p, dy: p)
        textView.frame.size.width = scroller.contentSize.width
        let r = CardShape.corner * scale
        layer!.cornerRadius = r
        layer!.shadowRadius = CardShape.lift.radius * scale
        layer!.shadowOffset = CGSize(width: 0, height: -CardShape.lift.offset * scale)
        layer!.shadowPath = CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil)
        // 字号换了要重排：放在文本框定好宽度之后
        if scale != self.scale {
            self.scale = scale
            restyle()
        }
    }

    /// 淡出后拿掉
    func dismiss() {
        textView.isEditable = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.fade
            animator().alphaValue = 0
        }
        Task {
            try? await Task.sleep(for: .seconds(Motion.fade))
            removeFromSuperview()
        }
    }

    // MARK: 排版

    /// 版式和卡片上同一套（CardArt.noteStyle），按镜头倍率换成屏幕点
    private var style: Markdown.Style { CardArt.noteStyle(t: CardSize.typeWidth * scale, ink: Self.color) }
    private static let padding = CardSize.typeWidth * CardType.padding

    private static func color(_ c: RGBA) -> NSColor { NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a) }

    /// 每改一个字重新上一遍样式（便签不长，整段重排也就一两毫秒）。拼音还没选字时不动，免得打断输入法
    private func restyle() {
        guard scale > 0, let storage = textView.textStorage, !textView.hasMarkedText() else { return }
        let styled = Markdown.styled(storage.string, style: style)
        storage.beginEditing()
        styled.enumerateAttributes(in: NSRange(location: 0, length: styled.length)) { attributes, range, _ in
            storage.setAttributes(attributes, range: range)
        }
        storage.endEditing()
        // 新打的字先按正文样式出现，下一次重排再按它所在的写法上样式
        let plain = Markdown.styled(" ", style: style)
        textView.typingAttributes = plain.attributes(at: 0, effectiveRange: nil)
    }

    // MARK: 文本框

    func textDidChange(_ notification: Notification) { restyle() }

    func textDidEndEditing(_ notification: Notification) { onEnd?() }

    func undoManager(for view: NSTextView) -> UndoManager? { history }

    /// Esc：写完
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(cancelOperation(_:)) else { return false }
        window?.makeFirstResponder(superview)
        return true
    }
}

extension BoardItem {
    /// 你写的文字卡
    public var isNote: Bool { if case .card(let card) = face { card.form == .note } else { false } }
}

// MARK: 画布上写字

extension CanvasView {
    /// 改一张文字卡：取出全文，盖上文本框，底下那张图先藏起来
    public func edit(_ id: Int64) {
        guard isEditable, let item = items[id], item.isNote, case .card(let card) = item.face else { return }
        Task {
            guard let note = try? await store.notes([card.id]).first, items[id] != nil, isEditable else { return }
            begin(NoteEditor(placement: id, original: note, frame: item.placement.frame, rotation: item.placement.rotation))
        }
    }

    /// 写一张新的文字卡：point 附近找块空地（默认是视野中央），写完才进资料库，什么都没写就当没发生
    public func addNote(at point: CGPoint? = nil) {
        guard isEditable else { return }
        begin(NoteEditor(placement: nil, original: nil, frame: Layout.spot(CardSize.note, near: point ?? visibleCenter, avoiding: occupied), rotation: 0))
    }

    private func begin(_ editor: NoteEditor) {
        finishEditing()
        noteEditor = editor
        selection = []
        editor.onEnd = { [weak self, weak editor] in
            guard let self, let editor, self.noteEditor === editor else { return }
            self.finishEditing()
        }
        addSubview(editor)
        if let id = editor.placement { live[id]?.isHidden = true }
        layoutEditor()
        window?.makeFirstResponder(editor.textView)
        updateOverlay()
    }

    /// 镜头动了：跟着卡片的位置摆
    func layoutEditor() {
        guard let editor = noteEditor else { return }
        let c = screenPoint(CGPoint(x: editor.world.midX, y: editor.world.midY))
        editor.layout(center: CGPoint(x: c.x, y: bounds.height - c.y), scale: camera.scale)
    }

    /// 写完：文字变了就存，写空了就删（都能撤销）；文本框淡出，卡片回到一张画好的图。
    /// 返回写资料库的那件事，退出 App 前等它写完
    @discardableResult
    public func finishEditing() -> Task<Void, Never>? {
        guard let editor = noteEditor else { return nil }
        noteEditor = nil
        if window?.firstResponder === editor.textView { window?.makeFirstResponder(self) }
        updateOverlay()
        let text = editor.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = editor.placement else {
            guard !text.isEmpty, let board else { editor.dismiss(); return nil }
            return Task {
                await createNote(text, frame: editor.world, on: board, as: String(localized: "添加文字"))
                // 画布读回新卡、开始画了再淡出，中间不空一下
                editor.dismiss()
            }
        }
        editor.dismiss()
        live[id]?.isHidden = false
        guard items[id] != nil, let old = editor.original else { return nil }
        // 写空了：这张卡进废纸篓，放了它的每个画板上都拿掉
        if text.isEmpty { return apply(.trashed([old.card]), as: String(localized: "删除文字")) }
        guard text != old.text else { return nil }
        let new = Note(card: old.card, text: text, tint: old.tint)
        show([new])
        return apply(.written(old: [old], new: [new]), as: String(localized: "编辑文字"))
    }

    /// 把一段字写成文字卡，放在眼前的空处（讨论的回答收成文字卡）。和亲手写的走同一条路，⌘Z 撤回
    @discardableResult
    public func addNote(_ text: String, as name: String) -> Task<Void, Never>? {
        guard isEditable, let board else { return nil }
        let frame = Layout.spot(CardSize.note, near: visibleCenter, avoiding: occupied)
        return Task { await createNote(text, frame: frame, on: board, as: name) }
    }

    private func createNote(_ text: String, frame: CGRect, on board: Int64, as name: String) async {
        do {
            let p = try await store.createNote(text, on: board, frame: frame)
            // 撤销「添加」就是把它放进废纸篓
            let edit = Edit.restored([p.cardID!])
            record(edit, as: name, on: .board(board))
            await delegate?.canvas(self, didApply: edit)
        } catch {
            delegate?.canvasDidEdit(self, error: error)
        }
    }

    /// 文字卡的新样子先画上，不等资料库读回来；同一张卡在这个画板上的每一份都换
    private func show(_ notes: [Note]) {
        for note in notes {
            for (id, var item) in items {
                guard case .card(var face) = item.face, face.id == note.card else { continue }
                face.excerpt = String(note.text.prefix(CardFace.excerptLength))
                face.length = note.text.unicodeScalars.count
                face.tint = note.tint
                item.face = .card(face)
                items[id] = item
                if let l = live[id] { refresh(l, with: item) }
            }
        }
    }

}
