import SwiftUI
import Tokens

/// First-launch onboarding has several steps, all skippable and completable later in settings. Only steps not done and not seen appear:
/// when a step is added later, existing users see only the new step on launch
enum OnboardingStep: String, CaseIterable {
    case keys, model, browser, phone

    var title: String {
        switch self {
        case .keys: String(localized: "接入云端模型")
        case .model: String(localized: "下载本机模型")
        case .browser: String(localized: "装上浏览器扩展")
        case .phone: String(localized: "从手机收集")
        }
    }

    var detail: String {
        switch self {
        case .keys: String(localized: "用于生成标题、描述、标签和总结。可稍后填写，已收集的卡片会自动补全。")
        case .model: String(localized: "用于搜索，离线可用。仅需下载一次。")
        case .browser: String(localized: "在 Chrome、Edge、Arc 里一键收下正在看的网页；要登录、靠脚本加载的网页，片羽也交给它在后台打开。")
        case .phone: String(localized: "在 iPhone 上分享到「Collect To Piyi」，内容经 iCloud 云盘存入资料库。")
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

    /// One short bar per step, the current one stretched
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
            // No title on the left: the provider picker hugs the left at its content width, left-aligned with the key field below
            case .keys:
                VStack(alignment: .leading, spacing: 12) { CloudAccess(model: model, labeled: false) }
                    .labelsHidden()
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

/// The popup opened by "…Guide" in settings: same title, explanation and content as that onboarding step
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
