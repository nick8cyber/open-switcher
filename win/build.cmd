@echo off
setlocal
cd /d "%~dp0"

set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe
if not exist "%CSC%" (
    echo ERROR: .NET Framework csc.exe not found
    exit /b 1
)

rem каталог компилятора: UIA-сборки лежат не рядом с csc.exe, а в подпапке WPF
for %%I in ("%CSC%") do set "CSCDIR=%%~dpI"

if not exist tools\app.ico (
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\make-icon.ps1
)

"%CSC%" /nologo /target:winexe /platform:anycpu /optimize+ ^
  /out:OpenSwitcher.exe ^
  /win32icon:tools\app.ico ^
  /win32manifest:app.manifest ^
  /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll ^
  /r:"%CSCDIR%WPF\UIAutomationClient.dll" /r:"%CSCDIR%WPF\UIAutomationTypes.dll" ^
  src\*.cs src\Core\*.cs src\UI\*.cs

if errorlevel 1 (
    echo BUILD FAILED
    exit /b 1
)

rem --- подпись стабильным сертификатом (чтобы COMODO не сбрасывал рейтинг на каждом ребилде)
powershell -NoProfile -ExecutionPolicy Bypass -File tools\sign.ps1

echo BUILD OK: OpenSwitcher.exe

rem --- self-test детектора раскладки (вывод в stdout) ---
OpenSwitcher.exe --selftest "%~dp0selftest_result.txt"
exit /b 0
