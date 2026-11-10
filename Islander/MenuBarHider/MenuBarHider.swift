import AppKit
import Observation
import os

private let log = Logger(subsystem: "com.kadaliao.islander", category: "hider")

/// 用"永远隐藏分隔符 + 分隔符 + 开关"三个状态栏图标隐藏菜单栏图标。
///
///     [永远隐藏的图标…] ⋮ [藏到岛上的图标…] |  [常显图标…]  ◖岛民◗  [系统图标]
///                      ↑ 永远隐藏分隔符     ↑ 分隔符                ↑ 开关
///
/// 隐藏时把分隔符的长度设成 10000，它左边的图标全被挤出屏幕；显示时恢复成一条细线。
/// 有永远隐藏的图标时，永远隐藏分隔符一直是 10000 长：用户点开关"显示藏起来的图标"时，它左边的图标仍然在屏幕外。
/// 只有在设置里调整布局、或者打开一个只能在菜单栏里点开的永远隐藏图标时，才临时缩回细线。
/// 没有永远隐藏的图标时它缩成一段看不见的空白（新出现的图标可能落在它左边，不能把它们一直挤在屏幕外）。
/// 哪些图标在分隔符左边，由用户在设置的「菜单栏布局」里调整（MenuBarItemMover 替用户 ⌘ 拖动），
/// 或者用户自己按住 ⌘ 拖动（系统原生行为）；位置由系统按 autosaveName 记住；
/// 显示 / 隐藏状态由我们存在 UserDefaults 里，重启后恢复。
@MainActor
@Observable
final class MenuBarHider: NSObject {
    static let shared = MenuBarHider()

    private enum Name {
        static let toggle = "IslanderToggle"
        static let separator = "IslanderSeparator"
        static let alwaysHidden = "IslanderAlwaysHiddenSeparator"
        static let collector = "IslanderCollector"
    }
    private static let hiddenKey = "menuBarItemsHidden"

    /// 隐藏时分隔符的长度：足够把它左边的所有图标挤出任何屏幕
    private static let hidingLength: CGFloat = 10_000
    private static let separatorLength: CGFloat = 12

    private(set) var isHidden = false
    /// 点击岛上图标、调整布局期间，临时把图标露出来
    private(set) var isTemporarilyRevealed = false
    /// 临时露出时连永远隐藏的也露出来
    @ObservationIgnored private var temporarilyRevealsAlwaysHidden = false
    /// 用户放了图标进"永远隐藏"（由 HiddenItemsStore 扫描后告知）
    @ObservationIgnored var hasAlwaysHiddenItems = false {
        didSet { if hasAlwaysHiddenItems != oldValue { applyLengths() } }
    }

    /// 图标位置发生变化（显示 / 隐藏切换）后调用，用来刷新岛上的内容
    @ObservationIgnored var onLayoutChange: (() -> Void)?
    /// 启动时分隔符就位、隐藏状态恢复完成后调用一次。在这之前扫描会拿到位置正在变化的快照
    @ObservationIgnored var onReady: (() -> Void)? {
        didSet { if isReady { onReady?() } }
    }
    private(set) var isReady = false

    @ObservationIgnored private var toggleItem: NSStatusItem?
    @ObservationIgnored private var separatorItem: NSStatusItem?
    @ObservationIgnored private var alwaysHiddenItem: NSStatusItem?
    @ObservationIgnored private var contextMenu: NSMenu?
    @ObservationIgnored private var ignoresToggleClicksUntil = Date.distantPast
    @ObservationIgnored private var collectorItem: NSStatusItem?
    /// 上一次由我们写下的收纳符首选位置
    @ObservationIgnored private var collectorPosition: CGFloat?

    private override init() {}

