import AppKit
import ApplicationServices

/// 移动图标失败时给用户拷贝的诊断信息：系统和屏幕、上一次移动每一步的经过、
/// 辅助功能报告的图标、窗口服务器里的菜单栏窗口，以及两边对不对得上。
///
/// 用户会把它贴到公开的 issue 里，所以第三方 App 的名字和标识一律换成「第三方 N」，
/// 只留系统自带的和岛民自己的。
@MainActor
enum MoveDiagnostics {
    nonisolated static func brief(_ rect: CGRect) -> String {
        guard !rect.isNull, !rect.isInfinite else { return "无" }
        return "x=\(Int(rect.minX)) y=\(Int(rect.minY)) 宽 \(Int(rect.width)) 高 \(Int(rect.height))"
    }

    static func report() async -> String {
        let store = HiddenItemsStore.shared
        let mover = MenuBarItemMover.shared
        let own = MenuBarScanner.AppInfo(NSRunningApplication.current)
        var scrubber = Scrubber(ownBundleID: own.bundleID)
        var lines: [String] = []

        // 系统和设置
        let info = Bundle.main.infoDictionary
        lines.append("""
            岛民 \(info?["CFBundleShortVersionString"] as? String ?? "?")（\(info?["CFBundleVersion"] as? String ?? "?")） · \
            macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(hardwareModel())
            """)
        lines.append("""
            权限：辅助功能 \(mark(AXIsProcessTrusted()))，屏幕录制 \(mark(Permissions.shared.screenRecording)) · \
            在岛上显示全部图标 \(mark(store.showAllItems)) · 临时露出 \(mark(MenuBarHider.shared.isTemporarilyRevealed))
            """)
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        for (index, screen) in NSScreen.screens.enumerated() {
            let f = screen.frame
            let notch = screen.safeAreaInsets.top > 0
                ? "刘海：左 \(Int(screen.auxiliaryTopLeftArea?.width ?? -1)) 右 \(Int(screen.auxiliaryTopRightArea?.width ?? -1)) 高 \(Int(screen.safeAreaInsets.top))"
                : "无刘海"
            lines.append("屏幕 \(index)：x=\(Int(f.minX)) y=\(Int(primaryTop - f.maxY)) \(Int(f.width))×\(Int(f.height))，\(notch)")
        }

        // 上一次移动
        lines.append("")
        lines.append("【上一次移动】")
        if mover.trail.isEmpty {
            lines.append("（打开设置以后还没移动过图标）")
        } else {
            lines.append(contentsOf: mover.trail.enumerated().map { "\($0 + 1). \($1)" })
            if let error = mover.lastError { lines.append("提示：\(error.replacingOccurrences(of: "\n", with: " "))") }
        }

        // 辅助功能原样报告的
        let dump = await store.scanner.rawDump(own: own)
        for app in dump { scrubber.register(bundleID: app.info.bundleID, name: app.info.name) }
        lines.append("")
        lines.append("【辅助功能：各 App 报告的菜单栏图标】")
        for app in dump.sorted(by: { $0.isOwn && !$1.isOwn }) {
            let name = app.isOwn ? "岛民" : (app.info.bundleID ?? app.info.name)
            guard app.hasExtrasBar else {
                lines.append("\(name)：没有 AXExtrasMenuBar")
                continue
            }
            lines.append("\(name)：\(app.children.count) 个")
            // Control Center 会挂一堆 0 尺寸的占位元素，只报个数
            let isPlaceholder = { (child: MenuBarScanner.RawChild) in
                child.identifier == nil && child.frame.map { $0.width == 0 && $0.height == 0 } == true
            }
            let placeholders = app.children.filter(isPlaceholder).count
            if placeholders > 0 { lines.append("  （其中 \(placeholders) 个是没有标识、0 尺寸的占位元素）") }
            for child in app.children where !isPlaceholder(child) {
                let identifier: String = {
                    guard let identifier = child.identifier else { return "无标识" }
                    return app.isOwn || app.info.bundleID?.hasPrefix("com.apple.") == true || isGeneric(identifier)
                        ? identifier : "（自定义标识）"
                }()
                lines.append("  #\(child.index) \(identifier) \(child.role ?? "无角色") \(child.frame.map(brief) ?? "读不到位置")")
            }
        }

        // 扫描结果，以及和窗口对不对得上
        let result = await store.scanner.scan(adding: [], own: own, isFull: false)
        for item in result.items { scrubber.register(itemID: item.id, bundleID: item.bundleID, name: item.appName) }
        lines.append("")
        lines.append("【扫描结果】")
        lines.append("""
            分隔符 \(result.separator.map(brief) ?? "读不到") · 永远隐藏分隔符 \(result.alwaysHiddenSeparator.map(brief) ?? "读不到") · \
            开关 \(result.toggle.map(brief) ?? "读不到") · 收纳符 \(result.collector.map(brief) ?? "无")
            """)
        lines.append("岛民图标的位置来自：\(result.ownFramesFromAppKit ? "AppKit（辅助功能里读不到）" : "辅助功能")")
        lines.append("AppKit 报告的岛民图标：\(MenuBarHider.shared.ownFramesDescription)")
        for item in result.items {
            lines.append("  \(item.id) \(brief(item.frame)) 窗口 \(item.windowID.map(String.init) ?? "无")\(item.isMovable ? "" : " 固定")")
        }
        lines.append("对照（用记着的窗口）：\(mapping(result, known: store.itemWindows))")
        lines.append("对照（只按位置）：\(mapping(result, known: [:]))")
        for top in Set(NSScreen.screens.map { primaryTop - $0.frame.maxY }).sorted() {
            let chain = result.rows.chain(top: top)
            lines.append("y=\(Int(top)) 这一行：状态栏层窗口 \(result.rows.row(top: top).count) 个，连成链的 \(chain.count) 个")
        }

        // 窗口服务器
        lines.append("")
        lines.append("【窗口服务器：贴着屏幕顶边的矮窗口】")
        lines.append(contentsOf: windowLines(tops: NSScreen.screens.map { primaryTop - $0.frame.maxY }, scrubber: &scrubber))

        return scrubber.scrub(lines.joined(separator: "\n"))
    }

