import Foundation

/// Компактные списки частых слов (RU/EN) для валидации решений конвертации.
/// Порт WordDict.cs 1:1.
public enum WordDict {
    static let ruSrc = """
        и в не на я он с как а то все она так его но да ты к у же вы за бы по только ее мне \
        было вот от меня еще нет о из ему теперь когда даже ну вдруг ли если уже или ни до \
        вас уж вам ведь там потом себя ничего ей может они тут где есть надо ней для мы \
        тебя их чем была сам чтоб без будто чего раз тоже себе под будет тогда кто этот \
        потому этого какой совсем ним здесь этом один почти мой тем чтобы сейчас были куда \
        зачем всех никогда можно при наконец два об другой хоть после над больше тот через \
        эти нас про всего них какая много три эту моя впрочем хорошо свою этой перед \
        иногда лучше нельзя такой им более всегда конечно всю между привет пока спасибо \
        пожалуйста извини извините ладно окей блин жаль точно наверное возможно кажется \
        вроде просто очень мало меньше самое самый весь вся нормальный нормально круто \
        класс ужас страшно смешно скучно время человек день ночь жизнь работа дом друг \
        друзья мама папа брат сестра семья девушка парень сайт интернет текст письмо \
        слово язык экран файл файлы папка папки игра игры город страна вопрос ответ \
        пример деньги телефон компьютер ноутбук мышь клавиатура окно окна дверь стол \
        стул еда вода чай кофе школа университет урок учитель студент делать сделать \
        говорить сказать знать думать хотеть видеть смотреть слушать слышать понимать \
        работать жить любить писать читать помочь помогать купить продать открыть \
        закрыть начать ждать найти потерять взять дать забыть помнить сидеть стоять \
        лежать бежать спать пить идти приехать уехать большой маленький новый старый \
        хороший плохой быстрый медленный красный белый черный синий зеленый желтый \
        первый второй третий последний лучший худший простой сложный серьезный смешной \
        умный глупый сильный слабый сегодня вчера завтра утром вечером сразу снова \
        опять обязательно вообще именно реально естественно йцукен йцукенг мудак \
        мудила дадут дадим дайте понял понятно сейчас короче согласен жаль бывает \
        проверка проверить проверю тест тесты чел крч щас изи спасибо еще нормально \
        нажимал сверху пишет сделал знаю видел анализ память логин админка автоматически \
        сука блять блядь нахуй пиздец пиздат хуй хуйня похуй ебать ебаный ебанутый пидор \
        пидорас мразь мразота уебок хуила заебал заебись охуел охуенно хуёво хуёвая бля \
        что это тебе тобой твой твоя твое твоего твоему моего моей которого которые \
        такого какого моему вашему нашего вашего никакого никакого каждого любого \
        него неё ними мочь могла могло делу деле года году годы лет дело поэтому \
        почему значит кстати давай давайте сколько зато однако либо буквально \
        подожди слушай молодец отлично супер жесть обидно ясно ура поздравляю \
        удачи здорово страшно интересно ок ой ай эй уж ум ух эх ах ей
        """

    static let enSrc = """
        the of and to in is are was were be been being have has had do does did will \
        would can could should may might must not no yes it its this that these those \
        with for from at by on about into over after before between out up down off \
        again then once here there when where why how all any both each few more most \
        other some such only own same so than too very one two three four five hello \
        hi hey thanks thank please sorry okay ok yeah yep nope lol wow oops world love \
        time work day night life home house friend friends best good bad new old big \
        small great little last first next long short make made want need know think \
        see look hear listen understand write read help open close start stop wait \
        find take give forget remember sit stand sleep eat drink run walk go come get \
        got say said tell ask answer question word text email phone message computer \
        laptop screen window file folder game games city country people man woman boy \
        girl name money water food room door table chair book page learn study play \
        watch send nice cool crazy funny boring easy hard real true false sure maybe \
        probably actually right wrong now later today tomorrow yesterday morning \
        evening just like know really qwerty who test tests ban tan win fail \
        fixed fixer bugfix \
        an as am we he me my us if or ah oh eh \
        what they them their which your yours whose whom mine ours myself himself \
        herself themselves done doing going getting saying week month year years \
        hour minutes seconds welcome awesome perfect excellent amazing terrible \
        horrible beautiful interesting important available document documents \
        project projects issue issues ticket commit branch merge release update \
        updates error errors better well done \
        ctrl alt shift esc del tab caps api sdk cli gui url ssh ssl sql css html json yaml \
        http https git npm pip app dev pro max min log cfg env var tmp msg btn img
        """

