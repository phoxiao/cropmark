import AppKit

/// 把标注画到一个"y 向下、单位点"的 CGContext 上。覆盖层预览与最终导出共用。
struct AnnotationRenderer {
    /// 整屏尺寸（点），马赛克需要把块化底图铺满整屏再裁
    let screenSize: CGSize
    /// 取块化底图：参数为块边长（点）
    let pixelatedImage: (Thickness) -> CGImage?
    private let bakedMosaicImage: () -> CGImage?

    init(screenSize: CGSize, bakedMosaicImage: @escaping () -> CGImage? = { nil },
         pixelatedImage: @escaping (Thickness) -> CGImage?) {
        self.screenSize = screenSize
        self.bakedMosaicImage = bakedMosaicImage
        self.pixelatedImage = pixelatedImage
    }

    /// 导出必须检查返回值，打码失败时不能交付仍含原始像素的截图。
    @discardableResult
    func draw(_ annotations: [Annotation], in ctx: CGContext) -> Bool {
        annotations.allSatisfy {
            draw($0.shape, style: $0.style, in: ctx, bakedMosaic: $0.isBakedMosaic)
        }
    }

    /// 单独吃 shape + style：正在画的预览还不是一条标注，不必先造个带 id 的对象。
    @discardableResult
    func draw(_ shape: Annotation.Shape, style s: Style, in ctx: CGContext, bakedMosaic: Bool = false) -> Bool {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch shape {
        case .rect(let r):
            ctx.setStrokeColor(s.color.cgColor)
            ctx.setLineWidth(s.lineWidth)
            ctx.stroke(r.insetBy(dx: s.lineWidth / 2, dy: s.lineWidth / 2))
        case .ellipse(let r):
            ctx.setStrokeColor(s.color.cgColor)
            ctx.setLineWidth(s.lineWidth)
            ctx.strokeEllipse(in: r.insetBy(dx: s.lineWidth / 2, dy: s.lineWidth / 2))
        case .arrow(let from, let to):
            let g = ArrowGeometry.build(from: from, to: to, lineWidth: s.thickness.lineWidth, scale: s.viewScale)
            ctx.setStrokeColor(s.color.cgColor)
            ctx.setFillColor(s.color.cgColor)
            ctx.setLineWidth(s.lineWidth)
            ctx.move(to: from); ctx.addLine(to: g.shaftEnd); ctx.strokePath()
            ctx.move(to: g.head[0]); ctx.addLine(to: g.head[1]); ctx.addLine(to: g.head[2]); ctx.closePath(); ctx.fillPath()
        case .pen(let pts):
            guard let first = pts.first else { return true }
            ctx.setStrokeColor(s.color.cgColor)
            ctx.setLineWidth(s.lineWidth)
            ctx.move(to: first)
            if pts.count == 1 { ctx.addLine(to: first) }
            for p in pts.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
        case .mosaic(let pts):
            guard let first = pts.first,
                  let img = bakedMosaic ? bakedMosaicImage() : pixelatedImage(s.thickness) else { return false }
            if pts.contains(where: { $0 != first }) {
                let path = CGMutablePath()
                path.move(to: first)
                for p in pts.dropFirst() { path.addLine(to: p) }
                ctx.addPath(path.copy(strokingWithWidth: s.mosaicBrush, lineCap: .round, lineJoin: .round, miterLimit: 10))
            } else {
                let d = s.mosaicBrush
                ctx.addEllipse(in: CGRect(x: first.x - d / 2, y: first.y - d / 2, width: d, height: d))
            }
            // 遮挡范围内直接替换像素，避免边缘混入原图，也让重画遮挡时能复用同一张底图。
            ctx.setShouldAntialias(false)
            ctx.clip()
            ctx.setBlendMode(.copy)
            Self.drawImage(img, in: CGRect(origin: .zero, size: screenSize), ctx: ctx)
        case .text(let str, let origin, let maxWidth):
            // 按原字号折行，再缩放结果，避免小字号重新排版。
            let attr = Self.attributedText(str, style: s)
            ctx.translateBy(x: origin.x, y: origin.y)
            ctx.scaleBy(x: s.viewScale, y: s.viewScale)
            let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = gc
            attr.draw(with: Self.textRect(attr, origin: .zero, maxWidth: maxWidth / s.viewScale), options: [.usesLineFragmentOrigin])
            NSGraphicsContext.restoreGraphicsState()
        }
        return true
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
        let width = maxWidth / style.viewScale
        let key = Key(text: text, fontSize: style.thickness.fontSize, maxWidth: width)
        let measured: CGSize
        if let cached = sizes[key] {
            measured = cached
        } else {
            measured = AnnotationRenderer.textBounds(AnnotationRenderer.attributedText(text, style: style),
                                                     origin: .zero, maxWidth: width).size
            sizes[key] = measured
        }
        return CGSize(width: measured.width * style.viewScale, height: measured.height * style.viewScale)
    }
}
