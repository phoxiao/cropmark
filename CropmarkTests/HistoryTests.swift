import XCTest
import AppKit
@testable import Cropmark

/// 截图历史：落盘格式、存档的增删改与上限、马赛克烧进底图、覆盖层的入库与重新编辑。
@MainActor
final class HistoryTests: XCTestCase {
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private var dir: URL!
    private var limit = 5

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cropmark-history-\(UUID().uuidString)")
        limit = 5
    }
    override func tearDown() {
        stores.forEach { $0.flush() }   // 后台写盘排空再删目录，免得写到一半目录没了
        stores = []
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private var stores: [HistoryStore] = []
    private func makeStore() -> HistoryStore {
        let s = HistoryStore(directory: dir, limit: { [unowned self] in self.limit })
        stores.append(s)
        return s
    }

    /// w×h 像素，左半红、右半蓝
    private func image(_ w: Int = 400, _ h: Int = 300) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: sRGB, components: [1, 0, 0, 1])!); ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
        ctx.setFillColor(CGColor(colorSpace: sRGB, components: [0, 0, 1, 1])!); ctx.fill(CGRect(x: w / 2, y: 0, width: w - w / 2, height: h))
        return ctx.makeImage()!
    }

    private func pixel(_ img: CGImage, x: Int, y: Int) -> [Int] {
        let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let i = (y * img.width + x) * 4
        return [Int(p[i]), Int(p[i + 1]), Int(p[i + 2])]
    }

    private func archive(_ annotations: [Annotation] = [], replacing: UUID? = nil, base: CGImage? = nil) -> HistoryArchive {
        HistoryArchive(base: base ?? image(), scale: 1, annotations: annotations, replacing: replacing)
    }

    private let style = Style(color: Palette.colors[2], thickness: .thick)

    // MARK: 落盘格式

    func testStoredAnnotationRoundTripsEveryShape() throws {
        let shapes: [Annotation.Shape] = [
            .rect(CGRect(x: 1, y: 2, width: 30, height: 40)),
            .ellipse(CGRect(x: 5, y: 6, width: 7, height: 8)),
            .arrow(from: CGPoint(x: 1, y: 1), to: CGPoint(x: 50, y: 60)),
            .pen([CGPoint(x: 0, y: 0), CGPoint(x: 3, y: 4), CGPoint(x: 9, y: 2)]),
            .mosaic([CGPoint(x: 10, y: 10)]),
            .text("你好\nhi", origin: CGPoint(x: 12, y: 13), maxWidth: 140),
        ]
        let stored = shapes.map { StoredAnnotation(Annotation(shape: $0, style: style)) }
        let data = try JSONEncoder().encode(stored)
        let back = try JSONDecoder().decode([StoredAnnotation].self, from: data).map { try XCTUnwrap($0.annotation) }
        XCTAssertEqual(back.map(\.shape), shapes)
        for a in back { XCTAssertEqual(a.style, style, "颜色要还原成调色板里同一个颜色，工具栏才认得出选中的是哪个色块") }
    }

    func testCorruptStoredAnnotationIsDropped() {
        var s = StoredAnnotation(Annotation(shape: .rect(.zero), style: style))
        s.points = [.zero]
        XCTAssertNil(s.annotation)
        s = StoredAnnotation(Annotation(shape: .rect(.zero), style: style))
        s.thickness = 9
        XCTAssertNil(s.annotation)
    }

    // MARK: 存档

    func testRecordPersistsAndReloads() throws {
        let store = makeStore()
        let rect = Annotation(shape: .rect(CGRect(x: 10, y: 10, width: 50, height: 40)), style: style)
        let e = try XCTUnwrap(store.record(archive([rect]), final: image()))
        store.flush()
        XCTAssertEqual(store.entries.map(\.id), [e.id])

        let reopened = makeStore()
        XCTAssertEqual(reopened.entries, [e])
        XCTAssertEqual(reopened.base(for: e)?.width, 400)
        XCTAssertNotNil(reopened.final(for: e))
        XCTAssertNotNil(reopened.thumbnail(for: e))
        // 目录只给本人读写
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(e.id.uuidString).path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testLimitDropsOldestAndShrinkingPrunesImmediately() {
        let store = makeStore()
        var ids: [UUID] = []
        for i in 0..<7 {
            ids.append(store.record(archive(), final: image(), date: Date(timeIntervalSince1970: Double(i)))!.id)
        }
        XCTAssertEqual(store.entries.map(\.id), Array(ids.reversed().prefix(5)))
        limit = 2
        store.prune()
        store.flush()
        XCTAssertEqual(store.entries.map(\.id), [ids[6], ids[5]])
        let onDisk = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertEqual(Set(onDisk), Set([ids[6], ids[5]].map(\.uuidString)), "磁盘上的张数要和设置一致")
    }

    func testZeroLimitDisablesAndClearsHistory() {
        let store = makeStore()
        store.record(archive(), final: image())
        limit = 0
        store.prune()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(store.isEnabled)
        XCTAssertNil(store.record(archive(), final: image()))
    }

    func testReplacingKeepsIdAndMovesToFront() throws {
        let store = makeStore()
        let a = try XCTUnwrap(store.record(archive(), final: image(), date: Date(timeIntervalSince1970: 1)))
        let b = try XCTUnwrap(store.record(archive(), final: image(), date: Date(timeIntervalSince1970: 2)))
        XCTAssertEqual(store.entries.map(\.id), [b.id, a.id])
        let rect = Annotation(shape: .rect(CGRect(x: 0, y: 0, width: 9, height: 9)), style: style)
        store.record(archive([rect], replacing: a.id), final: image(), date: Date(timeIntervalSince1970: 3))
        XCTAssertEqual(store.entries.map(\.id), [a.id, b.id], "改过的那条挪到最前，不新增")
        XCTAssertEqual(store.entries[0].annotations.count, 1)
        store.flush()
        XCTAssertEqual(makeStore().entries.map(\.id), [a.id, b.id])
    }

    func testDeleteAndClear() throws {
        let store = makeStore()
        let a = try XCTUnwrap(store.record(archive(), final: image()))
        let b = try XCTUnwrap(store.record(archive(), final: image()))
        var changes = 0
        store.onChange = { changes += 1 }
        store.delete(a.id)
        XCTAssertEqual(store.entries.map(\.id), [b.id])
        store.clear()
        store.flush()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(changes, 2)
        XCTAssertTrue(makeStore().entries.isEmpty)
    }

    /// 打码的意图就是那块不该留下来：底图里马赛克已经烧进去，标注列表里没有它
    func testMosaicIsBakedIntoBase() throws {
        let store = makeStore()
        // 一条横穿红蓝分界的马赛克，块够大，分界处的块会被平均成紫色
        let mosaic = Annotation(shape: .mosaic([CGPoint(x: 150, y: 150), CGPoint(x: 250, y: 150)]),
                                style: Style(color: .black, thickness: .thick))
        let rect = Annotation(shape: .rect(CGRect(x: 10, y: 10, width: 40, height: 40)), style: style)
        let e = try XCTUnwrap(store.record(archive([mosaic, rect]), final: image()))
        XCTAssertEqual(e.annotations.map(\.kind), [.rect])
        store.flush()
        let base = try XCTUnwrap(makeStore().base(for: e))
        let original = image()
        var changed = false
        for x in stride(from: 190, through: 210, by: 1) where pixel(base, x: x, y: 150) != pixel(original, x: x, y: 150) { changed = true }
        XCTAssertTrue(changed, "马赛克区域的底图像素必须和原图不同")
        XCTAssertEqual(pixel(base, x: 20, y: 280), pixel(original, x: 20, y: 280), "马赛克以外不动")
    }

    // MARK: 摆放

    func testPlacementCentersAndShrinksToFit() {
        let fit = HistoryEditContext.place(pointSize: CGSize(width: 200, height: 100), in: CGSize(width: 1000, height: 800),
                                           topInset: 24, scale: 2)
        XCTAssertEqual(fit.k, 1)
        XCTAssertEqual(fit.rect, CGRect(x: 400, y: 362, width: 200, height: 100))

        let big = HistoryEditContext.place(pointSize: CGSize(width: 2000, height: 1000), in: CGSize(width: 1000, height: 800),
                                           topInset: 0, scale: 1)
        XCTAssertLessThan(big.k, 1)
        XCTAssertLessThanOrEqual(big.rect.width, 1000 - HistoryEditContext.margin * 2)
        XCTAssertEqual(big.rect.width / big.rect.height, 2, accuracy: 0.01)
    }

    // MARK: 覆盖层

    private func key(_ code: UInt16, chars: String, flags: NSEvent.ModifierFlags = [], in w: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: w.windowNumber,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }
    private func mouse(_ type: NSEvent.EventType, _ p: CGPoint, in w: NSWindow, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: p.x, y: w.frame.height - p.y), modifierFlags: [], timestamp: 0,
                           windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }
    private func drag(_ v: OverlayView, from a: CGPoint, to b: CGPoint, in w: NSWindow) {
        v.mouseDown(with: mouse(.leftMouseDown, a, in: w))
        v.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), in: w))
        v.mouseDragged(with: mouse(.leftMouseDragged, b, in: w))
        v.mouseUp(with: mouse(.leftMouseUp, b, in: w))
    }
    private func pasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("com.kivixiao.cropmark.tests.history"))
        pb.clearContents()
        return pb
    }
    private let noFile = ExportOptions(copyAt1x: false, saveAt1x: false, clipboardIncludesFile: false)

    /// 新截图入库：底图是选区那块、不带标注；标注换到以选区左上角为原点
    func testCaptureIsArchivedRelativeToSelection() throws {
        let store = makeStore()
        let snap = ScreenSnapshot(screen: NSScreen.screens[0], frame: CGRect(x: 0, y: 0, width: 400, height: 300), scale: 1, image: image())
        let session = CaptureSession(snapshots: [snap], windowList: [], elementDetection: .off) {}
        session.pasteboard = pasteboard()
        session.exportOptions = noFile
        session.history = store
        let window = session.makeWindows()[0]
        let view = window.overlayView
        drag(view, from: CGPoint(x: 100, y: 50), to: CGPoint(x: 300, y: 250), in: window)
        view.selectToolForTesting(.rect)
        drag(view, from: CGPoint(x: 150, y: 100), to: CGPoint(x: 250, y: 200), in: window)
        view.keyDown(with: key(36, chars: "\r", in: window))
        withExtendedLifetime(session) {}

        let e = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(e.pixelWidth, 200)
        XCTAssertEqual(e.pixelHeight, 200)
        XCTAssertEqual(e.annotations.first?.annotation?.shape, .rect(CGRect(x: 50, y: 50, width: 100, height: 100)))
        let base = try XCTUnwrap(store.base(for: e))
        XCTAssertEqual(pixel(base, x: 52, y: 100), [255, 0, 0], "底图不带标注")
        XCTAssertNotEqual(pixel(try XCTUnwrap(store.final(for: e)), x: 52, y: 100), [255, 0, 0], "成品带标注")
    }

    func testCancelledCaptureIsNotArchived() {
        let store = makeStore()
        let snap = ScreenSnapshot(screen: NSScreen.screens[0], frame: CGRect(x: 0, y: 0, width: 400, height: 300), scale: 1, image: image())
        let session = CaptureSession(snapshots: [snap], windowList: [], elementDetection: .off) {}
        session.history = store
        let window = session.makeWindows()[0]
        drag(window.overlayView, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 100, y: 100), in: window)
        window.overlayView.keyDown(with: key(53, chars: "\u{1b}", in: window))
        XCTAssertTrue(store.entries.isEmpty)
    }

    /// 编辑会话：图在屏幕正中、选区锁死、旧标注载入可改；Enter 覆盖原条目，成品按原始像素
    func testEditSessionLocksSelectionAndReplacesEntry() throws {
        let store = makeStore()
        let rect = Annotation(shape: .rect(CGRect(x: 20, y: 20, width: 60, height: 60)), style: style)
        // 200×100 点 @2x 的历史截图
        let entry = try XCTUnwrap(store.record(HistoryArchive(base: image(400, 200), scale: 2, annotations: [rect], replacing: nil),
                                               final: image(400, 200)))
        let other = try XCTUnwrap(store.record(archive(), final: image()))
        XCTAssertEqual(store.entries.first?.id, other.id)

        let ctx = try XCTUnwrap(HistoryEditContext(entry: entry, base: try XCTUnwrap(store.base(for: entry)),
                                                   screen: NSScreen.screens[0], frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                                                   scale: 1, topInset: 0))
        XCTAssertEqual(ctx.placement, CGRect(x: 200, y: 150, width: 200, height: 100))
        let pb = pasteboard()
        var finished = false
        let session = CaptureSession(snapshots: [ctx.snapshot], windowList: [], elementDetection: .off, editContext: ctx) { finished = true }
        session.pasteboard = pb
        session.exportOptions = noFile
        session.history = store
        let window = session.makeWindows()[0]
        let view = window.overlayView

        XCTAssertEqual(view.currentSelection, ctx.placement)
        XCTAssertTrue(view.isToolbarVisible)
        XCTAssertEqual(view.annotationsForTesting.map(\.shape), [.rect(CGRect(x: 220, y: 170, width: 60, height: 60))])
        XCTAssertFalse(view.isHistoryButtonVisible)

        // 在图外拖动不会新建选区，右键也不会清掉选区
        drag(view, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 150, y: 120), in: window)
        XCTAssertEqual(view.currentSelection, ctx.placement)
        view.rightMouseDown(with: mouse(.rightMouseDown, CGPoint(x: 300, y: 200), in: window))
        XCTAssertEqual(view.currentSelection, ctx.placement)
        XCTAssertEqual(view.annotationCount, 1)
        // 载入的标注不占撤销
        view.keyDown(with: key(6, chars: "z", flags: .command, in: window))
        XCTAssertEqual(view.annotationCount, 1)

        // 加一个箭头后完成
        view.selectToolForTesting(.arrow)
        drag(view, from: CGPoint(x: 300, y: 160), to: CGPoint(x: 380, y: 230), in: window)
        XCTAssertEqual(view.annotationCount, 2)
        view.keyDown(with: key(36, chars: "\r", in: window))
        XCTAssertTrue(finished)
        withExtendedLifetime(session) {}

        XCTAssertEqual(store.entries.map(\.id), [entry.id, other.id], "覆盖原条目并挪到最前")
        let updated = store.entries[0]
        XCTAssertEqual(updated.annotations.compactMap(\.annotation).map(\.shape), [
            .rect(CGRect(x: 20, y: 20, width: 60, height: 60)),
            .arrow(from: CGPoint(x: 100, y: 10), to: CGPoint(x: 180, y: 80)),
        ])
        let data = try XCTUnwrap(pb.data(forType: .png))
        let out = try XCTUnwrap(NSBitmapImageRep(data: data)?.cgImage)
        XCTAssertEqual(out.width, 400, "在 1x 屏幕上编辑 2x 截图，成品仍是原始像素")
        XCTAssertEqual(out.height, 200)
    }

    func testEscDiscardsEdit() throws {
        let store = makeStore()
        let entry = try XCTUnwrap(store.record(archive(), final: image(), date: Date(timeIntervalSince1970: 1)))
        let ctx = try XCTUnwrap(HistoryEditContext(entry: entry, base: image(), screen: NSScreen.screens[0],
                                                   frame: CGRect(x: 0, y: 0, width: 800, height: 600), scale: 1, topInset: 0))
        let session = CaptureSession(snapshots: [ctx.snapshot], windowList: [], elementDetection: .off, editContext: ctx) {}
        session.history = store
        let window = session.makeWindows()[0]
        window.overlayView.selectToolForTesting(.rect)
        drag(window.overlayView, from: CGPoint(x: 250, y: 200), to: CGPoint(x: 350, y: 300), in: window)
        window.overlayView.keyDown(with: key(53, chars: "\u{1b}", in: window))
        XCTAssertEqual(store.entries, [entry])
    }

    /// 右上角按钮：只在悬停阶段、光标在这块屏幕时出现；点下去收起覆盖层并转去历史面板
    func testHistoryButtonVisibilityAndAction() throws {
        let snap = ScreenSnapshot(screen: NSScreen.screens[0], frame: CGRect(x: 0, y: 0, width: 400, height: 300), scale: 1, image: image())
        var finished = false, opened = false
        let session = CaptureSession(snapshots: [snap], windowList: [], elementDetection: .off) { finished = true }
        session.onOpenHistory = { opened = true }
        let window = session.makeWindows()[0]
        let view = window.overlayView
        view.setPointerInsideForTesting(true)
        XCTAssertTrue(view.isHistoryButtonVisible)
        let frame = try XCTUnwrap(view.historyButtonFrame)
        XCTAssertEqual(frame.maxX, 400 - HistoryButton.inset)
        view.setPointerInsideForTesting(false)
        XCTAssertFalse(view.isHistoryButtonVisible)
        view.setPointerInsideForTesting(true)
        drag(view, from: CGPoint(x: 10, y: 100), to: CGPoint(x: 100, y: 200), in: window)
        XCTAssertFalse(view.isHistoryButtonVisible, "框出选区后藏起来")
        view.rightMouseDown(with: mouse(.rightMouseDown, CGPoint(x: 50, y: 150), in: window))
        XCTAssertTrue(view.isHistoryButtonVisible, "右键清掉选区又回到悬停阶段")

        session.openHistory()
        XCTAssertTrue(finished)
        XCTAssertTrue(opened)
    }

    func testHistoryButtonReplaysOnShowAndStopsOnHide() throws {
        let snap = ScreenSnapshot(screen: NSScreen.screens[0], frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                                  scale: 1, image: image(600, 400))
        let session = CaptureSession(snapshots: [snap], windowList: [], elementDetection: .off) {}
        session.onOpenHistory = {}
        let window = session.makeWindows()[0]
        window.alphaValue = 0
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        let view = window.overlayView
        let button = try XCTUnwrap(view.subviews.compactMap { $0 as? HistoryButton }.first)
        view.setPointerInsideForTesting(false)
        view.setPointerInsideForTesting(true)
        XCTAssertNotNil(button.layer?.animation(forKey: "historyButtonEntrance"))
        button.stopEntrance()
        view.refreshHistoryButton()
        XCTAssertNil(button.layer?.animation(forKey: "historyButtonEntrance"))
        view.setPointerInsideForTesting(false)
        view.setPointerInsideForTesting(true)
        XCTAssertNotNil(button.layer?.animation(forKey: "historyButtonEntrance"))
        view.setPointerInsideForTesting(false)
        XCTAssertNil(button.layer?.animation(forKey: "historyButtonEntrance"))
    }

    func testHistoryButtonReducedMotionUsesOnlyFade() {
        let button = HistoryButton(tooltip: "History") {}
        button.animateEntrance(reduceMotion: true)
        XCTAssertNotNil(button.layer?.animation(forKey: "historyButtonEntrance"))
        XCTAssertNil(button.layer?.animation(forKey: "historyButtonScale"))
        XCTAssertTrue(button.subviews.allSatisfy { $0.layer?.animationKeys()?.isEmpty ?? true })
    }

    func testNoHistoryButtonWhenDisabled() {
        let snap = ScreenSnapshot(screen: NSScreen.screens[0], frame: CGRect(x: 0, y: 0, width: 400, height: 300), scale: 1, image: image())
        let session = CaptureSession(snapshots: [snap], windowList: [], elementDetection: .off) {}
        let view = session.makeWindows()[0].overlayView
        view.setPointerInsideForTesting(true)
        XCTAssertFalse(view.isHistoryButtonVisible)
    }

    // MARK: 面板

    func testPanelKeysDeleteStaysOpenOthersClose() throws {
        let store = makeStore()
        let a = try XCTUnwrap(store.record(archive(), final: image(), date: Date(timeIntervalSince1970: 1)))
        let b = try XCTUnwrap(store.record(archive(), final: image(), date: Date(timeIntervalSince1970: 2)))
        let c = try XCTUnwrap(store.record(archive(), final: image(), date: Date(timeIntervalSince1970: 3)))
        let panel = HistoryPanelController(store: store)
        var actions: [(HistoryAction, UUID)] = []
        var closed = false
        panel.onAction = { actions.append(($0, $1.id)) }
        panel.onClose = { closed = true }
        let grid = panel.gridForTesting
        XCTAssertEqual(grid.entryIDsForTesting, [c.id, b.id, a.id])

        let w = panel.window
        grid.keyDown(with: key(124, chars: "", in: w))          // → 选第二张
        grid.keyDown(with: key(51, chars: "\u{7f}", in: w))     // Delete
        XCTAssertEqual(grid.entryIDsForTesting, [c.id, a.id])
        XCTAssertEqual(grid.selectedIndex, 1, "删完选中落到原位置的下一张")
        XCTAssertTrue(actions.isEmpty)

        grid.keyDown(with: key(8, chars: "c", flags: .command, in: w))
        XCTAssertEqual(actions.map(\.0), [.copy])
        XCTAssertEqual(actions.map(\.1), [a.id])
        XCTAssertFalse(closed, "主动操作由协调器接手焦点，不走被动关闭")
    }

    func testPanelEscClosesAndEnterEdits() throws {
        let store = makeStore()
        let a = try XCTUnwrap(store.record(archive(), final: image()))
        let panel = HistoryPanelController(store: store)
        var actions: [HistoryAction] = []
        var closed = false
        panel.onAction = { action, _ in actions.append(action) }
        panel.onClose = { closed = true }
        panel.gridForTesting.keyDown(with: key(36, chars: "\r", in: panel.window))
        XCTAssertEqual(actions, [.edit])
        _ = a

        let panel2 = HistoryPanelController(store: store)
        panel2.onClose = { closed = true }
        panel2.gridForTesting.keyDown(with: key(53, chars: "\u{1b}", in: panel2.window))
        XCTAssertTrue(closed)
    }

    func testGridFooterActsOnKeyboardSelectionAndDisablesWhenEmpty() throws {
        let store = makeStore()
        for i in 0..<5 {
            store.record(archive(), final: image(), date: Date(timeIntervalSince1970: Double(i)))
        }
        let panel = HistoryPanelController(store: store)
        let grid = panel.gridForTesting
        let ids = grid.entryIDsForTesting
        grid.keyDown(with: key(125, chars: "", in: panel.window))
        XCTAssertEqual(grid.selectedIndex, 3, "下移一行应跨过三张截图")
        grid.actionButtons[0].performClick(nil)
        XCTAssertFalse(grid.entryIDsForTesting.contains(ids[3]))
        XCTAssertEqual(grid.selectedIndex, 3)
        var copied: UUID?
        panel.onAction = { action, entry in
            XCTAssertEqual(action, .copy)
            copied = entry.id
        }
        grid.actionButtons[3].performClick(nil)
        XCTAssertEqual(copied, ids[4])

        let emptyPanel = HistoryPanelController(store: store)
        store.clear()
        XCTAssertTrue(emptyPanel.gridForTesting.actionButtons.allSatisfy { !$0.isEnabled })
        XCTAssertEqual(emptyPanel.gridForTesting.fittingSize.width, grid.fittingSize.width)
    }

    func testHistoryEntryButtonUsesFullLabeledHitArea() {
        var opened = false
        let entry = HistoryButton(tooltip: "History") { opened = true }
        let button = entry.subviews.compactMap { $0 as? NSButton }.first
        XCTAssertEqual(button?.title, L10n.t("截图历史"))
        XCTAssertGreaterThan(entry.frame.width, 80)
        button?.performClick(nil)
        XCTAssertTrue(opened)
    }

    func testEmptyPanelRenders() throws {
        let store = makeStore()
        let panel = HistoryPanelController(store: store)
        XCTAssertTrue(panel.gridForTesting.entryIDsForTesting.isEmpty)
        let content = try XCTUnwrap(panel.window.contentView)
        try savePreview(content, "preview-history-empty.png")
        for i in 0..<5 { store.record(archive(), final: image(), date: Date(timeIntervalSince1970: Double(i))) }
        try savePreview(try XCTUnwrap(panel.window.contentView), "preview-history-panel.png")
        XCTAssertEqual(panel.gridForTesting.entryIDsForTesting.count, 5, "面板开着时新增要跟着刷新")
    }

    // MARK: 渲染图，供人工检查

    /// 编辑界面和悬停阶段的右上角按钮各渲染一张，看摆放、暗底、工具栏是否正常
    func testRenderEditOverlayAndHistoryButton() throws {
        let store = makeStore()
        let rect = Annotation(shape: .rect(CGRect(x: 30, y: 30, width: 120, height: 80)), style: style)
        let text = Annotation(shape: .text("重新编辑", origin: CGPoint(x: 200, y: 60), maxWidth: 150), style: Style(color: Palette.colors[0], thickness: .medium))
        let entry = try XCTUnwrap(store.record(archive([rect, text]), final: image()))
        let ctx = try XCTUnwrap(HistoryEditContext(entry: entry, base: try XCTUnwrap(store.base(for: entry)), screen: NSScreen.screens[0],
                                                   frame: CGRect(x: 0, y: 0, width: 900, height: 600), scale: 1, topInset: 24))
        let session = CaptureSession(snapshots: [ctx.snapshot], windowList: [], elementDetection: .off, editContext: ctx) {}
        let window = session.makeWindows()[0]
        try savePreview(try XCTUnwrap(window.contentView), "preview-history-edit.png")

        let snap = ScreenSnapshot(screen: NSScreen.screens[0], frame: CGRect(x: 0, y: 0, width: 600, height: 400), scale: 1, image: image(600, 400))
        let s2 = CaptureSession(snapshots: [snap], windowList: [], elementDetection: .off) {}
        s2.onOpenHistory = {}
        let w2 = s2.makeWindows()[0]
        w2.overlayView.setPointerInsideForTesting(true)
        try savePreview(try XCTUnwrap(w2.contentView), "preview-history-button.png")
        withExtendedLifetime((session, s2)) {}
    }
}
