import AppKit

/// 给每块需要的屏幕建一个岛窗口，显示器配置变化时重建。
/// 阶段 1：有真刘海的屏幕各一个；一个都没有时，在主屏画虚拟刘海兜底。
/// 阶段 4 在这里加虚拟刘海模式、合盖、全屏 / 自动隐藏菜单栏等处理。
@MainActor
final class ScreenManager {
    static let shared = ScreenManager()

    private(set) var controllers: [NotchWindowController] = []
    private let mouse = MouseMonitor()
    private var screenObserver: NSObjectProtocol?

    private init() {}

    func start() {
        rebuild()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { ScreenManager.shared.rebuild() }
        }

        mouse.onMove = { [weak self] point in
            guard let self, !self.isSuspended else { return }
            self.controllers.forEach { $0.pointerMoved(to: point) }
        }
        mouse.onFlagsChanged = { [weak self] flags in
            guard let self, !self.isSuspended else { return }
            self.controllers.forEach { $0.modifiersChanged(flags) }
        }
        mouse.start()
    }

    func rebuild() {
        var targets = NSScreen.screens.compactMap(NotchGeometry.init(physicalNotchOn:))
        if targets.isEmpty, let main = NSScreen.main, let virtual = NotchGeometry(virtualNotchOn: main) {
            targets = [virtual]
        }

        // 几何没变的窗口保留，避免插拔显示器时无关的岛闪一下
        var kept: [NotchWindowController] = []
        for controller in controllers {
            if targets.contains(controller.geometry) {
                kept.append(controller)
            } else {
                controller.close()
            }
        }
        for geometry in targets where !kept.contains(where: { $0.geometry == geometry }) {
            let controller = NotchWindowController(geometry: geometry)
            if isPinned { controller.setPinned(true) }
            kept.append(controller)
        }
        controllers = kept
    }

    // MARK: - 菜单 / 设置用

    func expandAll() { controllers.forEach { $0.expand() } }
    func collapseAll() { controllers.forEach { $0.collapse() } }

    func toggleAll() {
        if controllers.contains(where: { $0.model.isExpanded }) {
            collapseAll()
        } else {
            expandAll()
        }
    }

    var isPinned = false {
        didSet { controllers.forEach { $0.setPinned(isPinned) } }
    }

    /// 替用户拖动菜单栏图标期间：岛收起，不响应悬停（合成的拖动会经过刘海附近）
    var isSuspended = false {
        didSet { if isSuspended { collapseAll() } }
    }
}
