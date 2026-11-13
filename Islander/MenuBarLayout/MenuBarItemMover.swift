import AppKit
import ApplicationServices
import Observation
import os

private let log = Logger(subsystem: "com.kadaliao.islander", category: "mover")

/// 在设置里调整菜单栏布局：替用户在菜单栏上"按住 ⌘ 拖动"图标（需要辅助功能权限）。
///
/// 系统没有移动其他 App 状态栏图标的接口，只能合成 ⌘ 拖动的鼠标事件。首选"定向事件"：
/// 按下、松开两个事件直接指名发给图标所在的窗口（窗口编号写在事件里），图标在不在屏幕上都行，
/// 不用露出隐藏的图标、不用拖光标，刘海也挡不住。图标窗口编号跟着图标走，移动后用窗口服务器的实时位置核对。
///
/// 定向事件没起作用、或者图标对不上窗口发不出去时，退回到合成一次真实的拖动：
/// 先把藏起来的图标露出来，按住图标拖到目标位置松手。
/// 拖动期间鼠标和光标暂时脱钩，结束后光标回到原位。实测规律（macOS 26.7）：
/// - 只对活动的那一行菜单栏有效，辅助功能报告的位置也只属于这一行；
/// - 刘海后面的图标抓不起来，落点在刘海后面结果不可控；刘海左边被挤压的图标拖了也没反应，
///   所以有刘海的屏幕上只在刘海右边拖；
/// - 向左拖时光标要进到目标左边缘内约 3pt 才算越过它，向右拖要进到右边缘内约 3pt；
///   落在两个邻居之间空隙的中点，两个方向都稳。
/// - 隐藏状态下分隔符有 10000pt 长，会打乱落点判断，所以移动前先临时把两条分隔符都缩回细线，
///   藏起来的、永远隐藏的图标全露出来。
@MainActor
@Observable
final class MenuBarItemMover {
    static let shared = MenuBarItemMover()

    enum Section: Sendable {
        /// 永远隐藏分隔符左边：菜单栏和岛上都不显示
        case alwaysHidden
        /// 两条分隔符之间：平时藏起来，显示在岛上
        case hidden
        /// 分隔符右边：留在菜单栏上
        case visible
    }

    struct Destination: Sendable {
        let section: Section
        /// 放在这个图标左边；nil 表示放在这一区的最右边
        let beforeID: String?
    }

    enum MoveError: LocalizedError {
        case noPermission
        case notFound
        case immovable
        /// 图标和窗口对不上（附带原因），定向事件发不出去；退回真实拖动也没成功时报给用户
        case unmapped(String)
        /// 辅助功能里读不到岛民自己的分隔符，分不出哪边是藏起来的
        case ownItemsMissing
        case blocked
        case didNotMove
        /// 辅助功能报的图标位置互相叠在一起，还是旧的：照着抓会拖走别的图标
        case stalePositions
        /// 拖动抓到的是别的图标（附带它的名字），再拖只会接着拖错
        case grabbedOther(String)

        var errorDescription: String? {
            switch self {
            case .noPermission:
                "需要辅助功能权限才能移动菜单栏图标。"
            case .notFound:
                "菜单栏上找不到这个图标了，可能它的 App 刚退出。"
            case .immovable:
                "这是系统固定的图标，不能移动。"
            case .unmapped(let reason):
                "没能移动这个图标：菜单栏上的图标和窗口对不上，改用拖动也没成功。\n详情：\(reason)"
            case .ownItemsMissing:
                "没能移动这个图标：岛民读不到自己放在菜单栏上的分隔符。"
            case .blocked, .didNotMove:
                "没能移动这个图标，请再试一次。"
            case .stalePositions:
                "没能移动这个图标：系统报告的图标位置还没更新，照着拖会拖错图标。请过几分钟再试。"
            case .grabbedOther(let name):
                "拖动时抓到的是「\(name)」，不是这个图标：系统报告的图标位置还没更新。已经停下，请看看「\(name)」现在在哪一排，过几分钟再试。"
            }
        }
    }

    /// 正在移动的图标
    private(set) var movingItemID: String?
    var isMoving: Bool { movingItemID != nil }
    /// 上一次移动失败的原因，界面显示用
    var lastError: String?
    /// 上一次移动每一步的经过，写进诊断信息
    private(set) var trail: [String] = []

    private init() {}

    private func note(_ step: String) {
        trail.append(step)
        log.notice("\(step, privacy: .public)")
    }

    /// 把图标移到指定位置。失败时把原因写进 `lastError`
    @discardableResult
    func move(_ itemID: String, to destination: Destination) async -> Bool {
        guard !isMoving else { return false }
        lastError = nil
        trail = ["移动 \(itemID) → \(destination.section)"]
        do {
            try await performMove(itemID, to: destination)
            HiddenItemsStore.shared.setAlwaysHidden(itemID, destination.section == .alwaysHidden)
            return true
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            trail.append("失败：\(error)")
            log.error("移动 \(itemID, privacy: .public) 失败：\(self.lastError ?? "", privacy: .public)")
            return false
        }
    }

    // MARK: - 流程

