import Foundation

/// Автотест детектора (порт SelfTest.cs 1:1): статические карты ЙЦУКЕН/QWERTY,
/// без хуков и реальных раскладок.
public enum SelfTest {
    public struct Case {
        public let typed: String
        public let typedIsRu: Bool
        public let expectConvert: Bool
        public let note: String
        public let live: Bool
    }

    public static func run(_ outPath: String) -> Int {
        let cases = [
            Case(typed: "ghbdtn", typedIsRu: false, expectConvert: true,  note: "привет", live: false),
            Case(typed: "руддщ",  typedIsRu: true,  expectConvert: true,  note: "hello", live: false),
            Case(typed: "hello",  typedIsRu: false, expectConvert: false, note: "уже английское", live: false),
            Case(typed: "привет", typedIsRu: true,  expectConvert: false, note: "уже русское", live: false),
            Case(typed: "ntcn",   typedIsRu: false, expectConvert: true,  note: "текст", live: false),
            Case(typed: "црщ",    typedIsRu: true,  expectConvert: true,  note: "who", live: false),
            Case(typed: "world",  typedIsRu: false, expectConvert: false, note: "уже английское", live: false),
            Case(typed: "знает",  typedIsRu: true,  expectConvert: false, note: "уже русское", live: false),
            Case(typed: "qwerty", typedIsRu: false, expectConvert: true,  note: "йцукен (клавиатурный ряд)", live: false),
            Case(typed: "qwe",    typedIsRu: false, expectConvert: false, note: "двусмысленно, коротко", live: false),
            Case(typed: "bd",     typedIsRu: false, expectConvert: false, note: "слишком коротко", live: false),
            Case(typed: "quit",   typedIsRu: false, expectConvert: false, note: "настоящее английское слово", live: false),
            Case(typed: "дадут",  typedIsRu: true,  expectConvert: false, note: "русское слово не превращать в lflen", live: false),
            Case(typed: "муд",    typedIsRu: true,  expectConvert: false, note: "живое: 'vel' не словарное — не трогаем", live: true),
            Case(typed: "ghbdtn", typedIsRu: false, expectConvert: true,  note: "живое: привет в словаре — перевернём", live: true),
            Case(typed: "что",    typedIsRu: true,  expectConvert: false, note: "частое русское: цель 'xnj' не словарная, не трогаем", live: false),
            Case(typed: "xnj",    typedIsRu: false, expectConvert: true,  note: "цель 'что' словарная, набранное нет — словарь сильнее скоринга", live: false),
        ]

        var sb = ""
        var fails = 0
        for c in cases {
            let keys = buildKeys(c.typed, isRu: c.typedIsRu)
            if keys.count < 3 {
                sb += "PASS: '\(c.typed)' (\(c.typedIsRu ? "ru" : "en")) — короче MinLen, не трогаем: \(c.note)\n"
                continue
            }
            let curText = c.typed
            let altText = mapAll(c.typed, fromRu: c.typedIsRu)
            let curLang = c.typedIsRu ? 0 : 1
            let altLang = c.typedIsRu ? 1 : 0
            let curScore = LanguageTables.score(LanguageTables.lettersOnly(curText), curLang)
            let altScore = LanguageTables.score(LanguageTables.lettersOnly(altText), altLang)
            var convert: Bool
            if c.live && !WordDict.has(altText, altLang) {
                convert = false
            } else {
                convert = LanguageTables.shouldConvert(curText: curText, curLang: curLang, curScore: curScore,
                                                       bestText: altText, bestLang: altLang, bestScore: altScore,
                                                       sensitivity: 1.0)
                let targetInDict = WordDict.has(altText, altLang)
                let curInDict = WordDict.has(curText, curLang)
                if convert && curInDict && !targetInDict { convert = false }
                if !convert && targetInDict && !curInDict { convert = true }
            }
            let pass = convert == c.expectConvert
            if !pass { fails += 1 }
            sb += String(format: "%@: '%@' (%@) -> '%@' [%@] %@  cur=%.2f alt=%.2f  (%@)\n",
                         pass ? "PASS" : "FAIL", c.typed, c.typedIsRu ? "ru" : "en", altText,
                         convert ? "CONVERT" : "keep", pass ? "" : "!!",
                         curScore, altScore, c.note)
        }
        // --- SPEC v3: словность одиночных букв и PossibleWord из корпуса ---
        let v3checks: [(String, Bool, Bool)] = [
            ("singles: 'а' — слово RU",        WordDict.hasSingleLetterWord("а", 0), true),
            ("singles: 'я' — слово RU",        WordDict.hasSingleLetterWord("я", 0), true),
            ("singles: 'f' — не слово RU",     WordDict.hasSingleLetterWord("f", 0), false),
            ("singles: 'a' — слово EN",        WordDict.hasSingleLetterWord("a", 1), true),
            ("singles: 'q' — не слово EN",     WordDict.hasSingleLetterWord("q", 1), false),
            ("possible: 'нажимал' (корпус)",   LanguageTables.possibleWord("нажимал", 0), true),
            ("possible: 'запусти' (корпус)",   LanguageTables.possibleWord("запусти", 0), true),
            ("possible: 'что' (корпус)",       LanguageTables.possibleWord("что", 0), true),
            // NB: спека §11 обещает отсечение 'каая'/'воо', но в корпусе 55k есть
            // 'аа' ('аарон') и 'оо' ('вообще') — код C# v3 их тоже пропускает;
            // порт сверяется с КОДОМ (норматив), а не с прозой спеки
            ("possible: 'каая' = код C# v3",   LanguageTables.possibleWord("каая", 0), true),
            ("possible: 'воо' = код C# v3",    LanguageTables.possibleWord("воо", 0), true),
            ("possible: 'кшмрре' — мусор",     LanguageTables.possibleWord("кшмрре", 0), false),
            // известный дефект v3 (порт и C# одинаково): 'тб' есть в корпусе (×28),
            // поэтому twin-ветка не выбирает «привет,» и критерий приёмки №2 даёт
            // «приветб» — задокументировано, чинить только синхронно с оригиналом
            ("possible: 'приветб' = true (дефект v3)", LanguageTables.possibleWord("приветб", 0), true),
            ("possible: 'pfgectnb' EN-пар",    LanguageTables.possibleWord("pfgectnb", 1), true),
            ("dict v3: 'нажимал' в корпусе",   WordDict.has("нажимал", 0), true),
            ("dict v3: 'iban' удалён",         WordDict.has("iban", 1), false),
        ]
        for (name, got, want) in v3checks {
            let pass = got == want
            if !pass { fails += 1 }
            sb += "\(pass ? "PASS" : "FAIL"): [v3] \(name)\(pass ? "" : " !!")\n"
        }

        sb += fails == 0 ? "ALL TESTS PASSED\n" : "\(fails) TEST(S) FAILED\n"
        try? sb.write(toFile: outPath, atomically: true, encoding: .utf8)
        print(sb, terminator: "")
        return fails == 0 ? 0 : 1
    }

