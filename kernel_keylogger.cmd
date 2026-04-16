@echo off
setlocal
chcp 65001 >nul 2>&1

set ROOT=%~dp0
set PID_FILE=%ROOT%gui.pid

if /i "%~1"=="on" goto :on
if /i "%~1"=="off" goto :off
if /i "%~1"=="gui" goto :on
if /i "%~1"=="portable" (
    call "%ROOT%portable.bat"
    exit /b %errorlevel%
)
if "%~1"=="" goto :python_view

goto :python_view

:on
call "%ROOT%gui.bat"
echo GUI start requested.
exit /b 0

:off
if not exist "%PID_FILE%" (
    echo GUI is not running.
    exit /b 0
)

set /p APP_PID=<"%PID_FILE%"
if not defined APP_PID (
    del /f /q "%PID_FILE%" >nul 2>&1
    echo Cleared stale pid file.
    exit /b 0
)

taskkill /PID %APP_PID% /T /F >nul 2>&1
if errorlevel 1 (
    del /f /q "%PID_FILE%" >nul 2>&1
    echo GUI was not running. Cleared stale pid file.
    exit /b 0
)

del /f /q "%PID_FILE%" >nul 2>&1
echo GUI stopped.
exit /b 0

:python_view
where python >nul 2>&1
if errorlevel 1 (
    echo Usage:
    echo   kernel_keylogger on
    echo   kernel_keylogger off
    echo   kernel_keylogger portable
    echo   kernel_keylogger --tail 50
    echo   kernel_keylogger --stats
    exit /b 1
)

python "%ROOT%kernel_keylogger.py" %*
exit /b %errorlevel%