    private func performMove(_ itemID: String, to destination: Destination) async throws {
        guard AXIsProcessTrusted() else { throw MoveError.noPermission }

        movingItemID = itemID
        let store = HiddenItemsStore.shared
        store.isPaused = true
        // 事件发出时光标会短暂跳到图标那里，别让岛因此展开
        ScreenManager.shared.isSuspended = true
        defer {
            ScreenManager.shared.isSuspended = false
            store.isPaused = false
            // 辅助功能报告的位置要过一会儿才跟上，多刷新一次
            store.refresh(after: .milliseconds(400))
            store.refresh(after: .milliseconds(1500))
            movingItemID = nil
        }

        // 对照表建不起来时定向事件发不出去，但真实拖动用不着它，还有机会成功
        var unmapped: String?
        do {
            if try await moveWithTargetedEvents(itemID, to: destination) { return }
            note("定向事件没起作用，改用真实拖动")
        } catch MoveError.unmapped(let reason) {
            note("对不上窗口，改用真实拖动：\(reason)")
            unmapped = reason
        } catch MoveError.notFound {
            // 对照表建起来了、却没给这个图标认到窗口：拖动用不着窗口，还有机会成功
            note("窗口对照表里没有这个图标，改用真实拖动")
        }
        do {
            try await moveByDragging(itemID, to: destination)
        } catch let error as MoveError {
            note("真实拖动没成功：\(error)")
            // 两条路都没走通：报出对不上窗口的原因，才看得出卡在哪一环。不能动这类明确的原因照常报
            guard let unmapped else { throw error }
            switch error {
            case .blocked, .didNotMove, .notFound: throw MoveError.unmapped(unmapped)
            default: throw error
            }
        }
    }

    /// 扫描结果里每个图标的位置都对得上窗口服务器里的窗口（辅助功能报告的位置不是旧的）
    // MARK: - 定向事件

    /// 返回 false 表示事件没起作用（图标一动没动），交给真实拖动再试
    private func moveWithTargetedEvents(_ itemID: String, to destination: Destination) async throws -> Bool {
        var bar = try await windowBar()
        var moved = false
        for attempt in 1...3 {
            guard let source = bar.entry(itemID), let window = source.windowID else {
                note("定向第 \(attempt) 次：对照表里没有这个图标（窗口 \(bar.entries.count) 个）")
                throw MoveError.notFound
            }
            guard source.isMovable else { throw MoveError.immovable }
            let target = bar.neighbors(for: destination, moving: itemID)
            if bar.isPlaced(itemID, between: target) {
                log.notice("\(itemID, privacy: .public) 已在目标位置（第 \(attempt) 次）")
                return true
            }
            // 位置不完全对、但已经在正确的一侧，第三次就不再折腾
            if attempt == 3, moved, bar.section(of: itemID) == destination.section { return true }

            // 放在右邻居的左边；没有右邻居时放在左邻居的右边。点落在邻居窗口里靠边的位置
            let anchor: (point: CGPoint, window: CGWindowID)
            if let right = target.right, let id = right.windowID {
                anchor = (CGPoint(x: right.frame.minX + 2, y: right.frame.midY), id)
            } else if let left = target.left, let id = left.windowID {
                anchor = (CGPoint(x: left.frame.maxX - 2, y: left.frame.midY), id)
            } else {
                return false
            }

            log.notice("""
                定向移动 \(itemID, privacy: .public) → \(target.left?.id ?? "-", privacy: .public) | \
                \(target.right?.id ?? "-", privacy: .public)（第 \(attempt) 次）
                """)
            trail.append("定向第 \(attempt) 次：图标 \(MoveDiagnostics.brief(source.frame)) → x=\(Int(anchor.point.x))")
            NSCursor.hide()
            await Self.postTargetedMove(window: window, pid: source.ownerPID, start: source.frame.center,
                                        end: anchor.point, endWindow: anchor.window)
            NSCursor.unhide()
            let after = await bar.refreshed(waitingForMoveOf: window)
            if after.entry(itemID)?.frame != source.frame { moved = true }
            bar = after
        }
        if bar.section(of: itemID) == destination.section, moved { return true }
        if moved {
            note("定向事件让图标动了，但没到目标那一区")
            throw MoveError.didNotMove
        }
        return false
    }

