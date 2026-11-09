import SwiftUI

/// 岛上显示什么
enum IslandContent: Equatable {
    case items([IslandEntry])
    /// 调试面板的占位预览
    case placeholders(Int)
    case message(IslandMessage)
}

/// 岛上的一格：一个图标，或者两区之间的分隔线（永远隐藏 | 藏到岛上 | 菜单栏上的）
enum IslandEntry: Identifiable, Equatable {
    case item(HiddenItemsStore.Item)
    case divider(Int)

    var id: String {
        switch self {
        case .item(let item): item.id
        case .divider(let index): "divider-\(index)"
        }
    }
}

enum IslandMessage: Equatable {
    case needsPermission
    case noHiddenItems
    case loading
}

/// 单个岛的展开状态。外形和内容是两个独立的状态，各自有自己的动画：
/// 展开时外形先动、内容延迟淡入；收起时内容先淡出、外形延迟收回。
@MainActor
@Observable
final class NotchViewModel {
    let geometry: NotchGeometry

    /// 外形是否展开（驱动 NotchShape 的弹簧）
    private(set) var isExpanded = false
    /// 内容是否显示（每个图标用自己的 `.animation(_:value:)` 跟随，带延迟和错峰）
    private(set) var showsContent = false
    /// 正在弹出镜像菜单的那个图标：岛保持展开，图标保持高亮
    private(set) var openMenuItemID: String?
    /// 按住 ⌥ 打开的岛：连永远隐藏的图标也显示
    var showsAlwaysHidden = false

    /// 岛的 SwiftUI 宿主视图，镜像菜单弹在它上面
    @ObservationIgnored weak var hostView: NSView?
    /// 镜像菜单关闭后通知窗口控制器（参数：是否选中了某一项）
    @ObservationIgnored var onMenuClosed: ((Bool) -> Void)?

    func menuDidOpen(_ itemID: String) {
        openMenuItemID = itemID
    }

    func menuDidClose(choseItem: Bool) {
        openMenuItemID = nil
        onMenuClosed?(choseItem)
    }

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }

    var tuning: AnimationTuning { TuningStore.shared.tuning }

    /// 跟随这块屏幕菜单栏的深浅：深色是纯黑的岛，浅色是毛玻璃
    var style: IslandStyle {
        HiddenItemsStore.shared.style(forRowTop: geometry.menuBarRowTop)
    }

    var content: IslandContent {
        let store = HiddenItemsStore.shared
        if store.previewPlaceholders {
            return .placeholders(max(tuning.placeholderCount, 1))
        }
        if !Permissions.shared.accessibility {
            return .message(.needsPermission)
        }
        let items = store.islandItems(includingAlwaysHidden: showsAlwaysHidden)
        if !items.isEmpty {
            // 从左到右是永远隐藏的、藏到岛上的、菜单栏上的；相邻两段之间加一条分隔线
            func group(_ item: HiddenItemsStore.Item) -> Int { item.isAlwaysHidden ? 0 : item.isHidden ? 1 : 2 }
            var entries: [IslandEntry] = []
            for (index, item) in items.enumerated() {
                if index > 0, group(items[index - 1]) != group(item) {
                    entries.append(.divider(group(item)))
                }
                entries.append(.item(item))
            }
            return .items(entries)
        }
        return .message(store.hasScanned ? .noHiddenItems : .loading)
    }

    var layout: NotchLayout {
        let maxRowWidth = min(geometry.screenFrame.width - 240, 720)
        let widths: [CGFloat]
        var minimumWidth: CGFloat = 0
        switch content {
        case .items(let entries):
            widths = entries.map { entry in
                switch entry {
                case .item(let item): item.displaySize.width
                case .divider: NotchLayout.dividerWidth
                }
            }
        case .placeholders(let count):
            widths = Array(repeating: NotchLayout.iconSize, count: count)
        case .message:
            widths = []
            minimumWidth = 300
        }
        return NotchLayout(notchSize: geometry.notchSize, tuning: tuning, itemWidths: widths,
                           minimumContentWidth: minimumWidth, maxRowWidth: maxRowWidth)
    }

    func expand() {
        guard !isExpanded else { return }
        withAnimation(tuning.expandAnimation) {
            isExpanded = true
        }
        showsContent = true
    }

    func collapse() {
        guard isExpanded else { return }
        showsContent = false
        withAnimation(tuning.collapseAnimation) {
            isExpanded = false
        }
    }
}

extension HiddenItemsStore.Item {
    /// 在岛上的显示尺寸：原尺寸显示，比行高还高的等比缩到行高
    @MainActor var displaySize: CGSize {
        let size = self.size
        guard size.height > NotchLayout.iconSize, size.height > 0 else {
            return CGSize(width: max(size.width, 20), height: size.height)
        }
        let scale = NotchLayout.iconSize / size.height
        return CGSize(width: max(size.width * scale, 20), height: NotchLayout.iconSize)
    }
}
