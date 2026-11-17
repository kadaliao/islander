import AppKit
import Observation
import os

private let log = Logger(subsystem: "com.kadaliao.islander", category: "hider")

/// 用"永远隐藏分隔符 + 分隔符 + 岛民图标"三个状态栏图标隐藏菜单栏图标。
///
///     [永远隐藏的图标…] ⋮ [藏到岛上的图标…] |  [常显图标…]  ◖岛民◗  [系统图标]
///                      ↑ 永远隐藏分隔符     ↑ 分隔符                ↑ 岛民图标
///
/// 分隔符一直是 10000 长，它左边的图标全被挤出屏幕：藏到岛上的图标只在岛上出现，菜单栏上不再露出来。
/// 只有替用户移动图标（MenuBarItemMover）、或者打开一个只能在菜单栏里点开的图标（ClickForwarder）时，
/// 才临时缩回细线。
/// 永远隐藏分隔符在有永远隐藏的图标时同样一直是 10000 长；
/// 没有永远隐藏的图标时缩成一段看不见的空白（新出现的图标可能落在它左边，不能把它们一直挤在屏幕外）。
/// 哪些图标在分隔符左边，由用户在设置的「菜单栏布局」里调整（MenuBarItemMover 替用户 ⌘ 拖动），
/// 或者用户自己按住 ⌘ 把菜单栏上的图标拖到左边（系统原生行为）；位置由系统按 autosaveName 记住。
/// 点岛民图标（左键右键都一样）打开岛民的菜单。
///
/// macOS 27 起菜单栏由 MenuBarAgent 统一排版，规矩变了（实测 27.3）：
/// - 超过约半个屏幕宽的状态栏图标会被直接无视，不占位置，10000 长的分隔符什么也挤不走；
/// - 放不下的图标不再被挤出屏幕，而是收进系统的「«」按钮里；从放不下的那个起，它左边的全都收进去。
/// 所以隐藏时分隔符只伸到系统还认的长度，并在它右边紧挨着放一个"垫片"：
/// 垫片放得下，分隔符就放不下，分隔符连同左边的图标一起收进「«」；垫片也放不下，就连它一起收进去。
/// 垫片不能把左边的空位占满：系统的「屏幕共享」等提示胶囊和「«」也排在垫片左边，放不下就没了，
/// 所以垫片按前台 App 菜单（有刘海时是刘海）右边到分隔符之间的距离算，留出一段给它们；
/// 没刘海的屏幕上让它们贴着岛民画的虚拟岛，不至于离得老远或者被岛盖住。
/// 收进去的图标在辅助功能里就没有了，由 HiddenItemsStore 记着。
@MainActor
@Observable
final class MenuBarHider: NSObject {
    static let shared = MenuBarHider()

    private enum Name {
        static let toggle = "IslanderToggle"
        static let separator = "IslanderSeparator"
        static let alwaysHidden = "IslanderAlwaysHiddenSeparator"
        static let collector = "IslanderCollector"
        /// macOS 27：紧挨在分隔符 / 收纳符右边的垫片
        static let separatorPad = "IslanderSeparatorPad"
        static let collectorPad = "IslanderCollectorPad"
    }

    /// macOS 27 起菜单栏放不下的图标收进「«」，不再能挤出屏幕
    static let hidesByOverflow = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    /// 以前版本存的"图标藏没藏起来"，现在一直藏着，启动时清掉
    private static let legacyHiddenKey = "menuBarItemsHidden"

    /// 隐藏时分隔符的长度：足够把它左边的所有图标挤出任何屏幕。
    /// macOS 27 上超过约半屏宽的图标会被系统无视（1920 宽的屏幕上 940 管用、950 就不管用了），
    /// 按最窄的屏幕留出余量
    private static var hidingLength: CGFloat {
        guard hidesByOverflow else { return 10_000 }
        let narrowest = NSScreen.screens.map(\.frame.width).min() ?? 1440
        return max((narrowest / 2).rounded(.down) - 40, 200)
    }
    private static let separatorLength: CGFloat = 12

    /// 点击岛上图标、调整布局期间，临时把图标露出来
    private(set) var isTemporarilyRevealed = false
    /// 临时露出时连永远隐藏的也露出来
    @ObservationIgnored private var temporarilyRevealsAlwaysHidden = false
    /// 用户放了图标进"永远隐藏"（由 HiddenItemsStore 扫描后告知）
    @ObservationIgnored var hasAlwaysHiddenItems = false {
        didSet { if hasAlwaysHiddenItems != oldValue { applyLengths() } }
    }

