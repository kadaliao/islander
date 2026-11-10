#if DEBUG
import AppKit
import ImageIO
import os

private let log = Logger(subsystem: "com.kadaliao.islander", category: "debug")

/// 仅调试构建：从终端用分布式通知驱动岛民，做自动化测试。
///
///     com.kadaliao.islander.debug.open      object = 图标 id 的一部分（如 "Alfred"）：模拟点击岛上的这个图标
///     com.kadaliao.islander.debug.style     object = "light" / "dark" / "auto"：强制配色
///     com.kadaliao.islander.debug.pin       object = "on" / "off"：展开并锁定岛
///     com.kadaliao.islander.debug.snapshot  object = PNG 路径[@高度]：把岛所在区域截图存下来
///     com.kadaliao.islander.debug.settings  object = 页面名（general / layout / island / permissions / about）：打开设置
///     com.kadaliao.islander.debug.window    object = PNG 路径：把设置窗口截图存下来
///     com.kadaliao.islander.debug.move      object = "图标>always / hidden / visible[@放在它前面的图标]"：移动菜单栏图标
///     com.kadaliao.islander.debug.hidden    object = "on" / "off"：藏起 / 显示分隔线左边的图标
///     com.kadaliao.islander.debug.layout    打印当前菜单栏布局
///     com.kadaliao.islander.debug.showall   object = "on" / "off"：岛上显示全部图标
///     com.kadaliao.islander.debug.windows   打印菜单栏图标窗口（编号、位置、标题）
///     com.kadaliao.islander.debug.chain     打印每个图标认的是哪个窗口（记着的 / 现在认的 / 合起来认的）
///     com.kadaliao.islander.debug.capture   object = 窗口编号：截一张，打印耗时和不透明像素数
///     com.kadaliao.islander.debug.slow      object = 倍数：动画慢放（会存进手感参数，用完改回 1）
enum DebugHooks {
    @MainActor
    static func install() {
        observe("open") { query in
            guard let item = HiddenItemsStore.shared.items.first(where: { $0.id.localizedCaseInsensitiveContains(query) }),
                  let controller = ScreenManager.shared.controllers.first,
                  let view = controller.model.hostView
            else {
                log.error("调试点击：没找到 \(query, privacy: .public)")
                return
            }
            log.info("调试点击：\(item.id, privacy: .public)")
            controller.expand()
            // 锚点：岛内容区正中的一个图标位置
            let layout = controller.model.layout
            let anchor = CGRect(x: view.bounds.midX - 14, y: layout.notchSize.height + 10, width: 28, height: 28)
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                ClickForwarder.shared.open(item.source, isHidden: item.isHidden, from: controller.model, anchor: anchor)
            }
        }
        observe("style") { value in
            HiddenItemsStore.shared.debugStyleOverride = switch value {
            case "light": .light
            case "dark": .dark
            default: nil
            }
        }
        observe("pin") { value in
            ScreenManager.shared.isPinned = value == "on"
        }
        observe("settings") { value in
            SettingsController.shared.show(SettingsController.Pane(rawValue: value))
        }
        observe("window") { path in
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title != "" && $0.contentViewController != nil
                && !($0 is NSPanel) }) else { return }
            let id = CGWindowID(window.windowNumber)
            DispatchQueue.global().async {
                guard let image = captureWindow(id) else { return log.error("设置窗口截图失败") }
                save(image, to: path)
            }
        }
        observe("move") { value in
            let parts = value.split(separator: ">", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            let target = parts[1].split(separator: "@", maxSplits: 1).map(String.init)
            let items = HiddenItemsStore.shared.allItems
            guard let item = items.first(where: { $0.id.localizedCaseInsensitiveContains(parts[0]) }) else {
                return log.error("调试移动：没找到 \(parts[0], privacy: .public)")
            }
            let before = target.count > 1 ? items.first { $0.id.localizedCaseInsensitiveContains(target[1]) }?.id : nil
            let section: MenuBarItemMover.Section = switch target[0] {
            case "always": .alwaysHidden
            case "hidden": .hidden
            default: .visible
            }
            let destination = MenuBarItemMover.Destination(section: section, beforeID: before)
            Task {
                let ok = await MenuBarItemMover.shared.move(item.id, to: destination)
                log.notice("调试移动 \(item.id, privacy: .public)：\(ok ? "成功" : MenuBarItemMover.shared.lastError ?? "失败", privacy: .public)")
            }
        }
        observe("windows") { _ in
            guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return }
            let layer = Int(CGWindowLevelForKey(.statusWindow))
            for info in list where (info[kCGWindowLayer as String] as? Int) == layer {
                let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
                guard let bounds, bounds.minY < 40 else { continue }
                log.notice("""
                    窗口 \(info[kCGWindowNumber as String] as? Int ?? 0) \(String(describing: bounds), privacy: .public) \
                    名字=\(info[kCGWindowName as String] as? String ?? "-", privacy: .public) \
                    属于=\(info[kCGWindowOwnerName as String] as? String ?? "-", privacy: .public)
                    """)
            }
        }
        observe("chain") { _ in
            let store = HiddenItemsStore.shared
            let known = store.itemWindows
            Task {
                let own = MenuBarScanner.AppInfo(NSRunningApplication.current)
                let result = await store.scanner.scan(adding: [], own: own, isFull: false)
                let fresh = MenuBarSnapshot(mapping: result)
                let withKnown = MenuBarSnapshot(mapping: result, knownWindows: known)
                for item in result.items {
                    let ax = Int(item.frame.minX)
                    log.notice("""
                        链 \(item.id, privacy: .public) ax=\(ax) 记着=\(known[item.id].map(String.init) ?? "-", privacy: .public) \
                        现认=\(fresh?.itemWindows[item.id].map(String.init) ?? "-", privacy: .public) \
                        合用=\(withKnown?.itemWindows[item.id].map(String.init) ?? "-", privacy: .public)
                        """)
                }
            }
        }
        observe("capture") { value in
            guard let id = UInt32(value) else { return }
            DispatchQueue.global().async {
                let start = Date()
                typealias Create = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
                guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray") else { return }
                let create = unsafeBitCast(symbol, to: Create.self)
                var values: [UnsafeRawPointer?] = [UnsafeRawPointer(bitPattern: UInt(id))]
                let array = CFArrayCreate(kCFAllocatorDefault, &values, 1, nil)!
                let options: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]
                let image = create(.null, array, options.rawValue)?.takeRetainedValue()
                let created = Date()
                var alpha = 0
                if let image, let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                                      bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                    let pixels = context.data!.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
                    for i in stride(from: 3, to: image.width * image.height * 4, by: 4) where pixels[i] > 0 { alpha += 1 }
                }
                log.notice("""
                    截图窗口 \(id)：\(image.map { "\($0.width)×\($0.height)" } ?? "nil", privacy: .public)，\
                    创建 \(Int(created.timeIntervalSince(start) * 1000)) ms，画出来 \(Int(Date().timeIntervalSince(created) * 1000)) ms，\
                    不透明像素 \(alpha)
                    """)
            }
        }
        observe("showall") { value in
            HiddenItemsStore.shared.showAllItems = value == "on"
        }
        observe("slow") { value in
            TuningStore.shared.tuning.slowMotion = Double(value) ?? 1
        }
        observe("hidden") { value in
            MenuBarHider.shared.setHidden(value == "on", interactive: false)
        }
        observe("layout") { _ in
            let items = HiddenItemsStore.shared.allItems
            let always = items.filter(\.isAlwaysHidden).map(\.source.appName).joined(separator: " ")
            let hidden = items.filter { $0.isHidden && !$0.isAlwaysHidden }.map(\.source.appName).joined(separator: " ")
            let visible = items.filter { !$0.isHidden }.map(\.source.appName).joined(separator: " ")
            log.notice("布局 永远隐藏：\(always, privacy: .public) ｜ 岛上：\(hidden, privacy: .public) ｜ 菜单栏：\(visible, privacy: .public)")
        }
        observe("snapshot") { value in
            guard let geometry = ScreenManager.shared.controllers.first?.geometry else { return }
            // 岛周围一块区域（CG 坐标）；"路径@高度" 可以截得更高（看岛下面的弹窗）
            let parts = value.split(separator: "@", maxSplits: 1).map(String.init)
            let path = parts.first ?? value
            let height = parts.count > 1 ? CGFloat(Double(parts[1]) ?? 160) : 160
            let area = CGRect(x: geometry.notchRect.midX - 400, y: geometry.menuBarRowTop, width: 800, height: height)
            DispatchQueue.global().async {
                guard let image = captureScreen(area) else { return }
                save(image, to: path)
            }
        }
    }

    @MainActor
    private static func observe(_ name: String, _ handler: @escaping @MainActor (String) -> Void) {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.kadaliao.islander.debug.\(name)"), object: nil, queue: .main
        ) { note in
            let value = (note.object as? String) ?? ""
            MainActor.assumeIsolated { handler(value) }
        }
    }

    private static func save(_ image: CGImage, to path: String) {
        let url = URL(fileURLWithPath: path)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    private typealias CreateImage = @convention(c) (CGRect, UInt32, CGWindowID, UInt32) -> Unmanaged<CGImage>?

    private static func captureScreen(_ rect: CGRect) -> CGImage? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        return create(rect, CGWindowListOption.optionOnScreenOnly.rawValue, kCGNullWindowID,
                      CGWindowImageOption.bestResolution.rawValue)?.takeRetainedValue()
    }

    private static func captureWindow(_ id: CGWindowID) -> CGImage? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        return create(.null, CGWindowListOption.optionIncludingWindow.rawValue, id,
                      CGWindowImageOption.bestResolution.rawValue)?.takeRetainedValue()
    }
}
#endif
