import AppKit
import ImageIO
import SwiftUI
import os

private let log = Logger(subsystem: "com.kadaliao.islander", category: "items")

/// 一张截到的图标，按岛的配色懒生成对应的 NSImage
@MainActor
final class IconImage {
    let raw: CGImage
    let scale: CGFloat
    let analysis: IconAppearance.Analysis
    private var cache: [IslandStyle: NSImage] = [:]

    init(_ captured: ItemImageCapturer.Captured) {
        raw = captured.image
        scale = captured.scale
        analysis = captured.analysis
    }

    var size: CGSize {
        CGSize(width: CGFloat(raw.width) / scale, height: CGFloat(raw.height) / scale)
    }

    func image(for style: IslandStyle) -> NSImage {
        if let cached = cache[style] { return cached }
        let adapted = IconAppearance.adapt(raw, tone: analysis.monochromeTone, for: style)
        let image = NSImage(cgImage: adapted, size: size)
        cache[style] = image
        return image
    }
}

/// 菜单栏上的图标及其图像。岛上默认显示被隐藏的那些（分隔符左边）；
/// 打开"显示全部图标"后是菜单栏上所有图标（岛民自己的除外）。设置里的"菜单栏布局"用全部图标。
///
/// 扫描（辅助功能 + 窗口位置，不触发录屏指示）每 10 秒一次，全在后台；结果回主线程发布。
/// 截图会让系统亮起录屏指示，所以只在必要时截：图标新出现、宽度变了，
/// 或者外观可能变了（深浅色切换、换空间、授权变化），以及岛打开时缓存已超过 10 分钟。
/// 显示全部图标时，可见图标的内容变得勤（时钟、Wi-Fi），岛打开时超过 1 分钟的会重截。
@MainActor
@Observable
final class HiddenItemsStore {
    static let shared = HiddenItemsStore()

    struct Item: Identifiable, Equatable {
        let source: MenuBarItem
        /// 截到的图标；没有（没授权屏幕录制或截图失败）时用 App 图标代替
        let icon: IconImage?
        let appIcon: NSImage?
        /// 在分隔符左边（被隐藏，含永远隐藏的）
        let isHidden: Bool
        /// 用户放进"永远隐藏"的：岛上也不显示，除非按住 ⌥
        let isAlwaysHidden: Bool
        /// 实际在永远隐藏分隔符左边（要两条分隔符都缩回才能在菜单栏上露出来）。
        /// 不一定是永远隐藏的：新出现、或者 App 重建的图标默认落在菜单栏最左边，也会在这里
        let isBeyondAlwaysHiddenSeparator: Bool

        var id: String { source.id }

        /// 在岛上占的尺寸（pt）
        @MainActor var size: CGSize { icon?.size ?? CGSize(width: 28, height: 22) }

        static func == (lhs: Item, rhs: Item) -> Bool {
            lhs.source == rhs.source && lhs.icon === rhs.icon && lhs.appIcon === rhs.appIcon
                && lhs.isHidden == rhs.isHidden && lhs.isAlwaysHidden == rhs.isAlwaysHidden
                && lhs.isBeyondAlwaysHiddenSeparator == rhs.isBeyondAlwaysHiddenSeparator
        }
    }

    struct Stats {
        var totalItems = 0
        var hiddenItems = 0
        var captured = 0
        var scanDuration: TimeInterval = 0
        var lastScanWasFull = false
        var lastScan: Date?
        var lastCapture: Date?
    }

    /// 菜单栏上所有图标（岛民自己的除外），从左到右
    private(set) var allItems: [Item] = []

    /// 岛上显示的图标
    var items: [Item] { islandItems(includingAlwaysHidden: false) }

    /// 岛上显示的图标：默认是藏到岛上的；显示全部时再加上菜单栏上的（时钟、控制中心这些系统固定的除外）。
    /// 永远隐藏的只在按住 ⌥ 打开岛时才显示
    func islandItems(includingAlwaysHidden: Bool) -> [Item] {
        allItems.filter { item in
            if item.isAlwaysHidden { return includingAlwaysHidden }
            return item.isHidden || (showAllItems && item.source.isMovable)
        }
    }

