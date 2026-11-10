import AppKit
import Observation
import SwiftUI

/// 岛民的设置窗口：通用、菜单栏布局、灵动岛、权限、关于。
/// 从菜单栏图标的右键菜单、Dock 图标、⌘, 打开；首次启动缺权限时自动打开到"权限"页。
@MainActor
final class SettingsController {
    static let shared = SettingsController()

    enum Pane: String, CaseIterable, Identifiable {
        case general, layout, island, permissions, about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "通用"
            case .layout: "菜单栏布局"
            case .island: "灵动岛"
            case .permissions: "权限"
            case .about: "关于岛民"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape.fill"
            case .layout: "menubar.rectangle"
            case .island: "capsule.fill"
            case .permissions: "lock.shield.fill"
            case .about: "info.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .general: .gray
            case .layout: .blue
            case .island: .black
            case .permissions: .green
            case .about: .orange
            }
        }
    }

    @MainActor
    @Observable
    final class State {
        var pane: Pane? = .general {
            didSet { onPaneChange?(pane ?? .general) }
        }
        @ObservationIgnored var onPaneChange: ((Pane) -> Void)?
    }

    let state = State()
    private var window: NSWindow?
    private static let shownKey = "onboardingShown"

    private init() {}

    /// 首次启动、权限没给全时打开到"权限"页
    func showIfNeeded() {
        guard !Permissions.shared.allGranted, !UserDefaults.standard.bool(forKey: Self.shownKey) else { return }
        show(.permissions)
    }

    func show(_ pane: Pane? = nil) {
        UserDefaults.standard.set(true, forKey: Self.shownKey)
        if let pane { state.pane = pane }
        let window = window ?? makeWindow()
        window.title = (state.pane ?? .general).title
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        updateLayoutEditing()
    }

    /// "菜单栏布局"页开着时要截全部图标；关窗口时 SwiftUI 不一定通知页面消失，由这里统一管
    private func updateLayoutEditing(closing: Bool = false) {
        HiddenItemsStore.shared.isEditingLayout = !closing && (window?.isVisible ?? false) && state.pane == .layout
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(state: state))
        hosting.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        // 有工具栏，侧边栏才会像系统设置那样一直延伸到标题栏
        window.toolbar = NSToolbar(identifier: "IslanderSettings")
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 760, height: 560))
        window.center()
        window.setFrameAutosaveName("IslanderSettings")
        state.onPaneChange = { [weak self, weak window] pane in
            window?.title = pane.title
            self?.updateLayoutEditing()
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                               queue: .main) { _ in
            MainActor.assumeIsolated { SettingsController.shared.updateLayoutEditing(closing: true) }
        }
        self.window = window
        return window
    }
}

private struct SettingsView: View {
    @Bindable var state: SettingsController.State

    var body: some View {
        NavigationSplitView {
            List(SettingsController.Pane.allCases, selection: $state.pane) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    SidebarIcon(symbol: pane.symbol, tint: pane.tint)
                }
                .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 240)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch state.pane ?? .general {
                case .general: GeneralPane()
                case .layout: LayoutPane()
                case .island: IslandPane()
                case .permissions: PermissionsPane()
                case .about: AboutPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 700, minHeight: 480)
    }
}

/// 系统设置风格的侧边栏图标：彩色圆角方块里一个白色符号
private struct SidebarIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(tint.gradient))
    }
}

// MARK: - 通用

private struct GeneralPane: View {
    @Bindable private var settings = AppSettings.shared
    private var hider: MenuBarHider { .shared }

