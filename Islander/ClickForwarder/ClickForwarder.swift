import AppKit
import ApplicationServices
import os

private let log = Logger(subsystem: "com.kadaliao.islander", category: "click")

/// 点击岛上的图标：
/// - 读得到菜单的（多数 App）：在被点图标的正下方弹出一份"镜像菜单"，选中后转给 App 执行。
///   不挪动任何图标，也不动光标，菜单紧贴着岛展开。
/// - 读不到菜单的（弹自己小窗口的，如 Wi‑Fi、专注模式）：点一下真实图标（藏在屏幕外的也照样能点，见 click），
///   再把弹出来的窗口挪到岛上被点的图标下方（真实图标可能在屏幕外、在菜单栏另一头，多屏时还可能在另一块屏幕上）。
///   挪不动的（或者只是把 App 主窗口带到前面的，如微信）留在原处。
/// 右键：读得到菜单的照样弹镜像菜单（状态栏图标挂着菜单时左右键都弹它）；读不到的先把图标露到菜单栏上，
/// 再把右键送给它，让 App 自己的右键菜单在真实图标下面弹出来。
@MainActor
final class ClickForwarder {
    static let shared = ClickForwarder()

    enum Button: Sendable {
        case left, right
    }

    private var session: Task<Void, Never>?
    private var generation = 0
    /// 退路里弹出的界面正开着、在等它关闭的那个图标。这期间点别的图标不该被吞掉
    private var watchedItemID: String?

    private init() {}