    /// 当前活动那一行菜单栏的图标窗口，每个窗口标上它是哪个图标。
    /// 辅助功能报告的位置偶尔是旧的，对不上窗口时等一下重扫，绝不猜：认错了就会拖走别的图标。
    /// 一直对不上就抛出 `.unmapped`，带上最后一次对不上的原因
    private func windowBar() async throws -> MenuBarSnapshot {
        let own = MenuBarScanner.AppInfo(NSRunningApplication.current)
        var reason = ""
        for _ in 0..<12 {
            let result = await HiddenItemsStore.shared.scanner.scan(adding: [], own: own, isFull: false)
            do {
                return try MenuBarSnapshot(mapping: result, knownWindows: HiddenItemsStore.shared.itemWindows)
            } catch {
                reason = "\(error)"
            }
            // 窗口服务器里根本没有图标窗口（macOS 27）：再等也对不上，直接交给真实拖动
            if result.rows.windows.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(150))
        }
        throw MoveError.unmapped(reason)
    }

    private nonisolated static func postTargetedMove(window: CGWindowID, pid: pid_t, start: CGPoint,
                                                      end: CGPoint, endWindow: CGWindowID) async {
        await withCheckedContinuation { continuation in
            eventQueue.async {
                postTargeted(window: window, pid: pid, start: start, end: end, endWindow: endWindow)
                continuation.resume()
            }
        }
    }

    private nonisolated static func postTargeted(window: CGWindowID, pid: pid_t, start: CGPoint,
                                                  end: CGPoint, endWindow: CGWindowID) {
        let source = CGEventSource(stateID: .hidSystemState)
        let saved = CGEvent(source: nil)?.location
        CGAssociateMouseAndMouseCursorPosition(0)
        defer {
            if let saved { CGWarpMouseCursorPosition(saved) }
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        func event(_ type: CGEventType, at point: CGPoint, in window: CGWindowID) -> CGEvent? {
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.flags = .maskCommand
            event?.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
            event?.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window))
            event?.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window))
            // 0x33 是事件里的窗口编号字段（没有公开名字）
            if let field = CGEventField(rawValue: 0x33) { event?.setIntegerValueField(field, value: Int64(window)) }
            return event
        }
        event(.leftMouseDown, at: start, in: window)?.post(tap: .cgSessionEventTap)
        usleep(80_000)
        event(.leftMouseUp, at: end, in: endWindow)?.post(tap: .cgSessionEventTap)
        usleep(60_000)
    }

    // MARK: - 退路：真实拖动

    private func moveByDragging(_ itemID: String, to destination: Destination) async throws {
        let hider = MenuBarHider.shared
        hider.beginTemporaryReveal(includingAlwaysHidden: true)
        defer { hider.endTemporaryReveal() }

        var bar = try await settledBar()
        var moved = false
        for attempt in 1...3 {
            guard let source = bar.entry(itemID) else {
                note("拖动第 \(attempt) 次：扫描结果里没有这个图标（共 \(bar.entries.count) 个）")
                throw MoveError.notFound
            }
            guard source.isMovable else { throw MoveError.immovable }
            let target = bar.neighbors(for: destination, moving: itemID)
            if bar.isPlaced(itemID, between: target) {
                log.notice("\(itemID, privacy: .public) 已在目标位置（第 \(attempt) 次）")
                return
            }
            // 位置不完全对、但已经在正确的一侧，第三次就不再折腾
            if attempt == 3, bar.section(of: itemID) == destination.section { return }

            let row = RowGeometry(containing: source.frame)
            guard let start = row.grabPoint(for: source.frame),
                  let end = row.dropPoint(between: target, from: source.frame)
            else {
                // 已经拖进了正确的一侧、只是落到刘海后面抓不起来了：图标确实动了，算成功，不报「没能移动」
                if moved, bar.section(of: itemID) == destination.section {
                    log.notice("\(itemID, privacy: .public) 已在正确的一侧，落点在刘海附近、没法再调（第 \(attempt) 次）")
                    return
                }
                note("""
                    拖动第 \(attempt) 次拖不到：图标 \(MoveDiagnostics.brief(source.frame))，\
                    目标 \(target.left.map { MoveDiagnostics.brief($0.frame) } ?? "-") | \
                    \(target.right.map { MoveDiagnostics.brief($0.frame) } ?? "-")，\
                    屏幕 \(MoveDiagnostics.brief(row.screen)) 刘海 \(row.notch.map { "\(Int($0.lowerBound))…\(Int($0.upperBound))" } ?? "无")
                    """)
                throw MoveError.blocked
            }

            log.notice("""
                拖动 \(itemID, privacy: .public) → \(target.left?.id ?? "-", privacy: .public) | \
                \(target.right?.id ?? "-", privacy: .public)，\(Int(start.x)) → \(Int(end.x))（第 \(attempt) 次）
                """)
            trail.append("拖动第 \(attempt) 次：\(Int(start.x)) → \(Int(end.x))，图标 \(MoveDiagnostics.brief(source.frame))")
            let windowBefore = source.windowID.flatMap(Self.windowFrame)
            await Self.drag(from: start, to: end)
            let before = bar
            bar = try await barAfterDrag(of: source, windowBefore: windowBefore)
            if bar.entry(itemID)?.frame != source.frame {
                moved = true
            } else if let other = bar.farthestMoved(since: before, excluding: itemID, beyond: 80) {
                // 这个图标没动，别的图标却挪了老远：抓的地方其实是别的图标（位置是旧的）。
                // 再拖还是抓在同一个地方，只会接着拖错，停下
                note("""
                    拖动第 \(attempt) 次抓到了别的图标：\(other) \
                    \(before.entry(other).map { MoveDiagnostics.brief($0.frame) } ?? "-") → \
                    \(bar.entry(other).map { MoveDiagnostics.brief($0.frame) } ?? "-")
                    """)
                throw MoveError.grabbedOther(Self.displayName(of: other))
            }
        }
        guard bar.section(of: itemID) == destination.section else {
            note("拖了 3 次，图标\(moved ? "动过但没到目标那一区" : "一动没动")，现在 \(bar.entry(itemID).map { MoveDiagnostics.brief($0.frame) } ?? "不见了")")
            throw MoveError.didNotMove
        }
    }

    /// 拖完之后的菜单栏。辅助功能报告的位置比窗口服务器晚到，拿旧位置判断会以为没拖动、再拖一次，
    /// 而那个位置上已经换成别的图标了。所以先看窗口（实时的）有没有动，动了再等辅助功能的位置跟上
    private func barAfterDrag(of source: MenuBarSnapshot.Entry, windowBefore: CGRect?) async throws -> MenuBarSnapshot {
        if let id = source.windowID, let windowBefore {
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(80))
                if let now = Self.windowFrame(id), now != windowBefore { break }
            }
        } else {
            try? await Task.sleep(for: .milliseconds(350))
        }
        return try await settledBar()
    }

    private nonisolated static func windowFrame(_ id: CGWindowID) -> CGRect? {
        StatusBarRows.current().windows.first { $0.id == id }?.frame
    }

    /// 报错时给人看的图标名字
    private static func displayName(of id: String) -> String {
        if id.hasPrefix("islander|") { return "岛民自己的图标" }
        return HiddenItemsStore.shared.allItems.first { $0.id == id }?.source.displayName ?? id
    }

    /// 露出隐藏的图标后等菜单栏排好：两条分隔符都变回细线、所有图标都回到屏幕附近、
    /// 每个图标报告的位置都落在一个图标窗口里，并且连续两次扫描位置一致。
    /// 辅助功能先报告分隔符的新宽度，图标的新位置要晚一些才到，只看宽度会拿到还在屏幕外的旧位置
    private func settledBar() async throws -> MenuBarSnapshot {
        var previous: MenuBarSnapshot?
        for _ in 0..<30 {
            let bar = try await scanBar()
            if bar.isLaidOut, let previous, previous.frames == bar.frames { return bar }
            previous = bar
            try? await Task.sleep(for: .milliseconds(100))
        }
        let bar = try await scanBar()
        // 图标还叠在一起：位置是旧的，照着抓会拖走别的图标。macOS 27 上连续移动后会这样，
        // 两次扫描一模一样、几分钟后才自己恢复，等不到，宁可不拖（issue #1）
        if case let (a, b)? = bar.overlap {
            note("""
                辅助功能报的位置叠在一起：\(a) \(bar.entry(a).map { MoveDiagnostics.brief($0.frame) } ?? "-") 和 \
                \(b) \(bar.entry(b).map { MoveDiagnostics.brief($0.frame) } ?? "-")，不拖
                """)
            throw MoveError.stalePositions
        }
        return bar
    }

    private func scanBar() async throws -> MenuBarSnapshot {
        let own = MenuBarScanner.AppInfo(NSRunningApplication.current)
        let result = await HiddenItemsStore.shared.scanner.scan(adding: [], own: own, isFull: false)
        guard let separator = result.separator else {
            note("辅助功能里读不到岛民的分隔符（开关\(result.toggle == nil ? "也读不到" : "读得到")，图标 \(result.items.count) 个）")
            throw MoveError.ownItemsMissing
        }
        if result.ownFramesFromAppKit {
            let step = "辅助功能里读不到岛民的分隔符，改用 AppKit 报告的位置：\(MoveDiagnostics.brief(separator))"
            if !trail.contains(step) { note(step) }
        }
        return MenuBarSnapshot(items: result.items, separator: separator, alwaysHiddenSeparator: result.alwaysHiddenSeparator,
                   toggle: result.toggle, hasItemWindows: !result.rows.windows.isEmpty)
    }

    // MARK: - 合成 ⌘ 拖动

    private nonisolated static let eventQueue = DispatchQueue(label: "com.kadaliao.islander.mover", qos: .userInteractive)

    /// 在专用线程上发事件：中间要等十几次，不占 Swift 并发的线程池
    private nonisolated static func drag(from start: CGPoint, to end: CGPoint) async {
        await withCheckedContinuation { continuation in
            eventQueue.async {
                postDrag(from: start, to: end)
                continuation.resume()
            }
        }
    }

    private nonisolated static func postDrag(from start: CGPoint, to end: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        let saved = CGEvent(source: nil)?.location
        // 拖动期间用户动鼠标不会干扰
        CGAssociateMouseAndMouseCursorPosition(0)
        defer {
            if let saved { CGWarpMouseCursorPosition(saved) }
            CGAssociateMouseAndMouseCursorPosition(1)
        }

        func wait(_ milliseconds: UInt32) { usleep(milliseconds * 1000) }
        func mouse(_ type: CGEventType, _ point: CGPoint) {
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
        func command(down: Bool) {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: down)
            event?.flags = down ? .maskCommand : []
            event?.post(tap: .cghidEventTap)
        }

        command(down: true)
        defer { command(down: false) }
        wait(20)
        mouse(.mouseMoved, start)
        wait(30)
        mouse(.leftMouseDown, start)
        wait(60)
        // 一步 5pt：太快的话菜单栏跟不上，落点会错一位
        let steps = max(Int(abs(end.x - start.x) / 5), 8)
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            mouse(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
            wait(8)
        }
        // 让其他图标滑到位后在原地再报一次位置，菜单栏按排好后的位置判断落点
        wait(120)
        mouse(.leftMouseDragged, end)
        wait(180)
        mouse(.leftMouseUp, end)
        wait(40)
    }
}

