import AVFoundation
import Observation
import Library

/// 全应用只有一个声音。听是背景里的事：切画板、开关放大查看都不打断，所以播放器归 App，不归哪块界面。
/// 点另一段，前一段就停；放完了自己收起
@MainActor @Observable
final class AudioPlayer {
    /// 一段能播的声音：哪张卡、叫什么、文件在哪
    struct Track {
        var card: Int64
        var title: String
        var url: URL
        /// 秒；收的时候没读出来是 nil，播的时候再问文件
        var duration: Double?
    }

    private(set) var track: Track?
    private(set) var isPlaying = false
    /// 播到第几秒、一共多少秒
    private(set) var time: Double = 0
    private(set) var duration: Double = 0
    /// 出声的卡换了（换了一段、播了、停了）：画布上的播放钮跟着换
    @ObservationIgnored var soundingChanged: (() -> Void)?
    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var ticking: Any?
    @ObservationIgnored private var ending: NSObjectProtocol?
    @ObservationIgnored private var status: NSKeyValueObservation?

    /// 正在出声的那张卡；暂停、没在播是 nil
    var sounding: Int64? { isPlaying ? track?.card : nil }

    /// 播这一段（已经是它就接着播）；seconds 不为空时从那一秒播
    func play(_ track: Track, at seconds: Double? = nil) {
        if track.card != self.track?.card { load(track) }
        if let seconds { seek(to: seconds) }
        player.play()
        isPlaying = true
        soundingChanged?()
    }

    /// 正在播这一段就暂停，否则播它
    func toggle(_ track: Track) {
        if track.card == self.track?.card, isPlaying { pause() } else { play(track) }
    }

    func pause() {
        guard isPlaying else { return }
        player.pause()
        isPlaying = false
        soundingChanged?()
    }

    func seek(to seconds: Double) {
        // 进度马上落到新位置，不等播放器跳完，拖动条松手不往回弹
        time = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// 停下并收起：全局的播放条跟着消失
    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let ending { NotificationCenter.default.removeObserver(ending) }
        ending = nil
        (track, isPlaying, time, duration) = (nil, false, 0, 0)
        soundingChanged?()
    }

    private func load(_ track: Track) {
        if let ending { NotificationCenter.default.removeObserver(ending) }
        let item = AVPlayerItem(url: track.url)
        player.replaceCurrentItem(with: item)
        (self.track, time, duration) = (track, 0, track.duration ?? 0)
        ending = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        if ticking == nil {
            ticking = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] now in
                MainActor.assumeIsolated { self?.tick(now.seconds) }
            }
        }
        if status == nil {
            status = player.observe(\.timeControlStatus) { [weak self] _, _ in
                let player = self
                Task { @MainActor in player?.settle() }
            }
        }
        if track.duration == nil {
            Task {
                guard let length = try? await item.asset.load(.duration).seconds, length.isFinite, self.track?.card == track.card else { return }
                duration = length
            }
        }
    }

    /// 播放器自己停了（文件读不了、被系统打断）：界面跟着回到没在播的样子，不停在「正在播」上
    private func settle() {
        guard isPlaying, player.timeControlStatus == .paused else { return }
        isPlaying = false
        soundingChanged?()
    }

    private func tick(_ seconds: Double) {
        if isPlaying, seconds.isFinite { time = seconds }
    }
}

extension AudioPlayer.Track {
    /// 音频卡、原文件还在才播得了
    init?(_ card: Card, files: FileStore) {
        guard card.kind == .audio, let id = card.id else { return nil }
        self.init(card: id, title: card.displayTitle, original: card.original, duration: card.duration, files: files)
    }

    init?(_ face: CardFace, files: FileStore) {
        guard face.kind == .audio else { return nil }
        self.init(card: face.id, title: face.title, original: face.original, duration: face.duration, files: files)
    }

    private init?(card: Int64, title: String, original: String?, duration: Double?, files: FileStore) {
        guard let url = original.map(files.url(of:)), FileManager.default.fileExists(atPath: url.path) else { return nil }
        self.init(card: card, title: title, url: url, duration: duration)
    }
}
