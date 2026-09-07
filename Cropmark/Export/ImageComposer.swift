import AppKit

/// 把冻结底图按选区裁剪，叠上标注，输出像素图。
enum ImageComposer {
    /// 视图坐标（点，y 向下）→ 像素矩形：四条边各自四舍五入到整数像素，再裁进图片范围。
    /// 不用 `.integral`（向外取整），否则 0.5 点的边会让导出图比屏幕上显示的尺寸多 1 像素。
    static func pixelRect(for viewRect: CGRect, scale: CGFloat, imageSize: CGSize) -> CGRect {
        let x0 = (viewRect.minX * scale).rounded(), y0 = (viewRect.minY * scale).rounded()
        let x1 = (viewRect.maxX * scale).rounded(), y1 = (viewRect.maxY * scale).rounded()
        let r = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        return r.intersection(CGRect(origin: .zero, size: imageSize))
    }

    static func compose(snapshot: ScreenSnapshot,
                        selection: CGRect,
                        annotations: [Annotation],
                        renderer: AnnotationRenderer) -> CGImage? {
        let base = snapshot.image
        let scale = snapshot.scale
        let px = pixelRect(for: selection, scale: scale, imageSize: CGSize(width: base.width, height: base.height))
        guard px.width >= 1, px.height >= 1 else { return nil }
        let w = Int(px.width), h = Int(px.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // 变成 y 向下、单位点、原点在选区左上角的坐标系
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -px.minX / scale, y: -px.minY / scale)

        let screenRect = CGRect(x: 0, y: 0, width: CGFloat(base.width) / scale, height: CGFloat(base.height) / scale)
        AnnotationRenderer.drawImage(base, in: screenRect, ctx: ctx)
        ctx.clip(to: CGRect(x: px.minX / scale, y: px.minY / scale, width: px.width / scale, height: px.height / scale))
        renderer.draw(annotations, in: ctx)
        return ctx.makeImage()
    }
}
