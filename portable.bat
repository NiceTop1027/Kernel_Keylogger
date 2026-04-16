@echo off
setlocal
chcp 65001 >nul 2>&1
title Portable Console Input

where powershell >nul 2>&1
if errorlevel 1 (
    echo PowerShell 을 찾을 수 없습니다.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0portable.ps1" %*
set ERR=%errorlevel%
if not "%ERR%"=="0" (
    echo.
    echo Portable input failed.
    echo Error log: %~dp0portable_error.log
    pause
)
exit /b %ERR%
