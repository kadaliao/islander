import AppKit
import ApplicationServices

/// 把别的 App 从菜单栏图标下弹出的窗口（控制中心的面板、第三方 App 的小弹窗）挪到岛上被点的图标下方。
///
/// 这些窗口是 App 自己贴着真实图标摆的：真实图标可能在菜单栏另一头；多屏时"按下"打开的位置还跟着
/// 活动的那一行菜单栏走，可能弹在另一块屏幕上。系统没有"在指定位置打开"的接口，只能等它出来以后
/// 用辅助功能改窗口位置（实测 macOS 26.7：控制中心的面板、多数第三方弹窗都改得动，改完不会自己关）。
/// 真正的 NSMenu 不是辅助功能窗口，改不了——那种走镜像菜单。
///
/// 只挪贴着图标弹出的窗口。有的图标点了只是把 App 的主窗口带到前面，那种窗口不在图标下面，不能动。
/// 所有坐标都是 CG 全局坐标（原点在主屏左上角）。
enum PopupRelocator {
    struct Destination: Sendable {
        /// 被点图标的水平中心
        let midX: CGFloat
        /// 弹窗原本贴着菜单栏底边的那条线，挪过来以后贴在这里（岛的底边下面一点）
        let top: CGFloat
        /// 岛所在的屏幕
        let screen: CGRect

        /// - Parameter anchor: 被点图标在岛窗口里的位置（SwiftUI 全局坐标，原点在左上）
        @MainActor
        init?(under anchor: CGRect, of model: NotchViewModel) {
            guard let window = model.hostView?.window else { return nil }
            let geometry = model.geometry
            midX = anchor.isEmpty ? geometry.notchRect.midX : window.frame.minX + anchor.midX
            top = geometry.menuBarRowTop + model.layout.expanded.height + 4
            screen = CGRect(x: geometry.screenFrame.minX, y: geometry.menuBarRowTop,
                            width: geometry.screenFrame.width, height: geometry.screenFrame.height)
        }
    }

    /// 一块屏幕和它的菜单栏底边
    struct MenuBar: Sendable {
        let screen: CGRect
        let bottom: CGFloat

        /// 图标在这块屏幕的菜单栏里（菜单栏自动隐藏时图标在屏幕顶边上方一点，也算）
        func holds(_ item: CGRect) -> Bool {
            item.minX >= screen.minX && item.maxX <= screen.maxX && abs(item.midY - screen.minY) < 45
        }
    }

    @MainActor
    static func menuBars() -> [MenuBar] {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return NSScreen.screens.map { screen in
            let frame = screen.frame
            let top = primaryTop - frame.maxY
            // 菜单栏自动隐藏时 visibleFrame 顶到屏幕顶，退回状态栏的标准高度
            let height = max(frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top, NSStatusBar.system.thickness)
            return MenuBar(screen: CGRect(x: frame.minX, y: top, width: frame.width, height: frame.height),
                           bottom: top + height)
        }
    }

    /// - Parameters:
    ///   - windows: "按下"之后这个 App 新出现的窗口
    ///   - item: 真实图标按下时的位置（藏起来的图标在屏幕外）
    ///   - bar: 活动的那一行菜单栏
    /// - Returns: 是否挪动了至少一个窗口
    @concurrent
    static func relocate(_ windows: Set<CGWindowID>, anchoredTo item: CGRect,
                         in bar: MenuBar, to destination: Destination) async -> Bool {
        // 跨屏挪过来的系统面板不显示（实测），活动行不在岛这块屏幕上就不挪
        guard bar.screen == destination.screen else { return false }
        let delta = CGVector(dx: destination.midX - item.midX, dy: destination.top - bar.bottom)
        // 本来就在被点的图标下面（"显示全部"时真实图标恰好挨着岛），不用动
        guard abs(delta.dx) > 1 || abs(delta.dy) > 1 else { return false }
        let itemOnScreen = bar.holds(item)

        // 窗口出现时可能带一小段位移动画：等位置稳定再动
        var frames = InterfaceWatcher.placements(of: windows)
        for _ in 0..<5 {
            try? await Task.sleep(for: .milliseconds(20))
            let now = InterfaceWatcher.placements(of: windows)
            if now == frames { break }
            frames = now
        }
        /// 贴着图标弹出的：水平方向和图标有交集
        func hugsItem(_ frame: CGRect) -> Bool {
            frame.minX - 24 <= item.maxX && frame.maxX + 24 >= item.minX
        }
        // 贴着菜单栏底边、在图标下面的才是弹窗。图标在屏幕外时 App 可能把弹窗贴到屏幕边上，那种也算
        let anchored = frames.values.filter { placement in
            let frame = placement.frame
            return frame.width > 8 && frame.height > 8
                && frame.minY >= bar.screen.minY - 1 && frame.minY <= bar.bottom + 30
                && (hugsItem(frame) || !itemOnScreen)
        }
        guard !anchored.isEmpty else { return false }

        var moved = false
        // 弹窗不一定属于图标所在的进程（飞书的图标在辅助进程里，弹窗是主进程的）
        for pid in Set(anchored.map(\.pid)) {
            let targets = anchored.filter { $0.pid == pid }.map(\.frame)
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.5)
            for element in AX.elements(app, kAXWindowsAttribute) {
                guard let frame = AX.frame(element),
                      targets.contains(where: { abs($0.minX - frame.minX) < 2 && abs($0.minY - frame.minY) < 2
                          && abs($0.width - frame.width) < 2 && abs($0.height - frame.height) < 2 })
                else { continue }
                // 普通窗口（App 的主窗口等）碰巧在那个位置：不是弹窗，不能动
                if AX.string(element, kAXSubroleAttribute) == kAXStandardWindowSubrole { continue }
                // 贴着图标的保持和图标的相对位置；被贴到屏幕边上的，居中放在被点的图标下面。水平方向不出岛所在的屏幕
                let x = hugsItem(frame) ? frame.minX + delta.dx : destination.midX - frame.width / 2
                let maxX = max(destination.screen.maxX - frame.width, destination.screen.minX)
                var origin = CGPoint(x: min(max(x, destination.screen.minX), maxX), y: frame.minY + delta.dy)
                guard let value = AXValueCreate(.cgPoint, &origin),
                      AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success,
                      let after = AX.frame(element), abs(after.minX - origin.x) < 2, abs(after.minY - origin.y) < 2
                else { continue }
                moved = true
            }
        }
        return moved
    }
}