// MARK: - 菜单栏快照

extension MenuBarItem {
    /// 系统固定的图标：时钟、控制中心，以及用麦克风 / 摄像头时出现的隐私指示
    var isMovable: Bool {
        !["com.apple.controlcenter|com.apple.menuextra.clock",
          "com.apple.controlcenter|com.apple.menuextra.controlcenter",
          "com.apple.controlcenter|com.apple.menuextra.audiovideo"].contains(id)
    }
}

/// 活动那一行菜单栏上的所有图标（含岛民自己的分隔符和开关），从左到右
struct MenuBarSnapshot {
    struct Entry {
        let id: String
        let frame: CGRect
        let isMovable: Bool
        /// 图标所在的窗口
        var windowID: CGWindowID? = nil
        /// 窗口的所属进程（macOS 26 上都是 Control Center），定向事件发给它
        var ownerPID: pid_t = 0
    }

    static let separatorID = "islander|separator"
    static let alwaysHiddenSeparatorID = "islander|always-hidden-separator"
    static let toggleID = "islander|toggle"
    static let collectorID = "islander|collector"

    let entries: [Entry]
    let separator: CGRect
    let alwaysHiddenSeparator: CGRect?
    private let itemCount: Int
    /// 窗口服务器里有没有图标窗口：macOS 27 上没有，排没排好就不能拿窗口核对
    private var hasItemWindows = true
    /// 没有图标窗口可核对时，叠在一起的两个第三方图标：说明辅助功能报的位置是旧的
    private(set) var overlap: (String, String)?
    /// 按窗口建的快照：这一行菜单栏的顶边，以及每个窗口是哪个图标
    private var rowTop: CGFloat?
    private var labels: [CGWindowID: (id: String, isMovable: Bool)] = [:]

