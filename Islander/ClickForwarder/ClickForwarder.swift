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
/// 右键：读得到菜单的照样弹镜像菜单（状态栏图标挂着菜单时左右键都弹它）。读不到的（QQ：菜单是收到右键才临时挂上的）
/// 把右键直接交给 App（见 DirectClick），菜单在屏幕外弹出来，读出来关掉、在岛上弹一份一样的，选中哪项再打开一次替用户按下去；
/// 弹的是窗口就和左键一样挪到岛下面。直接交不了的（拿不到通行码、交过去没反应），才先把图标露到菜单栏上再把右键送给它。
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
                await showMirror(entries, of: item, model: model, anchor: anchor, in: view) { choice in
                    let result = await MenuMirror.perform(choice.element)
                    log.info("转给 \(item.id, privacy: .public) 执行：AXError \(result.rawValue)")
                }
            } else if button == .right, !revealedFirst, !Self.isSystemItem(item), let view = model.hostView,
                      await openDirectly(item, isHidden: isHidden, alwaysHidden: needsFullReveal,
                                         model: model, anchor: anchor, in: view) {
                return
            } else {
                log.info("\(item.id, privacy: .public) 读不到菜单，改为在菜单栏里打开")
                await openInMenuBar(item, button: button, offscreen: isHidden && !revealedFirst,
                                    alwaysHidden: needsFullReveal, model: model, anchor: anchor)
            }
        }
    }

    /// - Parameter perform: 用户选中某一项以后怎么执行
    private func showMirror(_ entries: [MirroredMenuItem], of item: MenuBarItem, model: NotchViewModel, anchor: CGRect,
                            in view: NSView, perform: (MirrorChoice) async -> Void) async {
        // 菜单左上角对齐图标左下角，留一点间隙
        let gap: CGFloat = 6
        let y = view.isFlipped ? anchor.maxY + gap : view.bounds.height - anchor.maxY - gap
        let point = NSPoint(x: anchor.minX, y: y)

        model.menuDidOpen(item.id)
        let chosen = MirrorMenuPresenter().popUp(entries, at: point, in: view, style: model.style)
        model.menuDidClose(choseItem: chosen != nil)
        log.debug("\(item.id, privacy: .public) 的镜像菜单关了，\(chosen == nil ? "没选" : "选了「\(chosen!.path.joined(separator: " › "))」", privacy: .public)")

        if let chosen { await perform(chosen) }
    }

    // MARK: - 右键：直接交给 App

    /// 把右键直接交给 App（见 DirectClick），图标不用露出来。
    /// 个别图标（QQ 刚启动时）藏着探不到通行码：在菜单栏上露一下、按位置真点一次（截下来不给 App），马上藏回去。
    /// 点过这一次以后藏着也探得到，所以每次 App 启动后最多露这一次
    /// - Returns: false 表示交不了（拿不到通行码，或者交过去没反应），由调用方退回到先把图标露出来再点
    private func openDirectly(_ item: MenuBarItem, isHidden: Bool, alwaysHidden: Bool, model: NotchViewModel,
                              anchor: CGRect, in view: NSView) async -> Bool {
        let scanner = HiddenItemsStore.shared.scanner
        guard let frame = await scanner.frame(of: item.element),
              let window = Self.window(of: item, at: frame, in: StatusBarRows.current())
        else { return false }
        let remembered = DirectClick.known(item)
        var route = remembered
        if route == nil {
            route = await DirectClick.probe(item, window: window)
        }
        let bars = PopupRelocator.menuBars()
        if route == nil, isHidden, !bars.contains(where: { $0.holds(frame) }) {
            route = await primeByRevealing(item, alwaysHidden: alwaysHidden, bars: bars)
        }
        guard var route else { return false }

        let pids = Self.relatedProcesses(of: item)
        var reaction = await deliver(route, to: item, pids: pids)
        if case .nothing = reaction, remembered != nil {
            // 记着的通行码可能过期了（App 重建了图标）：重新探一次再交
            DirectClick.forget(item)
            if let now = await scanner.frame(of: item.element),
               let window = Self.window(of: item, at: now, in: StatusBarRows.current()),
               let fresh = await DirectClick.probe(item, window: window) {
                route = fresh
                reaction = await deliver(fresh, to: item, pids: pids)
            }
        }

        switch reaction {
        case .nothing:
            log.info("\(item.id, privacy: .public) 收到右键没有反应，改用老办法")
            DirectClick.forget(item)
            return false
        case .unreadableMenu:
            // 弹了菜单却读不到：开在屏幕外看不见、又一直接走键盘，按 Esc 关掉
            log.error("\(item.id, privacy: .public) 右键弹出的菜单读不到，关掉")
            await DirectClick.escape(pid: item.pid)
            ScreenManager.shared.collapseAll()
        case .menu(let entries):
            // 真实菜单开在屏幕外：读完就关，在岛上弹一份一样的
            log.info("\(item.id, privacy: .public) 的菜单读到 \(entries.count) 项，关掉，在岛上弹一份")
            await closeMenu(of: item)
            await showMirror(entries, of: item, model: model, anchor: anchor, in: view) { [route] choice in
                await self.choose(choice, in: item, route: route)
            }
        case .windows(let opened):
            await relocate(opened, of: item, itemFrame: frame, model: model, anchor: anchor, pids: pids)
        }
        return true
    }

    /// 露一下取通行码。露出来以后先按窗口探（多屏时每一行各有一个窗口，挨个探），探不到就按位置真点一次：
    /// 按位置送的点到哪个图标算哪个，那个 App 会真的收到左键，所以等窗口停稳了再点。
    /// 藏回去以后按窗口再探一次，用这次的（实测 QQ：露着时探到的那份，藏回去以后交过去没反应）
    private func primeByRevealing(_ item: MenuBarItem, alwaysHidden: Bool,
                                  bars: [PopupRelocator.MenuBar]) async -> DirectClick.Route? {
        log.info("\(item.id, privacy: .public) 露一下取通行码")
        let scanner = HiddenItemsStore.shared.scanner
        let hider = MenuBarHider.shared
        var route: DirectClick.Route?
        hider.beginTemporaryReveal(includingAlwaysHidden: alwaysHidden)
        if let shown = await waitUntilOnScreen(item, bars: bars) {
            let rows = StatusBarRows.current()
            let shownWindow = Self.window(of: item, at: shown, in: rows)
            let others = shownWindow.map { window in
                bars.compactMap { rows.counterpart(of: window, inRowTop: $0.screen.minY) }
                    .filter { $0.id != window.id && $0.isOnScreen }
            } ?? []
            for candidate in [shownWindow].compactMap({ $0 }) + others {
                route = await DirectClick.probe(item, window: candidate)
                if route != nil { break }
                guard let settled = await Self.settledWindow(candidate.id) else {
                    log.info("\(item.id, privacy: .public) 窗口 \(candidate.id) 没停稳，不按位置点")
                    continue
                }
                route = await DirectClick.probe(item, window: settled, byPosition: true)
                if route != nil { break }
            }
        }
        hider.endTemporaryReveal()
        // 等它回到屏幕外：还在菜单栏上的话，菜单会弹在看得见的地方
        var hidden: CGRect?
        for _ in 0..<40 {
            guard let now = await scanner.frame(of: item.element) else { break }
            if !bars.contains(where: { $0.holds(now) }) {
                hidden = now
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard route != nil else { return nil }
        if let hidden, let window = Self.window(of: item, at: hidden, in: StatusBarRows.current()),
           let again = await DirectClick.probe(item, window: window) {
            return again
        }
        return route
    }

    /// 等窗口停稳（隔 40 毫秒连读两次位置一样）、在屏幕上，最多等 0.6 秒
    private static func settledWindow(_ id: CGWindowID) async -> StatusBarRows.Window? {
        var last: CGRect?
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(40))
            guard let now = StatusBarRows.current().windows.first(where: { $0.id == id }) else { return nil }
            if now.isOnScreen, now.frame == last { return now }
            last = now.frame
        }
        return nil
    }

    private enum Reaction {
        case nothing
        /// 弹了菜单，辅助功能却读不到
        case unreadableMenu
        case menu([MirroredMenuItem])
        case windows(Set<CGWindowID>)
    }

    /// 交一次右键，看 App 有什么反应。
    /// 菜单：辅助功能里图标下面挂出一个菜单。弹的是窗口：这个 App 多出新窗口。
    /// 菜单本身也是个窗口（弹出菜单层级），可能比辅助功能里的菜单先出来，那种接着等
    private func deliver(_ route: DirectClick.Route, to item: MenuBarItem, pids: Set<pid_t>) async -> Reaction {
        let baseline = await InterfaceWatcher.windows(of: pids)
        log.info("\(item.id, privacy: .public) 右键直接交给 App")
        await DirectClick.rightClick(route, pid: item.pid)
        var opened: Set<CGWindowID> = []
        for _ in 0..<40 {
            if let entries = await MenuMirror.read(item) { return .menu(entries) }
            opened = await InterfaceWatcher.windows(of: pids).subtracting(baseline)
            if !opened.isEmpty, !Self.containsMenuWindow(opened) { return .windows(opened) }
            try? await Task.sleep(for: .milliseconds(25))
        }
        if Self.containsMenuWindow(opened) { return .unreadableMenu }
        return opened.isEmpty ? .nothing : .windows(opened)
    }

    /// 镜像菜单里选中了一项：再把真实菜单打开一次（屏幕外），按标题找到那一项按下去
    private func choose(_ choice: MirrorChoice, in item: MenuBarItem, route: DirectClick.Route) async {
        await DirectClick.rightClick(route, pid: item.pid)
        for _ in 0..<40 {
            if let entries = await MenuMirror.read(item) {
                guard let target = MenuMirror.find(choice.path, in: entries) else {
                    log.error("\(item.id, privacy: .public) 重新打开的菜单里找不到「\(choice.path.joined(separator: " › "), privacy: .public)」")
                    await closeMenu(of: item)
                    return
                }
                let result = await MenuMirror.perform(target.element)
                log.info("转给 \(item.id, privacy: .public) 执行「\(choice.path.joined(separator: " › "), privacy: .public)」：AXError \(result.rawValue)")
                return
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        log.error("\(item.id, privacy: .public) 重新打开菜单没成功")
    }

    /// 关掉屏幕外开着的真实菜单，等它真的关了（开着的菜单会一直接走键盘）
    private func closeMenu(of item: MenuBarItem) async {
        for attempt in 0..<3 {
            guard await MenuMirror.cancel(item) else { return }
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(25))
                if await MenuMirror.read(item) == nil { return }
            }
            log.error("\(item.id, privacy: .public) 菜单没关上（第 \(attempt + 1) 次）")
        }
    }

    /// 这些窗口里有弹出菜单（NSMenu 开着时的窗口在弹出菜单层级）
    private static func containsMenuWindow(_ windows: Set<CGWindowID>) -> Bool {
        guard !windows.isEmpty, let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let menuLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return list.contains { info in
            guard let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return false }
            return windows.contains(number) && (info[kCGWindowLayer as String] as? Int) == menuLayer
        }
    }

    /// 右键弹出的是窗口：和左键一样挪到岛下面，等它关掉
    private func relocate(_ opened: Set<CGWindowID>, of item: MenuBarItem, itemFrame: CGRect, model: NotchViewModel,
                          anchor: CGRect, pids: Set<pid_t>) async {
        let bars = PopupRelocator.menuBars()
        let destination = PopupRelocator.Destination(under: anchor, of: model)
        // 图标所在的那一行：窗口服务器给的图标位置在哪块屏幕的菜单栏高度上
        let bar = bars.first { abs(itemFrame.midY - $0.screen.minY) < 45 }
        var moved = false
        if let destination, let bar {
            moved = await PopupRelocator.relocate(opened, of: item.element, pid: item.pid, anchoredTo: itemFrame,
                                                  in: bar, to: destination)
        }
        log.info("\(item.id, privacy: .public) 右键弹出的窗口\(moved ? "已挪到岛下面" : "挪不动，留在原处", privacy: .public)")
        watchedItemID = item.id
        defer { watchedItemID = nil }
        if moved { model.menuDidOpen(item.id) } else { ScreenManager.shared.collapseAll() }
        await InterfaceWatcher.waitUntilClosed(pids: pids, opened: opened)
        if moved { model.menuDidClose(choseItem: false) }
    }

    // MARK: - 退路：点一下真实图标，弹出的窗口挪到岛下面

    /// 隐藏的图标不用先露出来：在屏幕外照样能点，弹窗出现在屏幕外或者被 App 自己贴到屏幕边上，
    /// 挪过来就行——菜单栏不会跟着变，弹窗也不会先在别处闪一下。
    /// 只有屏幕外打不开弹窗的（实测很少），才退回到"先把图标露出来再点"。
    /// 右键例外：先试着直接交给 App（openDirectly）；交不了的，右键弹的多半是菜单（QQ），菜单挪不动，
    /// 在屏幕外弹出来就看不见了，所以先露出来再点。
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

    /// 往图标的窗口发一次定向点击，由控制中心当成用户的点击转给 App
    /// - Parameter byPosition: 只指定控制中心、由它按位置找图标（只能点屏幕上的）。右键总是这样
    nonisolated static func postClick(_ button: Button, at point: CGPoint, window: CGWindowID, pid: pid_t,
                                      byPosition: Bool = false) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            eventQueue.async {
                postClickNow(button, at: point, window: window, pid: pid, byPosition: byPosition || button == .right)
                continuation.resume()
            }
        }
    }

    private nonisolated static func postClickNow(_ button: Button, at point: CGPoint, window: CGWindowID, pid: pid_t,
                                                 byPosition: Bool) {
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
            // 记号：DirectClick 的事件开关凭它认出岛民自己的点击
            event?.setIntegerValueField(.eventSourceUserData, value: DirectClick.marker)
            // 按位置的只指定进程，由控制中心按位置找图标（所以只能点屏幕上的）。右键都这样发：
            // 实测（macOS 26.7）带上窗口编号的右键有时整个被丢掉，图标在屏幕上也一样；不带就总能送到
            if !byPosition {
                event?.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window))
                event?.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window))
                // 0x33 是事件里的窗口编号字段（没有公开名字）：靠它，屏幕外的图标也点得到
                if let field = CGEventField(rawValue: 0x33) { event?.setIntegerValueField(field, value: Int64(window)) }
            }
            event?.post(tap: .cgSessionEventTap)
            usleep(60_000)
        }
    }
}
