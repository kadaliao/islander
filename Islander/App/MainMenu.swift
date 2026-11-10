import AppKit

/// App 在前台时（设置窗口、调试面板）屏幕顶上的菜单。在 Dock 里显示时才看得到，
/// 不显示时也要有：⌘W、⌘Q、⌘C / ⌘V 这些快捷键靠它生效。
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()

        let app = submenu(of: main, title: "岛民")
        app.addItem(item("关于岛民", #selector(Actions.about), target: Actions.shared))
        app.addItem(item("检查更新…", #selector(Actions.checkForUpdates), target: Actions.shared))
        app.addItem(.separator())
        app.addItem(item("设置…", #selector(Actions.settings), key: ",", target: Actions.shared))
        app.addItem(.separator())
        app.addItem(item("隐藏岛民", #selector(NSApplication.hide(_:)), key: "h"))
        let hideOthers = item("隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), key: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(hideOthers)
        app.addItem(item("全部显示", #selector(NSApplication.unhideAllApplications(_:))))
        app.addItem(.separator())
        app.addItem(item("退出岛民", #selector(NSApplication.terminate(_:)), key: "q"))

        let edit = submenu(of: main, title: "编辑")
        edit.addItem(item("撤销", Selector(("undo:")), key: "z"))
        let redo = item("重做", Selector(("redo:")), key: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(item("剪切", #selector(NSText.cut(_:)), key: "x"))
        edit.addItem(item("拷贝", #selector(NSText.copy(_:)), key: "c"))
        edit.addItem(item("粘贴", #selector(NSText.paste(_:)), key: "v"))
        edit.addItem(item("全选", #selector(NSText.selectAll(_:)), key: "a"))

        let window = submenu(of: main, title: "窗口")
        window.addItem(item("最小化", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        window.addItem(item("关闭", #selector(NSWindow.performClose(_:)), key: "w"))
        NSApp.windowsMenu = window

        return main
    }

    private static func submenu(of main: NSMenu, title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        main.addItem(holder)
        return menu
    }

    private static func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }

    @MainActor
    private final class Actions: NSObject {
        static let shared = Actions()
        @objc func about() { SettingsController.shared.show(.about) }
        @objc func settings() { SettingsController.shared.show() }
        @objc func checkForUpdates() { Task { await Updater.shared.check(userInitiated: true) } }
    }
}
