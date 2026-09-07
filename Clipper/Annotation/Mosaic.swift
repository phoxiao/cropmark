import CoreImage
import CoreGraphics

/// 像素块化（纯函数）。
enum Mosaic {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// 整图块化，输出尺寸与输入一致。blockPixels 为块边长（像素）。
    static func pixelate(_ image: CGImage, blockPixels: Int) -> CGImage? {
        let block = max(blockPixels, 1)
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(CGFloat(block), forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        guard let out = filter.outputImage?.clampedToExtent().cropped(to: input.extent) else { return nil }
        return ciContext.createCGImage(out, from: input.extent)
    }
}
