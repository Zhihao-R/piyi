import SwiftUI
import Tokens

/// 第一次打开的引导分几步，都可以先跳过，之后在设置里补。只出现没做过、也没看过的那几步：
/// 以后加一步，老用户打开时只看到新加的那一步
enum OnboardingStep: String, CaseIterable {
    case keys, model, browser, phone

    var title: String {
        switch self {
        case .keys: String(localized: "填云端服务方的密钥")
        case .model: String(localized: "下载本机模型")
        case .browser: String(localized: "装上浏览器扩展")
        case .phone: String(localized: "从手机收集")
        }
    }

    var detail: String {
        switch self {
        case .keys: String(localized: "用来给卡片起标题、写描述和标签。不填也能收集，卡片会停在「等待密钥」，填上后自动补上。")
        case .model: String(localized: "用来在本机算向量，搜索要用它。只需下载一次。")
        case .browser: String(localized: "在 Chrome、Edge、Arc 里一键收下正在看的网页；要登录、靠脚本加载的网页，拼贴也交给它在后台打开。")
        case .phone: String(localized: "在 iPhone 上分享到「收集拼贴」，内容经 iCloud 云盘存入资料库。")
        }
    }
}

struct Onboarding: View {
    let model: AppModel
    @State private var index = 0
    @State private var forward = true

    private var steps: [OnboardingStep] { model.onboardingSteps }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if steps.count > 1 { progress }
            ZStack(alignment: .topLeading) {
                if steps.indices.contains(index) {
                    page(steps[index])
                        .id(index)
                        .transition(.asymmetric(
                            insertion: .offset(x: forward ? 28 : -28).combined(with: .opacity),
                            removal: .offset(x: forward ? -28 : 28).combined(with: .opacity)))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            footer
        }
        .padding(32)
        .frame(width: 520)
    }

    /// 几步就几根短条，走到的那根拉长
    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(steps.indices, id: \.self) { i in
                Capsule()
                    .fill(i <= index ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
                    .frame(width: i == index ? 22 : 8, height: 4)
            }
        }
        .animation(.spring(response: Motion.lift.response, dampingFraction: Motion.lift.damping), value: index)
    }

    private func page(_ step: OnboardingStep) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            StepHeader(step: step)
            switch step {
            case .keys: VStack(spacing: 10) { ForEach(model.cloud, id: \.name) { KeyField(provider: $0, model: model) } }
            case .model: LocalModelRow(model: model)
            case .browser: ExtensionGuide(model: model)
            case .phone: PhoneGuide(inbox: model.phoneInbox)
            }
        }
    }

    private var footer: some View {
        HStack {
            if index > 0 {
                Button("上一步") { go(-1) }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Spacer()
            let last = index == steps.count - 1
            if !last {
                Button("以后再说") { model.finishOnboarding() }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .padding(.trailing, 8)
            }
            Button(last ? "完成" : "继续") { if last { model.finishOnboarding() } else { go(1) } }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func go(_ step: Int) {
        forward = step > 0
        withAnimation(.spring(response: Motion.place.response, dampingFraction: Motion.place.damping)) { index += step }
    }
}

private struct StepHeader: View {
    let step: OnboardingStep

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(step.title).font(.system(size: 22, weight: .semibold))
            Text(step.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 设置里点「…指引」打开的弹窗：和引导里那一步同样的标题、说明和内容
struct GuideSheet<Content: View>: View {
    let step: OnboardingStep
    let done: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            StepHeader(step: step)
            content
            HStack {
                Spacer()
                Button("完成", action: done)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 500)
    }
}
