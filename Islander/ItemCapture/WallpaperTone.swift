import CoreGraphics
import Foundation
import ImageIO

/// 根据壁纸判断一块屏幕菜单栏的深浅。
///
/// macOS 26 的菜单栏是透明的，菜单栏图标深浅跟着它下面那条壁纸的亮度走。
/// 直接读壁纸文件、取顶部一条的平均亮度，不需要截屏，也就不会亮录屏指示。
/// （截图探针只在那块屏幕的菜单栏恰好是"活动行"时才截得到内容，只能作为校正。）
enum WallpaperTone {
    struct Key: Hashable, Sendable {
        let url: URL
        let modified: Date?
    }

    static func key(for url: URL) -> Key {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return Key(url: url, modified: modified)
    }

    /// 读不出来（文件夹、动态壁纸取不到图等）返回 nil
    static func style(forWallpaperAt url: URL) -> IslandStyle? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 320,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options)
        else { return nil }

        // 菜单栏大约占屏幕高度的 3%，取顶部 4% 的一条
        let bandHeight = max(1, thumbnail.height * 4 / 100)
        guard let band = thumbnail.cropping(to: CGRect(x: 0, y: 0, width: thumbnail.width, height: bandHeight)),
              let luminance = averageLuminance(band)
        else { return nil }
        return luminance > 0.55 ? .light : .dark
    }

    private static func averageLuminance(_ image: CGImage) -> Double? {
        let width = 32
        let height = 4
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var total = 0.0
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            total += 0.299 * Double(pixels[i]) + 0.587 * Double(pixels[i + 1]) + 0.114 * Double(pixels[i + 2])
        }
        return total / Double(width * height) / 255
    }
}
