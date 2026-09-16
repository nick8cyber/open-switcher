$ErrorActionPreference = "Stop"
$file = "D:\Developing\tools\open-switcher\src\Core\Engine.cs"
$c = [IO.File]::ReadAllText($file)
$nl = [char]10

$anchor = '            FireInfo(lang == 0 ? "' + [char]0x420 + [char]0x423 + [char]0x421 + '" : "ENG");' + $nl + '        }'
$method = $nl +
'        /// <summary>Switch lag check: verify layout applied after 400ms,' + $nl +
'        /// else synchronous fallback AttachThreadInput + ActivateKeyboardLayout.</summary>' + $nl +
'        private void VerifySwitch(IntPtr fgHwnd, IntPtr target)' + $nl +
'        {' + $nl +
'            var t = new System.Windows.Forms.Timer { Interval = 400 };' + $nl +
'            t.Tick += delegate' + $nl +
'            {' + $nl +
'                t.Stop();' + $nl +
'                t.Dispose();' + $nl +
'                try' + $nl +
'                {' + $nl +
'                    IntPtr cur = LayoutService.GetForegroundHkl(fgHwnd);' + $nl +
'                    if (cur == target) return;' + $nl +
'                    Log("switch lag/ignored -> ActivateKeyboardLayout fallback");' + $nl +
'                    uint pid;' + $nl +
'                    uint tid = Native.GetWindowThreadProcessId(fgHwnd, out pid);' + $nl +
'                    uint mine = Native.GetCurrentThreadId();' + $nl +
'                    bool attached = false;' + $nl +
'                    if (tid != 0 && tid != mine) attached = Native.AttachThreadInput(mine, tid, true);' + $nl +
'                    Native.ActivateKeyboardLayout(target, 0);' + $nl +
'                    if (attached) Native.AttachThreadInput(mine, tid, false);' + $nl +
'                }' + $nl +
'                catch (Exception) { }' + $nl +
'            };' + $nl +
'        }'

$rus = [string][char]0x420 + [char]0x423 + [char]0x421
$insert = '            FireInfo(lang == 0 ? "' + $rus + '" : "ENG");' + $nl + '            VerifySwitch(_fgHwnd, target);'

if (-not $c.Contains($anchor)) { Write-Host "ANCHOR NOT FOUND"; exit 1 }
$c = $c.Replace($anchor, $insert + $method)
[IO.File]::WriteAllText($file, $c)
Write-Host "patched OK"
