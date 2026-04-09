@echo off
setlocal EnableDelayedExpansion
chcp 65001 >nul 2>&1
title KeyLogger Setup

:: ================================================================
::  setup.bat — 원클릭 완전 자동 설치
::
::  자동 처리 항목:
::    [0] 관리자 권한 확인
::    [1] Python 자동 설치 (winget)
::    [2] pip 패키지 설치 (requirements.txt)
::    [3] WDK / VS2022 확인
::    [4] 드라이버 빌드 (KeyFilter.sys)
::    [5] 드라이버 서명 (테스트 인증서 자동 생성)
::    [6] 드라이버 설치 및 시작
::    [7] PATH 등록 (kernel_keylogger 명령)
::
::  필수 조건: Windows 10/11 VM + 관리자 권한
:: ================================================================

set ROOT=%~dp0
set DRIVER_SRC=%ROOT%driver
set DRIVER_SYS=%ROOT%driver\KeyFilter.sys
set SERVICE=KeyFilter
set CERT_NAME=KeyFilterTestCert
set ERRORS=0

call :header

:: ────────────────────────────────────────────────────────────────
:: STEP 0: 관리자 권한
:: ────────────────────────────────────────────────────────────────
call :step 0 7 "관리자 권한 확인"
net session >nul 2>&1
if errorlevel 1 (
    call :fail "관리자 권한 없음 — 우클릭 후 '관리자로 실행'"
    pause & exit /b 1
)
call :ok

:: ────────────────────────────────────────────────────────────────
:: STEP 1: Python 설치
:: ────────────────────────────────────────────────────────────────
call :step 1 7 "Python 확인 및 설치"
python --version >nul 2>&1
if not errorlevel 1 (
    for /f "tokens=*" %%v in ('python --version 2^>^&1') do call :ok "%%v 발견"
    goto :pip_install
)

:: winget 으로 자동 설치 시도
echo         Python 없음 — winget 으로 자동 설치 시도...
winget --version >nul 2>&1
if errorlevel 1 (
    call :fail "winget 도 없음"
    echo.
    echo    수동 설치: https://python.org/downloads
    echo    설치 후 이 스크립트를 다시 실행하세요.
    pause & exit /b 1
)

winget install -e --id Python.Python.3.12 --silent --accept-package-agreements --accept-source-agreements
if errorlevel 1 (
    call :fail "Python 자동 설치 실패 — https://python.org 에서 수동 설치"
    pause & exit /b 1
)

:: PATH 갱신 후 재확인
for /f "skip=2 tokens=3*" %%a in ('reg query "HKCU\Environment" /v PATH 2^>nul') do set "UPATH=%%a %%b"
python --version >nul 2>&1
if errorlevel 1 (
    call :warn "설치됐지만 PATH 반영 안 됨 — CMD 재시작 후 재실행 권장"
) else (
    call :ok "Python 설치 완료"
)

:pip_install
:: ────────────────────────────────────────────────────────────────
:: STEP 2: pip 패키지 설치
:: ────────────────────────────────────────────────────────────────
call :step 2 7 "pip 패키지 설치 (requirements.txt)"

python -m pip install --upgrade pip --quiet 2>nul

if exist "%ROOT%requirements.txt" (
    python -m pip install -r "%ROOT%requirements.txt" --quiet 2>nul
    if errorlevel 1 (
        call :warn "일부 패키지 설치 실패 (표준 라이브러리만 사용하므로 무시 가능)"
    ) else (
        call :ok "패키지 설치 완료 (현재 외부 패키지 없음)"
    )
) else (
    call :ok "requirements.txt 없음 — 건너뜀"
)

python -c "import ctypes, sqlite3, struct, argparse; print('stdlib OK')" >nul 2>&1
if errorlevel 1 (
    call :fail "Python 표준 라이브러리 임포트 실패"
    pause & exit /b 1
)
call :ok "Python 모듈 검증 완료"

:: ────────────────────────────────────────────────────────────────
:: STEP 3: Visual Studio 2022 + WDK 확인
:: ────────────────────────────────────────────────────────────────
call :step 3 7 "Visual Studio 2022 + WDK 확인"

