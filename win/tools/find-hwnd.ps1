param([string]$HexHwnd = "201E8")
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class W {
  public delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
}
'@

$target = [IntPtr][Convert]::ToInt32($HexHwnd, 16)
$found = $false
$cb = [W+EnumWindowsProc]{
  param($h, $l)
  if ($h -eq $script:target) {
    $script:found = $true
    $wpid = 0
    [W]::GetWindowThreadProcessId($h, [ref]$wpid) | Out-Null
    $sb = New-Object System.Text.StringBuilder 512
    [W]::GetWindowText($h, $sb, 512) | Out-Null
    $cn = New-Object System.Text.StringBuilder 256
    [W]::GetClassName($h, $cn, 256) | Out-Null
    $vis = [W]::IsWindowVisible($h)
    "hwnd=0x$HexHwnd visible=$vis"
    "title: " + $sb.ToString()
    "class: " + $cn.ToString()
    "pid:   $wpid"
    try {
      $p = Get-Process -Id $wpid -ErrorAction Stop
      "process: " + $p.ProcessName
      "path:    " + $p.Path
      try { $null = $p.Handle; "access:  process handle OK (not elevated)" }
      catch { "access:  CANNOT open handle -> window owner likely ELEVATED (admin)" }
    } catch { "process lookup failed: $_" }
  }
  return $true
}
[W]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
if (-not $found) { "hwnd=0x$HexHwnd not found among top-level windows (child window or already destroyed)" }
