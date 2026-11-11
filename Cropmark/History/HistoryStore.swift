import AppKit

/// 一条历史截图的元数据。底图、成品图、缩略图是同目录下的三个 PNG。
/// 标注坐标相对底图左上角，单位是截图时那块屏幕的点（像素 ÷ scale）。
struct HistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    /// 最后一次产出的时间：新截的是截图时间，重新编辑过的是编辑完成的时间。排序只看它
    var date: Date
    let scale: CGFloat
    let pixelWidth: Int
    let pixelHeight: Int
    /// 不含马赛克：马赛克在存档时已经烧进底图
    var annotations: [StoredAnnotation]

    var pointSize: CGSize { CGSize(width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale) }
}

/// 标注的落盘格式。Annotation 本身带 NSColor、id 不可解码，不直接做 Codable。
struct StoredAnnotation: Codable, Equatable {
    enum Kind: String, Codable { case rect, ellipse, arrow, pen, mosaic, text }
    var kind: Kind
    /// rect / ellipse：左上、右下两点；arrow：起点、终点；pen / mosaic：轨迹；text：左上角
    var points: [CGPoint]
    var text: String?
    var maxWidth: CGFloat?
    /// sRGB 的 r g b a
    var color: [CGFloat]
    var thickness: Int

    init(_ a: Annotation) {
        let c = a.style.color.usingColorSpace(.sRGB) ?? a.style.color
        color = [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
        thickness = a.style.thickness.rawValue
        switch a.shape {
        case .rect(let r): kind = .rect; points = [r.origin, CGPoint(x: r.maxX, y: r.maxY)]
        case .ellipse(let r): kind = .ellipse; points = [r.origin, CGPoint(x: r.maxX, y: r.maxY)]
        case .arrow(let f, let t): kind = .arrow; points = [f, t]
        case .pen(let pts): kind = .pen; points = pts
        case .mosaic(let pts): kind = .mosaic; points = pts
        case .text(let s, let o, let w): kind = .text; points = [o]; text = s; maxWidth = w
        }
    }

    /// 文件被改坏（点数不够、粗细越界）时返回 nil，整条标注丢掉，不让一条坏数据拖垮整张图
    var annotation: Annotation? {
        guard color.count == 4, let t = Thickness(rawValue: thickness) else { return nil }
        let style = Style(color: NSColor(srgbRed: color[0], green: color[1], blue: color[2], alpha: color[3]), thickness: t)
        let shape: Annotation.Shape
        switch kind {
        case .rect, .ellipse:
            guard points.count == 2 else { return nil }
            let r = CGRect(x: points[0].x, y: points[0].y, width: points[1].x - points[0].x, height: points[1].y - points[0].y)
            shape = kind == .rect ? .rect(r) : .ellipse(r)
        case .arrow:
            guard points.count == 2 else { return nil }
            shape = .arrow(from: points[0], to: points[1])
        case .pen:
            guard !points.isEmpty else { return nil }
            shape = .pen(points)
        case .mosaic:
            guard !points.isEmpty else { return nil }
            shape = .mosaic(points)
        case .text:
            guard let o = points.first, let text, let maxWidth else { return nil }
            shape = .text(text, origin: o, maxWidth: maxWidth)
        }
        return Annotation(shape: shape, style: style)
    }
}

extension Annotation.Shape {
    /// 按「等比缩放 + 平移」换坐标系。t 必须是等比的（a == d、无旋转），宽度类的量只乘 t.a。
    func applying(_ t: CGAffineTransform) -> Self {
        switch self {
        case .rect(let r): return .rect(r.applying(t))
        case .ellipse(let r): return .ellipse(r.applying(t))
        case .arrow(let f, let to): return .arrow(from: f.applying(t), to: to.applying(t))
        case .pen(let pts): return .pen(pts.map { $0.applying(t) })
        case .mosaic(let pts): return .mosaic(pts.map { $0.applying(t) })
        case .text(let s, let o, let w): return .text(s, origin: o.applying(t), maxWidth: w * t.a)
        }
    }
}

extension Array where Element == Annotation {
    func applying(_ t: CGAffineTransform) -> [Annotation] {
        map { Annotation(shape: $0.shape.applying(t), style: $0.style) }
    }
}

/// 一次完成的截图交给历史的东西：不带标注的底图，加上相对底图的标注。
struct HistoryArchive {
    let base: CGImage
    let scale: CGFloat
    /// 相对底图左上角，单位点。可以含马赛克，入库时烧进底图
    let annotations: [Annotation]
    /// 重新编辑的那条；nil 表示新截图
    let replacing: UUID?
}

/// 在「底图坐标系」里合成：原点在底图左上角、y 向下、单位点。
enum HistoryComposer {
    static func compose(base: CGImage, scale: CGFloat, annotations: [Annotation]) -> CGImage? {
        let w = base.width, h = base.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.scaleBy(x: scale, y: scale)
        let size = CGSize(width: CGFloat(w) / scale, height: CGFloat(h) / scale)
        AnnotationRenderer.drawImage(base, in: CGRect(origin: .zero, size: size), ctx: ctx)
        var cache: [Thickness: CGImage] = [:]
        let renderer = AnnotationRenderer(screenSize: size) { t in
            if let c = cache[t] { return c }
            let img = Mosaic.pixelate(base, blockPixels: Int(t.mosaicBlock * scale))
            cache[t] = img
            return img
        }
        ctx.clip(to: CGRect(origin: .zero, size: size))
        renderer.draw(annotations, in: ctx)
        return ctx.makeImage()
    }

