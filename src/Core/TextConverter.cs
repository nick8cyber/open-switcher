using System;
using System.Collections.Generic;
using System.Threading;
using System.Windows.Forms;

namespace OpenSwitcher.Core
{
    /// <summary>Синтез ввода: забой, unicode-ввод, Ctrl+C/V, работа с буфером обмена.</summary>
    public static class TextConverter
    {
        public static void SendKey(int vk, bool extended)
        {
            SendKey(vk, extended, false);
        }

        /// <summary>Нажать клавишу (опционально с Shift) — для пересылки проглоченного разделителя.</summary>
        public static void SendKey(int vk, bool extended, bool withShift)
        {
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
            Native.SendInput((uint)list.Count, list.ToArray(), System.Runtime.InteropServices.Marshal.SizeOf(typeof(Native.INPUT)));
        }

        public static void SendCombo(int modifierVk, int vk)
        {
            uint scM = Native.MapVirtualKeyEx((uint)modifierVk, Native.MAPVK_VK_TO_VSC, IntPtr.Zero);
            uint scK = Native.MapVirtualKeyEx((uint)vk, Native.MAPVK_VK_TO_VSC, IntPtr.Zero);
            var inputs = new Native.INPUT[4];
            for (int i = 0; i < 4; i++) inputs[i].type = 1;
            inputs[0].u.ki.wVk = (ushort)modifierVk; inputs[0].u.ki.wScan = (ushort)scM;
            inputs[1].u.ki.wVk = (ushort)vk; inputs[1].u.ki.wScan = (ushort)scK;
            inputs[2].u.ki.wVk = (ushort)vk; inputs[2].u.ki.wScan = (ushort)scK; inputs[2].u.ki.dwFlags = Native.KEYEVENTF_KEYUP;
            inputs[3].u.ki.wVk = (ushort)modifierVk; inputs[3].u.ki.wScan = (ushort)scM; inputs[3].u.ki.dwFlags = Native.KEYEVENTF_KEYUP;
            Native.SendInput((uint)inputs.Length, inputs, System.Runtime.InteropServices.Marshal.SizeOf(typeof(Native.INPUT)));
        }

        /// <summary>Забить n символов backspace'ами.</summary>
        public static void SendBackspaces(int n)
        {
            if (n <= 0) return;
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
            Native.SendInput((uint)inputs.Length, inputs, System.Runtime.InteropServices.Marshal.SizeOf(typeof(Native.INPUT)));
        }

        /// <summary>Ввод строки "юникодом" — не зависит от текущей раскладки.</summary>
        public static void SendUnicode(string text)
        {
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
            Native.SendInput((uint)list.Count, list.ToArray(), System.Runtime.InteropServices.Marshal.SizeOf(typeof(Native.INPUT)));
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