    /// 图标位置发生变化（临时露出结束、分隔符换了位置）后调用，用来刷新岛上的内容
    @ObservationIgnored var onLayoutChange: (() -> Void)?
    /// 启动时分隔符就位、图标藏好后调用一次。在这之前扫描会拿到位置正在变化的快照
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
    @ObservationIgnored private var separatorPad: NSStatusItem?
    @ObservationIgnored private var collectorPad: NSStatusItem?
    /// 上一次真正改动长度的时间：之后要过一会儿菜单栏才排好、辅助功能的位置才跟上
    @ObservationIgnored private(set) var lastLengthChange = Date.distantPast
    @ObservationIgnored private var appliedLengths: [CGFloat] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// macOS 27：分隔符、收纳符的垫片在菜单栏上的右端（CG x），垫片从这里往左伸。永远隐藏分隔符没有垫片，记它缩成细线时的右边缘
    @ObservationIgnored private var separatorRightEdge: CGFloat?
    @ObservationIgnored private var collectorRightEdge: CGFloat?
    @ObservationIgnored private var alwaysHiddenRightEdge: CGFloat?
    /// macOS 27：分隔符、收纳符和各自垫片之间隔着的图标的宽度（AppKit 窗口之间的空当）
    @ObservationIgnored private var separatorPadGap: CGFloat = 0
    @ObservationIgnored private var collectorPadGap: CGFloat = 0
    /// 上一次设长度时哪些图标在菜单栏上
    @ObservationIgnored private var appliedShows = (hidden: false, alwaysHidden: false)
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
            // 按下就打开菜单，和系统的菜单栏图标一样
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.toolTip = "岛民"
            button.setAccessibilityIdentifier(MenuBarScanner.toggleIdentifier)
        }
        toggleItem = toggle

        createSeparator()
        createAlwaysHiddenSeparator()
        applyLengths()

        if Self.hidesByOverflow {
            // 隐藏时的长度跟着屏幕宽度走，垫片还跟着前台 App 菜单的宽度走
            observers.append(NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { MenuBarHider.shared.applyLengths() }
            })
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { MenuBarHider.shared.applyLengths() }
            })
        }

        // 新建的图标要过一会儿才排进菜单栏，排好后再检查位置、把图标藏起来。
        // macOS 27 上永远隐藏分隔符这时可能已经伸长、收进了「«」，不等它
        let awaited = Self.hidesByOverflow ? [separatorItem, toggleItem] : [alwaysHiddenItem, separatorItem, toggleItem]
        Task {
            var attempts = 0
            while Self.settledFrames(awaited) == nil, attempts < 60 {
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
        if hidesByOverflow { return laidOutFrames(items) }
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

    /// macOS 27：窗口服务器里没有单个图标的窗口了，只能看 AppKit 给的位置。
    /// 占位帧（(0,0,w,0)、(0,-30,w,30)）的顶边不贴着屏幕顶边，据此排除
    private static func laidOutFrames(_ items: [NSStatusItem?]) -> [CGRect]? {
        var frames: [CGRect] = []
        for item in items {
            guard let frame = item?.button?.window?.frame, frame.width > 0, frame.height > 0,
                  let cg = cgFrame(item),
                  NSScreen.screens.contains(where: { screen in
                      let top = (NSScreen.screens.first?.frame.maxY ?? 0) - screen.frame.maxY
                      return abs(cg.minY - top) < 1 && cg.midX >= screen.frame.minX && cg.midX <= screen.frame.maxX
                  })
            else { return nil }
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
        separatorPad = createPad(Name.separatorPad, rightOf: Name.separator, replacing: separatorPad)
    }

    /// macOS 27：在某个图标右边紧挨着放一个垫片（见类型说明）。平时长度为 0，隐藏时伸长。
    /// 系统按首选位置排序，比那个图标的首选位置小一点就紧挨在它右边
    /// - Parameter neighborFrame: 那个图标排好后的位置（AppKit 坐标）。系统还没记下它的首选位置时（首次启动），按它算
    private func createPad(_ name: String, rightOf neighbor: String, replacing old: NSStatusItem?,
                           at position: CGFloat? = nil, neighborFrame: CGRect? = nil) -> NSStatusItem? {
        guard Self.hidesByOverflow else { return nil }
        if let old { NSStatusBar.system.removeStatusItem(old) }
        let neighborPosition = UserDefaults.standard.double(forKey: Self.preferredPositionKey(neighbor))
        // 删掉再建同名图标时系统会把记着的首选位置也删掉（实测 27.3：建的那一刻读到了，之后就没了），
        // 找到的数值另外记一份，每次建之前写回去
        if let position = position ?? Self.savedPadPosition(name) {
            UserDefaults.standard.set(position, forKey: Self.preferredPositionKey(name))
        } else if neighborPosition > 0 {
            // 收纳符和开关之间只差 1，取一半
            UserDefaults.standard.set(max(neighborPosition - 0.5, 0.25), forKey: Self.preferredPositionKey(name))
        } else if let neighborFrame,
                  let screen = NSScreen.screens.first(where: { $0.frame.minX <= neighborFrame.midX && neighborFrame.midX <= $0.frame.maxX }) {
            // 首选位置大致是"左边缘离屏幕右边缘多远"：取那个图标右边缘再往左一点，排在它和右边的图标之间
            UserDefaults.standard.set(max(screen.frame.maxX - neighborFrame.maxX + 2, 0.5),
                                      forKey: Self.preferredPositionKey(name))
        }
        // 来回切 isVisible 会让它丢掉位置（实测），一直显示着，只改长度
        UserDefaults.standard.removeObject(forKey: Self.visibleKey(name))
        // 别的图标跟着挪位置，AppKit 报告的位置要过一会儿才跟上
        lastLengthChange = Date()
        let pad = NSStatusBar.system.statusItem(withLength: 0)
        pad.autosaveName = name
        pad.isVisible = true
        if let button = pad.button {
            (button.cell as? NSButtonCell)?.highlightsBy = []
            // 按名字区分两个垫片，settlePad 从辅助功能里读它们的位置
            button.setAccessibilityIdentifier(name)
        }
        return pad
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
        } else if let frames, frames[0].maxX > frames[1].minX + 1 {
            // 分隔符跑到了开关右边（用户 ⌘ 拖过）：伸长后会把开关自己也挤出屏幕，再也点不到。挪回开关左边
            log.notice("分隔符在开关右边，挪到开关左边")
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

        UserDefaults.standard.removeObject(forKey: Self.legacyHiddenKey)
        Task {
            // 垫片必须紧挨在分隔符右边，中间夹着的图标会被一起收走。这时图标都还排在菜单栏上，位置读得准
            if Self.hidesByOverflow {
                await settlePad(Name.separatorPad, rightOf: \.separatorItem,
                                identifier: MenuBarScanner.separatorIdentifier, pad: \.separatorPad)
                // 等 AppKit 报告的位置跟上，applyLengths 要量垫片的右端和它与分隔符之间的空当
                try? await Task.sleep(for: .milliseconds(400))
            }
            createCollectorIfNeeded()
            isHiding = true
            applyLengths()
            // 刚改完分隔符长度，图标还要约 150ms 才移到位
            try? await Task.sleep(for: .milliseconds(400))
            isReady = true
            onReady?()
        }
    }

    /// macOS 27：把垫片挪到 neighbor 右边。首选位置只在新建时读，按新建那一刻的排布换算，和像素对不上，
    /// 首次建的垫片常常落在分隔符左边（实测 27.3）。在左边就换个更小的数值重建（越小越靠右），二分着往分隔符靠。
    /// 不一定能紧挨着：有的排布里分隔符右边那几个空当怎么给数值都落不进去。隔着的图标本来就在分隔符右边、算常显，
    /// 垫片伸长时让出它们的宽度就行（见 padGaps）。只在图标都排在菜单栏上（没收进「«」）时调用
    private func settlePad(_ name: String, rightOf neighbor: KeyPath<MenuBarHider, NSStatusItem?>,
                           identifier neighborIdentifier: String,
                           pad: ReferenceWritableKeyPath<MenuBarHider, NSStatusItem?>) async {
        var low: CGFloat = 0
        var high: CGFloat?
        // 建垫片时用的数值。不能回头读系统记的那份，它可能已经被删了
        var current = Self.savedPadPosition(name)
            ?? CGFloat(UserDefaults.standard.double(forKey: Self.preferredPositionKey(name)))
        /// 落在右边的数值里离 neighbor 最近的一个
        var best: (position: CGFloat, gap: CGFloat)?
        var lastPad: CGRect?
        for attempt in 0..<10 {
            guard let frames = await stableFrames(neighbor, neighborIdentifier, pad, name) else {
                log.error("垫片 \(name, privacy: .public) 没排好，不调了")
                return
            }
            let gap = frames.pad.minX - frames.neighbor.maxX - frames.adjacentGap
            // 换了数值重建，位置却没变：再试也一样
            let stuck = lastPad == frames.pad
            lastPad = frames.pad
            if frames.pad.midX > frames.neighbor.midX {
                if best == nil || gap < best!.gap { best = (current, gap) }
                // 紧挨着了（中间最多夹着岛民自己一个 0 长的垫片，约 16），或者试不动了：就这样
                if gap <= 18 || stuck || attempt >= 5 {
                    if attempt > 0 {
                        log.notice("垫片 \(name, privacy: .public) 落在右边，隔着 \(Int(gap))，首选位置 \(current)")
                        Self.savePadPosition(current, for: name)
                    }
                    return
                }
                low = current
            } else {
                high = current
            }
            let next = high.map { (low + $0) / 2 } ?? current * 1.5 + 20
            if abs(next - current) < 0.25 || stuck || attempt >= 5 { break }
            log.notice("垫片 \(name, privacy: .public) 位置不对：\(String(describing: frames.neighbor), privacy: .public) / \(String(describing: frames.pad), privacy: .public)，首选位置 \(current) → \(next) 重建")
            current = next
            self[keyPath: pad] = createPad(name, rightOf: "", replacing: self[keyPath: pad], at: next)
        }
        // 最后一次落在了左边：退回到落在右边的那个数值
        guard let best else {
            log.error("垫片 \(name, privacy: .public) 找不到分隔符右边的位置")
            return
        }
        log.notice("垫片 \(name, privacy: .public) 退回首选位置 \(best.position)（隔着 \(Int(best.gap))）")
        self[keyPath: pad] = createPad(name, rightOf: "", replacing: self[keyPath: pad], at: best.position)
        Self.savePadPosition(best.position, for: name)
        _ = await stableFrames(neighbor, neighborIdentifier, pad, name)
    }

    /// 新建的图标要过一会儿才排好，别的图标也跟着挪：连续两次读到一样的位置才算数。
    /// 优先看辅助功能：刚重建的图标，AppKit 报告的窗口位置会旧一阵子。
    /// 辅助功能里相邻两个图标之间隔约 14，AppKit 的窗口是首尾相接的（adjacentGap）
    private func stableFrames(_ neighbor: KeyPath<MenuBarHider, NSStatusItem?>, _ neighborIdentifier: String,
                              _ pad: KeyPath<MenuBarHider, NSStatusItem?>, _ name: String) async
        -> (neighbor: CGRect, pad: CGRect, adjacentGap: CGFloat)? {
        var previous: (neighbor: CGRect, pad: CGRect, adjacentGap: CGFloat)?
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(150))
            var current: (neighbor: CGRect, pad: CGRect, adjacentGap: CGFloat)?
            let ax = await Self.ownAXFrames([neighborIdentifier, name])
            if let a = ax[neighborIdentifier], let b = ax[name] {
                current = (a, b, 14)
            } else if let frames = Self.laidOutFrames([self[keyPath: neighbor], self[keyPath: pad]]) {
                current = (frames[0], frames[1], 0)
            }
            if let current, let previous, current.neighbor == previous.neighbor, current.pad == previous.pad {
                return current
            }
            previous = current
        }
        return nil
    }

    /// 辅助功能报告的岛民自己的图标位置（CG 坐标），按标识。要在后台读：主线程得空着回答这些请求。
    /// 有的系统上辅助功能不报告岛民自己的图标（issue #1），这时是空的
    private nonisolated static func ownAXFrames(_ identifiers: [String]) async -> [String: CGRect] {
        await Task.detached {
            let app = AXUIElementCreateApplication(getpid())
            AXUIElementSetMessagingTimeout(app, 0.5)
            guard let bar = AX.element(app, "AXExtrasMenuBar") else { return [:] }
            var frames: [String: CGRect] = [:]
            for child in AX.elements(bar, kAXChildrenAttribute) {
                guard let id = AX.string(child, kAXIdentifierAttribute), identifiers.contains(id),
                      let frame = AX.frame(child) else { continue }
                frames[id] = frame
            }
            return frames
        }.value
    }

    /// 垫片找到的首选位置，岛民自己记的一份（系统那份会被删掉，见 createPad）
    private static func savedPadPosition(_ name: String) -> CGFloat? {
        (UserDefaults.standard.object(forKey: "IslanderPadPosition \(name)") as? Double).map { CGFloat($0) }
    }

    private static func savePadPosition(_ position: CGFloat, for name: String) {
        UserDefaults.standard.set(Double(position), forKey: "IslanderPadPosition \(name)")
        UserDefaults.standard.set(Double(position), forKey: preferredPositionKey(name))
    }

    /// macOS 27：收纳符排好以后，把它的垫片挪到紧挨它右边（HiddenItemsStore 临时放出图标时调用）
    func settleCollectorPad() async {
        guard Self.hidesByOverflow, collectorItem != nil else { return }
        await settlePad(Name.collectorPad, rightOf: \.collectorItem,
                        identifier: MenuBarScanner.collectorIdentifier, pad: \.collectorPad)
        applyLengths()
    }

    /// 临时露出被隐藏的图标
    /// - Parameter includingAlwaysHidden: 连永远隐藏的也露出来
    func beginTemporaryReveal(includingAlwaysHidden: Bool = false) {
        guard !isTemporarilyRevealed else { return }
        isTemporarilyRevealed = true
        temporarilyRevealsAlwaysHidden = includingAlwaysHidden
        applyLengths()
    }

    /// 结束临时露出：重新藏起来
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
        collectorItem?.length = collectsAll || !Self.hidesByOverflow ? Self.separatorLength : 0
        separatorPad?.length = 0
        collectorPad?.length = 0
    }

    /// 被隐藏的图标现在在不在菜单栏上（没收进「«」、没挤出屏幕）。macOS 27 上用来判断辅助功能报告的位置能不能拿来分区
    var showsHiddenItems: Bool { !isHiding || isTemporarilyRevealed }
    /// 永远隐藏的图标现在在不在菜单栏上
    var showsAlwaysHiddenItems: Bool {
        showsHiddenItems && (!hasAlwaysHiddenItems || (isTemporarilyRevealed && temporarilyRevealsAlwaysHidden))
    }

    /// 分隔符在菜单栏里的真实位置（AppKit 坐标），阶段 3 用来区分哪些图标被隐藏
    var separatorFrame: CGRect? {
        Self.settledFrames([separatorItem])?.first
    }

    /// 岛民自己几个图标的位置，CG 全局坐标（原点在主屏左上）
    struct OwnFrames: Sendable {
        var separator: CGRect?
        var alwaysHiddenSeparator: CGRect?
        var collector: CGRect?
        var toggle: CGRect?
    }

    /// 从 AppKit 读自己图标的位置：macOS 27 上辅助功能不再报告岛民自己的 AXExtrasMenuBar（issue #1），
    /// 扫描器读不到分隔符时拿它顶上。还没排好的占位帧不算
    var ownFrames: OwnFrames {
        OwnFrames(separator: Self.menuBarFrame(separatorItem),
                  alwaysHiddenSeparator: Self.menuBarFrame(alwaysHiddenItem),
                  collector: collectsAll ? Self.menuBarFrame(collectorItem) : nil,
                  toggle: Self.menuBarFrame(toggleItem))
    }

    /// AppKit 原样给出的位置，不做筛选：诊断信息用
    var ownFramesDescription: String {
        let items: [(String, NSStatusItem?)] = [
            ("分隔符", separatorItem), ("永远隐藏分隔符", alwaysHiddenItem), ("开关", toggleItem), ("收纳符", collectorItem),
        ] + (Self.hidesByOverflow ? [("分隔符垫片", separatorPad), ("收纳符垫片", collectorPad)] : [])
        return items.map { name, item in
            guard let item else { return "\(name) 没建" }
            guard let frame = Self.cgFrame(item) else { return "\(name) 没有窗口" }
            return "\(name) \(MoveDiagnostics.brief(frame))\(Self.menuBarFrame(item) == nil ? "（不在菜单栏上）" : "")"
        }.joined(separator: " · ")
    }

    /// 图标窗口的位置，AppKit 坐标（原点在主屏左下）→ CG 坐标（原点在主屏左上）
    private static func cgFrame(_ item: NSStatusItem?) -> CGRect? {
        guard let frame = item?.button?.window?.frame, let primary = NSScreen.screens.first else { return nil }
        return CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
    }

    /// 贴着某块屏幕顶边的才算排好了：新建的图标会先给出 (0,0,w,0)、(0,-30,w,30) 这样的占位帧
    private static func menuBarFrame(_ item: NSStatusItem?) -> CGRect? {
        guard let frame = cgFrame(item), frame.width > 0, frame.height > 0,
              let primaryTop = NSScreen.screens.first?.frame.maxY,
              NSScreen.screens.contains(where: { abs(frame.midY - (primaryTop - $0.frame.maxY)) <= 50 })
        else { return nil }
        return frame
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
            // macOS 27：别的图标收在「«」里时新建的图标会插错地方，等 HiddenItemsStore 临时放出图标时再建。
            // 关掉时直接删掉：留着的话哪怕 0 长也占一格，把提示胶囊往右挤；来回切 isVisible 又会丢位置
            if Self.hidesByOverflow, !collectsAll {
                removeCollector()
                // 菜单栏排好以后按分隔符垫片的新位置再算一遍
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(600))
                    self?.applyLengths()
                }
            } else if isReady, !Self.hidesByOverflow || showsHiddenItems {
                createCollectorIfNeeded()
            }
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

    /// macOS 27：收纳符现在的首选位置。排错了地方时 HiddenItemsStore 按它换个数值重建
    var collectorPreferredPosition: CGFloat {
        collectorPosition ?? CGFloat(UserDefaults.standard.double(forKey: Self.preferredPositionKey(Name.collector)))
    }

    private func removeCollector() {
        for item in [collectorItem, collectorPad].compactMap({ $0 }) { NSStatusBar.system.removeStatusItem(item) }
        collectorItem = nil
        collectorPad = nil
        collectorRightEdge = nil
        collectorPadGap = 0
        // 下次收纳符按新的数值建，它的垫片也重新找
        UserDefaults.standard.removeObject(forKey: "IslanderPadPosition \(Name.collectorPad)")
        // 别的图标跟着挪位置，AppKit 报告的位置要过一会儿才跟上
        lastLengthChange = Date()
    }

    /// macOS 27：按新的首选位置删掉重建收纳符和它的垫片（要在图标都排在菜单栏上时调用）
    func recreateCollector(at position: CGFloat) {
        guard Self.hidesByOverflow, collectsAll else { return }
        removeCollector()
        createCollector(at: max(position, 1))
        applyLengths()
    }

    /// 以前建过（系统记着它的位置）就接着用，没建过的放在开关左边。要等开关排好位置才能算
    func createCollectorIfNeeded() {
        guard collectsAll, collectorItem == nil else { return }
        if Self.hidesByOverflow {
            // macOS 27 只在新建图标时读首选位置，按新建那一刻的排布插进去：数值越大越靠左，
            // 但和离屏幕右边缘多远对不上（实测开关左边那个空当是 200 左右，开关自己记的是 461）。
            // 以前找到过合适的数值就接着用，没有就从开关右边缘离屏幕右边多远猜起，HiddenItemsStore 放出图标后核对、二分重建。
            // 别的图标收在「«」里时新建会插错地方，所以只在图标都排在菜单栏上时建
            let key = Self.preferredPositionKey(Name.collector)
            if UserDefaults.standard.object(forKey: key) != nil {
                createCollector(at: nil)
            } else if let frame = Self.settledFrames([toggleItem])?.first,
                      let screen = NSScreen.screens.first(where: { $0.frame.minX <= frame.midX && frame.midX <= $0.frame.maxX }) {
                createCollector(at: max(screen.frame.maxX - frame.maxX, 1))
            } else {
                createCollector(at: 200)
            }
            return
        }
        let known = UserDefaults.standard.object(forKey: Self.preferredPositionKey(Name.collector)) != nil
        createCollector(at: known ? nil : positionLeftOfToggle())
    }

    private func createCollector(at position: CGFloat?) {
        if let position {
            UserDefaults.standard.set(position, forKey: Self.preferredPositionKey(Name.collector))
            collectorPosition = position
        }
        // macOS 27：首选位置落在同一档的图标，后建的排在左边。先建垫片，收纳符才会在它左边
        collectorPad = createPad(Name.collectorPad, rightOf: Name.collector, replacing: collectorPad)
        // 以前隐藏过（isVisible = false）的话系统记着"不显示"，新建出来也看不见、位置也不对
        UserDefaults.standard.removeObject(forKey: Self.visibleKey(Name.collector))
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

    /// 启动时位置检查完之前不伸长分隔符：新建的图标还没排好，伸长了会把排错位置的图标（甚至开关）挤出屏幕
    @ObservationIgnored private var isHiding = false

    /// 按当前状态设置两条分隔符和收纳符的长度
    private func applyLengths() {
        let showsHidden = showsHiddenItems
        let showsAlwaysHidden = showsAlwaysHiddenItems
        let hidingLength = Self.hidingLength
        if Self.hidesByOverflow {
            applyOverflowLengths(showsHidden: showsHidden, showsAlwaysHidden: showsAlwaysHidden, cap: hidingLength)
        } else {
            separatorItem?.length = showsHidden ? Self.separatorLength : hidingLength
            alwaysHiddenItem?.length = showsAlwaysHidden ? Self.separatorLength : hidingLength
            collectorItem?.length = collectsAll && !showsHidden ? hidingLength : Self.separatorLength
        }
        separatorItem?.button?.image = showsHidden ? Self.separatorImage : nil
        // 只在全部露出（调整布局等）时画出来；平时就算缩成细线也不显示，菜单栏上不多一个记号
        let revealsAll = isTemporarilyRevealed && temporarilyRevealsAlwaysHidden
        alwaysHiddenItem?.button?.image = revealsAll ? Self.alwaysHiddenImage : nil
        // 收纳符：只在"显示全部图标"时存在；图标藏着时伸长，把分隔符右边的图标也挤出屏幕。
        // macOS 27 上来回切 isVisible 会丢掉位置（系统删掉记着的位置，下次出现在别处），建了就一直显示着，只改长度
        if !Self.hidesByOverflow { collectorItem?.isVisible = collectsAll }

        let lengths = [separatorItem, separatorPad, alwaysHiddenItem, collectorItem, collectorPad].map { $0?.length ?? -1 }
        if lengths != appliedLengths {
            appliedLengths = lengths
            lastLengthChange = Date()
        }

        if toggleItem?.button?.image == nil {
            let image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "岛民")
            image?.isTemplate = true
            toggleItem?.button?.image = image
        }
    }

    /// macOS 27 的长度（见类型说明）。分隔符不能一律伸到上限：比垫片左边剩下的空位长出太多，
    /// 系统就连提示胶囊都不显示了，所以只比剩下的空位长一点（见 overflowLengths）
    private func applyOverflowLengths(showsHidden: Bool, showsAlwaysHidden: Bool, cap: CGFloat) {
        // 缩着、排好了的时候记下右边缘，垫片从这里往左伸。
        // 窗口还是长的说明刚缩回来、还没排好（收进「«」时 AppKit 留着的是长条的旧位置）
        // 只认上一个状态里确实画在菜单栏上、并且排好了一会儿的：收在「«」里的 AppKit 位置不可信
        let settled = Date().timeIntervalSince(lastLengthChange) > 0.3
        func edge(_ item: NSStatusItem?, shown: Bool) -> CGFloat? {
            guard shown, settled, item?.length == Self.separatorLength else { return nil }
            return Self.laidOutFrames([item])?.first.flatMap { $0.width < 60 ? $0.maxX : nil }
        }
        // 垫片一直排在菜单栏上，它右边的图标不动它的右端就不动（伸长时往左长），比分隔符的位置可靠：
        // 分隔符只有露出来的时候才读得准，中间有图标进出（比如收纳符删掉了）又不会再露出来更新。
        // 垫片窗口比长度宽 16，菜单栏上画出来的右端在窗口右边缘往左 8
        func padEnd(_ pad: NSStatusItem?) -> CGFloat? {
            guard settled, let pad, let frame = Self.laidOutFrames([pad])?.first,
                  abs(frame.width - pad.length - 16) < 2 else { return nil }
            return frame.maxX - 8
        }
        // 分隔符和垫片之间隔着的图标（垫片没能紧挨着分隔符，见 settlePad）有多宽。露出来、排好了的时候量
        func gap(_ neighbor: NSStatusItem?, _ pad: NSStatusItem?, shown: Bool) -> CGFloat? {
            guard shown, settled, neighbor?.length == Self.separatorLength, pad?.length == 0,
                  let frames = Self.laidOutFrames([neighbor, pad]) else { return nil }
            return max(frames[1].minX - frames[0].maxX, 0)
        }
        // 有收纳符时它和它的垫片夹在分隔符垫片和开关之间，分隔符这边的位置都不是平时的，不记
        if collectorItem == nil, collectorPad == nil {
            separatorRightEdge = padEnd(separatorPad)
                ?? edge(separatorItem, shown: appliedShows.hidden).map { $0 + 8 } ?? separatorRightEdge
            separatorPadGap = gap(separatorItem, separatorPad, shown: appliedShows.hidden) ?? separatorPadGap
        }
        alwaysHiddenRightEdge = edge(alwaysHiddenItem, shown: appliedShows.alwaysHidden) ?? alwaysHiddenRightEdge
        if collectsAll {
            collectorRightEdge = padEnd(collectorPad)
                ?? edge(collectorItem, shown: appliedShows.hidden).map { $0 + 8 } ?? collectorRightEdge
            collectorPadGap = gap(collectorItem, collectorPad, shown: appliedShows.hidden) ?? collectorPadGap
        }
        appliedShows = (showsHidden, showsAlwaysHidden)

        // 显示全部图标时收纳符把分隔符连同它左边的一起收走，分隔符不用伸长（收进去的长条会让「«」和提示胶囊消失）
        let collecting = collectsAll && !showsHidden
        let separator = overflowLengths(rightEdge: separatorRightEdge, gap: separatorPadGap, cap: cap)
        separatorItem?.length = showsHidden || collecting ? Self.separatorLength : separator.spacer
        separatorPad?.length = showsHidden || collecting ? 0 : separator.pad
        // 永远隐藏分隔符在分隔符左边，全藏着时跟着一起收进去，不用伸长；
        // 只露出藏到岛上的图标时（点岛上的图标）才要靠它自己放不下，把永远隐藏的图标留在「«」里
        let alwaysHidden = overflowLengths(rightEdge: alwaysHiddenRightEdge, gap: 0, cap: cap)
        alwaysHiddenItem?.length = showsHidden && !showsAlwaysHidden
            ? min(alwaysHidden.spacer + alwaysHidden.pad, cap) : Self.separatorLength
        let collector = overflowLengths(rightEdge: collectorRightEdge, gap: collectorPadGap, cap: cap)
        collectorItem?.length = !collectsAll ? 0 : showsHidden ? Self.separatorLength : collector.spacer
        collectorPad?.length = collectsAll && !showsHidden ? collector.pad : 0
    }

    /// 从右边缘往左：垫片伸到 padLeft，提示胶囊和「«」靠右排在 padLeft 左边；
    /// 分隔符（spacer）的左端要刚好落在 App 菜单右边一点点（见 spacerOvershoot）。不知道右边缘时两个都取上限。
    ///
    /// 实测 27.3（App 菜单排到 184，垫片左边在 649，挂着两个提示胶囊）：
    /// - spacer 左端在 ≥ 约 200（菜单右边 +16）时放得下，藏着的图标会露出来（算上胶囊和「«」要占的位置）；
    /// - spacer 左端 < 约 200 时放不下，连同左边一起收走；在 200 附近、又只因为胶囊占了地方才放不下时，系统才显示「«」；
    /// - spacer 左端 < 约 150 时，系统连提示胶囊也不显示了。
    /// 菜单多的 App（访达等）在前台时「«」也会出现，大概是系统能把菜单缩短腾地方。
    /// 「«」出不出现没法事先算准，所以不去凑它，只保证藏得住、胶囊还在。
    /// - Parameter gap: 分隔符和垫片之间隔着的图标的宽度。它们排在垫片左边，胶囊排在它们左边
    private func overflowLengths(rightEdge: CGFloat?, gap: CGFloat, cap: CGFloat) -> (spacer: CGFloat, pad: CGFloat) {
        guard let rightEdge, let area = Self.statusArea(near: rightEdge) else { return (cap, cap) }
        let left = area.left
        let reserve = Self.indicatorReserve
        var padLeft = left + reserve
        if let island = area.virtualIsland {
            // 没刘海的屏幕上岛民画了个虚拟的岛，系统不知道它，胶囊可能排到岛底下。
            // 让胶囊贴着岛：岛左边放得下就贴在岛左边，放不下就排到岛右边
            if island.minX - Self.islandGap - left >= reserve {
                // 胶囊和垫片之间是「«」的位子（约 47），「«」不出现时空着。
                // 它出不出现看前台 App：菜单多的（访达）系统能缩菜单腾地方，就会出现，不能让它落在岛底下
                padLeft = island.minX - Self.islandGap
            } else if island.maxX + Self.islandGap > left {
                padLeft = island.maxX + Self.islandGap + reserve
            }
        }
        // 垫片、分隔符都不能超过上限，垫片不能是负的
        padLeft = min(max(padLeft, rightEdge - gap - cap), left + cap - Self.spacerOvershoot, rightEdge - gap)
        let pad = rightEdge - gap - padLeft
        let spacer = min(max(padLeft - left + Self.spacerOvershoot, 100), cap)
        return (spacer, pad)
    }

    /// 给「屏幕共享」等系统提示胶囊和「«」留的位置：一个胶囊约 62（含间距），「«」约 32，够放三个胶囊
    private static let indicatorReserve: CGFloat = 230
    /// 分隔符左端越过 App 菜单右边多少。放得下的界线在菜单右边 +16，胶囊消失的界线在菜单右边 -34 左右
    private static let spacerOvershoot: CGFloat = 4
    /// 胶囊和虚拟岛之间的空隙
    private static let islandGap: CGFloat = 6

    /// 菜单栏上状态栏图标最左能排到哪里（CG x）：前台 App 菜单的右边，有刘海时至少在刘海右边。
    /// 没刘海、岛民画了虚拟岛的屏幕上，一并给出岛的水平范围
    private static func statusArea(near x: CGFloat) -> (left: CGFloat, virtualIsland: CGRect?)? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.minX <= x && x <= $0.frame.maxX + 1 }) else { return nil }
        var left = screen.frame.minX
        if screen.safeAreaInsets.top > 0, let right = screen.auxiliaryTopRightArea {
            left = max(left, right.minX)
        }
        if let menusEnd = frontmostMenusEnd(on: screen) {
            left = max(left, menusEnd)
        }
        let island = ScreenManager.shared.controllers
            .map(\.geometry)
            .first { !$0.isPhysical && $0.displayID == screen.displayID }
            .map(\.notchRect)
        return (left, island)
    }

    /// 前台 App 的菜单（苹果菜单、App 名、文件……）在这块屏幕上排到哪里（CG x）。读不到时返回 nil
    private static func frontmostMenusEnd(on screen: NSScreen) -> CGFloat? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.2)
        guard let bar = AX.element(element, kAXMenuBarAttribute) else { return nil }
        let ends = AX.elements(bar, kAXChildrenAttribute).compactMap { AX.frame($0) }
            .filter { $0.width > 0 && $0.midX >= screen.frame.minX && $0.midX <= screen.frame.maxX }
            .map(\.maxX)
        return ends.max()
    }

    @objc private func toggleClicked() {
        guard Date() >= ignoresToggleClicksUntil, let toggleItem, let contextMenu else { return }
        // 不能一直挂着菜单：岛民切换活动菜单栏时会往开关上发一次点击，那次不该弹菜单。
        // 所以临时挂上菜单再模拟点击，菜单出现在图标正下方，关闭后再摘掉
        toggleItem.menu = contextMenu
        toggleItem.button?.performClick(nil)
        toggleItem.menu = nil
    }

    // MARK: - 首选位置

    /// 系统按 autosaveName 记住每个状态栏图标的位置，值大致是"离屏幕右边缘多远"，越大越靠左。
    private static func preferredPositionKey(_ autosaveName: String) -> String {
        "NSStatusItem Preferred Position \(autosaveName)"
    }

    /// 系统记的"这个图标显示不显示"（isVisible = false 时写成 0）
    private static func visibleKey(_ autosaveName: String) -> String {
        "NSStatusItem VisibleCC \(autosaveName)"
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
