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

/// 第一次点击就响应（面板不激活 App，默认第一次点击会被当成"激活窗口"吞掉）
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
