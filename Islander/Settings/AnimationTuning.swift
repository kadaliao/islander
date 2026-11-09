import SwiftUI

/// 灵动岛的全部手感参数。调试面板直接改这里，改动实时生效并存进 UserDefaults。
/// 时间单位一律是秒，尺寸单位是 pt。
struct AnimationTuning: Codable, Equatable {
    // 外形展开：带轻微回弹
    var expandResponse = 0.46
    var expandDamping = 0.78
    // 外形收起：更快、几乎不回弹
    var collapseResponse = 0.30
    var collapseDamping = 0.95
    /// 收起时，内容先淡出，外形晚这么久再收
    var collapseShapeDelay = 0.06

    // 内容（图标）出现
    var contentDelay = 0.08
    var contentResponse = 0.38
    var contentDamping = 0.82
    /// 相邻图标之间的错峰
    var iconStagger = 0.018
    var contentFadeOut = 0.12
    var contentBlur = 8.0
    var contentScale = 0.8

    // 悬停意图
    var hoverInDelay = 0.05
    var hoverOutDelay = 0.05

    // 外形尺寸
    /// 展开后刘海两侧至少各多出的宽度
    var wingWidth = 56.0
    /// 刘海下方内容区的高度
    var contentHeight = 48.0
    var expandedBottomRadius = 22.0
    /// 顶部两侧的内凹过渡圆角（让外形从屏幕上沿"流"出来）
    var shoulderRadius = 10.0
    var collapsedBottomRadius = 14.0
    /// 收起时比刘海略小一点，保证完全藏在刘海里
    var collapsedWidthAdjust = -4.0
    var collapsedHeightAdjust = -1.0

    // 调试
    var slowMotion = 1.0
    var placeholderCount = 10

    static let defaults = AnimationTuning()
}

// MARK: - 动画

extension AnimationTuning {
    private func spring(_ response: Double, _ damping: Double) -> Animation {
        .spring(response: response * slowMotion, dampingFraction: damping)
    }

    var expandAnimation: Animation {
        spring(expandResponse, expandDamping)
    }

    var collapseAnimation: Animation {
        spring(collapseResponse, collapseDamping).delay(collapseShapeDelay * slowMotion)
    }

    func contentInAnimation(index: Int) -> Animation {
        spring(contentResponse, contentDamping)
            .delay((contentDelay + Double(index) * iconStagger) * slowMotion)
    }

    var contentOutAnimation: Animation {
        .easeOut(duration: contentFadeOut * slowMotion)
    }
}

// MARK: - 解码：缺失的字段用默认值，以后加参数不会把用户调好的值冲掉

extension AnimationTuning {
    private enum CodingKeys: String, CodingKey {
        case expandResponse, expandDamping, collapseResponse, collapseDamping, collapseShapeDelay
        case contentDelay, contentResponse, contentDamping, iconStagger, contentFadeOut, contentBlur, contentScale
        case hoverInDelay, hoverOutDelay
        case wingWidth, contentHeight, expandedBottomRadius, shoulderRadius
        case collapsedBottomRadius, collapsedWidthAdjust, collapsedHeightAdjust
        case slowMotion, placeholderCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AnimationTuning.defaults
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        expandResponse = v(.expandResponse, d.expandResponse)
        expandDamping = v(.expandDamping, d.expandDamping)
        collapseResponse = v(.collapseResponse, d.collapseResponse)
        collapseDamping = v(.collapseDamping, d.collapseDamping)
        collapseShapeDelay = v(.collapseShapeDelay, d.collapseShapeDelay)
        contentDelay = v(.contentDelay, d.contentDelay)
        contentResponse = v(.contentResponse, d.contentResponse)
        contentDamping = v(.contentDamping, d.contentDamping)
        iconStagger = v(.iconStagger, d.iconStagger)
        contentFadeOut = v(.contentFadeOut, d.contentFadeOut)
        contentBlur = v(.contentBlur, d.contentBlur)
        contentScale = v(.contentScale, d.contentScale)
        hoverInDelay = v(.hoverInDelay, d.hoverInDelay)
        hoverOutDelay = v(.hoverOutDelay, d.hoverOutDelay)
        wingWidth = v(.wingWidth, d.wingWidth)
        contentHeight = v(.contentHeight, d.contentHeight)
        expandedBottomRadius = v(.expandedBottomRadius, d.expandedBottomRadius)
        shoulderRadius = v(.shoulderRadius, d.shoulderRadius)
        collapsedBottomRadius = v(.collapsedBottomRadius, d.collapsedBottomRadius)
        collapsedWidthAdjust = v(.collapsedWidthAdjust, d.collapsedWidthAdjust)
        collapsedHeightAdjust = v(.collapsedHeightAdjust, d.collapsedHeightAdjust)
        slowMotion = v(.slowMotion, d.slowMotion)
        placeholderCount = v(.placeholderCount, d.placeholderCount)
    }
}
