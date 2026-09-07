import AppKit

/// 盖住一整块屏幕的无边框窗口。内容分两层：底下是冻结画面（只画一次），上面是交互层。
final class OverlayWindow: NSWindow {
    let snapshot: ScreenSnapshot
    let overlayView: OverlayView

    init(snapshot: ScreenSnapshot, session: CaptureSession) {
        self.snapshot = snapshot
        self.overlayView = OverlayView(snapshot: snapshot, session: session)
        super.init(contentRect: snapshot.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false

        let container = NSView(frame: CGRect(origin: .zero, size: snapshot.frame.size))
        container.addSubview(FrozenImageView(image: snapshot.image, frame: container.bounds))
        container.addSubview(overlayView)
        contentView = container
        initialFirstResponder = overlayView
        makeFirstResponder(overlayView)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 冻结底图。独立成一个图层只画一次，覆盖层每次鼠标移动重绘时就不用再搬这张全分辨率大图。
final class FrozenImageView: NSView {
    private let image: CGImage

    init(image: CGImage, frame: CGRect) {
        self.image = image
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // 像素与点一一对应，不需要插值
        ctx.interpolationQuality = .none
        ctx.draw(image, in: bounds)
    }
}
