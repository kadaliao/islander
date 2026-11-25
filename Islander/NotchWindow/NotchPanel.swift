import AppKit
import SwiftUI

/// 承载灵动岛的无边框面板：不激活 App、不抢键盘焦点、层级高于菜单栏、所有空间和全屏 App 上都在。
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        // 菜单栏是 .mainMenu(24)，状态栏图标是 .statusBar(25)；弹出菜单是 .popUpMenu(101)，要在它下面
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        // 默认点击穿透；只有展开且指针在岛上时才接收鼠标
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 系统默认会把窗口挤到菜单栏下面，这里要盖住菜单栏和刘海
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// 第一次点击就响应（面板不激活 App，默认第一次点击会被当成"激活窗口"吞掉）。
/// 右键也在这里接：SwiftUI 的按钮只管左键，右键要送给真实图标（#8 的 QQ 右键菜单）
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    weak var model: NotchViewModel?

    /// 正按着的右键：按下时指针下的图标，松开时还在它上面才算点了它
    private var secondaryID: String?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        if !beginSecondaryClick(event) { super.rightMouseDown(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        if !endSecondaryClick(event) { super.rightMouseUp(with: event) }
    }

    private func item(under event: NSEvent) -> HiddenItemsStore.Item? {
        let point = convert(event.locationInWindow, from: nil)
        return model?.item(at: isFlipped ? point : CGPoint(x: point.x, y: bounds.height - point.y))
    }

    private func beginSecondaryClick(_ event: NSEvent) -> Bool {
        guard let item = item(under: event) else { return false }
        secondaryID = item.id
        model?.setPressed(item.id)
        return true
    }

    /// - Returns: 是不是这次右键的松开（是的话事件就不再交给 SwiftUI）
    private func endSecondaryClick(_ event: NSEvent) -> Bool {
        guard let pressed = secondaryID else { return false }
        secondaryID = nil
        model?.setPressed(nil)
        if let model, let item = item(under: event), item.id == pressed {
            model.open(item, button: .right)
        }
        return true
    }
}
