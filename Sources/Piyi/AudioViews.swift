import SwiftUI
import Tokens

/// Playback bar at the top of an audio card's detail view: always there, no need to click a timestamp first. It controls the same player as the one in the toolbar
struct AudioBar: View {
    let audio: AudioPlayer
    /// This card's clip. The player may currently be playing another card: then this stays at the start and switches to it only when clicked
    let track: AudioPlayer.Track
    /// Dragging the progress bar: show where it's dragged, seek only on release
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
            // Duration not known yet (couldn't be read at collection, only available once playing): no dragging for now
            .disabled(total <= 0)
            // Total duration is rounded the same way as written on the card
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

/// Global playback bar in the toolbar: appears only when something is playing (or paused). Sound doesn't follow the board, so when the card isn't in view this is how you see what's playing, pause, or go back to that card
struct NowPlaying: View {
    let audio: AudioPlayer
    /// Title clicked: open that card
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
