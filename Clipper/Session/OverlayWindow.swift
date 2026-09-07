import AppKit

/// 盖住一整块屏幕的无边框窗口。
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
        contentView = overlayView
        initialFirstResponder = overlayView
        makeFirstResponder(overlayView)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
