import AppKit
import OpenSwitcherKit
import SwiftUI

_ = NSApplication.shared

setenv("OS_DISABLE_TAP", "1", 1)
let settings = SettingsStore.load()
if let tm = ProcessInfo.processInfo.environment["UI_THEME"] { settings.themeMode = Int(tm) ?? 0 }
UiTheme.shared.applyMode(settings.themeMode)

let engine = Engine(settings)
// UI_HEIGHT — рендер с нестандартной высотой окна (страницы длиннее 660)
let winH = Double(ProcessInfo.processInfo.environment["UI_HEIGHT"] ?? "") ?? 660
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: winH),
                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.titlebarAppearsTransparent = true
window.titleVisibility = .hidden
window.backgroundColor = .clear
let page = Int(ProcessInfo.processInfo.environment["UI_PAGE"] ?? "0") ?? 0
let vc = NSHostingController(rootView: SettingsRoot(engine: engine, initialPage: page))
vc.sizingOptions = [] // иначе hosting controller жмёт окно к fitting-минимуму (620)
window.contentViewController = vc
vc.view.wantsLayer = true
// окно не видно — AppKit не размечает hosting view сам: кадр задаём явно
vc.view.frame = NSRect(x: 0, y: 0, width: 880, height: winH)
window.layoutIfNeeded()

let view = vc.view
view.layoutSubtreeIfNeeded()

// прогоняем runloop, чтобы SwiftUI досчитал лейаут — ДО гейта размера:
// на macOS 15 синхронный layoutSubtreeIfNeeded без тиков runloop даёт 0x0
for _ in 0..<5 { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }

view.layoutSubtreeIfNeeded()
let size = view.bounds.size
guard size.width > 10 else { print("no size"); exit(2) }

let image = NSImage(size: size)
image.lockFocus()
if let ctx = NSGraphicsContext.current {
    let cg = ctx.cgContext
    cg.saveGState()
    cg.translateBy(x: 0, y: size.height)
    cg.scaleBy(x: 1, y: -1)
    UiTheme.shared.bg.setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
    view.layer?.render(in: cg)
    cg.restoreGState()
}
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    print("encode failed"); exit(2)
}
let out = ProcessInfo.processInfo.environment["UI_OUT"] ?? "/tmp/os_ui_render.png"
try! png.write(to: URL(fileURLWithPath: out))
print("rendered \(out)")
exit(0)
