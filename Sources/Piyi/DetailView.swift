import SwiftUI
import AVKit
import PDFKit
import WebKit
import Library
import Canvas
import Tokens

/// Detail view: only this one card remains. Cards with visuals (images, video, web pages and documents with images) have the visual on the left and a text column on the right;
/// cards without visuals are all text. Text has only one layout, the reading page (Reader), getting finer from top to bottom
struct DetailView: View {
    let store: Store
    let card: Int64
    /// A citation clicked in the discussion: scroll to that passage and flash it, video plays from that second
    let focus: AppModel.Focus?
    /// The one player for the whole app: audio card sound goes to it, and it's stopped here when a video with sound starts playing
    let audio: AudioPlayer
    /// Buttons at the right end of the source row: discuss, put on the table
    let discuss: Action
    /// Which card on the canvas it corresponds to: grows out of it on open, shrinks back into it on close. None when switched to with arrow keys or opened from the discussion bar
    let spot: Spot?
    /// Left open when switching back to the board: doesn't fly out of the card, fades in with the canvas
    let stayed: Bool
    /// The outside said to close: shrink back or fade out, call closed when done
    let closing: Bool
    /// Swapped out (card changed, board switched, closed outright): treated as part of the old view, fades out in step with the canvas's old view, then calls closed
    let away: Bool
    let close: () -> Void
    /// Open the original link or original file
    let follow: (URL) -> Void
    /// Refetch an incomplete card
    let refetch: () -> Void
    /// The text of a note you wrote changed
    let rewrite: (String) -> Void
    /// Pick up the card on the canvas (it shouldn't still be in place while flying) and put it back
    let lift: (Bool) -> Void
    let closed: () -> Void
    /// The panel's opacity and size: fades in and grows out of the card on entry, the reverse on close
    @State private var shown = false
    @State private var grown = false
    /// The image that flies in and back. Normally it sits transparent over the visual, following it; on close it shows and flies back
    @State private var ghost: Ghost?
    @State private var flying = false
    /// How much of the card's look remains on the layer under the panel: it fades quickly once expanding, leaving only a page-colored block to keep growing, and the panel's text fades in over it.
    /// Without fading, the enlarged card's text and the panel's text overlap for a moment, one large and one small
    @State private var faceOpacity = 1.0
    /// Already closing. Animation completion callbacks must check this: the closing passed in is the value at view creation, long stale when the callback runs
    @State private var leaving = false
    /// Where the visual area sits in the window; the fly-in lands inside it
    @State private var stageFrame: CGRect?
    /// Where the panel is when half expanded (cards that can't fly whole expand from the card's position into the panel); nil means staying in place
    @State private var morph: CGRect?
    /// The panel's size and this area's position in the window: the panel sits centered, so its position can be computed
    @State private var panelSize: CGSize?
    @State private var area: CGRect = .zero
    /// The visual's image finished decoding (failing counts too): only then does the flown-in image fade
    @State private var decoded = false
    @State private var loaded: Card?
    /// Other images (excluding the cover)
    @State private var images: [String] = []
    @State private var page = 0
    /// The current image, decoded in the background
    @State private var picture: CGImage?
    /// Visual height / width: the panel's size follows it. Known from the cover's file header, no need to wait for decoding
    @State private var aspect: CGFloat = 1
    /// Online video with play or a timestamp clicked, local video with a timestamp clicked; nil means still on the cover (local video loops muted)
    @State private var playing: Seek?
    /// Original file of an animated image: once loaded it replaces the static first frame and keeps animating
    @State private var moving: NSImage?
    /// Full text and transcript: laid out once on open, not again on play or timestamp clicks
    @State private var bodyText: NSAttributedString?
    @State private var transcriptText: NSAttributedString?

    /// The passage to flash
    @State private var highlight: LongText.Highlight?

    struct Action {
        var title: String
        var enabled: Bool
        var run: () -> Void
    }

    /// Cover plus other images, switch left and right
    private var gallery: [String] { [loaded?.cover].compactMap { $0 } + images }

