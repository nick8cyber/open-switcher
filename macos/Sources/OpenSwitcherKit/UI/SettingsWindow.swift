import AppKit
import SwiftUI

/// Окно настроек (порт SettingsForm.cs): безрамочное окно, сайдбар + страницы,
/// градиентный статус-герой, карточки, футер «Сбросить / Сохранить».
public final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let engine: Engine
    private let uiModel: SettingsUiModel = SettingsUiModel()
    public var onClose: (() -> Void)?

    public init(engine: Engine) {
        self.engine = engine
        let m = uiModel
        let contentRect = NSRect(x: 0, y: 0, width: 880, height: 660)
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        let window = NSWindow(contentRect: contentRect, styleMask: style,
                              backing: .buffered, defer: false)
        window.title = "OpenSwitcher"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.center()
        super.init(window: window)
        window.delegate = self
        m.load(engine.s)
        let vc = NSHostingController(rootView: SettingsRoot(engine: engine, model: m))
        self.contentViewController = vc
        vc.view.wantsLayer = true
        engine.uiSettingsActive = true
    }

    public required init?(coder: NSCoder) { fatalError() }

    public func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        engine.uiSettingsActive = true
    }

    public func windowWillClose(_ notification: Notification) {
        engine.uiSettingsActive = false
        engine.sandboxFocused = false
        // окно закрывается — освобождаем ссылку в статус-айтеме через замыкание
        onClose?()

    }
}

// ---------------------------------------------------------------- SwiftUI

/// SwiftUI-обёртка палитры: NSColor -> Color на каждый доступ.
public struct ThemeColors {
    var bg: Color { Color(nsColor: UiTheme.shared.bg) }
    var sidebarBg: Color { Color(nsColor: UiTheme.shared.sidebarBg) }
    var card: Color { Color(nsColor: UiTheme.shared.card) }
    var cardBorder: Color { Color(nsColor: UiTheme.shared.cardBorder) }
    var input: Color { Color(nsColor: UiTheme.shared.input) }
    var inputBorder: Color { Color(nsColor: UiTheme.shared.inputBorder) }
    var chipBg: Color { Color(nsColor: UiTheme.shared.chipBg) }
    var text: Color { Color(nsColor: UiTheme.shared.text) }
    var dim: Color { Color(nsColor: UiTheme.shared.dim) }
    var accent: Color { Color(nsColor: UiTheme.shared.accent) }
    var accentHover: Color { Color(nsColor: UiTheme.shared.accentHover) }
    var accentPressed: Color { Color(nsColor: UiTheme.shared.accentPressed) }
    /// Заливка акцентных кнопок: в тёмной теме accent (#628FFF) даёт белый текст
    /// всего 3:1 — берём более тёмный accentPressed
    var buttonAccent: Color { UiTheme.shared.isLight ? accent : accentPressed }
    var accentSoft: Color { Color(nsColor: UiTheme.shared.accentSoft) }
    var hero1: Color { Color(nsColor: UiTheme.shared.hero1) }
    var hero2: Color { Color(nsColor: UiTheme.shared.hero2) }
    var paused1: Color { Color(nsColor: UiTheme.shared.paused1) }
    var paused2: Color { Color(nsColor: UiTheme.shared.paused2) }
    var ok: Color { Color(nsColor: UiTheme.shared.ok) }
    var warn: Color { Color(nsColor: UiTheme.shared.warn) }
    var danger: Color { Color(nsColor: UiTheme.shared.danger) }
    var trackOff: Color { Color(nsColor: UiTheme.shared.trackOff) }
    var rowHover: Color { Color(nsColor: UiTheme.shared.rowHover) }
}

public final class ThemeEnv: ObservableObject {
    public static let shared = ThemeEnv()
    public var t: ThemeColors { ThemeColors() }
    public func refresh() { objectWillChange.send() }
}

public struct SettingsRoot: View {
    let engine: Engine
    @ObservedObject private var theme = ThemeEnv.shared
    @State private var page = 0
    @ObservedObject var model: SettingsUiModel
    public init(engine: Engine, initialPage: Int = 0) {
        self.engine = engine
        _page = State(initialValue: initialPage)
        let m = SettingsUiModel()
        m.load(engine.s)
        _model = ObservedObject(wrappedValue: m)
    }
    public init(engine: Engine, model: SettingsUiModel, initialPage: Int = 0) {
        self.engine = engine
        _page = State(initialValue: initialPage)
        _model = ObservedObject(wrappedValue: model)
    }

    /// Единая точка применения настроек (футер и подтверждение закрытия).
    func saveSettings() {
        applySettingsFromModel(engine: engine, model: model)
    }

