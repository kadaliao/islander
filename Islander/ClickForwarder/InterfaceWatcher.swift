import CoreGraphics
import Foundation

/// 判断点开的菜单 / 弹窗什么时候关闭：对比点击前后这个进程在屏幕上的窗口。
/// 菜单栏图标本身的窗口（状态栏层级）不算。所有轮询都在后台线程。
enum InterfaceWatcher {
    @concurrent
    static func windows(of pid: pid_t) async -> Set<CGWindowID> {
        onScreenWindows(of: pid)
    }

    /// 先最多等 1.5 秒看有没有新窗口出现；出现了就等它们全部消失。
    /// 没检测到新窗口（比如点一下只是切换状态的图标），给 2 秒宽限再返回。
    /// - Returns: 是否检测到了弹出的界面
    @discardableResult
    @concurrent
    static func waitUntilClosed(pid: pid_t, baseline: Set<CGWindowID>) async -> Bool {
        var opened = Set<CGWindowID>()
        for _ in 0..<15 {
            opened = onScreenWindows(of: pid).subtracting(baseline)
            if !opened.isEmpty { break }
            guard (try? await Task.sleep(for: .milliseconds(100))) != nil else { return false }
        }

        guard !opened.isEmpty else {
            try? await Task.sleep(for: .seconds(2))
            return false
        }

        // 最长等 10 分钟，防止异常情况下一直露着
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            guard (try? await Task.sleep(for: .milliseconds(150))) != nil else { return true }
            if onScreenWindows(of: pid).isDisjoint(with: opened) { break }
        }
        // 等菜单的淡出动画走完再收，避免菜单栏在它眼皮底下移动
        try? await Task.sleep(for: .milliseconds(150))
        return true
    }

    private static func onScreenWindows(of pid: pid_t) -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let statusLayer = Int(CGWindowLevelForKey(.statusWindow))
        var result = Set<CGWindowID>()
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) != statusLayer,
                  let number = info[kCGWindowNumber as String] as? NSNumber
            else { continue }
            result.insert(number.uint32Value)
        }
        return result
    }
}
