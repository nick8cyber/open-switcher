import Foundation
import Carbon
import Carbon.HIToolbox
import CoreServices

/// Вариант прочтения набранного слова в одной из установленных раскладок (порт LayoutCandidate).
public final class LayoutCandidate {
    public var layoutID: String
    public var source: TISInputSource
    public var text: String
    public var lang: Int      // 0 ru / 1 en / -1
    public var score: Double
    public var name: String

    init(layoutID: String, source: TISInputSource, text: String, lang: Int, score: Double, name: String) {
        self.layoutID = layoutID
        self.source = source; self.text = text; self.lang = lang
        self.score = score; self.name = name
    }
}

/// Рендер key-буфера в произвольной раскладке (UCKeyTranslate вместо ToUnicodeEx),
/// список раскладок (TIS), переключение (TISSelectInputSource).
public enum LayoutService {
    public struct LayoutData {
        public var source: TISInputSource
        public var id: String
        public var layoutData: CFData   // держит байты живыми
        public var layout: UnsafePointer<UCKeyboardLayout> { UnsafeRawPointer(CFDataGetBytePtr(layoutData)!).assumingMemoryBound(to: UCKeyboardLayout.self) }
    }

    static var cache: [LayoutData] = []
    static var cacheAt: TimeInterval = 0
    static let cacheLock = NSLock()
    static let cacheTTL: TimeInterval = 30
    /// Фактическая текущая раскладка системы по последнему опросу `TISCopyCurrentKeyboardInputSource()` на main.
    /// НЕ перезаписывается искусственно в `switchTo` — благодаря этому `Engine` точно видит окно лага
    /// применения раскладки и переводит нажатые в просвете клавиши без потери букв.
    static var cachedCurrent: LayoutData?

    /// Единственная точка TIS-вызовов чтения состояния (macOS 15 требует main-очередь).
    public static func refreshOnMain() {
        dispatchPrecondition(condition: .onQueue(.main))
        cacheLock.lock()
        let empty = cache.isEmpty
        let stale = Date().timeIntervalSinceReferenceDate - cacheAt >= cacheTTL
        cacheLock.unlock()
        if empty || stale {
            _ = rebuildLayoutsOnMain()
        }
        guard let cur = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let idPtr = TISGetInputSourceProperty(cur, kTISPropertyInputSourceID) else { return }
        let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
        cacheLock.lock()
        var match = cache.first(where: { $0.id == id })
        cacheLock.unlock()
        if match == nil {
            let rebuilt = rebuildLayoutsOnMain()
            match = rebuilt.first(where: { $0.id == id })
        }
        cacheLock.lock()
        cachedCurrent = match
        cacheLock.unlock()
    }

    /// Все включённые раскладки с юникод-данными (кэш 30 с).
    public static func getLayouts() -> [LayoutData] {
        cacheLock.lock()
        let now = Date().timeIntervalSinceReferenceDate
        if !cache.isEmpty, now - cacheAt < cacheTTL {
            let snap = cache
            cacheLock.unlock()
            return snap
        }
        let stale = cache
        cacheLock.unlock()

        guard Thread.isMainThread else {
            DispatchQueue.main.async { refreshOnMain() }
            return stale
        }
        return rebuildLayoutsOnMain()
    }

