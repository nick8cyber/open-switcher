using System;
using System.Collections.Generic;
using System.Threading;
using System.Windows.Forms;

namespace OpenSwitcher.Core
{
    /// <summary>Синтез ввода: два канала — SendInput и сообщения окна (WM_KEYDOWN/WM_CHAR).</summary>
    public static class TextConverter
    {
        /// <summary>0 = SendInput, 1 = сообщения окна в hwndFocus. Задаётся движком.</summary>
        public static int InjectMode;
        /// <summary>Куда слать сообщения окна (hwndFocus переднего окна).</summary>
        public static IntPtr FocusHwnd;

        /// <summary>Диагностика блокировки SendInput: сколько событий запросили/сколько
        /// реально приняла система в последнем вызове. 0 принятых при запросе >0 —
        /// ввод гасит HIPS/антивирус («замена в журнале есть, текст не меняется»).</summary>
        public static uint LastSendInputRequested;
        public static uint LastSendInputResult;

        /// <summary>Глубина СОБСТВЕННОЙ инжекции движка. В тест-режиме (OS_TEST_INJECT)
        /// движок обрабатывает инжектированный ввод как настоящий — включая СВОЙ, чего
        /// в проде не бывает (там injected-события скипаются). Чтобы тест-режим вёл себя
        /// как прод, события, произошедшие пока счётчик > 0, движок игнорирует.</summary>
        public static int SelfInjectDepth;

        private static void SendInputs(Native.INPUT[] arr)
        {
            LastSendInputRequested = (uint)arr.Length;
            LastSendInputResult = 0;
            SelfInjectDepth++;
            try
            {
                LastSendInputResult = arr.Length == 0 ? 0 :
                    Native.SendInput((uint)arr.Length, arr,
                        System.Runtime.InteropServices.Marshal.SizeOf(typeof(Native.INPUT)));
            }
            finally { SelfInjectDepth--; }
        }

        /// <summary>Канал сообщений активен и есть куда слать. Если hwnd не задан —
        /// вызов должен падать назад на SendInput, а не молча терять ввод.</summary>
        private static bool UseMessages(IntPtr hwnd)
        {
            return InjectMode == 1 && hwnd != IntPtr.Zero;
        }

        // lParam для сообщений клавиатуры: repeat=1, scancode<<16;
        // расширенные клавиши (стрелки/Ins/Del) — бит 24; KEYUP — ещё биты 30/31.
        private const uint LPK_EXTENDED = 0x01000000u;
        private const uint LPK_KEYUP = 0xC0000000u;

        private static void PostKey(IntPtr hwnd, int vk, bool up)
        {
            PostKey(hwnd, vk, up, false);
        }

        private static void PostKey(IntPtr hwnd, int vk, bool up, bool extended)
        {
            uint sc = Native.MapVirtualKeyEx((uint)vk, Native.MAPVK_VK_TO_VSC, IntPtr.Zero);
            uint lp = (sc << 16) | 1u;
            if (extended) lp |= LPK_EXTENDED;
            if (up) lp |= LPK_KEYUP;
            Native.PostMessage(hwnd, up ? Native.WM_KEYUP : Native.WM_KEYDOWN, (IntPtr)vk, (IntPtr)lp);
        }

        private static void PostChar(IntPtr hwnd, char c)
        {
            Native.PostMessage(hwnd, Native.WM_CHAR, (IntPtr)c, IntPtr.Zero);
        }

        private static void SendKeyMessages(IntPtr hwnd, int vk)
        {
            PostKey(hwnd, vk, false);
            PostKey(hwnd, vk, true);
        }