    func start(contextMenu: NSMenu) {
        guard toggleItem == nil else { return }
        self.contextMenu = contextMenu

        // 开关放最右（位置 0 = 紧挨系统图标）。
        // 分隔符首次放在当前可见图标的最左边：一开始什么都不隐藏，用户把想藏的图标 ⌘ 拖到它左边。
        // （不能依赖"新图标默认在最左边"：装了 Bartender 等工具时，最左边是它们挤到屏幕外的区域。）
        Self.presetPreferredPosition(0, for: Name.toggle)
        if let position = Self.leftmostVisiblePosition() {
            Self.presetPreferredPosition(position, for: Name.separator)
        }
        // 永远隐藏分隔符首次放在最左边：一开始没有永远隐藏的图标
        Self.presetPreferredPosition(Self.leftmostPosition, for: Name.alwaysHidden)

        let toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        toggle.autosaveName = Name.toggle
        toggle.isVisible = true
        if let button = toggle.button {
            button.target = self
            button.action = #selector(toggleClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "点按：显示 / 隐藏图标\n右键：菜单"
            button.setAccessibilityIdentifier(MenuBarScanner.toggleIdentifier)
        }
        toggleItem = toggle

        createSeparator()
        createAlwaysHiddenSeparator()
        applyLengths()

        // 新建的图标要过一会儿才排进菜单栏，排好后再检查位置、恢复隐藏状态
        Task {
            var attempts = 0
            while Self.settledFrames([alwaysHiddenItem, separatorItem, toggleItem]) == nil, attempts < 60 {
                attempts += 1
                try? await Task.sleep(for: .milliseconds(50))
            }
            finishSetup()
        }
    }

    /// 图标在菜单栏里的真实窗口帧（AppKit 坐标），还没排好时返回 nil。
    ///
    /// 新建的图标会先给出 (0,0,w,0)、(0,-30,w,30) 这样的占位帧，约 150ms 后才是真实位置；
    /// 占位帧没有可靠的标记（-30 那个还恰好贴着内置屏顶边、被报告为可见）。
    /// 所以只认窗口服务器里确实存在、位置大小都一致的菜单栏窗口（macOS 26 上这些窗口归 Control Center）。
    private static func settledFrames(_ items: [NSStatusItem?]) -> [CGRect]? {
        guard let primary = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        let statusLayer = Int(CGWindowLevelForKey(.statusWindow))
        let barWindows: [CGRect] = windows.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == statusLayer,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary
            else { return nil }
            return CGRect(dictionaryRepresentation: bounds)
        }

