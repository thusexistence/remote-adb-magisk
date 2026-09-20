@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-remote-adb-all.ps1"
set RC=%ERRORLEVEL%
echo.
if not "%RC%"=="0" echo Update finished with errors. Exit code: %RC%
pause
exit /b %RC%

