import AppKit
import SwiftUI

/// 浅色菜单栏上的岛：模糊身后内容的浅色毛玻璃，形状跟 NotchShape 一起逐帧变形。
///
/// 用 AppKit 的 NSVisualEffectView（behindWindow 模糊菜单栏和壁纸），外形用一个 CAShapeLayer 遮罩。
/// SwiftUI 不会给 NSViewRepresentable 插值（就算它声明了 Animatable，玻璃也会直接跳到终点的外形），
/// 所以插值交给一个 Animatable 的 ViewModifier：弹簧动画的每一帧它都拿到插值后的外形，再交给 AppKit 视图。
struct GlassBackground: View {
    var shape: NotchShape

    var body: some View {
        Color.clear.modifier(AnimatedGlass(shape: shape))
    }
}

private struct AnimatedGlass: ViewModifier, @preconcurrency Animatable {
    var shape: NotchShape

    var animatableData: NotchShape.AnimatableData {
        get { shape.animatableData }
        set { shape.animatableData = newValue }
    }

    func body(content: Content) -> some View {
        content.overlay(GlassRepresentable(shape: shape))
    }
}

private struct GlassRepresentable: NSViewRepresentable {
    let shape: NotchShape

    func makeNSView(context: Context) -> GlassView {
        GlassView()
    }

    func updateNSView(_ view: GlassView, context: Context) {
        view.shape = shape
    }
}

final class GlassView: NSView {
    private let effect = NSVisualEffectView()
    private let maskLayer = CAShapeLayer()

    var shape: NotchShape? {
        didSet {
            if shape != oldValue { updateMask() }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .aqua)
        effect.frame = bounds
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)
        layer?.mask = maskLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // 只是背景，不接收点击
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        updateMask()
    }

    private func updateMask() {
        guard let shape else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.frame = bounds
        // SwiftUI 的路径原点在左上；这个视图的图层原点在左下，翻转一下
        var flip = CGAffineTransform(translationX: 0, y: bounds.height).scaledBy(x: 1, y: -1)
        maskLayer.path = shape.path(in: bounds).cgPath.copy(using: &flip)
        CATransaction.commit()
    }
}
