// 生成应用图标：make icon
// 由 Makefile 用 swiftc 连同 Cropmark/App/IconArtwork.swift 一起编译——
// 图形的几何和配色全在那份共享代码里，这里只负责出各种尺寸并打包成 icns。
// 输出 AppIcon.icns（经 iconutil）和 icon-preview.png（512）。
import AppKit

@main
enum MakeIcon {
    static func render(_ size: CGFloat) -> CGImage {
        let c = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                          space: IconArtwork.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.interpolationQuality = .high
        IconArtwork.drawAppIcon(c, canvas: size)
        return c.makeImage()!
    }

    static func png(_ img: CGImage) -> Data {
        NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!
    }

    static func main() {
        let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
        let fm = FileManager.default
        let iconset = URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon.iconset")
        try? fm.removeItem(at: iconset)
        try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            try! png(render(CGFloat(base))).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
            try! png(render(CGFloat(base * 2))).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
        }
        try! png(render(512)).write(to: URL(fileURLWithPath: outDir).appendingPathComponent("icon-preview.png"))

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        p.arguments = ["-c", "icns", iconset.path, "-o", URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon.icns").path]
        try! p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
        try? fm.removeItem(at: iconset)
        print("AppIcon.icns written to \(outDir)")
    }
}