    private static func mark(_ value: Bool) -> String { value ? "开" : "关" }

    private static func mapping(_ result: MenuBarScanner.Result, known: [String: CGWindowID]) -> String {
        do {
            let snapshot = try MenuBarSnapshot(mapping: result, knownWindows: known)
            return "对得上，认出 \(snapshot.itemWindows.count) 个"
        } catch {
            return "对不上：\(error)"
        }
    }

    /// 系统自动起的标识（"Item-0"、"#3"），看不出是哪个 App
    private nonisolated static func isGeneric(_ identifier: String) -> Bool {
        identifier.range(of: #"^(Item-\d+|#\d+)$"#, options: .regularExpression) != nil
    }

    private static func windowLines(tops: [CGFloat], scrubber: inout Scrubber) -> [String] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return ["读不到窗口列表"]
        }
        let statusLayer = Int(CGWindowLevelForKey(.statusWindow))
        var rows: [(layer: Int, x: CGFloat, text: String)] = []
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds)
            else { continue }
            // 贴着某块屏幕顶边的矮窗口，不限于状态栏层（图标窗口要是换了层，也看得到）
            guard layer != 0, frame.height <= 60, tops.contains(where: { abs(frame.minY - $0) <= 12 }) else { continue }
            let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
            let app = NSRunningApplication(processIdentifier: pid)
            let ownerName = info[kCGWindowOwnerName as String] as? String
            scrubber.register(bundleID: app?.bundleIdentifier, name: app?.localizedName ?? ownerName ?? "")
            if let ownerName { scrubber.register(bundleID: app?.bundleIdentifier, name: ownerName) }
            let owner = app?.bundleIdentifier ?? ownerName ?? "pid \(pid)"
            // 图标窗口的标题是图标自己起的名字，常常就是 App 的 bundle ID：只留看不出第三方 App 的
            let name: String = {
                guard let name = info[kCGWindowName as String] as? String, !name.isEmpty else { return "无标题" }
                let isKnown = name.hasPrefix("Islander") || name.hasPrefix("com.apple.") || name == Bundle.main.bundleIdentifier
                    || isGeneric(name) || systemWindowNames.contains { name.hasPrefix($0) }
                return isKnown ? name : "（其他标题）"
            }()
            let onScreen = (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
            rows.append((layer, frame.minX, """
                  #\(info[kCGWindowNumber as String] as? Int ?? 0) 层 \(layer) \(brief(frame)) \(onScreen ? "在屏" : "不在屏") \
                \(owner) \(name)
                """))
        }
        rows.sort { ($0.layer, $0.x) < ($1.layer, $1.x) }
        var lines = ["状态栏层 = \(statusLayer)，共 \(rows.count) 个"]
        lines.append(contentsOf: rows.prefix(150).map(\.text))
        if rows.count > 150 { lines.append("  …还有 \(rows.count - 150) 个没列出") }
        return lines
    }

    /// 系统图标窗口的标题（macOS 26 实测），以及菜单栏本身
    private static let systemWindowNames = [
        "Clock", "BentoBox", "WiFi", "FocusModes", "UserSwitcher", "Battery", "Bluetooth", "Sound", "Display",
        "NowPlaying", "ScreenMirroring", "AirDrop", "Spotlight", "Siri", "TextInput", "AudioVideoModule",
        "KeyboardBrightness", "Accessibility", "TimeMachine", "VPN", "Weather", "Hearing", "StageManager",
        "Menubar", "MenuBar",
    ]

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "未知机型" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    /// 把第三方 App 的名字、bundle ID、图标标识换成「第三方 N」
    private struct Scrubber {
        let ownBundleID: String?
        private var aliases: [String: String] = [:]
        private var replacements: [String: String] = [:]

        init(ownBundleID: String?) { self.ownBundleID = ownBundleID }

        func isSystem(bundleID: String?) -> Bool {
            guard let bundleID else { return false }
            return bundleID == ownBundleID || bundleID.hasPrefix("com.apple.")
        }

        private mutating func alias(for key: String) -> String {
            if let alias = aliases[key] { return alias }
            let alias = "第三方\(aliases.count + 1)"
            aliases[key] = alias
            return alias
        }

        mutating func register(bundleID: String?, name: String) {
            guard !isSystem(bundleID: bundleID) else { return }
            if bundleID == nil, ["Window Server", "WindowServer", "Dock", "WindowManager"].contains(name) { return }
            let key = bundleID ?? name
            guard !key.isEmpty else { return }
            let alias = alias(for: key)
            if let bundleID { replacements[bundleID] = alias }
            if name.count >= 2 { replacements[name] = alias }
        }

        mutating func register(itemID: String, bundleID: String?, name: String) {
            register(bundleID: bundleID, name: name)
            guard !isSystem(bundleID: bundleID) else { return }
            let parts = itemID.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, !MoveDiagnostics.isGeneric(parts[1]),
                  parts[1].range(of: #"^#\d+(#\d+)?$"#, options: .regularExpression) == nil
            else { return }
            // 自定义的图标标识也可能看得出是哪个 App
            replacements[itemID] = "\(alias(for: bundleID ?? name))|（自定义标识）"
        }

        /// 长的先换，免得 bundle ID 里的一段先被 App 名换掉
        func scrub(_ text: String) -> String {
            replacements.sorted { $0.key.count > $1.key.count }.reduce(text) {
                $0.replacingOccurrences(of: $1.key, with: $1.value)
            }
        }
    }
}
