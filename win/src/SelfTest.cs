using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using OpenSwitcher.Core;

namespace OpenSwitcher
{
    /// <summary>
    /// Автотест детектора: запускается через "OpenSwitcher.exe --selftest out.txt",
    /// не требует хуков и реальных раскладок (статические карты ЙЦУКЕН/QWERTY).
    /// </summary>
    public static class SelfTest
    {
        private class Case
        {
            public string Typed;      // что реально набрано на клавиатуре (символы текущей раскладки)
            public bool TypedIsRu;    // раскладка, в которой это набрано
            public bool ExpectConvert;
            public string Note;
            public bool Live;         // живое исправление (до пробела): цель обязана быть в словаре

            public Case(string typed, bool isRu, bool expect, string note, bool live = false)
            {
                Typed = typed; TypedIsRu = isRu; ExpectConvert = expect; Note = note; Live = live;
            }
        }

        public static int Run(string outPath)
        {
            try
            {
                return RunInner(outPath);
            }
            catch (Exception ex)
            {
                try { File.WriteAllText("os_selftest_crash.log", ex.ToString()); } catch (Exception) { }
                return 2;
            }
        }

        /// <summary>
        /// "OpenSwitcher.exe --simtest ghbdtn" — прогон строки через НАСТОЯЩИЕ установленные
        /// раскладки (ToUnicodeEx) с печатью скоров. Без хуков и без инжекции ввода.
        /// </summary>
        public static int Simulate(string typed, double sensitivity)
        {
            List<KeyRec> keys = BuildKeys(typed, false);
            if (keys.Count == 0)
            {
                Console.WriteLine("unknown characters");
                return 2;
            }
            List<IntPtr> layouts = LayoutService.GetLayouts();
            Console.WriteLine("layouts: " + layouts.Count);
            List<LayoutCandidate> cands = LayoutService.RenderAll(keys, layouts);
            foreach (LayoutCandidate c in cands)
                Console.WriteLine(string.Format("  {0}: '{1}' lang={2} score={3:F3}",
                    c.Name, c.Text, c.Lang, c.Score));
            if (cands.Count < 2)
            {
                Console.WriteLine("only one layout installed - nothing to decide");
                return 0;
            }
            LayoutCandidate cur = cands[0];
            LayoutCandidate best = null;
            foreach (LayoutCandidate c in cands)
            {
                if (c.Hkl == cur.Hkl || c.Lang < 0) continue;
                if (best == null || c.Score > best.Score) best = c;
            }
            if (best == null) { Console.WriteLine("no candidate"); return 0; }
            bool conv = LanguageTables.ShouldConvert(cur.Text, cur.Lang, cur.Score,
                                                     best.Text, best.Lang, best.Score, sensitivity);
            Console.WriteLine(conv
                ? "DECISION: convert '" + cur.Text + "' -> '" + best.Text + "' (" + best.Name + ")"
                : "DECISION: keep '" + cur.Text + "'");
            return conv ? 0 : 0;
        }

