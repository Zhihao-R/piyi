import AppKit
import Library
import Tokens

/// The text card being written: the only thing on the canvas that temporarily gets a real text box over it (the first coding rule in CONTRIBUTING.md); it's removed when done and the card goes back to a drawn image.
/// The text box holds the source text, with markers faded and headings larger, at the same font size as on the card. The text box is as big as the card and doesn't grow by itself: write more and it scrolls inside the box; you set the card size by dragging
@MainActor
final class NoteEditor: NSView, NSTextViewDelegate {
    /// Which placement is being edited; nil for a new one, which only goes into the library once done
    let placement: Int64?
    /// The text and background color before editing; nil for a new one
    let original: Note?
    /// The frame in world coordinates, i.e. the card's frame
    let world: CGRect
    let rotation: CGFloat
    let textView = NSTextView(usingTextLayoutManager: false)
    private let scroller = NSScrollView()
    /// Undo history while typing: while typing ⌘Z undoes text; the board's undo only comes once done
    let history = UndoManager()
    /// The text box lost focus (clicked elsewhere, pressed Esc)
    var onEnd: (() -> Void)?
    private var scale: CGFloat = 0

    override var isFlipped: Bool { true }

    init(placement: Int64?, original: Note?, frame: CGRect, rotation: CGFloat) {
        (self.placement, self.original, world, self.rotation) = (placement, original, frame, rotation)
        super.init(frame: .zero)
        wantsLayer = true
        layer!.backgroundColor = Palette.tint(original?.tint).now.cg
        // The card being written looks lifted
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

    /// Placed over the card by the camera: center is the card center's position in the view (AppKit coordinates, y up)
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
        // A changed font size needs relayout: do it after the text box's width is set
        if scale != self.scale {
            self.scale = scale
            restyle()
        }
    }

    /// Removed after fading out
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

    // MARK: Layout

    /// Same layout as on the card (CardArt.noteStyle), converted to screen points by the camera scale
    private var style: Markdown.Style { CardArt.noteStyle(t: CardSize.typeWidth * scale, ink: Self.color) }
    private static let padding = CardSize.typeWidth * CardType.padding

    private static func color(_ c: RGBA) -> NSColor { NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a) }

    /// Reapply styles on every character change (notes are short; relaying out the whole thing takes a millisecond or two). Leave it alone while pinyin is still being composed, so the input method isn't interrupted
    private func restyle() {
        guard scale > 0, let storage = textView.textStorage, !textView.hasMarkedText() else { return }
        let styled = Markdown.styled(storage.string, style: style)
        storage.beginEditing()
        styled.enumerateAttributes(in: NSRange(location: 0, length: styled.length)) { attributes, range, _ in
            storage.setAttributes(attributes, range: range)
        }
        storage.endEditing()
        // Newly typed text first appears in body style; the next relayout styles it by the form it's in
        let plain = Markdown.styled(" ", style: style)
        textView.typingAttributes = plain.attributes(at: 0, effectiveRange: nil)
    }

    // MARK: Text box

    func textDidChange(_ notification: Notification) { restyle() }

    func textDidEndEditing(_ notification: Notification) { onEnd?() }

    func undoManager(for view: NSTextView) -> UndoManager? { history }

    /// Esc: done writing
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(cancelOperation(_:)) else { return false }
        window?.makeFirstResponder(superview)
        return true
    }
}

extension BoardItem {
    /// A text card you wrote
    public var isNote: Bool { if case .card(let card) = face { card.form == .note } else { false } }
}

// MARK: Writing on the canvas

extension CanvasView {
    /// Edit a text card: take out the full text, put the text box over it, and hide the image underneath for now
    public func edit(_ id: Int64) {
        guard isEditable, let item = items[id], item.isNote, case .card(let card) = item.face else { return }
        Task {
            guard let note = try? await store.notes([card.id]).first, items[id] != nil, isEditable else { return }
            begin(NoteEditor(placement: id, original: note, frame: item.placement.frame, rotation: item.placement.rotation))
        }
    }

    /// Write a new text card: find free space near point (the center of the view by default); it only goes into the library once done, and if nothing was written it's as if nothing happened
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

    /// The camera moved: follow the card's position
    func layoutEditor() {
        guard let editor = noteEditor else { return }
        let c = screenPoint(CGPoint(x: editor.world.midX, y: editor.world.midY))
        editor.layout(center: CGPoint(x: c.x, y: bounds.height - c.y), scale: camera.scale)
    }

    /// Done writing: save if the text changed, delete if it was emptied (both undoable); the text box fades out and the card goes back to a drawn image.
    /// Returns the library write task; quitting the App waits for it to finish
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
                // Fade out only after the canvas has read back the new card and started drawing, so there's no blank moment
                editor.dismiss()
            }
        }
        editor.dismiss()
        live[id]?.isHidden = false
        guard items[id] != nil, let old = editor.original else { return nil }
        // Emptied: this card goes to the trash and is removed from every board it was on
        if text.isEmpty { return apply(.trashed([old.card]), as: String(localized: "删除文字")) }
        guard text != old.text else { return nil }
        let new = Note(card: old.card, text: text, tint: old.tint)
        show([new])
        return apply(.written(old: [old], new: [new]), as: String(localized: "编辑文字"))
    }

    /// Turns some text into a text card placed in free space in front of you (a discussion answer collected as a text card). Takes the same path as one written by hand; ⌘Z undoes it
    @discardableResult
    public func addNote(_ text: String, as name: String) -> Task<Void, Never>? {
        guard isEditable, let board else { return nil }
        let frame = Layout.spot(CardSize.note, near: visibleCenter, avoiding: occupied)
        return Task { await createNote(text, frame: frame, on: board, as: name) }
    }

    private func createNote(_ text: String, frame: CGRect, on board: Int64, as name: String) async {
        do {
            let p = try await store.createNote(text, on: board, frame: frame)
            // Undoing "add" means putting it in the trash
            let edit = Edit.restored([p.cardID!])
            record(edit, as: name, on: .board(board))
            await delegate?.canvas(self, didApply: edit)
        } catch {
            delegate?.canvasDidEdit(self, error: error)
        }
    }

    /// Draw the text card's new look right away without waiting for the library read; every copy of the card on this board is updated
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
