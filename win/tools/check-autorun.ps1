$r = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -ErrorAction SilentlyContinue
Write-Host ("RunKey = " + $r.OpenSwitcher)
$ini = Join-Path $env:APPDATA "OpenSwitcher\settings.ini"
Write-Host ("IniExists = " + (Test-Path $ini))
if (Test-Path $ini) {
    Get-Content $ini | ForEach-Object {
        if ($_ -match "StartWithWindows|DefaultsV|Paused") { Write-Host $_ }
    }
}
