using System;
using System.Collections.Generic;

namespace OpenSwitcher.Core
{
    /// <summary>
    /// Компактные списки частых слов (RU/EN) для валидации решений конвертации.
    /// Не словарь в лингвистическом смысле — «якорь уверенности»: если результат
    /// конвертации оказался частым словом — решение надёжно; если текущее слово
    /// частое, а результат нет — конвертация сомнительна.
    /// </summary>
    public static class WordDict
    {
        private const string RuSrc =
            "и в не на я он с как а то все она так его но да ты к у же вы за бы по только ее мне " +
            "было вот от меня еще нет о из ему теперь когда даже ну вдруг ли если уже или ни до " +
            "вас уж вам ведь там потом себя ничего ей может они тут где есть надо ней для мы " +
            "тебя их чем была сам чтоб без будто чего раз тоже себе под будет тогда кто этот " +
            "потому этого какой совсем ним здесь этом один почти мой тем чтобы сейчас были куда " +
            "зачем всех никогда можно при наконец два об другой хоть после над больше тот через " +
            "эти нас про всего них какая много три эту моя впрочем хорошо свою этой перед " +
            "иногда лучше нельзя такой им более всегда конечно всю между привет пока спасибо " +
            "пожалуйста извини извините ладно окей блин жаль точно наверное возможно кажется " +
            "вроде просто очень мало меньше самое самый весь вся нормальный нормально круто " +
            "класс ужас страшно смешно скучно время человек день ночь жизнь работа дом друг " +
            "друзья мама папа брат сестра семья девушка парень сайт интернет текст письмо " +
            "слово язык экран файл файлы папка папки игра игры город страна вопрос ответ " +
            "пример деньги телефон компьютер ноутбук мышь клавиатура окно окна дверь стол " +
            "стул еда вода чай кофе школа университет урок учитель студент делать сделать " +
            "говорить сказать знать думать хотеть видеть смотреть слушать слышать понимать " +
            "работать жить любить писать читать помочь помогать купить продать открыть " +
            "закрыть начать ждать найти потерять взять дать забыть помнить сидеть стоять " +
            "лежать бежать спать пить идти приехать уехать большой маленький новый старый " +
            "хороший плохой быстрый медленный красный белый черный синий зеленый желтый " +
            "первый второй третий последний лучший худший простой сложный серьезный смешной " +
            "умный глупый сильный слабый сегодня вчера завтра утром вечером сразу снова " +
            "опять обязательно вообще именно реально естественно йцукен йцукенг мудак " +
            "мудила дадут дадим дайте понял понятно сейчас короче согласен жаль бывает " +
            "проверка проверить проверю тест тесты чел крч щас изи спасибо еще нормально " +
            // топ частотных слов, отсутствие которых давало ложные конвертации
            // ('что'->'xnj', 'твоему'->'ndjtve'): защита cur-in-dict их не спасала
            // частотные формы из реальных логов пропусков ('нажимал'->'yf;bvfk' и т.п.)
            "нажимал сверху пишет сделал знаю видел анализ память логин админка автоматически " +
            // живой лексикон (из логов: 'сука'->'cerf', 'блять'->',kznm' — без них
            // target-not-in-dict блокировал конвертацию самых частых слов юзера)
            "сука блять блядь нахуй пиздец пиздат хуй хуйня похуй ебать ебаный ебанутый пидор " +
            "пидорас мразь мразота уебок хуила заебал заебись охуел охуенно хуёво хуёвая бля " +
            "что это тебе тобой твой твоя твое твоего твоему моего моей которого которые " +
            "такого какого моему вашему нашего вашего никакого никакого каждого любого " +
            "него неё ними мочь могла могло делу деле года году годы лет дело поэтому " +
            "почему значит кстати давай давайте сколько зато однако либо буквально " +
            "подожди слушай молодец отлично супер жесть обидно ясно ура поздравляю " +
            "удачи здорово страшно интересно ок ой ай эй уж ум ух эх ах ей";

