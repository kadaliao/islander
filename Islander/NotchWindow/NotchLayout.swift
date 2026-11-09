import CoreGraphics

/// 由刘海尺寸 + 手感参数 + 内容尺寸算出收起 / 展开两个外形和画布大小。
struct NotchLayout: Equatable {
    /// 行高，也是占位图标的边长
    static let iconSize: CGFloat = 28
    static let iconSpacing: CGFloat = 6
    static let dividerWidth: CGFloat = 9
    static let rowSpacing: CGFloat = 8
    static let contentPadding: CGFloat = 20
    /// 画布给弹簧回弹留的余量：外形冲过头时不能被窗口边缘裁掉
    static let overshootMargin: CGFloat = 40

    let notchSize: CGSize
    let collapsed: NotchShape
    let expanded: NotchShape
    /// 每一行包含哪些条目（下标区间）。图标太多时换行
    let rows: [Range<Int>]

    init(notchSize: CGSize,
         tuning: AnimationTuning,
         itemWidths: [CGFloat],
         minimumContentWidth: CGFloat = 0,
         maxRowWidth: CGFloat) {
        self.notchSize = notchSize

        collapsed = NotchShape(
            width: notchSize.width + tuning.collapsedWidthAdjust,
            height: notchSize.height + tuning.collapsedHeightAdjust,
            bottomRadius: tuning.collapsedBottomRadius,
            shoulderRadius: 0
        )

        let rows = Self.wrap(itemWidths, maxRowWidth: maxRowWidth)
        self.rows = rows
        let rowWidth = rows.map { row in
            row.reduce(0) { $0 + itemWidths[$1] } + CGFloat(max(row.count - 1, 0)) * Self.iconSpacing
        }.max() ?? 0
        let contentWidth = max(rowWidth, minimumContentWidth)
        let extraRows = CGFloat(max(rows.count - 1, 0))

        expanded = NotchShape(
            width: max(notchSize.width + 2 * tuning.wingWidth, contentWidth + 2 * Self.contentPadding),
            height: notchSize.height + tuning.contentHeight + extraRows * (Self.iconSize + Self.rowSpacing),
            bottomRadius: tuning.expandedBottomRadius,
            shoulderRadius: tuning.shoulderRadius
        )
    }

    /// 刘海下方内容区高度
    var contentHeight: CGFloat { expanded.height - notchSize.height }

    /// 展开后连同两侧肩部的总宽度
    var expandedOuterWidth: CGFloat { expanded.width + 2 * expanded.shoulderRadius }

    /// 窗口尺寸：展开外形 + 回弹余量，动画期间不变
    var canvasSize: CGSize {
        CGSize(width: (expandedOuterWidth + 2 * Self.overshootMargin).rounded(.up),
               height: (expanded.height + Self.overshootMargin).rounded(.up))
    }

    /// 按最大行宽贪心换行
    private static func wrap(_ widths: [CGFloat], maxRowWidth: CGFloat) -> [Range<Int>] {
        var rows: [Range<Int>] = []
        var start = 0
        var current: CGFloat = 0
        for (index, width) in widths.enumerated() {
            let needed = index == start ? width : current + iconSpacing + width
            if index > start, needed > maxRowWidth {
                rows.append(start..<index)
                start = index
                current = width
            } else {
                current = needed
            }
        }
        if start < widths.count {
            rows.append(start..<widths.count)
        }
        return rows
    }
}
