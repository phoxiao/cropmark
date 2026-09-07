import AppKit
import ScreenCaptureKit

/// 一块显示器在按下快捷键那一刻的冻结画面。
struct ScreenSnapshot {
    let screen: NSScreen
    /// AppKit 坐标（y 向上）下的屏幕矩形，单位：点
    let frame: CGRect
    let scale: CGFloat
    /// 全分辨率像素图，y 向下
    let image: CGImage
}

enum ScreenGrabError: Error { case noDisplays, screenMismatch }

/// 用 ScreenCaptureKit 抓取所有显示器。
enum ScreenGrabber {
    static func grabAllScreens() async throws -> [ScreenSnapshot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard !content.displays.isEmpty else { throw ScreenGrabError.noDisplays }

        var snapshots: [ScreenSnapshot] = []
        for display in content.displays {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == display.displayID }) else { continue }
            let scale = screen.backingScaleFactor
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int((CGFloat(display.width) * scale).rounded())
            config.height = Int((CGFloat(display.height) * scale).rounded())
            config.showsCursor = false
            config.captureResolution = .best
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = CGColorSpace.sRGB
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            snapshots.append(ScreenSnapshot(screen: screen, frame: screen.frame, scale: scale, image: image))
        }
        guard !snapshots.isEmpty else { throw ScreenGrabError.screenMismatch }
        return snapshots
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
