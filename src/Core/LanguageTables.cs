using System;
using System.Collections.Generic;

namespace OpenSwitcher.Core
{
    /// <summary>
    /// Оценка "похожести" слова на английский / русский (в латинице или кириллице)
    /// по частотам букв и биграмм. Тем же методом работали ранние Punto/Keyboard Ninja.
    /// </summary>
    public static class LanguageTables
    {
        private const double UniFloor = 0.01;   // % для незнакомой буквы
        private const double BiFloor = 0.02;    // % для незнакомой биграммы
        private const double UniWeight = 0.6;

        /// <summary>Порог "уверенности", при котором слово считается набранным не в той раскладке.</summary>
        public const double BaseMargin = 0.22;
        /// <summary>Ниже такого скора целевое слово не бывает — защита от мусорных конвертаций.</summary>
        public const double HardFloor = -1.35;

        private static readonly Dictionary<char, double> EnUni = new Dictionary<char, double>();
        private static readonly Dictionary<char, double> RuUni = new Dictionary<char, double>();
        private static readonly Dictionary<string, double> EnBi = new Dictionary<string, double>();
        private static readonly Dictionary<string, double> RuBi = new Dictionary<string, double>();

        private static readonly string[] RuKeyboardRows = { "йцукенгшщзхъ", "фывапролджэ", "ячсмитьбюё" };
        private static readonly string[] EnKeyboardRows = { "qwertyuiop", "asdfghjkl", "zxcvbnm" };

        static LanguageTables()
        {
            Load(EnUni, "a:8.2,b:1.5,c:2.8,d:4.3,e:12.7,f:2.2,g:2.0,h:6.1,i:7.0,j:0.15,k:0.77,l:4.0,m:2.4,n:6.7,o:7.5,p:1.9,q:0.095,r:6.0,s:6.3,t:9.1,u:2.8,v:0.98,w:2.4,x:0.15,y:2.0,z:0.074");
            Load(RuUni, "о:11.7,е:8.5,а:8.0,и:7.4,н:6.7,т:6.3,с:5.5,р:4.7,в:4.5,л:4.3,к:3.5,м:3.2,д:3.0,п:2.8,у:2.6,я:2.0,ы:1.9,з:1.6,ь:1.4,б:1.4,г:1.3,ч:1.0,й:0.9,х:0.8,ж:0.7,ю:0.6,ш:0.6,ц:0.4,щ:0.3,э:0.3,ф:0.2,ъ:0.02,ё:0.05");
            LoadBi(EnBi, "th:3.56,he:3.07,in:2.43,er:2.33,an:2.03,re:1.99,on:1.91,at:1.66,en:1.63,nd:1.62,ti:1.57,es:1.55,or:1.54,te:1.49,of:1.46,ed:1.42,is:1.36,it:1.29,al:1.26,ar:1.25,st:1.22,to:1.20,nt:1.17,ng:1.14,se:1.10,ha:1.08,as:1.07,ou:1.05,io:1.04,le:1.03,ve:1.01,co:0.98,me:0.97,de:0.96,hi:0.94,ri:0.93,ro:0.92,ic:0.91,ne:0.90,ea:0.89,ra:0.88,ce:0.87,li:0.86,ch:0.83,ll:0.82,be:0.80,ma:0.79,si:0.78,om:0.77,ur:0.76,ca:0.75,el:0.74,ta:0.73,la:0.73,ns:0.71,di:0.70,fo:0.69,ho:0.68,pe:0.67,ec:0.66,pr:0.65,no:0.64,ct:0.63,us:0.62,ac:0.61,ot:0.60,il:0.59,tr:0.58,ly:0.57,nc:0.56,et:0.55,ut:0.54,ss:0.53,so:0.52,rs:0.51,un:0.50,lo:0.49,wa:0.48,ge:0.47,ie:0.46,wh:0.45,ee:0.44,wi:0.43,em:0.42,ad:0.41,ol:0.40,rt:0.39,po:0.38,we:0.37,na:0.36,ul:0.35,ni:0.34,ts:0.33,mo:0.32,ow:0.31,pa:0.30,im:0.29,mi:0.28,ai:0.27,sh:0.26,ir:0.25,su:0.24,qu:0.24,id:0.23,os:0.22,iv:0.21,ia:0.20,am:0.19,fi:0.18,ci:0.17,vi:0.16,pl:0.15,ig:0.14,tu:0.13,ev:0.12,ld:0.11,ry:0.10,ty:0.10,mp:0.09,fe:0.09,bl:0.08,ab:0.08,gh:0.08,ke:0.08,kn:0.07,ck:0.07,ui:0.07,sa:0.07,oo:0.07");
            LoadBi(RuBi, "ст:2.65,но:2.04,ен:1.88,то:1.82,на:1.73,ов:1.55,ни:1.54,ра:1.48,во:1.42,ко:1.35,ет:1.33,го:1.31,со:1.19,ти:1.18,не:1.12,ес:1.05,ос:1.03,ло:1.03,ер:1.01,ро:0.99,по:0.96,ол:0.95,ва:0.92,ал:0.90,ая:0.86,ма:0.84,нт:0.83,от:0.80,да:0.79,ви:0.77,ка:0.77,ла:0.76,ел:0.75,ре:0.74,та:0.73,ат:0.73,ки:0.70,ия:0.70,ры:0.69,ск:0.67,чи:0.65,ме:0.64,ся:0.62,ам:0.61,ав:0.59,ил:0.58,чн:0.56,ыв:0.55,мо:0.54,ог:0.53,ым:0.52,ис:0.51,ем:0.50,ой:0.49,ль:0.48,од:0.47,до:0.46,из:0.45,ую:0.44,ан:0.43,ор:0.42,ей:0.41,ин:0.40,ых:0.39,ша:0.38,ны:0.37,ту:0.36,ми:0.35,ук:0.35,ке:0.35,ру:0.34,тв:0.33,ом:0.31,ве:0.30,нь:0.30,жд:0.29,нн:0.29,пр:0.28,ул:0.27,аз:0.26,об:0.26,тр:0.25,он:0.25,ик:0.24,ар:0.24,кл:0.23,ку:0.22,еп:0.21,ед:0.21,им:0.20,ие:0.20,уж:0.19,ак:0.19,ок:0.19,щи:0.18,ек:0.18,кс:0.18,зн:0.17,ри:0.17,че:0.17,ну:0.17,бр:0.16");
        }