    /// 按窗口服务器的窗口链建快照（实时、准确），再给每个窗口标上是哪个图标。
    ///
    /// 图标的窗口编号跟着图标走，`knownWindows` 里记着的直接认。岛民自己的三个窗口按窗口标题认。
    /// 其他没记过的按辅助功能报告的位置认，但屏幕外的图标位置整体偏了一截（每次扫描偏得还不一样），
    /// 好在同一次扫描里偏移是一致的：用它右边最近的岛民窗口量出偏移，校正后差几 pt 以内才算对上。
    /// 对不上就抛出原因，绝不猜：认错了就会拖走别的图标
    init(mapping result: MenuBarScanner.Result, knownWindows: [String: CGWindowID] = [:]) throws(MappingFailure) {
        guard let separatorAX = result.separator, let toggleAX = result.toggle else {
            throw MappingFailure("辅助功能里找不到岛民的\(result.separator == nil ? "分隔符" : "开关")")
        }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let tops = NSScreen.screens.map { primaryTop - $0.frame.maxY }
        guard let top = tops.filter({ $0 <= separatorAX.midY }).max() else {
            throw MappingFailure("分隔符不在任何屏幕的菜单栏上（y=\(Int(separatorAX.midY))）")
        }
        let chain = result.rows.chain(top: top)
        guard !chain.isEmpty else { throw MappingFailure("窗口服务器里 y=\(Int(top)) 这一行没有图标窗口") }
        let inChain = Set(chain.map(\.id))
        var labels: [CGWindowID: (id: String, isMovable: Bool)] = [:]

        // 岛民自己的窗口：记着的 → 标题 → 宽度和位置
        var anchors: [(id: String, ax: CGRect, window: StatusBarRows.Window)] = []
        let own: [(id: String, name: String, ax: CGRect?)] = [
            (Self.alwaysHiddenSeparatorID, "IslanderAlwaysHiddenSeparator", result.alwaysHiddenSeparator),
            (Self.separatorID, "IslanderSeparator", separatorAX),
            (Self.toggleID, "IslanderToggle", toggleAX),
            (Self.collectorID, "IslanderCollector", result.collector),
        ]
        // 伸长的窗口从左到右：永远隐藏分隔符、分隔符、收纳符（"显示全部图标"时才有）
        var wide = chain.filter { $0.frame.width > 1000 }
        let wideCollector = (result.collector?.width ?? 0) > 1000 ? wide.popLast() : nil
        for (id, name, ax) in own {
            guard let ax else { continue }
            let window: StatusBarRows.Window? = {
                if let known = knownWindows[id], inChain.contains(known) { return chain.first { $0.id == known } }
                if let named = chain.first(where: { $0.name == name }) { return named }
                // 没有屏幕录制权限读不到标题：伸长的分隔符是链上最宽的两个窗口，左边那个是永远隐藏分隔符
                if ax.width > 1000 {
                    if id == Self.collectorID { return wideCollector }
                    if id == Self.separatorID { return wide.last }
                    if id == Self.alwaysHiddenSeparatorID, wide.count > 1 { return wide.first }
                }
                return chain.filter { abs($0.frame.minX - (ax.minX - 7)) < 8 && labels[$0.id] == nil }
                    .min { abs($0.frame.minX - ax.minX + 7) < abs($1.frame.minX - ax.minX + 7) }
            }()
            guard let window, labels[window.id] == nil else {
                if id == Self.alwaysHiddenSeparatorID || id == Self.collectorID { continue }
                let found = window.flatMap { labels[$0.id] }.map { "窗口已认给 \($0.id)" } ?? "链上没有对得上的窗口"
                let names = chain.contains { $0.name != nil } ? "" : "，读不到窗口标题（没有屏幕录制权限？）"
                throw MappingFailure("认不出 \(id) 的窗口：\(found)，辅助功能 x=\(Int(ax.minX)) 宽 \(Int(ax.width))\(names)")
            }
            labels[window.id] = (id, false)
            anchors.append((id, ax, window))
        }

        // 其他图标：记着的直接认
        var pending: [MenuBarItem] = []
        for item in result.items {
            if let known = knownWindows[item.id], inChain.contains(known), labels[known] == nil {
                labels[known] = (item.id, item.isMovable)
            } else {
                pending.append(item)
            }
        }
        // 没记过的：按右边最近的岛民窗口校正位置。锚点要按位置排：收纳符在开关左边，却是最后认的，
        // 不排的话收纳符左边那些被挤出屏幕的图标会拿屏幕上的开关量偏移，开关右边的时钟反而拿收纳符量
        anchors.sort { $0.ax.minX < $1.ax.minX }
        // Control Center 偶尔会额外挂一个和别人窗口重合的元素（没有标识，序号每台机器不一样），
        // 排在最后、对不上也不要紧
        let controlCenter = "com.apple.controlcenter"
        pending.sort { ($0.bundleID == controlCenter ? 1 : 0) < ($1.bundleID == controlCenter ? 1 : 0) }
        for item in pending {
            let anchor = anchors.first { $0.ax.minX > item.frame.minX } ?? anchors.last
            let offset = anchor.map { $0.window.frame.minX - $0.ax.minX } ?? -7
            let expected = item.frame.minX + offset
            let free = chain.filter { labels[$0.id] == nil }
            let nearest = free.min { abs($0.frame.minX - expected) < abs($1.frame.minX - expected) }
            if let nearest, abs(nearest.frame.minX - expected) <= 12 {
                labels[nearest.id] = (item.id, item.isMovable)
            } else if item.bundleID != controlCenter || !item.id.hasPrefix("\(controlCenter)|#") {
                throw MappingFailure("""
                    \(item.displayName)（\(item.id)）对不上窗口：辅助功能 x=\(Int(item.frame.minX)) 宽 \(Int(item.frame.width))，\
                    按 \(anchor?.id ?? "默认") 校正 \(Int(offset)) 后应在 x=\(Int(expected))，\
                    最近的空窗口\(nearest.map { " x=\(Int($0.frame.minX)) 宽 \(Int($0.frame.width))" } ?? "：没有")
                    """)
            }
        }
        self.init(chain: chain, labels: labels, rowTop: top)
    }

