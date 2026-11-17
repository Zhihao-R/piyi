import SwiftUI
import Library
import Intelligence
import Tokens

/// The search bar docked at the bottom center of the canvas: "Ask your library…". Filter buttons float up only while typing, focused, or with active filters
struct SearchBar: View {
    static let placeholder = String(localized: "对资料库说一句话…")
    @Bindable var search: SearchModel
    /// Shares one piece of glass with the action bar: morphs from this bar when cards are selected
    let bar: Namespace.ID
    /// Incremented on every ⌘F: put the cursor in the search bar
    let focusRequest: Int
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: Chrome.gap) {
            if focused || !search.text.isEmpty || search.filters != Filters() {
                FilterRow(search: search)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .symbolEffect(.pulse, options: .repeating, isActive: search.working)
                TextField(Self.placeholder, text: $search.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { search.submit() }
                if !search.text.isEmpty {
                    Button { search.text = ""; search.dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
                Button { search.panel?.kind == .inspire ? search.another() : search.inspireHere() } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(search.inspirationBlocked == nil ? .primary : .tertiary)
                .disabled(search.inspirationBlocked != nil)
                .help(search.inspirationBlocked ?? String(localized: "灵感：从这个画板挑几张卡，说出它们之间的联系"))
                .onHover { if $0 { search.prepare() } }
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .frame(height: Chrome.searchHeight)
            .frame(maxWidth: Chrome.searchWidth)
            .glassEffect(.regular, in: .capsule)
            .glassEffectID("bar", in: bar)
        }
        .padding(.horizontal, Chrome.inset)
        .padding(.bottom, Chrome.inset)
        .animation(.spring(Motion.lift), value: focused)
        .animation(.spring(Motion.lift), value: search.text.isEmpty)
        .onChange(of: focusRequest) { focused = true }
    }
}

/// Filter buttons: time, type, color, scope. They show the conditions merged from buttons and the sentence; conditions parsed from the sentence are visible here too
private struct FilterRow: View {
    @Bindable var search: SearchModel
    @State private var picking = false

    private var q: Query { search.parsed }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                SwiftUI.Menu {
                    Picker("时间", selection: $search.filters.days) {
                        Text("不限").tag(Int?.none)
                        ForEach(Self.days.filter { $0.0 != 2 }, id: \.0) { Text($0.1).tag(Int?.some($0.0)) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    chip(q.days.map { d in Self.days.first { $0.0 == d }?.1 ?? String(localized: "最近 \(d) 天") } ?? String(localized: "时间"), active: q.days != nil)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()

                SwiftUI.Menu {
                    ForEach(Kind.allCases, id: \.self) { kind in
                        Toggle(kind.label, isOn: Binding(get: { search.filters.kinds.contains(kind) },
                                                         set: { if $0 { search.filters.kinds.insert(kind) } else { search.filters.kinds.remove(kind) } }))
                    }
                    if !search.filters.kinds.isEmpty { Divider(); Button("不限") { search.filters.kinds = [] } }
                } label: {
                    chip(q.kinds.isEmpty ? String(localized: "类型") : Kind.allCases.filter(q.kinds.contains).map(\.label).formatted(.list(type: .or)), active: !q.kinds.isEmpty)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()

                Button { picking.toggle() } label: {
                    HStack(spacing: 6) {
                        if q.colors.isEmpty { Text("颜色") } else {
                            HStack(spacing: -4) { ForEach(q.colors, id: \.self) { Circle().fill($0.swatch).frame(width: 12, height: 12).overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1)) } }
                        }
                    }
                    .chipStyle(active: !q.colors.isEmpty)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $picking, arrowEdge: .top) { ColorPicker(search: search) }

                SwiftUI.Menu {
                    Picker("范围", selection: $search.filters.scope) {
                        Text("全部卡片").tag(Scope.all)
                        if let board = search.currentBoard { Text("当前画板").tag(Scope.board(board)) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    chip(q.scope == .all ? String(localized: "全部卡片") : String(localized: "当前画板"), active: q.scope != .all)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()

                // Find-cards results include cards from other boards: keep them (for inspiration and questions, on the text panel)
                if search.showing == .find, search.visitors > 0 {
                    Button { search.keepVisitors() } label: {
                        Label("放进当前画板 \(search.visitors) 张", systemImage: "plus").chipStyle(active: true)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
        }
        .font(.system(size: 12))
        .animation(.fade, value: search.visitors)
    }

    private func chip(_ title: String, active: Bool) -> some View {
        Text(title).chipStyle(active: active)
    }

    /// Same set of day ranges as time words in sentences (QueryRules.timePhrases), so button labels match what the sentence parses to. "Yesterday" only comes from sentences
    static let days = [(1, String(localized: "今天")), (2, String(localized: "昨天以来")), (5, String(localized: "这几天")), (7, String(localized: "这一周")), (14, String(localized: "最近两周")), (31, String(localized: "这个月"))]
}

/// Color: twelve nameable colors, click to select, click again to deselect
private struct ColorPicker: View {
    @Bindable var search: SearchModel

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 10), count: 6), spacing: 10) {
            ForEach(ColorName.allCases, id: \.self) { color in
                let on = search.filters.color == color
                Button { search.filters.color = on ? nil : color } label: {
                    Circle().fill(color.swatch)
                        .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1))
                        .overlay(Circle().stroke(Color.primary, lineWidth: on ? 2 : 0).padding(-3))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(color.label)
            }
        }
        .padding(14)
    }
}

extension View {
    /// Look of filter buttons: glass capsules; with conditions the text darkens, no extra accent color
    func chipStyle(active: Bool) -> some View {
        padding(.horizontal, 12).frame(height: 26)
            .foregroundStyle(active ? .primary : .secondary)
            .fontWeight(active ? .medium : .regular)
            .glassEffect(.regular.interactive(), in: .capsule)
            .contentShape(Capsule())
    }
}

/// Text panel: inspiration's wording, a card draw's interpretation, a question's answer, appearing with the cards gathered in view
struct ReadingPanel: View {
    let search: SearchModel
    let panel: SearchModel.Panel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
                Spacer()
                Button { search.dismiss() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain)
                    .help("收起（Esc）")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)

            if let text = panel.text {
                Text(text)
                    .font(.system(size: 15))
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            } else {
                Waiting()
            }

            if panel.text != nil, panel.kind != .draw || search.visitors > 0 {
                HStack(spacing: 8) {
                    if panel.kind == .inspire {
                        Button { search.another() } label: { Label("换一组", systemImage: "arrow.triangle.2.circlepath") }
                    }
                    if panel.kind == .ask {
                        Button { search.continueChat() } label: { Label("接着聊", systemImage: "bubble.left.and.bubble.right") }
                    }
                    if search.visitors > 0 {
                        Button { search.keepVisitors() } label: { Label("放进当前画板", systemImage: "plus") }
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
        .padding(20)
        .frame(width: Chrome.panelWidth, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .animation(.fade, value: panel.text)
    }

    private var icon: String {
        switch panel.kind {
        case .inspire: "sparkles"
        case .draw: "suit.diamond"
        case .ask: "text.bubble"
        }
    }

    private var title: String {
        switch panel.kind {
        case .inspire: String(localized: "灵感")
        case .draw: String(localized: "抽到这一张")
        case .ask: String(localized: "回答")
        }
    }
}

/// While waiting for the model to write: three faint placeholder lines breathing at the "waiting" rhythm. Shared by the text panel and the discussion bar
struct Waiting: View {
    @State private var breathe = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach([1.0, 0.92, 0.6], id: \.self) { w in
                RoundedRectangle(cornerRadius: 4).fill(.primary.opacity(0.14)).frame(height: 12).frame(maxWidth: .infinity, alignment: .leading)
                    .scaleEffect(x: w, anchor: .leading)
            }
        }
        .opacity(breathe ? 0.45 : 1)
        .onAppear { withAnimation(.easeInOut(duration: Motion.wait / 2).repeatForever()) { breathe = true } }
    }
}

extension Kind {
    var label: String {
        switch self {
        case .image: String(localized: "图片")
        case .text: String(localized: "文字")
        case .web: String(localized: "网页")
        case .document: String(localized: "文档")
        case .video: String(localized: "视频")
        case .audio: String(localized: "音频")
        }
    }
}

extension ColorName {
    var label: String {
        switch self {
        case .red: String(localized: "红色")
        case .orange: String(localized: "橙色")
        case .yellow: String(localized: "黄色")
        case .green: String(localized: "绿色")
        case .cyan: String(localized: "青色")
        case .blue: String(localized: "蓝色")
        case .purple: String(localized: "紫色")
        case .pink: String(localized: "粉色")
        case .brown: String(localized: "棕色")
        case .black: String(localized: "黑色")
        case .white: String(localized: "白色")
        case .gray: String(localized: "灰色")
        }
    }

    /// Swatch on a button
    var swatch: Color { Palette.swatches[rawValue]!.color }
}