    /// 等比缩小到不超过 maxPixels 见方，用来做缩略图
    static func thumbnail(_ image: CGImage, maxPixels: CGSize) -> CGImage? {
        let k = min(1, maxPixels.width / CGFloat(image.width), maxPixels.height / CGFloat(image.height))
        let w = max(Int((CGFloat(image.width) * k).rounded()), 1), h = max(Int((CGFloat(image.height) * k).rounded()), 1)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

/// 最近几张截图的存档：`<目录>/<id>/` 下放 entry.json、base.png、final.png、thumb.png。
///
/// 写盘放在后台串行队列：一张 5K 截图编三次 PNG 要几百毫秒，放主线程会让 Enter 之后的
/// 焦点归还和粘贴都卡一下。还没写完的条目，图片先从内存里取，写完就释放。
/// 删除也走同一个队列，保证「刚写的又被删掉」不会因为先后颠倒留下孤儿目录。
@MainActor
final class HistoryStore {
    static let shared = HistoryStore(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cropmark/History", isDirectory: true),
        limit: { Preferences.historyLimit })

    static let thumbnailPixels = CGSize(width: 440, height: 280)

    let directory: URL
    private let limit: () -> Int
    /// 新的在前
    private(set) var entries: [HistoryEntry] = []
    private struct Images { let base: CGImage; let final: CGImage; let thumb: CGImage? }
    /// 还在排队写盘的条目
    private var pending: [UUID: Images] = [:]
    /// 每条写盘任务的序号：同一条连续改两次，先写完的那次不能把后一次的内存图释放掉
    private var pendingGeneration: [UUID: Int] = [:]
    private var generation = 0
    private let queue = DispatchQueue(label: "com.kivixiao.cropmark.history")
    /// 条目列表变了（新增、删除、清空）。历史面板开着时靠它刷新
    var onChange: (() -> Void)?

    init(directory: URL, limit: @escaping () -> Int) {
        self.directory = directory
        self.limit = limit
        entries = Self.load(from: directory)
        prune()
    }

    var isEnabled: Bool { limit() > 0 }

    // MARK: 读

    func base(for entry: HistoryEntry) -> CGImage? { pending[entry.id]?.base ?? Self.png(dir(entry.id).appendingPathComponent("base.png")) }
    func final(for entry: HistoryEntry) -> CGImage? { pending[entry.id]?.final ?? Self.png(dir(entry.id).appendingPathComponent("final.png")) }
    func thumbnail(for entry: HistoryEntry) -> CGImage? {
        if let p = pending[entry.id] { return p.thumb ?? p.final }
        return Self.png(dir(entry.id).appendingPathComponent("thumb.png")) ?? final(for: entry)
    }

    // MARK: 写

    /// 入库一张截图。final 是已经交给剪贴板的那张成品，原样存下来，「复制」时拿到的就是同一张。
    /// 马赛克在这里烧进底图：打码的意图就是那块不该留下来，磁盘上不能有一份清晰的原图。
    @discardableResult
    func record(_ archive: HistoryArchive, final: CGImage, date: Date = Date()) -> HistoryEntry? {
        guard isEnabled else { return nil }
        let mosaics = archive.annotations.filter(\.isMosaic)
        let base = mosaics.isEmpty ? archive.base
            : (HistoryComposer.compose(base: archive.base, scale: archive.scale, annotations: mosaics) ?? archive.base)
        let entry = HistoryEntry(id: archive.replacing ?? UUID(), date: date, scale: archive.scale,
                                 pixelWidth: base.width, pixelHeight: base.height,
                                 annotations: archive.annotations.filter { !$0.isMosaic }.map(StoredAnnotation.init))
        let thumb = HistoryComposer.thumbnail(final, maxPixels: Self.thumbnailPixels)
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)

        generation += 1
        let gen = generation
        pending[entry.id] = Images(base: base, final: final, thumb: thumb)
        pendingGeneration[entry.id] = gen
        let folder = dir(entry.id)
        queue.async { [weak self] in
            Self.write(entry, base: base, final: final, thumb: thumb, to: folder)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.pendingGeneration[entry.id] == gen else { return }
                    self.pending[entry.id] = nil
                    self.pendingGeneration[entry.id] = nil
                }
            }
        }
        prune()
        onChange?()
        return entry
    }

