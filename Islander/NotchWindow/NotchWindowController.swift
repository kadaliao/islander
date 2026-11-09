import AppKit
import SwiftUI

/// 一块屏幕上的一个岛：管理面板位置、悬停意图、鼠标穿透。
@MainActor
final class NotchWindowController {
    let geometry: NotchGeometry
    let model: NotchViewModel

    private let panel: NotchPanel
    private var pendingHover: Task<Void, Never>?
    private var pendingShrink: Task<Void, Never>?
    private var pointerInside = false
    private var isPinned = false

    /// 收起时热区比刘海左右各宽一点
    private static let collapsedTolerance: CGFloat = 4
    /// 展开时热区比外形左右、下方各宽一点，指针擦边不至于立刻收起
    private static let expandedTolerance: CGFloat = 8

    init(geometry: NotchGeometry) {
        self.geometry = geometry
        model = NotchViewModel(geometry: geometry)
        panel = NotchPanel()

        let hostingView = NotchHostingView(rootView: NotchView(model: model))
        // 不让 SwiftUI 根据内容改窗口尺寸：窗口固定，动画只在画布内发生
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        model.hostView = hostingView
        model.onMenuClosed = { [weak self] choseItem in self?.menuClosed(choseItem: choseItem) }

        layoutPanel()
        observeLayout()
        panel.orderFrontRegardless()
    }

    func close() {
        pendingHover?.cancel()
        pendingShrink?.cancel()
        panel.orderOut(nil)
        panel.close()
    }

    // MARK: - 布局

    /// 外形尺寸（手感参数、图标数量、授权状态……）变化时重新布局。Observation 自动追踪 layout 依赖的所有状态
    private func observeLayout() {
        withObservationTracking {
            _ = model.layout
        } onChange: { [weak self] in
            // onChange 在值改变之前触发，下一轮再读新值
            Task { @MainActor in
                self?.layoutPanel()
                self?.refreshInteractivity()
                self?.observeLayout()
            }
        }
    }

    /// 窗口变大立即生效；变小推迟到外形的收缩动画走完，否则动画中途会被窗口边缘裁掉
    private func layoutPanel() {
        pendingShrink?.cancel()
        let target = frame(for: model.layout.canvasSize)
        let current = panel.frame
        if target.width >= current.width, target.height >= current.height {
            setPanelFrame(target)
            return
        }
        setPanelFrame(frame(for: CGSize(width: max(target.width, current.width),
                                        height: max(target.height, current.height))))
        pendingShrink = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.setPanelFrame(self.frame(for: self.model.layout.canvasSize))
        }
    }

    /// 画布贴着屏幕顶边、以刘海为中心；原点落在整数坐标上，外形中心正好对准刘海中心
    private func frame(for canvas: CGSize) -> CGRect {
        let midX = geometry.notchRect.midX
        var width = canvas.width
        if (midX - width / 2).rounded() != midX - width / 2 {
            width += 1
        }
        return CGRect(x: midX - width / 2, y: geometry.screenTop - canvas.height,
                      width: width, height: canvas.height)
    }

    private func setPanelFrame(_ frame: CGRect) {
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
    }

    // MARK: - 悬停意图

    /// 当前热区（全局坐标）。屏幕最上面一行像素的 y 等于 screenTop，所以高度多给 1
    private var hotZone: CGRect {
        let top = geometry.screenTop
        if model.isExpanded {
            let layout = model.layout
            let width = layout.expandedOuterWidth + 2 * Self.expandedTolerance
            let height = layout.expanded.height + Self.expandedTolerance
            return CGRect(x: geometry.notchRect.midX - width / 2, y: top - height, width: width, height: height + 1)
        } else {
            let notch = geometry.notchRect.insetBy(dx: -Self.collapsedTolerance, dy: 0)
            return CGRect(x: notch.minX, y: notch.minY, width: notch.width, height: notch.height + 1)
        }
    }

    func pointerMoved(to point: NSPoint) {
        let inside = hotZone.contains(point)
        if inside != pointerInside {
            pointerInside = inside
            if inside {
                // 指针刚碰到刘海：趁停留判断的这段时间在后台刷新图标
                HiddenItemsStore.shared.refreshIfStale()
                scheduleExpand()
            } else {
                scheduleCollapse()
            }
        }
        refreshInteractivity()
    }

    /// 停留够久才展开，路过不触发
    private func scheduleExpand() {
        pendingHover?.cancel()
        guard !model.isExpanded else { return }
        let delay = model.tuning.hoverInDelay
        pendingHover = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.pointerInside else { return }
            self.expand()
        }
    }

    /// 移出后稍等再收，指针短暂擦出去再回来不会抖
    private func scheduleCollapse() {
        pendingHover?.cancel()
        // 镜像菜单开着时，指针移到菜单上不算离开
        guard model.isExpanded, !isPinned, model.openMenuItemID == nil else { return }
        let delay = model.tuning.hoverOutDelay
        pendingHover = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, !self.pointerInside else { return }
            self.collapse()
        }
    }

    // MARK: - 展开 / 收起

    func expand() {
        pendingHover?.cancel()
        // 按住 ⌥ 打开时，永远隐藏的图标也显示
        if !model.isExpanded {
            model.showsAlwaysHidden = NSEvent.modifierFlags.contains(.option)
        }
        model.expand()
        syncPointer()
    }

    /// 岛开着时按下 / 松开 ⌥：显示 / 收起永远隐藏的图标
    func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        let option = flags.contains(.option)
        guard model.isExpanded, model.showsAlwaysHidden != option else { return }
        withAnimation(model.tuning.expandAnimation) {
            model.showsAlwaysHidden = option
        }
    }

    func collapse() {
        pendingHover?.cancel()
        guard !isPinned else { return }
        model.collapse()
        syncPointer()
    }

    /// 镜像菜单关闭：选了某一项就收起；只是取消的话，指针还在岛上就保持展开
    private func menuClosed(choseItem: Bool) {
        syncPointer()
        if choseItem {
            collapse()
        } else if !pointerInside {
            scheduleCollapse()
        }
    }

    func setPinned(_ pinned: Bool) {
        isPinned = pinned
        if pinned {
            expand()
        } else if !pointerInside {
            scheduleCollapse()
        }
    }

    /// 展开 / 收起后热区变了，按当前指针位置重新判断
    private func syncPointer() {
        pointerInside = hotZone.contains(NSEvent.mouseLocation)
        refreshInteractivity()
    }

    /// 只有展开且指针在岛上时才接收点击，其余时间点击穿透到下面的菜单栏
    private func refreshInteractivity() {
        let interactive = model.isExpanded && pointerInside
        if panel.ignoresMouseEvents == interactive {
            panel.ignoresMouseEvents = !interactive
        }
    }
}
