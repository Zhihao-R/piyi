import SwiftUI
import AVKit
import WebKit
import Library
import Canvas
import Tokens

/// 放大查看：只剩眼前这张卡。有画面的卡（图、视频、带配图的网页和文档），左边是画面，右边一栏文字；
/// 没有画面的卡整块是文字。文字只有阅读页一种版式（Reader），从上到下越来越细
struct DetailView: View {
    let store: Store
    let card: Int64
    /// 讨论里点了引用：滚到那一段闪一下，视频从那一秒播
    let focus: AppModel.Focus?
    /// 全应用那一个播放器：音频卡的声音交给它，这里带声音的视频开播时让它停
    let audio: AudioPlayer
    /// 出处那一行右端的按钮：讨论、放上桌
    let discuss: Action
    /// 对着画布上哪张卡：打开时从它长出来，关的时候缩回它。按方向键换来的、从讨论栏打开的没有
    let spot: Spot?
    /// 切回画板时原样开着的：不从卡片飞出来，跟着画布一起淡入
    let stayed: Bool
    /// 外面说要关了：缩回去或淡出，做完叫 closed
    let closing: Bool
    /// 被换下去了（换卡、切画板、直接关）：当作旧画面的一张，跟画布的旧画面同一节奏淡完，再叫 closed
    let away: Bool
    let close: () -> Void
    /// 打开原链接、原文件
    let follow: (URL) -> Void
    /// 残缺的卡重新抓取
    let refetch: () -> Void
    /// 你写的文字卡改了字
    let rewrite: (String) -> Void
    /// 把画布上那张卡拿起来（飞着的时候它不该还在原处）、放回去
    let lift: (Bool) -> Void
    let closed: () -> Void
    /// 面板的透明度和大小：进来时淡入、从卡片那边长出来，关的时候反过来
    @State private var shown = false
    @State private var grown = false
    /// 飞进来、飞回去的那张图。平时透明地叠在画面上跟着它走，关的时候显出来飞回去
    @State private var ghost: Ghost?
    @State private var flying = false
    /// 已经在关了。动画做完的回调里要看这个：传进来的 closing 是建视图那一刻的值，回调跑的时候早过期了
    @State private var leaving = false
    /// 画面那一块在窗口里的位置，飞进来落在它里面
    @State private var stageFrame: CGRect?
    /// 面板展开到一半时占的位置（不能整张飞的卡从卡片原位展开成面板）；nil 是停在原位
    @State private var morph: CGRect?
    /// 面板的大小和这块地方在窗口里的位置：面板停在正中，算得出它在哪
    @State private var panelSize: CGSize?
    @State private var area: CGRect = .zero
    /// 画面那张图解完了（解不出来也算）：飞来的那张这才淡掉
    @State private var decoded = false
    @State private var loaded: Card?
    /// 其余图片（不含封面）
    @State private var images: [String] = []
    @State private var page = 0
    /// 当前这一张图，在后台解码好
    @State private var picture: CGImage?
    /// 画面的高 / 宽：面板的大小跟着它走。读封面的文件头就知道，不用等解码
    @State private var aspect: CGFloat = 1
    /// 网上的视频点了播放、点了时间点，本机的视频点了时间点；nil 是还停在封面（本机视频静音循环）
    @State private var playing: Seek?
    /// 动图的原文件：读进来了就换下静止的第一帧，接着动
    @State private var moving: NSImage?
    /// 全文和转录：打开时排一次，点播放、点时间点不重排
    @State private var bodyText: NSAttributedString?
    @State private var transcriptText: NSAttributedString?

    /// 要闪一下的那一段
    @State private var highlight: LongText.Highlight?

    struct Action {
        var title: String
        var enabled: Bool
        var run: () -> Void
    }

    /// 封面加其余图片，左右切换看
    private var gallery: [String] { [loaded?.cover].compactMap { $0 } + images }