    static let ru: Set<String> = Make(ruSrc)
    static let en: Set<String> = Make(enSrc)

    /// Частотники OpenSubtitles (RU 35k / EN 20k) — WordData, покрывают живую лексику.
    static let ruBig: Set<String> = Make(WordData.ruAll)
    static let enBig: Set<String> = Make(WordData.enAll)

    /// Расширенное членство (WordDataHuge: топ 200k RU / 150k EN OpenSubtitles, ADR-003).
    /// Используется для подтверждения редких слов (при пройденном скоринге) и защиты
    /// cur-in-dict, но НЕ имеет права в одиночку пробивать скоринг через dict-over-score.
    static let ruHuge: Set<String> = Make(WordDataHuge.ruHugeAll)
    static let enHuge: Set<String> = Make(WordDataHuge.enHugeAll)

    /// Deny-list мусорных токенов из субтитровых корпусов ('iban' = клавиши «шифт»;
    /// 'gemin' = обрубок 'gemini', ломавший недописанное «пуьшт»).
    static let v3Removed: Set<String> = ["iban", "gemin"]

    /// Закрытый белый список частых 2-буквенных русских слов для безопасного авто-переворота
    /// при MinWordLen >= 3 (исключает случайные срабатывания вроде TV -> ЕМ, CV -> СМ).
    static let ruTwoLetterAuto: Set<String> = [
        "да", "не", "но", "он", "ты", "вы", "то", "за", "на", "по",
        "от", "из", "же", "бы", "ну", "ок", "ли", "ни", "до", "со",
        "во", "ко", "об", "уж", "ее", "ей", "им", "их", "ой",
    ]

    /// Защищённые 2-буквенные английские слова и IT-сокращения (никогда не конвертируются автоматически).
    static let enTwoLetterProtected: Set<String> = [
        "in", "on", "to", "no", "so", "it", "is", "at", "by", "or", "of",
        "as", "an", "am", "we", "he", "me", "my", "us", "if", "up", "do",
        "go", "be", "hi", "ok", "oh", "ah", "eh", "yo", "vs", "id", "ip",
        "os", "ui", "ux", "qa", "ai", "pr", "hr", "js", "ts", "py", "sh",
        "db", "ci", "cd", "vm", "ml", "dl", "cv", "tv", "pc", "io", "re", "cc",
    ]

    /// Однобуквенные слова языка (предлоги/союзы) — «неприкасаемые» Caramba.
    static let ruSingles = "аивкосуя"
    static let enSingles = "ai"

    public static func hasSingleLetterWord(_ ch: String, _ lang: Int) -> Bool {
        guard ch.count == 1, let c = ch.lowercased().first else { return false }
        return lang == 0 ? ruSingles.contains(c) : enSingles.contains(c)
    }

    /// Разрешён ли авто-переворот 2-буквенного слова (только однозначные EN->RU пары, не в ALL_CAPS).
    public static func isAllowedTwoLetterAuto(curText: String, bestCore: String, curLang: Int, bestLang: Int) -> Bool {
        guard curLang == 1, bestLang == 0 else { return false }
        let cLow = curText.lowercased()
        let bLow = bestCore.lowercased()
        guard cLow.count == 2, bLow.count == 2 else { return false }
        // Запрещаем 2-буквенный автофлип для ALL_CAPS (даже при включённом CapsLock: 'LF', 'TV', 'UI'),
        // но разрешаем заглавную первую букву в начале предложения ('Lf' -> 'Да').
        if curText == curText.uppercased() && curText != cLow { return false }
        if enTwoLetterProtected.contains(cLow) { return false }
        return ruTwoLetterAuto.contains(bLow)
    }

