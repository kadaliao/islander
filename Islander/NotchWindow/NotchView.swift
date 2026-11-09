import SwiftUI

/// 岛的 SwiftUI 根视图。画布 = 整个窗口，外形贴顶居中。
struct NotchView: View {
    let model: NotchViewModel

    var body: some View {
        let layout = model.layout
        let style = model.style
        let expanded = model.isExpanded
        let shape = expanded ? layout.expanded : layout.collapsed

        ZStack(alignment: .top) {
            if style == .light {
                // 阴影让浅色的岛从浅色菜单栏上浮起来
                shape.fill(Color.white.opacity(0.35))
                    .shadow(color: .black.opacity(expanded ? 0.22 : 0), radius: 18, y: 8)
                // 从头到尾都是毛玻璃：收起时外形整个藏在刘海后面，看不见，不需要先盖一层黑色再淡出
                GlassBackground(shape: shape)
                shape.stroke(Color.black.opacity(0.1), lineWidth: 0.5)
            } else {
                shape.fill(Color.black)
            }

            NotchContentView(model: model, content: model.content, layout: layout, style: style)
                .clipShape(shape)
                .contentShape(shape)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .environment(\.colorScheme, style == .light ? .light : .dark)
    }
}

/// 刘海下方的内容区
private struct NotchContentView: View {
    let model: NotchViewModel
    let content: IslandContent
    let layout: NotchLayout
    let style: IslandStyle

    private static let symbols = [
        "wifi", "battery.75percent", "speaker.wave.2.fill", "moon.fill", "bell.fill",
        "cloud.fill", "music.note", "camera.fill", "lock.fill", "bolt.fill",
    ]

    private struct Entry: Identifiable {
        let index: Int
        let id: String
    }

    var body: some View {
        let tuning = model.tuning
        let visible = model.showsContent

        Group {
            switch content {
            case .items(let entries):
                rows(ids: entries.map(\.id)) { index in
                    Group {
                        switch entries[index] {
                        case .item(let item):
                            IslandItemButton(item: item, style: style, model: model)
                        case .divider:
                            IslandDivider(style: style)
                        }
                    }
                    .appearing(index: index, visible: visible, tuning: tuning)
                }
            case .placeholders(let count):
                rows(ids: (0..<count).map { "placeholder-\($0)" }) { index in
                    PlaceholderIcon(symbol: Self.symbols[index % Self.symbols.count], style: style)
                        .appearing(index: index, visible: visible, tuning: tuning)
                }
            case .message(let message):
                IslandMessageView(message: message, style: style)
                    .appearing(index: 0, visible: visible, tuning: tuning)
            }
        }
        .frame(width: layout.expanded.width, height: layout.contentHeight)
        .padding(.top, layout.notchSize.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func rows<Cell: View>(ids: [String], @ViewBuilder cell: @escaping (Int) -> Cell) -> some View {
        VStack(spacing: NotchLayout.rowSpacing) {
            ForEach(layout.rows, id: \.lowerBound) { row in
                HStack(spacing: NotchLayout.iconSpacing) {
                    ForEach(row.filter { $0 < ids.count }.map { Entry(index: $0, id: ids[$0]) }) { entry in
                        cell(entry.index)
                    }
                }
            }
        }
    }
}

// MARK: - 条目

private struct IslandItemButton: View {
    let item: HiddenItemsStore.Item
    let style: IslandStyle
    let model: NotchViewModel
    /// 图标在岛窗口里的位置，镜像菜单弹在它正下方
    @State private var frame: CGRect = .zero

    var body: some View {
        let size = item.displaySize
        Button {
            ClickForwarder.shared.open(item.source, isHidden: item.isHidden,
                                       needsFullReveal: item.isBeyondAlwaysHiddenSeparator, from: model, anchor: frame)
        } label: {
            if let icon = item.icon {
                Image(nsImage: icon.image(for: style))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)
            } else if let appIcon = item.appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 18, height: 18)
            }
        }
        .buttonStyle(IslandIconButtonStyle(width: size.width, style: style,
                                           isActive: model.openMenuItemID == item.id))
        .help(item.source.displayName)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
    }
}

/// "显示全部图标"时隐藏区和可见区之间的细线
private struct IslandDivider: View {
    let style: IslandStyle

    var body: some View {
        Capsule()
            .fill((style == .light ? Color.black : Color.white).opacity(0.25))
            .frame(width: 1.5, height: 16)
            .frame(width: NotchLayout.dividerWidth, height: NotchLayout.iconSize)
    }
}

private struct PlaceholderIcon: View {
    let symbol: String
    let style: IslandStyle

    var body: some View {
        Button {} label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(style == .light ? Color.black.opacity(0.8) : .white)
        }
        .buttonStyle(IslandIconButtonStyle(width: NotchLayout.iconSize, style: style))
    }
}

private struct IslandMessageView: View {
    let message: IslandMessage
    let style: IslandStyle

    var body: some View {
        HStack(spacing: 8) {
            switch message {
            case .needsPermission:
                Image(systemName: "lock.fill")
                Text("授权后，被隐藏的图标会出现在这里")
                Button("去授权") { SettingsController.shared.show(.permissions) }
                    .buttonStyle(IslandCapsuleButtonStyle(style: style))
            case .noHiddenItems:
                Image(systemName: "eye.slash")
                Text("还没有藏起来的图标")
                Button("整理菜单栏") { SettingsController.shared.show(.layout) }
                    .buttonStyle(IslandCapsuleButtonStyle(style: style))
            case .loading:
                ProgressView().controlSize(.small)
                Text("正在读取菜单栏…")
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(style == .light ? Color.black.opacity(0.75) : Color.white.opacity(0.85))
        .lineLimit(1)
    }
}

// MARK: - 动画与样式

private extension View {
    /// 内容分层出现：透明度 + 轻微缩放 + 模糊，按序号错峰
    func appearing(index: Int, visible: Bool, tuning: AnimationTuning) -> some View {
        self
            .opacity(visible ? 1 : 0)
            .scaleEffect(visible ? 1 : tuning.contentScale, anchor: .top)
            .blur(radius: visible ? 0 : tuning.contentBlur)
            .animation(visible ? tuning.contentInAnimation(index: index) : tuning.contentOutAnimation, value: visible)
    }
}

struct IslandIconButtonStyle: ButtonStyle {
    var width: CGFloat = NotchLayout.iconSize
    var style: IslandStyle = .dark
    /// 它的菜单正开着
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        IslandIconButton(configuration: configuration, width: width, style: style, isActive: isActive)
    }
}

private struct IslandIconButton: View {
    let configuration: ButtonStyleConfiguration
    let width: CGFloat
    let style: IslandStyle
    let isActive: Bool
    @State private var hovering = false

    var body: some View {
        let ink: Color = style == .light ? .black : .white
        let strength = style == .light ? 0.6 : 1.0
        let level = configuration.isPressed || isActive ? 0.24 : hovering ? 0.12 : 0
        configuration.label
            .frame(width: width, height: NotchLayout.iconSize)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(ink.opacity(level * strength))
            )
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

private struct IslandCapsuleButtonStyle: ButtonStyle {
    let style: IslandStyle

    func makeBody(configuration: Configuration) -> some View {
        let ink: Color = style == .light ? .black : .white
        return configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .foregroundStyle(ink)
            .background(Capsule().fill(ink.opacity(configuration.isPressed ? 0.25 : 0.12)))
    }
}
