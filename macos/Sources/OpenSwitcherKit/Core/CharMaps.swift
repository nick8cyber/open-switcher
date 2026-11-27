import Foundation

/// Символ, набранный физической клавишей: keyCode + состояние shift/caps.
/// Порт KeyRec из CharMaps.cs; vk заменён на macOS-код клавиши (HIToolbox).
public struct KeyRec: Equatable {
    public var code: Int   // macOS virtual keycode (kVK_...)
    public var shift: Bool
    public var caps: Bool

    public init(_ code: Int, _ shift: Bool, _ caps: Bool) {
        self.code = code; self.shift = shift; self.caps = caps
    }
}

/// Статические карты ЙЦУКЕН <-> QWERTY (порт CharMaps.cs 1:1).
public enum CharMaps {
    public static let en = "qwertyuiop[]asdfghjkl;'zxcvbnm,.`"
    public static let ru = "йцукенгшщзхъфывапролджэячсмитьбюё"
    public static let enUpper = "QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>~"
    public static let ruUpper = "ЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮЁ"

    private static let enLowerArr = Array(en)
    private static let ruLowerArr = Array(ru)
    private static let enUpperArr = Array(enUpper)
    private static let ruUpperArr = Array(ruUpper)

    /// macOS-keycode клавиши, которой набирается символ ru/en раскладки.
    public static func keyCode(ofChar c: Character, fromRu: Bool) -> Int {
        let lowerSrc = fromRu ? ruLowerArr : enLowerArr
        let upperSrc = fromRu ? ruUpperArr : enUpperArr
        if let idx = lowerSrc.firstIndex(of: c) {
            return KeyCodeMap.ansiCode(ofLatin: enLowerArr[idx])
        }
        if let idx = upperSrc.firstIndex(of: c) {
            return KeyCodeMap.ansiCode(ofLatin: enLowerArr[idx])
        }
        let lo = Character(String(c).lowercased())
        if let idx = lowerSrc.firstIndex(of: lo) {
            return KeyCodeMap.ansiCode(ofLatin: enLowerArr[idx])
        }
        return -1
    }

    /// Конвертация готового текста между раскладками с сохранением регистра
    /// и двунаправленным маппингом Shift-символов (: < > " { } ~ ⇄ Ж Б Ю Э Х Ъ Ё).
    public static func mapText(_ text: String, toRu: Bool) -> String {
        let srcLo = toRu ? enLowerArr : ruLowerArr
        let dstLo = toRu ? ruLowerArr : enLowerArr
        let srcHi = toRu ? enUpperArr : ruUpperArr
        let dstHi = toRu ? ruUpperArr : enUpperArr
        var out = String()
        out.reserveCapacity(text.count)
        for c in text {
            if let i = srcLo.firstIndex(of: c) {
                out.append(dstLo[i])
            } else if let i = srcHi.firstIndex(of: c) {
                out.append(dstHi[i])
            } else {
                out.append(c)
            }
        }
        return out
    }
}

/// Физические клавиши (macOS virtual keycodes) — аналог VK-кодов Windows.
public enum KeyCodeMap {
    // A-Z
    public static let letters: [Int: Character] = [
        0x00: "a", 0x0B: "b", 0x08: "c", 0x02: "d", 0x0E: "e", 0x03: "f", 0x05: "g",
        0x04: "h", 0x22: "i", 0x26: "j", 0x28: "k", 0x25: "l", 0x2E: "m", 0x2D: "n",
        0x1F: "o", 0x23: "p", 0x0C: "q", 0x0F: "r", 0x01: "s", 0x11: "t", 0x20: "u",
        0x09: "v", 0x0D: "w", 0x07: "x", 0x10: "y", 0x06: "z",
    ]
    // знаковые клавиши, несущие русские буквы (б ю ж э х ё ъ, плюс ISO ё = 0x0A)
    public static let signLetterKeys: [Int: Character] = [
        0x29: ";", 0x27: "'", 0x21: "[", 0x1E: "]", 0x2B: ",", 0x2F: ".", 0x32: "`", 0x0A: "`",
    ]
    public static let digits: Set<Int> = [0x1D, 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19]
    public static let keypadDigits: Set<Int> = [0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C]
    public static let keypadOps: Set<Int> = [0x41, 0x43, 0x45, 0x47, 0x4B, 0x4E, 0x51]

    public static let space = 0x31
    public static let enter = 0x24
    public static let keypadEnter = 0x4C
    public static let backspace = 0x33
    public static let tab = 0x30
    public static let esc = 0x35
    public static let equal = 0x18
    public static let minus = 0x1B
    public static let comma = 0x2B
    public static let period = 0x2F
    public static let semicolon = 0x29
    public static let quote = 0x27
    public static let slash = 0x2C
    public static let backslash = 0x2A
    public static let leftShift = 0x38
    public static let rightShift = 0x3C  // kVK_RightShift (0x7C — это RightArrow!)
    public static let capsLock = 0x39
    public static let f15 = 0x71   // Pause/Break-клавиша на Mac-клавиатурах

    /// Латиница → ANSI keycode.
    public static func ansiCode(ofLatin c: Character) -> Int {
        for (code, ch) in letters where ch == c { return code }
        for (code, ch) in signLetterKeys where ch == c && code != 0x0A { return code }
        return -1
    }

    /// Знаковая клавиша-«двойник» русской буквы (б=',', ю='.', ж=';', э='\'').
    /// Хвост такой клавиши в перевороте остаётся ЗНАКОМ: «z,» -> «я,», а не «яб».
    public static func isPunctTwinKey(_ code: Int) -> Bool {
        code == 0x29 || code == 0x2B || code == 0x2F || code == 0x27
    }

