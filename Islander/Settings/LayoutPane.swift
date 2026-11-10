import SwiftUI
import UniformTypeIdentifiers

/// 设置里的"菜单栏布局"：三排图标，从上到下是留在菜单栏的、藏到岛上的、永远隐藏的。
/// 拖动图标调整位置（也可以右键 / 双击换一排），岛民替用户在真实的菜单栏上按住 ⌘ 拖动。
struct LayoutPane: View {
    private typealias Zone = MenuBarItemMover.Section

    private var store: HiddenItemsStore { .shared }
    private var mover: MenuBarItemMover { .shared }
    private var permissions: Permissions { .shared }
    @Environment(\.colorScheme) private var colorScheme

    @State private var draggingID: String?
    @State private var dropTarget: DropTarget?
    /// 每个图标的实际宽度，判断落点在它左半边还是右半边
    @State private var chipWidths: [String: CGFloat] = [:]

    fileprivate struct DropTarget: Equatable {
        let section: MenuBarItemMover.Section
        /// 插在这个图标前面；nil 表示这一排的末尾
        let beforeID: String?
    }

    /// 三排各有哪些图标，以及换排时的落点
    private struct Zones {
        let alwaysHidden: [HiddenItemsStore.Item]
        let hidden: [HiddenItemsStore.Item]
        let visible: [HiddenItemsStore.Item]

        init(_ items: [HiddenItemsStore.Item]) {
            alwaysHidden = items.filter(\.isAlwaysHidden)
            hidden = items.filter { $0.isHidden && !$0.isAlwaysHidden }
            visible = items.filter { !$0.isHidden }
        }

        /// 换到另一排时放在紧挨分隔线的位置，拖动距离最短
        func destination(moving item: HiddenItemsStore.Item, to zone: Zone) -> MenuBarItemMover.Destination {
            switch zone {
            case .visible:
                // 菜单栏上最左边（紧挨分隔线右边）
                .init(section: .visible, beforeID: visible.first(where: \.source.isMovable)?.id)
            case .hidden where item.isAlwaysHidden:
                // 藏到岛上那一排的最左边（紧挨永远隐藏分隔线右边）
                .init(section: .hidden, beforeID: hidden.first?.id)
            case .hidden, .alwaysHidden:
                // 这一排的最右边（紧挨右边那条分隔线）
                .init(section: zone, beforeID: nil)
            }
        }
    }

    private var style: IslandStyle { colorScheme == .dark ? .dark : .light }

    var body: some View {
        let zones = Zones(store.allItems)

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("拖动图标调整位置，或者右键 / 双击把它换到另一排。菜单栏上的图标会跟着移过去。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !permissions.accessibility {
                    notice(symbol: "lock.fill", text: "需要辅助功能权限才能读取和移动菜单栏图标。") {
                        Button("去授权") { SettingsController.shared.state.pane = .permissions }
                    }
                } else if !store.hasScanned {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在读取菜单栏…").foregroundStyle(.secondary)
                    }
                } else {
                    shelf(.visible, title: "留在菜单栏", symbol: "menubar.rectangle",
                          caption: "始终显示在菜单栏上。带锁的是系统固定的图标，不能移动。",
                          empty: "把图标拖到这里，它就会回到菜单栏", items: zones.visible, zones: zones)
                    shelf(.hidden, title: "藏到岛上", symbol: "capsule.fill",
                          caption: "平时不占菜单栏，鼠标移到刘海上时出现在灵动岛里。",
                          empty: "把图标拖到这里，它就会藏到岛上", items: zones.hidden, zones: zones)
                    shelf(.alwaysHidden, title: "永远隐藏", symbol: "eye.slash",
                          caption: "菜单栏和岛上都不显示。要用时按住 ⌥ 再把鼠标移到刘海上。",
                          empty: "把不想看到的图标拖到这里", items: zones.alwaysHidden, zones: zones)
                }