    var body: some View {
        GeometryReader { geo in
            let space = geo.frame(in: .global)
            ZStack {
                // Start flying and expanding after it appears: placing it and changing its destination in the same update makes it just sit at the destination
                if let ghost, ghost.below { ghostView(ghost, in: space).onAppear { unfold() } }
                if let loaded {
                    panel(loaded, in: CGSize(width: min(geo.size.width - Self.margin * 2, 1180), height: min(geo.size.height - Self.margin * 2, 800)))
                        .clipShape(RoundedRectangle(cornerRadius: Self.corner))
                        .shadow(color: .black.opacity(0.3), radius: 30, y: 10)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { panelSize = $0 }
                        .scaleEffect(x: morphScale.width, y: morphScale.height)
                        .offset(x: morph.map { $0.midX - space.midX } ?? 0, y: morph.map { $0.midY - space.midY } ?? 0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(shown ? 1 : 0)
                        // Only cards that can't fly whole grow out of the card; whole-flying ones don't scale, the measured visual position is where they land
                        .scaleEffect(grows && !grown ? Motion.emerge : 1, anchor: Self.anchor(of: spot, in: space))
                }
                if let ghost, !ghost.below { ghostView(ghost, in: space).onAppear { flyIn() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { area = $0 }
        }
        .onChange(of: panelSize) { unfold() }
        .task { await arrive() }
        .onChange(of: stageFrame) {
            // After the panel is out and not flying, the transparent overlay follows the visual (the window changed)
            if shown, !flying, ghost?.below != true, let stageFrame { ghost?.frame = fitted(in: stageFrame) }
            flyIn()
        }
        .onChange(of: decoded) { settle() }
        .onChange(of: closing) { if closing { leave() } }
        .onChange(of: away) { if away { fadeAway() } }
        .task(id: card) {
            // Card and images arrive together, so long body text isn't laid out twice
            let card = try? await store.card(self.card)
            let images = (try? await store.images(of: self.card)) ?? []
            guard !Task.isCancelled else { return }
            let narrow = card.map { Self.hasStage($0, pictures: ($0.cover == nil ? 0 : 1) + images.count) } ?? false
            let type = narrow ? Reading.narrow : Reading.wide
            aspect = card.flatMap { c in c.cover.flatMap { CardSize.coverAspect($0, files: store.files) } ?? (c.kind == .video ? 9 / 16 : nil) } ?? 1
            (loaded, self.images, page, playing) = (card, images, 0, nil)
            (bodyText, transcriptText) = (card.flatMap { Self.bodyText($0, type: type) }, card.flatMap { Self.transcriptText($0, type: type) })
            aim()
            // Left open when switching back to the board, with no visual to wait for (text, audio): fade in once content arrives
            if stayed, let card, !Self.hasStage(card, pictures: gallery.count) { reappear() }
        }
        .onChange(of: focus?.id) { aim() }
        // Only one sound at a time: when a video plays with sound, audio stops. When audio plays, videos in the system player pause themselves (see StreamVideo);
        // a platform's embedded player is someone else's web page that can't be stopped, so the only option is going back to the cover
        .onChange(of: playing) { if playing != nil { audio.pause() } }
        .onChange(of: audio.isPlaying) { if audio.isPlaying, let loaded, loaded.original == nil, loaded.player.map(Player.isStream) != true { playing = nil } }
        .task(id: loaded?.id) {
            moving = nil
            guard let loaded, loaded.form == .animated, let name = loaded.original ?? loaded.cover else { return }
            let image = await Self.moving(store.files.url(of: name))
            if !Task.isCancelled { moving = image }
        }
        .task(id: gallery.indices.contains(page) ? gallery[page] : nil) {
            picture = nil
            guard let loaded else { return }
            // The reading page decodes at column width itself, not needed here
            if gallery.indices.contains(page), Self.hasStage(loaded, pictures: gallery.count) {
                let name = gallery[page]
                // Use the existing thumbnail first and swap when the full image is decoded: the same image gets sharper, the swap isn't visible. Long images' thumbnails are only the top part, so skip them
                if loaded.form != .long, let thumb = await Self.thumbnail(name, files: store.files), !Task.isCancelled { picture = thumb }
                if let full = await Self.decode(store.files.url(of: name), maxPixel: 4000), !Task.isCancelled { picture = full }
            }
            guard !Task.isCancelled else { return }
            decoded = true
            if stayed { reappear() }
        }
        // Left open when switching back to the board: the panel fades in as soon as the visual arrives (the thumbnail is enough)
        .onChange(of: picture) { if stayed, picture != nil { reappear() } }
    }

    // MARK: Growing out of the card, shrinking back

    struct Ghost {
        var face: CGImage
        var frame: CGRect
        var rotation: Double
        var opacity: Double = 1
        /// Layer under the panel: when expanding the panel fades in over it; the whole-flying image is above the panel and hides after landing
        var below = false
        /// Corner radius: the layer underneath grows from the card's square corners to the panel's rounded corners
        var corner: CGFloat = 0
    }

    /// The panel's corner radius
    private static let corner: CGFloat = 14

    private func ghostView(_ ghost: Ghost, in space: CGRect) -> some View {
        Image(decorative: ghost.face, scale: 1).resizable()
            .opacity(ghost.below ? faceOpacity : 1)
            .background { if ghost.below { Palette.page.color } }
            .frame(width: ghost.frame.width, height: ghost.frame.height)
            .clipShape(RoundedRectangle(cornerRadius: ghost.corner))
            .rotationEffect(.radians(ghost.rotation))
            .position(x: ghost.frame.midX - space.minX, y: ghost.frame.midY - space.minY)
            .opacity(ghost.opacity)
            .allowsHitTesting(false)
    }

    /// The panel's position when centered
    private var rest: CGRect? {
        panelSize.map { CGRect(x: area.midX - $0.width / 2, y: area.midY - $0.height / 2, width: $0.width, height: $0.height) }
    }

    /// The panel's scale relative to full size when half expanded
    private var morphScale: CGSize {
        guard let morph, let panelSize, panelSize.width > 0, panelSize.height > 0 else { return CGSize(width: 1, height: 1) }
        return CGSize(width: morph.width / panelSize.width, height: morph.height / panelSize.height)
    }

    /// Cards that can't fly whole: the panel expands from the card's position to the center, the card's look underneath, the panel fading in over it all the way
    private func unfold() {
        guard ghost?.below == true, !flying, !shown, loaded != nil, let rest else { return }
        (grown, flying) = (true, true)
        withAnimation(.fly) {
            morph = nil
            ghost?.frame = rest
            ghost?.rotation = 0
            ghost?.corner = Self.corner
            shown = true
        } completion: {
            guard !leaving else { return }
            flying = false
            // The panel is solid now; put away the layer underneath, otherwise it shows at the rounded corners
            ghost?.opacity = 0
        }
        withAnimation(.swap) { faceOpacity = 0 }
    }

    /// Entering: cards with a whole visual fly the thumbnail from the card's position; others grow out of the card (fade in place if not opened from the canvas)
    private func arrive() async {
        if !stayed, let spot, let cover = spot.cover, let face = await Self.thumbnail(cover, files: store.files) {
            guard !leaving else { return }
            ghost = Ghost(face: face, frame: spot.frame, rotation: spot.rotation)
            lift(true)
        } else if !stayed, let spot, let face = spot.face {
            ghost = Ghost(face: face, frame: spot.frame, rotation: spot.rotation, below: true)
            morph = spot.frame
            lift(true)
        } else if !stayed, spot != nil {
            withAnimation(.spring(Motion.place)) { grown = true }
            withAnimation(.fade) { shown = true }
        } else if !stayed {
            grown = true
            withAnimation(.swap) { shown = true }
        }
    }

    /// Left open when switching back to the board: the panel fades in together with the visual, in sync with the canvas change
    private func reappear() {
        guard !shown, !leaving else { return }
        grown = true
        withAnimation(.swap) { shown = true }
    }

    /// Cards that can't fly a whole visual (text, web pages): the panel grows out of the card
    private var grows: Bool { spot != nil && spot?.cover == nil }

    /// Fly over once the panel is laid out (the visual's landing spot is known); once the image is in place, the panel fades in around it
    private func flyIn() {
        guard let stageFrame, ghost?.below == false, !flying, !shown, loaded != nil else { return }
        flying = true
        withAnimation(.fly) {
            ghost?.frame = fitted(in: stageFrame)
            ghost?.rotation = 0
        } completion: {
            guard !leaving else { return }
            // Hide the flown-in image only when the panel is fully out and the visual underneath is solid: the moment both are semi-transparent flashes dark
            withAnimation(.fade) { shown = true } completion: {
                guard !leaving else { return }
                flying = false
                settle()
            }
        }
    }

    /// Landed and the real visual underneath has arrived: the flown-in image hides. A video's picture comes from the player, so hide on landing
    private func settle() {
        guard !flying, !leaving, decoded || loaded?.kind == .video else { return }
        if ghost == nil, let picture, let stageFrame {
            // Switched to with arrow keys: never flew, but prepare a transparent one too so it can fly back on close
            ghost = Ghost(face: picture, frame: fitted(in: stageFrame), rotation: 0, opacity: 0)
        }
        withAnimation(.swap) { ghost?.opacity = 0 }
    }

    /// Close: if still on the first image, fly from the visual back to the card (from midway if midway); if flipped to another image, or a card that can't fly, shrink back toward the card and fade out
    private func leave() {
        leaving = true
        // Expanded: retract to the card the way it came; the card's look shows where the panel fades out
        if let spot, let face = spot.face, ghost?.below == true {
            lift(true)
            ghost?.face = face
            ghost?.opacity = 1
            flying = true
            withAnimation(.fly) {
                morph = spot.frame
                ghost?.frame = spot.frame
                ghost?.rotation = spot.rotation
                ghost?.corner = 0
                faceOpacity = 1
                shown = false
            } completion: { closed() }
            return
        }
        guard let spot, spot.cover != nil, page == 0, ghost?.below == false else {
            lift(false)
            // The panel isn't out yet (thumbnail still decoding): nothing to retract, close directly
            guard shown else { closed(); return }
            withAnimation(.spring(Motion.place)) { grown = false }
            withAnimation(.fade) { shown = false } completion: { closed() }
            return
        }
        lift(true)
        if let picture { ghost?.face = picture }
        ghost?.opacity = 1
        flying = true
        withAnimation(.swap) { shown = false }
        withAnimation(.fly) {
            ghost?.frame = spot.frame
            ghost?.rotation = spot.rotation
        } completion: { closed() }
    }

    private func fadeAway() {
        leaving = true
        guard shown else { closed(); return }
        withAnimation(.swapOut) {
            shown = false
            ghost?.opacity = 0
        } completion: { closed() }
    }

    /// Anchor for scaling the panel: the card center's relative position within this area
    private static func anchor(of spot: Spot?, in space: CGRect) -> UnitPoint {
        guard let spot, space.width > 0, space.height > 0 else { return .center }
        return UnitPoint(x: (spot.frame.midX - space.minX) / space.width, y: (spot.frame.midY - space.minY) / space.height)
    }

    /// Where the image actually sits in the visual area: fitted proportionally, centered
    private func fitted(in stage: CGRect) -> CGRect {
        let width = min(stage.width, stage.height / aspect), height = width * aspect
        return CGRect(x: stage.midX - width / 2, y: stage.midY - height / 2, width: width, height: height)
    }

    /// The flying image uses the ready thumbnail on disk (the largest size): fast to decode, without the badges of the canvas card
    private static func thumbnail(_ cover: String, files: FileStore) async -> CGImage? {
        for tier in FileStore.tiers.reversed() {
            if let image = await decode(files.thumbnailURL(of: cover, tier: tier), maxPixel: tier) { return image }
        }
        return nil
    }

    /// The panel's distance from the window edge
    private static let margin: CGFloat = 40
    /// The visual area must be at least this wide to sit beside the text
    static let narrowestStage: CGFloat = 280

    /// Panel: room is the most space it can take
    @ViewBuilder
    private func panel(_ card: Card, in room: CGSize) -> some View {
        if Self.hasStage(card, pictures: gallery.count), room.width < Reading.narrowWidth + Self.narrowestStage {
            // Window too narrow for visual and text side by side: visual on top, text below
            VStack(spacing: 0) {
                stage(card)
                    .frame(height: min(room.width * aspect, room.height / 2))
                    .frame(maxWidth: .infinity)
                    .background(Palette.stage.color)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { stageFrame = $0 }
                reader(card, compact: true)
            }
            .frame(maxWidth: room.width, maxHeight: room.height)
        } else if Self.hasStage(card, pictures: gallery.count) {
            // PDFs, like long images, are read by scrolling vertically, with no "whole-page proportion" to fit: give a fixed reading width and fill the height
            let size = Self.stageSize(aspect: aspect, long: card.form == .long || Self.isPDF(card), in: room)
            HStack(spacing: 0) {
                stage(card)
                    .frame(width: size.width, height: size.height)
                    .background(Palette.stage.color)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { stageFrame = $0 }
                reader(card, compact: true)
                    .frame(width: Reading.narrowWidth, height: size.height)
            }
        } else {
            VStack(spacing: 0) {
                if let track = AudioPlayer.Track(card, files: store.files) { AudioBar(audio: audio, track: track) }
                reader(card, compact: false)
            }
            .frame(maxWidth: Reading.pageWidth)
            // At most as tall as room, shorter when the content is short. Can't be written as frame(maxHeight:): that stretches the panel to full height regardless of content,
            // the visible page is only a small block in the middle, while the image underneath during expansion scales to full height; once removed after expanding, the page seems to suddenly shrink
            .layout(AtMost(height: room.height))
        }
    }

    private func reader(_ card: Card, compact: Bool) -> some View {
        Reader(store: store, card: card, images: images, compact: compact, bodyText: bodyText, transcriptText: transcriptText,
               highlight: highlight, discuss: discuss, follow: follow, seek: { play(at: $0) }, jump: { aim(at: $0.text, seconds: $0.seconds) },
               refetch: refetch, rewrite: rewrite)
    }

    /// PDF whose original file still exists: the whole document can be paged through in detail view
    static func isPDF(_ card: Card) -> Bool { card.kind == .document && card.format == "PDF" && card.original != nil }

    /// Whether there's a visual to show: images and videos always; web pages and documents need images and not be read as articles
    static func hasStage(_ card: Card, pictures: Int) -> Bool {
        switch card.kind {
        case .image, .video: true
        case .web, .document: pictures > 0 && !isArticle(card)
        case .text, .audio: false
        }
    }

    /// How big the visual area is: as large as possible while matching the visual's proportions, with no large blank margins. Landscape images and videos get short, wide panels, portrait ones tall panels.
    /// However short, leave room for the side column with title, description and key points; long images and PDFs (long) get a fixed width and scroll vertically
    static func stageSize(aspect: CGFloat, long: Bool, in room: CGSize) -> CGSize {
        let widest = room.width - Reading.narrowWidth
        if long { return CGSize(width: min(widest, 560), height: room.height) }
        let width = max(min(widest, room.height / aspect), min(widest, 380))
        return CGSize(width: width, height: min(max(width * aspect, min(room.height, 460)), room.height))
    }

    /// Focus the passage clicked in the discussion: scroll there and flash it; seekable video and audio play from that second
    private func aim() {
        guard let focus, focus.card == card else { return }
        aim(at: focus.text, seconds: focus.seconds)
    }

    /// Clicking a key point also goes here: scroll to that passage in the original and flash it, seekable media play from that second
    private func aim(at text: String?, seconds: Int?) {
        guard let loaded else { return }
        highlight = text.map { LongText.Highlight(text: $0) }
        let seekable = loaded.original != nil || loaded.player.map(Player.canSeek) == true
        if let seconds, seekable, loaded.kind == .video || loaded.kind == .audio { play(at: seconds) }
    }

    /// Play from that second: audio goes to the app-wide player (keeps playing after closing detail view or switching boards), video plays in the visual
    private func play(at seconds: Int) {
        if let loaded, let track = AudioPlayer.Track(loaded, files: store.files) { audio.play(track, at: Double(seconds)) } else { playing = Seek(seconds: seconds) }
    }

    /// Text cards you wrote and Markdown files are shown formatted, colors following the system light/dark mode
    static func markdown(_ type: Reading.Scale) -> Markdown.Style {
        Markdown.Style(body: type.body, lineSpacing: type.lineSpacing) { ink in
            switch ink {
            case .primary: NSColor.labelColor
            case .secondary: NSColor.secondaryLabelColor
            case .faint: NSColor.tertiaryLabelColor
            case .link: NSColor.linkColor
            }
        }
    }

    /// Web pages with body text are read as articles
    static func isArticle(_ card: Card) -> Bool { card.kind == .web && !(card.body ?? "").isEmpty }

    // MARK: Visual

    @ViewBuilder
    private func stage(_ card: Card) -> some View {
        switch card.kind {
        case .video where card.original != nil:
            // A timestamp in the transcript clicked: play from there with sound
            if let playing {
                StreamVideo(url: store.files.url(of: card.original!), seek: playing, hushed: audio.isPlaying) { audio.pause() }
            } else {
                LoopingVideo(url: store.files.url(of: card.original!))
            }
        case .video where card.player != nil:
            onlineVideo(card.player!, page: card.sourceURL ?? card.url)
        case .document where Self.isPDF(card):
            // The whole PDF covers the first page's preview image: before the file opens, or if it can't, the preview image is still visible
            pictures(long: false).overlay { PDFPages(url: store.files.url(of: card.original!)) }
        default:
            pictures(long: card.form == .long)
        }
    }

    /// Images: pinch to zoom in; scroll through long images vertically; switch between multiple images left and right
    private func pictures(long: Bool) -> some View {
        ZStack(alignment: .bottom) {
            if let picture {
                if !long, page == 0, let moving {
                    // Animated image: once the original file loads it takes over animating, replacing the static first frame (if kept, transparent animated images would show a still shadow through)
                    MovingImage(image: moving)
                } else {
                    // Flipping to the next image starts unzoomed; closing also returns to unzoomed first so the image flying back to the card matches
                    ZoomableImage(image: picture, long: long, whole: leaving).id(page)
                }
            }
            if gallery.count > 1 {
                HStack {
                    Button { page = (page + gallery.count - 1) % gallery.count } label: { Image(systemName: "chevron.left") }
                    Text("\(page + 1) / \(gallery.count)").monospacedDigit()
                    Button { page = (page + 1) % gallery.count } label: { Image(systemName: "chevron.right") }
                }
                .padding(8)
                .glassEffect()
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Online video: cover first, the player loads only when clicked (opening detail view doesn't go online).
    /// The player page is embedded in a blank page whose origin is the original page: some platforms (YouTube) won't play if they don't know who embedded them. Without an original page, use the player's own origin
    @ViewBuilder
    private func onlineVideo(_ player: String, page: String?) -> some View {
        if let playing {
            if Player.isStream(player), let url = URL(string: player) {
                StreamVideo(url: url, seek: playing, hushed: audio.isPlaying) { audio.pause() }
            } else {
                EmbeddedPlayer(player: player, seek: playing,
                               origin: [page, player].lazy.compactMap { $0.flatMap(URL.init(string:)).flatMap(Self.origin) }.first)
            }
        } else {
            // When the cover didn't download, a black block, so it still reads as a video
            pictures(long: false).background(gallery.isEmpty ? Color.black : .clear).overlay {
                Button { playing = Seek(seconds: 0) } label: {
                    Image(systemName: "play.fill").font(.system(size: 26)).frame(width: 68, height: 68)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
            }
        }
    }

    /// The origin part of a URL: https://www.bilibili.com
    static func origin(_ url: URL) -> URL? {
        guard let scheme = url.scheme, let host = url.host() else { return nil }
        return URL(string: "\(scheme)://\(host)")
    }

    // MARK: Full text, transcript

    /// Full text. Your own text and Markdown files are laid out as Markdown; an article's body is laid out by the reading page with its images, not here
    static func bodyText(_ card: Card, type: Reading.Scale) -> NSAttributedString? {
        if card.kind == .text || Markdown.applies(to: card) {
            guard let text = card.text ?? card.body, !text.isEmpty else { return nil }
            return Markdown.applies(to: card) ? Markdown.rendered(text, style: markdown(type))
                : LongText.attributed(text, font: .systemFont(ofSize: type.body), lineSpacing: type.lineSpacing, paragraphSpacing: type.paragraphSpacing)
        }
        guard let body = card.body, !body.isEmpty, !(isArticle(card) && type == Reading.wide) else { return nil }
        return timed(body, card: card, type: type, paragraphSpacing: type == Reading.wide ? type.paragraphSpacing : 0)
    }

    /// One transcript segment per line, with a little space between segments
    static func transcriptText(_ card: Card, type: Reading.Scale) -> NSAttributedString? {
        card.transcript.map { timed($0, card: card, type: type, paragraphSpacing: 8) }
    }

    /// Timestamp digits at the start of video and audio lines are monospaced and one shade lighter (a "19:00 dinner" in an article doesn't count); for seekable ones (local files, recognized players), timestamps become seek:seconds links
    static func timed(_ string: String, card: Card, type: Reading.Scale, paragraphSpacing: CGFloat) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: type.body)
        let text = NSMutableAttributedString(attributedString: LongText.attributed(string, font: font, lineSpacing: type.lineSpacing, paragraphSpacing: paragraphSpacing))
        let seekable = card.original != nil || card.player.map(Player.canSeek) == true
        let chapters = card.kind == .video || card.kind == .audio ? Player.chapters(in: string, duration: card.duration) : []
        for (range, seconds) in chapters {
            text.addAttributes([.font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular),
                                .foregroundColor: NSColor.secondaryLabelColor], range: range)
            if seekable { text.addAttributes([.link: URL(string: "seek:\(seconds)")!, .foregroundColor: NSColor.linkColor], range: range) }
        }
        return text
    }

    /// The animated image's original file is loaded in the background; the system image view decodes frames while playing, so even a big image with a hundred-plus frames only takes memory for a frame or two
    @concurrent static func moving(_ url: URL) async -> NSImage? {
        (try? Data(contentsOf: url)).flatMap(NSImage.init(data:))
    }

    /// Decode in the background, longest side no more than maxPixel
    @concurrent static func decode(_ url: URL, maxPixel: Int) async -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    /// The main colors from the color statistics (hex)
    static func swatches(_ json: String?) -> [String]? {
        guard let data = json?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["swatches"] as? [String]
    }
}

/// Give the content at most this much height; it takes however much it actually uses
private struct AtMost: SwiftUI.Layout {
    let height: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: min(proposal.height ?? height, height))) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

private extension View {
    func layout(_ layout: some SwiftUI.Layout) -> some View { layout { self } }
}

/// Long body text is laid out by the system text view: SwiftUI's Text takes about a second to lay out a several-thousand-character WeChat article, and opening detail view lays it out several times
struct LongText: NSViewRepresentable {
    let content: NSAttributedString
    /// The passage to scroll to and flash: the text block containing it scrolls itself
    var highlight: Highlight?
    /// A link in the body text clicked: return true if handled, otherwise open in the browser as usual
    var onLink: ((URL) -> Bool)?

    struct Highlight: Equatable {
        var text: String
        /// Clicking the same passage again flashes it again
        let id = UUID()
    }

    init(_ content: NSAttributedString, highlight: Highlight? = nil, onLink: ((URL) -> Bool)? = nil) {
        self.content = content
        self.highlight = highlight
        self.onLink = onLink
    }

    init(text: String, font: NSFont, lineSpacing: CGFloat, paragraphSpacing: CGFloat = 0, highlight: Highlight? = nil) {
        content = Self.attributed(text, font: font, lineSpacing: lineSpacing, paragraphSpacing: paragraphSpacing)
        self.highlight = highlight
    }

    static func attributed(_ text: String, font: NSFont, lineSpacing: CGFloat, paragraphSpacing: CGFloat = 0) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = paragraphSpacing
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
    }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator
        // Links only change color, no underline; links with their own color (citation numbers in the discussion) keep theirs
        view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.onLink = onLink
        if view.textStorage?.isEqual(to: content) == false { view.textStorage?.setAttributedString(content) }
        if let highlight, context.coordinator.flashed != highlight.id {
            context.coordinator.flashed = highlight.id
            // Find the position after this layout pass settles
            DispatchQueue.main.async { Self.flash(highlight.text, in: view) }
        }
    }

    /// Scroll to this passage, lay a temporary highlight under it, fade it after a moment. Do nothing if it's not in this text block
    static func flash(_ text: String, in view: NSTextView) {
        let range = (view.string as NSString).range(of: text)
        guard range.location != NSNotFound, let layout = view.layoutManager, let container = view.textContainer else { return }
        layout.ensureLayout(for: container)
        var rect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        rect.origin.y += view.textContainerOrigin.y
        // Leave context: the passage lands in the top third of the visible area
        view.scrollToVisible(rect.insetBy(dx: 0, dy: -min(160, view.visibleRect.height / 3)))
        layout.addTemporaryAttribute(.backgroundColor, value: NSColor.findHighlightColor.withAlphaComponent(Palette.flash), forCharacterRange: range)
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.flash) { layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, let container = view.textContainer, let layout = view.layoutManager else { return nil }
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let height = ceil(layout.usedRect(for: container).height)
        // SwiftUI measures at several widths: after measuring, give the text container back the view's current width, otherwise text lays out at the last measured width,
        // and won't change back if the view width doesn't change (text too narrow, or overflowing to the right, with content below overlapping)
        if view.bounds.width > 0 { container.size = NSSize(width: view.bounds.width, height: .greatestFiniteMagnitude) }
        return CGSize(width: width, height: height)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onLink: ((URL) -> Bool)?
        var flashed: UUID?

        func textView(_ view: NSTextView, clickedOnLink link: Any, at index: Int) -> Bool {
            guard let url = link as? URL else { return false }
            return onLink?(url) ?? false
        }
    }
}

/// An image you can look at closely: pinch to zoom, two-finger drag when zoomed, double-click to toggle between fit and actual size. Uses the system scroll view, so it feels like Preview and Photos.
/// Unzoomed, a normal image fits proportionally in this area, centered, matching the flown-in image; long images (long) fill the width and scroll vertically
private struct ZoomableImage: NSViewRepresentable {
    let image: CGImage
    var long = false
    /// Back to unzoomed
    var whole = false
    /// How far double-click zooms for images whose original isn't sharper than unzoomed; at most this many times the double-click level
    private static let fallback: CGFloat = 2, headroom: CGFloat = 3

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.allowsMagnification = true
        scroll.minMagnification = 1
        scroll.hasVerticalScroller = long
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = Picture()
        // When this area grows or shrinks, the unzoomed image is laid out again
        scroll.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.resized(_:)), name: NSView.frameDidChangeNotification, object: scroll)
        let twice = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.toggle(_:)))
        twice.numberOfClicksRequired = 2
        scroll.addGestureRecognizer(twice)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        (coordinator.image, coordinator.long) = (image, long)
        (scroll.documentView as? Picture)?.image = image
        if whole, scroll.magnification != 1 { scroll.magnification = 1 }
        coordinator.fit(scroll)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator: NSObject {
        var image: CGImage?
        var long = false

        /// How big the image is unzoomed: a normal image fills this area (fitted and centered inside), a long image is as wide as this area and proportionally tall
        func fit(_ scroll: NSScrollView) {
            guard let picture = scroll.documentView, let image, scroll.magnification == 1 else { return }
            let room = scroll.contentSize
            let size = long ? CGSize(width: room.width, height: (room.width * CGFloat(image.height) / CGFloat(image.width)).rounded()) : room
            if picture.frame.size != size { picture.frame = CGRect(origin: .zero, size: size) }
            scroll.maxMagnification = closeUp(in: scroll) * ZoomableImage.headroom
        }

        /// How far double-click zooms: looking closely is about seeing real pixels, so zoom to one image pixel per screen pixel; small images already this sharp unzoomed get a fixed factor
        private func closeUp(in scroll: NSScrollView) -> CGFloat {
            guard let image, let shown = scroll.documentView?.frame.size, shown.width > 0, shown.height > 0 else { return ZoomableImage.fallback }
            let drawn = min(shown.width / CGFloat(image.width), shown.height / CGFloat(image.height)) * (scroll.window?.backingScaleFactor ?? 2)
            return drawn < 1 / 1.2 ? 1 / drawn : ZoomableImage.fallback
        }

        @objc func resized(_ note: Notification) {
            if let scroll = note.object as? NSScrollView { fit(scroll) }
        }

        /// Double-click: zoom to actual size centered on the clicked point; if already zoomed, go back
        @objc func toggle(_ click: NSClickGestureRecognizer) {
            guard let scroll = click.view as? NSScrollView, let picture = scroll.documentView else { return }
            let point = click.location(in: picture), target = scroll.magnification > 1 ? 1 : closeUp(in: scroll)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.fade
                scroll.animator().setMagnification(target, centeredAt: point)
            }
        }
    }

    /// The block that draws the image: fitted proportionally, centered. Laid out top-down, so long images open at the top
    private final class Picture: NSView {
        var image: CGImage? {
            didSet { if image !== oldValue { needsDisplay = true } }
        }

        override var isFlipped: Bool { true }
        override var wantsUpdateLayer: Bool { true }

        override func updateLayer() {
            layer?.contentsGravity = .resizeAspect
            layer?.contents = image
        }
    }
}

