import CoreGraphics

/// 灵动岛的配色：深色菜单栏上是纯黑的岛 + 浅色图标；浅色菜单栏上是浅色毛玻璃 + 深色图标
enum IslandStyle: Sendable, Equatable {
    case dark
    case light
}

/// 菜单栏图标的明暗处理。
///
/// macOS 26 的菜单栏是透明的，单色图标的颜色跟着壁纸走（浅色壁纸下是黑色，深色壁纸下是白色）。
/// 截到的图标要放到和它所在菜单栏不一样的背景上时（比如白色图标放到浅色毛玻璃上），
/// 把其中的灰阶像素反色；彩色像素（App 自己的彩色 logo、红色角标）保持不变。
enum IconAppearance {
    enum Tone: Sendable {
        case dark
        case light
    }

    struct Analysis: Sendable {
        /// 以单色为主时的明暗；彩色图标为 nil
        let monochromeTone: Tone?
        /// 像素内容的指纹，图标没变时复用上一次的图，避免界面无谓刷新
        let fingerprint: Int
    }

    /// 返回 nil 表示图像是空的（全透明），通常说明截图失败
    static func analyze(_ image: CGImage) -> Analysis? {
        guard let bitmap = Bitmap(image) else { return Analysis(monochromeTone: nil, fingerprint: 0) }

        var weight = 0.0
        var luminance = 0.0
        var grayWeight = 0.0
        bitmap.forEachPixel { r, g, b, alpha in
            guard alpha > 0.15 else { return }
            weight += alpha
            luminance += alpha * (0.299 * r + 0.587 * g + 0.114 * b)
            if max(r, g, b) - min(r, g, b) < grayThreshold { grayWeight += alpha }
        }
        guard weight > 0 else { return nil }

        var tone: Tone?
        if grayWeight / weight > 0.7 {
            let average = luminance / weight
            if average < 0.45 { tone = .dark } else if average > 0.55 { tone = .light }
        }
        return Analysis(monochromeTone: tone, fingerprint: bitmap.fingerprint())
    }

    /// 让图标在指定配色的岛上看得清：图标明暗和背景相同时，反转其中的灰阶像素
    static func adapt(_ image: CGImage, tone: Tone?, for style: IslandStyle) -> CGImage {
        let needsInversion = (style == .dark && tone == .dark) || (style == .light && tone == .light)
        guard needsInversion, let bitmap = Bitmap(image) else { return image }
        bitmap.invertGrayPixels(threshold: grayThreshold)
        return bitmap.makeImage() ?? image
    }

    /// 图像里有内容（不透明）的列范围，只看 `rows` 这几行（从上往下数）。全透明返回 nil
    static func opaqueColumns(_ image: CGImage, rows: Range<Int>) -> ClosedRange<Int>? {
        guard let bitmap = Bitmap(image) else { return nil }
        return bitmap.opaqueColumns(rows: rows.clamped(to: 0..<image.height), minAlpha: 26)
    }

    /// 截一个已知是单色模板图标（岛民自己的开关）在某块屏幕菜单栏上的样子，判断那块菜单栏的深浅
    static func style(ofMenuBarShowing probe: CGImage) -> IslandStyle? {
        switch analyze(probe)?.monochromeTone {
        case .dark: .light    // 图标是黑的 → 菜单栏是浅色
        case .light: .dark
        case nil: nil
        }
    }

    private static let grayThreshold = 0.18
}

/// 把 CGImage 画进一块 RGBA（预乘 alpha）内存，方便逐像素处理
private final class Bitmap {
    let context: CGContext
    let pixels: UnsafeMutablePointer<UInt8>
    let count: Int
    let width: Int

    init?(_ image: CGImage) {
        width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        self.context = context
        count = width * height * 4
        pixels = data.bindMemory(to: UInt8.self, capacity: count)
    }

    /// 回调参数：去掉预乘后的 r, g, b（0…1）和 alpha（0…1）
    func forEachPixel(_ body: (Double, Double, Double, Double) -> Void) {
        for i in stride(from: 0, to: count, by: 4) {
            let alpha = Double(pixels[i + 3]) / 255
            guard alpha > 0 else { continue }
            let (r, g, b) = color(at: i, alpha: alpha)
            body(r, g, b, alpha)
        }
    }

    /// 预乘 alpha 下的反色是 c' = a - c
    func invertGrayPixels(threshold: Double) {
        for i in stride(from: 0, to: count, by: 4) {
            let a = pixels[i + 3]
            guard a > 0 else { continue }
            let (r, g, b) = color(at: i, alpha: Double(a) / 255)
            guard max(r, g, b) - min(r, g, b) < threshold else { continue }
            pixels[i] = a &- min(pixels[i], a)
            pixels[i + 1] = a &- min(pixels[i + 1], a)
            pixels[i + 2] = a &- min(pixels[i + 2], a)
        }
    }

    func makeImage() -> CGImage? { context.makeImage() }

    /// 内存里第 0 行是图像最上面一行
    func opaqueColumns(rows: Range<Int>, minAlpha: UInt8) -> ClosedRange<Int>? {
        var first: Int?
        var last: Int?
        for row in rows {
            let base = row * width * 4
            for column in 0..<width where pixels[base + column * 4 + 3] >= minAlpha {
                first = min(first ?? column, column)
                last = max(last ?? column, column)
            }
        }
        guard let first, let last else { return nil }
        return first...last
    }

    func fingerprint() -> Int {
        var hasher = Hasher()
        hasher.combine(width)
        hasher.combine(bytes: UnsafeRawBufferPointer(start: pixels, count: count))
        return hasher.finalize()
    }

    private func color(at i: Int, alpha: Double) -> (Double, Double, Double) {
        (min(Double(pixels[i]) / 255 / alpha, 1),
         min(Double(pixels[i + 1]) / 255 / alpha, 1),
         min(Double(pixels[i + 2]) / 255 / alpha, 1))
    }
}
