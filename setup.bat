@echo off
setlocal EnableDelayedExpansion
chcp 65001 >nul 2>&1
title KeyLogger Setup

set ROOT=%~dp0
set DRIVER_SRC=%ROOT%driver
set DRIVER_SYS=%ROOT%driver\KeyFilter.sys
set SERVICE=KeyFilter
set CERT_NAME=KeyFilterTestCert

echo.
echo  =========================================
echo    KeyLogger  원클릭 자동 설치 스크립트
echo  =========================================
echo.

:: ────────────────────────────────────────────────────────────────
:: STEP 0: 관리자 권한
:: ────────────────────────────────────────────────────────────────
call :step 0 8 "관리자 권한 확인"
net session >nul 2>&1
if errorlevel 1 (
    call :fail "관리자 권한 없음 -- 우클릭 후 '관리자로 실행'"
    pause & exit /b 1
)
call :ok

:: ────────────────────────────────────────────────────────────────
:: STEP 1: 테스트 서명 모드
:: ────────────────────────────────────────────────────────────────
call :step 1 8 "테스트 서명 모드 확인"
bcdedit 2>nul | findstr /i "testsigning" | findstr /i "yes" >nul 2>&1
if not errorlevel 1 (
    call :ok "이미 활성화됨"
) else (
    bcdedit /set testsigning on >nul 2>&1
    if errorlevel 1 (
        call :fail "활성화 실패 -- VM 설정에서 Secure Boot 를 꺼주세요"
        pause & exit /b 1
    )
    call :ok "활성화 완료 -- 재부팅 후 자동 재실행"
    :: 재부팅 후 이 스크립트를 자동 실행하도록 레지스트리 등록
    reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" ^
        /v "KeyLoggerSetup" /t REG_SZ ^
        /d "cmd /c \"%~f0\"" /f >nul 2>&1
    shutdown /r /t 5 /c "testsigning 적용을 위한 재부팅 (5초 후)"
    exit /b 0
)

:: ────────────────────────────────────────────────────────────────
:: STEP 2: Python 설치
:: ────────────────────────────────────────────────────────────────
call :step 2 8 "Python 확인 및 설치"
python --version >nul 2>&1
if not errorlevel 1 (
    for /f "tokens=*" %%v in ('python --version 2^>^&1') do call :ok "%%v 발견"
    goto :pip_install
)

echo         Python 없음 -- winget 으로 자동 설치...
winget install -e --id Python.Python.3.12 --silent --accept-package-agreements --accept-source-agreements
if errorlevel 1 (
    call :fail "Python 설치 실패 -- https://python.org 에서 수동 설치 후 재실행"
    pause & exit /b 1
)
set "PATH=%LOCALAPPDATA%\Programs\Python\Python312;%LOCALAPPDATA%\Programs\Python\Python312\Scripts;%PATH%"
python --version >nul 2>&1
if errorlevel 1 (
    call :warn "PATH 미반영 -- CMD 재시작 후 재실행 권장"
) else (
    call :ok "Python 설치 완료"
)

:pip_install
:: ────────────────────────────────────────────────────────────────
:: STEP 3: pip 패키지 설치
:: ────────────────────────────────────────────────────────────────
call :step 3 8 "pip 패키지 설치"
python -m pip install --upgrade pip --quiet 2>nul
if exist "%ROOT%requirements.txt" (
    python -m pip install -r "%ROOT%requirements.txt" --quiet 2>nul
)
python -c "import ctypes, sqlite3, struct, argparse" >nul 2>&1
if errorlevel 1 (
    call :fail "Python 표준 라이브러리 임포트 실패"
    pause & exit /b 1
)
call :ok "Python 모듈 검증 완료"

:: ────────────────────────────────────────────────────────────────
:: STEP 4: Visual Studio 2022 + WDK 자동 설치
:: ────────────────────────────────────────────────────────────────
call :step 4 8 "Visual Studio 2022 + WDK 확인 및 설치"

:: VS2022 확인 및 자동 설치
call :find_msbuild
if not defined MSBUILD (
    echo         VS2022 없음 -- winget 으로 자동 설치 중... (수분 소요)
    winget install -e --id Microsoft.VisualStudio.2022.BuildTools --silent ^
        --accept-package-agreements --accept-source-agreements ^
        --override "--quiet --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
    if errorlevel 1 (
        call :fail "VS2022 설치 실패 -- https://aka.ms/vs/17/release/vs_buildtools.exe 수동 설치"
        pause & exit /b 1
    )
    call :find_msbuild
    if not defined MSBUILD (
        call :fail "VS2022 설치됐지만 MSBuild 경로를 찾지 못함 -- CMD 재시작 후 재실행"
        pause & exit /b 1
    )
)
call :ok "MSBuild 발견"

:: WDK VS 통합 확인 (WindowsKernelModeDriver10.0 툴셋 존재 여부)
call :check_wdk_vs
if "!WDK_VS_OK!"=="1" (
    call :ok "WDK VS 통합 발견"
    goto :build
)

:: WDK 없음 → 자동 설치
echo         WDK 없음 -- 자동 설치 시작...

