import AppKit
import UniformTypeIdentifiers

enum Exporter {
    /// 带 DPI 信息的位图：Retina 截图按「点」尺寸声明，粘贴到 Pages、邮件这类尊重 DPI 的应用里才不会显示成两倍大。
    static func bitmapRep(_ image: CGImage, scale: CGFloat) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(cgImage: image)
        let s = max(scale, 1)
        rep.size = NSSize(width: CGFloat(image.width) / s, height: CGFloat(image.height) / s)
        return rep
    }

    static func pngData(_ image: CGImage, scale: CGFloat = 1) -> Data? {
        bitmapRep(image, scale: scale).representation(using: .png, properties: [:])
    }

    static func copyToPasteboard(_ image: CGImage, scale: CGFloat = 1, to pb: NSPasteboard = .general) {
        pb.clearContents()
        let rep = bitmapRep(image, scale: scale)
        if let png = rep.representation(using: .png, properties: [:]) { pb.setData(png, forType: .png) }
        if let tiff = rep.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
    }

    static func defaultFileName(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "截屏\(f.string(from: date)).png"
    }

    /// 弹系统保存框写 PNG。返回是否真的写成功了；失败会告诉用户，不只是记日志。
    @MainActor
    @discardableResult
    static func saveWithPanel(_ image: CGImage, scale: CGFloat = 1) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = defaultFileName()
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        panel.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        guard let data = pngData(image, scale: scale) else {
            presentSaveFailure("无法把截图编码为 PNG。")
            return false
        }
        do {
            try data.write(to: url)
        } catch {
            presentSaveFailure("写入 \(url.lastPathComponent) 失败：\(error.localizedDescription)")
            return false
        }
        if Preferences.playSound { playCaptureSound() }
        return true
    }

    @MainActor
    private static func presentSaveFailure(_ detail: String) {
        let alert = NSAlert()
        alert.messageText = "保存失败"
        alert.informativeText = detail + "\n截图仍在剪贴板里，可以直接粘贴。"
        alert.runModal()
    }

    static func playCaptureSound() {
        let grab = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif"
        if let s = NSSound(contentsOfFile: grab, byReference: true) { s.play(); return }
        NSSound(named: "Pop")?.play()
    }
}
