import AppKit
import UniformTypeIdentifiers

enum Exporter {
    static func pngData(_ image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    static func copyToPasteboard(_ image: CGImage, to pb: NSPasteboard = .general) {
        pb.clearContents()
        let rep = NSBitmapImageRep(cgImage: image)
        if let png = rep.representation(using: .png, properties: [:]) { pb.setData(png, forType: .png) }
        if let tiff = rep.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
    }

    static func defaultFileName(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "截屏\(f.string(from: date)).png"
    }

    @MainActor
    static func saveWithPanel(_ image: CGImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = defaultFileName()
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        panel.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, let data = pngData(image) else { return }
        do { try data.write(to: url) } catch { NSLog("save failed: \(error)") }
        if Preferences.playSound { playCaptureSound() }
    }

    static func playCaptureSound() {
        let grab = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif"
        if let s = NSSound(contentsOfFile: grab, byReference: true) { s.play(); return }
        NSSound(named: "Pop")?.play()
    }
}