        private static void BackspaceOnce(IntPtr hwnd, bool useMessages)
        {
            if (useMessages && hwnd != IntPtr.Zero)
            {
                SendKeyMessages(hwnd, 0x08); // VK_BACK
            }
            else
            {
                uint sc = Native.MapVirtualKeyEx(8, Native.MAPVK_VK_TO_VSC, IntPtr.Zero);
                var inputs = new Native.INPUT[2];
                inputs[0].type = 1;
                inputs[0].u.ki.wVk = 8;
                inputs[0].u.ki.wScan = (ushort)sc;
                inputs[1].type = 1;
                inputs[1].u.ki.wVk = 8;
                inputs[1].u.ki.wScan = (ushort)sc;
                inputs[1].u.ki.dwFlags = Native.KEYEVENTF_KEYUP;
                SendInputs(inputs);
            }
        }

        /// <summary>Забить n символов backspace'ами. Одноаргументная версия маршрутизируется
        /// через статический FocusHwnd (движок обязан выставить его ДО вызова) — иначе
        /// даже при InjectMode=1 backspace'ы уходили бы через SendInput и глохли в HIPS.</summary>
        public static void SendBackspaces(int n)
        {
            SendBackspaces(n, FocusHwnd);
        }

        public static void SendBackspaces(int n, IntPtr hwndFocus)
        {
            if (UseMessages(hwndFocus))
            {
                LastSendInputRequested = 0;
                for (int i = 0; i < n; i++) BackspaceOnce(hwndFocus, true);
            }
            else
            {
                uint sc = Native.MapVirtualKeyEx(8, Native.MAPVK_VK_TO_VSC, IntPtr.Zero);
                var inputs = new Native.INPUT[n * 2];
                for (int i = 0; i < n; i++)
                {
                    inputs[2 * i].type = 1;
                    inputs[2 * i].u.ki.wVk = 8;
                    inputs[2 * i].u.ki.wScan = (ushort)sc;
                    inputs[2 * i + 1].type = 1;
                    inputs[2 * i + 1].u.ki.wVk = 8;
                    inputs[2 * i + 1].u.ki.wScan = (ushort)sc;
                    inputs[2 * i + 1].u.ki.dwFlags = Native.KEYEVENTF_KEYUP;
                }
                SendInputs(inputs);
            }
        }
        public static void SendKey(int vk, bool extended)
        {
            SendKey(vk, extended, false);
        }

        /// <summary>Принудительно «отпустить» зажатые модификаторы. Без этого инжекция
        /// при удерживаемом Shift/Ctrl даёт Ctrl+Shift+C вместо Ctrl+C и управляющие
        /// символы вместо букв. SendInput-версия может быть погашена HIPS — тогда
        /// физически зажатые модификаторы хотя бы логически отпускаются сообщением
        /// WM_KEYUP в окно фокуса (приложения, отслеживающие поток сообщений, увидят
        /// отпускание; повторный KEYUP при физическом отпускании безвреден).</summary>
        public static void ReleaseModifiers()
        {
            var list = new List<Native.INPUT>();
            int[] vks = { 0x10, 0xA0, 0xA1, 0x11, 0xA2, 0xA3, 0x12, 0xA4, 0xA5, 0x5B, 0x5C };
            foreach (int vk in vks)
            {
                if ((Native.GetAsyncKeyState(vk) & 0x8000) != 0)
                {
                    if (UseMessages(FocusHwnd))
                    {
                        // L/R-модификаторы (0xA0..0xA5) шлём как генерические VK_SHIFT/CTRL/ALT
                        int g = vk;
                        if (vk == 0xA0 || vk == 0xA1) g = 0x10;
                        else if (vk == 0xA2 || vk == 0xA3) g = 0x11;
                        else if (vk == 0xA4 || vk == 0xA5) g = 0x12;
                        PostKey(FocusHwnd, g, true);
                    }
                    var u = new Native.INPUT();
                    u.type = 1;
                    u.u.ki.wVk = (ushort)vk;
                    u.u.ki.wScan = (ushort)Native.MapVirtualKeyEx((uint)vk, Native.MAPVK_VK_TO_VSC, IntPtr.Zero);
                    u.u.ki.dwFlags = Native.KEYEVENTF_KEYUP;
                    list.Add(u);
                }
            }
            if (list.Count > 0)
                SendInputs(list.ToArray());
        }

