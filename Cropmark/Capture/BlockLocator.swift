import CoreGraphics

/// 把冻结截图接到块检测上：负责坐标换算和亮度图的一次性准备。
///
/// 亮度图按 step 降采样，代价换精度——2 的步长在 Retina 屏上等于按点采样，
/// 边界误差最多一两个点，肉眼看不出，而计算量少四分之三。
final class BlockLocator: ElementLocating {
    /// 屏幕在 AppKit 坐标下的位置，用来把屏幕点换算成图像像素
    private let screenFrame: CGRect
    /// 图像像素 / 点
    private let scale: CGFloat
    private let step: Int
    private let image: CGImage
    /// 第一次用到时才建：一次会话里大多数情况只需要建一次，建不出来就永远退回整窗
    private var buffer: LumaBuffer?
    private var bufferFailed = false

    /// 块的边长下限，单位是**点**。检测器那边用的是缓冲像素，换算在这里做——
    /// 这是唯一知道 scale 和 step 的地方，两边各写一个 40 会在非 Retina 屏上悄悄变成 80 点。
    private let minSidePoints: CGFloat

    init(image: CGImage, screenFrame: CGRect, scale: CGFloat, step: Int = 2,
         minSidePoints: CGFloat = 40) {
        self.image = image
        self.screenFrame = screenFrame
        self.scale = scale
        self.step = max(1, step)
        self.minSidePoints = minSidePoints
    }

    private var config: BlockDetector.Config {
        var c = BlockDetector.Config()
        c.minSide = max(4, Int((minSidePoints * scale / CGFloat(step)).rounded()))
        return c
    }

    func element(at point: CGPoint, within window: CGRect) -> LocatableElement? {
        guard let buffer = lumaBuffer() else { return nil }
        let clipped = window.intersection(screenFrame)
        guard !clipped.isNull else { return nil }
        let bounds = pixelRect(clipped, in: buffer)
        let p = pixelPoint(point)
        guard bounds.contains(p) else { return nil }
        guard let block = BlockDetector.rect(at: p, in: buffer, bounds: bounds, config: config) else { return nil }
        return LocatableElement(frame: appKitRect(block))
    }

    private func lumaBuffer() -> LumaBuffer? {
        if let buffer { return buffer }
        guard !bufferFailed else { return nil }
        guard let made = LumaBuffer.make(from: image, step: step) else { bufferFailed = true; return nil }
        buffer = made
        return made
    }

    // MARK: 坐标换算（AppKit 屏幕坐标 y 向上，图像缓冲 y 向下）

    private func pixelPoint(_ p: CGPoint) -> (x: Int, y: Int) {
        let f = scale / CGFloat(step)
        return (x: Int(((p.x - screenFrame.minX) * f).rounded()),
                y: Int(((screenFrame.maxY - p.y) * f).rounded()))
    }

    private func pixelRect(_ r: CGRect, in buffer: LumaBuffer) -> PixelRect {
        let a = pixelPoint(CGPoint(x: r.minX, y: r.maxY))   // 左上
        let b = pixelPoint(CGPoint(x: r.maxX, y: r.minY))   // 右下
        return PixelRect(x0: max(0, min(a.x, b.x)),
                         y0: max(0, min(a.y, b.y)),
                         x1: min(buffer.width - 1, max(a.x, b.x)),
                         y1: min(buffer.height - 1, max(a.y, b.y)))
    }

    private func appKitRect(_ r: PixelRect) -> CGRect {
        let f = CGFloat(step) / scale
        let x = screenFrame.minX + CGFloat(r.x0) * f
        let width = CGFloat(r.width) * f
        let height = CGFloat(r.height) * f
        let top = screenFrame.maxY - CGFloat(r.y0) * f
        return CGRect(x: x, y: top - height, width: width, height: height)
    }
}