    public var body: some View {
        let t = theme.t
        VStack(spacing: 0) {
            TitleBar()
            HStack(spacing: 0) {
                Sidebar(page: $page)
                    .frame(width: 208)
                Rectangle().fill(t.cardBorder).frame(width: 1)
                VStack(spacing: 0) {
                    // герой вне скролла: статус всегда виден (раунд 5, дизайн-аудит)
                    StatusHero(engine: engine)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                    ScrollView {
                        VStack(spacing: 12) {
                            Group {
                                switch page {
                                case 0: MainPage(engine: engine, model: model)
                                case 1: KeysPage(engine: engine, model: model)
                                case 2: LookPage(engine: engine, model: model)
                                case 3: SystemPage(engine: engine, model: model)
                                default: ExclusionsPage(engine: engine, model: model)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 16)
                    }
                }
            }
            Rectangle().fill(t.cardBorder).frame(height: 1)
            Footer(engine: engine, model: model)
        }
        .background(t.bg)
        .frame(minWidth: 880, minHeight: 620)
        .onAppear { model.load(engine.s) }
    }
}

struct TitleBar: View {
    @ObservedObject private var theme = ThemeEnv.shared
    var body: some View {
        let t = theme.t
        HStack(spacing: 10) {
            AppIconView()
                .frame(width: 22, height: 22)
            Text("OpenSwitcher")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(t.text)
            Spacer()
        }
        .padding(.leading, 76)   // зона светофоров macOS (~70pt)
        .padding(.trailing, 16)
        .padding(.vertical, 12)
        .background(t.bg)
    }
}

struct AppIconView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSImageView {
        let iv = NSImageView()
        iv.image = StatusItemService.makeIcon()
        iv.imageScaling = .scaleProportionallyUpOrDown
        return iv
    }
    func updateNSView(_ nsView: NSImageView, context: Context) {}
}

struct Sidebar: View {
    @Binding var page: Int
    @ObservedObject private var theme = ThemeEnv.shared

    static let pages = ["Основное", "Горячие клавиши", "Внешний вид", "Система", "Исключения"]
    static let glyphs = ["fix", "keys", "look", "sys", "block"]

    var body: some View {
        let t = theme.t
        VStack(alignment: .leading, spacing: 2) {
            ForEach(0..<Self.pages.count, id: \.self) { i in
                SidebarRow(title: Self.pages[i], glyph: Self.glyphs[i], selected: page == i) {
                    page = i
                }
            }
            Spacer()
        }
        .padding(.top, 8)
        .padding(.horizontal, 8) // «плавающая» пилюля, как ItemRect в оригинале
        .background(t.sidebarBg)
    }
}

struct SidebarRow: View {
    let title: String
    let glyph: String
    let selected: Bool
    let action: () -> Void
    @ObservedObject private var theme = ThemeEnv.shared
    @State private var hover = false

