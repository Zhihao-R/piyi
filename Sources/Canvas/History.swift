import AppKit
import Library

/// 一步可撤销的改动。反过来就是撤销它，撤销时再登记反过来的那一步，重做就有了
public enum Edit: Sendable {
    /// 摆放从 old 改成 new：位置、大小、角度、叠放顺序、裁剪
    case moved(old: [Placement], new: [Placement])
    /// 摆放出现、消失：记着整行，撤销时按原编号放回
    case placed(added: [Placement], removed: [Placement])
    /// 卡进了废纸篓
    case trashed([Int64])
    /// 卡从废纸篓恢复
    case restored([Int64])
    /// 你写的文字卡改了文字、底色
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

    /// 摆放变了的画板：它们的缩略拼贴要重画
    public var boards: Set<Int64> {
        switch self {
        case .moved(let old, _): Set(old.map(\.boardID))
        case .placed(let added, let removed): Set((added + removed).map(\.boardID))
        case .trashed, .restored, .written: []
        }
    }
}

// MARK: 撤销：每个画板、每种卡片视图各一条，⌘Z 只撤眼前这一处

extension CanvasView: NSMenuItemValidation {
    var undoHistory: UndoManager? { content.map(undoHistory) }

    func undoHistory(of place: CanvasContent) -> UndoManager {
        if let h = undoHistories[place] { return h }
        let h = UndoManager()
        undoHistories[place] = h
        return h
    }

    /// 这一处的撤销记录作废（画板删了）；nil 表示每一处都作废（卡彻底删了）
    public func forgetUndoHistory(of place: CanvasContent? = nil) {
        if let place { undoHistories[place] = nil } else { undoHistories = [:] }
    }

    /// 记下刚做完的一步，记在做这一步的地方（默认是眼前这一处；写库期间可能已经换了画板）。
    /// 一步里可以有几样改动，⌘Z 一起撤回；什么都没变的不记
    public func record(_ edits: Edit..., as name: String, on place: CanvasContent? = nil) {
        let edits = edits.filter { !$0.isEmpty }
        guard !edits.isEmpty, let history = (place ?? content).map(undoHistory) else { return }
        history.beginUndoGrouping()
        for edit in edits { history.registerUndo(withTarget: self) { $0.apply(edit.reversed, as: name) } }
        history.setActionName(name)
        history.endUndoGrouping()
    }

    /// 做一步改动（撤销、重做，或者写完一张文字卡）：先登记反过来的一步（撤销过程中必须同步登记，才进重做栈），
    /// 再写资料库，外壳刷新后选中改到的。返回写资料库的那件事；改摆放是同步记下的，返回 nil
    @discardableResult
    func apply(_ edit: Edit, as name: String) -> Task<Void, Never>? {
        let selects: (Placement) -> Bool
        switch edit {
        case .moved(_, let new):
            // 改摆放自己会登记反过来的一步
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

    /// 写着字时撤的是字
    private var activeHistory: UndoManager? { noteEditor?.history ?? undoHistory }

    @objc func undo(_ sender: Any?) {
        // 裁剪到一半：先撤这次裁剪
        if cropper != nil { endCrop(commit: false) } else { activeHistory?.undo() }
    }

    @objc func redo(_ sender: Any?) { activeHistory?.redo() }

    /// 聚拢的结果是临时摆法，撤销等退出聚拢再说
    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            if cropper != nil { item.title = "取消裁剪"; return true }
            item.title = "撤销" + (activeHistory?.undoActionName ?? "")
            return gathering == nil && activeHistory?.canUndo == true
        case #selector(redo(_:)):
            item.title = "重做" + (activeHistory?.redoActionName ?? "")
            return gathering == nil && cropper == nil && activeHistory?.canRedo == true
        case #selector(copy(_:)):
            return gathering == nil && content != .collection(.trash) && selectedItems.contains { $0.placement.cardID != nil }
        default:
            return true
        }
    }
}
