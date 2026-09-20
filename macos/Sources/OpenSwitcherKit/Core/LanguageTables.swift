import Foundation

/// Оценка «похожести» слова на английский / русский по частотам букв и биграмм.
/// Порт LanguageTables.cs 1:1.
public enum LanguageTables {
    static let uniFloor = 0.01
    static let biFloor = 0.02
    static let uniWeight = 0.6

    /// Порог «уверенности».
    public static let baseMargin = 0.22
    /// Ниже такого скора целевое слово не бывает.
    public static let hardFloor = -1.35

    static var enUni: [Character: Double] = [:]
    static var ruUni: [Character: Double] = [:]
    static var enBi: [String: Double] = [:]
    static var ruBi: [String: Double] = [:]

    static let ruKeyboardRows = ["йцукенгшщзхъ", "фывапролджэ", "ячсмитьбюё"]
    static let enKeyboardRows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]

    static func load(_ d: inout [Character: Double], _ src: String) {
        for pair in src.split(separator: ",") {
            let kv = pair.split(separator: ":", maxSplits: 1)
            if kv.count == 2, let f = Double(kv[1]), let c = kv[0].first { d[c] = f }
        }
    }

    static func loadBi(_ d: inout [String: Double], _ src: String) {
        for pair in src.split(separator: ",") {
            let kv = pair.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].count == 2, let f = Double(kv[1]) { d[String(kv[0])] = f }
        }
    }

    static var initialized: Bool = {
        load(&enUni, "a:8.2,b:1.5,c:2.8,d:4.3,e:12.7,f:2.2,g:2.0,h:6.1,i:7.0,j:0.15,k:0.77,l:4.0,m:2.4,n:6.7,o:7.5,p:1.9,q:0.095,r:6.0,s:6.3,t:9.1,u:2.8,v:0.98,w:2.4,x:0.15,y:2.0,z:0.074")
        load(&ruUni, "о:11.7,е:8.5,а:8.0,и:7.4,н:6.7,т:6.3,с:5.5,р:4.7,в:4.5,л:4.3,к:3.5,м:3.2,д:3.0,п:2.8,у:2.6,я:2.0,ы:1.9,з:1.6,ь:1.4,б:1.4,г:1.3,ч:1.0,й:0.9,х:0.8,ж:0.7,ю:0.6,ш:0.6,ц:0.4,щ:0.3,э:0.3,ф:0.2,ъ:0.02,ё:0.05")
        loadBi(&enBi, "th:3.56,he:3.07,in:2.43,er:2.33,an:2.03,re:1.99,on:1.91,at:1.66,en:1.63,nd:1.62,ti:1.57,es:1.55,or:1.54,te:1.49,of:1.46,ed:1.42,is:1.36,it:1.29,al:1.26,ar:1.25,st:1.22,to:1.20,nt:1.17,ng:1.14,se:1.10,ha:1.08,as:1.07,ou:1.05,io:1.04,le:1.03,ve:1.01,co:0.98,me:0.97,de:0.96,hi:0.94,ri:0.93,ro:0.92,ic:0.91,ne:0.90,ea:0.89,ra:0.88,ce:0.87,li:0.86,ch:0.83,ll:0.82,be:0.80,ma:0.79,si:0.78,om:0.77,ur:0.76,ca:0.75,el:0.74,ta:0.73,la:0.73,ns:0.71,di:0.70,fo:0.69,ho:0.68,pe:0.67,ec:0.66,pr:0.65,no:0.64,ct:0.63,us:0.62,ac:0.61,ot:0.60,il:0.59,tr:0.58,ly:0.57,nc:0.56,et:0.55,ut:0.54,ss:0.53,so:0.52,rs:0.51,un:0.50,lo:0.49,wa:0.48,ge:0.47,ie:0.46,wh:0.45,ee:0.44,wi:0.43,em:0.42,ad:0.41,ol:0.40,rt:0.39,po:0.38,we:0.37,na:0.36,ul:0.35,ni:0.34,ts:0.33,mo:0.32,ow:0.31,pa:0.30,im:0.29,mi:0.28,ai:0.27,sh:0.26,ir:0.25,su:0.24,qu:0.24,id:0.23,os:0.22,iv:0.21,ia:0.20,am:0.19,fi:0.18,ci:0.17,vi:0.16,pl:0.15,ig:0.14,tu:0.13,ev:0.12,ld:0.11,ry:0.10,ty:0.10,mp:0.09,fe:0.09,bl:0.08,ab:0.08,gh:0.08,ke:0.08,kn:0.07,ck:0.07,ui:0.07,sa:0.07,oo:0.07")
        loadBi(&ruBi, "ст:2.65,но:2.04,ен:1.88,то:1.82,на:1.73,ов:1.55,ни:1.54,ра:1.48,во:1.42,ко:1.35,ет:1.33,го:1.31,со:1.19,ти:1.18,не:1.12,ес:1.05,ос:1.03,ло:1.03,ер:1.01,ро:0.99,по:0.96,ол:0.95,ва:0.92,ал:0.90,ая:0.86,ма:0.84,нт:0.83,от:0.80,да:0.79,ви:0.77,ка:0.77,ла:0.76,ел:0.75,ре:0.74,та:0.73,ат:0.73,ки:0.70,ия:0.70,ры:0.69,ск:0.67,чи:0.65,ме:0.64,ся:0.62,ам:0.61,ав:0.59,ил:0.58,чн:0.56,ыв:0.55,мо:0.54,ог:0.53,ым:0.52,ис:0.51,ем:0.50,ой:0.49,ль:0.48,од:0.47,до:0.46,из:0.45,ую:0.44,ан:0.43,ор:0.42,ей:0.41,ин:0.40,ых:0.39,ша:0.38,ны:0.37,ту:0.36,ми:0.35,ук:0.35,ке:0.35,ру:0.34,тв:0.33,ом:0.31,ве:0.30,нь:0.30,жд:0.29,нн:0.29,пр:0.28,ул:0.27,аз:0.26,об:0.26,тр:0.25,он:0.25,ик:0.24,ар:0.24,кл:0.23,ку:0.22,еп:0.21,ед:0.21,им:0.20,ие:0.20,уж:0.19,ак:0.19,ок:0.19,щи:0.18,ек:0.18,кс:0.18,зн:0.17,ри:0.17,че:0.17,ну:0.17,бр:0.16")
        return true
    }()

    public static func isCyrillic(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x0400...0x04FF).contains(Int(v))
    }

    public static func isLatin(_ c: Character) -> Bool {
        ("a"..."z").contains(c) || ("A"..."Z").contains(c)
    }

    /// 0 = русский, 1 = английский, -1 = смешанно/не буквы.
    public static func langOf(_ s: String) -> Int {
        var ru = 0, en = 0
        for c in s {
            if isCyrillic(c) { ru += 1 } else if isLatin(c) { en += 1 }
        }
        if ru > 0 && en == 0 { return 0 }
        if en > 0 && ru == 0 { return 1 }
        return -1
    }

    public static func lettersOnly(_ s: String) -> String {
        String(s.filter { isCyrillic($0) || isLatin($0) })
    }

    /// Нормированный скор: чем ближе к 0, тем «естественнее» слово для языка.
    public static func score(_ word: String, _ lang: Int) -> Double {
        _ = initialized
        let w = word.lowercased()
        let chars = Array(w)
        let n = chars.count
        if n == 0 { return -3 }
        var bi = 0.0, uni = 0.0
        for i in 0..<n {
            let f = (lang == 0 ? ruUni[chars[i]] : enUni[chars[i]]) ?? uniFloor
            uni += log10(max(f, uniFloor))
        }
        for i in 0..<(n - 1) {
            let key = String(chars[i...i+1])
            let f = (lang == 0 ? ruBi[key] : enBi[key]) ?? biFloor
            bi += log10(max(f, biFloor))
        }
        var s = (bi + uniWeight * uni) / (1.0 + uniWeight) / Double(n)
        if s < -3 { s = -3 }
        return s
    }

    /// Бонус за слова-«дорожки клавиатуры»: qwerty -> йцукен и т.п.
    static func rowBoost(_ word: String, _ lang: Int) -> Double {
        let w = word.lowercased()
        if w.count < 4 { return 0 }
        let rows = lang == 0 ? ruKeyboardRows : enKeyboardRows
        for row in rows where row.hasPrefix(w) || w.hasPrefix(row) { return 0.6 }
        return 0
    }

    public static func hasVowel(_ text: String, _ lang: Int) -> Bool {
        let rv = "аеёиоуыэюя"
        let ev = "aeiouy"
        let v = lang == 0 ? rv : ev
        return text.lowercased().contains { v.contains($0) }
    }

    static var ruBigAll: Set<String>?
    static var enBigAll: Set<String>?
    static let bigSetsLock = NSLock()

    /// Все пары букв, встречающиеся в корпусе WordData (+ ручные таблицы биграмм).
    static func bigramsOf(_ src: String) -> Set<String> {
        var set = Set<String>()
        for w in src.split(separator: " ") {
            let t = String(w).trimmingCharacters(in: .whitespaces).lowercased()
            guard t.count >= 2, lettersOnly(t) == t else { continue }
            let chars = Array(t)
            for i in 0..<(chars.count - 1) { set.insert(String(chars[i...i+1])) }
        }
        return set
    }

    static func ensureBigSets() {
        bigSetsLock.lock()
        defer { bigSetsLock.unlock() }
        if ruBigAll != nil { return }
        var r = bigramsOf(WordData.ruAll)
        r.formUnion(ruBi.keys)
        ruBigAll = r
        var e = bigramsOf(WordData.enAll)
        e.formUnion(enBi.keys)
        enBigAll = e
    }

    /// «Возможное» слово языка: чисто из букв и КАЖДАЯ пара соседних букв
    /// встречается хотя бы в одном слове корпуса (55k слов). Позитивная морфология:
    /// покрывает формы вне словаря («нажимал», «запусти»), отсекает мусор («каая»).
    public static func possibleWord(_ word: String, _ lang: Int) -> Bool {
        if word.isEmpty { return false }
        let w = word.lowercased()
        guard w.count >= 2, lettersOnly(w) == w else { return false }
        ensureBigSets()
        let set = lang == 0 ? (ruBigAll ?? []) : (enBigAll ?? [])
        let chars = Array(w)
        for i in 0..<(chars.count - 1) where !set.contains(String(chars[i...i+1])) {
            return false
        }
        return true
    }

    /// Решение «слово набрано не в той раскладке» (порт ShouldConvert).
    public static func shouldConvert(curText: String, curLang: Int, curScore: Double,
                                     bestText: String, bestLang: Int, bestScore: Double,
                                     sensitivity: Double) -> Bool {
        if curLang < 0 || bestLang < 0 || curLang == bestLang { return false }
        if bestText.isEmpty { return false }
        let margin = baseMargin / max(0.3, sensitivity)
        let b = bestScore + rowBoost(bestText, bestLang)
        if b < curScore + margin { return false }
        if b < hardFloor { return false }
        if bestLang == 1 && bestScore < -0.05 { return false }
        if bestLang == 0 && bestScore < -0.55 { return false }
        if !hasVowel(bestText, bestLang) { return false }
        return true
    }
}
