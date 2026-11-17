import AVFoundation
import Observation
import Library

/// The whole app has only one sound. Listening is a background thing: switching boards or opening/closing the detail view doesn't interrupt it, so the player belongs to the App, not to any part of the interface.
/// Clicking another clip stops the previous one; it dismisses itself when finished
@MainActor @Observable
final class AudioPlayer {
    /// A playable clip: which card, what it's called, where the file is
    struct Track {
        var card: Int64
        var title: String
        var url: URL
        /// Seconds; nil if it couldn't be read at collection time, then the file is asked at play time
        var duration: Double?
    }

    private(set) var track: Track?
    private(set) var isPlaying = false
    /// Current second and total seconds
    private(set) var time: Double = 0
    private(set) var duration: Double = 0
    /// The card making sound changed (another clip, played, stopped): the play buttons on the canvas follow
    @ObservationIgnored var soundingChanged: (() -> Void)?
    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var ticking: Any?
    @ObservationIgnored private var ending: NSObjectProtocol?
    @ObservationIgnored private var status: NSKeyValueObservation?

    /// The card currently making sound; nil when paused or not playing
    var sounding: Int64? { isPlaying ? track?.card : nil }

    /// Play this clip (continue if it already is); when seconds isn't nil, play from that second
    func play(_ track: Track, at seconds: Double? = nil) {
        if track.card != self.track?.card { load(track) }
        if let seconds { seek(to: seconds) }
        player.play()
        isPlaying = true
        soundingChanged?()
    }

    /// Pause if this clip is playing, otherwise play it
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
        // Progress jumps to the new position at once, without waiting for the player to finish seeking, so the slider doesn't snap back on release
        time = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Stop and dismiss: the global playback bar disappears with it
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

    /// The player stopped on its own (file unreadable, interrupted by the system): the interface returns to not playing instead of staying on "playing"
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
    /// Only playable if it's an audio card and the original file still exists
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