    /// 对不上窗口的原因：哪一步、哪个图标、位置差多少。写进日志和界面提示，方便定位卡在哪一环
    struct MappingFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private init(chain: [StatusBarRows.Window], labels: [CGWindowID: (id: String, isMovable: Bool)], rowTop: CGFloat) {
        entries = chain.map { window in
            let label = labels[window.id]
            return Entry(id: label?.id ?? "window|\(window.id)", frame: window.frame, isMovable: label?.isMovable ?? true,
                         windowID: window.id, ownerPID: window.ownerPID)
        }
        separator = entries.first { $0.id == Self.separatorID }?.frame ?? .null
        alwaysHiddenSeparator = entries.first { $0.id == Self.alwaysHiddenSeparatorID }?.frame
        itemCount = entries.count
        self.rowTop = rowTop
        self.labels = labels
    }

    /// 发出移动事件之后的快照：先等这个窗口挪了位置（最多约 1 秒），再等窗口链重新连成一整条
    /// （图标滑到新位置的途中，相邻窗口会短暂对不上，链会断成两截）并且连续两次一样
    func refreshed(waitingForMoveOf window: CGWindowID) async -> MenuBarSnapshot {
        guard let rowTop else { return self }
        let before = entries.first { $0.windowID == window }?.frame
        func current() -> MenuBarSnapshot { MenuBarSnapshot(chain: StatusBarRows.current().chain(top: rowTop), labels: labels, rowTop: rowTop) }
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(80))
            if current().entries.first(where: { $0.windowID == window })?.frame != before { break }
        }
        var previous: MenuBarSnapshot?
        for _ in 0..<25 {
            let bar = current()
            if bar.isComplete, let previous, previous.frames == bar.frames { return bar }
            previous = bar
            try? await Task.sleep(for: .milliseconds(80))
        }
        return current()
    }

    /// 每个图标（含岛民自己的分隔符、开关）对应的窗口
    var itemWindows: [String: CGWindowID] {
        var result: [String: CGWindowID] = [:]
        for (window, label) in labels {
            result[label.id] = window
        }
        return result
    }

    func window(of id: String) -> StatusBarRows.Window? {
        entries.first { $0.id == id }.flatMap { entry in
            entry.windowID.map { StatusBarRows.Window(id: $0, frame: entry.frame, ownerPID: entry.ownerPID, isOnScreen: true) }
        }
    }

    /// 在分隔符左边（藏起来的，含永远隐藏分隔符左边的）
    var hiddenIDs: Set<String> { Set(entries.filter { section(of: $0.id) != .visible }.map(\.id)) }
    /// 在永远隐藏分隔符左边
    var beyondAlwaysHiddenIDs: Set<String> { Set(entries.filter { section(of: $0.id) == .alwaysHidden }.map(\.id)) }

    /// 从左到右第几个
    func orderIndex(of id: String) -> Int? { entries.firstIndex { $0.id == id } }

    /// 标过的窗口都在链上（链没有断）
    private var isComplete: Bool {
        let present = Set(entries.compactMap(\.windowID))
        return labels.keys.allSatisfy(present.contains)
    }

    init(items: [MenuBarItem], separator: CGRect, alwaysHiddenSeparator: CGRect?, toggle: CGRect?,
         hasItemWindows: Bool = true) {
        self.hasItemWindows = hasItemWindows
        var entries = items.map { Entry(id: $0.id, frame: $0.frame, isMovable: $0.isMovable, windowID: $0.windowID) }
        itemCount = items.count
        rowTop = nil
        entries.append(Entry(id: Self.separatorID, frame: separator, isMovable: false))
        if let alwaysHiddenSeparator {
            entries.append(Entry(id: Self.alwaysHiddenSeparatorID, frame: alwaysHiddenSeparator, isMovable: false))
        }
        if let toggle { entries.append(Entry(id: Self.toggleID, frame: toggle, isMovable: false)) }
        self.entries = entries.sorted { $0.frame.minX < $1.frame.minX }
        self.separator = separator
        self.alwaysHiddenSeparator = alwaysHiddenSeparator
        if !hasItemWindows { overlap = Self.overlappingPair(in: items, row: RowGeometry(containing: separator)) }
    }

    /// macOS 27 上连续移动后，辅助功能会报出叠在一起的旧位置（实测三个图标的左边缘挤在 6pt 里），
    /// 照着抓会拖走正坐在那里的别的图标。位置正常时相邻图标也会交叠 2pt 左右，所以叠到 8pt 才算。
    /// 只看拖得到的第三方图标：岛民自己的位置是 AppKit 给的，不会旧；
    /// 刘海左边、屏幕外的图标不会去抓，被系统挤压时叠在一起也不一定是旧位置
    private static func overlappingPair(in items: [MenuBarItem], row: RowGeometry) -> (String, String)? {
        let others = items.filter { $0.bundleID?.hasPrefix("com.apple.") != true && row.isReachable($0.frame.midX) }
        for (index, a) in others.enumerated() {
            for b in others[(index + 1)...] where a.frame.intersection(b.frame).width >= 8 {
                return (a.id, b.id)
            }
        }
        return nil
    }

    /// 两条分隔符都是细线了，所有图标都在菜单栏上排开（没有被挤到屏幕外很远的）
    var isLaidOut: Bool {
        guard separator.width < 100, (alwaysHiddenSeparator?.width ?? 0) < 100 else { return false }
        let screen = RowGeometry(containing: separator).screen
        guard entries.allSatisfy({ $0.frame.minX > screen.minX - 200 && $0.frame.maxX < screen.maxX + 200 }) else {
            return false
        }
        // 没有图标窗口可核对（macOS 27）：位置是旧的时图标会叠在一起
        guard hasItemWindows else { return overlap == nil }
        // 位置还是旧的时，有的图标报告的位置不在任何图标窗口里，或者两个图标落进同一个窗口
        let windows = entries.compactMap(\.windowID)
        return windows.count == itemCount && Set(windows).count == windows.count
    }

    var frames: [CGRect] { entries.map(\.frame) }

    func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }

    /// 和之前的快照比，除了 `id` 以外挪得最远、并且超过 `distance` 的图标。
    /// 拖的图标没动时别的图标本不该动；宽度会变的图标（网速、时钟）只会让旁边的挪一点，被抓错拖走的才挪得远
    func farthestMoved(since before: MenuBarSnapshot, excluding id: String, beyond distance: CGFloat) -> String? {
        let moves = entries.compactMap { entry -> (id: String, distance: CGFloat)? in
            guard entry.id != id, let old = before.entry(entry.id) else { return nil }
            return (entry.id, abs(entry.frame.midX - old.frame.midX))
        }
        return moves.filter { $0.distance > distance }.max { $0.distance < $1.distance }?.id
    }

    func section(of id: String) -> MenuBarItemMover.Section? {
        guard let entry = entry(id) else { return nil }
        if let alwaysHiddenSeparator, entry.frame.midX < alwaysHiddenSeparator.midX { return .alwaysHidden }
        return entry.frame.midX < separator.midX ? .hidden : .visible
    }

    /// 目标位置左右两边的图标（不算正在移动的那个）
    func neighbors(for destination: MenuBarItemMover.Destination, moving id: String) -> (left: Entry?, right: Entry?) {
        let others = entries.filter { $0.id != id }
        guard let separatorIndex = others.firstIndex(where: { $0.id == Self.separatorID }) else { return (nil, nil) }
        // 没有永远隐藏分隔符时（还没排好），永远隐藏区就是空的、位于最左边
        let alwaysHiddenIndex = others.firstIndex { $0.id == Self.alwaysHiddenSeparatorID } ?? -1

        let rightIndex: Int? = {
            if let before = destination.beforeID, let index = others.firstIndex(where: { $0.id == before }) {
                // 目标图标在另一区时以区为准，放到这一区的尽头
                switch destination.section {
                case .alwaysHidden where index < alwaysHiddenIndex: return index
                case .hidden where index > alwaysHiddenIndex && index < separatorIndex: return index
                case .visible where index > separatorIndex: return index
                default: break
                }
            }
            switch destination.section {
            case .alwaysHidden:
                return alwaysHiddenIndex >= 0 ? alwaysHiddenIndex : 0
            case .hidden:
                return separatorIndex
            case .visible:
                // 放在岛民开关（有收纳符时是收纳符）左边；开关不在这一区时，放在系统固定的图标（控制中心、时钟）左边
                return others.indices.first {
                    $0 > separatorIndex && (others[$0].id == Self.toggleID || others[$0].id == Self.collectorID)
                }
                    ?? others.indices.first { $0 > separatorIndex && !others[$0].isMovable }
            }
        }()

        if let rightIndex {
            return (rightIndex > 0 ? others[rightIndex - 1] : nil, others[rightIndex])
        }
        return (others.last, nil)
    }

    func isPlaced(_ id: String, between target: (left: Entry?, right: Entry?)) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        let left = index > 0 ? entries[index - 1].id : nil
        let right = index < entries.count - 1 ? entries[index + 1].id : nil
        return left == target.left?.id && right == target.right?.id
    }
}