        /// <summary>Нажать клавишу (опционально с Shift) — для пересылки проглоченного разделителя.</summary>
        public static void SendKey(int vk, bool extended, bool withShift)
        {
            if (UseMessages(FocusHwnd))
            {
                if (withShift) PostKey(FocusHwnd, 0x10, false);
                SendKeyMessages(FocusHwnd, vk);
                if (withShift) PostKey(FocusHwnd, 0x10, true);
                return;
            }
            var list = new List<Native.INPUT>(withShift ? 4 : 2);
            uint sc = Native.MapVirtualKeyEx((uint)vk, Native.MAPVK_VK_TO_VSC, IntPtr.Zero);
            if (withShift)
            {
                var sd = new Native.INPUT(); var su = new Native.INPUT();
                sd.type = 1; su.type = 1;
                sd.u.ki.wVk = 0x10; su.u.ki.wVk = 0x10;
                su.u.ki.dwFlags = Native.KEYEVENTF_KEYUP;
                list.Add(sd); list.Add(su);
            }
            var down = new Native.INPUT(); var up = new Native.INPUT();
            down.type = 1; up.type = 1;
            down.u.ki.wVk = (ushort)vk; down.u.ki.wScan = (ushort)sc;
            up.u.ki.wVk = (ushort)vk; up.u.ki.wScan = (ushort)sc;
            up.u.ki.dwFlags = Native.KEYEVENTF_KEYUP | (extended ? Native.KEYEVENTF_EXTENDEDKEY : 0);
            down.u.ki.dwFlags = extended ? Native.KEYEVENTF_EXTENDEDKEY : 0;
            list.Add(down); list.Add(up);
            SendInputs(list.ToArray());
        }

        public static void SendCombo(int modifierVk, int vk)
        {
            SendCombo(modifierVk, 0, vk, false);
        }

        /// <summary>Расширенные клавиши (стрелки/PGUP/PGDN/Home/End/Ins/Del) —
        /// нужен бит extended в SendInput и бит 24 lParam для сообщений.</summary>
        private static bool IsExtendedVk(int vk)
        {
            return (vk >= 0x21 && vk <= 0x28) || vk == 0x2D || vk == 0x2E;
        }

        /// <summary>Сочетание с двумя модификаторами (напр. Ctrl+Shift+Left для выделения слова).
        /// При InjectMode=1 и allowMessages=true уходит сообщениями (PostMessage) в окно фокуса:
        /// зажатие модификаторов — WM_KEYDOWN VK_CONTROL/VK_SHIFT, отпускание — WM_KEYUP.
        /// Приложения, читающие GetKeyState вместо потока сообщений, могут модификаторы не
        /// увидеть — тогда сочетание сработает как голая клавиша (для стрелок это безопасно).
        /// Для буквенных сочетаний (Ctrl+C/V) сообщений избегаем: PostMessage не обновляет
        /// key-state потока-получателя, и TranslateMessage чужого приложения может превратить
        /// «Ctrl+C» в напечатанную букву 'c' поверх выделения.</summary>
        public static void SendCombo(int modifierVk1, int modifierVk2, int vk, bool extended)
        {
            SendCombo(modifierVk1, modifierVk2, vk, extended, true);
        }

