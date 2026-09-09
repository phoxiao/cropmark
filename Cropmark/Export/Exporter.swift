import AppKit
import UniformTypeIdentifiers

/// 一次导出的选项。真机从偏好读，测试直接构造。
struct ExportOptions: Equatable {
    /// 复制到剪贴板时缩小到 1x
    var copyAt1x = false
    /// 保存文件时缩小到 1x
    var saveAt1x = false
    /// 剪贴板同时附带 PNG 文件引用
    var clipboardIncludesFile = true

    static var current: ExportOptions {
        ExportOptions(copyAt1x: Preferences.copyAt1x,
                      saveAt1x: Preferences.saveAt1x,
                      clipboardIncludesFile: Preferences.clipboardIncludesFile)
    }
}

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

    /// 把 Retina 像素图重采样到屏幕显示尺寸（2x 就是长宽各减半）。scale ≤ 1 原样返回。
    static func downscaled(_ image: CGImage, by scale: CGFloat) -> CGImage? {
        guard scale > 1 else { return image }
        let w = max(1, Int((CGFloat(image.width) / scale).rounded()))
        let h = max(1, Int((CGFloat(image.height) / scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// 决定最终输出：要缩到 1x 就重采样并按 1x 声明，否则原像素加 DPI 声明。
    static func output(_ image: CGImage, scale: CGFloat, at1x: Bool) -> (image: CGImage, scale: CGFloat) {
        if at1x, scale > 1, let small = downscaled(image, by: scale) { return (small, 1) }
        return (image, scale)
    }

    /// 剪贴板附带文件时 PNG 落在这里；只留最近几张，不会越积越多。
    static let clipboardDirectory: URL = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Cropmark/Clipboard", isDirectory: true)

    /// 复制到剪贴板：一个 pasteboard item 同时带 PNG、TIFF，可选再带一个文件 URL。
    /// 类型顺序就是应用取用的优先顺序：要图的应用拿到图，Finder / 终端这类只认文件的拿到文件。
    static func copyToPasteboard(_ image: CGImage, scale: CGFloat = 1, includeFile: Bool = false,
                                 fileDirectory: URL = clipboardDirectory, to pb: NSPasteboard = .general) {
        pb.clearContents()
        let rep = bitmapRep(image, scale: scale)
        let item = NSPasteboardItem()
        let png = rep.representation(using: .png, properties: [:])
        if let png { item.setData(png, forType: .png) }
        if let tiff = rep.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        if includeFile, let png, let url = writeClipboardFile(png, in: fileDirectory) {
            item.setString(url.absoluteString, forType: .fileURL)
        }
        pb.writeObjects([item])
    }

    /// 把 PNG 写进剪贴板文件目录并清理旧文件。写失败返回 nil，剪贴板照常只有图片。
    static func writeClipboardFile(_ png: Data, in directory: URL, keep: Int = 20) -> URL? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            var url = directory.appendingPathComponent(defaultFileName())
            var n = 2
            while fm.fileExists(atPath: url.path) {
                let base = defaultFileName().dropLast(4)
                url = directory.appendingPathComponent("\(base) \(n).png")
                n += 1
            }
            try png.write(to: url)
            pruneClipboardFiles(in: directory, keep: keep)
            return url
        } catch {
            NSLog("clipboard file write failed: \(error)")
            return nil
        }
    }

    static func pruneClipboardFiles(in directory: URL, keep: Int) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let pngs = urls.filter { $0.pathExtension.lowercased() == "png" }
        guard pngs.count > keep else { return }
        let sorted = pngs.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for old in sorted.dropFirst(keep) { try? fm.removeItem(at: old) }
    }

    static func defaultFileName(date: Date = Date()) -> String {
        let f = DateFormatter()
        // 日期部分固定用阿拉伯数字，不随系统语言变；前缀随语言（截屏 / Screenshot）
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return L10n.t("截屏%@.png", f.string(from: date))
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
            presentSaveFailure(L10n.t("无法把截图编码为 PNG。"))
            return false
        }
        do {
            try data.write(to: url)
        } catch {
            presentSaveFailure(L10n.t("写入 %@ 失败：%@", url.lastPathComponent, error.localizedDescription))
            return false
        }
        if Preferences.playSound { playCaptureSound() }
        return true
    }

    @MainActor
    private static func presentSaveFailure(_ detail: String) {
        let alert = NSAlert()
        alert.messageText = L10n.t("保存失败")
        alert.informativeText = L10n.t("%@\n截图仍在剪贴板里，可以直接粘贴。", detail)
        alert.runModal()
    }

    static func playCaptureSound() {
        let grab = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif"
        if let s = NSSound(contentsOfFile: grab, byReference: true) { s.play(); return }
        NSSound(named: "Pop")?.play()
    }
}