:: 1) wdksetup.exe 다운로드
set "WDK_SETUP=%TEMP%\wdksetup.exe"
echo         WDK 다운로드 중... (수분 소요)
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/?linkid=2272234' -OutFile '%WDK_SETUP%' -UseBasicParsing"
if not exist "%WDK_SETUP%" (
    call :fail "WDK 다운로드 실패 -- 네트워크 확인 후 재실행"
    pause & exit /b 1
)

:: 2) WDK 설치 (무인 설치)
echo         WDK 설치 중... (수분 소요)
"%WDK_SETUP%" /quiet /norestart
del /f /q "%WDK_SETUP%" >nul 2>&1

:: 3) WDK.vsix → VSIXInstaller 로 VS2022 통합 (WindowsKernelModeDriver10.0 등록)
echo         WDK VS2022 통합 설치 중...
call :install_wdk_vsix

:: 4) 재확인
call :check_wdk_vs
if "!WDK_VS_OK!"=="1" (
    call :ok "WDK + VS 통합 설치 완료"
    goto :build
)

:: 통합이 아직 안 됐으면 재부팅 필요 (레지스트리에 자동 재실행 등록 후 재부팅)
call :warn "WDK 설치 완료 -- VS 통합 적용을 위해 재부팅 필요"
echo         재부팅 후 자동으로 setup.bat 재실행됩니다. (5초 후 재부팅)
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" ^
    /v "KeyLoggerSetup" /t REG_SZ ^
    /d "cmd /c \"%~f0\"" /f >nul 2>&1
timeout /t 5 /nobreak >nul
shutdown /r /t 0 /c "WDK VS 통합 적용을 위한 재부팅"
exit /b 0

:: ────────────────────────────────────────────────────────────────
:: STEP 5: 드라이버 빌드
:: ────────────────────────────────────────────────────────────────
:build
call :step 5 8 "드라이버 빌드"
if not exist "%DRIVER_SRC%\KeyFilter.vcxproj" (
    call :fail "KeyFilter.vcxproj 없음: %DRIVER_SRC%"
    pause & exit /b 1
)

if exist "%DRIVER_SYS%" (
    call :ok "기존 KeyFilter.sys 사용 (빌드 건너뜀)"
    goto :sign
)

"%MSBUILD%" "%DRIVER_SRC%\KeyFilter.vcxproj" ^
    /p:Configuration=Release /p:Platform=x64 ^
    /nologo /verbosity:minimal ^
    /p:OutDir="%DRIVER_SRC%\bin\\" 2>&1 | findstr /i "error warning"

if not exist "%DRIVER_SRC%\bin\KeyFilter.sys" (
    call :fail "빌드 실패 -- 위 오류 메시지를 확인하세요"
    pause & exit /b 1
)
copy /y "%DRIVER_SRC%\bin\KeyFilter.sys" "%DRIVER_SYS%" >nul
call :ok "KeyFilter.sys 생성 완료"

:: ────────────────────────────────────────────────────────────────
:: STEP 6: 드라이버 서명
:: ────────────────────────────────────────────────────────────────
:sign
call :step 6 8 "드라이버 서명 (테스트 인증서)"

set MAKECERT=
set SIGNTOOL=
for /d %%v in ("%ProgramFiles(x86)%\Windows Kits\10\bin\10.*") do (
    if exist "%%v\x64\makecert.exe" (
        set "MAKECERT=%%v\x64\makecert.exe"
        set "SIGNTOOL=%%v\x64\signtool.exe"
    )
)

if not defined MAKECERT (
    call :warn "서명 도구 없음 -- 서명 건너뜀"
    goto :install_driver
)

certutil -store PrivateCertStore "%CERT_NAME%" >nul 2>&1
if errorlevel 1 (
    "%MAKECERT%" -r -pe -ss root -sr localMachine -n "CN=%CERT_NAME% Root" ^
        -eku 1.3.6.1.5.5.7.3.3 "%ROOT%%CERT_NAME%Root.cer" >nul 2>&1
    "%MAKECERT%" -pe -ss PrivateCertStore -n "CN=%CERT_NAME%" ^
        -eku 1.3.6.1.5.5.7.3.3 -is root -ir localMachine ^
        -in "%CERT_NAME% Root" "%ROOT%%CERT_NAME%.cer" >nul 2>&1
)
"%SIGNTOOL%" sign /s PrivateCertStore /n "%CERT_NAME%" /fd sha256 ^
    /t http://timestamp.digicert.com "%DRIVER_SYS%" >nul 2>&1
if errorlevel 1 (
    call :warn "서명 실패 -- 계속 진행"
) else (
    call :ok "서명 완료"
)

:install_driver
:: ────────────────────────────────────────────────────────────────
:: STEP 7: 드라이버 설치 및 시작
:: ────────────────────────────────────────────────────────────────
call :step 7 8 "드라이버 설치"

sc query %SERVICE% >nul 2>&1
if not errorlevel 1 (
    sc stop %SERVICE% >nul 2>&1
    timeout /t 2 /nobreak >nul
    sc delete %SERVICE% >nul 2>&1
    timeout /t 1 /nobreak >nul
)

