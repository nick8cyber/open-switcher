@echo off
setlocal
cd /d "%~dp0.."
set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe
if not exist "%CSC%" (
    echo ERROR: .NET Framework csc.exe not found
    exit /b 1
)
for %%I in ("%CSC%") do set "CSCDIR=%%~dpI"
"%CSC%" /nologo /codepage:65001 /target:exe /platform:anycpu /optimize+ ^
  /out:os_console.exe /win32manifest:app.manifest ^
  /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll ^
  /r:"%CSCDIR%WPF\UIAutomationClient.dll" /r:"%CSCDIR%WPF\UIAutomationTypes.dll" ^
  src\*.cs src\Core\*.cs src\UI\*.cs
if errorlevel 1 (
    echo BUILD FAILED
    exit /b 1
)
echo CONSOLE BUILD OK