        private static int RunInner(string outPath)
        {
            var cases = new List<Case>
            {
                new Case("ghbdtn", false, true,  "привет"),
                new Case("руддщ",  true,  true,  "hello"),
                new Case("hello",  false, false, "уже английское"),
                new Case("привет", true,  false, "уже русское"),
                new Case("ntcn",   false, true,  "текст"),
                new Case("црщ",    true,  true,  "who"),
                new Case("world",  false, false, "уже английское"),
                new Case("знает",  true,  false, "уже русское"),
                new Case("qwerty", false, true,  "йцукен (клавиатурный ряд)"),
                new Case("qwe",    false, false, "двусмысленно, коротко"),
                new Case("bd",     false, false, "слишком коротко"),
                new Case("quit",   false, false, "настоящее английское слово"),
                new Case("дадут",  true,  false, "русское слово не превращать в lflen"),
                new Case("муд",    true,  false, "живое: 'vel' не словарное — не трогаем", true),
                new Case("ghbdtn", false, true,  "живое: привет в словаре — перевернём", true),
                new Case("что",    true,  false, "частое русское: цель 'xnj' не словарная, не трогаем"),
                new Case("xnj",    false, true,  "цель 'что' словарная, набранное нет — словарь сильнее скоринга"),
                new Case("кфп",    true,  true,  "мусор (rag в EN) -> словарное 'rag': короткий гейт пускает"),
                new Case("еще",    true,  false, "короткое правильное русское — гейт не пускает")
            };

            var sb = new StringBuilder();
            int fails = 0;
            foreach (Case c in cases)
            {
                List<KeyRec> keys = BuildKeys(c.Typed, c.TypedIsRu);
                if (keys.Count < 3)
                {
                    sb.AppendLine(string.Format("{0}: '{1}' ({2}) — короче MinLen, не трогаем: {3}",
                        "PASS", c.Typed, c.TypedIsRu ? "ru" : "en", c.Note));
                    continue;
                }

                // два "фейковых" варианта прочтения: как набрано и в другой раскладке
                string curText = c.TypedIsRu ? c.Typed : c.Typed;
                string altText = MapAll(c.Typed, c.TypedIsRu);
                int curLang = c.TypedIsRu ? 0 : 1;
                int altLang = c.TypedIsRu ? 1 : 0;
                double curScore = LanguageTables.Score(LanguageTables.LettersOnly(curText), curLang);
                double altScore = LanguageTables.Score(LanguageTables.LettersOnly(altText), altLang);
                bool convert;
                if (c.Live && !WordDict.HasCore(altText, altLang))
                {
                    convert = false; // живое исправление — только в основные словарные слова
                }
                else
                {
                    convert = LanguageTables.ShouldConvert(curText, curLang, curScore,
                                                            altText, altLang, altScore, 1.0);
                    bool targetInDict = WordDict.HasCore(altText, altLang);
                    bool curInDict = WordDict.Has(curText, curLang);
                    if (convert && curInDict && !targetInDict) convert = false;
                    if (!convert && targetInDict && !curInDict) convert = true;
                }
                bool pass = convert == c.ExpectConvert;
                if (!pass) fails++;
                sb.AppendLine(string.Format("{0}: '{1}' ({2}) -> '{3}' [{4}] {5}  cur={6:F2} alt={7:F2}  ({8})",
                    pass ? "PASS" : "FAIL", c.Typed, c.TypedIsRu ? "ru" : "en", altText,
                    convert ? "CONVERT" : "keep", pass ? "" : "!!", curScore, altScore, c.Note));
            }

            // ретро-флип одиночной буквы перед сконвертированным словом ('f␣ns' -> «а ты»):
            // только «не-слово своего языка» -> «однобуквенное слово языка цели»
            var retro = new[]
            {
                new object[] { "f", 1, "а", 0, true,  "f -> союз а" },
                new object[] { "F", 1, "А", 0, true,  "заглавная в начале фразы" },
                new object[] { "b", 1, "и", 0, true,  "b -> союз и" },
                new object[] { "d", 1, "в", 0, true,  "d -> предлог в" },
                new object[] { "z", 1, "я", 0, true,  "z -> я" },
                new object[] { "x", 1, "ч", 0, false, "ч — не слово" },
                new object[] { "a", 1, "ф", 0, false, "a — английское слово, неприкосновенно" },
                new object[] { "i", 1, "ш", 0, false, "i — английское слово, неприкосновенно" },
                new object[] { "ф", 0, "a", 1, true,  "ф -> a" },
                new object[] { "ш", 0, "i", 1, true,  "ш -> i" },
                new object[] { "в", 0, "d", 1, false, "в — русское слово, неприкосновенно" },
                new object[] { ",", 1, "б", 0, false, "знак — не буква" }
            };
            foreach (object[] r in retro)
            {
                bool got = Engine.RetroFlipLetterOk((string)r[0], (int)r[1], (string)r[2], (int)r[3]);
                bool pass = got == (bool)r[4];
                if (!pass) fails++;
                sb.AppendLine(string.Format("{0}: retro '{1}' -> '{2}' [{3}] {4} ({5})",
                    pass ? "PASS" : "FAIL", r[0], r[2], got ? "FLIP" : "keep", pass ? "" : "!!", r[5]));
            }

            // форма цели авто-замены: буквы ИЛИ буквы + один знак в конце; знак внутри — мусор
            var shapes = new[]
            {
                new object[] { "привет",  true,  "только буквы" },
                new object[] { "привет,", true,  "буквы + знак в конце" },
                new object[] { "тебя.",   true,  "хвост-двойник точкой" },
                new object[] { "et,e",    false, "знак внутри (русское слово с «б») — мусор" },
                new object[] { "le,rf[",  false, "знаки внутри и в конце" },
                new object[] { "e,,",     false, "два знака в конце" },
                new object[] { ",",       false, "без букв" }
            };
            foreach (object[] r in shapes)
            {
                bool got = Engine.TargetShapeOk((string)r[0]);
                bool pass = got == (bool)r[1];
                if (!pass) fails++;
                sb.AppendLine(string.Format("{0}: shape '{1}' [{2}] {3} ({4})",
                    pass ? "PASS" : "FAIL", r[0], got ? "ok" : "reject", pass ? "" : "!!", r[2]));
            }

            // словарь членства (ADR-003) + deny-list v3/v4 + умный режим (СПЕКА §5 11а)
            var dictChecks = new[]
            {
                new object[] { "перкуссия", 0, true,  "huge: редкое RU-слово в словаре" },
                new object[] { "callback",  1, true,  "huge: редкое EN-слово в словаре" },
                new object[] { "iban",      1, false, "deny-list v3: RU-прочтение с клавиш = «шифт»" },
                new object[] { "gemin",     1, false, "deny-list v4: шум из субтитров" },
                new object[] { "vel",       1, false, "3-буквенный мусор субтитров — не член (мин. 4 буквы)" }
            };
            foreach (object[] r in dictChecks)
            {
                bool got = WordDict.Has((string)r[0], (int)r[1]);
                bool pass = got == (bool)r[2];
                if (!pass) fails++;
                sb.AppendLine(string.Format("{0}: dict '{1}' [{2}] {3} ({4})",
                    pass ? "PASS" : "FAIL", r[0], got ? "в словаре" : "нет", pass ? "" : "!!", r[3]));
            }
            int fuzzyDist;
            string fuzzyNeighbor = WordDict.DictNeighbor("смоьри", 0, 2, out fuzzyDist);
            bool fuzzyPass = fuzzyNeighbor != null && fuzzyDist == 1;
            if (!fuzzyPass) fails++;
            sb.AppendLine(string.Format("{0}: fuzzy 'смоьри' ~= '{1}' dist{2} ({3})",
                fuzzyPass ? "PASS" : "FAIL", fuzzyNeighbor ?? "-", fuzzyDist, "умный режим: сосед на дистанции 1"));
            int transDist;
            string transNeighbor = WordDict.DictNeighbor("првиет", 0, 2, out transDist);
            bool transPass = transNeighbor != null && transDist == 2;
            if (!transPass) fails++;
            sb.AppendLine(string.Format("{0}: fuzzy 'првиет' ~= '{1}' dist{2} ({3})",
                transPass ? "PASS" : "FAIL", transNeighbor ?? "-", transDist, "смежная транспозиция = 2 замены"));
            int arb2Dist;
            string arb2Neighbor = WordDict.DictNeighbor("пкивед", 0, 2, out arb2Dist);
            bool arb2Pass = arb2Neighbor == null;
            if (!arb2Pass) fails++;
            sb.AppendLine(string.Format("{0}: fuzzy 'пкивед' == null ({1})",
                arb2Pass ? "PASS" : "FAIL", "2 произв. замены отклонены O(L)"));
            int skipDist;
            string skipNeighbor = WordDict.DictNeighbor("смотр", 0, 2, out skipDist);
            bool skipPass = skipNeighbor != null && skipDist == 1;
            if (!skipPass) fails++;
            sb.AppendLine(string.Format("{0}: fuzzy 'смотр' ~= '{1}' dist{2} ({3})",
                skipPass ? "PASS" : "FAIL", skipNeighbor ?? "-", skipDist, "пропуск буквы = вставка"));
            int extraDist;
            string extraNeighbor = WordDict.DictNeighbor("смоотри", 0, 2, out extraDist);
            bool extraPass = extraNeighbor != null && extraDist == 1;
            if (!extraPass) fails++;
            sb.AppendLine(string.Format("{0}: fuzzy 'смоотри' ~= '{1}' dist{2} ({3})",
                extraPass ? "PASS" : "FAIL", extraNeighbor ?? "-", extraDist, "лишняя буква = удаление"));

            // защиты Фазы 4: HasCore, 2-буквенный whitelist, ALL_CAPS, camelCase, цифры
            var v4Checks = new[]
            {
                new object[] { "core: 'api' в HasCore", WordDict.HasCore("api", 1), true },
                new object[] { "core: 'перкуссия' НЕ в HasCore", WordDict.HasCore("перкуссия", 0), false },
                new object[] { "2-let: 'lf' -> 'да' разрешён", WordDict.IsAllowedTwoLetterAuto("lf", "да", 1, 0), true },
                new object[] { "2-let: 'LF' (CAPS) запрещён", WordDict.IsAllowedTwoLetterAuto("LF", "да", 1, 0), false },
                new object[] { "2-let: 'tv' -> 'ем' запрещён", WordDict.IsAllowedTwoLetterAuto("tv", "ем", 1, 0), false },
                new object[] { "2-let: 'in' -> 'шт' запрещён", WordDict.IsAllowedTwoLetterAuto("in", "шт", 1, 0), false },
                new object[] { "caps: 'TV' = акроним", Engine.IsAllCapsAcronym(BuildKeys("TV", false)), true },
                new object[] { "caps: 'Ghbdtn' != акроним", Engine.IsAllCapsAcronym(BuildKeys("Ghbdtn", false)), false },
                new object[] { "camel: 'JoeSnow' = camelCase", Engine.HasCamelCaseTransition(BuildKeys("JoeSnow", false)), true },
                new object[] { "camel: 'iPhone' = camelCase", Engine.HasCamelCaseTransition(BuildKeys("iPhone", false)), true },
                new object[] { "camel: 'GHbdtn' != camelCase", Engine.HasCamelCaseTransition(BuildKeys("GHbdtn", false)), false },
                new object[] { "sep: голая '7' не сепаратор", Engine.IsSeparatorVk(0x37, false), false },
                new object[] { "sep: Shift+'7' сепаратор", Engine.IsSeparatorVk(0x37, true), true },
                new object[] { "punct: 'here.' в EN словаре", WordDict.Has(LanguageTables.LettersOnly("here."), 1), true },
                new object[] { "punct: 'keys.' в EN словаре", WordDict.Has(LanguageTables.LettersOnly("keys."), 1), true },
                new object[] { "punct: 'her,' в EN словаре", WordDict.Has(LanguageTables.LettersOnly("her,"), 1), true },
                new object[] { "2-let: 'it.' защищено", WordDict.IsAllowedTwoLetterAuto("it", "ше", 1, 0), false },
                new object[] { "2-let: 'vs.' защищено", WordDict.IsAllowedTwoLetterAuto("vs", "мы", 1, 0), false },
                new object[] { "2-let: 'Lf!' -> 'Да!' допустимо", WordDict.IsAllowedTwoLetterAuto("Lf", "Да", 1, 0) && Engine.TargetShapeOk("Да!"), true },
                new object[] { "domain: 'main.py' защищён", Engine.IsDomainOrFileName("main.py"), true },
                new object[] { "domain: 'vk.ru' защищён", Engine.IsDomainOrFileName("vk.ru"), true },
                new object[] { "domain: 'ghbdtn.' не домен", Engine.IsDomainOrFileName("ghbdtn."), false },
                new object[] { "shape: 'какой-то' валидно", Engine.TargetShapeOk("какой-то"), true },
                new object[] { "shape: '--help' отклонён", Engine.TargetShapeOk("--help"), false },
                new object[] { "shape: '-rf' отклонён", Engine.TargetShapeOk("-rf"), false },
                new object[] { "shift-map: :<>\"{}~ -> ЖБЮЭХЪЁ", CharMaps.MapText(":<>\"{}~", true) == "ЖБЮЭХЪЁ", true },
                new object[] { "shift-map: ЖБЮЭХЪЁ -> :<>\"{}~", CharMaps.MapText("ЖБЮЭХЪЁ", false) == ":<>\"{}~", true },
                new object[] { "vk: 'б' -> 0xBC", CharMaps.VkOfChar('б', true) == 0xBC, true },
                new object[] { "caps: 'XNJ' RU-ядро 'что'", WordDict.HasCore("что", 0) && !WordDict.HasCore("xnj", 1), true },
                new object[] { "caps: 'YTN' RU-ядро 'нет'", WordDict.HasCore("нет", 0) && !WordDict.HasCore("ytn", 1), true },
                new object[] { "caps: 'GJRF' RU-ядро 'пока'", WordDict.HasCore("пока", 0) && !WordDict.HasCore("gjrf", 1), true },
                new object[] { "caps: 'API' EN акроним", Engine.IsAllCapsAcronym(BuildKeys("API", false)) && WordDict.HasCore("api", 1) && !WordDict.HasCore("фзш", 0), true },
                new object[] { "caps: 'SQL' EN акроним", Engine.IsAllCapsAcronym(BuildKeys("SQL", false)) && !WordDict.HasCore("ыйд", 0), true }
            };
            foreach (object[] r in v4Checks)
            {
                bool got = (bool)r[1];
                bool pass = got == (bool)r[2];
                if (!pass) fails++;
                sb.AppendLine(string.Format("{0}: [v4] {1} {2}",
                    pass ? "PASS" : "FAIL", r[0], pass ? "" : "!!"));
            }

            // Инвертированный CapsLock ('gHBDTN') и переполнение WordBuffer (>40)
            var capsKeys = new List<KeyRec>();
            string capsSample = "ghbdtn";
            for (int i = 0; i < capsSample.Length; i++)
                capsKeys.Add(new KeyRec(CharMaps.VkOfChar(capsSample[i], false), i == 0, true));
            bool capsPass = !Engine.HasCamelCaseTransition(capsKeys);
            if (!capsPass) fails++;
            sb.AppendLine(string.Format("{0}: camel 'gHBDTN' (Caps+Shift) != camelCase {1}",
                capsPass ? "PASS" : "FAIL", capsPass ? "" : "!!"));

            var wb = new WordBuffer();
            for (int i = 0; i < 40; i++) wb.Push(new KeyRec(0x41, false, false));
            bool wb40 = wb.Count == 40 && !wb.Overflowed;
            wb.Push(new KeyRec(0x41, false, false));
            bool wb41 = wb.Count == 0 && wb.Overflowed;
            wb.Clear();
            bool wbClr = wb.Count == 0 && !wb.Overflowed;
            bool wbPass = wb40 && wb41 && wbClr;
            if (!wbPass) fails++;
            sb.AppendLine(string.Format("{0}: WordBuffer overflow >40 & clear {1}",
                wbPass ? "PASS" : "FAIL", wbPass ? "" : "!!"));

            // сверка скопированного с ожидаемым словом паст-конверта (бой 02:08/03:02 06.11:
            // гонка печати/реплея подсовывает чужой текст — вставлять нельзя)
            var selExpectChecks = new[]
            {
                new object[] { "lf ",  "lf", true,  "своё слово с хвостовым пробелом" },
                new object[] { "да ",  "lf", false, "чужой текст (десинк раскладки) — отказ" },
                new object[] { null,   "lf", false, "пустое чтение — отказ" },
                new object[] { "lf",   null, true,  "ручной sel-флоу без ожидания — сверять не с чем" }
            };
            foreach (object[] r in selExpectChecks)
            {
                bool got = Engine.SelMatchesExpect((string)r[0], (string)r[1]);
                bool pass = got == (bool)r[2];
                if (!pass) fails++;
                sb.AppendLine(string.Format("{0}: sel-expect '{1}' vs '{2}' [{3}] {4} ({5})",
                    pass ? "PASS" : "FAIL", r[0] ?? "-", r[1] ?? "-", got ? "ok" : "reject", pass ? "" : "!!", r[3]));
            }

            sb.AppendLine(fails == 0 ? "ALL TESTS PASSED" : fails + " TEST(S) FAILED");
            try
            {
                File.WriteAllText(outPath, sb.ToString());
            }
            catch (Exception) { }
            // winexe без консоли (CI/старт из explorer): первый Write бросает
            // IOException «handle is invalid» и валил самотест ДО записи файла —
            // гейт build.cmd видел exit 2 без единой строки диагностики
            try { Console.Write(sb.ToString()); } catch (Exception) { }
            return fails == 0 ? 0 : 1;
        }

        private static List<KeyRec> BuildKeys(string typed, bool isRu)
        {
            var keys = new List<KeyRec>();
            foreach (char ch in typed)
            {
                int vk = CharMaps.VkOfChar(ch, isRu);
                if (vk == 0) return new List<KeyRec>(); // незнакомый символ — тест неприменим
                keys.Add(new KeyRec(vk, char.IsUpper(ch), false));
            }
            return keys;
        }

        /// <summary>Как эта же последовательность клавиш выглядит в другой раскладке.</summary>
        private static string MapAll(string typed, bool fromRu)
        {
            var sb = new StringBuilder();
            foreach (char ch in typed.ToLowerInvariant())
            {
                int i = fromRu ? CharMaps.Ru.IndexOf(ch) : CharMaps.En.IndexOf(ch);
                if (i < 0) { sb.Append('?'); continue; }
                sb.Append(fromRu ? CharMaps.En[i] : CharMaps.Ru[i]);
            }
            return sb.ToString();
        }
    }
}
