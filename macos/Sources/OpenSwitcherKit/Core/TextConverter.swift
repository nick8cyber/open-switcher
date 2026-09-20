import Foundation
import AppKit
import CoreGraphics

/// Инжекция ввода (порт TextConverter.cs): юникод-символы, Backspace, комбинации
/// клавиш. На macOS всё через CGEvent, posted в .cghidEventTap.
/// Собственную инжекцию помечаем магикой в поле 87 (eventSourceUserData) и
/// глотаем в тапе — аналог LLMHF_INJECTED.
public enum TextConverter {
    static let selfMagic: Int64 = 0x05FA_5717
    static let userField = CGEventField(rawValue: 42)! // kCGEventSourceUserData (CGEventTypes.h)

    /// Индекс GLM: помечаем и нажатия и отпускания.
    static var selfInjectDepth = 0

    /// PID переднего приложения: инжекция адресуется ему (CGEventPostToPid,
    /// спека v3 §16) — смена окна в момент доставки не уводит текст в чужое окно.
    public static var targetPid: pid_t = 0

    private static func post(_ event: CGEvent) {
        event.setIntegerValueField(userField, value: selfMagic)
        if targetPid > 0 {
            event.postToPid(targetPid)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }

    /// Отпустить все модификаторы физически не нужно — CGEvent-комбо несут свои флаги.
    public static func releaseModifiers() {}

    /// Ввести текст «юникодом» (аналог KEYEVENTF_UNICODE).
    public static func sendUnicode(_ text: String) {
        let chars = Array(text.unicodeScalars)
        var i = 0
        while i < chars.count {
            let chunk = String(String.UnicodeScalarView(chars[i..<min(i + 60, chars.count)]))
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: chunk.utf16.count,
                                           unicodeString: chunk.utf16.map { $0 as UniChar })
            if let d = down { post(d) }
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: chunk.utf16.count,
                                         unicodeString: chunk.utf16.map { $0 as UniChar })
            if let u = up { post(u) }
            i += 60
        }
    }

    public static func sendBackspaces(_ n: Int) {
        guard n > 0 else { return }
        for _ in 0..<n {
            let d = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(KeyCodeMap.backspace), keyDown: true)
            let u = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(KeyCodeMap.backspace), keyDown: false)
            if let d = d { post(d) }
            if let u = u { post(u) }
        }
    }

    public static func sendEnter() {
        let d = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(KeyCodeMap.enter), keyDown: true)
        let u = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(KeyCodeMap.enter), keyDown: false)
        if let d = d { post(d) }
        if let u = u { post(u) }
    }

    /// Комбинация: код клавиши + модификаторы (биты HK.*).
    public static func sendCombo(keyCode: Int, mods: Int) {
        var flags: CGEventFlags = []
        if mods & HK.CTRL != 0 { flags.insert(.maskControl) }
        if mods & HK.SHIFT != 0 { flags.insert(.maskShift) }
        if mods & HK.ALT != 0 { flags.insert(.maskAlternate) }
        if mods & HK.CMD != 0 { flags.insert(.maskCommand) }
        let d = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true)
        d?.flags = flags
        let u = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: false)
        u?.flags = flags
        if let d = d { post(d) }
        if let u = u { post(u) }
    }

    /// Символ, который печатает клавиша в текущей раскладке (для досылки разделителей).
    public static func renderKeyChar(keyCode: Int, shift: Bool) -> String {
        guard let data = LayoutService.currentLayout() else { return "" }
        let s = LayoutService.render(data, [KeyRec(keyCode, shift, false)])
        return s.isEmpty || s == "?" ? "" : s
    }

    // ---------------------------------------------------------------- буфер обмена

    public static func clipboardChangeCount() -> Int {
        NSPasteboard.general.changeCount
    }

    public static func getClipboardTextOnce() -> String? {
        let pb = NSPasteboard.general
        guard let types = pb.types, types.contains(.string) else { return nil }
        return pb.string(forType: .string)
    }

    public static func setClipboardText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
