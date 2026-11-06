@echo off
title Real Screen - uninstall
if not exist "%~dp0files\setup.ps1" (
    echo Unzip the whole archive first, then run Uninstall.bat from the unzipped folder.
    echo.
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0files\setup.ps1" -Action uninstall
echo.
pause
