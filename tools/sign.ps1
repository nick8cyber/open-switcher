# Подпись OpenSwitcher.exe локальным сертификатом подписи кода.
# Сертификат создаётся один раз и хранится в личном хранилище — все пересборки
# подписываются ИМ, поэтому репутация/доверие в COMODO не сбрасывается на каждом ребилде.
$ErrorActionPreference = "Continue"

$exe = "D:\Developing\tools\open-switcher\OpenSwitcher.exe"
$subject = "CN=OpenSwitcher Local"

$cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
    Where-Object { $_.Subject -eq $subject } | Select-Object -First 1

if (-not $cert)
{
    $cert = New-SelfSignedCertificate -Subject $subject -Type CodeSigningCert `
        -CertStoreLocation Cert:\CurrentUser\My -KeyUsage DigitalSignature `
        -NotAfter (Get-Date).AddYears(10)
    Write-Host ("certificate created: " + $cert.Thumbprint)
}

$sig = Set-AuthenticodeSignature -FilePath $exe -Certificate $cert
Write-Host ("sign status: " + $sig.Status)

# Один раз от админа: сделать сертификат доверенным издателем/корневым,
# чтобы COMODO доверял подписи (раскомментировать при запуске от администратора):
# Export-Certificate -Cert $cert -FilePath "D:\Developing\tools\open-switcher\tools\OpenSwitcherLocal.cer"
# Import-Certificate -FilePath "D:\Developing\tools\open-switcher\tools\OpenSwitcherLocal.cer" -CertStoreLocation Cert:\LocalMachine\TrustedPublisher
# Import-Certificate -FilePath "D:\Developing\tools\open-switcher\tools\OpenSwitcherLocal.cer" -CertStoreLocation Cert:\LocalMachine\Root
