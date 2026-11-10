import CoreGraphics
import Foundation

/// 判断点开的菜单 / 弹窗什么时候关闭：对比点击前后这个 App（含它的辅助进程）在屏幕上的窗口。
/// 菜单栏图标本身的窗口（状态栏层级）不算。所有轮询都在后台线程。
enum InterfaceWatcher {
    @concurrent
    static func windows(of pids: Set<pid_t>) async -> Set<CGWindowID> {
        onScreenWindows(of: pids)
    }

    /// 等这个进程弹出新窗口，最多等 `timeout`。
    /// - Returns: 新出现的窗口；一个都没有（比如点一下只是切换状态、或者只是把主窗口带到前面）时为空
    @concurrent
    static func waitUntilOpened(pids: Set<pid_t>, baseline: Set<CGWindowID>, timeout: Duration) async -> Set<CGWindowID> {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let opened = onScreenWindows(of: pids).subtracting(baseline)
            if !opened.isEmpty { return opened }
            guard (try? await Task.sleep(for: .milliseconds(20))) != nil else { return [] }
        }
        return []
    }

    /// 等弹出的窗口全部消失
    @concurrent
    static func waitUntilClosed(pids: Set<pid_t>, opened: Set<CGWindowID>) async {
        // 最长等 10 分钟，防止异常情况下一直露着
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            guard (try? await Task.sleep(for: .milliseconds(150))) != nil else { return }
            if onScreenWindows(of: pids).isDisjoint(with: opened) { break }
        }
        // 等菜单的淡出动画走完再收，避免菜单栏在它眼皮底下移动
        try? await Task.sleep(for: .milliseconds(150))
    }

    struct Placement: Equatable, Sendable {
        let pid: pid_t
        let frame: CGRect
    }

    /// 这些窗口现在的位置（CG 全局坐标）和所属进程
    static func placements(of windows: Set<CGWindowID>) -> [CGWindowID: Placement] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var result: [CGWindowID: Placement] = [:]
        for info in list {
            guard let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value, windows.contains(number),
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds)
            else { continue }
            result[number] = Placement(pid: pid, frame: frame)
        }
        return result
    }

    private static func onScreenWindows(of pids: Set<pid_t>) -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let statusLayer = Int(CGWindowLevelForKey(.statusWindow))
        var result = Set<CGWindowID>()
        for info in list {
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(owner),
                  (info[kCGWindowLayer as String] as? Int) != statusLayer,
                  let number = info[kCGWindowNumber as String] as? NSNumber
            else { continue }
            result.insert(number.uint32Value)
        }
        return result
    }
}