/// Whole PDF: scroll through page by page, zoomable, text selectable. The file opens in the background and fades in once open
private struct PDFPages: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = Pages(), url = url
        view.displayMode = .singlePageContinuous
        view.autoScales = true
        view.backgroundColor = NSColor(Palette.stage.color)
        // Hidden (not just transparent) before opening: a transparent view still takes gestures, and the preview image underneath couldn't zoom
        view.isHidden = true
        view.alphaValue = 0
        Task {
            // Can't open, password protected, or no pages: don't cover, keep the preview image underneath
            guard let document = await Self.open(url).document, !document.isLocked, document.pageCount > 0 else { return }
            view.isHidden = false
            view.document = document
            // Go back to the top of page one after setting the scale from the column width: otherwise the position was computed before scaling and the title gets cut by half a line
            view.layoutDocumentView()
            if let first = document.page(at: 0) {
                view.go(to: PDFDestination(page: first, at: CGPoint(x: 0, y: first.bounds(for: view.displayBox).maxY)))
            }
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = Motion.swap
            view.animator().alphaValue = 1
            NSAnimationContext.endGrouping()
        }
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {}

    /// The context menu keeps only "Copy": the system's built-in items (single page, two pages, continuous scroll…) would switch it to a layout that doesn't fit the panel, reverting on next open
    private final class Pages: PDFView {
        override func menu(for event: NSEvent) -> NSMenu? {
            guard let menu = super.menu(for: event) else { return nil }
            for item in menu.items where item.action != #selector(NSText.copy(_:)) { menu.removeItem(item) }
            return menu.items.isEmpty ? nil : menu
        }
    }

    /// The opened document is handed back to the main thread for one use only
    private struct Opened: @unchecked Sendable { let document: PDFDocument? }

    @concurrent private static func open(_ url: URL) async -> Opened { Opened(document: PDFDocument(url: url)) }
}