    /// 设置里的"菜单栏布局"正开着：所有图标都要截图
    var isEditingLayout = false {
        didSet {
            if isEditingLayout, !oldValue { refresh() }
        }
    }

    /// 用户放进"永远隐藏"的图标。只认这里记下的：新出现的图标会自己落到菜单栏最左边（永远隐藏分隔符左边），
    /// 不能因此就永远藏起来，让用户找不到。App 退出了也记着，下次它的图标出现时照样永远隐藏
    private(set) var alwaysHiddenIDs: Set<String> {
        didSet {
            guard alwaysHiddenIDs != oldValue else { return }
            UserDefaults.standard.set(Array(alwaysHiddenIDs).sorted(), forKey: Self.alwaysHiddenKey)
        }
    }

    func setAlwaysHidden(_ id: String, _ alwaysHidden: Bool) {
        if alwaysHidden { alwaysHiddenIDs.insert(id) } else { alwaysHiddenIDs.remove(id) }
    }

    /// 正在替用户拖动菜单栏图标，菜单栏上的位置都是临时的：不扫描、不截图，结束后补一次
    var isPaused = false {
        didSet {
            if !isPaused, oldValue, missedRefreshWhilePaused {
                missedRefreshWhilePaused = false
                refresh()
            }
        }
    }
    /// 至少完成过一次全量扫描（区分"正在读取"和"没有隐藏的图标"）
    private(set) var hasScanned = false
    private(set) var stats = Stats()
    /// 每块屏幕菜单栏的深浅，键是菜单栏顶边的 CG y 坐标
    private(set) var rowStyles: [Int: IslandStyle] = [:]

    /// 调试：用占位图标代替真实内容
    var previewPlaceholders = false

    /// 岛上显示菜单栏上的全部图标，而不只是被隐藏的。打开时菜单栏上能挪的图标也全收到岛上（MenuBarHider 的收纳符）
    var showAllItems: Bool {
        didSet {
            guard showAllItems != oldValue else { return }
            UserDefaults.standard.set(showAllItems, forKey: Self.showAllItemsKey)
            MenuBarHider.shared.collectsAll = showAllItems
            settleCollector()
            refresh()
        }
    }

    var captureMethod: ItemImageCapturer.Method {
        didSet {
            UserDefaults.standard.set(captureMethod.rawValue, forKey: Self.captureMethodKey)
            refresh(forceCapture: true)
        }
    }

    @ObservationIgnored let scanner = MenuBarScanner()
    @ObservationIgnored private let capturer = ItemImageCapturer()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var queued: (full: Bool, extra: [MenuBarScanner.AppInfo])?
    @ObservationIgnored private var lastRefreshStart = Date.distantPast
    @ObservationIgnored private var pendingForceCapture = false
    @ObservationIgnored private var lastFullCapture = Date.distantPast
    /// 截图缓存。只记宽度：活动菜单栏在不同屏幕间切换时，同一图标的窗口高度会变（30 / 33），不该因此重截
    @ObservationIgnored private var icons: [String: (width: CGFloat, icon: IconImage, capturedAt: Date)] = [:]
    /// 上次截到的是残缺图（窗口被挤窄）的图标和当时的窗口宽度：宽度不变就不再重试，免得录屏指示一直亮
    @ObservationIgnored private var clippedWidths: [String: CGFloat] = [:]
    @ObservationIgnored private var missedRefreshWhilePaused = false
    /// 连续几次扫到的位置对不上窗口（图标刚被移动过，辅助功能还没跟上）
    @ObservationIgnored private var staleScans = 0
    /// 每个图标所在的窗口。窗口编号跟着图标走，认准一次以后就按窗口服务器的实时位置排顺序、分区，
    /// 不受辅助功能位置滞后的影响（图标刚被移动后，辅助功能报告的位置会旧好几秒）
    @ObservationIgnored private(set) var itemWindows: [String: CGWindowID] = [:]
    @ObservationIgnored private var appIconCache: [pid_t: NSImage] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var periodic: Task<Void, Never>?
    @ObservationIgnored private var separatorSettling: Task<Void, Never>?
    /// 每块屏幕上次读过的壁纸（路径 + 修改时间），变了才重新估算深浅
    @ObservationIgnored private var wallpaperKeys: [Int: WallpaperTone.Key] = [:]
    /// 第一次全量扫描完成之前，增量扫描不知道哪些 App 有图标，结果不可信
    @ObservationIgnored private var didFullScan = false

