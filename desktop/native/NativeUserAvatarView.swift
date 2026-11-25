import AppKit

/// Circular object-cover rendering. Original bytes and a serial decoder exist
/// only while visible. No network access, predecoded frame array or polling timer.
final class NativeUserAvatarView:NSView {
    enum AnimationStatus: Equatable {
        case staticImage, paused, loading, waiting, playing, finished, unavailable(String)
        var message: String {
            switch self {
            case .staticImage: return "静止画を表示しています。"
            case .paused: return "写真の再生は表示中だけ行います。"
            case .loading: return "動く写真を読み込んでいます。"
            case .waiting: return "ほかの写真の再生が終わるまで待機しています。"
            case .playing: return "動く写真を再生しています。"
            case .finished: return "写真の再生が終了しました。"
            case .unavailable(let reason): return reason
            }
        }
    }
    typealias AnimationLoader = @MainActor () async throws -> Data?
    var decoderExecutableURL = NativeUserAvatarWorkerClient.bundledExecutableURL
    var onAnimationStatusChange: ((AnimationStatus) -> Void)?
    private(set) var animationStatus: AnimationStatus = .staticImage
    private(set) var animationFrameIndex: Int?
    private var image:CGImage?,thumbnail:CGImage?,fallback="?"
    private var animationLoader: AnimationLoader?
    private var playback: Task<Void, Never>?
    private var generation = UUID(), terminal = false, closing = false
    private var observers: [NSObjectProtocol] = []
    override var intrinsicContentSize:NSSize{NSSize(width:100,height:100)}
    override init(frame:NSRect){super.init(frame:frame);setAccessibilityElement(true);setAccessibilityRole(.image);setAccessibilityLabel("プロフィール写真")}
    required init?(coder:NSCoder){fatalError("init(coder:) is unsupported")}
    deinit { playback?.cancel();for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    func set(image:CGImage?,name:String?=nil){stopAnimation();self.image=image;thumbnail=image;let letters=(name ?? "").split(separator:" ").compactMap{$0.first}.prefix(2);fallback=letters.isEmpty ? "?":String(letters).uppercased();needsDisplay=true}

    /// Supply a fresh authorized read (e.g. store.original(forUserID:)?.data).
    /// Do not pre-load or capture the original Data in this closure. Visibility
    /// restoration reopens and validates the original, and restarts at frame 0.
    func setAnimationSource(_ loader: @escaping AnimationLoader) {
        stopAnimation();animationLoader = loader;setStatus(.paused);refreshAnimationVisibility()
    }
    func stopAnimation() {
        animationLoader = nil;cancelPlayback();setStatus(.staticImage)
    }
    private func cancelPlayback() {
        generation = UUID();playback?.cancel();playback = nil;terminal = false
        animationFrameIndex = nil;image = thumbnail;needsDisplay = true
    }
    private func setStatus(_ status: AnimationStatus) {
        guard animationStatus != status else { return }
        animationStatus = status;setAccessibilityHelp(status.message);onAnimationStatusChange?(status)
    }
    private var visibleForAnimation: Bool {
        guard let window else { return false }
        return !closing && !NSApp.isHidden && window.isVisible && !window.isMiniaturized
            && window.occlusionState.contains(.visible) && !isHiddenOrHasHiddenAncestor
            && !visibleRect.isEmpty && bounds.width > 0 && bounds.height > 0
    }
    func refreshAnimationVisibility() {
        guard let loader = animationLoader else { return }
        guard visibleForAnimation else {
            if playback != nil || terminal { cancelPlayback() }
            setStatus(.paused);return
        }
        guard playback == nil && !terminal else { return }
        let token = UUID();generation = token;setStatus(.loading)
        guard generation == token else { return }
        let load: AnimationLoader = { [weak self, loader] in
            try Task.checkCancellation()
            guard self?.generation == token && self?.visibleForAnimation == true else { throw CancellationError() }
            return try await loader()
        }
        let helperExecutable = decoderExecutableURL
        playback = Task.detached(priority: .utility) { [weak self, load] in
            let cancellation = NativeUserAvatarPlaybackCancellation()
            defer { cancellation.finish() }
            await withTaskCancellationHandler(operation: {
            do {
                // Coalesce queued WindowServer occlusion changes before doing I/O.
                try await Task.sleep(nanoseconds: 20_000_000)
                let data = try await load()
                try Task.checkCancellation()
                guard let data else {
                    await MainActor.run { [weak self] in self?.complete(.staticImage, token: token) };return
                }
                let decoder = try await NativeUserAvatarPlayback(data: data, helperExecutable: helperExecutable, cancellation: cancellation, waitingChanged: { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self,self.generation == token,self.visibleForAnimation else{return}
                        if cancellation.isWaiting {self.setStatus(.waiting)}
                        else if self.animationStatus == .waiting {self.setStatus(.loading)}
                    }
                }, refreshSource: { try await load() })
                guard decoder.frameCount > 1 else {
                    if decoder.requiresInitialFrameDisplay,let frame=try autoreleasepool(invoking:{try decoder.nextFrame()}) {
                        try Task.checkCancellation()
                        let accepted=await MainActor.run { [weak self] in self?.receive(frame,token:token) ?? false }
                        guard accepted else{return}
                    }
                    await MainActor.run { [weak self] in self?.complete(.staticImage, token: token) };return
                }
                while let frame = try autoreleasepool(invoking: { try decoder.nextFrame() }) {
                    try Task.checkCancellation()
                    let accepted = await MainActor.run { [weak self] in self?.receive(frame, token: token) ?? false }
                    guard accepted else { return }
                    // One cancellable wait per frame; no timer exists offscreen.
                    try await Task.sleep(nanoseconds: UInt64(frame.delay * 1_000_000_000))
                }
                await MainActor.run { [weak self] in self?.complete(.finished, token: token) }
            } catch is CancellationError {
                // The generation fence also rejects a noncooperative old loader.
            } catch {
                let reason = (error as? NativeUserAvatarAnimation.Failure)?.errorDescription
                    ?? (error as? NativeUserAvatarWorkerFailure)?.errorDescription
                    ?? "写真を読み込めないため、静止画を表示しています。"
                await MainActor.run { [weak self] in self?.complete(.unavailable(reason), token: token) }
            }
            }, onCancel: { cancellation.cancel() })
        }
    }
    private func receive(_ frame: NativeUserAvatarAnimation.Frame, token: UUID) -> Bool {
        guard generation == token && visibleForAnimation else {
            if generation == token { refreshAnimationVisibility() };return false
        }
        image = frame.image;animationFrameIndex = frame.index;setStatus(.playing);needsDisplay = true;return true
    }
    private func complete(_ status: AnimationStatus, token: UUID) {
        guard generation == token else { return }
        playback = nil;terminal = true
        if case .unavailable = status { image = thumbnail;animationFrameIndex = nil;needsDisplay = true }
        setStatus(status)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in observers { NotificationCenter.default.removeObserver(observer) };observers.removeAll()
        closing = false
        if let window {
            let center = NotificationCenter.default
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.didUpdateNotification,
                         NSWindow.didResizeNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.refreshAnimationVisibility() })
            }
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                self?.closing = true;self?.refreshAnimationVisibility()
            })
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                observers.append(center.addObserver(forName: name, object: NSApp, queue: .main) { [weak self] _ in self?.refreshAnimationVisibility() })
            }
        }
        refreshAnimationVisibility()
    }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview();refreshAnimationVisibility() }
    override func viewDidHide() { super.viewDidHide();refreshAnimationVisibility() }
    override func viewDidUnhide() { super.viewDidUnhide();refreshAnimationVisibility() }
    override func layout() { super.layout();refreshAnimationVisibility() }
    override func draw(_ dirtyRect:NSRect){let side=min(bounds.width,bounds.height),rect=NSRect(x:bounds.midX-side/2,y:bounds.midY-side/2,width:side,height:side);NSGraphicsContext.saveGraphicsState();defer{NSGraphicsContext.restoreGraphicsState()};NSBezierPath(ovalIn:rect).addClip()
        if let image,let context=NSGraphicsContext.current?.cgContext{let ratio=max(rect.width/CGFloat(image.width),rect.height/CGFloat(image.height));let size=NSSize(width:CGFloat(image.width)*ratio,height:CGFloat(image.height)*ratio);context.interpolationQuality = .high;context.draw(image,in:CGRect(x:rect.midX-size.width/2,y:rect.midY-size.height/2,width:size.width,height:size.height))}
        else{NSColor.controlBackgroundColor.setFill();rect.fill();let attrs:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:side*0.28,weight:.semibold),.foregroundColor:NSColor.secondaryLabelColor];let text=NSAttributedString(string:fallback,attributes:attrs),size=text.size();text.draw(at:NSPoint(x:rect.midX-size.width/2,y:rect.midY-size.height/2))}
        NSColor.separatorColor.setStroke();let border=NSBezierPath(ovalIn:rect.insetBy(dx:0.5,dy:0.5));border.lineWidth=1;border.stroke()
    }
}