    var body: some View {
        let t = theme.t
        Button(action: action) {
            HStack(spacing: 10) {
                GlyphView(name: glyph, selected: selected)
                    .frame(width: 18, height: 18)
                Text(title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(selected ? t.accentSoft : (hover ? t.rowHover : .clear)))
            .foregroundColor(selected ? t.text : t.dim)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Векторные пиктограммы (порт Glyphs.cs: fix/keys/look/block/sys).
struct GlyphView: NSViewRepresentable {
    let name: String
    var selected: Bool = false
    @ObservedObject private var theme = ThemeEnv.shared

    func makeNSView(context: Context) -> GlyphNsView {
        GlyphNsView()
    }
    func updateNSView(_ nsView: GlyphNsView, context: Context) {
        nsView.name = name
        nsView.color = selected ? UiTheme.shared.accent : UiTheme.shared.dim
        nsView.needsDisplay = true
    }

    final class GlyphNsView: NSView {
        var name = "fix"
        var color: NSColor = .controlAccentColor
        override func draw(_ dirtyRect: NSRect) {
            let cx = bounds.midX, cy = bounds.midY
            let rad = min(bounds.width, bounds.height) / 2 - 1
            guard rad > 0 else { return }
            let ctx = NSGraphicsContext.current?.cgContext
            ctx?.setStrokeColor(color.cgColor)
            ctx?.setFillColor(color.cgColor)
            ctx?.setLineWidth(1.4)
            ctx?.setLineCap(.round)
            switch name {
            case "fix":
                ctx?.strokeEllipse(in: CGRect(x: cx - rad, y: cy - rad, width: rad * 2, height: rad * 2))
                ctx?.strokePath(); ctx?.beginPath()
                ctx?.move(to: CGPoint(x: cx - rad, y: cy))
                ctx?.addLine(to: CGPoint(x: cx + rad, y: cy))
                ctx?.addLine(to: CGPoint(x: cx + rad - 4, y: cy + 4))
                ctx?.strokePath()
            case "keys":
                let body = CGRect(x: cx - rad, y: cy - rad + 2, width: rad * 2, height: rad * 2 - 4)
                let path = NSBezierPath(roundedRect: body, xRadius: 4, yRadius: 4)
                path.stroke()
                ctx?.move(to: CGPoint(x: cx - rad + 4, y: cy - rad + 6))
                ctx?.addLine(to: CGPoint(x: cx + rad - 4, y: cy - rad + 6))
                ctx?.strokePath()
            case "look":
                ctx?.strokeEllipse(in: CGRect(x: cx - rad, y: cy - rad, width: rad * 2, height: rad * 2))
                ctx?.fill(CGRect(x: cx - rad, y: cy, width: rad * 2, height: rad))
            case "block":
                ctx?.strokeEllipse(in: CGRect(x: cx - rad, y: cy - rad, width: rad * 2, height: rad * 2))
                let d = rad * 0.707
                ctx?.move(to: CGPoint(x: cx - d, y: cy - d))
                ctx?.addLine(to: CGPoint(x: cx + d, y: cy + d))
                ctx?.strokePath()
            case "sys":
                let r0 = rad - 4
                ctx?.strokeEllipse(in: CGRect(x: cx - r0, y: cy - r0, width: r0 * 2, height: r0 * 2))
                for a in 0..<8 {
                    let ang = Double(a) * .pi / 4
                    ctx?.move(to: CGPoint(x: cx + r0 * Foundation.cos(ang), y: cy + r0 * Foundation.sin(ang)))
                    ctx?.addLine(to: CGPoint(x: cx + rad * Foundation.cos(ang), y: cy + rad * Foundation.sin(ang)))
                }
                ctx?.strokePath()
            default: break
            }
        }
    }
}

struct StatusHero: View {
    let engine: Engine
    @ObservedObject private var theme = ThemeEnv.shared
    @State private var paused = false
    @State private var hover = false

    var body: some View {
        let t = theme.t
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.22))
                    .frame(width: 36, height: 36)
                Image(systemName: paused ? "pause.fill" : "arrow.left.arrow.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(paused ? "На паузе" : "Работает")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(.white)
                Text(paused ? "Автоисправление отключено" : "Автоисправление активно · Ru ⇄ En")
                    .font(.system(size: 10.5))
                    .foregroundColor(.white.opacity(0.85))
            }
            Spacer()
            // кнопка как в оригинале: «Приостановить» / «Возобновить»
            Text(paused ? "Возобновить" : "Приостановить")
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(hover ? 0.32 : 0.24)))
                .foregroundColor(.white)
                .contentShape(Rectangle())
                .onTapGesture {
                    paused.toggle()
                    engine.s.paused = paused
                    SettingsStore.save(engine.s)
                    engine.apply(engine.s)
                }
                .onHover { hover = $0 }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            LinearGradient(colors: paused ? [t.paused1, t.paused2] : [t.hero1, t.hero2],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        )
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08)))
        .cornerRadius(14)
        .onAppear { paused = engine.s.paused }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("os.paused"))) { _ in
            paused = engine.s.paused
        }
    }
}

struct PageCard<Content: View>: View {
    let content: Content
    @ObservedObject private var theme = ThemeEnv.shared

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        let t = theme.t
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 14).fill(t.card))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(t.cardBorder))
    }
}

struct PageHeader: View {
    let title: String
    let sub: String
    @ObservedObject private var theme = ThemeEnv.shared
    var body: some View {
        let t = theme.t
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 15.5, weight: .bold)).foregroundColor(t.text)
            Text(sub).font(.system(size: 10.5)).foregroundColor(t.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Row<Trailing: View>: View {
    let title: String
    let sub: String?
    @ViewBuilder var trailing: () -> Trailing
    @ObservedObject private var theme = ThemeEnv.shared

    init(title: String, sub: String?, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.sub = sub
        self.trailing = trailing
    }

    var body: some View {
        let t = theme.t
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5)).foregroundColor(t.text)
                if let s = sub {
                    Text(s).font(.system(size: 10.5)).foregroundColor(t.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }
}

/// Тумблер (порт ToggleSwitch).
struct ToggleButton: View {
    let on: Bool
    var label: String = ""
    var danger: Bool = false
    var labelColor: Color? = nil
    var disabled: Bool = false
    let action: () -> Void
    @ObservedObject private var theme = ThemeEnv.shared
    @State private var hover = false

    var body: some View {
        let t = theme.t
        HStack(spacing: 8) {
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(labelColor ?? (danger ? t.danger : (on ? t.accent : t.dim)))
            }
            ZStack {
                Capsule().fill(on ? t.accent : t.trackOff)
                    .frame(width: 40, height: 22)
                Circle().fill(.white)
                    .frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                    .offset(x: on ? 9 : -9)
                    .animation(.easeInOut(duration: 0.15), value: on)
            }
        }
        .opacity(disabled ? 0.4 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if !disabled { action() } }
        .onHover { hover = $0 }
    }
}

