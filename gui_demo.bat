@echo off
setlocal
chcp 65001 >nul 2>&1

start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0gui_demo.ps1" %*
exit /b 0
