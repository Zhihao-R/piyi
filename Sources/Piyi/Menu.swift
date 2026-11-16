import AppKit
import Library
import Canvas
import Tokens

/// 画布上的右键菜单
@MainActor
enum Menu {
    static func build(for items: [BoardItem], model: AppModel) -> NSMenu? {
        guard let canvas = model.canvas, !items.isEmpty else { return nil }
        let menu = NSMenu()
        let cards = items.filter { if case .card = $0.face { true } else { false } }
        let inTrash = model.location == .collection(.trash)
        let onBoard = canvas.board != nil

        if items.count == 1, let item = items.first {
            switch item.face {
            case .entry(let board, _, _):
                menu.add(String(localized: "进入画板")) { model.enter(board) }
            case .card(let card):
                menu.add(String(localized: "放大查看")) { model.open(item) }
                if let url = card.url.flatMap(URL.init(string:)) { menu.add(String(localized: "打开原链接")) { model.follow(url, of: card.id) } }
                if let file = card.original, let store = model.store {
                    menu.add(String(localized: "用默认应用打开")) { model.follow(store.files.url(of: file), of: card.id) }
                }
                if card.url != nil, !inTrash {
                    menu.add(String(localized: "重新抓取")) {
                        Task { if let full = try? await model.store?.card(card.id) { model.collector.refetch(full) } }
                    }
                }
            }
            menu.addItem(.separator())
        }
        // 聚拢的结果是临时摆法：不裁剪、不移动、不删除；来自别处的卡可以留下
        if canvas.isGathered {
            let visiting = Set(canvas.visitingCards)
            let keep = cards.compactMap(\.placement.cardID).filter(visiting.contains)
            if !keep.isEmpty, canvas.board != nil {
                menu.add(String(localized: "放进当前画板")) { model.search.keepVisitors(keep) }
            }
            if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
            return menu.items.isEmpty ? nil : menu
        }
        if canvas.canCrop { menu.add(String(localized: "裁剪")) { canvas.beginCrop() } }
        if onBoard, items.contains(where: { $0.placement.crop != nil }) { menu.add(String(localized: "恢复原图")) { canvas.resetCrop() } }
        if onBoard, items.count > 1 { menu.add(String(localized: "整理成行")) { canvas.arrangeRows() } }
        let actions = actions(for: cards, model: model)
        actions.discuss.map(menu.addItem)
        actions.more.forEach(menu.addItem)
        if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
        actions.place.map(menu.addItem)
        actions.copy.map(menu.addItem)
        if onBoard { menu.add(String(localized: "移出这个画板")) { model.removeFromBoard(items) } }
        actions.last.forEach(menu.addItem)
        return menu
    }

    /// 对几张卡做的事。右键菜单和资料库底部的操作栏都从这里取，叫法、内容只在这一处定
    struct Actions {
        /// 讨论栏收起时开一段新讨论，展开时放上当前的桌
        var discuss: NSMenuItem?
        /// 放进画板（画板里叫「移到」）：各画板，和用它们新建一个
        var place: NSMenuItem?
        /// 画板里才有：也放进别的画板，这里留着
        var copy: NSMenuItem?
        /// 颜色、重新理解
        var more: [NSMenuItem] = []
        /// 删除；废纸篓里是恢复、彻底删除。会删东西的 tag 是 destructive
        var last: [NSMenuItem] = []
    }

    /// 操作栏把这一项画成红字
    static let destructive = 1

