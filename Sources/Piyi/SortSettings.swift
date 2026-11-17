import SwiftUI
import Library

/// A board's sorting settings: automatic sorting switch and a one-line sorting rule
struct SortSettings: View {
    let board: Board
    let model: AppModel
    @State private var autoSort: Bool
    @State private var rule: String
    /// No cards in the board: with no rule written either, there's nothing to compare against, so it won't take cards
    @State private var empty = false
    @Environment(\.dismiss) private var dismiss

    init(board: Board, model: AppModel) {
        (self.board, self.model) = (board, model)
        // Opens with the board's current settings; the switch doesn't animate from the default value
        _autoSort = State(initialValue: board.autoSort)
        _rule = State(initialValue: board.rule ?? "")
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Form {
                Section {
                    Toggle("自动分拣", isOn: $autoSort).disabled(model.sortingUnavailable != nil)
                    TextField("分拣规则", text: $rule, prompt: Text("比如：配色和字体相关的参考"), axis: .vertical)
                        .lineLimit(2...4)
                        .disabled(!autoSort)
                } header: {
                    Text("「\(board.name)」的分拣设置")
                } footer: {
                    Text(footer).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("好") {
                    model.setSorting(board, autoSort: autoSort, rule: rule)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 400)
        .task { empty = (try? await model.store?.counts(board: board.id).board) == 0 }
    }

    private var footer: String {
        guard autoSort else { return String(localized: "关掉后，这个画板不再自动收卡。") }
        if let unavailable = model.sortingUnavailable { return String(localized: "\(unavailable)。") }
        if empty, rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return String(localized: "放进一张卡或写一句规则后开始收卡。") }
        return String(localized: "新收的卡有把握属于这里时，会自动放进来。不写规则就按画板里已有的卡判断。")
    }
}
