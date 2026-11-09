import AppKit
import ApplicationServices
import os

private let log = Logger(subsystem: "com.kadaliao.islander", category: "mirror")

/// 通过辅助功能读出的一个菜单项
struct MirroredMenuItem: Sendable {
    let title: String
    let isSeparator: Bool
    let isEnabled: Bool
    let isChecked: Bool
    let keyEquivalent: String
    /// 辅助功能的修饰键位：bit0 Shift、bit1 Option、bit2 Control、bit3 不含 Command
    let axModifiers: Int
    let submenu: [MirroredMenuItem]
    let element: AXRef
}

/// "镜像菜单"：读出菜单栏图标的菜单（不需要打开它），由岛民在岛上被点的图标正下方弹出一份同样的菜单，
/// 用户选中某项后，对真实菜单里对应的那一项执行辅助功能"按下"。
///
/// 实测（macOS 26.7）：多数 App 的菜单不打开也能完整读到，对没打开的菜单项"按下"会照常执行。
/// 读不到菜单的（弹自己小窗口的 App，如微信）返回 nil，由调用方改用别的办法打开。
enum MenuMirror {
    @concurrent
    static func read(_ item: MenuBarItem) async -> [MirroredMenuItem]? {
        let element = item.element.element
        AXUIElementSetMessagingTimeout(element, 0.3)
        guard let menu = AX.elements(element, kAXChildrenAttribute)
            .first(where: { AX.string($0, kAXRoleAttribute) == kAXMenuRole })
        else { return nil }
        let items = readItems(menu, depth: 0)
        return items.contains(where: { !$0.isSeparator }) ? items : nil
    }

    private static func readItems(_ menu: AXUIElement, depth: Int) -> [MirroredMenuItem] {
        AX.elements(menu, kAXChildrenAttribute).prefix(200).compactMap { element in
            let title = AX.string(element, kAXTitleAttribute) ?? ""
            let enabled = AX.bool(element, kAXEnabledAttribute) ?? true
            var submenu: [MirroredMenuItem] = []
            if depth < 3, let child = AX.elements(element, kAXChildrenAttribute)
                .first(where: { AX.string($0, kAXRoleAttribute) == kAXMenuRole }) {
                submenu = readItems(child, depth: depth + 1)
            }
            if title.isEmpty && submenu.isEmpty {
                // 没有标题：灰的是分隔线；能点的是自定义视图（滑块等），画不出来，跳过
                guard !enabled else { return nil }
                return MirroredMenuItem(title: "", isSeparator: true, isEnabled: false, isChecked: false,
                                        keyEquivalent: "", axModifiers: 0, submenu: [], element: AXRef(element: element))
            }
            return MirroredMenuItem(
                title: title,
                isSeparator: false,
                isEnabled: enabled,
                isChecked: !(AX.string(element, kAXMenuItemMarkCharAttribute) ?? "").isEmpty,
                keyEquivalent: AX.string(element, kAXMenuItemCmdCharAttribute) ?? "",
                axModifiers: AX.int(element, kAXMenuItemCmdModifiersAttribute) ?? 0,
                submenu: submenu,
                element: AXRef(element: element)
            )
        }
    }

    /// 对真实菜单里的那一项执行"按下"
    @concurrent
    static func perform(_ ref: AXRef) async -> AXError {
        AXUIElementSetMessagingTimeout(ref.element, 1.0)
        return AXUIElementPerformAction(ref.element, kAXPressAction as CFString)
    }
}

/// 把镜像菜单画成 NSMenu，弹在指定位置，返回用户选中的那一项
@MainActor
final class MirrorMenuPresenter: NSObject {
    private final class Box: NSObject {
        let ref: AXRef
        init(_ ref: AXRef) { self.ref = ref }
    }

    private var chosen: AXRef?

    /// 弹出菜单并等它关闭（NSMenu 的弹出是模态的，期间主线程在菜单的事件循环里）
    /// - Parameter point: 菜单左上角，`view` 的坐标系
    func popUp(_ items: [MirroredMenuItem], at point: NSPoint, in view: NSView, style: IslandStyle) -> AXRef? {
        chosen = nil
        let menu = makeMenu(items)
        menu.appearance = NSAppearance(named: style == .light ? .aqua : .darkAqua)
        menu.popUp(positioning: nil, at: point, in: view)
        return chosen
    }

    private func makeMenu(_ items: [MirroredMenuItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            if item.isSeparator {
                // 开头、结尾、连续的分隔线不要
                if menu.items.last.map({ !$0.isSeparatorItem }) ?? false {
                    menu.addItem(.separator())
                }
                continue
            }
            let entry = NSMenuItem(title: item.title,
                                   action: item.submenu.isEmpty ? #selector(choose(_:)) : nil,
                                   keyEquivalent: item.keyEquivalent.lowercased())
            entry.keyEquivalentModifierMask = Self.modifiers(item.axModifiers)
            entry.target = self
            entry.isEnabled = item.isEnabled
            entry.state = item.isChecked ? .on : .off
            entry.representedObject = Box(item.element)
            if !item.submenu.isEmpty {
                entry.submenu = makeMenu(item.submenu)
            }
            menu.addItem(entry)
        }
        while menu.items.last?.isSeparatorItem == true {
            menu.removeItem(at: menu.items.count - 1)
        }
        return menu
    }

    @objc private func choose(_ sender: NSMenuItem) {
        chosen = (sender.representedObject as? Box)?.ref
        log.info("选中镜像菜单项「\(sender.title, privacy: .public)」")
    }

    private static func modifiers(_ ax: Int) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if ax & 8 == 0 { flags.insert(.command) }
        if ax & 1 != 0 { flags.insert(.shift) }
        if ax & 2 != 0 { flags.insert(.option) }
        if ax & 4 != 0 { flags.insert(.control) }
        return flags
    }
}
