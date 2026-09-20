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
        удачи здорово страшно интересно
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
        updates error errors better well done
        """

    static let ru: Set<String> = Make(ruSrc)
    static let en: Set<String> = Make(enSrc)

    /// Частотники OpenSubtitles (RU 35k / EN 20k) — WordData, покрывают живую лексику
    static let ruBig: Set<String> = Make(WordData.ruAll)
    static let enBig: Set<String> = Make(WordData.enAll)

    /// Однобуквенные слова языка (предлоги/союзы) — «неприкасаемые» Caramba
    static let ruSingles = "аивкосуя"
    static let enSingles = "ai"

    /// Однобуквенное слово языка: «а», «и», «в»… / "a", "i".
    /// Главный сигнал одиночных букв: 'f' — не слово, «а» — слово.
    public static func hasSingleLetterWord(_ ch: String, _ lang: Int) -> Bool {
        guard ch.count == 1, let c = ch.lowercased().first else { return false }
        return lang == 0 ? ruSingles.contains(c) : enSingles.contains(c)
    }

    static func Make(_ src: String) -> Set<String> {
        var set = Set<String>()
        for w in src.split(separator: " ") {
            let t = w.trimmingCharacters(in: .whitespaces).lowercased()
            if t.count >= 2 { set.insert(t) }
        }
        return set
    }

    /// Есть ли слово в словаре языка: 0 = ru, 1 = en.
    public static func has(_ word: String, _ lang: Int) -> Bool {
        if word.isEmpty { return false }
        let w = word.trimmingCharacters(in: .whitespaces).lowercased()
        if w.count < 2 { return false }
        if lang == 0 { return ru.contains(w) || ruBig.contains(w) }
        if lang == 1 { return en.contains(w) || enBig.contains(w) }
        return false
    }
}