                statusBar
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { mover.lastError = nil }
    }

    // MARK: - 一排图标

    private func shelf(_ section: Zone, title: String, symbol: String, caption: String, empty: String,
                       items: [HiddenItemsStore.Item], zones: Zones) -> some View {
        let targeted = dropTarget?.section == section
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol).foregroundStyle(.secondary)
                Text(title).font(.headline)
                Text("\(items.count) 个").foregroundStyle(.secondary)
            }

            FlowLayout(spacing: 2, lineSpacing: 6) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let nextID = index + 1 < items.count ? items[index + 1].id : nil
                    LayoutChip(
                        item: item,
                        style: style,
                        isMoving: mover.movingItemID == item.id,
                        insertion: insertion(for: item.id, nextID: nextID, section: section)
                    )
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chipWidths[item.id] = $0 }
                    .draggable(item.source.isMovable) {
                        draggingID = item.id
                        return NSItemProvider(object: item.id as NSString)
                    }
                    .onDrop(of: [.plainText], delegate: ChipDropDelegate(
                        itemID: item.id, nextID: nextID, section: section, width: chipWidths[item.id] ?? 54,
                        target: $dropTarget, canDrop: canDrop, perform: performDrop
                    ))
                    .onTapGesture(count: 2) {
                        // 双击：菜单栏上的藏到岛上，岛上的回到菜单栏，永远隐藏的放回岛上
                        move(item, to: section == .hidden ? .visible : .hidden, zones: zones)
                    }
                    .contextMenu { contextMenu(for: item, in: section, zones: zones) }
                }
                if items.isEmpty {
                    Text(empty)
                        .foregroundStyle(.tertiary)
                        .frame(height: 46)
                        .padding(.horizontal, 8)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(targeted ? Color.accentColor : Color(nsColor: .separatorColor),
                                  lineWidth: targeted ? 2 : 1)
            )
            // 落在空白处：放到这一排末尾
            .onDrop(of: [.plainText], delegate: ShelfDropDelegate(
                section: section, target: $dropTarget, canDrop: canDrop, perform: performDrop
            ))
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: items.map(\.id))

            Text(caption)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// 这个图标的哪一侧要画插入标记
    private func insertion(for id: String, nextID: String?, section: Zone) -> HorizontalEdge? {
        guard let dropTarget, dropTarget.section == section else { return nil }
        if dropTarget.beforeID == id { return .leading }
        if dropTarget.beforeID == nil, nextID == nil { return .trailing }
        return nil
    }

    @ViewBuilder
    private func contextMenu(for item: HiddenItemsStore.Item, in section: Zone, zones: Zones) -> some View {
        if item.source.isMovable {
            if section != .visible { Button("留在菜单栏") { move(item, to: .visible, zones: zones) } }
            if section != .hidden { Button("藏到岛上") { move(item, to: .hidden, zones: zones) } }
            if section != .alwaysHidden { Button("永远隐藏") { move(item, to: .alwaysHidden, zones: zones) } }
        } else {
            Text("系统固定的图标，不能移动")
        }
    }

    // MARK: - 移动

    private var canDrop: Bool { !mover.isMoving && draggingID != nil }

    private func performDrop(_ target: DropTarget) {
        defer {
            draggingID = nil
            dropTarget = nil
        }
        guard let id = draggingID, id != target.beforeID else { return }
        move(id, to: .init(section: target.section, beforeID: target.beforeID))
    }

    private func move(_ item: HiddenItemsStore.Item, to zone: Zone, zones: Zones) {
        guard item.source.isMovable else { return }
        move(item.id, to: zones.destination(moving: item, to: zone))
    }

    private func move(_ id: String, to destination: MenuBarItemMover.Destination) {
        guard !mover.isMoving else { return }
        Task { await mover.move(id, to: destination) }
    }

    // MARK: - 状态

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let id = mover.movingItemID {
                ProgressView().controlSize(.small)
                Text("正在移动「\(store.allItems.first { $0.id == id }?.source.displayName ?? id)」…")
                    .foregroundStyle(.secondary)
            } else if let error = mover.lastError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("重新读取") { store.refresh(full: true, forceCapture: true) }
                .disabled(mover.isMoving)
        }
        .font(.callout)
    }

    private func notice<Action: View>(symbol: String, text: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(text)
            Spacer()
            action()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.5)))
    }
}

// MARK: - 图标

private struct LayoutChip: View {
    let item: HiddenItemsStore.Item
    let style: IslandStyle
    let isMoving: Bool
    let insertion: HorizontalEdge?
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 3) {
            icon
                .frame(height: 24)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(hovering && item.source.isMovable ? 0.08 : 0))
                )
            HStack(spacing: 2) {
                if !item.source.isMovable {
                    Image(systemName: "lock.fill").font(.system(size: 7, weight: .semibold))
                }
                Text(item.source.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .frame(maxWidth: 70)
        }
        .frame(minWidth: 54)
        .padding(.vertical, 2)
        .opacity(isMoving ? 0.35 : item.source.isMovable ? 1 : 0.55)
        .overlay {
            if isMoving { ProgressView().controlSize(.small) }
        }
        .overlay(alignment: insertion == .trailing ? .trailing : .leading) {
            if insertion != nil {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: 40)
                    .offset(x: insertion == .trailing ? 2.5 : -2.5)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(item.source.isMovable ? item.source.displayName : "\(item.source.displayName)（系统固定，不能移动）")
    }

    @ViewBuilder
    private var icon: some View {
        if let image = item.icon {
            let size = image.size
            let scale = size.height > 24 ? 24 / size.height : 1
            Image(nsImage: image.image(for: style))
                .resizable()
                .interpolation(.high)
                .frame(width: size.width * scale, height: size.height * scale)
        } else if let appIcon = item.appIcon {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 18, height: 18)
        }
    }
}

// MARK: - 拖放

private struct ChipDropDelegate: DropDelegate {
    let itemID: String
    let nextID: String?
    let section: MenuBarItemMover.Section
    /// 落点在图标左半边插到它前面，右半边插到它后面
    let width: CGFloat
    @Binding var target: LayoutPane.DropTarget?
    let canDrop: Bool
    let perform: (LayoutPane.DropTarget) -> Void

    func validateDrop(info: DropInfo) -> Bool { canDrop }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        target = destination(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if target == destination(info) { target = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        perform(destination(info))
        return true
    }

    private func destination(_ info: DropInfo) -> LayoutPane.DropTarget {
        .init(section: section, beforeID: info.location.x < width / 2 ? itemID : nextID)
    }
}

private struct ShelfDropDelegate: DropDelegate {
    let section: MenuBarItemMover.Section
    @Binding var target: LayoutPane.DropTarget?
    let canDrop: Bool
    let perform: (LayoutPane.DropTarget) -> Void

    func validateDrop(info: DropInfo) -> Bool { canDrop }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // 只有指针在空白处时才会走到这里（在图标上方时由图标自己的代理接管）
        target = .init(section: section, beforeID: nil)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if target?.section == section { target = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        perform(target ?? .init(section: section, beforeID: nil))
        return true
    }
}

private extension View {
    /// 只有能移动的图标才能拖
    @ViewBuilder
    func draggable(_ enabled: Bool, _ provider: @escaping () -> NSItemProvider) -> some View {
        if enabled {
            onDrag(provider)
        } else {
            self
        }
    }
}

/// 从左到右排、放不下就换行
private struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, needed > width {
                rows.append(current)
                current = Row(y: current.y + current.height + lineSpacing)
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = needed
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