    static func Make(_ src: String) -> Set<String> {
        var set = Set<String>()
        let trimChars = CharacterSet(charactersIn: " \t\r\n[]'\",")
        for w in src.split(whereSeparator: { $0.isWhitespace || $0 == "," }) {
            let t = String(w).trimmingCharacters(in: trimChars).lowercased()
            if t.count >= 2 { set.insert(t) }
        }
        return set
    }

    /// Полное членство в словаре (ядро + 35k/20k + 200k/150k Huge).
    public static func has(_ word: String, _ lang: Int) -> Bool {
        if word.isEmpty { return false }
        let w = word.trimmingCharacters(in: .whitespaces).lowercased()
        if w.count < 2 || v3Removed.contains(w) { return false }
        if lang == 0 { return ru.contains(w) || ruBig.contains(w) || ruHuge.contains(w) }
        if lang == 1 { return en.contains(w) || enBig.contains(w) || enHuge.contains(w) }
        return false
    }

    /// Строгое ядро словаря (ручное ядро + чистый частотник 35k RU / 20k EN, БЕЗ Huge).
    /// Используется для `dict-over-score`, `dictNeighbor` и разблокировки `autoLocked`,
    /// чтобы шум из 350k субтитров не пробивал биграммный скоринг.
    public static func hasCore(_ word: String, _ lang: Int) -> Bool {
        if word.isEmpty { return false }
        let w = word.trimmingCharacters(in: .whitespaces).lowercased()
        return hasCoreNormalized(w, lang)
    }

    @inline(__always)
    private static func hasCoreNormalized(_ w: String, _ lang: Int) -> Bool {
        if w.count < 2 || v3Removed.contains(w) { return false }
        if lang == 0 { return ru.contains(w) || ruBig.contains(w) }
        if lang == 1 { return en.contains(w) || enBig.contains(w) }
        return false
    }

    private static let alphabets: [Int: [Character]] = [
        0: Array("абвгдеёжзийклмнопрстуфхцчшщъыьэюя"),
        1: Array("abcdefghijklmnopqrstuvwxyz"),
    ]

    /// Быстрый поиск словарного соседа для умного режима (< 0.1 мс, без аллокаций trim/lower):
    /// - dist 1 (от 4 букв): 1 замена, 1 пропуск буквы или 1 лишняя буква (от 5 букв)
    /// - dist 2 (от 5 букв): смежная транспозиция соседних букв ('првиет' -> 'привет', O(L)).
    /// Квадратичный перебор всех пар букв удалён (вешал поток тапа до 570 мс и давал ложные совпадения).
    public static func dictNeighbor(_ word: String, _ lang: Int, maxSubs: Int) -> (neighbor: String, dist: Int)? {
        let w = Array(word.lowercased())
        guard w.count >= 4, w.count <= 16, let alphabet = alphabets[lang] else { return nil }
        if maxSubs >= 1 {
            // 1) замена одной буквы
            var c = w
            for i in c.indices {
                let orig = c[i]
                for ch in alphabet where ch != orig {
                    c[i] = ch
                    let s = String(c)
                    if hasCoreNormalized(s, lang) { return (s, 1) }
                }
                c[i] = orig
            }
            // 2) пропуск одной буквы (вставка)
            for i in 0...w.count {
                for ch in alphabet {
                    var ins = w
                    ins.insert(ch, at: i)
                    let s = String(ins)
                    if hasCoreNormalized(s, lang) { return (s, 1) }
                }
            }
            // 3) лишняя буква (двойное нажатие, от 5 букв, чтобы 4-буквенный мусор не падал в 3-буквенные корни)
            if w.count >= 5 {
                for i in w.indices {
                    var del = w
                    del.remove(at: i)
                    let s = String(del)
                    if hasCoreNormalized(s, lang) { return (s, 1) }
                }
            }
        }
        if maxSubs >= 2, w.count >= 5 {
            // смежная транспозиция двух соседних букв ('првиет' -> 'привет') — O(L)
            var tr = w
            for i in 0..<(tr.count - 1) where tr[i] != tr[i + 1] {
                tr.swapAt(i, i + 1)
                let s = String(tr)
                if hasCoreNormalized(s, lang) { return (s, 2) }
                tr.swapAt(i, i + 1)
            }
        }
        return nil
    }
}
