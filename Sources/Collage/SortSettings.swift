import SwiftUI
import Library

/// 画板的分拣设置：自动分拣开关和一句分拣规则
struct SortSettings: View {
    let board: Board
    let model: AppModel
    @State private var autoSort: Bool
    @State private var rule: String
    /// 画板里一张卡都没有：又没写规则时没有东西可比，不会收卡
    @State private var empty = false
    @Environment(\.dismiss) private var dismiss

    init(board: Board, model: AppModel) {
        (self.board, self.model) = (board, model)
        // 一打开就是画板现在的设置，开关不从默认值动画过去
        _autoSort = State(initialValue: board.autoSort)
        _rule = State(initialValue: board.rule ?? "")
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Form {
                Section {
                    Toggle("自动分拣", isOn: $autoSort)
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
        guard autoSort else { return "关掉后，这个画板不再自动收卡。" }
        if empty, rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "放进一张卡或写一句规则后开始收卡。" }
        return "新收的卡有把握属于这里时，会自动放进来。不写规则就按画板里已有的卡判断。"
    }
}
