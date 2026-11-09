import CoreGraphics
import Foundation

/// 菜单栏图标窗口按"行"分组：开了"显示器具有单独的空间"时，每块屏幕都有一份菜单栏，
/// 每个图标在每一行里各有一个窗口（macOS 26 上都归 Control Center）。坐标为 CG 全局坐标（原点在主屏左上）。
///
/// 同一时刻只有一行是"活动的"：辅助功能报告的位置、"按下"打开菜单的位置都跟着活动行走，
/// 也只有活动行里的窗口截得到内容（其他行截出来是透明的）。
struct StatusBarRows: Sendable {
    struct Window: Sendable, Equatable {
        let id: CGWindowID
        let frame: CGRect
        let ownerPID: pid_t
        let isOnScreen: Bool
        /// 窗口标题：macOS 26 上是状态栏图标的 autosaveName（"Item-0"、"IslanderSeparator"……）。
        /// 要屏幕录制权限才读得到
        var name: String? = nil
    }

    let windows: [Window]

    static func current() -> StatusBarRows {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return StatusBarRows(windows: [])
        }
        let statusLayer = Int(CGWindowLevelForKey(.statusWindow))
        let windows: [Window] = list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == statusLayer,
                  let number = info[kCGWindowNumber as String] as? NSNumber,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds)
            else { return nil }
            let onScreen = (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
            return Window(id: number.uint32Value, frame: frame, ownerPID: pid, isOnScreen: onScreen,
                          name: info[kCGWindowName as String] as? String)
        }
        return StatusBarRows(windows: windows)
    }

    /// 某一行（菜单栏顶边 y）的所有窗口，从左到右。
    /// 同一位置偶尔有两个完全重叠的窗口（实测内置屏那一行会出现），只留一个，优先留在屏幕上的
    func row(top: CGFloat) -> [Window] {
        var byFrame: [String: Window] = [:]
        for window in windows where abs(window.frame.minY - top) < 1 {
            let key = "\(window.frame)"
            if let existing = byFrame[key], existing.isOnScreen || !window.isOnScreen { continue }
            byFrame[key] = window
        }
        return byFrame.values.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// 一行里真正排在菜单栏上的图标窗口，从左到右：从最右边（时钟）开始，沿着首尾相接的边一路往左。
    /// 窗口服务器的位置是实时的，比辅助功能报告的位置可靠。不在这条链上的是还没排好的占位窗口
    /// （实测 (0, 0) 处会挂着岛民自己图标的几个副本）
    func chain(top: CGFloat) -> [Window] {
        let candidates = row(top: top)
        guard var current = candidates.max(by: { $0.frame.minX < $1.frame.minX }) else { return [] }
        var result = [current]
        while let next = candidates.first(where: { window in
            abs(window.frame.maxX - current.frame.minX) < 1 && !result.contains { $0.id == window.id }
        }) {
            result.insert(next, at: 0)
            current = next
        }
        return result
    }

    /// 包含某点的图标窗口（排除隐藏状态下超宽的分隔符）
    func window(containing point: CGPoint) -> Window? {
        windows
            .filter { $0.frame.contains(point) && $0.frame.width < 1000 }
            .min { $0.frame.width < $1.frame.width }
    }

    /// 同一个图标在另一行里的窗口：各行里图标顺序相同、右对齐，按"从右数第几个"对应，宽度必须一致
    func counterpart(of window: Window, inRowTop top: CGFloat) -> Window? {
        if abs(window.frame.minY - top) < 1 { return window }
        // 隐藏状态下超宽的分隔符右边缘远在屏幕外，会把排名带偏，不参与排名
        func ranked(_ top: CGFloat) -> [Window] {
            row(top: top).filter { $0.frame.width < 1000 }.sorted { $0.frame.maxX > $1.frame.maxX }
        }
        let source = ranked(window.frame.minY)
        let target = ranked(top)
        guard let rank = source.firstIndex(where: { $0.frame == window.frame }) else { return nil }
        // 偶尔有只出现在某一行的系统图标（比如录屏指示），允许错开一两位
        for offset in [0, -1, 1, -2, 2] {
            let index = rank + offset
            guard target.indices.contains(index) else { continue }
            if abs(target[index].frame.width - window.frame.width) < 1 {
                return target[index]
            }
        }
        return nil
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