/// 一行菜单栏所在的屏幕：光标能去哪、哪里被刘海挡住。CG 坐标（原点在主屏左上）
private struct RowGeometry {
    let screen: CGRect
    /// 刘海挡住的横向范围
    let notch: ClosedRange<CGFloat>?

    init(containing frame: CGRect) {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let point = CGPoint(x: frame.midX, y: frame.midY)
        let screens = NSScreen.screens.map { screen -> (NSScreen, CGRect) in
            let f = screen.frame
            return (screen, CGRect(x: f.minX, y: primaryTop - f.maxY, width: f.width, height: f.height))
        }
        // 被挤出屏幕的图标（x 为负数很远）按行的高度找屏幕
        let match = screens.first { $0.1.contains(point) }
            ?? screens.first { point.y >= $0.1.minY && point.y < $0.1.maxY }
        guard let (nsScreen, rect) = match else {
            screen = .null
            notch = nil
            return
        }
        screen = rect
        if nsScreen.safeAreaInsets.top > 0,
           let left = nsScreen.auxiliaryTopLeftArea, let right = nsScreen.auxiliaryTopRightArea {
            notch = (rect.minX + left.width - 2)...(rect.maxX - right.width + 2)
        } else {
            notch = nil
        }
    }

    /// 有刘海的屏幕上只有刘海右边能拖：刘海后面抓不起来；刘海左边挤着的图标窗口被系统压扁了，拖了也没反应
    func isReachable(_ x: CGFloat) -> Bool {
        guard x > screen.minX + 1, x < screen.maxX - 1 else { return false }
        if let notch { return x > notch.upperBound }
        return true
    }

