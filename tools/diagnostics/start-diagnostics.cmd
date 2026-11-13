@echo off
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Collect-ArtemisMemory.ps1" %*
set "diagnosticsExit=%ERRORLEVEL%"
echo.
pause
exit /b %diagnosticsExit%
