import AppKit

// 纯 AppKit 入口：状态栏图标要自己管（MenuBarHider 会改它的 length），不用 SwiftUI App / MenuBarExtra。
// Info.plist 里是 LSUIElement，是否进 Dock 由 AppSettings 在启动时按设置切换。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
