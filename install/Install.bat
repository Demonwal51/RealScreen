@echo off
title Real Screen - install
if not exist "%~dp0files\setup.ps1" (
    echo Unzip the whole archive first, then run Install.bat from the unzipped folder.
    echo.
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0files\setup.ps1" -Action install
echo.
pause
