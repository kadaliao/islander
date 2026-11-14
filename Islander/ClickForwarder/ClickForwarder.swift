import AppKit
import ApplicationServices
import os

private let log = Logger(subsystem: "com.kadaliao.islander", category: "click")

/// 点击岛上的图标：
/// - 读得到菜单的（多数 App）：在被点图标的正下方弹出一份"镜像菜单"，选中后转给 App 执行。
///   不挪动任何图标，也不动光标，菜单紧贴着岛展开。
/// - 读不到菜单的（弹自己小窗口的，如 Wi‑Fi、专注模式）：对真实图标"按下"（藏在屏幕外的也照样能按），
///   再把弹出来的窗口挪到岛上被点的图标下方（真实图标可能在屏幕外、在菜单栏另一头，多屏时还可能在另一块屏幕上）。
///   挪不动的（或者只是把 App 主窗口带到前面的，如微信）留在原处。
@MainActor
final class ClickForwarder {
    static let shared = ClickForwarder()

    private var session: Task<Void, Never>?
    private var generation = 0
    /// 退路里弹出的界面正开着、在等它关闭的那个图标。这期间点别的图标不该被吞掉
    private var watchedItemID: String?

    private init() {}

    /// - Parameters:
    ///   - isHidden: 图标在隐藏区；不在的话（"显示全部图标"时）退路里不用先露出隐藏区
    ///   - needsFullReveal: 图标在永远隐藏分隔符左边，退路里要两条分隔符都缩回才能露出来
    ///   - model: 被点的那个岛
    ///   - anchor: 被点图标在岛窗口里的位置（SwiftUI 全局坐标，原点在左上）
    func open(_ item: MenuBarItem, isHidden: Bool, needsFullReveal: Bool = false,
              from model: NotchViewModel, anchor: CGRect) {
        let previous = session
        if previous != nil {
            // 正在打开的过程中：忽略。只是在等上一个弹窗关闭：不等了，直接换成新点的这个
            guard let watched = watchedItemID else { return }
            previous?.cancel()
            // 再点一次同一个图标是想关掉它（点在岛上，弹窗自己会关）
            if watched == item.id { return }
        }
        generation += 1
        let current = generation
        session = Task {
            await previous?.value
            defer { if generation == current { session = nil } }
            if let view = model.hostView, let entries = await MenuMirror.read(item) {
                await showMirror(entries, of: item, model: model, anchor: anchor, in: view)
            } else {
                log.info("\(item.id, privacy: .public) 读不到菜单，改为在菜单栏里打开")
                await openInMenuBar(item, reveal: isHidden, alwaysHidden: needsFullReveal, model: model, anchor: anchor)
            }
        }
    }

    private func showMirror(_ entries: [MirroredMenuItem], of item: MenuBarItem,
                            model: NotchViewModel, anchor: CGRect, in view: NSView) async {
        // 菜单左上角对齐图标左下角，留一点间隙
        let gap: CGFloat = 6
        let y = view.isFlipped ? anchor.maxY + gap : view.bounds.height - anchor.maxY - gap
        let point = NSPoint(x: anchor.minX, y: y)

        model.menuDidOpen(item.id)
        let chosen = MirrorMenuPresenter().popUp(entries, at: point, in: view, style: model.style)
        model.menuDidClose(choseItem: chosen != nil)

        if let chosen {
            let result = await MenuMirror.perform(chosen)
            log.info("转给 \(item.id, privacy: .public) 执行：AXError \(result.rawValue)")
        }
    }

    // MARK: - 退路：对真实图标"按下"，弹出的窗口挪到岛下面