    /// Перечисление TISCreateInputSourceList — только с main (фильтрует CJK IME / InputMode).
    private static func rebuildLayoutsOnMain() -> [LayoutData] {
        dispatchPrecondition(condition: .onQueue(.main))
        var list: [LayoutData] = []
        let filter = [kTISPropertyInputSourceIsEnableCapable as String: true] as CFDictionary
        if let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] {
            for src in sources {
                // P2-4: игнорируем IME-режимы ввода (kTISTypeKeyboardInputMode — японский/китайский/корейский),
                // оставляем только клавиатурные раскладки (kTISTypeKeyboardLayout).
                if let typePtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceType) {
                    let stype = Unmanaged<CFString>.fromOpaque(typePtr).takeUnretainedValue() as String
                    if stype == (kTISTypeKeyboardInputMode as String) { continue }
                }
                guard let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { continue }
                let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue()
                guard let idPtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { continue }
                let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
                if list.contains(where: { $0.id == id }) { continue }
                list.append(LayoutData(source: src, id: id, layoutData: data))
            }
        }
        cacheLock.lock()
        let prevID = cachedCurrent?.id
        cache = list
        cacheAt = Date().timeIntervalSinceReferenceDate
        cachedCurrent = prevID.flatMap { id in list.first(where: { $0.id == id }) }
        cacheLock.unlock()
        return list
    }

    /// Находится ли буква 'ё' на клавише 0x2A ('\') в стандартной русской раскладке Apple (P1-2).
    public static func usesBackslashForYo(_ data: LayoutData? = nil) -> Bool {
        let list: [LayoutData]
        if let d = data {
            list = [d]
        } else {
            cacheLock.lock()
            list = cache
            cacheLock.unlock()
        }
        for l in list {
            if l.id == "com.apple.keylayout.Russian" { return true }
            if let ch = renderKey(l, KeyRec(KeyCodeMap.backslash, false, false))?.lowercased(), ch == "ё" {
                return true
            }
        }
        return false
    }

    /// Текст, который дала бы эта раскладка при тех же нажатиях.
    public static func render(_ data: LayoutData, _ keys: [KeyRec]) -> String {
        var out = ""
        for rec in keys { out += renderKey(data, rec) ?? "?" }
        return out
    }

    /// Символ одной клавиши; nil — раскладка его не дала.
    public static func renderKey(_ data: LayoutData, _ rec: KeyRec) -> String? {
        var deadState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 8)
        var count = 0
        var mods: UInt32 = 0
        if rec.shift { mods |= 1 << 1 }
        if rec.caps { mods |= 1 << 2 }
        let kr = UCKeyTranslate(data.layout, UInt16(rec.code),
                                UInt16(kUCKeyActionDown),
                                mods, UInt32(LMGetKbdType()),
                                OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
                                &deadState, 8, &count, &chars)
        guard kr == noErr && count > 0 else { return nil }
        var s = String(utf16CodeUnits: chars, count: Int(count))
        // P1-2: RussianWin на Shift+0x32 возвращает латинскую Ë (U+00CB) вместо кириллической Ё (U+0401)
        if data.id.lowercased().contains("russian") {
            if s == "\u{00CB}" { s = "Ё" }
            else if s == "\u{00EB}" { s = "ё" }
        }
        return s
    }

    private static let nonRussianCyrillic = CharacterSet(charactersIn: "іїєґўІЇЄҐЎ")

    private static func isOtherCyrillicLayout(_ id: String, rendered: String) -> Bool {
        let lid = id.lowercased()
        if lid.contains("ukrainian") || lid.contains("belarus") || lid.contains("belorussian") ||
            lid.contains("kazakh") || lid.contains("serbian") || lid.contains("bulgarian") {
            return true
        }
        return rendered.unicodeScalars.contains { nonRussianCyrillic.contains($0) }
    }

    public static func layoutName(_ text: String) -> String {
        let lang = LanguageTables.langOf(text)
        if lang == 0 { return "РУС" }
        if lang == 1 { return "ENG" }
        return "???"
    }

    /// Прочитать буфер во всех раскладок и оценить каждую.
    public static func renderAll(_ keys: [KeyRec], _ layouts: [LayoutData]) -> [LayoutCandidate] {
        layouts.map { data in
            let text = render(data, keys)
            let letters = LanguageTables.lettersOnly(text)
            var lang = !letters.isEmpty ? LanguageTables.langOf(letters) : -1
            if lang == 0 && isOtherCyrillicLayout(data.id, rendered: text) {
                lang = -1 // не путаем RU с UA/BY раскладками (P2-4)
            }
            let score = lang >= 0 ? LanguageTables.score(letters, lang) : -99
            return LayoutCandidate(layoutID: data.id, source: data.source, text: text, lang: lang,
                                   score: score, name: layoutName(letters))
        }
    }

    /// Фактическая системная раскладка (чтение под локом, безопасно с потока тапа).
    public static func currentLayout() -> LayoutData? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cachedCurrent
    }

    /// Найти раскладку языка (0 = РУС с приоритетом чисто русской; 1 = ENG с приоритетом QWERTY).
    public static func findLayoutByLang(_ lang: Int) -> LayoutData? {
        let probeA = [KeyRec(KeyCodeMap.ansiCode(ofLatin: "a"), false, false)]
        let layouts = getLayouts()
        if lang == 0 {
            let probeRu = [KeyRec(KeyCodeMap.ansiCode(ofLatin: "s"), false, false),
                           KeyRec(KeyCodeMap.ansiCode(ofLatin: "]"), false, false)]
            if let exact = layouts.first(where: { l in
                !isOtherCyrillicLayout(l.id, rendered: "") &&
                render(l, probeRu).lowercased() == "ыъ"
            }) {
                return exact
            }
            return layouts.first { !isOtherCyrillicLayout($0.id, rendered: "") && LanguageTables.langOf(render($0, probeA)) == 0 }
        }
        if lang == 1 {
            if let us = layouts.first(where: { $0.id == "com.apple.keylayout.ABC" || $0.id == "com.apple.keylayout.US" }) {
                return us
            }
            let probeYz = [KeyRec(KeyCodeMap.ansiCode(ofLatin: "y"), false, false),
                           KeyRec(KeyCodeMap.ansiCode(ofLatin: "z"), false, false)]
            if let qwerty = layouts.first(where: { render($0, probeYz).lowercased() == "yz" }) {
                return qwerty
            }
        }
        return layouts.first { LanguageTables.langOf(render($0, probeA)) == lang }
    }

    /// Переключить раскладку глобально (только на main).
    /// Планирует серию быстрых проверок `refreshOnMain`, чтобы поймать фактическое
    /// применение раскладки системой за ~30–180 мс без искусственного обмана кэша.
    @discardableResult
    public static func switchTo(_ data: LayoutData) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        let ok = TISSelectInputSource(data.source) == noErr
        for delay in [0.035, 0.09, 0.18] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                refreshOnMain()
            }
        }
        return ok
    }
}
