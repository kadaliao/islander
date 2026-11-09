import AppKit

/// 一块屏幕上刘海的位置。坐标都是 AppKit 全局坐标（原点在主屏左下角，y 向上）。
struct NotchGeometry: Equatable {
    let displayID: CGDirectDisplayID
    let screenFrame: CGRect
    let notchRect: CGRect
    /// false 表示屏幕没有刘海，这是画出来的"虚拟刘海"
    let isPhysical: Bool
    /// 这块屏幕菜单栏顶边的 CG 坐标 y（CG 原点在主屏左上角），用来找这块屏幕上那一行菜单栏图标
    let menuBarRowTop: CGFloat

    var notchSize: CGSize { notchRect.size }
    var screenTop: CGFloat { screenFrame.maxY }

    /// 真刘海：safeAreaInsets.top 是刘海高度，左右两块辅助区之间的空隙就是刘海宽度。
    /// 只用辅助区的宽度，不用它们的 origin——不同系统版本上 origin 的参照系不一致。
    init?(physicalNotchOn screen: NSScreen) {
        let height = screen.safeAreaInsets.top
        guard height > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              let displayID = screen.displayID
        else { return nil }

        let frame = screen.frame
        let minX = frame.minX + left.width
        let maxX = frame.maxX - right.width
        guard maxX > minX else { return nil }

        self.displayID = displayID
        self.screenFrame = frame
        self.notchRect = CGRect(x: minX, y: frame.maxY - height, width: maxX - minX, height: height)
        self.isPhysical = true
        self.menuBarRowTop = Self.cgTop(of: frame)
    }

    /// 无刘海屏幕上的虚拟刘海：菜单栏正中间，高度跟菜单栏一致。
    /// 阶段 1 只在找不到真刘海时兜底用，方便在外接屏 / Mac mini 上也能调手感；阶段 4 再做完整的模式切换。
    init?(virtualNotchOn screen: NSScreen, width: CGFloat = 185) {
        guard let displayID = screen.displayID else { return nil }
        let frame = screen.frame
        let menuBarHeight = frame.maxY - screen.visibleFrame.maxY
        let height = menuBarHeight > 0 ? menuBarHeight : 32
        self.displayID = displayID
        self.screenFrame = frame
        self.notchRect = CGRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height)
        self.isPhysical = false
        self.menuBarRowTop = Self.cgTop(of: frame)
    }

    private static func cgTop(of frame: CGRect) -> CGFloat {
        (NSScreen.screens.first?.frame.maxY ?? frame.maxY) - frame.maxY
    }

}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
