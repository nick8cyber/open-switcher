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

        /// <summary>VK-код клавиши, которой набирается символ ru/en раскладки.</summary>
        public static int VkOfChar(char c, bool fromRu)
        {
            char lo = char.ToLowerInvariant(c);
            int i = fromRu ? Ru.IndexOf(lo) : En.IndexOf(lo);
            if (i < 0) return 0;
            return (int)char.ToUpperInvariant(En[i]);
        }

        /// <summary>Конвертация готового текста между раскладками с сохранением регистра.</summary>
        public static string MapText(string text, bool toRu)
        {
            var sb = new StringBuilder(text.Length);
            foreach (char c in text)
            {
                char lo = char.ToLowerInvariant(c);
                int i = toRu ? En.IndexOf(lo) : Ru.IndexOf(lo);
                if (i < 0) { sb.Append(c); continue; }
                char m = toRu ? Ru[i] : En[i];
                sb.Append(char.IsUpper(c) ? char.ToUpperInvariant(m) : m);
            }
            return sb.ToString();
        }
    }

    /// <summary>Буфер последнего введённого слова из KeyRec.</summary>
    public class WordBuffer
    {
        private readonly List<KeyRec> _keys = new List<KeyRec>();
        public const int MaxLen = 40;

        public int Count { get { return _keys.Count; } }

        public void Push(KeyRec rec)
        {
            _keys.Add(rec);
            if (_keys.Count > MaxLen) _keys.RemoveRange(0, 10);
        }

        public void Pop()
        {
            if (_keys.Count > 0) _keys.RemoveAt(_keys.Count - 1);
        }

        public void Clear() { _keys.Clear(); }

        public List<KeyRec> Snapshot() { return new List<KeyRec>(_keys); }

        public void Restore(List<KeyRec> keys)
        {
            _keys.Clear();
            _keys.AddRange(keys);
        }
    }
}
