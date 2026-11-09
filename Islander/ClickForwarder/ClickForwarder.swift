import AppKit
import ApplicationServices
import os

private let log = Logger(subsystem: "com.kadaliao.islander", category: "click")

/// 点击岛上的图标：
/// - 读得到菜单的（多数 App）：在被点图标的正下方弹出一份"镜像菜单"，选中后转给 App 执行。
///   不挪动任何图标，也不动光标，菜单紧贴着岛展开。
/// - 读不到菜单的（弹自己小窗口的 App，如微信）：把隐藏的图标临时露出来，对真实图标"按下"，
///   界面在活动的那块屏幕的菜单栏下弹出；关闭后重新隐藏。
@MainActor
final class ClickForwarder {
    static let shared = ClickForwarder()

    private var session: Task<Void, Never>?

    private init() {}

    /// - Parameters:
    ///   - isHidden: 图标在隐藏区；不在的话（"显示全部图标"时）退路里不用先露出隐藏区
    ///   - needsFullReveal: 图标在永远隐藏分隔符左边，退路里要两条分隔符都缩回才能露出来
    ///   - model: 被点的那个岛
    ///   - anchor: 被点图标在岛窗口里的位置（SwiftUI 全局坐标，原点在左上）
    func open(_ item: MenuBarItem, isHidden: Bool, needsFullReveal: Bool = false,
              from model: NotchViewModel, anchor: CGRect) {
        guard session == nil else { return }
        session = Task {
            defer { session = nil }
            if let view = model.hostView, let entries = await MenuMirror.read(item) {
                await showMirror(entries, of: item, model: model, anchor: anchor, in: view)
            } else {
                log.info("\(item.id, privacy: .public) 读不到菜单，改为在菜单栏里打开")
                ScreenManager.shared.collapseAll()
                await openInMenuBar(item, reveal: isHidden, alwaysHidden: needsFullReveal)
            }
        }
    }

    private func showMirror(_ entries: [MirroredMenuItem], of item: MenuBarItem,
                            model: NotchViewModel, anchor: CGRect, in view: NSView) async {
        // 菜单左上角对齐图标左下角，留一点间隙
        let gap: CGFloat = 6
        let y = view.isFlipped ? anchor.maxY + gap : view.bounds.height - anchor.maxY - gap
        let point = NSPoint(x: anchor.minX, y: y)

        model.menuDidOpen(item.id)
        let chosen = MirrorMenuPresenter().popUp(entries, at: point, in: view, style: model.style)
        model.menuDidClose(choseItem: chosen != nil)

        if let chosen {
            let result = await MenuMirror.perform(chosen)
            log.info("转给 \(item.id, privacy: .public) 执行：AXError \(result.rawValue)")
        }
    }

    // MARK: - 退路：在菜单栏里打开（隐藏的图标先整段临时露出）

    private func openInMenuBar(_ item: MenuBarItem, reveal: Bool, alwaysHidden: Bool) async {
        let scanner = HiddenItemsStore.shared.scanner
        let hider = MenuBarHider.shared
        let revealed = alwaysHidden || (reveal && hider.isHidden)
        if revealed { hider.beginTemporaryReveal(includingAlwaysHidden: alwaysHidden) }
        defer { if revealed { hider.endTemporaryReveal() } }

        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let screens = NSScreen.screens.map { screen in
            CGRect(x: screen.frame.minX, y: primaryTop - screen.frame.maxY,
                   width: screen.frame.width, height: screen.frame.height)
        }
        var visible = false
        for _ in 0..<50 {
            if let frame = await scanner.frame(of: item.element), screens.contains(where: { $0.contains(frame) }) {
                visible = true
                break
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
        guard visible else {
            log.error("\(item.id, privacy: .public) 露出后仍不在屏幕上，放弃")
            return
        }
        let baseline = await InterfaceWatcher.windows(of: item.pid)
        _ = await scanner.press(item.element)
        await InterfaceWatcher.waitUntilClosed(pid: item.pid, baseline: baseline)
    }
}
