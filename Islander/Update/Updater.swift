import AppKit
import Observation
import os

private let log = Logger(subsystem: "com.kadaliao.islander", category: "update")

/// 从 GitHub Releases 保持岛民最新：大约每天检查一次，在后台下载新版本，
/// 等你离开电脑一会儿再装上并重新打开（重新打开时菜单栏图标会闪一下），退出时也会装上。
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    enum State: Equatable {
        case idle
        /// 有新版本，还没下载
        case available(Release)
        case downloading(Release)
        /// 已下载并校验过：安装只是一次改名
        case ready(Release, archive: URL)
        case installing(Release)
        /// 已经装到磁盘上；本进程还是旧版本，重新打开才换成新的
        case installed(Release)
    }

    private(set) var state: State = .idle
    private(set) var checking = false
    /// 新版本为什么没装上，显示在设置里
    private(set) var problem: String?
    var checksAutomatically: Bool {
        didSet {
            UserDefaults.standard.set(checksAutomatically, forKey: Key.check)
            if checksAutomatically { nextCheck = .now }
        }
    }
    var installsAutomatically: Bool {
        didSet {
            UserDefaults.standard.set(installsAutomatically, forKey: Key.install)
            if installsAutomatically { nextCheck = .now }
        }
    }
    private(set) var lastCheck: Date? {
        didSet { UserDefaults.standard.set(lastCheck, forKey: Key.lastCheck) }
    }

    let current: AppVersion
    /// 正式版才更新自己；Xcode 构建的不会
    let enabled: Bool
    /// 这份 App 为什么没法替换自己（从磁盘映像运行、没有权限），能替换时是 nil
    let blocker: String?

    @ObservationIgnored private var nextCheck = Date.now
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// 校验或安装失败过的版本：后台不再碰它，等更新的版本出来或用户手动再试
    @ObservationIgnored private var gaveUpOn: AppVersion?

    private enum Key {
        static let check = "updates.check"
        static let install = "updates.install"
        static let lastCheck = "updates.lastCheck"
    }

    private static let interval: TimeInterval = 24 * 3600
    private static let retry: TimeInterval = 3600
    /// 键盘鼠标闲置这么久才自动装：重新打开时菜单栏图标会闪一下，不能在你用电脑时发生
    private static let idleBeforeInstall: TimeInterval = 300

    private var userAgent: String { "Islander/\(current) (macOS)" }
    private var installed: URL { Bundle.main.bundleURL }
    private var downloads: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.kadaliao.islander/Updates", isDirectory: true)
    }

    private init() {
        let d = UserDefaults.standard
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        current = version.flatMap(AppVersion.init) ?? AppVersion("0")!
        enabled = Updates.isReleaseBuild
        blocker = Updates.blocker(for: Bundle.main.bundleURL)
        checksAutomatically = d.object(forKey: Key.check) as? Bool ?? true
        installsAutomatically = d.object(forKey: Key.install) as? Bool ?? true
        lastCheck = d.object(forKey: Key.lastCheck) as? Date
    }

    /// 正在提供的新版本
    var release: Release? {
        switch state {
        case .available(let r), .downloading(let r), .ready(let r, _), .installing(let r), .installed(let r): r
        case .idle: nil
        }
    }

    var isWorking: Bool {
        switch state {
        case .downloading, .installing: true
        default: checking
        }
    }

    /// 两个开关都开着：下载和安装都不用问
    private var installsOnItsOwn: Bool { checksAutomatically && installsAutomatically }

    func start() {
        guard enabled, loop == nil else { return }
        nextCheck = lastCheck.map { $0.addingTimeInterval(Self.interval) } ?? .now
        let dir = downloads, current = current
        Task.detached(priority: .utility) { Updates.pruneDownloads(in: dir, keepingNewerThan: current) }
        loop = Task {
            // 等启动时的扫描、截图忙完
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                await tick()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func tick() async {
        if checksAutomatically, Date.now >= nextCheck, !isWorking { await check(userInitiated: false) }
        forgetMissingDownload()
        guard installsOnItsOwn, isUnattended else { return }
        if case .ready(let r, _) = state, gaveUpOn != r.version { await install(asked: false) }
        // 安装要一点时间：装完还没人在用才重新打开
        if case .installed = state, isUnattended { relaunch() }
    }

    /// 下载放在 Caches 里，可能被清理软件清掉：那就得重新下载
    private func forgetMissingDownload() {
        if case .ready(let r, let archive) = state, !FileManager.default.fileExists(atPath: archive.path) {
            state = .available(r)
            if installsAutomatically { nextCheck = .now }
        }
    }

    // MARK: - 检查

    /// 找更新的版本。从菜单里点的会告诉你结果，并提出安装
    func check(userInitiated: Bool) async {
        guard enabled else {
            if userInitiated {
                alert("这个版本不会自己更新", "只有从 GitHub Releases 下载的正式版本会自己更新。")
            }
            return
        }
        guard !isWorking else { return }
        if case .installed(let r) = state {
            if userInitiated { offer(r) }
            return
        }
        checking = true
        defer { checking = false }
        let r: Release
        do {
            r = try await Updates.latest(userAgent: userAgent)
        } catch {
            log.error("检查更新失败：\(error.localizedDescription, privacy: .public)")
            nextCheck = Date.now.addingTimeInterval(Self.retry)
            if userInitiated { failed(error) }
            return
        }
        lastCheck = .now
        nextCheck = Date.now.addingTimeInterval(Self.interval)
        guard r.version > current else {
            state = .idle
            if userInitiated { alert("已经是最新版本", "岛民 \(current) 是最新版本。") }
            return
        }
        if release?.version != r.version { problem = nil }
        if case .ready(let have, let archive) = state, have.version == r.version,
           FileManager.default.fileExists(atPath: archive.path) {
            if userInitiated { offer(r) }
        } else if blocker != nil || (!userInitiated && (!installsOnItsOwn || gaveUpOn == r.version)) {
            state = .available(r)
            if userInitiated { offer(r) }
        } else if await download(r, asked: userInitiated), userInitiated {
            offer(r)
        }
    }

    /// 下载并校验，坏的版本不会留着等安装
    private func download(_ r: Release, asked: Bool) async -> Bool {
        state = .downloading(r)
        do {
            let archive = try await Updates.download(r, to: downloads, userAgent: userAgent)
            let installed = installed
            try await Task.detached(priority: .utility) {
                let app = try Updates.unpack(archive, version: r.version, near: installed)
                try? FileManager.default.removeItem(at: app.deletingLastPathComponent())
            }.value
            log.notice("\(r.version, privacy: .public) 已下载并校验")
            state = .ready(r, archive: archive)
            problem = nil
            return true
        } catch {
            state = .available(r)
            note(error, for: r, asked: asked)
            return false
        }
    }

    // MARK: - 安装

    /// 菜单项和提示框里的"更新"：需要的话先下载，然后安装、重新打开
    func update() async {
        if blocker != nil { NSWorkspace.shared.open(Updates.releasesPage); return }
        forgetMissingDownload()
        if case .available(let r) = state, await !download(r, asked: true) { return }
        if case .ready = state { await install(asked: true) }
        relaunch()
    }

    private func install(asked: Bool) async {
        guard case .ready(let r, let archive) = state else { return }
        state = .installing(r)
        let installed = installed
        do {
            try await Task.detached(priority: .userInitiated) {
                try Updates.install(archive, version: r.version, over: installed)
            }.value
            log.notice("已安装 \(r.version, privacy: .public)")
            state = .installed(r)
            problem = nil
        } catch {
            state = .available(r)
            note(error, for: r, asked: asked)
        }
    }

    /// 以装好的新版本重新打开
    func relaunch() {
        guard case .installed = state else { return }
        do {
            try Updates.relaunch(installed)
            NSApp.terminate(nil)
        } catch {
            failed(error)
        }
    }

    /// 已经下载好时退出就装上，下次打开就是新版本
    func installOnQuit() {
        guard enabled, installsOnItsOwn, case .ready(let r, let archive) = state, gaveUpOn != r.version else { return }
        do {
            try Updates.install(archive, version: r.version, over: installed)
            log.notice("退出时安装了 \(r.version, privacy: .public)")
        } catch {
            log.error("退出时安装失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 网络问题一小时后重试。没通过校验的版本先放着，等更新的版本出来或用户手动再试
    private func note(_ error: Error, for r: Release, asked: Bool) {
        log.error("更新到 \(r.version, privacy: .public) 失败：\(error.localizedDescription, privacy: .public)")
        nextCheck = Date.now.addingTimeInterval(Self.retry)
        switch error as? UpdateError {
        case .signature, .wrongApp, .unpack, .cannotReplace:
            gaveUpOn = r.version
            problem = error.localizedDescription
        default:
            break
        }
        if asked { failed(error) }
    }

    /// 重新打开不会被注意到：键盘鼠标闲置了一阵，岛收着，设置窗口、提示框都没开，也没在替你拖图标
    private var isUnattended: Bool {
        let screens = ScreenManager.shared
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        return idle >= Self.idleBeforeInstall
            && !NSApp.isActive && NSApp.modalWindow == nil
            && !NSApp.windows.contains { $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized) }
            && !screens.isSuspended && !screens.controllers.contains { $0.model.isExpanded }
    }

    // MARK: - 提示框

    private func offer(_ r: Release) {
        let a = NSAlert()
        if case .installed = state {
            a.messageText = "岛民 \(r.version) 已经装好"
        } else {
            a.messageText = "岛民 \(r.version) 可以更新了"
        }
        if let blocker {
            a.informativeText = "你现在用的是 \(current)。" + blocker
            a.addButton(withTitle: "打开下载页")
        } else {
            a.informativeText = "你现在用的是 \(current)。更新时岛民会退出再自动打开，菜单栏图标会闪一下。"
                + (installsOnItsOwn ? "选「稍后」的话，等你离开电脑一会儿时自动装上。" : "")
            a.addButton(withTitle: "更新并重新打开")
        }
        a.addButton(withTitle: "稍后")
        a.addButton(withTitle: "更新内容")
        NSApp.activate()
        switch a.runModal() {
        case .alertFirstButtonReturn: Task { await update() }
        case .alertThirdButtonReturn: NSWorkspace.shared.open(r.page)
        default: break
        }
    }

    private func failed(_ error: Error) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "没能更新"
        a.informativeText = error.localizedDescription
        a.addButton(withTitle: "好")
        a.addButton(withTitle: "打开下载页")
        NSApp.activate()
        if a.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(Updates.releasesPage) }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate()
        a.runModal()
    }
}
