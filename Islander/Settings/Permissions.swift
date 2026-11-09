import AppKit
import ApplicationServices
import Observation

/// 辅助功能（识别图标、点开菜单）和屏幕录制（截取图标样子）两项权限的状态。
@MainActor
@Observable
final class Permissions {
    static let shared = Permissions()

    private(set) var accessibility = AXIsProcessTrusted()
    private(set) var screenRecording = CGPreflightScreenCaptureAccess()
    /// 本次运行里点过"去授权"屏幕录制。macOS 要重启 App 后才认这项授权，界面上据此提示重启
    private(set) var requestedScreenRecording = false

    var allGranted: Bool { accessibility && screenRecording }

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var monitor: Task<Void, Never>?

    private init() {}

    /// 定期检查授权状态：没授权全时每秒一次，之后每 30 秒一次（发现被撤销）
    func startMonitoring() {
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                let interval: Duration = (self?.allGranted ?? true) ? .seconds(30) : .seconds(1)
                try? await Task.sleep(for: interval)
                self?.refresh()
            }
        }
    }

    func refresh() {
        let ax = AXIsProcessTrusted()
        let screen = CGPreflightScreenCaptureAccess()
        guard ax != accessibility || screen != screenRecording else { return }
        accessibility = ax
        screenRecording = screen
        onChange?()
    }

    func requestAccessibility() {
        // 第一次调用会弹系统提示并把岛民加进列表；同时直接打开设置页
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        openSettings("Privacy_Accessibility")
    }

    func requestScreenRecording() {
        requestedScreenRecording = true
        _ = CGRequestScreenCaptureAccess()
        openSettings("Privacy_ScreenCapture")
    }

    /// 屏幕录制授权要重启 App 才生效
    func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.8; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    private func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
