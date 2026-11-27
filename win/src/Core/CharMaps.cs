using System;
using System.Collections.Generic;
using System.Text;

namespace OpenSwitcher.Core
{
    /// <summary>Символ, набранный физической клавишей: vk + состояние shift/caps.</summary>
    public struct KeyRec
    {
        public int Vk;
        public bool Shift;
        public bool Caps;

        public KeyRec(int vk, bool shift, bool caps)
        {
            Vk = vk; Shift = shift; Caps = caps;
        }
    }

    /// <summary>
    /// Статические карты ЙЦУКЕН <-> QWERTY. Используются для конвертации текста
    /// (выделенного) и в self-test'ах; живой путь ввода идёт через ToUnicodeEx.
    /// </summary>
    public static class CharMaps
    {
        public const string En = "qwertyuiop[]asdfghjkl;'zxcvbnm,.`";
        public const string Ru = "йцукенгшщзхъфывапролджэячсмитьбюё";
        public const string EnUpper = "QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>~";
        public const string RuUpper = "ЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮЁ";

        /// <summary>VK-код клавиши, которой набирается символ ru/en раскладки (включая знаковые OEM-коды).</summary>
        public static int VkOfChar(char c, bool fromRu)
        {
            int i = (fromRu ? Ru : En).IndexOf(c);
            if (i < 0) i = (fromRu ? RuUpper : EnUpper).IndexOf(c);
            if (i < 0)
            {
                char lo = char.ToLowerInvariant(c);
                i = (fromRu ? Ru : En).IndexOf(lo);
            }
            if (i < 0) return 0;
            char e = En[i];
            switch (e)
            {
                case ';': return 0xBA; // VK_OEM_1
                case '\'': return 0xDE; // VK_OEM_7
                case '[': return 0xDB; // VK_OEM_4
                case ']': return 0xDD; // VK_OEM_6
                case ',': return 0xBC; // VK_OEM_COMMA
                case '.': return 0xBE; // VK_OEM_PERIOD
                case '`': return 0xC0; // VK_OEM_3
                default: return (int)char.ToUpperInvariant(e);
            }
        }

        /// <summary>Конвертация готового текста между раскладками с сохранением регистра
        /// и двунаправленным маппингом Shift-символов (: < > " { } ~ ⇄ Ж Б Ю Э Х Ъ Ё).</summary>
        public static string MapText(string text, bool toRu)
        {
            if (string.IsNullOrEmpty(text)) return text;
            string srcLo = toRu ? En : Ru;
            string dstLo = toRu ? Ru : En;
            string srcHi = toRu ? EnUpper : RuUpper;
            string dstHi = toRu ? RuUpper : EnUpper;
            var sb = new StringBuilder(text.Length);
            for (int k = 0; k < text.Length; k++)
            {
                char c = text[k];
                int i = srcLo.IndexOf(c);
                if (i >= 0) { sb.Append(dstLo[i]); continue; }
                i = srcHi.IndexOf(c);
                if (i >= 0) { sb.Append(dstHi[i]); continue; }
                sb.Append(c);
            }
            return sb.ToString();
        }
    }

    /// <summary>Буфер последнего введённого слова из KeyRec.</summary>
    public class WordBuffer
    {
        private readonly List<KeyRec> _keys = new List<KeyRec>();
        public const int MaxLen = 40;
        public bool Overflowed { get; private set; }

        public int Count { get { return _keys.Count; } }

        public void Push(KeyRec rec)
        {
            if (Overflowed) return;
            if (_keys.Count >= MaxLen)
            {
                _keys.Clear();
                Overflowed = true;
                return;
            }
            _keys.Add(rec);
        }

        public void Pop()
        {
            if (_keys.Count > 0) _keys.RemoveAt(_keys.Count - 1);
        }

        public void Clear() { _keys.Clear(); Overflowed = false; }

        public List<KeyRec> Snapshot() { return new List<KeyRec>(_keys); }

        public void Restore(List<KeyRec> keys)
        {
            _keys.Clear();
            _keys.AddRange(keys);
            Overflowed = false;
        }
    }
}