        private const string EnSrc =
            "the of and to in is are was were be been being have has had do does did will " +
            "would can could should may might must not no yes it its this that these those " +
            "with for from at by on about into over after before between out up down off " +
            "again then once here there when where why how all any both each few more most " +
            "other some such only own same so than too very one two three four five hello " +
            "hi hey thanks thank please sorry okay ok yeah yep nope lol wow oops world love " +
            "time work day night life home house friend friends best good bad new old big " +
            // 'iban' удалён: его RU-прочтение с клавиш — «шифт», и слово «шифт»
            // переворачивалось в 'iban' при каждом правильном наборе
            "really qwerty who test tests ban tan win fail " +
            "small great little last first next long short make made want need know think " +
            "see look hear listen understand write read help open close start stop wait " +
            "find take give forget remember sit stand sleep eat drink run walk go come get " +
            "got say said tell ask answer question word text email phone message computer " +
            "laptop screen window file folder game games city country people man woman boy " +
            "girl name money water food room door table chair book page learn study play " +
            "watch send nice cool crazy funny boring easy hard real true false sure maybe " +
            "probably actually right wrong now later today tomorrow yesterday morning " +
            "evening just like know really qwerty who test tests ban tan win fail " +
            "fixed fixer bugfix " +
            // двухбуквенные местоимения/предлоги/союзы: без них 2-буквенный порог
            // переворачивал бы 'he'->'не', 'me'->'ьу', 'we'->'це' при нормальном EN
            "an as am we he me my us if or ah oh eh " +
            // частотные, без которых не срабатывало исправление в обратную сторону
            // (живой режим требует, чтобы цель была словарной)
            "what they them their which your yours whose whom mine ours myself himself " +
            "herself themselves done doing going getting saying week month year years " +
            "hour minutes seconds welcome awesome perfect excellent amazing terrible " +
            "horrible beautiful interesting important available document documents " +
            "project projects issue issues ticket commit branch merge release update " +
            "updates error errors better well done " +
            // клавиатурные сокращения и частые IT-токены: юзер пишет их в чатах/коде,
            // чтобы обратный переворот срабатывал, а набранные в EN не считались несловарными
            "ctrl alt shift esc del tab caps " +
            "api sdk cli gui url ssh ssl sql css html json yaml http https git npm pip " +
            "app dev pro max min log cfg env var tmp msg btn img";

        private static readonly HashSet<string> Ru = Make(RuSrc);
        private static readonly HashSet<string> En = Make(EnSrc);

        // Частотные словари OpenSubtitles (топ-35k RU / топ-20k EN) — сгенерированы
        // в WordData.cs; покрывают живую разговорную лексику и формы слов
        private static readonly HashSet<string> RuBig = Make(WordData.RuAll);
        private static readonly HashSet<string> EnBig = Make(WordData.EnAll);

        /// <summary>Расширенное МЕМБЕРСТВО (WordDataHuge: топ 200k RU / 150k EN, ADR-003).
        /// На PossibleWord не влияет — биграммы только из WordData.</summary>
        private static readonly HashSet<string> RuHuge = Make(WordDataHuge.RuHugeAll);
        private static readonly HashSet<string> EnHuge = Make(WordDataHuge.EnHugeAll);

        private static HashSet<string> Make(string src)
        {
            var set = new HashSet<string>(StringComparer.InvariantCultureIgnoreCase);
            char[] trimChars = new[] { ' ', '\t', '\r', '\n', '[', ']', '\'', '"', ',' };
            foreach (string w in src.Split(new[] { ' ', '\t', '\r', '\n', ',' }, StringSplitOptions.RemoveEmptyEntries))
            {
                string t = w.Trim(trimChars);
                if (t.Length >= 2) set.Add(t.ToLowerInvariant());
            }
            return set;
        }

        /// <summary>Решения v3/v4 — исключены навсегда (расширения словаря их не возвращают):
        /// 'iban' — RU-прочтение с тех же клавиш = «шифт» (96f7c2b);
        /// 'gemin' — шум из субтитров, блокировавший опечатку в 'gemini'.</summary>
        private static readonly HashSet<string> V3Removed = new HashSet<string> { "iban", "gemin" };

        /// <summary>Закрытый белый список частых русских 2-буквенных слов, разрешённых к авто-конвертации
        /// из EN->RU при MinWordLen = 3 (только если их EN-прочтение не является английским словом/сокращением).</summary>
        private static readonly HashSet<string> RuTwoLetterAuto = Make(
            "не на да но ты мы вы он же бы то ли ну ни до из за от по со во об ко ее ей им их уж ой ай эй ух ах ох"
        );

        /// <summary>Двухбуквенные EN-слова и частые IT-сокращения, которые НИКОГДА не авто-конвертируем в RU.</summary>
        private static readonly HashSet<string> EnTwoLetterProtected = Make(
            "am an as at be by do go he hi id if in io ip is it js me my no of oh ok on or os pc pr qa re so to tv ui uk up us vm vs we ux ai hr ts py sh db ci cd ml dl cv cc"
        );

        /// <summary>Разрешён ли авто-переворот 2-буквенного слова (только однозначные EN->RU пары, не в ALL_CAPS).</summary>
        public static bool IsAllowedTwoLetterAuto(string curText, string bestCore, int curLang, int bestLang)
        {
            if (curLang != 1 || bestLang != 0) return false;
            if (string.IsNullOrEmpty(curText) || string.IsNullOrEmpty(bestCore)) return false;
            string cLow = curText.ToLowerInvariant();
            string bLow = bestCore.ToLowerInvariant();
            if (cLow.Length != 2 || bLow.Length != 2) return false;
            if (curText == curText.ToUpperInvariant() && curText != cLow) return false;
            if (EnTwoLetterProtected.Contains(cLow)) return false;
            return RuTwoLetterAuto.Contains(bLow);
        }

        public static bool Has(string word, int lang)
        {
            if (string.IsNullOrEmpty(word)) return false;
            string w = word.Trim().ToLowerInvariant();
            if (w.Length < 2) return false;
            if (V3Removed.Contains(w)) return false;
            if (lang == 0) return Ru.Contains(w) || RuBig.Contains(w) || RuHuge.Contains(w);
            if (lang == 1) return En.Contains(w) || EnBig.Contains(w) || EnHuge.Contains(w);
            return false;
        }

