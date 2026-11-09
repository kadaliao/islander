import AppKit
import SwiftUI

/// 手感调试面板：实时调弹簧、延迟、外形尺寸，改动立即作用到岛上并持久化。
@MainActor
final class DebugPanelController {
    static let shared = DebugPanelController()

    private var window: NSWindow?

    private init() {}

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: DebugPanelView())
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.title = "岛民 · 手感调试"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 440, height: 780))
            window.contentMinSize = NSSize(width: 380, height: 360)
            window.isReleasedWhenClosed = false
            // 浮在普通窗口上面，边调边看
            window.level = .floating
            window.center()
            window.setFrameAutosaveName("IslanderDebugPanel")
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct DebugPanelView: View {
    @Bindable private var store = TuningStore.shared
    @Bindable private var items = HiddenItemsStore.shared
    private var permissions: Permissions { Permissions.shared }
    @State private var pinned = ScreenManager.shared.isPinned
    @State private var demoRunning = false
    @State private var demoTask: Task<Void, Never>?
    @State private var copied = false

    var body: some View {
        Form {
            Section("演示") {
                HStack {
                    Button("展开") { ScreenManager.shared.expandAll() }
                    Button("收起") { ScreenManager.shared.collapseAll() }
                    Spacer()
                    Toggle("锁定展开", isOn: $pinned)
                    Toggle("循环演示", isOn: $demoRunning)
                }
                slider("慢放", \.slowMotion, 1...10, step: 0.5, .multiplier)
            }

            Section("展开 · 外形弹簧") {
                slider("response", \.expandResponse, 0.15...1.2, step: 0.01, .seconds)
                slider("dampingFraction", \.expandDamping, 0.4...1.0, step: 0.01, .ratio)
            }

            Section("收起 · 外形弹簧") {
                slider("response", \.collapseResponse, 0.1...1.0, step: 0.01, .seconds)
                slider("dampingFraction", \.collapseDamping, 0.5...1.0, step: 0.01, .ratio)
                slider("外形晚于内容收回", \.collapseShapeDelay, 0...0.3, step: 0.005, .milliseconds)
            }

            Section("内容出现 / 消失") {
                slider("出现延迟", \.contentDelay, 0...0.4, step: 0.005, .milliseconds)
                slider("错峰（每个图标）", \.iconStagger, 0...0.08, step: 0.002, .milliseconds)
                slider("出现 response", \.contentResponse, 0.1...1.0, step: 0.01, .seconds)
                slider("出现 dampingFraction", \.contentDamping, 0.4...1.0, step: 0.01, .ratio)
                slider("消失时长", \.contentFadeOut, 0.03...0.4, step: 0.005, .milliseconds)
                slider("初始模糊", \.contentBlur, 0...20, step: 0.5, .points)
                slider("初始缩放", \.contentScale, 0.5...1.0, step: 0.01, .ratio)
            }

            Section("悬停意图") {
                slider("停留多久才展开", \.hoverInDelay, 0...0.5, step: 0.01, .milliseconds)
                slider("移出多久才收起", \.hoverOutDelay, 0...1.0, step: 0.01, .milliseconds)
            }

            Section("外形") {
                slider("两侧最小加宽", \.wingWidth, 0...200, step: 1, .points)
                slider("内容区高度", \.contentHeight, 24...160, step: 1, .points)
                slider("展开底部圆角", \.expandedBottomRadius, 0...40, step: 0.5, .points)
                slider("顶部内凹肩", \.shoulderRadius, 0...24, step: 0.5, .points)
                slider("收起底部圆角", \.collapsedBottomRadius, 0...24, step: 0.5, .points)
                slider("收起宽度微调", \.collapsedWidthAdjust, -20...10, step: 0.5, .points)
                slider("收起高度微调", \.collapsedHeightAdjust, -10...4, step: 0.5, .points)
            }

            Section("菜单栏图标") {
                let stats = items.stats
                Toggle("在岛上显示全部图标", isOn: $items.showAllItems)
                Toggle("用占位图标预览（调外形用）", isOn: $items.previewPlaceholders)
                if items.previewPlaceholders {
                    Stepper("占位图标数：\(store.tuning.placeholderCount)",
                            value: $store.tuning.placeholderCount, in: 1...30)
                }
                Picker("截图方式", selection: $items.captureMethod) {
                    ForEach(ItemImageCapturer.Method.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("权限") {
                    Text("辅助功能 \(permissions.accessibility ? "✓" : "✗")　屏幕录制 \(permissions.screenRecording ? "✓" : "✗")")
                }
                LabeledContent("上次扫描") {
                    Text("""
                        \(stats.totalItems) 个图标，隐藏 \(stats.hiddenItems) 个，\
                        \(Int(stats.scanDuration * 1000)) ms\(stats.lastScanWasFull ? "（全量）" : "")
                        """)
                        .monospacedDigit()
                }
                LabeledContent("上次截图") {
                    Text(stats.lastCapture.map { "\($0.formatted(date: .omitted, time: .standard))，\(stats.captured) 张" } ?? "—")
                        .monospacedDigit()
                }
                LabeledContent("菜单栏深浅") {
                    Text(items.rowStyles.isEmpty ? "未知" : items.rowStyles.sorted { $0.key < $1.key }
                        .map { "y=\($0.key) \($0.value == .light ? "浅色" : "深色")" }.joined(separator: "，"))
                }
                if !items.items.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(items.items) { item in
                                VStack(spacing: 2) {
                                    Group {
                                        if let icon = item.icon {
                                            Image(nsImage: icon.image(for: .dark))
                                        } else if let appIcon = item.appIcon {
                                            Image(nsImage: appIcon)
                                        }
                                    }
                                    .frame(height: 24)
                                    .padding(4)
                                    .background(.black, in: RoundedRectangle(cornerRadius: 6))
                                    Text(item.source.displayName).font(.caption2).lineLimit(1)
                                }
                                .frame(maxWidth: 70)
                            }
                        }
                    }
                }
                Button("立即全量扫描并重截") { items.refresh(full: true, forceCapture: true) }
            }

            Section("屏幕") {
                ForEach(Array(ScreenManager.shared.controllers.enumerated()), id: \.offset) { _, controller in
                    let g = controller.geometry
                    LabeledContent(g.isPhysical ? "真刘海" : "虚拟刘海") {
                        Text(String(format: "%.0f × %.0f @ (%.0f, %.0f)",
                                    g.notchRect.width, g.notchRect.height,
                                    g.notchRect.minX, g.notchRect.minY))
                            .monospacedDigit()
                            .textSelection(.enabled)
                    }
                }
            }

            Section {
                HStack {
                    Button("全部恢复默认") { store.reset() }
                    Spacer()
                    Button(copied ? "已复制 ✓" : "复制参数 JSON") { copyJSON() }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: pinned) { _, value in
            ScreenManager.shared.isPinned = value
        }
        .onChange(of: demoRunning) { _, running in
            running ? startDemo() : stopDemo()
        }
        .onDisappear {
            demoRunning = false
            stopDemo()
        }
    }

    private func slider(
        _ title: String,
        _ keyPath: WritableKeyPath<AnimationTuning, Double>,
        _ range: ClosedRange<Double>,
        step: Double,
        _ unit: TuningUnit
    ) -> some View {
        TuningSlider(
            title: title,
            value: Binding(
                get: { store.tuning[keyPath: keyPath] },
                set: { store.tuning[keyPath: keyPath] = ($0 / step).rounded() * step }
            ),
            range: range,
            unit: unit,
            defaultValue: AnimationTuning.defaults[keyPath: keyPath]
        )
    }

    private func startDemo() {
        stopDemo()
        demoTask = Task {
            while !Task.isCancelled {
                ScreenManager.shared.expandAll()
                try? await Task.sleep(for: .seconds(1.5 * store.tuning.slowMotion))
                guard !Task.isCancelled else { break }
                ScreenManager.shared.collapseAll()
                try? await Task.sleep(for: .seconds(1.1 * store.tuning.slowMotion))
            }
        }
    }

    private func stopDemo() {
        demoTask?.cancel()
        demoTask = nil
    }

    private func copyJSON() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.exportedJSON, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

private enum TuningUnit {
    case seconds, milliseconds, ratio, points, multiplier

    func format(_ value: Double) -> String {
        switch self {
        case .seconds: String(format: "%.2f s", value)
        case .milliseconds: String(format: "%.0f ms", value * 1000)
        case .ratio: String(format: "%.2f", value)
        case .points: String(format: "%.1f pt", value)
        case .multiplier: String(format: "%.1f×", value)
        }
    }
}

private struct TuningSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: TuningUnit
    let defaultValue: Double

    private var isModified: Bool { abs(value - defaultValue) > 0.0001 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                Spacer()
                if isModified {
                    Button {
                        value = defaultValue
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("恢复默认值 \(unit.format(defaultValue))")
                }
                Text(unit.format(value))
                    .monospacedDigit()
                    .foregroundStyle(isModified ? Color.accentColor : .secondary)
                    .frame(minWidth: 64, alignment: .trailing)
            }
            Slider(value: $value, in: range)
                .controlSize(.small)
        }
    }
}
