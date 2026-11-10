import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appMenu = AppMenu()

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        AppSettings.shared.applyActivationPolicy()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Permissions.shared.startMonitoring()
        MenuBarHider.shared.start(contextMenu: appMenu.menu)
        ScreenManager.shared.start()
        HiddenItemsStore.shared.start()
        SettingsController.shared.showIfNeeded()
        Updater.shared.start()
        #if DEBUG
        DebugHooks.install()
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        MenuBarHider.shared.prepareForTermination()
        Updater.shared.installOnQuit()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 点 Dock 图标，或者 App 已经在运行时又从访达 / 启动台打开一次：打开设置
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsController.shared.show()
        return false
    }

    /// 右键 Dock 图标
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        appMenu.makeDockMenu()
    }
}
