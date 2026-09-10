using System;
using System.Globalization;
using System.IO;
using System.Text;

namespace OpenSwitcher.Core
{
    /// <summary>Биты модификаторов для хоткеев.</summary>
    public static class HK
    {
        public const int CTRL = 1;
        public const int SHIFT = 2;
        public const int ALT = 4;
        public const int WIN = 8;
    }

    public class Settings
    {
        // --- автоправка (по умолчанию ВКЛ — как в Punto/Caramba; ручные хоткеи работают всегда) ---
        public bool FixOnEnter = true;            // проверять слово при голом Enter (как в Punto)
        public bool AutoConvertOnWordEnd = true;  // проверять слово при пробеле / знаке препинания
        public int MinWordLen = 3;
        public double Sensitivity = 1.0;          // 0.7 низкая / 1.0 средняя / 1.5 высокая

        // --- хоткеи ---
        public int HotUndoVk = 0x13;               // Break — отмена последней автозамены
        public int HotUndoMods = 0;
        public int HotFixWordVk = 0x20;            // Ctrl+Space
        public int HotFixWordMods = HK.CTRL;
        public int HotFixSelVk = 0x13;             // Shift+Break — как в Caramba
        public int HotFixSelMods = HK.SHIFT;
        public int HotRuVk = 0xA0;        // левый Shift -> РУС
        public int HotRuMods = 0;
        public int HotEnVk = 0xA1;        // правый Shift -> ENG
        public int HotEnMods = 0;
        public int HotAutoToggleVk = 0;            // пауза автоперевода — по умолчанию НЕ назначена
        public int HotAutoToggleMods = 0;
        public bool LockAutoAfterManualSwitch = true; // ручной выбор раскладки отключает автодетект до новой сессии
        public bool DoubleShiftSwitch = true;      // двойной Shift = отмена последней замены (как в Caramba)
        public int InputMode = 1;                  // 0 = SendInput, 1 = сообщения окна (обход HIPS)

        // --- система ---
        public bool ShowPopup = true;
        public bool RestoreClipboard = true;
        public bool StartWithWindows = false;
        public bool Paused = false;
        public string Exclusions = "";
        public int ThemeMode = 0; // 0 системная / 1 светлая / 2 тёмная
        public int DefaultsV = 7; // версия дефолтов (7 = ввод сообщениями окна включён; 6 = автоправка вкл; 5 = Shift+Break конвертация выделенного)
    }

