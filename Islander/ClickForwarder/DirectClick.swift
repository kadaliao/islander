import AppKit
import os

private let log = Logger(subsystem: "com.kadaliao.islander", category: "click")

/// 绕开控制中心，把右键直接交给图标所属的 App：图标不用露出来，App 的反应（弹菜单、开窗口）发生在屏幕外。
///
/// 实测（macOS 26.7）：菜单栏图标的窗口归控制中心，点击经它转给 App；藏在屏幕外的图标它只转左键，右键怎么发都收不到。
/// 转到 App 手里的点击带着两样东西：图标窗口的编号（字段 0x33）和每个图标固定的一个"通行码"（字段 146），
/// App 里的 AppKit 凭这两样认出"点在我的状态栏图标上"。自己拼一个带着它们的右键，直接投进 App 的事件队列，
/// App 就当成有人右键了它的图标：菜单弹在图标所在的位置（屏幕外，看不见），辅助功能照样读得到、按得了。
///
/// 通行码这样拿：往图标窗口发一次定向左键（屏幕外也送得到），在送到 App 之前用只盯这个 App 的事件开关截下来，
/// 读出字段再吞掉，App 收不到。通行码在 App 退出前不变，按图标记着。
/// 个别图标（实测 QQ 刚启动时）系统转给它的点击走另一条路（字段 105 = 1，像点在非活动行上），不带通行码，
/// 光露出来也不行；要在它露在菜单栏上时按位置真点一次，之后藏着也探得到（见 ClickForwarder.openDirectly）。
@MainActor
enum DirectClick {
    struct Route: Sendable {
        /// 事件里的窗口编号（系统转发时填的那个，不一定是发过去的窗口）
        let window: Int64
        let token: Int64
        /// 点在窗口里的位置（窗口坐标）
        let point: CGPoint
    }

    /// 岛民自己发的点击做的记号（写在 eventSourceUserData 里，系统转发时原样带着）
    nonisolated static let marker: Int64 = 0x15_1A_4D_E5
    nonisolated fileprivate static let windowField = CGEventField(rawValue: 0x33)!
    nonisolated fileprivate static let tokenField = CGEventField(rawValue: 146)!

    /// 记下的通行码，按图标；App 重开以后进程号变了，作废
    private static var routes: [String: (pid: pid_t, route: Route)] = [:]