    func delete(_ id: UUID) {
        guard entries.contains(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        drop([id])
        onChange?()
    }

    func clear() {
        let ids = entries.map(\.id)
        entries.removeAll()
        drop(ids)
        // 顺手扫掉目录里认不出来的残留（比如写到一半被杀掉的那条）
        let folder = directory
        queue.async { try? FileManager.default.removeItem(at: folder) }
        onChange?()
    }

    /// 按当前上限删掉最旧的。设置里把数量调小时也调它，磁盘上的条数要立刻和设置一致
    func prune() {
        let keep = max(limit(), 0)
        guard entries.count > keep else { return }
        let extra = entries[keep...].map(\.id)
        entries.removeLast(entries.count - keep)
        drop(extra)
        onChange?()
    }

    /// 等后台写盘排空。测试用
    func flush() { queue.sync {} }

    // MARK: 内部

    private func dir(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }

    private func drop(_ ids: [UUID]) {
        for id in ids { pending[id] = nil; pendingGeneration[id] = nil }
        let folders = ids.map(dir)
        queue.async { for f in folders { try? FileManager.default.removeItem(at: f) } }
    }

    nonisolated private static func write(_ entry: HistoryEntry, base: CGImage, final: CGImage, thumb: CGImage?, to folder: URL) {
        let fm = FileManager.default
        do {
            // 截图里什么都可能有，目录只给本人读写
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.deletingLastPathComponent().path)
            if let d = Exporter.pngData(base) { try d.write(to: folder.appendingPathComponent("base.png"), options: .atomic) }
            if let d = Exporter.pngData(final) { try d.write(to: folder.appendingPathComponent("final.png"), options: .atomic) }
            if let thumb, let d = Exporter.pngData(thumb) { try d.write(to: folder.appendingPathComponent("thumb.png"), options: .atomic) }
            // entry.json 最后写：读的时候以它为准，图片没写全的条目不会被认出来
            let enc = JSONEncoder()
            try enc.encode(entry).write(to: folder.appendingPathComponent("entry.json"), options: .atomic)
        } catch {
            NSLog("history write failed: \(error)")
        }
    }

    private static func load(from directory: URL) -> [HistoryEntry] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        let dec = JSONDecoder()
        var out: [HistoryEntry] = []
        for d in dirs {
            guard let data = try? Data(contentsOf: d.appendingPathComponent("entry.json")),
                  let e = try? dec.decode(HistoryEntry.self, from: data),
                  e.id.uuidString == d.lastPathComponent,
                  fm.fileExists(atPath: d.appendingPathComponent("base.png").path) else {
                try? fm.removeItem(at: d)   // 写到一半或认不出来的目录，留着只会占空间
                continue
            }
            out.append(e)
        }
        return out.sorted { $0.date > $1.date }
    }

    private static func png(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
