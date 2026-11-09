import SwiftUI

/// 灵动岛外形：顶边与屏幕上沿齐平，底部两角是连续曲率圆角，顶部两侧可带内凹的"肩"。
///
/// 宽、高、底部圆角、肩部圆角全部放进 `animatableData`，
/// SwiftUI 在同一个弹簧里对它们一起插值——外形是连续变形，不会先变宽再变高。
/// 外形在画布里水平居中、贴顶绘制，画布（窗口）本身在动画过程中不改尺寸。
struct NotchShape: Shape, Equatable {
    var width: CGFloat
    var height: CGFloat
    var bottomRadius: CGFloat
    var shoulderRadius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(width, height), AnimatablePair(bottomRadius, shoulderRadius)) }
        set {
            width = newValue.first.first
            height = newValue.first.second
            bottomRadius = newValue.second.first
            shoulderRadius = newValue.second.second
        }
    }

    /// 连续曲率圆角沿每条边占用的长度 = 1.52866483 × 半径
    private static let cornerExtent: CGFloat = 1.52866483
    /// 用三次贝塞尔近似四分之一圆的控制点系数
    private static let arcKappa: CGFloat = 0.5522847

    func path(in rect: CGRect) -> Path {
        // 弹簧收起时可能略微冲过头，尺寸先夹到非负
        let w = max(width, 0)
        let h = max(height, 0)
        guard w > 0.5, h > 0.5 else { return Path() }

        let left = rect.midX - w / 2
        let right = rect.midX + w / 2
        let top = rect.minY
        let bottom = top + h

        let rs = min(max(shoulderRadius, 0), h / 2)
        let rb = min(max(bottomRadius, 0), (h - rs) / Self.cornerExtent, w / (2 * Self.cornerExtent))
        let k = 1 - Self.arcKappa

        var path = Path()
        path.move(to: CGPoint(x: left - rs, y: top))
        path.addLine(to: CGPoint(x: right + rs, y: top))
        if rs > 0 {
            // 右肩：从屏幕上沿内凹地转进右侧竖边，两端都相切
            path.addCurve(to: CGPoint(x: right, y: top + rs),
                          control1: CGPoint(x: right + rs * k, y: top),
                          control2: CGPoint(x: right, y: top + rs * k))
        }
        path.addContinuousCorner(at: CGPoint(x: right, y: bottom),
                                 incoming: CGVector(dx: 0, dy: 1),
                                 outgoing: CGVector(dx: -1, dy: 0),
                                 radius: rb)
        path.addContinuousCorner(at: CGPoint(x: left, y: bottom),
                                 incoming: CGVector(dx: -1, dy: 0),
                                 outgoing: CGVector(dx: 0, dy: -1),
                                 radius: rb)
        path.addLine(to: CGPoint(x: left, y: top + rs))
        if rs > 0 {
            path.addCurve(to: CGPoint(x: left - rs, y: top),
                          control1: CGPoint(x: left, y: top + rs * k),
                          control2: CGPoint(x: left - rs * k, y: top))
        }
        path.closeSubpath()
        return path
    }
}

extension Path {
    /// 苹果风格的连续曲率圆角（与 `RoundedRectangle(style: .continuous)` 同一套曲线）。
    /// - Parameters:
    ///   - corner: 直角的顶点
    ///   - incoming: 走向顶点那条边的方向（单位向量）
    ///   - outgoing: 离开顶点那条边的方向（单位向量）
    mutating func addContinuousCorner(at corner: CGPoint, incoming u: CGVector, outgoing v: CGVector, radius r: CGFloat) {
        // (a, b)：沿来边往回 a·r、沿去边往前 b·r
        func point(_ a: CGFloat, _ b: CGFloat) -> CGPoint {
            CGPoint(x: corner.x - a * r * u.dx + b * r * v.dx,
                    y: corner.y - a * r * u.dy + b * r * v.dy)
        }
        addLine(to: point(1.52866483, 0))
        addCurve(to: point(0.63149399, 0.07491100),
                 control1: point(1.08849323, 0),
                 control2: point(0.86840689, 0))
        addCurve(to: point(0.07491100, 0.63149399),
                 control1: point(0.37282392, 0.16905300),
                 control2: point(0.16905300, 0.37282392))
        addCurve(to: point(0, 1.52866483),
                 control1: point(0, 0.86840689),
                 control2: point(0, 1.08849323))
    }
}
