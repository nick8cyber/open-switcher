# Установка сертификата подписи OpenSwitcher в доверенные хранилища Windows.
# Запускать один раз; при необходимости сам запрашивает права администратора (UAC).
$id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$admin = (New-Object System.Security.Principal.WindowsPrincipal($id)).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin)
{
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

$cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
    Where-Object { $_.Subject -eq "CN=OpenSwitcher Local" } | Select-Object -First 1
if (-not $cert) { Write-Host "certificate not found"; exit 1 }

$cer = Join-Path $env:TEMP "OpenSwitcherLocal.cer"
Export-Certificate -Cert $cert -FilePath $cer | Out-Null
Import-Certificate -FilePath $cer -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
Import-Certificate -FilePath $cer -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null
Remove-Item $cer -ErrorAction SilentlyContinue
Write-Host "certificate installed to LocalMachine Root + TrustedPublisher"