set MSBUILD=
for %%e in (Community Professional Enterprise BuildTools) do (
    set TRY="%ProgramFiles%\Microsoft Visual Studio\2022\%%e\MSBuild\Current\Bin\MSBuild.exe"
    if exist !TRY! set MSBUILD=!TRY!
)
if not defined MSBUILD (
    call :fail "Visual Studio 2022 없음"
    echo.
    echo    설치 방법:
    echo      1. winget install Microsoft.VisualStudio.2022.BuildTools
    echo      2. VS Installer 에서 "C++를 사용한 데스크톱 개발" 선택
    echo      3. WDK: https://learn.microsoft.com/windows-hardware/drivers/download-the-wdk
    echo.
    set /p SKIP="VS/WDK 없이 계속 (드라이버 빌드 건너뜀)? [Y/N]: "
    if /i "!SKIP!"=="Y" goto :skip_build
    pause & exit /b 1
)
call :ok "MSBuild 발견"

set WDK_FOUND=0
for /d %%v in ("%ProgramFiles(x86)%\Windows Kits\10\bin\10.*") do (
    if exist "%%v\x64\makecert.exe" set WDK_FOUND=1
)
if "!WDK_FOUND!"=="0" (
    call :warn "WDK 없음 — 서명 없이 빌드 진행"
    echo         WDK 설치: https://learn.microsoft.com/windows-hardware/drivers/download-the-wdk
)

:: ────────────────────────────────────────────────────────────────
:: STEP 4: 드라이버 빌드
:: ────────────────────────────────────────────────────────────────
call :step 4 7 "드라이버 빌드"
if not exist "%DRIVER_SRC%\KeyFilter.vcxproj" (
    call :fail "KeyFilter.vcxproj 없음: %DRIVER_SRC%"
    pause & exit /b 1
)

%MSBUILD% "%DRIVER_SRC%\KeyFilter.vcxproj" ^
    /p:Configuration=Release /p:Platform=x64 ^
    /nologo /verbosity:minimal ^
    /p:OutDir="%DRIVER_SRC%\bin\\" 2>&1 | findstr /i "error warning"

if not exist "%DRIVER_SRC%\bin\KeyFilter.sys" (
    call :fail "빌드 결과물 없음 — VS 에서 직접 빌드해서 오류 확인"
    pause & exit /b 1
)
copy /y "%DRIVER_SRC%\bin\KeyFilter.sys" "%DRIVER_SYS%" >nul
call :ok "KeyFilter.sys 생성 완료"
goto :sign

:skip_build
if not exist "%DRIVER_SYS%" (
    call :fail "KeyFilter.sys 없음 — 빌드 없이 설치 불가"
    pause & exit /b 1
)
call :warn "기존 KeyFilter.sys 사용"

:sign
:: ────────────────────────────────────────────────────────────────
:: STEP 5: 드라이버 서명
:: ────────────────────────────────────────────────────────────────
call :step 5 7 "드라이버 서명 (테스트 인증서)"

set MAKECERT=
set SIGNTOOL=
for /d %%v in ("%ProgramFiles(x86)%\Windows Kits\10\bin\10.*") do (
    if exist "%%v\x64\makecert.exe" (
        set MAKECERT="%%v\x64\makecert.exe"
        set SIGNTOOL="%%v\x64\signtool.exe"
    )
)

if not defined MAKECERT (
    call :warn "WDK 서명 도구 없음 — 서명 건너뜀"
    goto :install_driver
)

certutil -store PrivateCertStore "%CERT_NAME%" >nul 2>&1
if errorlevel 1 (
    %MAKECERT% -r -pe -ss root -sr localMachine ^
        -n "CN=%CERT_NAME% Root" ^
        -eku 1.3.6.1.5.5.7.3.3 ^
        "%ROOT%%CERT_NAME%Root.cer" >nul 2>&1
    %MAKECERT% -pe -ss PrivateCertStore ^
        -n "CN=%CERT_NAME%" ^
        -eku 1.3.6.1.5.5.7.3.3 ^
        -is root -ir localMachine ^
        -in "%CERT_NAME% Root" ^
        "%ROOT%%CERT_NAME%.cer" >nul 2>&1
)

