import AppKit

/// 右键菜单栏上的岛民图标、右键 Dock 图标弹出的菜单
@MainActor
final class AppMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu()

    override init() {
        super.init()
        menu.delegate = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        addCommonItems(to: menu)
        menu.addItem(.separator())
        addItem("退出岛民", #selector(quit), key: "q", to: menu)
    }

    /// Dock 菜单：系统会自己加上"退出"等项
    func makeDockMenu() -> NSMenu {
        let menu = NSMenu()
        addCommonItems(to: menu)
        return menu
    }

    private func addCommonItems(to menu: NSMenu) {
        if addUpdateItem(to: menu) { menu.addItem(.separator()) }
        addItem(MenuBarHider.shared.isHidden ? "显示藏起来的图标" : "藏起图标", #selector(toggleHidden), to: menu)
        addItem("展开 / 收起灵动岛", #selector(toggleIsland), to: menu)
        addItem("在岛上显示全部图标", #selector(toggleShowAll), to: menu)
            .state = HiddenItemsStore.shared.showAllItems ? .on : .off
        menu.addItem(.separator())
        addItem("菜单栏布局…", #selector(openLayout), to: menu)
        addItem("设置…", #selector(openSettings), key: ",", to: menu)
        addItem("检查更新…", #selector(checkForUpdates), to: menu)
    }

    /// 有新版本时排在最前面；没有时不加
    private func addUpdateItem(to menu: NSMenu) -> Bool {
        let updater = Updater.shared
        guard let version = updater.release?.version else { return false }
        let title = switch updater.state {
        case .downloading: "正在下载岛民 \(version)…"
        case .installing: "正在安装岛民 \(version)…"
        case .installed: "重新打开以完成更新到 \(version)"
        default: updater.blocker == nil ? "更新到岛民 \(version)" : "下载岛民 \(version)…"
        }
        addItem(title, #selector(update), to: menu).image =
            NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
        return true
    }

    @discardableResult
    private func addItem(_ title: String, _ action: Selector, key: String = "", to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func toggleHidden() { MenuBarHider.shared.toggle() }
    @objc private func toggleIsland() { ScreenManager.shared.toggleAll() }
    @objc private func toggleShowAll() { HiddenItemsStore.shared.showAllItems.toggle() }
    @objc private func openLayout() { SettingsController.shared.show(.layout) }
    @objc private func openSettings() { SettingsController.shared.show() }
    @objc private func checkForUpdates() { Task { await Updater.shared.check(userInitiated: true) } }
    @objc private func update() { Task { await Updater.shared.update() } }
    @objc private func quit() { NSApp.terminate(nil) }
}

extension AppMenu: NSMenuItemValidation {
    /// 下载、安装进行中时，更新相关的两项不能点
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(update), #selector(checkForUpdates): !Updater.shared.isWorking
        default: true
        }
    }
}
