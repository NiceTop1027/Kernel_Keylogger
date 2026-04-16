@echo off
setlocal
chcp 65001 >nul 2>&1
title Portable Console Demo

where powershell >nul 2>&1
if errorlevel 1 (
    echo PowerShell 을 찾을 수 없습니다.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0portable_demo.ps1" %*
set ERR=%errorlevel%
if not "%ERR%"=="0" (
    echo.
    echo Portable demo 실행 실패. 위 오류 메시지를 확인하세요.
    pause
)
exit /b %ERR%
