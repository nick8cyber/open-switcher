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
                new Case("ghbdtn", false, true,  "живое: привет в словаре — перевернём", true)
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
                if (c.Live && !WordDict.Has(altText, altLang))
                {
                    convert = false; // живое исправление — только в словарные слова
                }
                else
                {
                    convert = LanguageTables.ShouldConvert(curText, curLang, curScore,
                                                            altText, altLang, altScore, 1.0);
                    bool targetInDict = WordDict.Has(altText, altLang);
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

            sb.AppendLine(fails == 0 ? "ALL TESTS PASSED" : fails + " TEST(S) FAILED");
            try
            {
                File.WriteAllText(outPath, sb.ToString());
            }
            catch (Exception) { }
            Console.Write(sb.ToString());
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