/// Сегментированный выбор (порт ChoiceSeg).
struct ChoiceSeg: View {
    let items: [String]
    @Binding var index: Int
    @ObservedObject private var theme = ThemeEnv.shared

    var body: some View {
        let t = theme.t
        HStack(spacing: 2) {
            ForEach(0..<items.count, id: \.self) { i in
                Text(items[i])
                    .font(.system(size: 11, weight: index == i ? .semibold : .regular))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(index == i ? t.accentSoft : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .stroke(index == i ? t.accent : .clear))
                    .foregroundColor(index == i ? t.text : t.dim)
                    .onTapGesture { index = i }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9).fill(t.input))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(t.inputBorder))
    }
}

/// Кнопка (порт RoundedButton).
struct AccentButton: View {
    let title: String
    var accent: Bool
    let action: () -> Void
    @ObservedObject private var theme = ThemeEnv.shared
    @State private var hover = false

    var body: some View {
        let t = theme.t
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(
                Group {
                    if accent {
                        // градиент Accent->AccentPressed, как RoundedButton в оригинале
                        LinearGradient(colors: [hover ? t.accentHover : t.buttonAccent, t.accentPressed],
                                       startPoint: .top, endPoint: .bottom)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(hover ? t.rowHover : t.chipBg)
                    }
                }
            )
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(accent ? Color.clear : t.cardBorder))
            .foregroundColor(accent ? .white : t.text)
            .onTapGesture { action() }
            .onHover { hover = $0 }
    }
}

/// Поле захвата хоткея (порт HotkeyBox): клик — захват, Backspace — очистить, Esc — отмена.
struct HotkeyBox: NSViewRepresentable {
    @Binding var vk: Int
    @Binding var mods: Int

    func makeNSView(context: Context) -> HotkeyNsView {
        let v = HotkeyNsView()
        v.onSet = { vk, mods in
            self.vk = vk; self.mods = mods
        }
        return v
    }

    func updateNSView(_ nsView: HotkeyNsView, context: Context) {
        nsView.displayVk = vk
        nsView.displayMods = mods
        nsView.display()
    }

    final class HotkeyNsView: NSView {
        var onSet: ((Int, Int) -> Void)?
        var displayVk = 0
        var displayMods = 0
        var capturing = false
        var errorText: String? = nil

        override func draw(_ dirtyRect: NSRect) {
            let t = UiTheme.shared
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
            (capturing ? t.accentSoft : t.input).setFill()
            path.fill()
            (capturing ? t.accent : t.inputBorder).setStroke()
            path.lineWidth = 1
            path.stroke()

            if let err = errorText {
                let font = NSFont.systemFont(ofSize: 11, weight: .medium)
                let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: t.danger]
                let size = (err as NSString).size(withAttributes: attr)
                (err as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2,
                                                   y: bounds.midY - size.height / 2),
                                        withAttributes: attr)
                return
            }
            let text: String
            if capturing {
                text = "Нажмите сочетание…"
            } else if displayVk == 0 {
                text = "Не задано"
            } else {
                var parts: [String] = []
                if displayMods & HK.CTRL != 0 { parts.append("Ctrl") }
                if displayMods & HK.ALT != 0 { parts.append("Alt") }
                if displayMods & HK.CMD != 0 { parts.append("Cmd") }
                if displayMods & HK.SHIFT != 0 { parts.append("Shift") }
                parts.append(KeyCodeMap.name(of: displayVk))
                text = parts.joined(separator: " + ")
            }
            let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            let color = capturing ? t.accent : (displayVk == 0 ? t.dim : t.text)
            let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = (text as NSString).size(withAttributes: attr)
            (text as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2,
                                                y: bounds.midY - size.height / 2),
                                     withAttributes: attr)
        }

        override func mouseDown(with event: NSEvent) {
            capturing = true
            errorText = nil
            needsDisplay = true
            window?.makeFirstResponder(self)
        }

        override var acceptsFirstResponder: Bool { true }

        // Shift/Caps приходят как flagsChanged, а не keyDown — но именно они
        // дефолтные тап-клавиши раскладки, их надо уметь захватывать
        override func flagsChanged(with event: NSEvent) {
            guard capturing else { return }
            let code = Int(event.keyCode)
            guard code == KeyCodeMap.leftShift || code == KeyCodeMap.rightShift
                || code == KeyCodeMap.capsLock else { return }
            let m = event.modifierFlags
            let otherMods = m.contains(.control) || m.contains(.option) || m.contains(.command)
            guard !otherMods else { return }
            onSet?(code, 0)
            capturing = false
            errorText = nil
            needsDisplay = true
        }

        override func keyDown(with event: NSEvent) {
            guard capturing else { return }
            let code = Int(event.keyCode)
            errorText = nil
            if event.keyCode == 53 { // Esc — отмена
                capturing = false
                needsDisplay = true
                return
            }
            if event.keyCode == KeyCodeMap.backspace {
                let m = event.modifierFlags
                if m.isEmpty { // голый Backspace очищает, как в оригинале
                    onSet?(0, 0)
                    capturing = false
                    needsDisplay = true
                }
                return
            }
            if KeyCodeMap.isModifier(code) { return }
            var mods = 0
            if event.modifierFlags.contains(.control) { mods |= HK.CTRL }
            if event.modifierFlags.contains(.option) { mods |= HK.ALT }
            if event.modifierFlags.contains(.command) { mods |= HK.CMD }
            if event.modifierFlags.contains(.shift) { mods |= HK.SHIFT }
            // буквам/цифрам/пробелу нужен Ctrl/Alt/Cmd (Shift не считается), как в оригинале
            let needsMod = KeyCodeMap.letters[code] != nil || KeyCodeMap.digits.contains(code)
                || code == KeyCodeMap.space
            if needsMod && (mods & (HK.CTRL | HK.ALT | HK.CMD)) == 0 {
                NSSound.beep()
                errorText = "Нужен Ctrl или Alt" // беззвучный для глаз beep недостаточен
                needsDisplay = true
                return
            }
            errorText = nil
            onSet?(code, mods)
            capturing = false
            needsDisplay = true
        }

        override func resignFirstResponder() -> Bool {
            capturing = false
            needsDisplay = true
            return true
        }
    }
}

