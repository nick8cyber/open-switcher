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
        /// <summary>Текст, который дала бы эта раскладка при тех же нажатиях.</summary>
        public static string Render(IntPtr hkl, List<KeyRec> keys)
        {
            var sb = new StringBuilder(keys.Count);
            var state = new byte[256];
            var chunk = new StringBuilder(8);
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
                    r = Native.ToUnicodeEx((uint)rec.Vk, sc, state, chunk, chunk.Capacity, 0, hkl);
                }
                catch (Exception) { }
                if (r > 0) sb.Append(chunk.ToString(0, r));
                else sb.Append('?');
            }
            return sb.ToString();
        }

        /// <summary>Все установленные раскладки (уникальные HKL).</summary>
        public static List<IntPtr> GetLayouts()
        {
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

        /// <summary>Прочитать буфер во всех раскладках и оценить каждую.</summary>
        public static List<LayoutCandidate> RenderAll(List<KeyRec> keys, List<IntPtr> layouts)
        {
            var res = new List<LayoutCandidate>();
            foreach (IntPtr hkl in layouts)
            {
                string text = Render(hkl, keys);
                string letters = LanguageTables.LettersOnly(text);
                int lang = letters.Length > 0 ? LanguageTables.LangOf(letters) : -1;
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

        /// <summary>Найти раскладку, в которой клавиша 'a' (vk 0x41) даёт кириллицу (0) или латиницу (1).</summary>
        public static IntPtr FindLayoutByLang(int lang)
        {
            var probe = new List<KeyRec>();
            probe.Add(new KeyRec(0x41, false, false));
            foreach (IntPtr hkl in GetLayouts())
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
    }
}