    /// «--simtest ghbdtn»: прогон строки через настоящие установленные раскладки.
    public static func simulate(_ typed: String, sensitivity: Double) -> Int {
        let keys = buildKeys(typed, isRu: false)
        if keys.isEmpty {
            print("unknown characters")
            return 2
        }
        let layouts = LayoutService.getLayouts()
        print("layouts: \(layouts.count)")
        let cands = LayoutService.renderAll(keys, layouts)
        for c in cands {
            print(String(format: "  %@: '%@' lang=%d score=%.3f", c.name, c.text, c.lang, c.score))
        }
        if cands.count < 2 {
            print("only one layout installed - nothing to decide")
            return 0
        }
        let cur = cands[0]
        guard let best = cands.dropFirst().filter({ $0.lang >= 0 }).max(by: { $0.score < $1.score }) else {
            print("no candidate")
            return 0
        }
        let conv = LanguageTables.shouldConvert(curText: cur.text, curLang: cur.lang, curScore: cur.score,
                                                bestText: best.text, bestLang: best.lang, bestScore: best.score,
                                                sensitivity: sensitivity)
        print(conv ? "DECISION: convert '\(cur.text)' -> '\(best.text)' (\(best.name))"
                   : "DECISION: keep '\(cur.text)'")
        return 0
    }

    static func buildKeys(_ typed: String, isRu: Bool) -> [KeyRec] {
        var keys: [KeyRec] = []
        for ch in typed {
            let code = CharMaps.keyCode(ofChar: ch, fromRu: isRu)
            if code < 0 { return [] }
            keys.append(KeyRec(code, ch.isUppercase, false))
        }
        return keys
    }

    /// Как эта же последовательность клавиш выглядит в другой раскладке.
    static func mapAll(_ typed: String, fromRu: Bool) -> String {
        var sb = ""
        for ch in typed.lowercased() {
            if let i = (fromRu ? CharMaps.ru : CharMaps.en).firstIndex(of: ch) {
                let pos = (fromRu ? CharMaps.ru : CharMaps.en).distance(from: (fromRu ? CharMaps.ru : CharMaps.en).startIndex, to: i)
                let src = fromRu ? CharMaps.en : CharMaps.ru
                sb.append(String(Array(src)[pos]))
            } else {
                sb.append("?")
            }
        }
        return sb
    }
}