struct DarkTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var multiline: Bool = false
    var onFocused: ((Bool) -> Void)?

    func makeNSView(context: Context) -> NSView {
        if multiline {
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = false
            scroll.borderType = .noBorder
            let tv = NSTextView()
            tv.isRichText = false
            tv.font = .systemFont(ofSize: 12)
            tv.isVerticallyResizable = true
            tv.autoresizingMask = [.width]
            tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            tv.textContainer?.widthTracksTextView = true
            tv.delegate = context.coordinator
            tv.string = text
            scroll.documentView = tv
            applyTheme(scroll: scroll, tv: tv)
            return scroll
        }
        let tf = NSTextField()
        tf.placeholderString = placeholder
        tf.font = .systemFont(ofSize: 12)
        tf.usesSingleLineMode = true
        tf.delegate = context.coordinator
        applyTheme(tf: tf)
        return tf
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let tf = nsView as? NSTextField {
            if tf.stringValue != text { tf.stringValue = text }
            applyTheme(tf: tf)
        } else if let scroll = nsView as? NSScrollView, let tv = scroll.documentView as? NSTextView {
            if tv.string != text { tv.string = text }
            applyTheme(scroll: scroll, tv: tv)
        }
    }

    /// Тема применяется явно — поле не зависит от системного оформления.
    private func applyTheme(tf: NSTextField? = nil, scroll: NSScrollView? = nil, tv: NSTextView? = nil) {
        let t = UiTheme.shared
        let appearance = NSAppearance(named: UiTheme.shared.isLight ? .aqua : .darkAqua)
        if let tf = tf {
            tf.drawsBackground = true
            tf.backgroundColor = t.input
            tf.textColor = t.text
            tf.isBordered = false
            tf.focusRingType = .none
            tf.appearance = appearance
            tf.wantsLayer = true
            tf.layer?.cornerRadius = 7
            tf.layer?.borderWidth = 1
            tf.layer?.borderColor = t.inputBorder.cgColor
        }
        if let scroll = scroll {
            // NSScrollView по умолчанию рисует свой (системный, белый) фон — глушим,
            // фон несёт сам NSTextView; бордер на слое scroll
            scroll.drawsBackground = false
            scroll.wantsLayer = true
            scroll.layer?.cornerRadius = 7
            scroll.layer?.borderWidth = 1
            scroll.layer?.borderColor = t.inputBorder.cgColor
            scroll.layer?.backgroundColor = t.input.cgColor
            if let tv = tv {
                tv.drawsBackground = true
                tv.backgroundColor = t.input
                tv.textColor = t.text
                tv.insertionPointColor = t.accent
                tv.appearance = appearance
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate, NSTextViewDelegate {
        var parent: DarkTextField
        init(_ p: DarkTextField) { parent = p }
        func controlTextDidChange(_ obj: Notification) {
            if let tf = obj.object as? NSTextField {
                parent.text = tf.stringValue
            } else if let tv = obj.object as? NSTextView {
                parent.text = tv.string
            }
        }
        func controlTextDidBeginEditing(_ obj: Notification) {
            parent.onFocused?(true)
        }
        func controlTextDidEndEditing(_ obj: Notification) {
            parent.onFocused?(false)
        }
        func textDidChange(_ obj: Notification) {
            if let tv = obj.object as? NSTextView { parent.text = tv.string }
        }
    }
}

/// Модель настроек для UI (сохранение по кнопке, как в оригинале).
public final class SettingsUiModel: ObservableObject {
    @Published var fixOnEnter = true
    @Published var autoConvert = true
    @Published var lockAuto = true
    @Published var sensIndex = 1
    @Published var sandbox = ""

    @Published var hkRuVk = 0; @Published var hkRuMods = 0
    @Published var hkEnVk = 0; @Published var hkEnMods = 0
    @Published var hkWordVk = 0; @Published var hkWordMods = 0
    @Published var hkSelVk = 0; @Published var hkSelMods = 0
    @Published var hkUndoVk = 0; @Published var hkUndoMods = 0
    @Published var hkAutoVk = 0; @Published var hkAutoMods = 0
    @Published var doubleShift = true

    @Published var themeIndex = 0
    @Published var showPopup = true
    @Published var restoreClipboard = true
    @Published var devLog = false
    @Published var startWithSystem = false
    @Published var exclusions = ""

    /// Базлайн для dirty-детекта (закрытие окна с несохранёнными правками).
    private var baseline: [String: String] = [:]

    func snapshotFields() -> [String: String] {
        return ["fixOnEnter": "\(fixOnEnter)", "autoConvert": "\(autoConvert)",
                "lockAuto": "\(lockAuto)", "sens": "\(sensIndex)", "sandbox": sandbox,
                "ru": "\(hkRuVk):\(hkRuMods)", "en": "\(hkEnVk):\(hkEnMods)",
                "word": "\(hkWordVk):\(hkWordMods)", "sel": "\(hkSelVk):\(hkSelMods)",
                "undo": "\(hkUndoVk):\(hkUndoMods)", "auto": "\(hkAutoVk):\(hkAutoMods)",
                "ds": "\(doubleShift)", "theme": "\(themeIndex)", "popup": "\(showPopup)",
                "clip": "\(restoreClipboard)", "devlog": "\(devLog)",
                "autostart": "\(startWithSystem)",
                "excl": exclusions]
    }

    public var isDirty: Bool { !baseline.isEmpty && snapshotFields() != baseline }

    public func refreshBaseline() { baseline = snapshotFields() }

    public func load(_ s: Settings) {
        fixOnEnter = s.fixOnEnter
        autoConvert = s.autoConvertOnWordEnd
        lockAuto = s.lockAutoAfterManualSwitch
        sensIndex = s.sensitivity <= 0.85 ? 0 : (s.sensitivity >= 1.25 ? 2 : 1)
        hkRuVk = s.hotRuVk; hkRuMods = s.hotRuMods
        hkEnVk = s.hotEnVk; hkEnMods = s.hotEnMods
        hkWordVk = s.hotFixWordVk; hkWordMods = s.hotFixWordMods
        hkSelVk = s.hotFixSelVk; hkSelMods = s.hotFixSelMods
        hkUndoVk = s.hotUndoVk; hkUndoMods = s.hotUndoMods
        hkAutoVk = s.hotAutoToggleVk; hkAutoMods = s.hotAutoToggleMods
        doubleShift = s.doubleShiftSwitch
        themeIndex = s.themeMode
        showPopup = s.showPopup
        restoreClipboard = s.restoreClipboard
        devLog = s.devLog
        startWithSystem = s.startWithSystem
        exclusions = s.exclusions
        refreshBaseline()
    }

    public func write(_ s: Settings) {
        s.fixOnEnter = fixOnEnter
        s.autoConvertOnWordEnd = autoConvert
        s.lockAutoAfterManualSwitch = lockAuto
        s.sensitivity = sensIndex == 0 ? 0.7 : (sensIndex == 2 ? 1.5 : 1.0)
        s.hotRuVk = hkRuVk; s.hotRuMods = hkRuMods
        s.hotEnVk = hkEnVk; s.hotEnMods = hkEnMods
        s.hotFixWordVk = hkWordVk; s.hotFixWordMods = hkWordMods
        s.hotFixSelVk = hkSelVk; s.hotFixSelMods = hkSelMods
        s.hotUndoVk = hkUndoVk; s.hotUndoMods = hkUndoMods
        s.hotAutoToggleVk = hkAutoVk; s.hotAutoToggleMods = hkAutoMods
        s.doubleShiftSwitch = doubleShift
        s.themeMode = themeIndex
        s.showPopup = showPopup
        s.restoreClipboard = restoreClipboard
        s.devLog = devLog
        s.startWithSystem = startWithSystem
        s.exclusions = exclusions
            .replacingOccurrences(of: "\n", with: ",")  // ini однострочный
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Атомарное применение настроек, как Apply в C#: копия + подмена ссылки —
/// тап между полями не увидит полуобновлённый хоткей.
func applySettingsFromModel(engine: Engine, model: SettingsUiModel) {
    let wasEnabled = Autostart.isEnabled()
    let snapshot = Settings()
    snapshot.paused = engine.s.paused // пауза не из UI-модели
    model.write(snapshot)
    SettingsStore.save(snapshot)
    if snapshot.startWithSystem != wasEnabled {
        Autostart.setEnabled(snapshot.startWithSystem)
    }
    engine.apply(snapshot)
    model.refreshBaseline()
}

// ---------------------------------------------------------------- страницы

struct MainPage: View {
    let engine: Engine
    @ObservedObject var model: SettingsUiModel
    @ObservedObject private var theme = ThemeEnv.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "Основное", sub: "Автоисправление неверной раскладки при вводе")
            PageCard {
                Row(title: "Живое автоисправление",
                    sub: "Слово переворачивается прямо при наборе, не дожидаясь пробела") {
                    ToggleButton(on: model.autoConvert) { model.autoConvert.toggle() }
                }
                DividerW()
                Row(title: "Исправлять слово перед Enter",
                    sub: "Enter перехватывается, слово правится до отправки") {
                    ToggleButton(on: model.fixOnEnter) { model.fixOnEnter.toggle() }
                }
                DividerW()
                Row(title: "Не трогать после ручного выбора языка",
                    sub: "Автодетект молчит до смены окна или приложения") {
                    ToggleButton(on: model.lockAuto) { model.lockAuto.toggle() }
                }
                DividerW()
                Row(title: "Как часто вмешиваться", sub: nil) {
                    ChoiceSeg(items: ["Низкая", "Средняя", "Высокая"], index: $model.sensIndex)
                }
            }
            PageCard {
                Row(title: "Попробуйте",
                    sub: "Напечатайте ghbdtn и пробел — исправится сразу")
                DarkTextField(text: $model.sandbox,
                              onFocused: { engine.sandboxFocused = $0 })
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .stroke(theme.t.inputBorder))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
    }
}

struct KeysPage: View {
    let engine: Engine
    @ObservedObject var model: SettingsUiModel
    @ObservedObject private var theme = ThemeEnv.shared

    /// Тап-переключение висит на Shift'ах? (тогда двойной Shift отключён, v3 §10)
    private var tapsOnShifts: Bool {
        let shifts: Set<Int> = [0x38, 0x3C]
        return (model.hkRuMods == 0 && shifts.contains(model.hkRuVk))
            || (model.hkEnMods == 0 && shifts.contains(model.hkEnVk))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "Горячие клавиши",
                       sub: "Кликните по полю и нажмите сочетание; Backspace — очистить")
            PageCard {
                Row(title: "Русская раскладка",
                    sub: "Тап Caps Lock / левого Shift / F9 — или сочетание с Ctrl") {
                    HotkeyBox(vk: $model.hkRuVk, mods: $model.hkRuMods).frame(width: 190, height: 26)
                }
                DividerW()
                Row(title: "Английская раскладка",
                    sub: "Тап правого Shift или другая своя клавиша") {
                    HotkeyBox(vk: $model.hkEnVk, mods: $model.hkEnMods).frame(width: 190, height: 26)
                }
                DividerW()
                Row(title: "Исправить последнее слово",
                    sub: "Сработает даже после пробела или Enter") {
                    HotkeyBox(vk: $model.hkWordVk, mods: $model.hkWordMods).frame(width: 190, height: 26)
                }
                DividerW()
                Row(title: "Исправить выделенный текст",
                    sub: "Конвертирует выделение и переключает раскладку") {
                    HotkeyBox(vk: $model.hkSelVk, mods: $model.hkSelMods).frame(width: 190, height: 26)
                }
                DividerW()
                Row(title: "Двойной Shift — сменить раскладку",
                    sub: tapsOnShifts
                        ? "Недоступно: переключение висит на тапах Shift'ов"
                        : "Двойной тап любого Shift переключает на другую") {
                    ToggleButton(on: model.doubleShift, disabled: tapsOnShifts) { model.doubleShift.toggle() }
                }
                DividerW()
                Row(title: "Отменить последнюю автозамену",
                    sub: "Вернуть слово и раскладку, которые были до автозамены") {
                    HotkeyBox(vk: $model.hkUndoVk, mods: $model.hkUndoMods).frame(width: 190, height: 26)
                }
                DividerW()
                Row(title: "Пауза автоперевода",
                    sub: "Глобальный тумблер; по умолчанию не назначена") {
                    HotkeyBox(vk: $model.hkAutoVk, mods: $model.hkAutoMods).frame(width: 190, height: 26)
                }
            }
        }
    }
}

