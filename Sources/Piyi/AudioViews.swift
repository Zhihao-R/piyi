import SwiftUI
import Tokens

/// 音频卡放大查看顶上的播放条：一直在，不用先点时间点。它和工具栏里那一条管的是同一个播放器
struct AudioBar: View {
    let audio: AudioPlayer
    /// 这张卡的那一段。播放器眼下播的可能是别的卡：那时这里停在开头，点了才换成它
    let track: AudioPlayer.Track
    /// 正拖着进度条：拖到哪显示到哪，松手才跳
    @State private var scrub: Double?

    private var current: Bool { audio.track?.card == track.card }

    var body: some View {
        let total = current ? audio.duration : track.duration ?? 0
        let now = scrub ?? (current ? audio.time : 0)
        HStack(spacing: 12) {
            Button { audio.toggle(track) } label: {
                Image(systemName: current && audio.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 14)).frame(width: 28, height: 28)
            }
            .buttonStyle(.hoverIcon)
            .foregroundStyle(.primary)
            Text(clockText(Int(now)))
            Slider(value: Binding(get: { now }, set: { scrub = $0 }), in: 0...max(total, 1)) { editing in
                guard !editing, let scrub else { return }
                if current { audio.seek(to: scrub) } else { audio.play(track, at: scrub) }
                self.scrub = nil
            }
            .controlSize(.small)
            // 还不知道多长（收的时候没读出来，要播起来才问得到）：先不让拖
            .disabled(total <= 0)
            // 总时长和卡片上写的一样四舍五入
            Text(clockText(Int(total.rounded())))
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Palette.stage.color)
    }
}

/// 工具栏里的全局播放条：有声音在播（或暂停着）才出现。声音不跟着画板走，卡片不在眼前时靠它看在播什么、暂停、回到那张卡
struct NowPlaying: View {
    let audio: AudioPlayer
    /// 点了标题：打开那张卡
    let open: (Int64) -> Void

    var body: some View {
        if let track = audio.track {
            HStack(spacing: 2) {
                Button { audio.toggle(track) } label: { Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill") }
                    .help(audio.isPlaying ? "暂停" : "继续播")
                Button { open(track.card) } label: {
                    HStack(spacing: 8) {
                        Text(track.title.isEmpty ? String(localized: "音频") : track.title).lineLimit(1).truncationMode(.tail).frame(maxWidth: 160)
                        Text(clockText(Int(audio.time))).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .help("打开这张卡")
                Button { audio.stop() } label: { Image(systemName: "xmark") }
                    .help("停止")
            }
        }
    }
}
