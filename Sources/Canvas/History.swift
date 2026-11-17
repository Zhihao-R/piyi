import AppKit
import Library

/// One undoable change. Its reverse undoes it; undoing registers the reverse step in turn, and that gives redo
public enum Edit: Sendable {
    /// A placement changed from old to new: position, size, angle, stacking order, crop
    case moved(old: [Placement], new: [Placement])
    /// A placement appears or disappears: keeps the whole row so undo puts it back under its original ID
    case placed(added: [Placement], removed: [Placement])
    /// A card went into the trash
    case trashed([Int64])
    /// A card was restored from the trash
    case restored([Int64])
    /// A text card you wrote changed its text or background color
    case written(old: [Note], new: [Note])

    var reversed: Edit {
        switch self {
        case .moved(let old, let new): .moved(old: new, new: old)
        case .placed(let added, let removed): .placed(added: removed, removed: added)
        case .trashed(let cards): .restored(cards)
        case .restored(let cards): .trashed(cards)
        case .written(let old, let new): .written(old: new, new: old)
        }
    }

    var isEmpty: Bool {
        switch self {
        case .moved(let old, _): old.isEmpty
        case .placed(let added, let removed): added.isEmpty && removed.isEmpty
        case .trashed(let cards), .restored(let cards): cards.isEmpty
        case .written(let old, let new): old == new
        }
    }

    /// Boards whose placements changed: their thumbnail collages need redrawing
    public var boards: Set<Int64> {
        switch self {
        case .moved(let old, _): Set(old.map(\.boardID))
        case .placed(let added, let removed): Set((added + removed).map(\.boardID))
        case .trashed, .restored, .written: []
        }
    }
}

// MARK: Undo: one history per board and per card view; ⌘Z only undoes the one in front of you

extension CanvasView: NSMenuItemValidation {
    var undoHistory: UndoManager? { content.map(undoHistory) }

    func undoHistory(of place: CanvasContent) -> UndoManager {
        if let h = undoHistories[place] { return h }
        let h = UndoManager()
        undoHistories[place] = h
        return h
    }

    /// Discard the undo history of this place (board deleted); nil discards every place (card deleted for good)
    public func forgetUndoHistory(of place: CanvasContent? = nil) {
        if let place { undoHistories[place] = nil } else { undoHistories = [:] }
    }

    /// Records a step just done, in the place where it was done (by default the one in front of you; the board may have changed while writing to the library).
    /// One step can contain several changes that ⌘Z undoes together; steps where nothing changed are not recorded
    public func record(_ edits: Edit..., as name: String, on place: CanvasContent? = nil) {
        let edits = edits.filter { !$0.isEmpty }
        guard !edits.isEmpty, let history = (place ?? content).map(undoHistory) else { return }
        history.beginUndoGrouping()
        for edit in edits { history.registerUndo(withTarget: self) { $0.apply(edit.reversed, as: name) } }
        history.setActionName(name)
        history.endUndoGrouping()
    }

    /// Performs a change (undo, redo, or finishing a text card): first registers the reverse step (it must be registered synchronously during undo to reach the redo stack),
    /// then writes to the library and selects what changed once the shell refreshes. Returns the library write task; placement changes are recorded synchronously and return nil
    @discardableResult
    func apply(_ edit: Edit, as name: String) -> Task<Void, Never>? {
        let selects: (Placement) -> Bool
        switch edit {
        case .moved(_, let new):
            // Changing placements registers its own reverse step
            commit(new, as: name)
            selection = Set(new.compactMap(\.id)).intersection(items.keys)
            return nil
        case .placed(let added, _): selects = { p in added.contains { $0.id == p.id } }
        case .restored(let cards): selects = { p in p.cardID.map(cards.contains) == true }
        case .written(_, let new): selects = { p in new.contains { $0.card == p.cardID } }
        case .trashed: selects = { _ in false }
        }
        record(edit, as: name)
        let store = store
        return Task {
            do {
                switch edit {
                case .placed(let added, let removed): try await store.exchangePlacements(adding: added, removing: removed.compactMap(\.id))
                case .trashed(let cards): try await store.trash(cards)
                case .restored(let cards): try await store.restore(cards)
                case .written(_, let new): try await store.saveNotes(new)
                case .moved: break
                }
            } catch {
                delegate?.canvasDidEdit(self, error: error)
                return
            }
            await delegate?.canvas(self, didApply: edit)
            selection = Set(items.values.filter { selects($0.placement) }.map(\.id))
        }
    }

    /// While typing, undo undoes the text
    private var activeHistory: UndoManager? { noteEditor?.history ?? undoHistory }

    @objc func undo(_ sender: Any?) {
        // Mid-crop: undo this crop first
        if cropper != nil { endCrop(commit: false) } else { activeHistory?.undo() }
    }

    @objc func redo(_ sender: Any?) { activeHistory?.redo() }

    /// The result of gathering is a temporary arrangement; undo waits until gathering is exited
    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            if cropper != nil { item.title = String(localized: "取消裁剪"); return true }
            let name = activeHistory?.undoActionName ?? ""
            item.title = name.isEmpty ? String(localized: "撤销") : String(localized: "撤销\(name)")
            return gathering == nil && activeHistory?.canUndo == true
        case #selector(redo(_:)):
            let name = activeHistory?.redoActionName ?? ""
            item.title = name.isEmpty ? String(localized: "重做") : String(localized: "重做\(name)")
            return gathering == nil && cropper == nil && activeHistory?.canRedo == true
        case #selector(copy(_:)):
            return gathering == nil && content != .collection(.trash) && selectedItems.contains { $0.placement.cardID != nil }
        default:
            return true
        }
    }
}
