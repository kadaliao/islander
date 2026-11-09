import AppKit

/// 全局 + 本地鼠标移动监听。
/// 岛窗口收起时完全不接收鼠标事件（点击穿透到菜单栏），所以悬停检测不能靠窗口自己的 tracking area。
/// 监听鼠标移动不需要辅助功能权限（只有键盘事件需要）。
@MainActor
final class MouseMonitor {
    var onMove: ((NSPoint) -> Void)?
    /// 修饰键变化（按住 ⌥ 显示永远隐藏的图标）
    var onFlagsChanged: ((NSEvent.ModifierFlags) -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?

    func start() {
        guard globalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]

        // 发给其他 App 的事件
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { self?.emit() }
        }
        // 发给本 App 的事件（鼠标在岛上、或调试面板在前台时）
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.emit() }
            return event
        }
        // 全局监听修饰键需要辅助功能权限，岛民本来就要
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let flags = event.modifierFlags
            MainActor.assumeIsolated { self?.onFlagsChanged?(flags) }
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let flags = event.modifierFlags
            MainActor.assumeIsolated { self?.onFlagsChanged?(flags) }
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalFlagsMonitor { NSEvent.removeMonitor(globalFlagsMonitor) }
        if let localFlagsMonitor { NSEvent.removeMonitor(localFlagsMonitor) }
        globalMonitor = nil
        localMonitor = nil
        globalFlagsMonitor = nil
        localFlagsMonitor = nil
    }

    private func emit() {
        onMove?(NSEvent.mouseLocation)
    }
}