    /// 设置事件"在窗口里的位置"的私有函数。系统转来的点击由窗口服务器填好；自己投给 App 的要自己填，
    /// 不填就是 (0, 0)，落在图标外面
    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    nonisolated private static let setWindowLocation: SetWindowLocation? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else { return nil }
        return unsafeBitCast(symbol, to: SetWindowLocation.self)
    }()

    static var isAvailable: Bool { setWindowLocation != nil }

    /// 这个图标的通行码：记着的直接用，没有就探一次
    /// - Parameters:
    ///   - window: 图标现在的窗口（活动行里的那个）
    ///   - byPosition: 探测的点击按位置送（图标得在屏幕上），默认按窗口编号送（藏着也送得到）
    static func route(for item: MenuBarItem, window: StatusBarRows.Window, byPosition: Bool = false) async -> Route? {
        if let known = known(item) { return known }
        return await probe(item, window: window, byPosition: byPosition)
    }

    /// 记着的通行码
    static func known(_ item: MenuBarItem) -> Route? {
        guard let known = routes[item.id], known.pid == item.pid else { return nil }
        return known.route
    }

    /// 不管记没记着，探一次；探到了就记下
    static func probe(_ item: MenuBarItem, window: StatusBarRows.Window, byPosition: Bool = false) async -> Route? {
        guard isAvailable else { return nil }
        // 探测用的左键一定要截得住，截不住就是一次真的左键：开关建不起来就不探
        guard let tap = EventTap(pid: item.pid, types: [.leftMouseDown, .leftMouseUp], swallow: true) else {
            log.error("\(item.id, privacy: .public) 建不起事件开关，没法探通行码")
            return nil
        }
        defer { tap.remove() }
        await ClickForwarder.postClick(.left, at: window.frame.center, window: window.id, pid: window.ownerPID,
                                       byPosition: byPosition)
        let how = byPosition ? "按位置" : "按窗口"
        guard let seen = await tap.wait() else {
            log.info("\(item.id, privacy: .public) 探测的点击（\(how, privacy: .public)）没送到它那里")
            return nil
        }
        guard seen.token != 0 else {
            log.info("\(item.id, privacy: .public) 系统转给它的点击（\(how, privacy: .public)，窗口 \(window.id)）不带通行码，转成了窗口 \(seen.window)")
            return nil
        }
        let route = Route(window: seen.window, token: seen.token,
                          point: CGPoint(x: window.frame.width / 2, y: window.frame.height / 2))
        routes[item.id] = (item.pid, route)
        log.info("\(item.id, privacy: .public) 拿到通行码（\(how, privacy: .public)，窗口 \(window.id) → \(seen.window)）")
        return route
    }

    /// 交给它以后没反应：通行码可能过期了（App 重建了图标），下次重新探
    static func forget(_ item: MenuBarItem) {
        routes[item.id] = nil
    }

    /// 给 App 按一下 Esc：关掉读不到的、开在屏幕外的菜单
    nonisolated static func escape(pid: pid_t) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInteractive).async {
                let source = CGEventSource(stateID: .hidSystemState)
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: down)
                    event?.setIntegerValueField(.eventSourceUserData, value: marker)
                    event?.postToPid(pid)
                    usleep(20_000)
                }
                continuation.resume()
            }
        }
    }

    /// 把一次右键直接投给 App
    nonisolated static func rightClick(_ route: Route, pid: pid_t) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInteractive).async {
                let source = CGEventSource(stateID: .hidSystemState)
                for type in [CGEventType.rightMouseDown, .rightMouseUp] {
                    guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                              mouseCursorPosition: .zero, mouseButton: .right)
                    else { continue }
                    event.setIntegerValueField(.mouseEventClickState, value: 1)
                    event.setIntegerValueField(.eventSourceUserData, value: marker)
                    event.setIntegerValueField(windowField, value: route.window)
                    event.setIntegerValueField(tokenField, value: route.token)
                    setWindowLocation?(event, route.point)
                    event.postToPid(pid)
                    usleep(60_000)
                }
                continuation.resume()
            }
        }
    }
}

/// 只盯一个 App 的事件开关：认出岛民自己发的点击（marker），记下窗口编号和通行码；swallow 时吞掉，App 收不到。
/// 回调在主线程的运行循环里跑；用完马上 remove，不然这个 App 的事件都要先经过岛民
@MainActor
private final class EventTap {
    private let port: CFMachPort
    private let source: CFRunLoopSource
    private let seen: TapSeen
    private let retained: Unmanaged<TapSeen>

    init?(pid: pid_t, types: [CGEventType], swallow: Bool) {
        let seen = TapSeen(swallow: swallow)
        let retained = Unmanaged.passRetained(seen)
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreateForPid(pid: pid, place: .headInsertEventTap,
                                                 options: swallow ? .defaultTap : .listenOnly,
                                                 eventsOfInterest: mask, callback: eventTapCallback,
                                                 userInfo: retained.toOpaque()),
              let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        else {
            retained.release()
            return nil
        }
        self.port = port
        self.source = source
        self.seen = seen
        self.retained = retained
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    /// 等开关截到岛民的点击（最多 0.4 秒）
    func wait() async -> (window: Int64, token: Int64)? {
        for _ in 0..<40 {
            let value = seen.lock.withLock { seen.value }
            if let value { return value }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    func remove() {
        CGEvent.tapEnable(tap: port, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFMachPortInvalidate(port)
        retained.release()
    }
}

/// 开关截到的东西。回调在主线程，读的人在主 actor 上，加锁只是保险
private final class TapSeen: @unchecked Sendable {
    let lock = NSLock()
    var value: (window: Int64, token: Int64)?
    let swallow: Bool
    init(swallow: Bool) { self.swallow = swallow }
}

private let eventTapCallback: CGEventTapCallBack = { _, _, event, info in
    guard let info, event.getIntegerValueField(.eventSourceUserData) == DirectClick.marker else {
        return Unmanaged.passUnretained(event)
    }
    let seen = Unmanaged<TapSeen>.fromOpaque(info).takeUnretainedValue()
    seen.lock.withLock {
        if seen.value == nil {
            seen.value = (event.getIntegerValueField(DirectClick.windowField), event.getIntegerValueField(DirectClick.tokenField))
        }
    }
    return seen.swallow ? nil : Unmanaged.passUnretained(event)
}
