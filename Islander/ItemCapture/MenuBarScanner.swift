import AppKit
import ApplicationServices
import os

private let log = Logger(subsystem: "com.kadaliao.islander", category: "scanner")

/// 在后台线程用辅助功能接口枚举菜单栏图标。
///
/// macOS 26 上所有图标窗口都归 Control Center，靠窗口的所属进程分不出是谁的图标；
/// 而每个 App 的 AXExtrasMenuBar 会列出它自己的图标和位置（包括被挤到屏幕外的），这是公开 API。
///
/// 全量扫描要逐个询问所有进程，有的进程不响应会卡到超时，一次可能好几秒，
/// 所以只偶尔做全量，平时只扫描已知有图标的那十几个 App。
final class MenuBarScanner: @unchecked Sendable {
    struct AppInfo: Sendable {
        let pid: pid_t
        let name: String
        let bundleID: String?

        @MainActor
        init(_ app: NSRunningApplication) {
            pid = app.processIdentifier
            name = app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)"
            bundleID = app.bundleIdentifier
        }
    }

    struct Result: Sendable {
        /// 所有第三方 / 系统图标（不含岛民自己的），按从左到右排序
        let items: [MenuBarItem]
        /// 岛民分隔符的位置；左边的图标就是被隐藏的
        let separator: CGRect?
        /// "永远隐藏"分隔符的位置，在分隔符更左边；它左边的图标连岛上也不显示
        let alwaysHiddenSeparator: CGRect?
        /// "显示全部图标"时开关左边的收纳符，没有这个模式时为 nil
        var collector: CGRect? = nil
        /// 岛民开关的位置，用来探测每块屏幕菜单栏的深浅
        let toggle: CGRect?
        /// 扫描结束时的菜单栏窗口快照
        let rows: StatusBarRows
        let isFull: Bool
        let duration: TimeInterval

        /// 被隐藏的图标（含永远隐藏的）：分隔符左边、和它在同一行
        var hiddenItems: [MenuBarItem] {
            guard let separator else { return [] }
            return items.filter { $0.frame.maxX <= separator.minX + 1 && abs($0.frame.midY - separator.midY) < 12 }
        }

        /// 永远隐藏的图标：两条分隔符都在它右边
        var alwaysHiddenItems: [MenuBarItem] {
            guard let alwaysHiddenSeparator else { return [] }
            return hiddenItems.filter { $0.frame.maxX <= alwaysHiddenSeparator.minX + 1 }
        }
    }

    static let separatorIdentifier = "IslanderSeparator"
    static let alwaysHiddenSeparatorIdentifier = "IslanderAlwaysHiddenSeparator"
    static let collectorIdentifier = "IslanderCollector"
    static let toggleIdentifier = "IslanderToggle"

    private let queue = DispatchQueue(label: "com.kadaliao.islander.scanner", qos: .userInitiated)
    private let actionQueue = DispatchQueue(label: "com.kadaliao.islander.ax-action", qos: .userInitiated)
    /// 已知有菜单栏图标的 App。只在 queue 上读写
    private var knownApps: [pid_t: AppInfo] = [:]

    /// 扫描已知有图标的 App，再加上 `extra`（全量扫描时传入所有运行中的 App）
    func scan(adding extra: [AppInfo], own: AppInfo, isFull: Bool) async -> Result {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.scanOnQueue(extra: extra, own: own, isFull: isFull))
            }
        }
    }

    func forget(pid: pid_t) {
        queue.async { self.knownApps[pid] = nil }
    }

    /// 读取某个图标当前的位置
    func frame(of ref: AXRef) async -> CGRect? {
        await withCheckedContinuation { continuation in
            actionQueue.async { continuation.resume(returning: AX.frame(ref.element)) }
        }
    }

    /// 对图标执行"按下"。打开菜单的 App 会进入菜单跟踪，回复可能晚到，超时返回 .cannotComplete 也算按下了
    func press(_ ref: AXRef) async -> AXError {
        await withCheckedContinuation { continuation in
            actionQueue.async {
                AXUIElementSetMessagingTimeout(ref.element, 0.5)
                continuation.resume(returning: AXUIElementPerformAction(ref.element, kAXPressAction as CFString))
            }
        }
    }

    // MARK: - 诊断

    /// 辅助功能原样报告的内容，不做任何筛选：诊断信息用
    struct RawApp: Sendable {
        let info: AppInfo
        let isOwn: Bool
        let hasExtrasBar: Bool
        let children: [RawChild]
    }

    struct RawChild: Sendable {
        let index: Int
        let identifier: String?
        let role: String?
        let frame: CGRect?
    }

    func rawDump(own: AppInfo) async -> [RawApp] {
        await withCheckedContinuation { continuation in
            queue.async {
                var apps = self.knownApps
                apps[own.pid] = own
                let dump = apps.values.map { app -> RawApp in
                    let appElement = AXUIElementCreateApplication(app.pid)
                    AXUIElementSetMessagingTimeout(appElement, 0.3)
                    let bar = AX.element(appElement, "AXExtrasMenuBar")
                    let children = bar.map { AX.elements($0, kAXChildrenAttribute) } ?? []
                    return RawApp(info: app, isOwn: app.pid == own.pid, hasExtrasBar: bar != nil,
                                  children: children.enumerated().map { index, child in
                        RawChild(index: index, identifier: AX.string(child, kAXIdentifierAttribute),
                                 role: AX.string(child, kAXRoleAttribute), frame: AX.frame(child))
                    })
                }
                continuation.resume(returning: dump)
            }
        }
    }

    // MARK: - 扫描（queue 上执行）

    /// 同一个图标窗口被两个 App 报告时只留一个：实测 Control Center 会额外挂一个
    /// 和某些第三方图标窗口一样大的元素（没有标识、没有描述），保留真正的那个 App
    private static func removingDuplicateWindows(_ items: [MenuBarItem]) -> [MenuBarItem] {
        let controlCenter = "com.apple.controlcenter"
        var indexByWindow: [CGWindowID: Int] = [:]
        var result: [MenuBarItem] = []
        for item in items {
            guard let windowID = item.windowID else {
                result.append(item)
                continue
            }
            if let index = indexByWindow[windowID] {
                if result[index].bundleID == controlCenter && item.bundleID != controlCenter {
                    result[index] = item
                }
                continue
            }
            indexByWindow[windowID] = result.count
            result.append(item)
        }
        return result
    }

    /// 切换活动菜单栏后，各个 App 报告的位置会在约 200ms 内陆续切到新的一行。
    /// 扫到"有的在这一行、有的在那一行"的快照时，等一下重扫，最多两次
    private func scanOnQueue(extra: [AppInfo], own: AppInfo, isFull: Bool) -> Result {
        let start = Date()
        var result = scanOnce(extra: extra, own: own, isFull: isFull, start: start)
        for _ in 0..<2 where !Self.isConsistent(result) {
            Thread.sleep(forTimeInterval: 0.3)
            result = scanOnce(extra: [], own: own, isFull: isFull, start: start)
        }
        return result
    }

    private static func isConsistent(_ result: Result) -> Bool {
        let frames = result.items.map(\.frame)
            + [result.separator, result.alwaysHiddenSeparator, result.toggle].compactMap { $0 }
        let rows = Set(frames.map { Int(($0.midY / 100).rounded(.down)) })
        return rows.count <= 1
    }

    /// 每块屏幕的顶边（CG 全局坐标，原点在主屏左上），每块屏幕各有一行菜单栏。CG 接口在后台线程也能用
    private static func menuBarRowTops() -> [CGFloat] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return displays.prefix(Int(count)).map { CGDisplayBounds($0).minY }
    }

    /// 图标在某一行菜单栏上：横向不管（被挤出屏幕的图标 x 在很远的地方），纵向要贴着某块屏幕的顶边。
    /// 前台是全屏 App 时菜单栏自动收起，图标停在屏幕顶边上方，也算
    private static func isOnMenuBarRow(_ frame: CGRect, rowTops: [CGFloat]) -> Bool {
        guard !rowTops.isEmpty else { return true }
        return rowTops.contains { abs(frame.midY - $0) <= 50 }
    }

    private func scanOnce(extra: [AppInfo], own: AppInfo, isFull: Bool, start: Date) -> Result {
        var apps = knownApps
        apps[own.pid] = own
        for app in extra where apps[app.pid] == nil {
            apps[app.pid] = app
        }
        var items: [MenuBarItem] = []
        var usedIDs = Set<String>()
        var separator: CGRect?
        var alwaysHiddenSeparator: CGRect?
        var collector: CGRect?
        var toggle: CGRect?
        var found: [(app: AppInfo, index: Int, frame: CGRect, identifier: String?, label: String?,
                     element: AXUIElement)] = []
        let rowTops = Self.menuBarRowTops()

        for app in apps.values {
            let appElement = AXUIElementCreateApplication(app.pid)
            // 已知的 App 一般秒回；陌生 App 里有些不响应，超时设短一点
            AXUIElementSetMessagingTimeout(appElement, knownApps[app.pid] != nil ? 0.3 : 0.15)
            guard let bar = AX.element(appElement, "AXExtrasMenuBar") else { continue }
            let children = AX.elements(bar, kAXChildrenAttribute)
            guard !children.isEmpty else { continue }

            if app.pid != own.pid {
                knownApps[app.pid] = app
            }

            for (index, child) in children.enumerated() {
                // Control Center 会挂一些 0 尺寸的占位元素
                guard let frame = AX.frame(child), frame.width > 0, frame.height > 0 else { continue }
                let identifier = AX.string(child, kAXIdentifierAttribute)

                if app.pid == own.pid {
                    if identifier == Self.separatorIdentifier { separator = frame }
                    if identifier == Self.alwaysHiddenSeparatorIdentifier { alwaysHiddenSeparator = frame }
                    if identifier == Self.collectorIdentifier { collector = frame }
                    if identifier == Self.toggleIdentifier { toggle = frame }
                    continue
                }

                // 有的 App 的图标其实没在菜单栏上（实测 flomo 报告在屏幕左下角），却照样列出来。
                // 留着它，岛民就永远对不上菜单栏的窗口，移动图标时只能放弃
                guard Self.isOnMenuBarRow(frame, rowTops: rowTops) else {
                    log.debug("不在菜单栏上，忽略：\(app.name, privacy: .public) #\(index) \(String(describing: frame), privacy: .public)")
                    continue
                }
                found.append((app, index, frame, identifier, AX.string(child, kAXDescriptionAttribute), child))
            }
        }

        // 窗口列表放在最后读：全量扫描要好几秒，期间图标可能在移动，越晚读越接近辅助功能报告的最终位置
        let rows = StatusBarRows.current()
        for entry in found {
            var id = "\(entry.app.bundleID ?? entry.app.name)|\(entry.identifier ?? "#\(entry.index)")"
            if usedIDs.contains(id) { id += "#\(entry.index)" }
            usedIDs.insert(id)

            let window = rows.window(containing: entry.frame.center)
            items.append(MenuBarItem(
                id: id,
                pid: entry.app.pid,
                appName: entry.app.name,
                bundleID: entry.app.bundleID,
                label: entry.label,
                frame: entry.frame,
                windowID: window?.id,
                windowFrame: window?.frame,
                element: AXRef(element: entry.element)
            ))
        }

        items = Self.removingDuplicateWindows(items)
        items.sort { $0.frame.minX < $1.frame.minX }
        return Result(items: items, separator: separator, alwaysHiddenSeparator: alwaysHiddenSeparator,
                      collector: collector, toggle: toggle, rows: rows, isFull: isFull,
                      duration: Date().timeIntervalSince(start))
    }
}