/// A continuously animating image: fitted proportionally in the space given, centered
private struct MovingImage: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        // Size is decided from outside; don't stretch the panel to the image's original size
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            view.setContentCompressionResistancePriority(.defaultLow, for: axis)
            view.setContentHuggingPriority(.defaultLow, for: axis)
        }
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        if view.image !== image { view.image = image }
    }
}

/// Muted looping playback
private struct LoopingVideo: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        let player = AVQueuePlayer()
        player.isMuted = true
        context.coordinator.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        view.player = player
        view.controlsStyle = .floating
        player.play()
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) { view.player?.pause() }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var looper: AVPlayerLooper? }
}

/// Play or a timestamp clicked. Each click is a new one, so clicking the same timestamp again jumps back
struct Seek: Equatable {
    let seconds: Int
    let id = UUID()
}

/// With sound and controls, playing from the clicked second: online video streams, local video with a timestamp clicked
struct StreamVideo: NSViewRepresentable {
    let url: URL
    let seek: Seek
    /// Something else (audio) is making sound: pause here, staying on the visible frame
    let hushed: Bool
    /// This one is making sound (just started, or you clicked resume on the controls): make the other stop
    let sounded: () -> Void

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(), player = AVPlayer(url: url), coordinator = context.coordinator
        view.controlsStyle = .inline
        view.player = player
        coordinator.watching = player.observe(\.timeControlStatus) { player, _ in
            guard player.timeControlStatus == .playing else { return }
            Task { @MainActor in coordinator.sounded?() }
        }
        updateNSView(view, context: context)
        return view
    }

    /// Another timestamp clicked: jump there and keep playing
    func updateNSView(_ view: AVPlayerView, context: Context) {
        let coordinator = context.coordinator
        coordinator.sounded = sounded
        if coordinator.seek != seek {
            coordinator.seek = seek
            view.player?.seek(to: CMTime(seconds: Double(seek.seconds), preferredTimescale: 1))
            view.player?.play()
        } else if hushed, !coordinator.hushed {
            view.player?.pause()
        }
        coordinator.hushed = hushed
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.watching = nil
        view.player?.pause()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    @MainActor final class Coordinator {
        var seek: Seek?
        var hushed = false
        var sounded: (() -> Void)?
        var watching: NSKeyValueObservation?
    }
}

