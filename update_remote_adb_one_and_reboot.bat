@echo off
setlocal
echo Enter the physical device ID shown by the preview, for example: 1a12da74
set /p DEVICE_ID=Device ID: 
if "%DEVICE_ID%"=="" (
    echo No device ID entered. Nothing changed.
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-remote-adb-all.ps1" -TargetDeviceId "%DEVICE_ID%" -RebootAfterInstall
set RC=%ERRORLEVEL%
echo.
if not "%RC%"=="0" echo Update finished with errors. Exit code: %RC%
pause
exit /b %RC%
