import Foundation
import AppKit
import CoreGraphics

/// Снимок всех элементов буфера обмена со всеми типами данных (картинки, RTF,
/// файлы, текст), чтобы конвертация выделения никогда не разрушала скриншоты
/// или форматированный буфер пользователя.
public struct PasteboardSnapshot {
    public let changeCount: Int
    public let items: [[(NSPasteboard.PasteboardType, Data)]]
}

/// Инжекция ввода: юникод-символы, Backspace, Enter, комбинации клавиш.
/// Все синтетические события создаются через выделенный приватный `CGEventSource`
/// (`.privateState`, `localEventsSuppressionInterval = 0`) и несут явные чистые
/// флаги `.maskNonCoalesced` — физически зажатые пользователем `Shift`, `Option`,
/// `Command` или `Control` никогда не протекают на синтетические нажатия.
public enum TextConverter {
    public static let selfMagic: Int64 = 0x05FA_5717
    public static let userField = CGEventField.eventSourceUserData

    public static var targetPid: pid_t = 0

    private static let privateSource: CGEventSource? = {
        let src = CGEventSource(stateID: .privateState)
        src?.localEventsSuppressionInterval = 0
        return src
    }()

    private static func makeSource() -> CGEventSource? {
        privateSource ?? CGEventSource(stateID: .privateState)
    }

    private static func post(_ event: CGEvent) {
        event.setIntegerValueField(userField, value: selfMagic)
        event.post(tap: .cghidEventTap)
    }

    public static func releaseModifiers() {}

    /// Посимвольная отправка текста через Unicode CGEvent (1 символ / суррогатная
    /// пара на событие, чистые флаги `.maskNonCoalesced`). Исключает обрезку длинных
    /// слов, гонку `interpretKeyEvents:` в Electron/Chromium и случайный `Cmd+A`
    /// на `virtualKey: 0`.
    public static func sendUnicode(_ text: String, interCharDelayUs: useconds_t = 1500) {
        guard !text.isEmpty else { return }
        let src = makeSource()
        let units = Array(text.utf16)
        var i = 0
        var sentAny = false
        while i < units.count {
            let u0 = units[i]
            if u0 == 0x000A || u0 == 0x000D {
                if sentAny && interCharDelayUs > 0 { usleep(interCharDelayUs) }
                sendEnter()
                sentAny = true
                i += 1
                continue
            }
            var chunk: [UniChar] = [u0]
            if u0 >= 0xD800 && u0 <= 0xDBFF && i + 1 < units.count {
                let u1 = units[i + 1]
                if u1 >= 0xDC00 && u1 <= 0xDFFF {
                    chunk.append(u1)
                    i += 1
                }
            }
            if sentAny && interCharDelayUs > 0 { usleep(interCharDelayUs) }
            if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
               let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                down.flags = .maskNonCoalesced
                up.flags = .maskNonCoalesced
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                post(down)
                post(up)
                sentAny = true
            }
            i += 1
        }
    }

    public static func sendBackspaces(_ n: Int, delayUs: useconds_t = 4000) {
        guard n > 0 else { return }
        let src = makeSource()
        for i in 0..<n {
            if i > 0 && delayUs > 0 { usleep(delayUs) }
            if let d = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(KeyCodeMap.backspace), keyDown: true),
               let u = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(KeyCodeMap.backspace), keyDown: false) {
                d.flags = .maskNonCoalesced
                u.flags = .maskNonCoalesced
                post(d)
                post(u)
            }
        }
    }

    public static func sendEnter(shift: Bool = false) {
        let src = makeSource()
        let flags: CGEventFlags = shift ? [.maskShift, .maskNonCoalesced] : [.maskNonCoalesced]
        if let d = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(KeyCodeMap.enter), keyDown: true),
           let u = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(KeyCodeMap.enter), keyDown: false) {
            d.flags = flags
            u.flags = flags
            post(d)
            post(u)
        }
    }

    /// Комбинация: код клавиши + модификаторы (биты HK.*).
    public static func sendCombo(keyCode: Int, mods: Int) {
        let src = makeSource()
        var flags: CGEventFlags = [.maskNonCoalesced]
        if mods & HK.CTRL != 0 { flags.insert(.maskControl) }
        if mods & HK.SHIFT != 0 { flags.insert(.maskShift) }
        if mods & HK.ALT != 0 { flags.insert(.maskAlternate) }
        if mods & HK.CMD != 0 { flags.insert(.maskCommand) }
        if let d = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: true),
           let u = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: false) {
            d.flags = flags
            u.flags = flags
            post(d)
            post(u)
        }
    }

    /// Символ, который печатает клавиша в указанной (или текущей) раскладке.
    public static func renderKeyChar(keyCode: Int, shift: Bool, layout: LayoutService.LayoutData? = nil) -> String {
        guard let data = layout ?? LayoutService.currentLayout(),
              let s = LayoutService.renderKey(data, KeyRec(keyCode, shift, false)) else { return "" }
        return s
    }

    // ---------------------------------------------------------------- буфер обмена (только main!)

    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let autoGeneratedType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")

    public static func clipboardChangeCountOnMain() -> Int {
        dispatchPrecondition(condition: .onQueue(.main))
        return NSPasteboard.general.changeCount
    }

    public static func getClipboardTextOnMain() -> String? {
        dispatchPrecondition(condition: .onQueue(.main))
        return NSPasteboard.general.string(forType: .string)
    }

    /// Полный снимок буфера обмена (включая картинки/скриншоты/файлы/RTF).
    public static func savePasteboardOnMain() -> PasteboardSnapshot {
        dispatchPrecondition(condition: .onQueue(.main))
        let pb = NSPasteboard.general
        var savedItems: [[(NSPasteboard.PasteboardType, Data)]] = []
        if let items = pb.pasteboardItems {
            for item in items {
                var pairs: [(NSPasteboard.PasteboardType, Data)] = []
                for t in item.types {
                    if let d = item.data(forType: t) {
                        pairs.append((t, d))
                    }
                }
                if !pairs.isEmpty { savedItems.append(pairs) }
            }
        }
        return PasteboardSnapshot(changeCount: pb.changeCount, items: savedItems)
    }

    /// Записывает временный текст с маркерами TransientType/AutoGeneratedType
    /// (менеджеры буфера обмена Raycast/Maccy/Paste не засоряют историю) и
    /// возвращает актуальный changeCount для безопасного восстановления.
    @discardableResult
    public static func setTransientClipboardTextOnMain(_ text: String) -> Int {
        dispatchPrecondition(condition: .onQueue(.main))
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: transientType)
        item.setData(Data(), forType: autoGeneratedType)
        pb.writeObjects([item])
        return pb.changeCount
    }

    /// Восстанавливает полный снимок буфера обмена, если за время ожидания
    /// пользователь сам не скопировал что-то новое.
    public static func restorePasteboardOnMain(_ snapshot: PasteboardSnapshot, expectedChangeCount: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        let pb = NSPasteboard.general
        guard pb.changeCount == expectedChangeCount else { return }
        pb.clearContents()
        guard !snapshot.items.isEmpty else { return }
        var restored: [NSPasteboardItem] = []
        for pairs in snapshot.items {
            let item = NSPasteboardItem()
            for (t, d) in pairs {
                item.setData(d, forType: t)
            }
            restored.append(item)
        }
        pb.writeObjects(restored)
    }
}
