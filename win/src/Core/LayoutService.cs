using System;
using System.Collections.Generic;
using System.Text;

namespace OpenSwitcher.Core
{
    /// <summary>Вариант прочтения набранного слова в одной из установленных раскладок.</summary>
    public class LayoutCandidate
    {
        public IntPtr Hkl;
        public string Text;
        public int Lang;     // 0 ru / 1 en / -1
        public double Score;
        public string Name;
    }

    /// <summary>Рендер vk-буфера в произвольной раскладке, список раскладок, переключение.</summary>
    public static class LayoutService
    {
        private static readonly bool IsWin10OrGreater = Environment.OSVersion.Version.Major >= 10;

        /// <summary>Текст, который дала бы эта раскладка при тех же нажатиях.</summary>
        public static string Render(IntPtr hkl, List<KeyRec> keys)
        {
            var sb = new StringBuilder(keys.Count);
            var state = new byte[256];
            var chunk = new StringBuilder(8);
            // P2-4: на Win10+ флаг 0x4 запрещает ToUnicodeEx менять dead-key буфер ядра
            uint flags = IsWin10OrGreater ? 4u : 0u;
            for (int i = 0; i < keys.Count; i++)
            {
                KeyRec rec = keys[i];
                Array.Clear(state, 0, state.Length);
                if (rec.Shift) { state[0x10] = 0x80; state[0xA0] = 0x80; }
                if (rec.Caps) { state[0x14] = 1; }
                uint sc = Native.MapVirtualKeyEx((uint)rec.Vk, Native.MAPVK_VK_TO_VSC, hkl);
                chunk.Length = 0;
                int r = 0;
                try
                {
                    r = Native.ToUnicodeEx((uint)rec.Vk, sc, state, chunk, chunk.Capacity, flags, hkl);
                }
                catch (Exception) { }
                if (r > 0) sb.Append(chunk.ToString(0, r));
                else sb.Append('?');
            }
            return sb.ToString();
        }

        private static List<IntPtr> _cache;
        private static int _cacheAt;

        /// <summary>Все установленные раскладки (уникальные HKL), кэш 30 с.</summary>
        public static List<IntPtr> GetLayouts()
        {
            if (_cache != null && _cache.Count > 0 &&
                unchecked(Environment.TickCount - _cacheAt) >= 0 &&
                unchecked(Environment.TickCount - _cacheAt) < 30000)
                return new List<IntPtr>(_cache);
            var list = new List<IntPtr>();
            try
            {
                int n = Native.GetKeyboardLayoutList(0, null);
                if (n <= 0) return list;
                var arr = new IntPtr[n];
                n = Native.GetKeyboardLayoutList(n, arr);
                for (int i = 0; i < n; i++)
                    if (!list.Contains(arr[i])) list.Add(arr[i]);
            }
            catch (Exception) { }
            _cache = new List<IntPtr>(list);
            _cacheAt = Environment.TickCount;
            return list;
        }

        public static string LayoutName(IntPtr hkl, string text)
        {
            int lang = LanguageTables.LangOf(text);
            if (lang == 0) return "РУС";
            if (lang == 1) return "ENG";
            ushort id = (ushort)((long)hkl & 0xFFFF);
            return id.ToString("X4");
        }

        private static bool IsOtherCyrillicHkl(IntPtr hkl, string rendered)
        {
            ushort lid = (ushort)((long)hkl & 0xFFFF);
            if (lid == 0x0422 /* UK */ || lid == 0x0423 /* BE */ || lid == 0x043F /* KK */ || lid == 0x0402 /* BG */)
                return true;
            if (!string.IsNullOrEmpty(rendered))
            {
                for (int i = 0; i < rendered.Length; i++)
                {
                    if ("іїєґўІЇЄҐЎ".IndexOf(rendered[i]) >= 0) return true;
                }
            }
            return false;
        }

        /// <summary>Прочитать буфер во всех раскладках и оценить каждую.</summary>
        public static List<LayoutCandidate> RenderAll(List<KeyRec> keys, List<IntPtr> layouts)
        {
            var res = new List<LayoutCandidate>();
            foreach (IntPtr hkl in layouts)
            {
                string text = Render(hkl, keys);
                string letters = LanguageTables.LettersOnly(text);
                int lang = letters.Length > 0 ? LanguageTables.LangOf(letters) : -1;
                if (lang == 0 && IsOtherCyrillicHkl(hkl, text)) lang = -1; // не путаем RU с UA/BY
                var c = new LayoutCandidate();
                c.Hkl = hkl;
                c.Text = text;
                c.Lang = lang;
                c.Score = lang >= 0 ? LanguageTables.Score(letters, lang) : -99;
                c.Name = LayoutName(hkl, letters);
                res.Add(c);
            }
            return res;
        }

        /// <summary>Найти раскладку языка (0 = РУС с приоритетом 0x0419 / 'ыъ', 1 = ENG с приоритетом 0x0409 / QWERTY).</summary>
        public static IntPtr FindLayoutByLang(int lang)
        {
            List<IntPtr> layouts = GetLayouts();
            var probe = new List<KeyRec>();
            probe.Add(new KeyRec(0x41, false, false));
            if (lang == 0)
            {
                foreach (IntPtr hkl in layouts)
                    if (((ushort)((long)hkl & 0xFFFF)) == 0x0419) return hkl;
                var probeRu = new List<KeyRec>();
                probeRu.Add(new KeyRec(0x53, false, false));
                probeRu.Add(new KeyRec(0xDD, false, false));
                foreach (IntPtr hkl in layouts)
                    if (!IsOtherCyrillicHkl(hkl, null) && Render(hkl, probeRu).ToLowerInvariant() == "ыъ") return hkl;
                foreach (IntPtr hkl in layouts)
                    if (!IsOtherCyrillicHkl(hkl, null) && LanguageTables.LangOf(Render(hkl, probe)) == 0) return hkl;
                return IntPtr.Zero;
            }
            if (lang == 1)
            {
                foreach (IntPtr hkl in layouts)
                    if (((ushort)((long)hkl & 0xFFFF)) == 0x0409) return hkl;
                var probeYz = new List<KeyRec>();
                probeYz.Add(new KeyRec(0x59, false, false));
                probeYz.Add(new KeyRec(0x5A, false, false));
                foreach (IntPtr hkl in layouts)
                    if (Render(hkl, probeYz).ToLowerInvariant() == "yz") return hkl;
            }
            foreach (IntPtr hkl in layouts)
            {
                string t = Render(hkl, probe);
                if (LanguageTables.LangOf(t) == lang) return hkl;
            }
            return IntPtr.Zero;
        }

        /// <summary>Переключить раскладку в чужом окне.</summary>
        public static bool SwitchForegroundTo(IntPtr hwnd, IntPtr hkl)
        {
            if (hwnd == IntPtr.Zero || hkl == IntPtr.Zero) return false;
            return Native.PostMessage(hwnd, Native.WM_INPUTLANGCHANGEREQUEST, IntPtr.Zero, hkl);
        }

        /// <summary>Фактическая раскладка потока, владеющего окном (для проверки, применился ли перевод).</summary>
        public static IntPtr GetForegroundHkl(IntPtr hwnd)
        {
            uint pid;
            uint tid = Native.GetWindowThreadProcessId(hwnd, out pid);
            return tid != 0 ? Native.GetKeyboardLayout(tid) : Native.GetKeyboardLayout(0);
        }
    }
}
