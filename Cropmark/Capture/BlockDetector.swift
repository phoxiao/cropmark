import CoreGraphics

/// 灰度亮度图。左上原点、y 向下，和像素排布一致。
/// 独立成一个值类型，是为了让检测逻辑完全脱离 CGImage，单测可以直接拿合成数据跑。
struct LumaBuffer {
    let width: Int
    let height: Int
    /// 每像素一个字节的亮度，长度必须是 width * height
    let pixels: [UInt8]

    @inline(__always)
    func luma(_ x: Int, _ y: Int) -> Int { Int(pixels[y * width + x]) }

    /// 把截图降采样成亮度图。step 是采样步长，检测结果要乘回去才是原图坐标。
    static func make(from image: CGImage, step: Int) -> LumaBuffer? {
        let w = image.width / step, h = image.height / step
        guard w > 2, h > 2 else { return nil }
        var gray = [UInt8](repeating: 0, count: w * h)
        let ok: Bool = gray.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? LumaBuffer(width: w, height: h, pixels: gray) : nil
    }
}

/// 像素坐标下的闭区间矩形（四个端点都含）
struct PixelRect: Equatable {
    var x0: Int, y0: Int, x1: Int, y1: Int
    var width: Int { x1 - x0 + 1 }
    var height: Int { y1 - y0 + 1 }
    var area: Int { width * height }
    func contains(_ p: (x: Int, y: Int)) -> Bool { p.x >= x0 && p.x <= x1 && p.y >= y0 && p.y <= y1 }
}

/// 在截图上找光标所在的那个「块」——对话框、卡片、面板。
///
/// 为什么不问系统：实测微信这类自绘应用根本不把界面交给无障碍接口；SwiftUI 应用交了，
/// 但弹框那一层的矩形是整个内容区而不是那张卡片。卡片的边界只存在于像素里。
///
/// 做法是从光标处做**同色区域生长**，再取生长结果的外接矩形。
/// 一开始试过「向外扫描找第一条完整的边」，被自己的单测证伪了：卡片里一行文字的上下缘
/// 同样是一条横贯整张卡片的边，扫描会停在文字上。区域生长则把文字当成被包住的洞，
/// 外接矩形照样是整张卡片。
enum BlockDetector {
    /// 尺寸类的判据一律以**缓冲区像素**为单位。缓冲区是降采样过的，同样的像素数在
    /// Retina 屏和普通屏上对应的点数不一样，所以调用方（BlockLocator）负责把「点」换算成
    /// 这里的像素再传进来，绝不能两边各写一个 40 就当对上了。
    struct Config {
        /// 和种子点亮度差多少以内算「同一块背景」。卡片底色通常是平的，定紧一点防止漏到外面。
        var tolerance = 16
        /// 找种子时看多大一圈。要比一行文字高，这样光标压在字上时众数仍然是卡片底色。
        var seedWindow = 21
        /// 生长出来的面积占外接矩形的比例。太低说明形状是个细条或 L 形，不像一个块。
        var minFillRatio = 0.45
        /// 长出来的面积占搜索范围的比例，超过就当场放弃——这是「漏到整屏背景上去了」的早停，
        /// 按范围取相对值，不能写死一个绝对像素数（写死的话在降采样后的缓冲上永远够不着）。
        var maxFillRatio = 0.85
        /// 外接矩形边长下限（缓冲像素）。太小说明命中的是图标或按钮。
        var minSide = 40
        /// 外接矩形面积占搜索范围的比例上限。到这个份上等于没细化。
        var maxAreaRatio = 0.9
    }

    /// point 和 bounds 都是缓冲区自己的像素坐标。找不到返回 nil，调用方退回整窗。
    static func rect(at point: (x: Int, y: Int),
                     in buffer: LumaBuffer,
                     bounds: PixelRect,
                     config: Config = Config()) -> PixelRect? {
        guard bounds.contains(point),
              bounds.x0 >= 0, bounds.y0 >= 0,
              bounds.x1 < buffer.width, bounds.y1 < buffer.height else { return nil }
        guard let seed = seed(at: point, in: buffer, bounds: bounds, config: config),
              let grown = grow(from: seed.origin, seed: seed.luma, in: buffer, bounds: bounds, config: config)
        else { return nil }

        let r = grown.rect
        guard r.contains(point),                       // 框里必须含光标，否则高亮和指针对不上
              r.width >= config.minSide, r.height >= config.minSide,
              Double(r.area) <= Double(bounds.area) * config.maxAreaRatio,
              Double(grown.filled) >= Double(r.area) * config.minFillRatio
        else { return nil }
        return r
    }