    /// 隐藏的图标不用先露出来：在屏幕外照样能"按下"，弹窗出现在屏幕外或者被 App 自己贴到屏幕边上，
    /// 挪过来就行——菜单栏不会跟着变，弹窗也不会先在别处闪一下。
    /// 只有屏幕外打不开弹窗的（实测很少），才退回到"先把图标露出来再按"。
    private func openInMenuBar(_ item: MenuBarItem, reveal: Bool, alwaysHidden: Bool,
                               model: NotchViewModel, anchor: CGRect) async {
        let scanner = HiddenItemsStore.shared.scanner
        let hider = MenuBarHider.shared
        let destination = PopupRelocator.Destination(under: anchor, of: model)
        let bars = PopupRelocator.menuBars()
        let home = bars.first { $0.screen == destination?.screen }

        // 多屏时"按下"打开的位置跟着活动的那一行菜单栏走：活动行不在岛所在的屏幕上，就先切过来
        // （跨屏挪过来的系统面板不显示，只能让它一开始就弹在这块屏幕上）。
        // 时钟永远在屏幕上，它报告的位置在哪一行，哪一行就是活动行
        let clock = HiddenItemsStore.shared.allItems.first { $0.id.hasSuffix("|com.apple.menuextra.clock") }?.source.element
        var activeBar = home
        if bars.count > 1, let home, let reference = clock {
            var activated = false
            for _ in 0..<25 {
                guard let frame = await scanner.frame(of: reference),
                      let bar = bars.first(where: { $0.holds(frame) })
                else { break }
                activeBar = bar
                if bar.screen == home.screen { break }
                if !activated {
                    activated = true
                    guard await activateMenuBar(of: home) else { break }
                    log.info("活动菜单栏在另一块屏幕上，先切到岛所在的屏幕")
                }
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
        guard var itemFrame = await scanner.frame(of: item.element) else {
            log.error("\(item.id, privacy: .public) 读不到位置，放弃")
            ScreenManager.shared.collapseAll()
            return
        }
        let pids = Self.relatedProcesses(of: item)
        var revealed = false
        defer { if revealed { hider.endTemporaryReveal() } }
        var baseline = await InterfaceWatcher.windows(of: pids)
        // 藏着的图标不能信它报的位置：macOS 27 上收进「«」的图标照样报一个屏幕上的位置，在那里点会点到别处
        if !(await press(item, at: itemFrame, onScreen: !reveal && bars.contains { $0.holds(itemFrame) })) {
            // 按不下去、也没有窗口可发定向点击（macOS 27），图标又藏着：先露出来，再在它身上真点一下
            if reveal, let frame = await revealItem(item, alwaysHidden: alwaysHidden, in: bars) {
                revealed = true
                itemFrame = frame
                baseline = await InterfaceWatcher.windows(of: pids)
                await press(item, at: itemFrame, onScreen: true)
            }
        }
        watchedItemID = item.id
        defer { watchedItemID = nil }

        // 弹窗一般 0.1～0.3 秒就出来。半秒还没有：多半只是切换状态 / 唤起主窗口
        var opened = await InterfaceWatcher.waitUntilOpened(pids: pids, baseline: baseline, timeout: .milliseconds(500))
        var moved = false
        if !opened.isEmpty, let destination, let activeBar {
            moved = await PopupRelocator.relocate(opened, of: item.element, pid: item.pid, anchoredTo: itemFrame, in: activeBar, to: destination)
        }

        // 图标在屏幕外，弹出来的东西挪不动、也不在屏幕上：把图标露出来
        let itemOnScreen = bars.contains { $0.holds(itemFrame) }
        if !moved, !itemOnScreen, !opened.isEmpty {
            let visible = InterfaceWatcher.placements(of: opened).values.filter { placement in
                placement.frame.width > 8 && bars.contains { $0.screen.intersects(placement.frame) }
            }
            if visible.isEmpty, !revealed {
                log.info("\(item.id, privacy: .public) 在屏幕外打不开，先露出来")
                revealed = true
                hider.beginTemporaryReveal(includingAlwaysHidden: alwaysHidden)
                for _ in 0..<50 {
                    if let frame = await scanner.frame(of: item.element), bars.contains(where: { $0.holds(frame) }) {
                        itemFrame = frame
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(30))
                }
                // 屏幕外那次没真正打开（只留下 1×1 的空窗口）才再按一次；已经开着的再按就关掉了
                if InterfaceWatcher.placements(of: opened).values.allSatisfy({ $0.frame.width <= 8 }) {
                    let baseline = await InterfaceWatcher.windows(of: pids)
                    await press(item, at: itemFrame, onScreen: bars.contains { $0.holds(itemFrame) })
                    opened = await InterfaceWatcher.waitUntilOpened(pids: pids, baseline: baseline, timeout: .milliseconds(500))
                    if !opened.isEmpty, let destination, let activeBar {
                        moved = await PopupRelocator.relocate(opened, of: item.element, pid: item.pid, anchoredTo: itemFrame, in: activeBar, to: destination)
                    }
                }
            }
        }
        if !opened.isEmpty {
            log.info("\(item.id, privacy: .public) 的弹窗\(moved ? "已挪到岛下面" : "挪不动，留在原处", privacy: .public)")
        }

        if moved {
            // 和镜像菜单一样：岛保持展开、图标保持高亮，直到弹窗关闭
            model.menuDidOpen(item.id)
        } else {
            ScreenManager.shared.collapseAll()
        }
        if opened.isEmpty {
            opened = await InterfaceWatcher.waitUntilOpened(pids: pids, baseline: baseline, timeout: .seconds(1))
        }
        if !opened.isEmpty {
            await InterfaceWatcher.waitUntilClosed(pids: pids, opened: opened)
        } else if revealed {
            // 点了没弹出任何窗口：有的图标是在菜单栏里原地展开（实测 QQ 音乐变成一排播放按钮）。
            // 立刻藏回去用户就点不到了：光标还在菜单栏上就先露着，离开菜单栏一秒再藏
            await Self.waitWhilePointerInMenuBar(bars, timeout: .seconds(20))
        }
        if moved { model.menuDidClose(choseItem: false) }
    }

    /// 等光标离开菜单栏（连续一秒不在任何一行菜单栏上），最多等 `timeout`
    private static func waitWhilePointerInMenuBar(_ bars: [PopupRelocator.MenuBar], timeout: Duration) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var outsideSince: ContinuousClock.Instant?
        while clock.now < deadline {
            let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
            let location = NSEvent.mouseLocation
            let point = CGPoint(x: location.x, y: primaryTop - location.y)
            let inBar = bars.contains { $0.screen.minX <= point.x && point.x <= $0.screen.maxX && point.y <= $0.bottom + 4 && point.y >= $0.screen.minY - 4 }
            if inBar {
                outsideSince = nil
            } else if let since = outsideSince {
                if clock.now - since > .seconds(1) { return }
            } else {
                outsideSince = clock.now
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// 对真实图标"按下"。有的图标自己接鼠标事件（实测 Neat Download Manager、QQ 音乐），辅助功能里列着"按下"
    /// 却回"不支持"：改成往图标的窗口发一次定向点击（不动光标，图标在屏幕外也收得到）。
    /// macOS 27 上图标没有自己的窗口，只能在它显示在屏幕上时真点一下。
    /// - Returns: 有没有发出去；false 表示图标不在屏幕上、又没有别的办法
    @discardableResult
    private func press(_ item: MenuBarItem, at frame: CGRect, onScreen: Bool) async -> Bool {
        let result = await HiddenItemsStore.shared.scanner.press(item.element)
        guard result == .actionUnsupported else { return true }
        if let window = StatusBarRows.current().window(containing: frame.center) {
            log.info("\(item.id, privacy: .public) 不支持辅助功能的按下，改发定向点击")
            await Self.postClick(at: frame.center, window: window.id, pid: window.ownerPID)
            return true
        }
        guard onScreen else {
            log.info("\(item.id, privacy: .public) 不支持辅助功能的按下，也没有窗口，图标不在屏幕上")
            return false
        }
        log.info("\(item.id, privacy: .public) 不支持辅助功能的按下，也没有窗口，在图标上真点一下：\(MoveDiagnostics.brief(frame), privacy: .public)")
        await Self.postRealClick(at: frame.center)
        return true
    }

    /// 临时露出隐藏的图标，等它出现在屏幕上，返回它的新位置；露不出来就结束露出、返回 nil
    private func revealItem(_ item: MenuBarItem, alwaysHidden: Bool, in bars: [PopupRelocator.MenuBar]) async -> CGRect? {
        let hider = MenuBarHider.shared
        log.info("\(item.id, privacy: .public) 先露出来再点")
        hider.beginTemporaryReveal(includingAlwaysHidden: alwaysHidden)
        // macOS 27 上收进「«」的图标要滑将近一秒才回到菜单栏，辅助功能却一开始就报最终位置：
        // 不等动画走完就点，会点到正滑过那里的别的图标。先等动画，再要位置连续两次一样
        try? await Task.sleep(for: .milliseconds(900))
        var previous: CGRect?
        for _ in 0..<50 {
            try? await Task.sleep(for: .milliseconds(40))
            guard let frame = await HiddenItemsStore.shared.scanner.frame(of: item.element),
                  bars.contains(where: { $0.holds(frame) })
            else { previous = nil; continue }
            if frame == previous { return frame }
            previous = frame
        }
        log.error("\(item.id, privacy: .public) 露出来以后还是不在屏幕上")
        hider.endTemporaryReveal()
        return nil
    }

    /// 图标所在的进程，加上同一个 App 的其他进程：有的 App 图标挂在辅助进程上，弹窗却是主进程开的
    /// （飞书：com.electron.lark.helper 的图标，com.electron.lark 的弹窗）。按 bundle ID 的前缀关系认
    private static func relatedProcesses(of item: MenuBarItem) -> Set<pid_t> {
        var pids: Set<pid_t> = [item.pid]
        guard let bundleID = item.bundleID, !bundleID.hasPrefix("com.apple.") else { return pids }
        for app in NSWorkspace.shared.runningApplications {
            guard let other = app.bundleIdentifier else { continue }
            if other.hasPrefix(bundleID + ".") || bundleID.hasPrefix(other + ".") {
                pids.insert(app.processIdentifier)
            }
        }
        return pids
    }

    // MARK: - 多屏：切换活动菜单栏

    /// 让某块屏幕的菜单栏变成活动行：往那一行里岛民自己的开关图标发一次定向点击（不动光标）。
    /// 实测（macOS 26.7）：点非活动行里的状态栏图标，系统只是把那一行变成活动行，点击本身不会送到图标；
    /// 大约一秒内没有菜单 / 弹窗打开就又切回去。保险起见这期间开关忽略点击。
    private func activateMenuBar(of bar: PopupRelocator.MenuBar) async -> Bool {
        guard let window = MenuBarHider.shared.toggleWindow(inRowTop: bar.screen.minY) else { return false }
        MenuBarHider.shared.ignoreToggleClicks(for: 0.6)
        await Self.postClick(at: window.frame.center, window: window.id, pid: window.ownerPID)
        return true
    }

    private nonisolated static let eventQueue = DispatchQueue(label: "com.kadaliao.islander.click", qos: .userInteractive)

    private nonisolated static func postClick(at point: CGPoint, window: CGWindowID, pid: pid_t) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            eventQueue.async {
                postClickNow(at: point, window: window, pid: pid)
                continuation.resume()
            }
        }
    }

    /// 在屏幕上的这一点真点一下（菜单栏没有图标窗口时用）。光标会瞬间跳过去，点完回到原处
    private nonisolated static func postRealClick(at point: CGPoint) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            eventQueue.async {
                let source = CGEventSource(stateID: .hidSystemState)
                let saved = CGEvent(source: nil)?.location
                CGAssociateMouseAndMouseCursorPosition(0)
                defer {
                    if let saved { CGWarpMouseCursorPosition(saved) }
                    CGAssociateMouseAndMouseCursorPosition(1)
                }
                for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                    CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                        .post(tap: .cghidEventTap)
                    usleep(type == .mouseMoved ? 30_000 : 40_000)
                }
                continuation.resume()
            }
        }
    }

    private nonisolated static func postClickNow(at point: CGPoint, window: CGWindowID, pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        let saved = CGEvent(source: nil)?.location
        CGAssociateMouseAndMouseCursorPosition(0)
        defer {
            if let saved { CGWarpMouseCursorPosition(saved) }
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp]
        for type in types {
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
            event?.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window))
            event?.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window))
            // 0x33 是事件里的窗口编号字段（没有公开名字）
            if let field = CGEventField(rawValue: 0x33) { event?.setIntegerValueField(field, value: Int64(window)) }
            event?.post(tap: .cgSessionEventTap)
            usleep(60_000)
        }
    }
}