    private static let captureMethodKey = "captureMethod"
    private static let showAllItemsKey = "showAllItems"
    private static let alwaysHiddenKey = "alwaysHiddenItemIDs"
    /// 岛打开时，缓存的图标超过这个时间就整体重截一次
    private static let maxIconAge: TimeInterval = 600
    /// 显示全部图标时，岛打开时可见图标的截图超过这个时间就重截
    private static let maxVisibleIconAge: TimeInterval = 60

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.captureMethodKey) ?? ""
        captureMethod = ItemImageCapturer.Method(rawValue: saved) ?? .automatic
        showAllItems = UserDefaults.standard.bool(forKey: Self.showAllItemsKey)
        alwaysHiddenIDs = Set(UserDefaults.standard.stringArray(forKey: Self.alwaysHiddenKey) ?? [])
    }

    /// 调试：强制所有岛用某种配色
    var debugStyleOverride: IslandStyle?

    func style(forRowTop top: CGFloat) -> IslandStyle {
        debugStyleOverride ?? AppSettings.shared.islandAppearance.fixedStyle ?? rowStyles[Int(top.rounded())] ?? .dark
    }

    // MARK: - 启动

    func start() {
        guard periodic == nil else { return }
        // 第一次扫描之前先按记下的猜：有永远隐藏的图标，永远隐藏分隔符就一直伸长
        MenuBarHider.shared.hasAlwaysHiddenItems = !alwaysHiddenIDs.isEmpty
        MenuBarHider.shared.collectsAll = showAllItems

        Permissions.shared.onChange = { [weak self] in self?.refresh(full: true, forceCapture: true) }
        MenuBarHider.shared.onLayoutChange = { [weak self] in self?.refresh(after: .milliseconds(400)) }
        // 等分隔符就位再做首次全量扫描
        MenuBarHider.shared.onReady = { [weak self] in
            self?.settleCollector()
            self?.refresh(full: true, forceCapture: true)
        }

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                               object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app { HiddenItemsStore.shared.appLaunched(app) }
            }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                               object: nil, queue: .main) { note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                if let pid { HiddenItemsStore.shared.appTerminated(pid) }
            }
        })
        // 换空间、深浅色切换：壁纸和菜单栏的深浅可能变了
        observers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HiddenItemsStore.shared.refresh(after: .milliseconds(500), forceCapture: true) }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { HiddenItemsStore.shared.refresh(after: .milliseconds(800), forceCapture: true) }
        })
        // 解锁后把锁屏期间没截的补上
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { HiddenItemsStore.shared.refresh(after: .seconds(1), forceCapture: true) }
        })

        // 定期只做扫描（不截图）：发现新图标、尺寸变化时才截
        periodic = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                tick += 1
                self?.refresh(full: tick % 6 == 0)
            }
        }
    }

    // MARK: - 显示全部图标

    /// 收纳符要紧挨在开关左边：夹在中间的图标不会被收走，跑到开关右边会把开关也挤出屏幕。
    /// 系统记的位置数值不精确，放下去以后核对，不对就一点点挪（它和开关之间的图标都在屏幕上，位置是准的）
    private func settleCollector() {
        separatorSettling?.cancel()
        guard showAllItems else { return }
        separatorSettling = Task { [scanner] in
            let own = MenuBarScanner.AppInfo(NSRunningApplication.current)
            var previous: [CGRect] = []
            for _ in 0..<30 {
                // 状态栏图标新建以后要过一会儿才排好：连续两次扫描位置一致才算数
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, self.showAllItems else { return }
                let result = await scanner.scan(adding: [], own: own, isFull: false)
                let frames = result.items.map(\.frame) + [result.collector, result.toggle].compactMap { $0 }
                guard let collector = result.collector, let toggle = result.toggle, frames == previous else {
                    previous = frames
                    continue
                }
                let delta: CGFloat
                if collector.minX > toggle.minX {
                    delta = 12
                } else if result.items.contains(where: {
                    $0.isMovable && $0.frame.minX >= collector.maxX - 1 && $0.frame.maxX <= toggle.minX + 1
                }) {
                    delta = -12
                } else {
                    break
                }
                log.notice("收纳符没到位，再挪 \(Int(delta))")
                MenuBarHider.shared.nudgeCollector(by: delta)
                previous = []
            }
            self.refresh(after: .milliseconds(400))
        }
    }

    // MARK: - 刷新

    /// 指针刚碰到刘海时调用：趁停留判断的时间在后台刷新；缓存太旧就顺便重截
    func refreshIfStale(maxAge: TimeInterval = 2) {
        let iconsTooOld = Date().timeIntervalSince(lastFullCapture) > Self.maxIconAge
        if iconsTooOld || Date().timeIntervalSince(lastRefreshStart) > maxAge {
            refresh(forceCapture: iconsTooOld, refreshVisibleIcons: true)
        }
    }

    func refresh(after delay: Duration, forceCapture: Bool = false) {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            self?.refresh(forceCapture: forceCapture)
        }
    }

    /// - Parameter refreshVisibleIcons: 显示全部图标时，顺便重截超过 1 分钟的可见图标（岛将要打开时用）
    func refresh(full: Bool = false, adding extra: [MenuBarScanner.AppInfo] = [], forceCapture: Bool = false,
                 refreshVisibleIcons: Bool = false) {
        if forceCapture { pendingForceCapture = true }
        guard Permissions.shared.accessibility else {
            if !allItems.isEmpty { allItems = [] }
            return
        }
        guard !isPaused else {
            missedRefreshWhilePaused = true
            return
        }
        // 同一时间只跑一轮；期间来的请求合并成一轮排在后面
        if refreshTask != nil {
            let previous = queued ?? (false, [])
            queued = (previous.full || full, previous.extra + extra)
            return
        }

        lastRefreshStart = Date()
        let own = MenuBarScanner.AppInfo(NSRunningApplication.current)
        let candidates = full ? NSWorkspace.shared.runningApplications.map(MenuBarScanner.AppInfo.init) : extra
        let method = captureMethod
        // 锁屏时截图每张要卡一秒、截出来是空的：先不截，解锁后补
        let canCapture = Permissions.shared.screenRecording && !Self.isScreenLocked
        let force = pendingForceCapture && canCapture
        if canCapture { pendingForceCapture = false }
        let islandRows = ScreenManager.shared.controllers.map(\.geometry.menuBarRowTop)
        let changedWallpapers = changedWallpapers()
        let cachedWidths = icons.mapValues(\.width)
        let clippedWidths = clippedWidths
        let showAll = showAllItems
        let editingLayout = isEditingLayout
        let staleIDs = showAll && refreshVisibleIcons
            ? Set(icons.filter { Date().timeIntervalSince($0.value.capturedAt) > Self.maxVisibleIconAge }.keys)
            : []

        refreshTask = Task { [scanner, capturer] in
            let result = await scanner.scan(adding: candidates, own: own, isFull: full)
            let snapshot = MenuBarSnapshot(mapping: result, knownWindows: self.itemWindows)
            if let snapshot {
                self.itemWindows.merge(snapshot.itemWindows) { _, new in new }
                self.staleScans = 0
            } else if self.didFullScan, self.staleScans < 3 {
                log.debug("扫描结果对不上窗口（第 \(self.staleScans + 1) 次），已认得 \(self.itemWindows.count) 个窗口")
                // 有图标对不上窗口（新出现的图标、位置还是旧的）：按旧位置分区会分错，过一会儿重扫。最多等三次
                self.staleScans += 1
                self.refreshTask = nil
                if force { self.pendingForceCapture = true }
                self.refresh(after: .milliseconds(400), forceCapture: false)
                return
            }
            // 顺序、分区、截哪个窗口都以窗口为准；对不上窗口时退回辅助功能的位置
            let items = Self.placed(result.items, in: snapshot)
            let hiddenIDs = snapshot?.hiddenIDs ?? Set(result.hiddenItems.map(\.id))
            let beyondIDs = snapshot?.beyondAlwaysHiddenIDs ?? Set(result.alwaysHiddenItems.map(\.id))
            let hidden = items.filter { hiddenIDs.contains($0.id) }
            // 布局页要全部图标；岛上显示全部时跳过系统固定的（时钟每分钟都变，没必要一直重截）
            let toCapture = editingLayout ? items : showAll ? items.filter(\.isMovable) : hidden
            var requests: [ItemImageCapturer.Request] = []
            if canCapture {
                // 只有可见图标才因为"旧了"重截；隐藏的图标平时看不到变化，按宽度判断就够
                let recapture = staleIDs.subtracting(hiddenIDs)
                requests = Self.iconRequests(toCapture, cachedWidths: cachedWidths, clippedWidths: clippedWidths,
                                             force: force, recapture: recapture)
                // 探针只在强制重截时发：截不到（那一行不是活动行）也不会每 10 秒重试一次
                if force {
                    requests += Self.probeRequests(result, rows: islandRows)
                }
            }
            // 先按新位置更新顺序和分区：截图可能要等好一会儿，刚移动过的图标不该先跳回原处
            if !requests.isEmpty {
                self.apply(result: result, items: items, hiddenIDs: hiddenIDs, beyondIDs: beyondIDs,
                           batch: ItemImageCapturer.Batch(), capturedAll: false)
            }
            let batch = await capturer.capture(requests, method: method)
            let wallpaperStyles = await Self.estimate(changedWallpapers)
            self.applyWallpapers(changedWallpapers, styles: wallpaperStyles)
            self.apply(result: result, items: items, hiddenIDs: hiddenIDs, beyondIDs: beyondIDs, batch: batch,
                       capturedAll: force && canCapture)

            self.refreshTask = nil
            if let next = self.queued {
                self.queued = nil
                self.refresh(full: next.full, adding: next.extra)
            }
        }
    }

    private static var isScreenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// 按窗口的实际顺序排，并把每个图标的窗口换成快照里认准的那个
    private static func placed(_ items: [MenuBarItem], in snapshot: MenuBarSnapshot?) -> [MenuBarItem] {
        guard let snapshot else { return items }
        return items
            .map { item in snapshot.window(of: item.id).map(item.placed(in:)) ?? item }
            .sorted { (snapshot.orderIndex(of: $0.id) ?? Int.max) < (snapshot.orderIndex(of: $1.id) ?? Int.max) }
    }

    /// 有岛的屏幕里，壁纸换过（或还没读过）的那些
    private func changedWallpapers() -> [(row: Int, key: WallpaperTone.Key)] {
        ScreenManager.shared.controllers.compactMap { controller in
            let geometry = controller.geometry
            guard let screen = NSScreen.screens.first(where: { $0.displayID == geometry.displayID }),
                  let url = NSWorkspace.shared.desktopImageURL(for: screen)
            else { return nil }
            let row = Int(geometry.menuBarRowTop.rounded())
            let key = WallpaperTone.key(for: url)
            return wallpaperKeys[row] == key ? nil : (row, key)
        }
    }

    @concurrent
    private nonisolated static func estimate(_ wallpapers: [(row: Int, key: WallpaperTone.Key)]) async -> [Int: IslandStyle] {
        var styles: [Int: IslandStyle] = [:]
        for wallpaper in wallpapers {
            styles[wallpaper.row] = WallpaperTone.style(forWallpaperAt: wallpaper.key.url)
        }
        return styles
    }

    private func applyWallpapers(_ wallpapers: [(row: Int, key: WallpaperTone.Key)], styles: [Int: IslandStyle]) {
        for wallpaper in wallpapers {
            wallpaperKeys[wallpaper.row] = wallpaper.key
        }
        guard !styles.isEmpty else { return }
        var newStyles = rowStyles
        styles.forEach { newStyles[$0.key] = $0.value }
        guard newStyles != rowStyles else { return }
        log.info("壁纸变了，菜单栏深浅 \(styles.map { "\($0.key):\($0.value == .light ? "浅" : "深")" }, privacy: .public)")
        withAnimation(.easeInOut(duration: 0.3)) { rowStyles = newStyles }
    }

    /// 只截新出现的、宽度变了的、指定要重截的图标（强制时全截）
    private nonisolated static func iconRequests(_ items: [MenuBarItem], cachedWidths: [String: CGFloat],
                                                 clippedWidths: [String: CGFloat],
                                                 force: Bool, recapture: Set<String>) -> [ItemImageCapturer.Request] {
        items.compactMap { item in
            guard let windowID = item.windowID, let windowFrame = item.windowFrame else { return nil }
            if !force, !recapture.contains(item.id),
               let width = cachedWidths[item.id], abs(width - windowFrame.width) < 0.5 { return nil }
            if !force, let width = clippedWidths[item.id], abs(width - windowFrame.width) < 0.5 { return nil }
            return .init(key: item.id, windowID: windowID, windowFrame: windowFrame, crop: item.frame)
        }
    }

    /// 探针：岛民开关是单色模板图标，截它在某块屏幕菜单栏上的样子，就知道那块菜单栏的深浅。
    /// 实测只有活动的那一行截得到内容（其他行截出来是透明的），截不到时以壁纸估算为准
    private nonisolated static func probeRequests(_ result: MenuBarScanner.Result,
                                                  rows: [CGFloat]) -> [ItemImageCapturer.Request] {
        guard let toggle = result.toggle, let window = result.rows.window(containing: toggle.center) else { return [] }
        return rows.compactMap { top in
            let key = Int(top.rounded())
            guard let copy = result.rows.counterpart(of: window, inRowTop: top) else { return nil }
            return .init(key: "probe:\(key)", windowID: copy.id, windowFrame: copy.frame, crop: nil)
        }
    }

    /// - Parameters:
    ///   - items: 按实际顺序排好的图标
    ///   - beyondIDs: 实际在永远隐藏分隔符左边的图标
    private func apply(result: MenuBarScanner.Result, items: [MenuBarItem], hiddenIDs: Set<String>,
                       beyondIDs: Set<String>, batch: ItemImageCapturer.Batch, capturedAll: Bool) {
        let captured = batch.captured
        if result.isFull {
            didFullScan = true
        } else if !didFullScan {
            return
        }

        var newStyles = rowStyles
        for (key, capture) in captured where key.hasPrefix("probe:") {
            if let row = Int(key.dropFirst("probe:".count)),
               let style = IconAppearance.style(ofMenuBarShowing: capture.image) {
                newStyles[row] = style
            }
        }

        var newItems: [Item] = []
        for source in items {
            if batch.clipped.contains(source.id), let windowFrame = source.windowFrame {
                clippedWidths[source.id] = windowFrame.width
            }
            if let capture = captured[source.id], let windowFrame = source.windowFrame {
                clippedWidths[source.id] = nil
                // 像素没变就复用原来的对象，界面不会无谓刷新
                let icon = icons[source.id].flatMap {
                    $0.icon.analysis.fingerprint == capture.analysis.fingerprint ? $0.icon : nil
                } ?? IconImage(capture)
                icons[source.id] = (windowFrame.width, icon, Date())
            }
            let isHidden = hiddenIDs.contains(source.id)
            let isBeyond = beyondIDs.contains(source.id)
            let icon = icons[source.id]?.icon
            newItems.append(Item(source: source, icon: icon, appIcon: icon == nil ? appIcon(for: source.pid) : nil,
                                 isHidden: isHidden, isAlwaysHidden: isBeyond && alwaysHiddenIDs.contains(source.id),
                                 isBeyondAlwaysHiddenSeparator: isBeyond))
        }
        // 用户自己按住 ⌘ 把永远隐藏的图标拖出来了：不再算永远隐藏
        if result.alwaysHiddenSeparator != nil {
            let movedOut = alwaysHiddenIDs.filter { id in result.items.contains { $0.id == id } && !beyondIDs.contains(id) }
            if !movedOut.isEmpty { alwaysHiddenIDs.subtract(movedOut) }
        }
        MenuBarHider.shared.hasAlwaysHiddenItems = newItems.contains(where: \.isAlwaysHidden)

        // 已经不在菜单栏上的图标，丢掉缓存
        let present = Set(result.items.map(\.id))
        icons = icons.filter { present.contains($0.key) }
        clippedWidths = clippedWidths.filter { present.contains($0.key) }
        if result.isFull {
            itemWindows = itemWindows.filter { present.contains($0.key) || $0.key.hasPrefix("islander|") }
        }

        let iconCaptures = captured.keys.filter { !$0.hasPrefix("probe:") }.count
        if !batch.clipped.isEmpty {
            log.info("图标窗口被挤窄，丢弃残缺截图：\(batch.clipped.sorted(), privacy: .public)")
        }
        if capturedAll { lastFullCapture = Date() }
        stats = Stats(
            totalItems: result.items.count,
            hiddenItems: hiddenIDs.count,
            captured: iconCaptures,
            scanDuration: result.duration,
            lastScanWasFull: result.isFull,
            lastScan: Date(),
            lastCapture: captured.isEmpty ? stats.lastCapture : Date()
        )
        if !captured.isEmpty || result.isFull {
            let styles = newStyles.sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value == .light ? "浅" : "深")" }.joined(separator: " ")
            log.info("""
                扫描\(result.isFull ? "（全量）" : "", privacy: .public) \(result.items.count) 个图标，\
                隐藏 \(hiddenIDs.count) 个，截图 \(iconCaptures) 张，菜单栏 \(styles, privacy: .public)，\
                \(Int(result.duration * 1000)) ms
                """)
        }
        Self.dumpIfRequested(captured)

        hasScanned = true
        guard newItems != allItems || newStyles != rowStyles else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            allItems = newItems
            rowStyles = newStyles
        }
    }

    private func appIcon(for pid: pid_t) -> NSImage {
        if let cached = appIconCache[pid] { return cached }
        let icon = (NSRunningApplication(processIdentifier: pid)?.icon ?? NSImage(named: NSImage.applicationIconName))?
            .copy() as? NSImage ?? NSImage()
        icon.size = NSSize(width: 18, height: 18)
        appIconCache[pid] = icon
        return icon
    }

    /// 调试：`defaults write com.kadaliao.islander debugDumpIconsPath <目录>` 后，每次截图都导出 PNG
    private static func dumpIfRequested(_ captured: [String: ItemImageCapturer.Captured]) {
        guard let path = UserDefaults.standard.string(forKey: "debugDumpIconsPath"), !captured.isEmpty else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let snapshot = captured.map { ($0.key, $0.value) }
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (id, capture) in snapshot {
                let name = id.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
                let tone = capture.analysis.monochromeTone.map { $0 == .dark ? "-dark" : "-light" } ?? "-color"
                let url = directory.appendingPathComponent("\(name)\(tone).png")
                guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
                else { continue }
                CGImageDestinationAddImage(destination, capture.image, nil)
                CGImageDestinationFinalize(destination)
            }
        }
    }

    // MARK: - App 启动 / 退出

    private func appLaunched(_ app: NSRunningApplication) {
        let info = MenuBarScanner.AppInfo(app)
        // 新 App 的菜单栏图标要过一会儿才出现
        Task { [weak self] in
            for delay in [2, 8] {
                try? await Task.sleep(for: .seconds(delay))
                self?.refresh(adding: [info])
            }
        }
    }

    private func appTerminated(_ pid: pid_t) {
        scanner.forget(pid: pid)
        // App 重开后图标是新窗口
        let ids = Set(allItems.filter { $0.source.pid == pid }.map(\.id))
        itemWindows = itemWindows.filter { !ids.contains($0.key) }
        appIconCache[pid] = nil
        refresh()
    }
}
