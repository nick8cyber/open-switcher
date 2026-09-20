$ErrorActionPreference = "Continue"
$subj = "CN=OpenSwitcher Local"

Write-Host "=== CodeSigning cert (CurrentUser\My):"
Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
    Where-Object { $_.Subject -eq $subj } |
    ForEach-Object { Write-Host ("  found: " + $_.Thumbprint + "  expires " + $_.NotAfter) }

Write-Host "=== LocalMachine\TrustedPublisher:"
$tp = Get-ChildItem Cert:\LocalMachine\TrustedPublisher -ErrorAction SilentlyContinue
if ($tp) { $tp | ForEach-Object { Write-Host ("  " + $_.Subject) } } else { Write-Host "  EMPTY" }

Write-Host "=== LocalMachine\Root (OpenSwitcher):"
$root = Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue |
    Where-Object { $_.Subject -eq $subj }
if ($root) { $root | ForEach-Object { Write-Host ("  found: " + $_.Thumbprint) } } else { Write-Host "  NOT IN ROOT" }

Write-Host "=== exe signature:"
$sig = Get-AuthenticodeSignature "D:\Developing\tools\open-switcher\OpenSwitcher.exe"
Write-Host ("  status: " + $sig.Status)
if ($sig.SignerCertificate) { Write-Host ("  signer: " + $sig.SignerCertificate.Subject) }
