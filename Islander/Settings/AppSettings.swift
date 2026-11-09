import AppKit
import Observation
import ServiceManagement
import os

private let log = Logger(subsystem: "com.kadaliao.islander", category: "settings")

/// 设置窗口里"通用""灵动岛"两页的开关。手感参数在 TuningStore，图标相关在 HiddenItemsStore。
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    enum IslandAppearance: String, CaseIterable, Identifiable {
        /// 跟随菜单栏：深色菜单栏上是黑色的岛，浅色菜单栏上是毛玻璃
        case automatic
        case dark
        case light

        var id: String { rawValue }

        var title: String {
            switch self {
            case .automatic: "跟随菜单栏"
            case .dark: "总是深色"
            case .light: "总是浅色"
            }
        }

        var fixedStyle: IslandStyle? {
            switch self {
            case .automatic: nil
            case .dark: .dark
            case .light: .light
            }
        }
    }

    private enum Key {
        static let showInDock = "showInDock"
        static let islandAppearance = "islandAppearance"
    }

    /// 在 Dock 里常驻一个图标：点它打开设置，右键是常用操作
    var showInDock: Bool {
        didSet {
            guard showInDock != oldValue else { return }
            UserDefaults.standard.set(showInDock, forKey: Key.showInDock)
            applyActivationPolicy()
        }
    }

    var islandAppearance: IslandAppearance {
        didSet {
            UserDefaults.standard.set(islandAppearance.rawValue, forKey: Key.islandAppearance)
        }
    }

    /// 登录时自动启动（系统"登录项"里的岛民）
    private(set) var launchAtLogin = false
    /// 用户需要去系统设置里批准登录项
    private(set) var launchAtLoginNeedsApproval = false

    private init() {
        UserDefaults.standard.register(defaults: [Key.showInDock: true])
        showInDock = UserDefaults.standard.bool(forKey: Key.showInDock)
        islandAppearance = IslandAppearance(
            rawValue: UserDefaults.standard.string(forKey: Key.islandAppearance) ?? ""
        ) ?? .automatic
        refreshLaunchAtLogin()
    }

    // MARK: - Dock

    /// Info.plist 里是 LSUIElement（默认不进 Dock），启动时和切换开关时按设置改
    func applyActivationPolicy() {
        let policy: NSApplication.ActivationPolicy = showInDock ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        // 切换策略时系统会把本 App 的窗口一起藏到后面，切完把前台的窗口拉回来
        let visible = NSApp.windows.filter { $0.isVisible && $0.canBecomeKey }
        NSApp.setActivationPolicy(policy)
        if !visible.isEmpty {
            NSApp.activate()
            visible.forEach { $0.orderFrontRegardless() }
            visible.first?.makeKey()
        }
    }

    // MARK: - 登录时启动

    func refreshLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        launchAtLoginNeedsApproval = status == .requiresApproval
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("登录项\(enabled ? "注册" : "取消", privacy: .public)失败：\(error.localizedDescription, privacy: .public)")
        }
        refreshLaunchAtLogin()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
