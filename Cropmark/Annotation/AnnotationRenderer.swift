import AppKit

/// 把标注画到一个"y 向下、单位点"的 CGContext 上。覆盖层预览与最终导出共用。
struct AnnotationRenderer {
    /// 整屏尺寸（点），马赛克需要把块化底图铺满整屏再裁
    let screenSize: CGSize
    /// 取块化底图：参数为块边长（点）
    let pixelatedImage: (Thickness) -> CGImage?

    func draw(_ annotations: [Annotation], in ctx: CGContext) {
        for a in annotations { draw(a, in: ctx) }
    }

    func draw(_ a: Annotation, in ctx: CGContext) { draw(a.shape, style: a.style, in: ctx) }

    /// 单独吃 shape + style：正在画的预览还不是一条标注，不必先造个带 id 的对象。
    func draw(_ shape: Annotation.Shape, style s: Style, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch shape {
        case .rect(let r):
            ctx.setStrokeColor(s.color.cgColor)
            ctx.setLineWidth(s.thickness.lineWidth)
            ctx.stroke(r.insetBy(dx: s.thickness.lineWidth / 2, dy: s.thickness.lineWidth / 2))
        case .ellipse(let r):
            ctx.setStrokeColor(s.color.cgColor)
            ctx.setLineWidth(s.thickness.lineWidth)
            ctx.strokeEllipse(in: r.insetBy(dx: s.thickness.lineWidth / 2, dy: s.thickness.lineWidth / 2))
        case .arrow(let from, let to):
            let lw = s.thickness.lineWidth
            let g = ArrowGeometry.build(from: from, to: to, lineWidth: lw)
            ctx.setStrokeColor(s.color.cgColor)
            ctx.setFillColor(s.color.cgColor)
            ctx.setLineWidth(lw)
            ctx.move(to: from); ctx.addLine(to: g.shaftEnd); ctx.strokePath()
            ctx.move(to: g.head[0]); ctx.addLine(to: g.head[1]); ctx.addLine(to: g.head[2]); ctx.closePath(); ctx.fillPath()
        case .pen(let pts):
            guard let first = pts.first else { return }
            ctx.setStrokeColor(s.color.cgColor)
            ctx.setLineWidth(s.thickness.lineWidth)
            ctx.move(to: first)
            if pts.count == 1 { ctx.addLine(to: first) }
            for p in pts.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
        case .mosaic(let pts):
            guard let first = pts.first, let img = pixelatedImage(s.thickness) else { return }
            let path = CGMutablePath()
            path.move(to: first)
            if pts.count == 1 { path.addLine(to: first) }
            for p in pts.dropFirst() { path.addLine(to: p) }
            let brush = path.copy(strokingWithWidth: s.thickness.mosaicBrush, lineCap: .round, lineJoin: .round, miterLimit: 10)
            ctx.addPath(brush)
            ctx.clip()
            Self.drawImage(img, in: CGRect(origin: .zero, size: screenSize), ctx: ctx)
        case .text(let str, let origin, let maxWidth):
            let attr = Self.attributedText(str, style: s)
            let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = gc
            attr.draw(with: Self.textRect(attr, origin: origin, maxWidth: maxWidth), options: [.usesLineFragmentOrigin])
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// 绘制用：宽度固定为 maxWidth，折行位置才和测量时一致。
    static func textRect(_ attr: NSAttributedString, origin: CGPoint, maxWidth: CGFloat) -> CGRect {
        var r = textBounds(attr, origin: origin, maxWidth: maxWidth)
        r.size.width = max(maxWidth, 1)
        return r
    }

    /// 文字实际占据的矩形（折行后的紧凑宽高）。命中判定和选中框用它。
    /// 绘制仍走 textRect（宽度恒为 maxWidth），两者分开，折行结果才不会被动到——
    /// 拿 textRect 当命中框的话，一个 "hi" 会把右边几百点的空白也算成可点区域。
    static func textBounds(_ attr: NSAttributedString, origin: CGPoint, maxWidth: CGFloat) -> CGRect {
        let w = max(maxWidth, 1)
        let b = attr.boundingRect(with: CGSize(width: w, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
        return CGRect(origin: origin, size: CGSize(width: ceil(min(b.width, w)), height: ceil(b.height)))
    }

    static func attributedText(_ s: String, style: Style) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: style.thickness.fontSize, weight: .medium),
            .foregroundColor: style.color,
        ])
    }

    /// 在 y 向下的上下文里把图片"正着"画进 rect。
    static func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: rect.minY + rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: rect)
        ctx.restoreGState()
    }
}


extension AnnotationGeometry {
    /// 真正走 TextKit 的那一份。几何逻辑本身不依赖 AppKit，测试里换成 stub 即可。
    static func appKit() -> AnnotationGeometry {
        let cache = TextSizeCache()
        return AnnotationGeometry { cache.size($0, $1, $2) }
    }
}

/// 文字折行尺寸的记忆表。拖一条文字标注时，同一串字每帧要被量好几遍
/// （拖拽几何一次、选中框一次、渲染一次），而键在整次拖动里纹丝不动。
/// 颜色不影响尺寸，所以不进键——改个颜色不该让缓存失效。
/// 生命周期跟着一次截图会话，会话结束一起释放。
private final class TextSizeCache {
    private struct Key: Hashable {
        let text: String
        let fontSize: CGFloat
        let maxWidth: CGFloat
    }
    private var sizes: [Key: CGSize] = [:]

    func size(_ text: String, _ style: Style, _ maxWidth: CGFloat) -> CGSize {
        let key = Key(text: text, fontSize: style.thickness.fontSize, maxWidth: maxWidth)
        if let known = sizes[key] { return known }
        let measured = AnnotationRenderer.textBounds(AnnotationRenderer.attributedText(text, style: style),
                                                    origin: .zero, maxWidth: maxWidth).size
        sizes[key] = measured
        return measured
    }
}
