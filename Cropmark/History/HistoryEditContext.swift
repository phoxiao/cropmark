import AppKit

/// 重新编辑一条历史截图时的摆放：图摆在屏幕正中，放不下就等比缩小显示。
///
/// 覆盖层的全部交互都是在「整屏视图坐标」里写的，所以这里造一张假的整屏截图（暗底 + 居中的历史图）
/// 喂给它，选区锁死在图的边界上。导出不走这张假图，而是回到底图坐标系按原始像素合成，
/// 缩小显示不会让成品变糊，换了倍率不同的屏幕编辑也一样。
struct HistoryEditContext {
    let entry: HistoryEntry
    /// 已经烧进马赛克的底图，原始像素
    let base: CGImage
    /// 图在目标屏幕上占的位置（视图坐标，点）
    let placement: CGRect
    /// 显示缩放：视图里的 1 点对应底图的 1/k 点。放得下就是 1
    let k: CGFloat
    let snapshot: ScreenSnapshot

    static let margin: CGFloat = 48
    static let backdrop = CGColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1)

    /// 底图坐标 → 视图坐标
    var toView: CGAffineTransform { CGAffineTransform(translationX: placement.minX, y: placement.minY).scaledBy(x: k, y: k) }
    var toBase: CGAffineTransform { toView.inverted() }

    /// 存档里的标注换算到视图坐标，好直接塞进覆盖层的标注列表
    var viewAnnotations: [Annotation] { entry.editAnnotations.applying(toView, styleScale: k) }

    /// 纯几何：在 screenSize（点）里给 pointSize 找位置。顶部让出菜单栏高度，四周留边，
    /// 落点吸附到目标屏幕的像素网格，免得边缘被插值成半透明的一条。
    static func place(pointSize: CGSize, in screenSize: CGSize, topInset: CGFloat, scale: CGFloat) -> (rect: CGRect, k: CGFloat) {
        let availW = max(screenSize.width - margin * 2, 1)
        let availH = max(screenSize.height - topInset - margin * 2, 1)
        let k = min(1, availW / pointSize.width, availH / pointSize.height)
        let snap = { (v: CGFloat) in (v * scale).rounded() / scale }
        let w = max(snap(pointSize.width * k), 1 / scale)
        let h = max(snap(pointSize.height * k), 1 / scale)
        let x = snap((screenSize.width - w) / 2)
        let y = snap(topInset + (screenSize.height - topInset - h) / 2)
        return (CGRect(x: x, y: y, width: w, height: h), k)
    }

    init?(entry: HistoryEntry, base: CGImage, screen: NSScreen) {
        let menuBar = max(screen.frame.maxY - screen.visibleFrame.maxY, 0)
        self.init(entry: entry, base: base, screen: screen, frame: screen.frame,
                  scale: screen.backingScaleFactor, topInset: menuBar)
    }

    init?(entry: HistoryEntry, base: CGImage, screen: NSScreen, frame: CGRect, scale: CGFloat, topInset: CGFloat) {
        let (rect, k) = Self.place(pointSize: entry.pointSize, in: frame.size, topInset: topInset, scale: scale)
        let w = Int((frame.width * scale).rounded()), h = Int((frame.height * scale).rounded())
        guard let ctx = Self.canvas(w, h) else { return nil }
        ctx.setFillColor(Self.backdrop)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(base, in: Self.pixelRect(rect, scale: scale, canvasHeight: h))
        guard let image = ctx.makeImage() else { return nil }
        self.entry = entry
        self.base = base
        self.placement = rect
        self.k = k
        self.snapshot = ScreenSnapshot(screen: screen, frame: frame, scale: scale, image: image)
    }

    /// 覆盖层预览马赛克用的整屏块化图：块化底图（块大小按底图像素算，和导出一致），贴到图所在的位置。
    func pixelatedCanvas(_ t: Thickness) -> CGImage? {
        guard let px = Mosaic.pixelate(base, blockPixels: Int(t.mosaicBlock * entry.scale)),
              let ctx = Self.canvas(snapshot.image.width, snapshot.image.height) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(px, in: Self.pixelRect(placement, scale: snapshot.scale, canvasHeight: snapshot.image.height))
        return ctx.makeImage()
    }

    /// 视图矩形（y 向下）→ CGContext 里的像素矩形（y 向上）
    private static func pixelRect(_ r: CGRect, scale: CGFloat, canvasHeight h: Int) -> CGRect {
        CGRect(x: r.minX * scale, y: CGFloat(h) - r.maxY * scale, width: r.width * scale, height: r.height * scale)
    }

    private static func canvas(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}