    /// 取光标附近出现最多的那档亮度当基准色——光标压在文字上时，周围一圈仍然以卡片底色为主。
    /// 同时返回离光标最近的一个该色像素当生长起点：起点必须是底色，不能是光标底下那个笔画像素。
    private static func seed(at point: (x: Int, y: Int), in buffer: LumaBuffer,
                             bounds: PixelRect, config: Config) -> (luma: Int, origin: (x: Int, y: Int))? {
        let half = config.seedWindow / 2
        let ys = max(bounds.y0, point.y - half)...min(bounds.y1, point.y + half)
        let xs = max(bounds.x0, point.x - half)...min(bounds.x1, point.x + half)
        var histogram = [Int](repeating: 0, count: 256)
        for y in ys { for x in xs { histogram[buffer.luma(x, y)] += 1 } }

        var best = buffer.luma(point.x, point.y), bestCount = -1
        for (value, count) in histogram.enumerated() where count > bestCount {
            best = value; bestCount = count
        }
        var origin: (x: Int, y: Int)?
        var nearest = Int.max
        for y in ys {
            for x in xs where abs(buffer.luma(x, y) - best) <= config.tolerance {
                let d = (x - point.x) * (x - point.x) + (y - point.y) * (y - point.y)
                if d < nearest { nearest = d; origin = (x, y) }
            }
        }
        return origin.map { (best, $0) }
    }

    /// 扫描线区域生长：一次吃掉一整行连续的同色像素，再把上下两行入栈。
    /// 比逐像素四邻域快一个数量级，栈也浅得多。
    private static func grow(from point: (x: Int, y: Int), seed: Int, in buffer: LumaBuffer,
                             bounds: PixelRect, config: Config) -> (rect: PixelRect, filled: Int)? {
        let lo = seed - config.tolerance, hi = seed + config.tolerance
        let maxFill = Int(Double(bounds.area) * config.maxFillRatio)
        @inline(__always) func matches(_ x: Int, _ y: Int) -> Bool {
            let v = buffer.luma(x, y)
            return v >= lo && v <= hi
        }
        guard matches(point.x, point.y) else { return nil }

        var visited = [Bool](repeating: false, count: buffer.width * buffer.height)
        var stack = [(x: point.x, y: point.y)]
        var rect = PixelRect(x0: point.x, y0: point.y, x1: point.x, y1: point.y)
        var filled = 0

        while let p = stack.popLast() {
            guard !visited[p.y * buffer.width + p.x], matches(p.x, p.y) else { continue }
            var left = p.x
            while left > bounds.x0, !visited[p.y * buffer.width + left - 1], matches(left - 1, p.y) { left -= 1 }
            var right = p.x
            while right < bounds.x1, !visited[p.y * buffer.width + right + 1], matches(right + 1, p.y) { right += 1 }

            for x in left...right { visited[p.y * buffer.width + x] = true }
            filled += right - left + 1
            if filled > maxFill { return nil }   // 漏到整屏背景上去了
            rect.x0 = min(rect.x0, left); rect.x1 = max(rect.x1, right)
            rect.y0 = min(rect.y0, p.y);  rect.y1 = max(rect.y1, p.y)

            for neighbour in [p.y - 1, p.y + 1] where neighbour >= bounds.y0 && neighbour <= bounds.y1 {
                var x = left
                while x <= right {
                    if !visited[neighbour * buffer.width + x], matches(x, neighbour) {
                        stack.append((x: x, y: neighbour))
                        // 同一段连续区间入栈一个点就够，跳到段尾
                        while x <= right, matches(x, neighbour) { x += 1 }
                    }
                    x += 1
                }
            }
        }
        return (rect, filled)
    }
}