    /// 按住图标的位置：正中间，不在屏幕上或被刘海挡住时返回 nil
    func grabPoint(for frame: CGRect) -> CGPoint? {
        isReachable(frame.midX) ? CGPoint(x: frame.midX, y: frame.midY) : nil
    }

    /// 松手的位置：两个邻居之间空隙的中点；空隙很宽时贴着要越过的那个邻居；
    /// 被刘海挡住时在有效范围里找最近的可达点
    func dropPoint(between target: (left: MenuBarSnapshot.Entry?, right: MenuBarSnapshot.Entry?), from source: CGRect) -> CGPoint? {
        let left = target.left?.frame
        let right = target.right?.frame
        guard let y = (left ?? right)?.midY else { return nil }

        let preferred: CGFloat
        switch (left, right) {
        case let (l?, r?):
            let middle = (l.maxX + r.minX) / 2
            // 空隙超过一个图标宽：macOS 27 上第一次藏图标时左邻居被挤到刘海左边，中点落在刘海后面，
            // 往两边找 60pt 也够不着刘海右边，每次都拖不到（issue #1）。往左拖贴着右邻居，往右拖贴着左邻居
            if r.minX - l.maxX > 40 {
                preferred = source.midX > middle ? r.minX - 4 : l.maxX + 4
            } else {
                preferred = middle
            }
        case let (l?, nil): preferred = l.maxX + 4
        case let (nil, r?): preferred = r.minX - 4
        case (nil, nil): return nil
        }

        // 光标落在这个范围里，图标就会停在两个邻居之间
        let movingLeft = source.midX > preferred
        let range: ClosedRange<CGFloat>
        if movingLeft {
            let lower = left.map { $0.minX + 6 } ?? -.infinity
            let upper = right.map { $0.minX + 2 } ?? preferred + 20
            range = lower...max(lower, upper)
        } else {
            let lower = left.map { $0.maxX - 2 } ?? preferred - 20
            let upper = right.map { $0.maxX - 6 } ?? .infinity
            range = lower...max(lower, upper)
        }

        let clamped = min(max(preferred, range.lowerBound), range.upperBound)
        if isReachable(clamped) { return CGPoint(x: clamped, y: y) }
        // 往两边一点点找可达的点
        for offset in stride(from: 1.0, through: 60.0, by: 1.0) {
            for x in [clamped + offset, clamped - offset] where range.contains(x) && isReachable(x) {
                return CGPoint(x: x, y: y)
            }
        }
        return nil
    }
}
