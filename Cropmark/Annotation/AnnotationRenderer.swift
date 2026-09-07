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

    func draw(_ a: Annotation, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch a {
        case .rect(let r, let s):
            ctx.setStrokeColor(s.color.cgColor)
            ctx.setLineWidth(s.thickness.lineWidth)
            ctx.stroke(r.insetBy(dx: s.thickness.lineWidth / 2, dy: s.thickness.lineWidth / 2))
        case .ellipse(let r, let s):
            ctx.setStrokeColor(s.color.cgColor)
            ctx.setLineWidth(s.thickness.lineWidth)
            ctx.strokeEllipse(in: r.insetBy(dx: s.thickness.lineWidth / 2, dy: s.thickness.lineWidth / 2))
        case .arrow(let from, let to, let s):
            let lw = s.thickness.lineWidth
            let g = ArrowGeometry.build(from: from, to: to, lineWidth: lw)
            ctx.setStrokeColor(s.color.cgColor)
            ctx.setFillColor(s.color.cgColor)
            ctx.setLineWidth(lw)
            ctx.move(to: from); ctx.addLine(to: g.shaftEnd); ctx.strokePath()
            ctx.move(to: g.head[0]); ctx.addLine(to: g.head[1]); ctx.addLine(to: g.head[2]); ctx.closePath(); ctx.fillPath()
        case .pen(let pts, let s):
            guard let first = pts.first else { return }
            ctx.setStrokeColor(s.color.cgColor)
            ctx.setLineWidth(s.thickness.lineWidth)
            ctx.move(to: first)
            if pts.count == 1 { ctx.addLine(to: first) }
            for p in pts.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
        case .mosaic(let pts, let t):
            guard let first = pts.first, let img = pixelatedImage(t) else { return }
            let path = CGMutablePath()
            path.move(to: first)
            if pts.count == 1 { path.addLine(to: first) }
            for p in pts.dropFirst() { path.addLine(to: p) }
            let brush = path.copy(strokingWithWidth: t.mosaicBrush, lineCap: .round, lineJoin: .round, miterLimit: 10)
            ctx.addPath(brush)
            ctx.clip()
            Self.drawImage(img, in: CGRect(origin: .zero, size: screenSize), ctx: ctx)
        case .text(let str, let origin, let maxWidth, let s):
            let attr = Self.attributedText(str, style: s)
            let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = gc
            attr.draw(with: Self.textRect(attr, origin: origin, maxWidth: maxWidth), options: [.usesLineFragmentOrigin])
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// 文字在 maxWidth 内折行后占据的矩形。宽度固定为 maxWidth，保证绘制时的折行与测量一致。
    static func textRect(_ attr: NSAttributedString, origin: CGPoint, maxWidth: CGFloat) -> CGRect {
        let w = max(maxWidth, 1)
        let h = attr.boundingRect(with: CGSize(width: w, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height
        return CGRect(origin: origin, size: CGSize(width: w, height: ceil(h)))
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