        private static void Load(Dictionary<char, double> d, string src)
        {
            foreach (string pair in src.Split(','))
            {
                string[] kv = pair.Split(':');
                if (kv.Length == 2) d[kv[0][0]] = ParseD(kv[1]);
            }
        }

        private static void LoadBi(Dictionary<string, double> d, string src)
        {
            foreach (string pair in src.Split(','))
            {
                string[] kv = pair.Split(':');
                if (kv.Length == 2 && kv[0].Length == 2) d[kv[0]] = ParseD(kv[1]);
            }
        }

        private static double ParseD(string s)
        {
            double v; double.TryParse(s.Replace(".", ","), out v);
            if (v <= 0) double.TryParse(s, out v);
            return v;
        }

        public static bool IsCyrillic(char c) { return c >= 0x0400 && c <= 0x04FF; }
        public static bool IsLatin(char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }

        /// <summary>0 = русский, 1 = английский, -1 = смешанно/не буквы.</summary>
        public static int LangOf(string s)
        {
            int ru = 0, en = 0;
            foreach (char c in s)
            {
                if (IsCyrillic(c)) ru++;
                else if (IsLatin(c)) en++;
            }
            if (ru > 0 && en == 0) return 0;
            if (en > 0 && ru == 0) return 1;
            return -1;
        }

        public static string LettersOnly(string s)
        {
            var sb = new System.Text.StringBuilder(s.Length);
            foreach (char c in s)
                if (IsCyrillic(c) || IsLatin(c)) sb.Append(c);
            return sb.ToString();
        }

        /// <summary>Нормированный скор: чем ближе к 0, тем "естественнее" слово для языка.</summary>
        public static double Score(string word, int lang)
        {
            string w = word.ToLowerInvariant();
            int n = w.Length;
            if (n == 0) return -3;
            double bi = 0, uni = 0;
            for (int i = 0; i < n; i++)
            {
                double f;
                if (lang == 0) RuUni.TryGetValue(w[i], out f); else EnUni.TryGetValue(w[i], out f);
                if (f <= 0) f = UniFloor;
                uni += Math.Log10(f);
            }
            for (int i = 0; i + 1 < n; i++)
            {
                double f;
                if (lang == 0) RuBi.TryGetValue(w.Substring(i, 2), out f); else EnBi.TryGetValue(w.Substring(i, 2), out f);
                if (f <= 0) f = BiFloor;
                bi += Math.Log10(f);
            }
            double score = (bi + UniWeight * uni) / (1.0 + UniWeight) / n;
            if (score < -3) score = -3;
            return score;
        }

        /// <summary>Бонус за слова-«дорожки клавиатуры»: qwerty -> йцукен и т.п.</summary>
        private static double RowBoost(string word, int lang)
        {
            string w = word.ToLowerInvariant();
            if (w.Length < 4) return 0;
            string[] rows = lang == 0 ? RuKeyboardRows : EnKeyboardRows;
            foreach (string row in rows)
                if (row.StartsWith(w) || w.StartsWith(row)) return 0.6;
            return 0;
        }

        public static bool HasVowel(string text, int lang)
        {
            const string rv = "аеёиоуыэюя";
            const string ev = "aeiouy";
            string v = lang == 0 ? rv : ev;
            string t = text.ToLowerInvariant();
            foreach (char c in t)
                if (v.IndexOf(c) >= 0) return true;
            return false;
        }

        /// <summary>
        /// Решение «слово набрано не в той раскладке». cur — как набрано, best — лучший другой вариант.
        /// </summary>
        public static bool ShouldConvert(string curText, int curLang, double curScore,
                                         string bestText, int bestLang, double bestScore,
                                         double sensitivity)
        {
            if (curLang < 0 || bestLang < 0 || curLang == bestLang) return false;
            if (string.IsNullOrEmpty(bestText)) return false;
            double margin = BaseMargin / Math.Max(0.3, sensitivity);
            double b = bestScore + RowBoost(bestText, bestLang);
            if (b < curScore + margin) return false;
            if (b < HardFloor) return false;
            if (!HasVowel(bestText, bestLang)) return false;
            return true;
        }
    }
}