/// A platform's embedded player: a full-size iframe in a blank page whose origin is origin
private struct EmbeddedPlayer: NSViewRepresentable {
    let player: String
    let seek: Seek
    let origin: URL?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Loaded only after the play button is clicked, so autoplay is that click of yours
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.underPageBackgroundColor = .black
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        updateNSView(view, context: context)
        return view
    }

    /// Timestamp clicked: reload with the start time
    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.seek != seek, let url = Player.url(player, start: seek.seconds) else { return }
        context.coordinator.seek = seek
        context.coordinator.ownLoad = true
        let src = url.absoluteString.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
        let html = """
        <html><body style="margin:0;background:#000"><iframe src="\(src)" style="position:fixed;inset:0;width:100%;height:100%;border:0" \
        allow="autoplay; fullscreen; encrypted-media; picture-in-picture" allowfullscreen referrerpolicy="strict-origin-when-cross-origin"></iframe></body></html>
        """
        view.loadHTMLString(html, baseURL: origin)
    }

    /// Stop the sound when the detail view closes
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.ownLoad = true
        view.loadHTMLString("", baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Links clicked in the player (video title, "Watch on YouTube") would replace the whole page or open a new window: hand them to the browser, keep the player on the left
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var seek: Seek?
        /// The next full-page load is the blank page we set up ourselves
        var ownLoad = false

        func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard action.targetFrame?.isMainFrame == true else { return .allow }
            if ownLoad {
                ownLoad = false
                return .allow
            }
            if let url = action.request.url, ["http", "https"].contains(url.scheme) { NSWorkspace.shared.open(url) }
            return .cancel
        }

        func webView(_ view: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, ["http", "https"].contains(url.scheme) { NSWorkspace.shared.open(url) }
            return nil
        }
    }
}


extension Color {
    /// #RRGGBB
    init(hex: String) {
        let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