        public static void SendCombo(int modifierVk1, int modifierVk2, int vk, bool extended, bool allowMessages)
        {
            if (allowMessages && UseMessages(FocusHwnd))
            {
                bool ext = extended || IsExtendedVk(vk);
                if (modifierVk1 != 0) PostKey(FocusHwnd, modifierVk1, false);
                if (modifierVk2 != 0) PostKey(FocusHwnd, modifierVk2, false);
                PostKey(FocusHwnd, vk, false, ext);
                PostKey(FocusHwnd, vk, true, ext);
                if (modifierVk2 != 0) PostKey(FocusHwnd, modifierVk2, true);
                if (modifierVk1 != 0) PostKey(FocusHwnd, modifierVk1, true);
                return;
            }
            var list = new List<Native.INPUT>(8);
            foreach (int m in new[] { modifierVk1, modifierVk2 })
            {
                if (m == 0) continue;
                var d = new Native.INPUT(); var u = new Native.INPUT();
                d.type = 1; u.type = 1;
                d.u.ki.wVk = (ushort)m; d.u.ki.wScan = (ushort)Native.MapVirtualKeyEx((uint)m, Native.MAPVK_VK_TO_VSC, IntPtr.Zero);
                u.u.ki.wVk = (ushort)m; u.u.ki.wScan = d.u.ki.wScan;
                u.u.ki.dwFlags = Native.KEYEVENTF_KEYUP;
                list.Add(d); list.Add(u);
            }
            var kd = new Native.INPUT(); var ku = new Native.INPUT();
            kd.type = 1; ku.type = 1;
            uint sc = Native.MapVirtualKeyEx((uint)vk, Native.MAPVK_VK_TO_VSC, IntPtr.Zero);
            kd.u.ki.wVk = (ushort)vk; kd.u.ki.wScan = (ushort)sc;
            ku.u.ki.wVk = (ushort)vk; ku.u.ki.wScan = (ushort)sc;
            kd.u.ki.dwFlags = extended ? Native.KEYEVENTF_EXTENDEDKEY : 0;
            ku.u.ki.dwFlags = Native.KEYEVENTF_KEYUP | (extended ? Native.KEYEVENTF_EXTENDEDKEY : 0);
            list.Add(kd); list.Add(ku);
            // модификаторы отпускаем в обратном порядке
            for (int i = list.Count - 1; i >= 0; i--)
            {
                Native.INPUT ev = list[i];
                if ((ev.u.ki.dwFlags & Native.KEYEVENTF_KEYUP) == 0 && ev.u.ki.wVk != vk)
                {
                    ev.u.ki.dwFlags = Native.KEYEVENTF_KEYUP;
                    list.Add(ev);
                }
            }
            SendInputs(list.ToArray());
        }

        /// <summary>Ввод строки "юникодом" — не зависит от текущей раскладки.
        /// При InjectMode=1 уходит как WM_CHAR в окно фокуса.</summary>
        public static void SendUnicode(string text)
        {
            if (UseMessages(FocusHwnd))
            {
                LastSendInputRequested = 0; // канал сообщений — SendInput не участвовал
                foreach (char c in text)
                {
                    if (c == '\r' || c == '\n' || c == '\t') continue;
                    PostChar(FocusHwnd, c);
                }
                return;
            }
            var list = new List<Native.INPUT>(text.Length * 2);
            foreach (char c in text)
            {
                if (c == '\r' || c == '\n' || c == '\t') continue;
                var down = new Native.INPUT();
                var up = new Native.INPUT();
                down.type = 1; up.type = 1;
                down.u.ki.wScan = c;
                down.u.ki.dwFlags = Native.KEYEVENTF_UNICODE;
                up.u.ki.wScan = c;
                up.u.ki.dwFlags = Native.KEYEVENTF_UNICODE | Native.KEYEVENTF_KEYUP;
                list.Add(down); list.Add(up);
            }
            if (list.Count == 0) return;
            SendInputs(list.ToArray());
        }

        public static string GetClipboardTextSafe()
        {
            for (int i = 0; i < 12; i++)
            {
                try
                {
                    if (Clipboard.ContainsText()) return Clipboard.GetText();
                    return null;
                }
                catch (Exception) { }
                Thread.Sleep(20);
            }
            return null;
        }

        public static string GetClipboardTextOnce()
        {
            try
            {
                if (Clipboard.ContainsText()) return Clipboard.GetText();
            }
            catch (Exception) { }
            return null;
        }

        public static bool SetClipboardTextSafe(string text)
        {
            for (int i = 0; i < 12; i++)
            {
                try
                {
                    Clipboard.SetDataObject(text, true, 5, 60);
                    return true;
                }
                catch (Exception) { }
                Thread.Sleep(20);
            }
            return false;
        }
    }
}
