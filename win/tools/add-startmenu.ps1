$ErrorActionPreference = "Stop"
$target = "D:\Developing\tools\open-switcher\OpenSwitcher.exe"
$dir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
$lnk = Join-Path $dir "OpenSwitcher.lnk"

$ws = New-Object -ComObject WScript.Shell
$s = $ws.CreateShortcut($lnk)
$s.TargetPath = $target
$s.WorkingDirectory = Split-Path $target
$s.IconLocation = $target
$s.Description = "OpenSwitcher - avtoispravlenie raskladki Ru<->En"
$s.Save()
Write-Host ("created: " + (Test-Path $lnk))
