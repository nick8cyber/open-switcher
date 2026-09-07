using System;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;
using OpenSwitcher.Core;
using OpenSwitcher.UI;

namespace OpenSwitcher
{
    internal static class Program
    {
        public static Engine Engine;
        public static TrayService Tray;

        [STAThread]
        private static void Main(string[] args)
        {
            AppDomain.CurrentDomain.UnhandledException += delegate(object s, UnhandledExceptionEventArgs e)
            {
                try { System.IO.File.WriteAllText("os_crash.log", e.ExceptionObject.ToString()); } catch (Exception) { }
            };
            try
            {
                RunMain(args);
            }
            catch (Exception ex)
            {
                try { System.IO.File.WriteAllText("os_crash.log", ex.ToString()); } catch (Exception) { }
                Environment.Exit(3);
            }
        }

        private static void RunMain(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            bool selfTest = false, showSettings = false;
            string outPath = "selftest_result.txt";
            string simWord = null;
            for (int i = 0; i < args.Length; i++)
            {
                if (args[i] == "--selftest") selfTest = true;
                else if (args[i] == "--settings") showSettings = true;
                else if (args[i] == "--simtest") { if (i + 1 < args.Length) simWord = args[i + 1]; }
                else if (i > 0 && args[i - 1] == "--selftest") outPath = args[i];
            }

            if (selfTest)
            {
                Environment.Exit(SelfTest.Run(outPath));
                return;
            }
            if (simWord != null)
            {
                Environment.Exit(SelfTest.Simulate(simWord, 1.0));
                return;
            }

            bool created;
            var mux = new Mutex(true, "OpenSwitcher_7F3A_Mutex", out created);
            if (!created)
            {
                MessageBox.Show("OpenSwitcher уже запущен — ищите иконку в трее.",
                    "OpenSwitcher", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            var settings = SettingsStore.Load();
            UiTheme.ApplyMode(settings.ThemeMode); // тема до создания UI
            UiTheme.Changed += OnThemeChanged;
            Microsoft.Win32.SystemEvents.UserPreferenceChanged += delegate
            {
                UiTheme.RefreshFromSystem();
            };

            Engine = new Engine(settings);
            Tray = new TrayService(Engine);
            Tray.Init();
            if (showSettings) Tray.ShowSettings();
            Application.Run(new ApplicationContext());
            GC.KeepAlive(mux);
        }

        private static void OnThemeChanged()
        {
            foreach (Form f in Application.OpenForms)
            {
                var s = f as OpenSwitcher.UI.SettingsForm;
                if (s != null) s.ApplyTheme();
                else f.Invalidate(true);
            }
        }

        public static void SetAutostart(bool on)
        {
            try
            {
                using (var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true))
                {
                    if (k == null) return;
                    if (on)
                        k.SetValue("OpenSwitcher", "\"" + Assembly.GetExecutingAssembly().Location + "\"");
                    else
                        k.DeleteValue("OpenSwitcher", false);
                }
            }
            catch (Exception) { }
        }

        public static bool GetAutostart()
        {
            try
            {
                using (var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"))
                {
                    if (k == null) return false;
                    return k.GetValue("OpenSwitcher") != null;
                }
            }
            catch (Exception) { return false; }
        }
    }
}
