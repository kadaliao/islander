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
    /// 指针下面的图标（悬停高亮）。由窗口控制器按全局鼠标位置算，和岛的展开 / 收起用同一路鼠标事件：
    /// 不用 SwiftUI 的 onHover——岛所在的面板不激活，悬停靠系统的跟踪区域，菜单开着时、别的 App 接过鼠标时
    /// 进出事件会丢，高亮会停在原来的图标上（#8）
    private(set) var hoveredItemID: String?
    /// 右键（或按住 ⌃ 点）按下、还没松开的图标：和左键按下一样缩一下
    private(set) var pressedItemID: String?
    /// 每个图标在岛窗口里的位置（SwiftUI 全局坐标，原点在左上）：判断指针、右键落在哪个图标上，镜像菜单也弹在它下面
    @ObservationIgnored var itemFrames: [String: CGRect] = [:]
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

    func setHovered(_ id: String?) {
        if hoveredItemID != id { hoveredItemID = id }
    }

    func setPressed(_ id: String?) {
        if pressedItemID != id { pressedItemID = id }
    }

    /// 岛上某一点（SwiftUI 全局坐标）落在哪个图标上。指针每动一下都要问，先只查位置
    func itemID(at point: CGPoint) -> String? {
        guard isExpanded else { return nil }
        return itemFrames.first { $0.value.contains(point) }?.key
    }

    func item(at point: CGPoint) -> HiddenItemsStore.Item? {
        guard let id = itemID(at: point), case .items(let entries) = content else { return nil }
        for case .item(let item) in entries where item.id == id { return item }
        return nil
    }

    /// 点了岛上的图标
    func open(_ item: HiddenItemsStore.Item, button: ClickForwarder.Button) {
        ClickForwarder.shared.open(item.source, button: button, isHidden: item.isHidden,
                                   needsFullReveal: item.isBeyondAlwaysHiddenSeparator, from: self,
                                   anchor: itemFrames[item.id] ?? .zero)
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
        let maxRowWidth = min(geometry.screenFrame.width - 240, NotchLayout.maxRowWidth)
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
        setHovered(nil)
        setPressed(nil)
        showsContent = false
        withAnimation(tuning.collapseAnimation) {
            isExpanded = false
        }
    }
}

extension HiddenItemsStore.Item {
    /// 在岛上的显示尺寸：原尺寸显示，比行高还高的等比缩到行高，比一行还宽的等比缩到一行宽。
    /// 宽度不设上限的话，一张超宽的截图就能把岛撑得比屏幕还宽（#6）
    @MainActor var displaySize: CGSize {
        let size = self.size
        guard size.width > 0, size.height > 0 else { return CGSize(width: max(size.width, 20), height: size.height) }
        let scale = min(NotchLayout.iconSize / size.height, NotchLayout.maxRowWidth / size.width, 1)
        return CGSize(width: max(size.width * scale, 20), height: size.height * scale)
    }
}
