import AppKit

/// Палитра и типографика (порт UiTheme.cs 1:1 — те же hex-значения).
public final class UiTheme {
    public static let shared = UiTheme()

    /// 0 = как в системе, 1 = светлая, 2 = тёмная.
    public var mode = 0
    private var light = true

    public var changed: (() -> Void)?

    public private(set) var bg: NSColor = .clear
    public private(set) var sidebarBg: NSColor = .clear
    public private(set) var card: NSColor = .clear
    public private(set) var cardBorder: NSColor = .clear
    public private(set) var input: NSColor = .clear
    public private(set) var inputBorder: NSColor = .clear
    public private(set) var chipBg: NSColor = .clear
    public private(set) var text: NSColor = .clear
    public private(set) var dim: NSColor = .clear
    public private(set) var accent: NSColor = .clear
    public private(set) var accentHover: NSColor = .clear
    public private(set) var accentPressed: NSColor = .clear
    public private(set) var accentSoft: NSColor = .clear
    public private(set) var hero1: NSColor = .clear
    public private(set) var hero2: NSColor = .clear
    public private(set) var paused1: NSColor = .clear
    public private(set) var paused2: NSColor = .clear
    public private(set) var ok: NSColor = .clear
    public private(set) var warn: NSColor = .clear
    public private(set) var danger: NSColor = .clear
    public private(set) var trackOff: NSColor = .clear
    public private(set) var rowHover: NSColor = .clear

    public var isLight: Bool { light }

    private init() {
        apply(readSystemLight())   // палитра валидна до первого applyMode
    }

    public func applyMode(_ m: Int) {
        mode = m
        apply(m == 1 ? true : (m == 2 ? false : readSystemLight()))
    }

    public func refreshFromSystem() {
        if mode == 0 { apply(readSystemLight()) }
    }

    public func readSystemLight() -> Bool {
        guard let app = NSApp else { return true }
        let style = app.effectiveAppearance.bestMatch(from:
            [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua])
        return style == NSAppearance.Name.aqua
    }

    private func apply(_ l: Bool) {
        light = l
        if l {
            bg = UiTheme.hex("#F4F5F8"); sidebarBg = UiTheme.hex("#EAECF1"); card = UiTheme.hex("#FFFFFF")
            cardBorder = UiTheme.hex("#E2E4EA"); input = UiTheme.hex("#FFFFFF"); inputBorder = UiTheme.hex("#D6DAE2")
            chipBg = UiTheme.hex("#F0F2F6"); text = UiTheme.hex("#191B1F"); dim = UiTheme.hex("#6E747E")
            accent = UiTheme.hex("#3671F6"); accentHover = UiTheme.hex("#2861E4"); accentPressed = UiTheme.hex("#2153C6")
            accentSoft = UiTheme.hex("#E8EFFF"); hero1 = UiTheme.hex("#3D74F5"); hero2 = UiTheme.hex("#8B5CF6")
            paused1 = UiTheme.hex("#B4BAC5"); paused2 = UiTheme.hex("#8B919D")
            ok = UiTheme.hex("#1FA463"); warn = UiTheme.hex("#C78A12"); danger = UiTheme.hex("#D93A3F")
            trackOff = UiTheme.hex("#CDD2DB"); rowHover = UiTheme.hex("#F2F4F8")
        } else {
            bg = UiTheme.hex("#141519"); sidebarBg = UiTheme.hex("#101114"); card = UiTheme.hex("#1C1E24")
            cardBorder = UiTheme.hex("#2A2D35"); input = UiTheme.hex("#121317"); inputBorder = UiTheme.hex("#31353F")
            chipBg = UiTheme.hex("#22252C"); text = UiTheme.hex("#E9EAEE"); dim = UiTheme.hex("#969DA8")
            accent = UiTheme.hex("#628FFF"); accentHover = UiTheme.hex("#7AA0FF"); accentPressed = UiTheme.hex("#4A79E8")
            accentSoft = UiTheme.hex("#26304A"); hero1 = UiTheme.hex("#4A7CF8"); hero2 = UiTheme.hex("#7C5CFF")
            paused1 = UiTheme.hex("#4B4F59"); paused2 = UiTheme.hex("#35383F")
            ok = UiTheme.hex("#3FBF7F"); warn = UiTheme.hex("#E8B341"); danger = UiTheme.hex("#E5484D")
            trackOff = UiTheme.hex("#3A3E48"); rowHover = UiTheme.hex("#22252C")
        }
        DispatchQueue.main.async { [weak self] in self?.changed?() }
    }

    public static func hex(_ s: String) -> NSColor {
        var v = s.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("#") { v.removeFirst() }
        var r: UInt64 = 0
        Scanner(string: v).scanHexInt64(&r)
        return NSColor(red: CGFloat((r >> 16) & 0xFF) / 255,
                       green: CGFloat((r >> 8) & 0xFF) / 255,
                       blue: CGFloat(r & 0xFF) / 255, alpha: 1)
    }

    /// Swift-совместимый локальный доступ к палитре (для SwiftUI).
    public static var current: UiTheme { shared }
}
