import CoreGraphics

/// 某一时刻菜单栏上的一个图标。
struct MenuBarItem: Sendable, Identifiable, Equatable {
    /// 稳定标识：App 的 bundle ID + 图标的辅助功能标识（没有就用它在 App 内的序号）
    let id: String
    let pid: pid_t
    let appName: String
    let bundleID: String?
    /// 辅助功能描述（系统图标会写"Wi‑Fi, connected, 3 bars"这样的话；第三方图标多半没有）
    let label: String?
    /// 辅助功能报告的按钮区域，CG 全局坐标（原点在主屏左上角）
    let frame: CGRect
    /// 承载它的菜单栏窗口（macOS 26 上归 Control Center 所有），截图用
    let windowID: CGWindowID?
    let windowFrame: CGRect?
    let element: AXRef

    static func == (lhs: MenuBarItem, rhs: MenuBarItem) -> Bool {
        lhs.id == rhs.id && lhs.frame == rhs.frame && lhs.windowID == rhs.windowID
    }
}

extension MenuBarItem {
    /// 换成窗口服务器里认准的那个窗口（辅助功能报告的位置可能是旧的，按它找到的窗口不一定对）
    func placed(in window: StatusBarRows.Window) -> MenuBarItem {
        MenuBarItem(id: id, pid: pid, appName: appName, bundleID: bundleID, label: label, frame: frame,
                    windowID: window.id, windowFrame: window.frame, element: element)
    }

    /// 给人看的名字：系统图标用它的功能名，其他用 App 名
    var displayName: String {
        let identifier = id.split(separator: "|", maxSplits: 1).last.map(String.init) ?? ""
        if let name = Self.systemNames[identifier] { return name }
        if bundleID == "com.apple.TextInputMenuAgent" { return "输入法" }
        if bundleID?.hasPrefix("com.apple.") == true, let label,
           let first = label.split(separator: ",").first?.trimmingCharacters(in: .whitespaces), !first.isEmpty {
            return first
        }
        return appName
    }

    private static let systemNames = [
        "com.apple.menuextra.clock": "时钟",
        "com.apple.menuextra.controlcenter": "控制中心",
        "com.apple.menuextra.wifi": "Wi‑Fi",
        "com.apple.menuextra.focusmode": "专注模式",
        "com.apple.menuextra.user": "快速切换用户",
        "com.apple.menuextra.battery": "电池",
        "com.apple.menuextra.bluetooth": "蓝牙",
        "com.apple.menuextra.sound": "声音",
        "com.apple.menuextra.display": "显示器",
        "com.apple.menuextra.airdrop": "隔空投送",
        "com.apple.menuextra.now-playing": "正在播放",
        "com.apple.menuextra.nowplaying": "正在播放",
        "com.apple.menuextra.screenmirroring": "屏幕镜像",
        "com.apple.menuextra.keyboardbrightness": "键盘亮度",
        "com.apple.menuextra.siri": "Siri",
        "com.apple.menuextra.spotlight": "聚焦",
        "com.apple.menuextra.accessibility": "辅助功能",
        "com.apple.menuextra.timemachine": "时间机器",
        "com.apple.menuextra.vpn": "VPN",
        "com.apple.menuextra.textinput": "输入法",
        "com.apple.menuextra.weather": "天气",
        "com.apple.menuextra.hearing": "听觉",
        "com.apple.menuextra.stagemanager": "台前调度",
        "com.apple.menuextra.audiovideo": "麦克风与摄像头",
    ]
}
