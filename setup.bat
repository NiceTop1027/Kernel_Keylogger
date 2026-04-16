@echo off
setlocal
chcp 65001 >nul 2>&1
title Keyboard Input Demo Setup

set ROOT=%~dp0

if /i "%~1"=="portable" (
    shift
    call "%ROOT%portable_demo.bat" %*
    exit /b %errorlevel%
)

if /i "%~1"=="gui" (
    shift
    call "%ROOT%gui_demo.bat" %*
    exit /b %errorlevel%
)

if /i "%~1"=="driver" goto :driver_retired
if /i "%~1"=="install" goto :driver_retired

call "%ROOT%gui_demo.bat" %*
exit /b %errorlevel%

:driver_retired
echo.
echo  =========================================
echo    User-Mode GUI Demo
echo  =========================================
echo.
echo    Kernel/WDK driver mode is retired.
echo    No WDK, Python, test signing, or driver install is required.
echo.
echo    Available commands:
echo      setup.bat
echo      setup.bat gui
echo      gui_demo.bat
echo      kernel_keylogger on
echo      kernel_keylogger off
echo      setup.bat portable
echo.
echo    Starting GUI demo instead...
echo.
call "%ROOT%gui_demo.bat"
exit /b %errorlevel%
