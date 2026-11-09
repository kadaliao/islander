import CoreGraphics
import Foundation
import ScreenCaptureKit
import os

private let log = Logger(subsystem: "com.kadaliao.islander", category: "capture")

/// 截取菜单栏图标窗口的图像（需要屏幕录制权限），全部在后台执行。
///
/// 每次截图都会让系统亮起录屏指示，所以调用方要尽量少截：只在图标有变化时截。
final class ItemImageCapturer: @unchecked Sendable {
    enum Method: String, CaseIterable, Identifiable, Sendable {
        /// CGWindowList：能截到被挤出屏幕的图标（实测 ScreenCaptureKit 截不到）
        case automatic
        /// 只用 ScreenCaptureKit（仅供调试对比）
        case screenCaptureKit

        var id: String { rawValue }
        var title: String {
            switch self {
            case .automatic: "CGWindowList（默认）"
            case .screenCaptureKit: "ScreenCaptureKit"
            }
        }
    }

    struct Request: Sendable {
        let key: String
        let windowID: CGWindowID
        let windowFrame: CGRect
        /// 要裁出的区域（CG 全局坐标）。窗口两侧带一点留白，按辅助功能报告的按钮区域裁
        let crop: CGRect?
    }

    struct Captured: @unchecked Sendable {
        let image: CGImage
        let scale: CGFloat
        let analysis: IconAppearance.Analysis
    }

    struct Batch: Sendable {
        var captured: [String: Captured] = [:]
        /// 图标窗口被系统挤窄了（刘海旁边放不下、菜单栏正在重排），截到的只是半个图标，丢弃
        var clipped: Set<String> = []
    }

    @concurrent
    func capture(_ requests: [Request], method: Method) async -> Batch {
        guard !requests.isEmpty else { return Batch() }
        var raw: [String: CGImage] = [:]
        switch method {
        case .automatic:
            for request in requests {
                raw[request.key] = Self.captureWithWindowList(request.windowID)
            }
        case .screenCaptureKit:
            raw = await captureWithScreenCaptureKit(requests)
        }

        var batch = Batch()
        for request in requests {
            guard let image = raw[request.key] else { continue }
            switch Self.crop(image, request: request) {
            case .clipped:
                batch.clipped.insert(request.key)
            case .empty:
                continue
            case .image(let cropped, let scale):
                // 全透明 = 实际没截到
                guard let analysis = IconAppearance.analyze(cropped) else { continue }
                batch.captured[request.key] = Captured(image: cropped, scale: scale, analysis: analysis)
            }
        }
        return batch
    }

    // MARK: - CGWindowList（已废弃但仍可用，通过 dlsym 调用，不依赖编译期声明）

    private typealias CreateImageFromArray = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?

    private static let createImageFromArray: CreateImageFromArray? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray") else {
            return nil
        }
        return unsafeBitCast(symbol, to: CreateImageFromArray.self)
    }()

    private static func captureWithWindowList(_ windowID: CGWindowID) -> CGImage? {
        guard let create = createImageFromArray else { return nil }
        // 这类接口要的是"直接存窗口 id 数值"的 CFArray，放 NSNumber 会被当成无效 id（实测拿不到任何结果）
        var values: [UnsafeRawPointer?] = [UnsafeRawPointer(bitPattern: UInt(windowID))]
        guard let windows = CFArrayCreate(kCFAllocatorDefault, &values, 1, nil) else { return nil }
        let options: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]
        return create(.null, windows, options.rawValue)?.takeRetainedValue()
    }

    // MARK: - ScreenCaptureKit（调试用）

    private func captureWithScreenCaptureKit(_ requests: [Request]) async -> [String: CGImage] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else {
            log.error("SCShareableContent 失败")
            return [:]
        }
        var windows: [CGWindowID: SCWindow] = [:]
        for window in content.windows { windows[window.windowID] = window }

        var images: [String: CGImage] = [:]
        for request in requests {
            guard let window = windows[request.windowID] else { continue }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(filter.pointPixelScale)
            let config = SCStreamConfiguration()
            config.width = max(Int(window.frame.width * scale), 1)
            config.height = max(Int(window.frame.height * scale), 1)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            config.captureResolution = .best
            images[request.key] = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
        return images
    }

    // MARK: - 裁剪

    private enum Cropped {
        case image(CGImage, scale: CGFloat)
        case clipped
        case empty
    }

    /// 每个图标独占一个窗口，窗口两侧各有约 7pt 透明留白。
    ///
    /// 竖直方向按辅助功能报告的按钮区域裁；水平方向以窗口里实际有像素的部分为准，宽度保持按钮宽度。
    /// 菜单栏重排、被刘海挤压时，辅助功能报告的位置会跟窗口错开，直接按它裁会切掉半个图标。
    /// 有像素的部分贴到了窗口边缘，说明窗口本身被系统挤窄了，截到的就是残缺的，整张不要。
    private static func crop(_ image: CGImage, request: Request) -> Cropped {
        let windowFrame = request.windowFrame
        guard windowFrame.width > 0 else { return .empty }
        let scale = CGFloat(image.width) / windowFrame.width
        guard let crop = request.crop else { return .image(image, scale: scale) }

        let local = crop.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY)
        var top = Int((local.minY * scale).rounded())
        var bottom = Int((local.maxY * scale).rounded())
        if top < 0 || bottom > image.height || bottom - top < 4 {
            top = 0
            bottom = image.height
        }
        guard let content = IconAppearance.opaqueColumns(image, rows: top..<bottom) else { return .empty }
        if content.lowerBound == 0 || content.upperBound >= image.width - 1 {
            return .clipped
        }

        let padding = Int((2 * scale).rounded())
        let width = min(max(Int((crop.width * scale).rounded()), content.count + 2 * padding), image.width)
        let center = (content.lowerBound + content.upperBound + 1) / 2
        let left = min(max(center - width / 2, 0), image.width - width)
        let rect = CGRect(x: left, y: top, width: width, height: bottom - top)
        guard let cropped = image.cropping(to: rect) else { return .empty }
        return .image(cropped, scale: scale)
    }
}