    static func actions(for cards: [BoardItem], model: AppModel) -> Actions {
        var actions = Actions()
        guard !cards.isEmpty else { return actions }
        if model.location == .collection(.trash) {
            actions.last = [item(String(localized: "恢复")) { model.restore(cards) },
                            item(String(localized: "彻底删除…"), destructive: true) { model.purge(cards) }]
            return actions
        }
        let onBoard = model.canvas?.board != nil
        let ids = cards.compactMap(\.placement.cardID)
        // 都已在桌上：菜单和操作条里不出这一项（放大查看里显示灰的「在桌上」）
        let entry = model.discussions.entry(for: ids)
        if entry.enabled { actions.discuss = item(entry.title) { model.discussions.discuss(ids) } }
        if cards.contains(where: \.isNote) { actions.more.append(tints(for: cards.filter(\.isNote), model: model)) }
        actions.more.append(item(String(localized: "重新理解")) { model.reunderstand(cards) })
        actions.place = boardMenu(onBoard ? String(localized: "移到") : String(localized: "放进画板"), cards: cards, keepingHere: false, model: model)
        if onBoard { actions.copy = boardMenu(String(localized: "也放进"), cards: cards, keepingHere: true, model: model) }
        // 画板里还有「移出这个画板」，所以说清是从资料库删
        actions.last = [item(onBoard ? String(localized: "从资料库删除") : String(localized: "删除"), destructive: true) { model.trash(cards) }]
        return actions
    }

    /// 一项带子菜单：各画板，和用它们新建一个
    private static func boardMenu(_ title: String, cards: [BoardItem], keepingHere: Bool, model: AppModel) -> NSMenuItem {
        let sub = NSMenu()
        for board in model.boards where board.id != model.canvas?.board { sub.add(board.name) { model.put(cards, into: board.id!, keepingHere: keepingHere) } }
        if !sub.items.isEmpty { sub.addItem(.separator()) }
        sub.add(String(localized: "新建画板")) { model.newBoard(with: cards, keepingHere: keepingHere) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }

    private static func item(_ title: String, destructive: Bool = false, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title, action: action)
        item.tag = destructive ? Self.destructive : 0
        return item
    }
}

extension Menu {
    /// 底色名在菜单里的叫法，顺序跟 Palette.tints
    private static let tintNames = ["yellow": String(localized: "黄"), "pink": String(localized: "粉"), "blue": String(localized: "蓝"), "green": String(localized: "绿"), "purple": String(localized: "紫")]

    /// 「颜色」子菜单：每种底色一个色块，当前的打勾（选了几张、颜色不一样时不打勾）
    private static func tints(for notes: [BoardItem], model: AppModel) -> NSMenuItem {
        let current = Set(notes.map { item -> String? in if case .card(let card) = item.face { card.tint } else { nil } })
        let sub = NSMenu()
        // 色块是卡片眼下会有的样子：深色外观下是压暗的那一档
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        for (name, color) in [(String?.none, Palette.card)] + Palette.tints.map({ (Optional($0.name), $0.color) }) {
            sub.add(name.flatMap { tintNames[$0] } ?? String(localized: "默认")) { model.tint(notes, name) }
            let item = sub.items.last!
            item.image = swatch(dark ? color.dark : color.light)
            item.state = current == [name] ? .on : .off
        }
        let item = NSMenuItem(title: String(localized: "颜色"), action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }

    /// 菜单里的小色块：圆点描一圈淡边，浅色在浅色菜单上也看得见
    private static func swatch(_ c: RGBA) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a).setFill()
            dot.fill()
            NSColor.black.withAlphaComponent(0.2).setStroke()
            dot.lineWidth = 0.5
            dot.stroke()
            return true
        }
    }
}

extension NSMenu {
    /// 加一项，点了执行 action
    func add(_ title: String, action: @escaping () -> Void) {
        addItem(NSMenuItem(title, action: action))
    }
}

extension NSMenuItem {
    /// 点了执行 action 的一项
    convenience init(_ title: String, action: @escaping () -> Void) {
        self.init(title: title, action: #selector(ClosureTarget.run), keyEquivalent: "")
        let target = ClosureTarget(action)
        self.target = target
        representedObject = target
    }

    /// 不经过菜单直接执行（操作栏上的按钮用）
    func perform() { (target as? ClosureTarget)?.run() }
}

/// 让菜单项直接执行一段代码
final class ClosureTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}
