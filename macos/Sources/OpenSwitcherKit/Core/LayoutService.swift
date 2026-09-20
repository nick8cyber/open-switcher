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
    /// TTL-кэш текущей раскладки: убирает TIS-вызовы с горячего пути (каждая клавиша).
    static var curCache: (data: LayoutData, at: TimeInterval)?

    /// Все включённые раскладки с юникод-данными (кэш 30 с).
    /// Вызывается и с потока тапа, и с main: под локом только проверка TTL и
    /// запись результата, само перечисление TIS (миллисекунды) — ВНЕ лока,
    /// иначе тап блокируется на полной перестройке.
    public static func getLayouts() -> [LayoutData] {
        cacheLock.lock()
        let now = Date().timeIntervalSinceReferenceDate
        if !cache.isEmpty, now - cacheAt < 30 {
            cacheLock.unlock()
            return cache
        }
        cacheLock.unlock()

        var list: [LayoutData] = []
        let filter = [kTISPropertyInputSourceIsEnableCapable as String: true] as CFDictionary
        if let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] {
            for src in sources {
                guard let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { continue }
                let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue()
                guard let idPtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { continue }
                let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
                if list.contains(where: { $0.id == id }) { continue } // дедуп как в оригинале
                list.append(LayoutData(source: src, id: id, layoutData: data))
            }
        }
        cacheLock.lock()
        cache = list
        cacheAt = Date().timeIntervalSinceReferenceDate
        curCache = nil // набор раскладок изменился — кэш текущей недостоверен
        cacheLock.unlock()
        return list
    }

    /// Текст, который дала бы эта раскладка при тех же нажатиях.
    public static func render(_ data: LayoutData, _ keys: [KeyRec]) -> String {
        var out = ""
        for rec in keys {
            var deadState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 8)
            var count = 0
            // UCKeyTranslate ждёт EventRecord.modifiers, сдвинутые >>8:
            // shiftKey (0x0200) -> 0x02, alphaLock (0x0400) -> 0x04
            var mods: UInt32 = 0
            if rec.shift { mods |= 1 << 1 }
            if rec.caps { mods |= 1 << 2 }
            let kr = UCKeyTranslate(data.layout, UInt16(rec.code),
                                    UInt16(kUCKeyActionDown),
                                    mods, UInt32(LMGetKbdType()),
                                    OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
                                    &deadState, 8, &count, &chars)
            if kr == noErr && count > 0 {
                out += String(utf16CodeUnits: chars, count: Int(count))
            } else {
                out += "?"
            }
        }
        return out
    }

    public static func layoutName(_ text: String) -> String {
        let lang = LanguageTables.langOf(text)
        if lang == 0 { return "РУС" }
        if lang == 1 { return "ENG" }
        return "???"
    }

    /// Прочитать буфер во всех раскладках и оценить каждую.
    public static func renderAll(_ keys: [KeyRec], _ layouts: [LayoutData]) -> [LayoutCandidate] {
        layouts.map { data in
            let text = render(data, keys)
            let letters = LanguageTables.lettersOnly(text)
            let lang = !letters.isEmpty ? LanguageTables.langOf(letters) : -1
            let score = lang >= 0 ? LanguageTables.score(letters, lang) : -99
            return LayoutCandidate(layoutID: data.id, source: data.source, text: text, lang: lang,
                                   score: score, name: layoutName(letters))
        }
    }

    /// Текущая системная раскладка. TTL-кэш 0.1 c: вызывается из тапа на каждую
    /// клавишу, TISCopyCurrentKeyboardInputSource на горячем пути недопустим.
    /// Смена раскладки снаружи подхватывается максимум за 100 мс (грейс expectLayout
    /// 1.2 с и gap-дедлайн 0.8 с это покрывают).
    public static func currentLayout() -> LayoutData? {
        cacheLock.lock()
        let now = Date().timeIntervalSinceReferenceDate
        if let c = curCache, now - c.at < 0.1 {
            cacheLock.unlock()
            return c.data
        }
        cacheLock.unlock()

        guard let cur = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let idPtr = TISGetInputSourceProperty(cur, kTISPropertyInputSourceID) else { return nil }
        let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
        let layouts = getLayouts()
        guard let hit = layouts.first(where: { $0.id == id }) else { return nil }

        cacheLock.lock()
        curCache = (hit, Date().timeIntervalSinceReferenceDate)
        cacheLock.unlock()
        return hit
    }

    /// Найти раскладку, в которой клавиша 'a' даёт кириллицу (0) или латиницу (1).
    public static func findLayoutByLang(_ lang: Int) -> LayoutData? {
        let probe = [KeyRec(KeyCodeMap.ansiCode(ofLatin: "a"), false, false)]
        return getLayouts().first { LanguageTables.langOf(render($0, probe)) == lang }
    }

    /// Переключить раскладку (на macOS — глобально, TISSelectInputSource).
    @discardableResult
    public static func switchTo(_ data: LayoutData) -> Bool {
        TISSelectInputSource(data.source) == noErr
    }
}