    /// Знак, печатаемый клавишей-«двойником» (для хвоста переворота).
    public static func punctCharOfKey(_ code: Int) -> Character? {
        switch code {
        case 0x2B: return ","
        case 0x2F: return "."
        case 0x29: return ";"
        case 0x27: return "'"
        default: return nil
        }
    }

    /// Буквенная ли клавиша: латиница + «русские» знаковые клавиши (б/ю/ж/э/х/ъ/ё)
    /// + дефис (0x1B без Shift держит «какой-то» целиком; Shift+0x1B = '_' помечает код-токен в Engine)
    /// + 0x2A ('\'), если активная русская раскладка Apple держит на нём 'ё'/'Ё'.
    public static func isLetterKey(_ code: Int, allowBackslashYo: Bool = false) -> Bool {
        letters[code] != nil || signLetterKeys[code] != nil || code == minus || (allowBackslashYo && code == backslash)
    }

    /// Цифровая клавиша 0..9: НЕ запускает автоконвертацию предшествующего буквенного куска
    /// ('snow7', 'gpt4', 'xnj1'), а помечает токен смешанным до пробела/Enter.
    /// ВАЖНО: с зажатым Shift клавиши цифр печатают знаки препинания ('!', '?', '"', ';', ':'),
    /// поэтому Shift+цифра считается разделителем конца слова (`isSeparatorKey(code, shift:)`).
    public static func isDigitKey(_ code: Int) -> Bool {
        digits.contains(code) || keypadDigits.contains(code)
    }

    public static func isKeypadDigitKey(_ code: Int) -> Bool {
        keypadDigits.contains(code)
    }

    public static func isKeypadOpKey(_ code: Int) -> Bool {
        keypadOps.contains(code)
    }

    /// Разделители конца слова: пробел, '=', '/', '\', а также Shift+цифры ('!', '?', '"', ';', ':', '(', ')').
    /// Голые цифры 0..9 сюда НЕ входят — они рвут слово без конвертации, защищая логины/токены.
    public static func isSeparatorKey(_ code: Int, shift: Bool = false, allowBackslashYo: Bool = false) -> Bool {
        if code == backslash && allowBackslashYo { return false }
        if code == space || code == equal || code == slash || code == backslash { return true }
        if shift && digits.contains(code) { return true }
        return false
    }

    /// F-клавиши, навигация, Ins/Del: каретку двигают / правят текст —
    /// буфер слова и хвост отката после них невоспроизводимы.
    public static let navigationKeys: Set<Int> = [
        // F1-F12 (F12=0x6F)
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F,
        // F13-F20 (F14=0x6B; F15=0x71 — хоткеи undo/fixsel матчятся раньше навигации)
        0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,
        // Help, Home, PageUp, ForwardDelete, End, PageDown, стрелки
        0x72, 0x73, 0x74, 0x75, 0x77, 0x79, 0x7B, 0x7C, 0x7D, 0x7E,
    ]

    public static func isNavigationKey(_ code: Int) -> Bool {
        navigationKeys.contains(code)
    }

    /// Модификатор ли (не считаем модификаторы «набором после слова»).
    public static func isModifier(_ code: Int) -> Bool {
        switch code {
        case 0x38, 0x3C, 0x3B, 0x3E, 0x3A, 0x3D, 0x37, 0x36, 0x39, 0x3F: return true
        default: return false
        }
    }

    /// Человекочитаемое имя клавиши (для полей хоткеев).
    public static func name(of code: Int) -> String {
        switch code {
        case space: return "Space"
        case enter: return "Enter"
        case backspace: return "Backspace"
        case tab: return "Tab"
        case esc: return "Esc"
        case 0x71: return "F15"
        case 0x72: return "Help"
        case 0x73: return "Home"
        case 0x74: return "PageUp"
        case 0x75: return "Delete"
        case 0x77: return "End"
        case 0x79: return "PageDown"
        case 0x7B: return "Left"
        case 0x7C: return "Right"
        case 0x7D: return "Down"
        case 0x7E: return "Up"
        case keypadEnter: return "KeypadEnter"
        case leftShift: return "LShift"
        case rightShift: return "RShift"
        case capsLock: return "CapsLock"
        default:
            if let c = letters[code] { return String(c).uppercased() }
            if let c = signLetterKeys[code] { return "'\(c)'" }
            let digitsByName = [0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4",
                                0x17: "5", 0x16: "6", 0x1A: "7", 0x1C: "8", 0x19: "9"]
            if let d = digitsByName[code] { return d }
            return "Key\(code)"
        }
    }
}

/// Буфер последнего введённого слова из KeyRec (порт WordBuffer).
/// Пишется с потока тапа и с main (сброс при смене окна) — под локом.
public final class WordBuffer {
    private var keys: [KeyRec] = []
    private let lock = NSLock()
    public static let maxLen = 40
    private var _overflowed = false

    public var overflowed: Bool {
        lock.lock(); defer { lock.unlock() }
        return _overflowed
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return keys.count
    }

    public func push(_ rec: KeyRec) {
        lock.lock(); defer { lock.unlock() }
        if _overflowed { return }
        if keys.count >= WordBuffer.maxLen {
            keys.removeAll()
            _overflowed = true
            return
        }
        keys.append(rec)
    }

    public func pop() {
        lock.lock(); defer { lock.unlock() }
        if !keys.isEmpty { keys.removeLast() }
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        keys.removeAll()
        _overflowed = false
    }

    public func snapshot() -> [KeyRec] {
        lock.lock(); defer { lock.unlock() }
        return keys
    }

    public func restore(_ k: [KeyRec]) {
        lock.lock(); defer { lock.unlock() }
        keys = k
        _overflowed = false
    }
}
