import SwiftUI
import Library
import Canvas
import Tokens

/// 资料库里有意选了卡：底部的搜索栏变形成这一条，对选中的几张做事。操作和右键菜单是同一份（Menu.actions）
struct SelectionBar: View {
    let model: AppModel
    /// 和搜索栏共用一块玻璃
    let bar: Namespace.ID

    var body: some View {
        let picked = model.picked
        let actions = Menu.actions(for: picked, model: model)
        HStack(spacing: 2) {
            Text("已选 \(picked.count) 张")
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(picked.count)))
                .padding(.horizontal, 12)
            Divider().frame(height: 18)
            if let discuss = actions.discuss {
                Button(discuss.title, action: discuss.perform)
                    .padding(.horizontal, 10).frame(height: Self.button).contentShape(Capsule())
                    .buttonStyle(.plain)
            }
            if let place = actions.place {
                SwiftUI.Menu { MenuItems(items: place.submenu?.items ?? []) } label: {
                    Text(place.title).padding(.horizontal, 10).frame(height: Self.button).contentShape(Capsule())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            if !actions.more.isEmpty {
                SwiftUI.Menu { MenuItems(items: actions.more) } label: {
                    Image(systemName: "ellipsis").frame(width: Self.button, height: Self.button).contentShape(Circle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("更多")
                Divider().frame(height: 18)
            }
            ForEach(actions.last, id: \.title) { item in
                Button(item.title, action: item.perform)
                    .padding(.horizontal, 10).frame(height: Self.button).contentShape(Capsule())
                    .buttonStyle(.plain)
                    .foregroundStyle(item.tag == Menu.destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            }
            Button { _ = model.canvas?.deselect() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: Self.button, height: Self.button).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("取消选择（Esc）")
        }
        .font(.system(size: 13))
        .padding(.horizontal, 6)
        .frame(height: Chrome.searchHeight)
        .glassEffect(.regular, in: .capsule)
        .glassEffectID("bar", in: bar)
        .padding(.horizontal, Chrome.inset)
        .padding(.bottom, Chrome.inset)
        .animation(.spring(Motion.lift), value: picked.count)
    }

    /// 按钮的点击区，和搜索栏上的按钮一样大
    private static let button: CGFloat = 28
}

/// 把 AppKit 的菜单项照样画成 SwiftUI 菜单的内容：标题、色块、打勾、子菜单都跟右键菜单一致
private struct MenuItems: View {
    let items: [NSMenuItem]

    var body: some View {
        ForEach(items.indices, id: \.self) { i in
            let item = items[i]
            if item.isSeparatorItem {
                Divider()
            } else if let sub = item.submenu {
                SwiftUI.Menu(item.title) { MenuItems(items: sub.items) }
            } else {
                let label = Label { Text(item.title) } icon: { if let image = item.image { Image(nsImage: image) } }
                if item.state == .on {
                    Toggle(isOn: Binding(get: { true }, set: { _ in item.perform() })) { label }
                } else {
                    Button(action: item.perform) { label }
                }
            }
        }
    }
}