        /// <summary>Строгое ядро словаря (ручное ядро + чистый частотник 35k RU / 20k EN, БЕЗ Huge).
        /// Используется для dict-over-score, DictNeighbor и разблокировки autoLocked,
        /// чтобы шум из 350k субтитров не пробивал биграммный скоринг.</summary>
        public static bool HasCore(string word, int lang)
        {
            if (string.IsNullOrEmpty(word)) return false;
            string w = word.Trim().ToLowerInvariant();
            return HasCoreNormalized(w, lang);
        }

        private static bool HasCoreNormalized(string w, int lang)
        {
            if (w.Length < 2 || V3Removed.Contains(w)) return false;
            if (lang == 0) return Ru.Contains(w) || RuBig.Contains(w);
            if (lang == 1) return En.Contains(w) || EnBig.Contains(w);
            return false;
        }

        private static readonly Dictionary<int, char[]> Alphabets = new Dictionary<int, char[]>
        {
            { 0, "абвгдеёжзийклмнопрстуфхцчшщъыьэюя".ToCharArray() },
            { 1, "abcdefghijklmnopqrstuvwxyz".ToCharArray() },
        };

        /// <summary>Быстрый поиск словарного соседа для умного режима (O(L), без лагов хука):
        /// - dist 1 (от 4 букв): 1 замена, 1 пропуск буквы или 1 лишняя буква (от 5 букв);
        /// - dist 2 (от 5 букв): смежная транспозиция соседних букв ('првиет' -> 'привет').
        /// ВНИМАНИЕ: сборка — легаси csc .NET 4.0 (C# 5): без туплов, out var, ?. и интерполяции.</summary>
        public static string DictNeighbor(string word, int lang, int maxSubs, out int dist)
        {
            dist = 0;
            if (string.IsNullOrEmpty(word)) return null;
            string w = word.Trim().ToLowerInvariant();
            if (w.Length < 4 || w.Length > 16) return null;
            char[] alphabet;
            if (!Alphabets.TryGetValue(lang, out alphabet)) return null;
            char[] chars = w.ToCharArray();
            if (maxSubs >= 1)
            {
                // 1) замена одной буквы
                for (int i = 0; i < chars.Length; i++)
                {
                    char orig = chars[i];
                    for (int a = 0; a < alphabet.Length; a++)
                    {
                        char ch = alphabet[a];
                        if (ch == orig) continue;
                        chars[i] = ch;
                        string candidate = new string(chars);
                        if (HasCoreNormalized(candidate, lang)) { chars[i] = orig; dist = 1; return candidate; }
                    }
                    chars[i] = orig;
                }
                // 2) пропуск буквы (недожал): вставка одной буквы ('смотр' + 'и')
                char[] ins = new char[chars.Length + 1];
                for (int i = 0; i <= chars.Length; i++)
                {
                    if (i > 0) Array.Copy(chars, 0, ins, 0, i);
                    if (i < chars.Length) Array.Copy(chars, i, ins, i + 1, chars.Length - i);
                    for (int a = 0; a < alphabet.Length; a++)
                    {
                        ins[i] = alphabet[a];
                        string candidate = new string(ins);
                        if (HasCoreNormalized(candidate, lang)) { dist = 1; return candidate; }
                    }
                }
                // 3) лишняя буква (дважды нажал, от 5 букв): удаление одной
                if (chars.Length >= 5)
                {
                    for (int i = 0; i < chars.Length; i++)
                    {
                        string candidate = w.Remove(i, 1);
                        if (HasCoreNormalized(candidate, lang)) { dist = 1; return candidate; }
                    }
                }
            }
            // 4) смежная транспозиция соседних букв ('првиет' -> 'привет', O(L))
            if (maxSubs >= 2 && chars.Length >= 5)
            {
                for (int i = 0; i + 1 < chars.Length; i++)
                {
                    if (chars[i] == chars[i + 1]) continue;
                    char tmp = chars[i];
                    chars[i] = chars[i + 1];
                    chars[i + 1] = tmp;
                    string candidate = new string(chars);
                    chars[i + 1] = chars[i];
                    chars[i] = tmp;
                    if (HasCoreNormalized(candidate, lang)) { dist = 2; return candidate; }
                }
            }
            return null;
        }

        // однобуквенные слова языка (предлоги/союзы/местоимения) — Caramba «неприкасаемые»
        private const string RuSingles = "аивкосуя";
        private const string EnSingles = "ai";

        /// <summary>Однобуквенное слово языка: «а», «и», «в»… / "a", "i".
        /// Главный сигнал для одиночных букв: 'f' — не слово, «а» — слово.</summary>
        public static bool HasSingleLetterWord(string ch, int lang)
        {
            if (string.IsNullOrEmpty(ch) || ch.Length != 1) return false;
            string c = ch.Trim().ToLowerInvariant();
            if (c.Length != 1) return false;
            return lang == 0 ? RuSingles.Contains(c) : EnSingles.Contains(c);
        }
    }
}