struct LookPage: View {
    let engine: Engine
    @ObservedObject var model: SettingsUiModel
    @ObservedObject private var theme = ThemeEnv.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "Внешний вид", sub: "Тема и уведомления")
            PageCard {
                Row(title: "Тема оформления", sub: nil) {
                    ChoiceSeg(items: ["Системная", "Светлая", "Тёмная"], index: $model.themeIndex)
                        .onChange(of: model.themeIndex) { newValue in
                            // палитра меняется сразу (как в оригинале: SelectedChanged -> ApplyMode)
                            UiTheme.shared.applyMode(newValue)
                            theme.objectWillChange.send()
                        }
                }
                DividerW()
                Row(title: "Показывать подсказку при исправлении",
                    sub: "Плашка «ghbdtn → привет» возле курсора") {
                    ToggleButton(on: model.showPopup) { model.showPopup.toggle() }
                }
            }
        }
    }
}

struct SystemPage: View {
    let engine: Engine
    @ObservedObject var model: SettingsUiModel
    @State private var counts: (Int, Int) = (0, 0)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "Система", sub: "Буфер обмена, запуск и память")
            PageCard {
                Row(title: "Восстанавливать буфер обмена",
                    sub: "Вернуть прежнее содержимое после конвертации выделения") {
                    ToggleButton(on: model.restoreClipboard) { model.restoreClipboard.toggle() }
                }
                DividerW()
                Row(title: "Режим разработчика",
                    sub: "Вести журнал решений в файл (для отладки)") {
                    ToggleButton(on: model.devLog) { model.devLog.toggle() }
                }
                DividerW()
                Row(title: "Запускать при входе в macOS", sub: nil) {
                    ToggleButton(on: model.startWithSystem) { model.startWithSystem.toggle() }
                }
                DividerW()
                Row(title: "Забыть изученные слова",
                    sub: "Очищает списки принятых и отменённых слов (сейчас: \(counts.1) принятых, \(counts.0) отменённых)") {
                    HStack(spacing: 8) {
                        AccentButton(title: "Показать", accent: false) {
                            Engine.openInEditor(SettingsStore.dir + "/accepted.txt")
                            Engine.openInEditor(SettingsStore.dir + "/learned.txt")
                        }
                        AccentButton(title: "Очистить", accent: false) {
                            engine.forgetAllWords()
                            counts = engine.learnedCounts
                        }
                    }
                }
                .onAppear { counts = engine.learnedCounts }
            }
        }
    }
}