    /// - Parameters:
    ///   - button: 在岛上用的是左键还是右键（按住 ⌃ 点算右键）
    ///   - isHidden: 图标在隐藏区；不在的话（"显示全部图标"时）退路里不用先露出隐藏区
    ///   - needsFullReveal: 图标在永远隐藏分隔符左边，退路里要两条分隔符都缩回才能露出来
    ///   - model: 被点的那个岛
    ///   - anchor: 被点图标在岛窗口里的位置（SwiftUI 全局坐标，原点在左上）
    func open(_ item: MenuBarItem, button: Button = .left, isHidden: Bool, needsFullReveal: Bool = false,
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
            var item = item
            // macOS 27：藏着的图标收在「«」里，辅助功能元素已经失效（读不到菜单、按了没反应）。
            // 先放回菜单栏，等它重新出现、拿到新的元素；菜单 / 弹窗关掉以后再藏回去
            let hider = MenuBarHider.shared
            var revealedFirst = false
            if MenuBarHider.hidesByOverflow, isHidden, !hider.isTemporarilyRevealed {
                hider.beginTemporaryReveal(includingAlwaysHidden: needsFullReveal)
                revealedFirst = true
                guard let shown = await HiddenItemsStore.shared.waitUntilShown(item.id) else {
                    log.error("\(item.id, privacy: .public) 放出来以后还是找不到，放弃")
                    hider.endTemporaryReveal()
                    ScreenManager.shared.collapseAll()
                    return
                }
                item = shown
            }
            defer { if revealedFirst { hider.endTemporaryReveal() } }
            if let view = model.hostView, let entries = await MenuMirror.read(item) {
                await showMirror(entries, of: item, model: model, anchor: anchor, in: view)
            } else {
                log.info("\(item.id, privacy: .public) 读不到菜单，改为在菜单栏里打开")
                await openInMenuBar(item, button: button, offscreen: isHidden && !revealedFirst,
                                    alwaysHidden: needsFullReveal, model: model, anchor: anchor)
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

    // MARK: - 退路：点一下真实图标，弹出的窗口挪到岛下面

    /// 隐藏的图标不用先露出来：在屏幕外照样能点，弹窗出现在屏幕外或者被 App 自己贴到屏幕边上，
    /// 挪过来就行——菜单栏不会跟着变，弹窗也不会先在别处闪一下。
    /// 只有屏幕外打不开弹窗的（实测很少），才退回到"先把图标露出来再点"。
    /// 右键例外：右键弹的多半是菜单（QQ），菜单挪不动，在屏幕外弹出来就看不见了，所以先露出来再点。
    /// - Parameter offscreen: 图标在隐藏区、现在被挤在屏幕外
    private func openInMenuBar(_ item: MenuBarItem, button: Button, offscreen: Bool, alwaysHidden: Bool,
                               model: NotchViewModel, anchor: CGRect) async {
        let scanner = HiddenItemsStore.shared.scanner
        let hider = MenuBarHider.shared
        let destination = PopupRelocator.Destination(under: anchor, of: model)
        let bars = PopupRelocator.menuBars()
        let home = bars.first { $0.screen == destination?.screen }

        // 多屏时点开的位置跟着活动的那一行菜单栏走：活动行不在岛所在的屏幕上，就先切过来
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
        // 右键：弹出来的就在真实图标旁边，不往岛下面挪
        var staysByItem = false
        if button == .right, offscreen, !Self.isSystemItem(item), !bars.contains(where: { $0.holds(itemFrame) }) {
            log.info("\(item.id, privacy: .public) 右键：先露出来再点")
            revealed = true
            staysByItem = true
            // 岛先收起：用不上了，也免得盖住露出来的图标（在刘海下面时），把右键接走
            ScreenManager.shared.collapseAll()
            hider.beginTemporaryReveal(includingAlwaysHidden: alwaysHidden)
            itemFrame = await waitUntilOnScreen(item, bars: bars) ?? itemFrame
        }

        let baseline = await InterfaceWatcher.windows(of: pids)
        await click(item, button, at: itemFrame)
        watchedItemID = item.id
        defer { watchedItemID = nil }

        // 弹窗一般 0.1～0.3 秒就出来。半秒还没有：多半只是切换状态 / 唤起主窗口
        var opened = await InterfaceWatcher.waitUntilOpened(pids: pids, baseline: baseline, timeout: .milliseconds(500))
        var moved = false
        if !opened.isEmpty, !staysByItem, let destination, let activeBar {
            moved = await PopupRelocator.relocate(opened, of: item.element, pid: item.pid, anchoredTo: itemFrame, in: activeBar, to: destination)
        }

        // 图标在屏幕外，弹出来的东西挪不动、也不在屏幕上：把图标露出来
        let itemOnScreen = bars.contains { $0.holds(itemFrame) }
        if !moved, !itemOnScreen, !opened.isEmpty, !revealed {
            let visible = InterfaceWatcher.placements(of: opened).values.filter { placement in
                placement.frame.width > 8 && bars.contains { $0.screen.intersects(placement.frame) }
            }
            if visible.isEmpty {
                log.info("\(item.id, privacy: .public) 在屏幕外打不开，先露出来")
                revealed = true
                hider.beginTemporaryReveal(includingAlwaysHidden: alwaysHidden)
                itemFrame = await waitUntilOnScreen(item, bars: bars) ?? itemFrame
                // 屏幕外那次没真正打开（只留下 1×1 的空窗口）才再点一次；已经开着的再点就关掉了
                if InterfaceWatcher.placements(of: opened).values.allSatisfy({ $0.frame.width <= 8 }) {
                    let baseline = await InterfaceWatcher.windows(of: pids)
                    await click(item, button, at: itemFrame)
                    opened = await InterfaceWatcher.waitUntilOpened(pids: pids, baseline: baseline, timeout: .milliseconds(500))
                    if !opened.isEmpty, let destination, let activeBar {
                        moved = await PopupRelocator.relocate(opened, of: item.element, pid: item.pid, anchoredTo: itemFrame, in: activeBar, to: destination)
                    }
                }
            }
        }
        if !opened.isEmpty {
            let outcome = moved ? "已挪到岛下面" : staysByItem ? "留在露出来的图标旁边" : "挪不动，留在原处"
            log.info("\(item.id, privacy: .public) 的弹窗\(outcome, privacy: .public)")
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
        }
        if moved { model.menuDidClose(choseItem: false) }
    }

    /// 临时露出以后，等图标排到菜单栏上，返回它的新位置（等不到返回 nil）
    private func waitUntilOnScreen(_ item: MenuBarItem, bars: [PopupRelocator.MenuBar]) async -> CGRect? {
        let scanner = HiddenItemsStore.shared.scanner
        for _ in 0..<50 {
            if let frame = await scanner.frame(of: item.element), bars.contains(where: { $0.holds(frame) }) {
                return frame
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return nil
    }

    /// 点一下真实图标。
    ///
    /// 平时用辅助功能的"按下"：让按钮执行它自己的动作，多数 App 都认。
    /// 有两种情况改成往图标的窗口发一次定向点击（光标点完放回原处，图标在屏幕外也收得到），由控制中心当成用户的点击转给 App：
    /// - 右键：辅助功能只有"按下"，没有右键（#8 的 QQ：右键菜单是 App 收到右键以后才弹的）；
    /// - Tauri 的托盘图标：自己接鼠标事件，"按下"回成功却什么也不做（#8 的 CC Switch）。
    /// 其余的左键不发定向点击：有的 App 对它和对"按下"反应不一样（实测 pap.er：定向点击以后面板没出来）。
    /// 系统图标、找不到窗口的（macOS 27 上没有单个图标的窗口）只能"按下"，右键也只好当左键按
    private func click(_ item: MenuBarItem, _ button: Button, at frame: CGRect) async {
        let viaEvents = button == .right ? true : await usesTrayIcon(item)
        let rows = StatusBarRows.current()
        if viaEvents, !Self.isSystemItem(item), let window = Self.window(of: item, at: frame, in: rows) {
            log.debug("\(item.id, privacy: .public) 定向\(button == .right ? "右键" : "左键", privacy: .public)点击窗口 \(window.id) \(String(describing: window.frame), privacy: .public)")
            await Self.postClick(button, at: window.frame.center, window: window.id, pid: window.ownerPID)
            return
        }
        // 有的图标自己接鼠标事件（实测 Neat Download Manager），辅助功能里列着"按下"却回"不支持"：也改发定向点击
        let result = await HiddenItemsStore.shared.scanner.press(item.element)
        guard result == .actionUnsupported else { return }
        guard let window = Self.window(of: item, at: frame, in: rows) else {
            log.error("\(item.id, privacy: .public) 不支持辅助功能的按下，也找不到它的窗口")
            return
        }
        log.info("\(item.id, privacy: .public) 不支持辅助功能的按下，改发定向点击")
        await Self.postClick(.left, at: window.frame.center, window: window.id, pid: window.ownerPID)
    }

    /// 系统图标（控制中心、时钟这些）：辅助功能的按下一直好用，不发鼠标事件
    private static func isSystemItem(_ item: MenuBarItem) -> Bool {
        item.bundleID?.hasPrefix("com.apple.") ?? false
    }

    /// 查过的可执行文件：是不是用 Tauri 的托盘图标
    private var trayIconExecutables: [String: Bool] = [:]

    /// Tauri（tray-icon）的托盘图标在按钮上盖一层自己接鼠标事件的视图，按钮本身没有动作。
    /// 这层视图的类名是 TaoTrayTarget，看 App 的可执行文件里有没有这个名字（每个 App 只查一次）
    private func usesTrayIcon(_ item: MenuBarItem) async -> Bool {
        guard !Self.isSystemItem(item),
              let url = NSRunningApplication(processIdentifier: item.pid)?.executableURL
        else { return false }
        if let known = trayIconExecutables[url.path] { return known }
        let found = await Self.file(at: url, contains: "TaoTrayTarget")
        trayIconExecutables[url.path] = found
        if found { log.info("\(item.id, privacy: .public) 是 Tauri 的托盘图标，改发定向点击") }
        return found
    }

    @concurrent
    private static func file(at url: URL, contains marker: String) async -> Bool {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return false }
        let needle = Array(marker.utf8)
        return data.withUnsafeBytes { bytes in
            needle.withUnsafeBytes { memmem(bytes.baseAddress, bytes.count, $0.baseAddress, $0.count) != nil }
        }
    }

    /// 图标现在所在的窗口。优先用扫描时认准的窗口（岛上的图标就是从它截的），按窗口服务器的实时位置点：
    /// 刚露出来时辅助功能报告的位置会晚一拍，按它去找可能点到旁边的图标上
    private static func window(of item: MenuBarItem, at frame: CGRect, in rows: StatusBarRows) -> StatusBarRows.Window? {
        let known = item.windowID ?? HiddenItemsStore.shared.itemWindows[item.id]
        if let known, let window = rows.windows.first(where: { $0.id == known && $0.frame.width < 1000 }) {
            // 多屏时每一行都有一份，点活动行（辅助功能报告的那一行）里的
            if abs(window.frame.midY - frame.midY) < window.frame.height / 2 { return window }
            if let counterpart = rows.counterpart(of: window, inRowTop: frame.minY) { return counterpart }
        }
        return rows.window(containing: frame.center)
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
        await Self.postClick(.left, at: window.frame.center, window: window.id, pid: window.ownerPID)
        return true
    }

    private nonisolated static let eventQueue = DispatchQueue(label: "com.kadaliao.islander.click", qos: .userInteractive)

    private nonisolated static func postClick(_ button: Button, at point: CGPoint, window: CGWindowID, pid: pid_t) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            eventQueue.async {
                postClickNow(button, at: point, window: window, pid: pid)
                continuation.resume()
            }
        }
    }

    private nonisolated static func postClickNow(_ button: Button, at point: CGPoint, window: CGWindowID, pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        // 发完事件以后系统默认压住真实鼠标 0.25 秒：用户点完接着移鼠标，光标会卡一下
        source?.localEventsSuppressionInterval = 0
        let permitted: CGEventFilterMask = [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents]
        source?.setLocalEventsFilterDuringSuppressionState(permitted, state: .eventSuppressionStateSuppressionInterval)
        source?.setLocalEventsFilterDuringSuppressionState(permitted, state: .eventSuppressionStateRemoteMouseDrag)
        let saved = CGEvent(source: nil)?.location
        CGAssociateMouseAndMouseCursorPosition(0)
        defer {
            if let saved { CGWarpMouseCursorPosition(saved) }
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        let types: [CGEventType] = button == .right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp]
        for type in types {
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                                mouseButton: button == .right ? .right : .left)
            // 单击：Electron 只认 clickCount 为 1 的点击
            event?.setIntegerValueField(.mouseEventClickState, value: 1)
            // 不带用户正按着的修饰键（按住 ⌥ 打开的岛），和辅助功能的按下一样
            event?.flags = .maskNonCoalesced
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
