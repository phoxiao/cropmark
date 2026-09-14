// 在一张真实截图上试跑块检测，把结果画出来。
// 用法：
//   block-probe 图片.png                  → 全图扫一遍网格，按出现次数列出检测到的块，并画出最常见的那个
//   block-probe 图片.png x y [输出.png]    → 只测一个点（图片像素坐标，左上原点）
// 由 Makefile 连同 Cropmark/Capture/BlockDetector.swift 一起编译，跑的就是应用里那份算法。
import AppKit

@main
enum BlockProbe {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2,
              let image = NSImage(contentsOfFile: args[1])?
                  .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("用法：block-probe 图片.png [x y] [输出.png]"); exit(1)
        }
        print("图片 \(image.width)x\(image.height)")
        if args.count >= 4, let px = Int(args[2]), let py = Int(args[3]) {
            single(image, px, py, out: args.count >= 5 ? args[4] : nil)
        } else {
            grid(image, out: args.count >= 3 ? args[2] : defaultOut(args[1]))
        }
    }

    static func defaultOut(_ input: String) -> String {
        (input as NSString).deletingPathExtension + "-blocks.png"
    }

    static func single(_ image: CGImage, _ px: Int, _ py: Int, out: String?) {
        print("取样点 (\(px),\(py))")
        for step in [1, 2, 4] {
            guard let buf = LumaBuffer.make(from: image, step: step) else { continue }
            let bounds = PixelRect(x0: 0, y0: 0, x1: buf.width - 1, y1: buf.height - 1)
            let t0 = Date()
            let r = BlockDetector.rect(at: (x: px / step, y: py / step), in: buf, bounds: bounds)
            let ms = Date().timeIntervalSince(t0) * 1000
            guard let r else { print(String(format: "step=%d  %4.0f ms  → 没找到，退回整窗", step, ms)); continue }
            let full = scaled(r, step)
            print(String(format: "step=%d  %4.0f ms  → %d,%d %dx%d", step, ms, full.x0, full.y0, full.width, full.height))
            if step == 2, let out { draw(image, boxes: [full], to: out) }
        }
    }

    /// 全图按网格取样，统计各个点分别识别出了什么块
    static func grid(_ image: CGImage, out: String) {
        let step = 2
        guard let buf = LumaBuffer.make(from: image, step: step) else { print("图太小"); return }
        let bounds = PixelRect(x0: 0, y0: 0, x1: buf.width - 1, y1: buf.height - 1)
        var tally: [String: (rect: PixelRect, count: Int)] = [:]
        var miss = 0, samples = 0
        let t0 = Date()
        var y = buf.height / 20
        while y < buf.height * 19 / 20 {
            var x = buf.width / 20
            while x < buf.width * 19 / 20 {
                samples += 1
                if let r = BlockDetector.rect(at: (x: x, y: y), in: buf, bounds: bounds) {
                    let key = "\(r.x0),\(r.y0),\(r.x1),\(r.y1)"
                    tally[key] = (r, (tally[key]?.count ?? 0) + 1)
                } else { miss += 1 }
                x += max(8, buf.width / 40)
            }
            y += max(8, buf.height / 40)
        }
        let ms = Date().timeIntervalSince(t0) * 1000
        print(String(format: "取样 %d 个点，用时 %.0f ms（平均每点 %.1f ms）", samples, ms, ms / Double(max(samples, 1))))
        print("没找到块的点：\(miss) 个（这些位置会退回整窗高亮）\n")
        let top = tally.values.sorted { $0.count > $1.count }.prefix(12)
        for t in top {
            let f = scaled(t.rect, step)
            print(String(format: "  %4d 个点 → %d,%d  %dx%d", t.count, f.x0, f.y0, f.width, f.height))
        }
        draw(image, boxes: top.map { scaled($0.rect, step) }, to: out)
    }

    static func scaled(_ r: PixelRect, _ step: Int) -> PixelRect {
        PixelRect(x0: r.x0 * step, y0: r.y0 * step, x1: r.x1 * step, y1: r.y1 * step)
    }

    static func draw(_ image: CGImage, boxes: [PixelRect], to path: String) {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.setLineWidth(4)
        // 画布是左下原点，框是左上原点，y 要翻过来。第一个（最常见的）画红，其余画蓝。
        for (i, box) in boxes.enumerated() {
            ctx.setStrokeColor(i == 0 ? CGColor(red: 1, green: 0.15, blue: 0.15, alpha: 1)
                                      : CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 0.7))
            ctx.stroke(CGRect(x: box.x0, y: image.height - box.y1, width: box.width, height: box.height))
        }
        guard let out = ctx.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: path))
        print("已画出 → \(path)")
    }
}