struct ExclusionsPage: View {
    let engine: Engine
    @ObservedObject var model: SettingsUiModel
    @ObservedObject private var theme = ThemeEnv.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "Исключения", sub: "Программы, где исправление выключено")
            PageCard {
                Row(title: "Не исправлять в",
                    sub: "Имена приложений через запятую: Terminal, iTerm2. Сейчас активно: \(engine.currentAppName)")
                DarkTextField(text: $model.exclusions, multiline: true)
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .stroke(theme.t.inputBorder))
                    .frame(height: 64)
                    .padding(.horizontal, 16)
                AccentButton(title: "Добавить текущее приложение", accent: false) {
                    let name = engine.currentAppName
                    guard !name.isEmpty else { return }
                    let parts = model.exclusions
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    guard !parts.contains(name) else { return }
                    model.exclusions = (parts + [name]).joined(separator: ", ")
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
    }
}

struct DividerW: View {
    @ObservedObject private var theme = ThemeEnv.shared
    var body: some View {
        Rectangle().fill(theme.t.cardBorder).frame(height: 1).padding(.horizontal, 16)
    }
}

struct Footer: View {
    let engine: Engine
    @ObservedObject var model: SettingsUiModel
    @ObservedObject private var theme = ThemeEnv.shared

    var body: some View {
        let t = theme.t
        HStack(spacing: 10) {
            Text("OpenSwitcher 1.1 · Ru ⇄ En")
                .font(.system(size: 10))
                .foregroundColor(t.dim)
            Spacer()
            AccentButton(title: "Сбросить", accent: false) {
                model.load(Settings())
            }
            AccentButton(title: "Сохранить", accent: true) {
                applySettingsFromModel(engine: engine, model: model)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(t.bg)
    }
}
