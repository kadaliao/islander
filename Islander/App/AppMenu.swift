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
        addItem(MenuBarHider.shared.isHidden ? "显示藏起来的图标" : "藏起图标", #selector(toggleHidden), to: menu)
        addItem("展开 / 收起灵动岛", #selector(toggleIsland), to: menu)
        addItem("在岛上显示全部图标", #selector(toggleShowAll), to: menu)
            .state = HiddenItemsStore.shared.showAllItems ? .on : .off
        menu.addItem(.separator())
        addItem("菜单栏布局…", #selector(openLayout), to: menu)
        addItem("设置…", #selector(openSettings), key: ",", to: menu)
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
    @objc private func quit() { NSApp.terminate(nil) }
}