%SIGNTOOL% sign /s PrivateCertStore /n "%CERT_NAME%" ^
    /fd sha256 /t http://timestamp.digicert.com ^
    "%DRIVER_SYS%" >nul 2>&1
if errorlevel 1 (
    call :warn "서명 실패 (타임스탬프 서버 응답 없을 수 있음 — 계속 진행)"
) else (
    call :ok "서명 완료"
)

:install_driver
:: ────────────────────────────────────────────────────────────────
:: STEP 6: 드라이버 설치 및 시작
:: ────────────────────────────────────────────────────────────────
call :step 6 7 "드라이버 설치"

sc query %SERVICE% >nul 2>&1
if not errorlevel 1 (
    sc stop %SERVICE% >nul 2>&1
    timeout /t 1 /nobreak >nul
    sc delete %SERVICE% >nul 2>&1
    timeout /t 1 /nobreak >nul
)

sc create %SERVICE% type= kernel start= demand ^
    binPath= "%DRIVER_SYS%" ^
    DisplayName= "Keyboard Filter (Research)" >nul 2>&1
if errorlevel 1 (
    call :fail "sc create 실패"
    pause & exit /b 1
)

sc start %SERVICE% >nul 2>&1
if errorlevel 1 (
    call :fail "드라이버 시작 실패"
    pause & exit /b 1
)
call :ok "드라이버 로드 완료"

sc query %SERVICE% | findstr /i "RUNNING" >nul 2>&1
if errorlevel 1 (
    call :warn "서비스 상태가 RUNNING 이 아님 — 확인 필요"
) else (
    call :ok "서비스 상태: RUNNING"
)

:: ────────────────────────────────────────────────────────────────
:: STEP 7: PATH 등록
:: ────────────────────────────────────────────────────────────────
call :step 7 7 "kernel_keylogger 명령 PATH 등록"
echo %PATH% | findstr /i "%ROOT:~0,-1%" >nul 2>&1
if errorlevel 1 (
    setx PATH "%PATH%;%ROOT:~0,-1%" >nul 2>&1
    call :ok "등록 완료 — 새 CMD 창에서 kernel_keylogger 사용 가능"
) else (
    call :ok "이미 등록됨"
)

:: ────────────────────────────────────────────────────────────────
:: 완료
:: ────────────────────────────────────────────────────────────────
echo.
echo  ╔═════════════════════════════════════════════════╗
echo  ║   설치 완료!                                    ║
echo  ╠═════════════════════════════════════════════════╣
echo  ║  실시간 캡처:                                   ║
echo  ║    python reader\reader.py                      ║
echo  ║                                                 ║
echo  ║  로그 조회 (새 CMD):                            ║
echo  ║    kernel_keylogger           (최근 200개)      ║
echo  ║    kernel_keylogger --tail 50 (최근 50개)       ║
echo  ║    kernel_keylogger --stats   (통계)            ║
echo  ║    kernel_keylogger --find 바보                 ║
echo  ║                                                 ║
echo  ║  드라이버 제거:                                 ║
echo  ║    sc stop KeyFilter                            ║
echo  ║    sc delete KeyFilter                          ║
echo  ╚═════════════════════════════════════════════════╝
echo.

set /p GORUN="지금 바로 reader.py 실행? [Y/N]: "
if /i "!GORUN!"=="Y" (
    start "KeyLogger Reader" cmd /k "cd /d %ROOT% && python reader\reader.py"
)
pause
goto :eof

:: ────────────────────────────────────────────────────────────────
:: 도우미 함수
:: ────────────────────────────────────────────────────────────────
:header
echo.
echo  ╔══════════════════════════════════════════╗
echo  ║   KeyLogger  원클릭 자동 설치 스크립트   ║
echo  ╚══════════════════════════════════════════╝
echo.
goto :eof

:step
echo.
echo  [%~1/%~2] %~3...
goto :eof

:ok
if "%~1"=="" (
    echo         OK
) else (
    echo         OK — %~1
)
goto :eof

:warn
echo         [경고] %~1
goto :eof

:fail
echo.
echo   [오류] %~1
echo.
goto :eof