sc create %SERVICE% type= kernel start= demand binPath= "%DRIVER_SYS%" ^
    DisplayName= "Keyboard Filter (Research)" >nul 2>&1
if errorlevel 1 (
    call :fail "sc create 실패"
    pause & exit /b 1
)

sc start %SERVICE% >nul 2>&1
if errorlevel 1 (
    call :fail "드라이버 시작 실패 (오류코드: %ERRORLEVEL%)"
    pause & exit /b 1
)
sc query %SERVICE% | findstr /i "RUNNING" >nul 2>&1
if errorlevel 1 (
    call :warn "서비스 상태 RUNNING 아님 -- 확인 필요"
) else (
    call :ok "드라이버 로드 완료 -- RUNNING"
)

:: ────────────────────────────────────────────────────────────────
:: STEP 8: PATH 등록
:: ────────────────────────────────────────────────────────────────
call :step 8 8 "kernel_keylogger 명령 PATH 등록"
echo %PATH% | findstr /i "%ROOT:~0,-1%" >nul 2>&1
if errorlevel 1 (
    setx PATH "%PATH%;%ROOT:~0,-1%" >nul 2>&1
    call :ok "등록 완료 -- 새 CMD 창에서 kernel_keylogger 사용 가능"
) else (
    call :ok "이미 등록됨"
)

:: ────────────────────────────────────────────────────────────────
:: 완료
:: ────────────────────────────────────────────────────────────────
echo.
echo  =========================================
echo    설치 완료!
echo  -----------------------------------------
echo    실시간 캡처:
echo      python reader\reader.py
echo.
echo    로그 조회 (새 CMD):
echo      kernel_keylogger           (최근 200개)
echo      kernel_keylogger --tail 50 (최근 50개)
echo      kernel_keylogger --stats   (통계)
echo.
echo    드라이버 제거:
echo      sc stop KeyFilter
echo      sc delete KeyFilter
echo  =========================================
echo.

start "KeyLogger Reader" cmd /k "cd /d %ROOT% && python reader\reader.py"
pause
goto :eof

:: ────────────────────────────────────────────────────────────────
:: 도우미 함수
:: ────────────────────────────────────────────────────────────────

:: WDK VS 통합 여부 확인 → WDK_VS_OK 설정
:check_wdk_vs
set WDK_VS_OK=0
for %%p in ("%ProgramFiles%" "%ProgramFiles(x86)%") do (
    for %%e in (Community Professional Enterprise BuildTools) do (
        if exist "%%~p\Microsoft Visual Studio\2022\%%e\MSBuild\Microsoft\WindowsDriver\" (
            set WDK_VS_OK=1
        )
    )
)
goto :eof

:: WDK.vsix 를 VSIXInstaller 로 VS2022 에 통합
:install_wdk_vsix
set VSIXINSTALLER=
for %%p in ("%ProgramFiles%" "%ProgramFiles(x86)%") do (
    for %%e in (Community Professional Enterprise BuildTools) do (
        if exist "%%~p\Microsoft Visual Studio\2022\%%e\Common7\IDE\VSIXInstaller.exe" (
            set "VSIXINSTALLER=%%~p\Microsoft Visual Studio\2022\%%e\Common7\IDE\VSIXInstaller.exe"
        )
    )
)
if not defined VSIXINSTALLER (
    call :warn "VSIXInstaller 없음 -- WDK VS 통합 건너뜀"
    goto :eof
)
set WDK_VSIX=
for /d %%v in ("%ProgramFiles(x86)%\Windows Kits\10\vsix\*") do (
    if exist "%%v\WDK.vsix" set "WDK_VSIX=%%v\WDK.vsix"
)
if not defined WDK_VSIX (
    call :warn "WDK.vsix 없음 -- WDK VS 통합 건너뜀"
    goto :eof
)
"%VSIXINSTALLER%" /q "%WDK_VSIX%" >nul 2>&1
call :ok "WDK VS 통합 완료 (WindowsKernelModeDriver10.0)"
goto :eof

:: MSBuild.exe 경로 탐색 → MSBUILD 설정
:find_msbuild
set MSBUILD=
set VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe
if exist "%VSWHERE%" (
    for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.Component.MSBuild -find MSBuild\**\Bin\MSBuild.exe 2^>nul`) do set "MSBUILD=%%i"
)
if not defined MSBUILD (
    for %%p in ("%ProgramFiles%" "%ProgramFiles(x86)%") do (
        for %%e in (Community Professional Enterprise BuildTools) do (
            if exist "%%~p\Microsoft Visual Studio\2022\%%e\MSBuild\Current\Bin\MSBuild.exe" (
                set "MSBUILD=%%~p\Microsoft Visual Studio\2022\%%e\MSBuild\Current\Bin\MSBuild.exe"
            )
        )
    )
)
goto :eof

:step
echo.
echo  [%~1/%~2] %~3...
goto :eof

:ok
if "%~1"=="" (
    echo         OK
) else (
    echo         OK -- %~1
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