    public static class SettingsStore
    {
        public static string Dir
        {
            get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "OpenSwitcher"); }
        }

        private static string FilePath
        {
            get { return Path.Combine(Dir, "settings.ini"); }
        }

        public static Settings Load()
        {
            var s = new Settings();
            bool fileExists = false;
            try
            {
                if (File.Exists(FilePath))
                {
                    fileExists = true;
                    foreach (string line in File.ReadAllLines(FilePath)) ApplyLine(s, line);
                }
            }
            catch (Exception) { }
            // миграция на безопасные дефолты: старые настройки могли держать
            // автоисправление и double-shift включёнными
            if (!fileExists || s.DefaultsV < 2)
            {
                s.FixOnEnter = false;
                s.AutoConvertOnWordEnd = false;
                s.DoubleShiftSwitch = false;
                s.DefaultsV = 2;
            }
            // v3: хоткеи исправления без мёртвой клавиши Pause/Break (кастомные не трогаем)
            if (s.DefaultsV < 3)
            {
                if (s.HotFixWordVk == 0x13)
                {
                    s.HotFixWordVk = 0x20;
                    s.HotFixWordMods = HK.CTRL;
                }
                if (s.HotFixSelVk == 0x13)
                {
                    s.HotFixSelVk = 0x20;
                    s.HotFixSelMods = HK.CTRL | HK.SHIFT;
                }
                s.DefaultsV = 3;
                Save(s);
            }
            // v4: Break = отмена последней автозамены; пауза автоперевода без клавиши по умолчанию
            if (s.DefaultsV < 4)
            {
                if (s.HotAutoToggleVk == 0x13)
                {
                    s.HotAutoToggleVk = 0;
                    s.HotAutoToggleMods = 0;
                }
                s.HotUndoVk = 0x13;
                s.HotUndoMods = 0;
                s.DefaultsV = 4;
                Save(s);
            }
            // v5: конвертация выделенного — Shift+Break (как в Caramba); кастомные хоткеи не трогаем
            if (s.DefaultsV < 5)
            {
                if (s.HotFixSelVk == 0x20 && s.HotFixSelMods == (HK.CTRL | HK.SHIFT))
                {
                    s.HotFixSelVk = 0x13;
                    s.HotFixSelMods = HK.SHIFT;
                }
                s.DefaultsV = 5;
                Save(s);
            }
            // v6: автоправка включена по умолчанию — как в Punto/Caramba (однократно; кто выключил
            // в настройках после миграции — остаётся выключенной)
            if (s.DefaultsV < 6)
            {
                s.FixOnEnter = true;
                s.AutoConvertOnWordEnd = true;
                s.DefaultsV = 6;
                Save(s);
            }
            // v7: ввод сообщениями окна (обход HIPS-блокировки SendInput) включён по умолчанию.
            // COMODO/антивирусы глушат SendInput от неподписанных процессов — замена
            // «логировалась как успешная, а текст не менялся». Кто выключил тумблер
            // после миграции — остаётся на SendInput.
            if (s.DefaultsV < 7)
            {
                s.InputMode = 1;
                s.DefaultsV = 7;
                Save(s);
            }
            return s;
        }

        private static void ApplyLine(Settings s, string line)
        {
            int i = line.IndexOf('=');
            if (i <= 0) return;
            string k = line.Substring(0, i).Trim();
            string v = line.Substring(i + 1).Trim();
            switch (k)
            {
                case "FixOnEnter": s.FixOnEnter = v == "1"; break;
                case "AutoConvertOnWordEnd": s.AutoConvertOnWordEnd = v == "1"; break;
                case "DoubleShiftSwitch": s.DoubleShiftSwitch = v == "1"; break;
                case "ShowPopup": s.ShowPopup = v == "1"; break;
                case "RestoreClipboard": s.RestoreClipboard = v == "1"; break;
                case "StartWithWindows": s.StartWithWindows = v == "1"; break;
                case "Paused": s.Paused = v == "1"; break;
                case "MinWordLen": { int n; if (int.TryParse(v, out n)) s.MinWordLen = Math.Max(2, Math.Min(8, n)); break; }
                case "Sensitivity": { double d; if (double.TryParse(v, NumberStyles.Float, CultureInfo.InvariantCulture, out d)) s.Sensitivity = d; break; }
                case "HotFixWordVk": { int n; if (int.TryParse(v, out n)) s.HotFixWordVk = n; break; }
                case "HotFixWordMods": { int n; if (int.TryParse(v, out n)) s.HotFixWordMods = n; break; }
                case "HotFixSelVk": { int n; if (int.TryParse(v, out n)) s.HotFixSelVk = n; break; }
                case "HotFixSelMods": { int n; if (int.TryParse(v, out n)) s.HotFixSelMods = n; break; }
                case "HotRuVk": { int n; if (int.TryParse(v, out n)) s.HotRuVk = n; break; }
                case "HotRuMods": { int n; if (int.TryParse(v, out n)) s.HotRuMods = n; break; }
                case "HotEnVk": { int n; if (int.TryParse(v, out n)) s.HotEnVk = n; break; }
                case "HotEnMods": { int n; if (int.TryParse(v, out n)) s.HotEnMods = n; break; }
                case "HotAutoToggleVk": { int n; if (int.TryParse(v, out n)) s.HotAutoToggleVk = n; break; }
                case "HotAutoToggleMods": { int n; if (int.TryParse(v, out n)) s.HotAutoToggleMods = n; break; }
                case "HotUndoVk": { int n; if (int.TryParse(v, out n)) s.HotUndoVk = n; break; }
                case "HotUndoMods": { int n; if (int.TryParse(v, out n)) s.HotUndoMods = n; break; }
                case "LockAutoAfterManualSwitch": s.LockAutoAfterManualSwitch = v == "1"; break;
                case "InputMode": { int n; if (int.TryParse(v, out n) && n >= 0 && n <= 1) s.InputMode = n; break; }
                case "Exclusions": s.Exclusions = v; break;
                case "ThemeMode": { int n; if (int.TryParse(v, out n) && n >= 0 && n <= 2) s.ThemeMode = n; break; }
                case "DefaultsV": { int n; if (int.TryParse(v, out n)) s.DefaultsV = n; break; }
            }
        }

        public static void Save(Settings s)
        {
            try
            {
                Directory.CreateDirectory(Dir);
                var sb = new StringBuilder();
                sb.AppendLine("FixOnEnter=" + (s.FixOnEnter ? "1" : "0"));
                sb.AppendLine("AutoConvertOnWordEnd=" + (s.AutoConvertOnWordEnd ? "1" : "0"));
                sb.AppendLine("DoubleShiftSwitch=" + (s.DoubleShiftSwitch ? "1" : "0"));
                sb.AppendLine("ShowPopup=" + (s.ShowPopup ? "1" : "0"));
                sb.AppendLine("RestoreClipboard=" + (s.RestoreClipboard ? "1" : "0"));
                sb.AppendLine("StartWithWindows=" + (s.StartWithWindows ? "1" : "0"));
                sb.AppendLine("Paused=" + (s.Paused ? "1" : "0"));
                sb.AppendLine("MinWordLen=" + s.MinWordLen);
                sb.AppendLine("Sensitivity=" + s.Sensitivity.ToString("0.0", CultureInfo.InvariantCulture));
                sb.AppendLine("HotFixWordVk=" + s.HotFixWordVk);
                sb.AppendLine("HotFixWordMods=" + s.HotFixWordMods);
                sb.AppendLine("HotFixSelVk=" + s.HotFixSelVk);
                sb.AppendLine("HotFixSelMods=" + s.HotFixSelMods);
                sb.AppendLine("HotRuVk=" + s.HotRuVk);
                sb.AppendLine("HotRuMods=" + s.HotRuMods);
                sb.AppendLine("HotEnVk=" + s.HotEnVk);
                sb.AppendLine("HotEnMods=" + s.HotEnMods);
                sb.AppendLine("HotAutoToggleVk=" + s.HotAutoToggleVk);
                sb.AppendLine("HotAutoToggleMods=" + s.HotAutoToggleMods);
                sb.AppendLine("HotUndoVk=" + s.HotUndoVk);
                sb.AppendLine("HotUndoMods=" + s.HotUndoMods);
                sb.AppendLine("LockAutoAfterManualSwitch=" + (s.LockAutoAfterManualSwitch ? "1" : "0"));
                sb.AppendLine("InputMode=" + s.InputMode);
                sb.AppendLine("Exclusions=" + s.Exclusions);
                sb.AppendLine("ThemeMode=" + s.ThemeMode);
                sb.AppendLine("DefaultsV=" + s.DefaultsV);
                File.WriteAllText(FilePath, sb.ToString());
            }
            catch (Exception) { }
        }
    }
}
