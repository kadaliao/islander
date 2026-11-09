import ApplicationServices
import Foundation

/// AXUIElement 不是 Sendable，但 AX 接口本身可以在任意线程调用。包一层，方便在后台线程和主线程之间传递。
struct AXRef: @unchecked Sendable {
    let element: AXUIElement
}

/// 读取辅助功能属性的小工具，带类型检查，避免把错误类型的 CF 对象强转。
enum AX {
    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        guard let value = copy(element, attribute), CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        let string = value as! String
        return string.isEmpty ? nil : string
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    static func int(_ element: AXUIElement, _ attribute: String) -> Int? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
        return (value as! NSNumber).intValue
    }

    /// 元素的位置和大小，CG 全局坐标（原点在主屏左上角）
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = axValue(element, kAXPositionAttribute),
              let size = axValue(element, kAXSizeAttribute)
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin),
              AXValueGetValue(size, .cgSize, &extent)
        else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}
