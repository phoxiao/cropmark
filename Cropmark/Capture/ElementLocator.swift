import CoreGraphics
import Dispatch

/// 窗口内部一个可被"自动识别"的块，frame 为 AppKit 坐标（y 向上）。
/// ancestors 是由内到外的逐级放大候选（不含 frame 自身），留给将来的"滚轮逐级放大"，本期不读。
struct LocatableElement: Equatable {
    let frame: CGRect
    let ancestors: [CGRect]

    init(frame: CGRect, ancestors: [CGRect] = []) {
        self.frame = frame
        self.ancestors = ancestors
    }
}

/// 在窗口内部做块级命中测试。真实实现看冻结截图的像素，测试注入假数据。
/// point 是 AppKit 屏幕坐标；返回 nil 表示没有值得用的结果，调用方退回整窗高亮。
protocol ElementLocating: AnyObject {
    func element(at point: CGPoint, within window: CGRect) -> LocatableElement?
}

/// 纯几何兜底：块矩形是否可信。**只管正确性，不管尺寸策略**——
/// 大小、形状、面积占比那些判据全在 BlockDetector.Config 一处，免得两边各持一份数字。
/// 这里只挡一种事故：算出来的矩形根本不在窗口里，那说明坐标换算写反了（y 翻转是重灾区）。
enum ElementGeometry {
    static func refine(window: CGRect, element: CGRect?) -> CGRect {
        guard let e = element, !e.isEmpty, !e.isNull,
              window.insetBy(dx: -1, dy: -1).contains(e)
        else { return window }
        return e
    }
}


/// 把块级识别挪出主线程，并做单飞和缓存。
///
/// 核心原则是 **识别永不阻塞第一次高亮**：调用方先同步画出窗口级高亮，这里的结果回来后再收紧。
/// 用户最差看到的是高亮在几毫秒后从整窗缩到对话框，不会有卡顿。
///
/// 节流方式是「同一时刻最多一个查询在飞」而不是固定间隔——识别得快就跟得紧，
/// 碰上难啃的区域就自动降频，不用拍脑袋定一个 debounce 时长。
@MainActor
final class HoverResolver {
    private let locator: ElementLocating
    /// 传 nil 则同步执行。单测靠它保持"合成事件 + 立即断言"的写法，不用改成 XCTestExpectation。
    private let queue: DispatchQueue?
    /// 只缓存正结果（确实收紧了的矩形）。缓存"整窗"会让光标之后移进对话框时也命中缓存，
    /// 那就永远发现不了对话框了。
    private var cache: (window: CGRect, rect: CGRect)?

    private var inFlight = false
    /// 在飞期间来的新请求只留最新的一条：中间那些点用户早已划过去了，算了也白算。
    private var pending: Query?
    /// 每来一个新请求就 +1。在飞的结果回来时若对不上号，说明光标早就移走了，只留缓存不上屏。
    ///
    /// 光看「有没有 pending」不够：命中缓存的请求会直接返回、根本不写 pending，
    /// 于是「悬停在对话框上 → 移到对话框外（发起查询）→ 移回对话框内（命中缓存）」这条路径里，
    /// 那条在飞的查询回来会把高亮改回整窗，而光标明明还在对话框上——单击采纳的就成了整窗。
    private var generation = 0

    private struct Query {
        let window: CGRect
        let point: CGPoint
        let completion: (CGRect) -> Void
    }

    init(locator: ElementLocating,
         queue: DispatchQueue? = DispatchQueue(label: "com.kivixiao.cropmark.hover", qos: .userInteractive)) {
        self.locator = locator
        self.queue = queue
    }

    func refine(window: CGRect, at point: CGPoint, completion: @escaping (CGRect) -> Void) {
        generation += 1
        let mine = generation
        let query = Query(window: window, point: point, completion: completion)
        if let c = cache, c.window == window, c.rect.contains(point) {
            completion(c.rect)
            return
        }
        guard let queue else {   // 同步路径（单测）
            deliver(query, element: locator.element(at: point, within: window), stale: false)
            return
        }
        guard !inFlight else { pending = query; return }
        inFlight = true
        let locator = self.locator
        queue.async {
            let element = locator.element(at: point, within: window)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inFlight = false
                let next = self.pending
                self.pending = nil
                self.deliver(query, element: element, stale: mine != self.generation)
                if let next {
                    self.refine(window: next.window, at: next.point, completion: next.completion)
                }
            }
        }
    }

    /// 调用方不再需要结果时（鼠标移出这块屏、进入旁观、已经有选区了）调一下。
    /// 否则晚到的结果会把已经清掉的高亮重新画回来，而且之后没有事件来再清一次。
    func invalidate() {
        generation += 1
        pending = nil
    }

    private func deliver(_ query: Query, element: LocatableElement?, stale: Bool) {
        let rect = ElementGeometry.refine(window: query.window, element: element?.frame)
        // 过期的结果照样进缓存：它对自己那个位置仍然是对的，白算一次太可惜
        if rect != query.window { cache = (query.window, rect) }
        guard !stale else { return }
        query.completion(rect)
    }
}