    var body: some View {
        Form {
            Section {
                Toggle("登录时启动岛民", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
                if settings.launchAtLoginNeedsApproval {
                    HStack {
                        Text("需要在系统设置里允许岛民作为登录项。")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("打开登录项设置") { settings.openLoginItemsSettings() }
                    }
                }
            }

            Section {
                Toggle("在 Dock 中显示", isOn: $settings.showInDock)
            } footer: {
                Text("点 Dock 图标打开设置；右键它可以隐藏 / 显示菜单栏图标、展开灵动岛。关掉后，从菜单栏上的岛民图标右键打开设置，或者再次打开岛民 App。")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("把分隔线左边的图标藏起来", isOn: Binding(
                    get: { hider.isHidden },
                    set: { hider.setHidden($0, interactive: true) }
                ))
                LabeledContent("哪些图标藏起来") {
                    Button("调整菜单栏布局…") { SettingsController.shared.state.pane = .layout }
                }
            } footer: {
                Text("藏起来的图标不占菜单栏，鼠标移到刘海上时出现在灵动岛里。点菜单栏上的岛民图标也能切换。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { settings.refreshLaunchAtLogin() }
    }
}

// MARK: - 灵动岛

private struct IslandPane: View {
    @Bindable private var settings = AppSettings.shared
    @Bindable private var items = HiddenItemsStore.shared
    @Bindable private var tuning = TuningStore.shared

    var body: some View {
        Form {
            Section {
                Picker("岛的颜色", selection: $settings.islandAppearance) {
                    ForEach(AppSettings.IslandAppearance.allCases) { Text($0.title).tag($0) }
                }
                Toggle("在岛上显示全部图标", isOn: $items.showAllItems)
            } footer: {
                Text("跟随菜单栏：深色菜单栏上是黑色的岛，浅色菜单栏上是毛玻璃。显示全部图标时，菜单栏上的图标全部收到岛上，菜单栏只留岛民的开关和系统固定的图标（时钟、控制中心）；关掉后回到原来的布局。")
                    .foregroundStyle(.secondary)
            }

            Section("悬停") {
                DelaySlider(title: "停留多久才展开", value: $tuning.tuning.hoverInDelay, range: 0...0.5,
                            defaultValue: AnimationTuning.defaults.hoverInDelay)
                DelaySlider(title: "移开多久才收起", value: $tuning.tuning.hoverOutDelay, range: 0...1,
                            defaultValue: AnimationTuning.defaults.hoverOutDelay)
            }

            Section {
                LabeledContent {
                    Button("打开…") { DebugPanelController.shared.show() }
                } label: {
                    Text("手感调试")
                    Text("弹簧动画、外形尺寸等细节参数，边调边看")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct DelaySlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: Binding(get: { value }, set: { value = ($0 * 100).rounded() / 100 }), in: range)
                    .frame(minWidth: 160)
                Text("\(Int((value * 1000).rounded())) ms")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
                Button {
                    value = defaultValue
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("恢复默认值")
                .opacity(abs(value - defaultValue) > 0.0001 ? 1 : 0)
            }
        }
    }
}

// MARK: - 权限

private struct PermissionsPane: View {
    private var permissions: Permissions { Permissions.shared }

    var body: some View {
        Form {
            Section {
                PermissionRow(
                    symbol: "accessibility",
                    title: "辅助功能",
                    detail: "识别菜单栏上每个图标属于哪个 App，替你点开它们的菜单，以及在「菜单栏布局」里替你拖动图标。",
                    granted: permissions.accessibility,
                    action: permissions.requestAccessibility
                )
                PermissionRow(
                    symbol: "rectangle.dashed.badge.record",
                    title: "屏幕录制",
                    detail: "截取菜单栏图标的样子显示在岛上。没有这项权限时，岛上显示对应 App 的图标。",
                    granted: permissions.screenRecording,
                    action: permissions.requestScreenRecording
                )
            } header: {
                Text("岛民需要两项权限才能把图标搬到岛上。只读取菜单栏，不会录制屏幕上的其他内容。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
                    .padding(.bottom, 4)
            }

            if permissions.requestedScreenRecording && !permissions.screenRecording {
                Section {
                    HStack {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .foregroundStyle(.orange)
                        Text("在系统设置里打开屏幕录制后，需要重新启动岛民才会生效。")
                        Spacer()
                        Button("重新启动岛民") { permissions.relaunch() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if granted {
                Label("已授权", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("去授权", action: action)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 关于

private struct AboutPane: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "版本 \(short)（\(build)）"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
            Text("岛民")
                .font(.system(size: 26, weight: .semibold))
            Text(version)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("把菜单栏图标藏进刘海，鼠标碰到刘海时在灵动岛里出现。")
                .padding(.top, 6)
            Text(Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? "")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.top, 12)
        }
        .multilineTextAlignment(.center)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
