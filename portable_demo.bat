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
exit /b %errorlevel%