        var frames: [CGRect] = []
        for item in items {
            guard let frame = item?.button?.window?.frame, frame.height > 0 else { return nil }
            // AppKit 坐标（原点在主屏左下）→ CG 坐标（原点在主屏左上）
            let flipped = CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY,
                                 width: frame.width, height: frame.height)
            let matched = barWindows.contains {
                abs($0.minX - flipped.minX) < 0.5 && abs($0.minY - flipped.minY) < 0.5
                    && abs($0.width - flipped.width) < 0.5 && abs($0.height - flipped.height) < 0.5
            }
            guard matched else { return nil }
            frames.append(frame)
        }
        return frames
    }

    private func createSeparator() {
        let separator = NSStatusBar.system.statusItem(withLength: Self.separatorLength)
        separator.autosaveName = Name.separator
        separator.isVisible = true
        if let button = separator.button {
            button.toolTip = "这条线左边的图标会藏到岛上。在岛民设置的「菜单栏布局」里调整，或按住 ⌘ 拖动图标"
            (button.cell as? NSButtonCell)?.highlightsBy = []
            // 扫描器靠这个标识在辅助功能树里找到分隔符，据此判断哪些图标被隐藏
            button.setAccessibilityIdentifier(MenuBarScanner.separatorIdentifier)
        }
        separatorItem = separator
    }

    private func createAlwaysHiddenSeparator() {
        let separator = NSStatusBar.system.statusItem(withLength: Self.hidingLength)
        separator.autosaveName = Name.alwaysHidden
        separator.isVisible = true
        if let button = separator.button {
            button.toolTip = "这条线左边的图标永远隐藏，岛上也不显示（按住 ⌥ 再移到刘海上才显示）"
            (button.cell as? NSButtonCell)?.highlightsBy = []
            button.setAccessibilityIdentifier(MenuBarScanner.alwaysHiddenSeparatorIdentifier)
        }
        alwaysHiddenItem = separator
    }

    private func finishSetup() {
        let frames = Self.settledFrames([separatorItem, toggleItem])
        log.info("图标已排好：分隔符 / 开关 = \(String(describing: frames), privacy: .public)")

        // 分隔符落到了屏幕外（被其他隐藏工具的区域吞掉等），用户就找不到它了：挪到开关左边
        // 只看水平方向：前台是全屏 App 时菜单栏自动隐藏，图标停在屏幕顶边上方，那不算屏幕外
        if let frame = frames?.first,
           !NSScreen.screens.contains(where: { screen in
               frame.minX >= screen.frame.minX - 1 && frame.maxX <= screen.frame.maxX + 1
                   && frame.minY >= screen.frame.minY && frame.minY <= screen.frame.maxY + 1
           }) {
            log.notice("分隔符在屏幕外 \(String(describing: frame), privacy: .public)，挪到开关左边")
            moveSeparator(to: positionLeftOfToggle() ?? 1)
        }

        // 永远隐藏分隔符必须在分隔符左边，否则它会把该藏到岛上的、甚至常显的图标一起挤出屏幕：放回最左边
        if let frames = Self.settledFrames([alwaysHiddenItem, separatorItem]), frames[0].maxX > frames[1].minX + 1 {
            log.notice("永远隐藏分隔符跑到了分隔符右边，放回最左边")
            if let alwaysHiddenItem { NSStatusBar.system.removeStatusItem(alwaysHiddenItem) }
            UserDefaults.standard.set(Self.leftmostPosition, forKey: Self.preferredPositionKey(Name.alwaysHidden))
            createAlwaysHiddenSeparator()
            applyLengths()
        }

        createCollectorIfNeeded()
        applyLengths()
        let restoreHidden = UserDefaults.standard.bool(forKey: Self.hiddenKey)
        if restoreHidden {
            setHidden(true, interactive: false)
        }
        // 刚改完分隔符长度，图标还要约 150ms 才移到位
        Task {
            if restoreHidden { try? await Task.sleep(for: .milliseconds(400)) }
            isReady = true
            onReady?()
        }
    }

    func toggle() {
        setHidden(!isHidden, interactive: true)
    }

    func setHidden(_ hidden: Bool, interactive: Bool) {
        if hidden, !isOrderValid {
            log.error("分隔符在开关右边，拒绝隐藏")
            if interactive { warnWrongOrder() }
            return
        }
        isHidden = hidden
        isTemporarilyRevealed = false
        temporarilyRevealsAlwaysHidden = false
        UserDefaults.standard.set(hidden, forKey: Self.hiddenKey)
        applyLengths()
        log.info("菜单栏图标 \(hidden ? "隐藏" : "显示", privacy: .public)")
        onLayoutChange?()
    }

    /// 临时露出被隐藏的图标（不改变、不保存隐藏状态）
    /// - Parameter includingAlwaysHidden: 连永远隐藏的也露出来
    func beginTemporaryReveal(includingAlwaysHidden: Bool = false) {
        guard isHidden || includingAlwaysHidden, !isTemporarilyRevealed else { return }
        isTemporarilyRevealed = true
        temporarilyRevealsAlwaysHidden = includingAlwaysHidden
        applyLengths()
    }

    /// 结束临时露出：恢复成原来的显示 / 隐藏状态
    func endTemporaryReveal() {
        guard isTemporarilyRevealed else { return }
        isTemporarilyRevealed = false
        temporarilyRevealsAlwaysHidden = false
        applyLengths()
        onLayoutChange?()
    }

    /// 退出前把分隔符恢复成正常长度，避免系统在超长状态下记录位置
    func prepareForTermination() {
        separatorItem?.length = Self.separatorLength
        alwaysHiddenItem?.length = Self.separatorLength
        collectorItem?.length = Self.separatorLength
    }

    /// 分隔符在菜单栏里的真实位置（AppKit 坐标），阶段 3 用来区分哪些图标被隐藏
    var separatorFrame: CGRect? {
        Self.settledFrames([separatorItem])?.first
    }

    // MARK: - 显示全部图标

    /// "在岛上显示全部图标"：菜单栏上的图标也全收到岛上，菜单栏上不再留一份
    /// （留在菜单栏上的图标，从岛上点开时弹窗会先在真实图标下出现、再跳到岛下面）。
    ///
    /// 不动用户的分隔符（系统记的首选位置数值不可靠，挪过去就放不回原处），而是在开关左边另放一个"收纳符"：
    /// 平时不存在；打开这个模式并且图标藏着的时候伸到一万 pt 长，把分隔符和开关之间的图标也挤出屏幕。
    /// 这些图标仍然算"菜单栏上的"（在分隔符右边），关掉模式它们原样回来。
    var collectsAll = false {
        didSet {
            guard collectsAll != oldValue, toggleItem != nil else { return }
            if isReady { createCollectorIfNeeded() }
            applyLengths()
            onLayoutChange?()
        }
    }

    /// 收纳符没落在紧挨开关左边的位置：往左（正数）或往右（负数）挪一点
    func nudgeCollector(by delta: CGFloat) {
        guard let collectorItem else { return }
        let key = Self.preferredPositionKey(Name.collector)
        let position = collectorPosition ?? CGFloat(UserDefaults.standard.double(forKey: key))
        NSStatusBar.system.removeStatusItem(collectorItem)
        createCollector(at: max(position + delta, 1))
        applyLengths()
    }

    /// 以前建过（系统记着它的位置）就接着用，没建过的放在开关左边。要等开关排好位置才能算
    private func createCollectorIfNeeded() {
        guard collectsAll, collectorItem == nil else { return }
        let known = UserDefaults.standard.object(forKey: Self.preferredPositionKey(Name.collector)) != nil
        createCollector(at: known ? nil : positionLeftOfToggle())
    }

    private func createCollector(at position: CGFloat?) {
        if let position {
            UserDefaults.standard.set(position, forKey: Self.preferredPositionKey(Name.collector))
            collectorPosition = position
        }
        let collector = NSStatusBar.system.statusItem(withLength: Self.separatorLength)
        collector.autosaveName = Name.collector
        if let button = collector.button {
            (button.cell as? NSButtonCell)?.highlightsBy = []
            button.setAccessibilityIdentifier(MenuBarScanner.collectorIdentifier)
        }
        collectorItem = collector
    }

    /// 分隔符换位置：系统没有移动状态栏图标的接口，删掉、写好首选位置再建一个
    private func moveSeparator(to position: CGFloat) {
        if let separatorItem { NSStatusBar.system.removeStatusItem(separatorItem) }
        UserDefaults.standard.set(position, forKey: Self.preferredPositionKey(Name.separator))
        createSeparator()
        applyLengths()
        onLayoutChange?()
    }

    /// 紧挨着开关左边的首选位置（和 leftmostVisiblePosition 同一个算法：比开关的左边缘稍微往右一点）
    private func positionLeftOfToggle() -> CGFloat? {
        guard let frame = Self.settledFrames([toggleItem])?.first,
              let screen = NSScreen.screens.first(where: { $0.frame.minX <= frame.midX && frame.midX <= $0.frame.maxX })
        else { return nil }
        return max(screen.frame.maxX - frame.minX - 12, 1)
    }

    /// 开关图标在某一行菜单栏（顶边 CG y 坐标）里的窗口。多屏时每一行各有一个
    func toggleWindow(inRowTop top: CGFloat) -> StatusBarRows.Window? {
        guard let frame = Self.settledFrames([toggleItem])?.first, let primary = NSScreen.screens.first else { return nil }
        let center = CGPoint(x: frame.midX, y: primary.frame.maxY - frame.midY)
        let rows = StatusBarRows.current()
        return rows.window(containing: center).flatMap { rows.counterpart(of: $0, inRowTop: top) }
    }

    /// 接下来一小段时间不响应对开关的点击（岛民自己为了切换活动菜单栏往它身上发了一次点击）
    func ignoreToggleClicks(for duration: TimeInterval) {
        ignoresToggleClicksUntil = Date().addingTimeInterval(duration)
    }

    // MARK: - 私有

    /// 按当前状态设置两条分隔符的长度和开关的样子
    private func applyLengths() {
        let showsHidden = !isHidden || isTemporarilyRevealed
        let showsAlwaysHidden = showsHidden && (!hasAlwaysHiddenItems
            || (isTemporarilyRevealed && temporarilyRevealsAlwaysHidden))
        separatorItem?.length = showsHidden ? Self.separatorLength : Self.hidingLength
        separatorItem?.button?.image = showsHidden ? Self.separatorImage : nil
        alwaysHiddenItem?.length = showsAlwaysHidden ? Self.separatorLength : Self.hidingLength
        // 只在全部露出（调整布局等）时画出来；平时就算缩成细线也不显示，菜单栏上不多一个记号
        let revealsAll = isTemporarilyRevealed && temporarilyRevealsAlwaysHidden
        alwaysHiddenItem?.button?.image = revealsAll ? Self.alwaysHiddenImage : nil
        // 收纳符：只在"显示全部图标"时存在；图标藏着时伸长，把分隔符右边的图标也挤出屏幕
        collectorItem?.isVisible = collectsAll
        collectorItem?.length = collectsAll && !showsHidden ? Self.hidingLength : Self.separatorLength

        let hidden = isHidden
        let symbol = hidden ? "capsule.fill" : "capsule"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: hidden ? "显示隐藏的图标" : "隐藏图标")
        image?.isTemplate = true
        toggleItem?.button?.image = image
    }

    /// 分隔符必须在开关左边，否则隐藏时开关会被一起挤出屏幕，用户就没法再点回来
    private var isOrderValid: Bool {
        guard let frames = Self.settledFrames([separatorItem, toggleItem]) else {
            return true  // 还没排好位置，无从判断
        }
        return frames[0].maxX <= frames[1].minX + 1
    }

    @objc private func toggleClicked() {
        guard Date() >= ignoresToggleClicksUntil, let event = NSApp.currentEvent else { return }
        let wantsMenu = event.type == .rightMouseUp
            || event.modifierFlags.contains(.control)
            || event.modifierFlags.contains(.option)
        if wantsMenu {
            showContextMenu()
        } else {
            toggle()
        }
    }

    private func showContextMenu() {
        guard let toggleItem, let contextMenu else { return }
        // 临时挂上菜单再模拟点击：菜单会出现在图标正下方，关闭后再摘掉，左键仍然是切换
        toggleItem.menu = contextMenu
        toggleItem.button?.performClick(nil)
        toggleItem.menu = nil
    }

    private func warnWrongOrder() {
        let alert = NSAlert()
        alert.messageText = "分隔符跑到了岛民图标的右边"
        alert.informativeText = "这样隐藏会把岛民图标自己也藏起来。请按住 ⌘，把细竖线「|」拖回岛民图标的左边，再试一次。"
        alert.addButton(withTitle: "好")
        NSApp.activate()
        alert.runModal()
    }

    // MARK: - 首选位置

    /// 系统按 autosaveName 记住每个状态栏图标的位置，值大致是"离屏幕右边缘多远"，越大越靠左。
    private static func preferredPositionKey(_ autosaveName: String) -> String {
        "NSStatusItem Preferred Position \(autosaveName)"
    }

    /// 比任何图标都靠左的首选位置
    private static let leftmostPosition: CGFloat = 20_000

    private static func presetPreferredPosition(_ position: CGFloat, for autosaveName: String) {
        let key = preferredPositionKey(autosaveName)
        if UserDefaults.standard.object(forKey: key) == nil {
            UserDefaults.standard.set(position, forKey: key)
        }
    }

    /// 主屏菜单栏上最左边那个可见图标对应的首选位置。
    /// 读窗口位置不需要屏幕录制权限；只在首次启动调用一次。
    private static func leftmostVisiblePosition() -> CGFloat? {
        guard let primary = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        let screenWidth = primary.frame.width
        let statusLayer = Int(CGWindowLevelForKey(.statusWindow))
        var leftmost: CGFloat?
        for info in windows {
            guard (info[kCGWindowLayer as String] as? Int) == statusLayer,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  // 主屏菜单栏（CG 坐标原点在主屏左上角），且整个在屏幕内
                  rect.minY == 0, rect.minX >= 0, rect.maxX <= screenWidth, rect.height <= 60
            else { continue }
            leftmost = min(leftmost ?? rect.minX, rect.minX)
        }
        guard let leftmost else { return nil }
        // 比最左图标的左边缘稍微往右一点：排序时落在它左边，又不会越过其他工具的隐藏区
        return max(screenWidth - leftmost - 12, 1)
    }

    /// 永远隐藏分隔符：竖着三个点，和分隔符的细线区分开
    private static let alwaysHiddenImage: NSImage = {
        let image = NSImage(size: NSSize(width: 6, height: 16), flipped: false) { rect in
            NSColor.black.setFill()
            for y in [3.0, 7.0, 11.0] {
                NSBezierPath(ovalIn: NSRect(x: (rect.width - 2.2) / 2, y: y, width: 2.2, height: 2.2)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()

    private static let separatorImage: NSImage = {
        let image = NSImage(size: NSSize(width: 6, height: 16), flipped: false) { rect in
            let bar = NSRect(x: (rect.width - 1.5) / 2, y: 1, width: 1.5, height: rect.height - 2)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 0.75, yRadius: 0.75).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
