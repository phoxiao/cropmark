// 生成应用图标：swift scripts/make-icon.swift <输出目录>
// 输出 AppIcon.icns（经 iconutil）和 icon-preview.png（512）。全部用 CoreGraphics 绘制，不含 SF Symbols。
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
func hex(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [CGFloat((h >> 16) & 0xff) / 255, CGFloat((h >> 8) & 0xff) / 255, CGFloat(h & 0xff) / 255, a])!
}

/// 在 size×size 像素画布上绘制图标
func render(_ size: CGFloat) -> CGImage {
    let c = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                      space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    // macOS 图标网格：1024 画布中图形占 824，圆角 22.5%
    let icon = CGRect(x: size * 100 / 1024, y: size * 100 / 1024, width: size * 824 / 1024, height: size * 824 / 1024)
    let radius = icon.width * 0.225
    let shape = CGPath(roundedRect: icon, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // 底：奶白到浅灰竖向渐变 + 细描边
    c.saveGState()
    c.addPath(shape); c.clip()
    let bg = CGGradient(colorsSpace: sRGB, colors: [hex(0xFFFFFF), hex(0xE9ECF2)] as CFArray, locations: nil)!
    c.drawLinearGradient(bg, start: CGPoint(x: 0, y: icon.maxY), end: CGPoint(x: 0, y: icon.minY), options: [])
    c.restoreGState()
    c.saveGState()
    c.addPath(shape); c.setStrokeColor(hex(0x000000, 0.08)); c.setLineWidth(max(size * 0.006, 1)); c.strokePath()
    c.restoreGState()

    // 选区与"画面"
    let sel = icon.insetBy(dx: icon.width * 0.19, dy: icon.height * 0.19)
    let pic = sel.insetBy(dx: sel.width * 0.16, dy: sel.height * 0.16).insetBy(dx: -size * 0.01, dy: -size * 0.01)
    let corner = size * 0.035
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -size * 0.02), blur: size * 0.05, color: hex(0x000000, 0.35))
    let picPath = CGPath(roundedRect: pic, cornerWidth: corner, cornerHeight: corner, transform: nil)
    c.addPath(picPath); c.setFillColor(hex(0xFF7A59)); c.fillPath()
    c.restoreGState()
    c.saveGState()
    c.addPath(picPath); c.clip()
    let g = CGGradient(colorsSpace: sRGB, colors: [hex(0xFF7A59), hex(0xFFC53D), hex(0x4FD1C5), hex(0x5B7CFA)] as CFArray, locations: nil)!
    c.drawLinearGradient(g, start: CGPoint(x: pic.minX, y: pic.maxY), end: CGPoint(x: pic.maxX, y: pic.minY), options: [])
    c.restoreGState()

    // 四个 L 括角
    c.saveGState()
    c.setStrokeColor(hex(0x2B2F3A)); c.setLineWidth(size * 0.045); c.setLineCap(.round); c.setLineJoin(.round)
    let len = sel.width * 0.24
    let r = sel
    let corners: [(CGPoint, CGPoint, CGPoint)] = [
        (CGPoint(x: r.minX, y: r.maxY - len), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX + len, y: r.maxY)),
        (CGPoint(x: r.maxX - len, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY - len)),
        (CGPoint(x: r.maxX, y: r.minY + len), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX - len, y: r.minY)),
        (CGPoint(x: r.minX + len, y: r.minY), CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.minX, y: r.minY + len)),
    ]
    for (a, b, d) in corners { c.move(to: a); c.addLine(to: b); c.addLine(to: d) }
    c.strokePath()
    c.restoreGState()
    return c.makeImage()!
}

func png(_ img: CGImage) -> Data { NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])! }

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