    var body: some View {
        GeometryReader { geo in
            let space = geo.frame(in: .global)
            ZStack {
                // 起飞、展开放在它出现之后：同一次更新里放上又改终点，它会直接停在终点
                if let ghost, ghost.below { ghostView(ghost, in: space).onAppear { unfold() } }
                if let loaded {
                    panel(loaded, in: CGSize(width: min(geo.size.width - Self.margin * 2, 1180), height: min(geo.size.height - Self.margin * 2, 800)))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .shadow(color: .black.opacity(0.3), radius: 30, y: 10)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { panelSize = $0 }
                        .scaleEffect(x: morphScale.width, y: morphScale.height)
                        .offset(x: morph.map { $0.midX - space.midX } ?? 0, y: morph.map { $0.midY - space.midY } ?? 0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(shown ? 1 : 0)
                        // 只有飞不了整张的卡从卡片那边长出来；整张飞的不缩放，画面的位置量出来就是落点
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
            // 面板出来以后、没在飞时，透明叠着的那张跟着画面走（窗口变了）
            if shown, !flying, ghost?.below != true, let stageFrame { ghost?.frame = fitted(in: stageFrame) }
            flyIn()
        }
        .onChange(of: decoded) { settle() }
        .onChange(of: closing) { if closing { leave() } }
        .onChange(of: away) { if away { fadeAway() } }
        .task(id: card) {
            // 卡片和配图一起到，免得长正文排两遍
            let card = try? await store.card(self.card)
            let images = (try? await store.images(of: self.card)) ?? []
            guard !Task.isCancelled else { return }
            let narrow = card.map { Self.hasStage($0, pictures: ($0.cover == nil ? 0 : 1) + images.count) } ?? false
            let type = narrow ? Reading.narrow : Reading.wide
            aspect = card.flatMap { c in c.cover.flatMap { CardSize.coverAspect($0, files: store.files) } ?? (c.kind == .video ? 9 / 16 : nil) } ?? 1
            (loaded, self.images, page, playing) = (card, images, 0, nil)
            (bodyText, transcriptText) = (card.flatMap { Self.bodyText($0, type: type) }, card.flatMap { Self.transcriptText($0, type: type) })
            aim()
            // 切回画板时原样开着、又没有画面可等的（文字、音频）：内容到了就淡入
            if stayed, let card, !Self.hasStage(card, pictures: gallery.count) { reappear() }
        }
        .onChange(of: focus?.id) { aim() }
        // 同一时间只有一个声音：视频带声音播了，音频停。音频播了，系统播放器播的视频自己暂停（见 StreamVideo）；
        // 平台的嵌入播放器是别人的网页，停不了它，只能回到封面
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
            // 阅读页自己按栏宽解码，这里不用
            if gallery.indices.contains(page), Self.hasStage(loaded, pictures: gallery.count) {
                let name = gallery[page]
                // 先用现成的缩略图顶上，大图解好再换：同一张图变清楚，看不出换。长图的缩略图只有开头一截，不顶
                if loaded.form != .long, let thumb = await Self.thumbnail(name, files: store.files), !Task.isCancelled { picture = thumb }
                if let full = await Self.decode(store.files.url(of: name), maxPixel: 4000), !Task.isCancelled { picture = full }
            }
            guard !Task.isCancelled else { return }
            decoded = true
            if stayed { reappear() }
        }
        // 切回画板时原样开着的：画面一到（缩略图就够）面板就淡入
        .onChange(of: picture) { if stayed, picture != nil { reappear() } }
    }

    // MARK: 从卡片长出来、缩回去

    struct Ghost {
        var face: CGImage
        var frame: CGRect
        var rotation: Double
        var opacity: Double = 1
        /// 垫在面板下面：展开时面板在它上面淡入；整张飞的图在面板上面，落地后再隐去
        var below = false
    }

    private func ghostView(_ ghost: Ghost, in space: CGRect) -> some View {
        Image(decorative: ghost.face, scale: 1).resizable()
            .frame(width: ghost.frame.width, height: ghost.frame.height)
            .rotationEffect(.radians(ghost.rotation))
            .position(x: ghost.frame.midX - space.minX, y: ghost.frame.midY - space.minY)
            .opacity(ghost.opacity)
            .allowsHitTesting(false)
    }

    /// 面板停在正中时的位置
    private var rest: CGRect? {
        panelSize.map { CGRect(x: area.midX - $0.width / 2, y: area.midY - $0.height / 2, width: $0.width, height: $0.height) }
    }

    /// 展开到一半时面板相对原大的缩放
    private var morphScale: CGSize {
        guard let morph, let panelSize, panelSize.width > 0, panelSize.height > 0 else { return CGSize(width: 1, height: 1) }
        return CGSize(width: morph.width / panelSize.width, height: morph.height / panelSize.height)
    }

    /// 不能整张飞的卡：面板从卡片原位展开到正中，卡片的样子垫在下面，面板在它上面一路淡入
    private func unfold() {
        guard ghost?.below == true, !flying, !shown, loaded != nil, let rest else { return }
        (grown, flying) = (true, true)
        withAnimation(.fly) {
            morph = nil
            ghost?.frame = rest
            ghost?.rotation = 0
            shown = true
        } completion: {
            guard !leaving else { return }
            flying = false
            // 面板是实的了；垫着的那张收起来，不然圆角处会露出来
            ghost?.opacity = 0
        }
    }

    /// 进来：整张画面的卡拿缩略图从卡片原位飞过来；其余的从卡片那边长出来（不是从画布打开的就原地淡入）
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

    /// 切回画板时原样开着的：面板连同画面一起淡入，跟画布换内容同步
    private func reappear() {
        guard !shown, !leaving else { return }
        grown = true
        withAnimation(.swap) { shown = true }
    }

    /// 飞不了整张画面的卡（文字、网页），面板从卡片那边长出来
    private var grows: Bool { spot != nil && spot?.cover == nil }

    /// 面板排好了（知道画面落在哪）就飞过去；图到位了，面板再在它周围淡入
    private func flyIn() {
        guard let stageFrame, ghost?.below == false, !flying, !shown, loaded != nil else { return }
        flying = true
        withAnimation(.fly) {
            ghost?.frame = fitted(in: stageFrame)
            ghost?.rotation = 0
        } completion: {
            guard !leaving else { return }
            // 面板完全出来、底下的画面是实的了，飞来的那张才隐去：两边都半透明的那一下会暗一闪
            withAnimation(.fade) { shown = true } completion: {
                guard !leaving else { return }
                flying = false
                settle()
            }
        }
    }

    /// 落地了、底下真的画面也到了：飞来的那张隐去。视频的画面由播放器自己出，落地就隐
    private func settle() {
        guard !flying, !leaving, decoded || loaded?.kind == .video else { return }
        if ghost == nil, let picture, let stageFrame {
            // 按方向键换来的：没飞过，也备一张透明的，关的时候好飞回去
            ghost = Ghost(face: picture, frame: fitted(in: stageFrame), rotation: 0, opacity: 0)
        }
        withAnimation(.swap) { ghost?.opacity = 0 }
    }

    /// 关：还在看第一张就从画面飞回卡片（半路上就从半路回）；翻到别的图、飞不了的卡缩回卡片那边淡出
    private func leave() {
        leaving = true
        // 展开出来的：原路收回卡片，卡片的样子在面板淡出的地方显出来
        if let spot, let face = spot.face, ghost?.below == true {
            lift(true)
            ghost?.face = face
            ghost?.opacity = 1
            flying = true
            withAnimation(.fly) {
                morph = spot.frame
                ghost?.frame = spot.frame
                ghost?.rotation = spot.rotation
                shown = false
            } completion: { closed() }
            return
        }
        guard let spot, spot.cover != nil, page == 0, ghost?.below == false else {
            lift(false)
            // 面板还没出来（缩略图还在解）：没有可收的，直接关
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

    /// 面板放大的支点：卡片中心在这块地方里的相对位置
    private static func anchor(of spot: Spot?, in space: CGRect) -> UnitPoint {
        guard let spot, space.width > 0, space.height > 0 else { return .center }
        return UnitPoint(x: (spot.frame.midX - space.minX) / space.width, y: (spot.frame.midY - space.minY) / space.height)
    }

    /// 图在画面那一块里实际占的位置：按比例放进去，居中
    private func fitted(in stage: CGRect) -> CGRect {
        let width = min(stage.width, stage.height / aspect), height = width * aspect
        return CGRect(x: stage.midX - width / 2, y: stage.midY - height / 2, width: width, height: height)
    }

    /// 飞的那张用硬盘上现成的缩略图（最大的一档），解得快，没有画布卡片上的角标
    private static func thumbnail(_ cover: String, files: FileStore) async -> CGImage? {
        for tier in FileStore.tiers.reversed() {
            if let image = await decode(files.thumbnailURL(of: cover, tier: tier), maxPixel: tier) { return image }
        }
        return nil
    }

    /// 面板离窗口边的距离
    private static let margin: CGFloat = 40
    /// 画面那一块至少这么宽才和文字并排
    static let narrowestStage: CGFloat = 280

    /// 面板：room 是它最多能占的地方
    @ViewBuilder
    private func panel(_ card: Card, in room: CGSize) -> some View {
        if Self.hasStage(card, pictures: gallery.count), room.width < Reading.narrowWidth + Self.narrowestStage {
            // 窗口窄到画面和文字并排不下：画面在上，文字在下
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
            let size = Self.stageSize(aspect: aspect, long: card.form == .long, in: room)
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
            .frame(maxWidth: Reading.pageWidth, maxHeight: room.height)
        }
    }

    private func reader(_ card: Card, compact: Bool) -> some View {
        Reader(store: store, card: card, images: images, compact: compact, bodyText: bodyText, transcriptText: transcriptText,
               highlight: highlight, discuss: discuss, follow: follow, seek: { play(at: $0) }, jump: { aim(at: $0.text, seconds: $0.seconds) },
               refetch: refetch, rewrite: rewrite)
    }

    /// 有没有画面可看：图片、视频总有；网页和文档要有配图、且不是按文章读的
    static func hasStage(_ card: Card, pictures: Int) -> Bool {
        switch card.kind {
        case .image, .video: true
        case .web, .document: pictures > 0 && !isArticle(card)
        case .text, .audio: false
        }
    }

    /// 画面那一块多大：尽量大，又刚好贴着画面的比例，四周不留大块空白。横图和视频的面板矮而宽，竖图的面板高。
    /// 再矮也留出旁边那一栏放标题、描述、要点的高度；长图给固定的宽度，上下滚着看
    static func stageSize(aspect: CGFloat, long: Bool, in room: CGSize) -> CGSize {
        let widest = room.width - Reading.narrowWidth
        if long { return CGSize(width: min(widest, 560), height: room.height) }
        let width = max(min(widest, room.height / aspect), min(widest, 380))
        return CGSize(width: width, height: min(max(width * aspect, min(room.height, 460)), room.height))
    }

    /// 对准讨论里点的那一段：滚过去闪一下；能跳时间的视频、音频从那一秒播
    private func aim() {
        guard let focus, focus.card == card else { return }
        aim(at: focus.text, seconds: focus.seconds)
    }

    /// 要点点了也走这里：滚到原文那一段闪一下，能跳时间的从那一秒播
    private func aim(at text: String?, seconds: Int?) {
        guard let loaded else { return }
        highlight = text.map { LongText.Highlight(text: $0) }
        let seekable = loaded.original != nil || loaded.player.map(Player.canSeek) == true
        if let seconds, seekable, loaded.kind == .video || loaded.kind == .audio { play(at: seconds) }
    }

    /// 从那一秒播：音频交给全应用那一个播放器（关了放大查看、切了画板接着响），视频在画面里播
    private func play(at seconds: Int) {
        if let loaded, let track = AudioPlayer.Track(loaded, files: store.files) { audio.play(track, at: Double(seconds)) } else { playing = Seek(seconds: seconds) }
    }

    /// 你写的文字卡、Markdown 文件排好了看，颜色跟着系统深浅色
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

    /// 有正文的网页按文章读
    static func isArticle(_ card: Card) -> Bool { card.kind == .web && !(card.body ?? "").isEmpty }

    // MARK: 画面

    @ViewBuilder
    private func stage(_ card: Card) -> some View {
        switch card.kind {
        case .video where card.original != nil:
            // 点了转录里的时间点：带声音从那里播
            if let playing {
                StreamVideo(url: store.files.url(of: card.original!), seek: playing, hushed: audio.isPlaying) { audio.pause() }
            } else {
                LoopingVideo(url: store.files.url(of: card.original!))
            }
        case .video where card.player != nil:
            onlineVideo(card.player!, page: card.sourceURL ?? card.url)
        default:
            pictures(long: card.form == .long)
        }
    }

    /// 图片：长图上下滚动看完；多图左右切换
    private func pictures(long: Bool) -> some View {
        ZStack(alignment: .bottom) {
            if let picture {
                let image = Image(decorative: picture, scale: 2)
                if long {
                    ScrollView { image.resizable().scaledToFit() }
                } else {
                    // 动图：原文件读进来了就由它接着动。静止的第一帧留着占位置，但藏起来：透明底的动图不然会透出一个不动的影子
                    let moves = page == 0 ? moving : nil
                    image.resizable().scaledToFit()
                        .opacity(moves == nil ? 1 : 0)
                        .overlay { if let moves { MovingImage(image: moves) } }
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

    /// 网上的视频：先是封面，点了才加载播放器（打开放大查看不额外联网）。
    /// 播放器网页嵌在一个以原页面为来源的空白页里：有的平台（YouTube）不知道被谁嵌入就不播。没有原页面时用播放器自己的来源
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
            // 封面没下下来时是一块黑底，看得出是视频
            pictures(long: false).background(gallery.isEmpty ? Color.black : .clear).overlay {
                Button { playing = Seek(seconds: 0) } label: {
                    Image(systemName: "play.fill").font(.system(size: 26)).frame(width: 68, height: 68)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
            }
        }
    }

    /// 网址的来源部分：https://www.bilibili.com
    static func origin(_ url: URL) -> URL? {
        guard let scheme = url.scheme, let host = url.host() else { return nil }
        return URL(string: "\(scheme)://\(host)")
    }

    // MARK: 全文、转录

    /// 全文。你写的文字、Markdown 文件按 Markdown 排；文章的正文由阅读页自己带着配图排，这里不排
    static func bodyText(_ card: Card, type: Reading.Scale) -> NSAttributedString? {
        if card.kind == .text || Markdown.applies(to: card) {
            guard let text = card.text ?? card.body, !text.isEmpty else { return nil }
            return Markdown.applies(to: card) ? Markdown.rendered(text, style: markdown(type))
                : LongText.attributed(text, font: .systemFont(ofSize: type.body), lineSpacing: type.lineSpacing, paragraphSpacing: type.paragraphSpacing)
        }
        guard let body = card.body, !body.isEmpty, !(isArticle(card) && type == Reading.wide) else { return nil }
        return timed(body, card: card, type: type, paragraphSpacing: type == Reading.wide ? type.paragraphSpacing : 0)
    }

    /// 转录一段一行，段与段之间空开一点
    static func transcriptText(_ card: Card, type: Reading.Scale) -> NSAttributedString? {
        card.transcript.map { timed($0, card: card, type: type, paragraphSpacing: 8) }
    }

    /// 视频、音频行首的时间点数字等宽、颜色淡一级（文章里的「19:00 晚宴」不算）；能跳时间的（本机文件、认得的播放器），时间点变成链接 seek:秒数
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

    /// 动图的原文件在后台读进来；各帧由系统的图片视图边播边解，一百多帧的大图也只占一两帧的内存
    @concurrent static func moving(_ url: URL) async -> NSImage? {
        (try? Data(contentsOf: url)).flatMap(NSImage.init(data:))
    }

    /// 在后台解码，最长边不超过 maxPixel
    @concurrent static func decode(_ url: URL, maxPixel: Int) async -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    /// 颜色统计里的几块主色（十六进制）
    static func swatches(_ json: String?) -> [String]? {
        guard let data = json?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["swatches"] as? [String]
    }
}

/// 长正文交给系统文本视图排版：SwiftUI 的 Text 排一篇几千字的公众号文章要卡一秒左右，打开放大查看时会排好几遍
struct LongText: NSViewRepresentable {
    let content: NSAttributedString
    /// 要滚到、闪一下的一段字：含它的那一块文本自己滚过去
    var highlight: Highlight?
    /// 点了正文里的链接：返回 true 表示处理过了，否则照常用浏览器打开
    var onLink: ((URL) -> Bool)?

    struct Highlight: Equatable {
        var text: String
        /// 同一段再点一次也再闪一次
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
        // 链接只换颜色，不加下划线；自己定了颜色的链接（讨论里的引用数字）照它自己的
        view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.onLink = onLink
        if view.textStorage?.isEqual(to: content) == false { view.textStorage?.setAttributedString(content) }
        if let highlight, context.coordinator.flashed != highlight.id {
            context.coordinator.flashed = highlight.id
            // 等这一轮排版落定再找位置
            DispatchQueue.main.async { Self.flash(highlight.text, in: view) }
        }
    }

    /// 滚到这段字，铺一层临时的底色，一会儿褪掉。不在这块文本里就什么也不做
    static func flash(_ text: String, in view: NSTextView) {
        let range = (view.string as NSString).range(of: text)
        guard range.location != NSNotFound, let layout = view.layoutManager, let container = view.textContainer else { return }
        layout.ensureLayout(for: container)
        var rect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        rect.origin.y += view.textContainerOrigin.y
        // 留出上下文：那一段落在可见区的上三分之一
        view.scrollToVisible(rect.insetBy(dx: 0, dy: -min(160, view.visibleRect.height / 3)))
        layout.addTemporaryAttribute(.backgroundColor, value: NSColor.findHighlightColor.withAlphaComponent(Palette.flash), forCharacterRange: range)
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.flash) { layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, let container = view.textContainer, let layout = view.layoutManager else { return nil }
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let height = ceil(layout.usedRect(for: container).height)
        // SwiftUI 会拿好几种宽度来量：量完把文本框还给视图现在的宽度，不然字按最后量的那个宽度排，
        // 视图宽度没变时不会再改回来（字排窄了、或溢出到右边，下面的东西压上来）
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

/// 一直在动的动图：按比例放进给它的地方，和垫在下面的第一帧重合
private struct MovingImage: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        // 大小听外面的，不按图的原始尺寸把面板撑开
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

/// 静音循环播放
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

/// 点了播放或者某个时间点。每点一次都是新的一次，同一个时间点再点也跳回去
struct Seek: Equatable {
    let seconds: Int
    let id = UUID()
}

/// 带声音、带控制条，从点的那一秒开始播：网上的视频流，点了时间点的本机视频
struct StreamVideo: NSViewRepresentable {
    let url: URL
    let seek: Seek
    /// 别处（音频）出声了：这边暂停，停在看到的地方
    let hushed: Bool
    /// 这边出声了（刚开播，或者你在控制条上点了继续）：让别处停
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

    /// 点了别的时间点：跳过去接着播
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

/// 平台的嵌入播放器：铺满的 iframe，放在以 origin 为来源的空白页里
private struct EmbeddedPlayer: NSViewRepresentable {
    let player: String
    let seek: Seek
    let origin: URL?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 点了播放按钮才加载，自动播放就是你点的那一下
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.underPageBackgroundColor = .black
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        updateNSView(view, context: context)
        return view
    }

    /// 点了时间点：带着开始时间重新加载
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

    /// 关掉放大查看时停下声音
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.ownLoad = true
        view.loadHTMLString("", baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// 播放器里点的链接（视频标题、「在 YouTube 上观看」）要换掉整页或开新窗口：交给浏览器，左边一直是播放器
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var seek: Seek?
        /// 下一次整页加载是自己装的空白页
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
