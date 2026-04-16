@echo off
setlocal
chcp 65001 >nul 2>&1
title Keyboard Input Setup

set ROOT=%~dp0

if /i "%~1"=="portable" (
    shift
    call "%ROOT%portable.bat" %*
    exit /b %errorlevel%
)

if /i "%~1"=="gui" (
    shift
    call "%ROOT%gui.bat" %*
    exit /b %errorlevel%
)

if /i "%~1"=="driver" goto :driver_retired
if /i "%~1"=="install" goto :driver_retired

call "%ROOT%gui.bat" %*
exit /b %errorlevel%

:driver_retired
echo.
echo  =========================================
echo    User-Mode GUI
echo  =========================================
echo.
echo    Kernel/WDK driver mode is retired.
echo    No WDK, Python, test signing, or driver install is required.
echo.
echo    Available commands:
echo      setup.bat
echo      setup.bat gui
echo      gui.bat
echo      kernel_keylogger on
echo      kernel_keylogger off
echo      setup.bat portable
echo.
echo    Starting GUI instead...
echo.
call "%ROOT%gui.bat"
exit /b %errorlevel%
