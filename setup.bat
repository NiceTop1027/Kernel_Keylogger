@echo off
setlocal EnableDelayedExpansion
chcp 65001 >nul 2>&1
title Kernel Input Demo Setup

set ROOT=%~dp0
set DRIVER_SRC=%ROOT%driver
set DRIVER_SYS=%ROOT%driver\KeyFilter.sys
set SERVICE=KeyFilter
set CERT_NAME=KeyFilterTestCert
set REG_KEY=HKLM\SOFTWARE\KernelInputDemoSetup

if /i "%~1"=="driver" goto :driver_install
if /i "%~1"=="install" goto :driver_install
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

call "%ROOT%gui_demo.bat" %*
exit /b %errorlevel%

:driver_install
echo.
echo  =========================================
echo    Kernel Input Demo 설치 스크립트
echo  =========================================
echo.
echo    설치 없이 바로 실행:
echo      gui_demo.bat
echo      kernel_keylogger on
echo      kernel_keylogger off
echo      setup.bat
echo.
echo    콘솔 포터블:
echo      portable_demo.bat
echo      setup.bat portable
echo.
echo    커널 드라이버 설치:
echo      setup.bat driver
echo.

:: ────────────────────────────────────────────────────────────────
:: STEP 0: Admin check
:: ────────────────────────────────────────────────────────────────
call :step 0 8 "관리자 권한 확인"
net session >nul 2>&1
if errorlevel 1 (
    call :fail "관리자 권한 없음 -- 우클릭 후 '관리자로 실행'"
    echo   설치 없이 바로 실행하려면: gui_demo.bat
    pause & exit /b 1
)
call :ok

:: ────────────────────────────────────────────────────────────────
:: STEP 1: Test signing mode
:: ────────────────────────────────────────────────────────────────
call :step 1 8 "테스트 서명 모드 확인"
bcdedit 2>nul | findstr /i "testsigning" | findstr /i "yes" >nul 2>&1
if not errorlevel 1 (
    call :ok "이미 활성화됨"
) else (
    bcdedit /set testsigning on >nul 2>&1
    if errorlevel 1 (
        call :fail "활성화 실패 -- Secure Boot 를 끄지 않으려면 gui_demo.bat 또는 kernel_keylogger on 을 사용하세요"
        pause & exit /b 1
    )
    call :ok "활성화 완료 -- 5초 후 재부팅, 재부팅 후 자동 재실행"
    reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" ^
        /v "KernelInputDemoSetup" /t REG_SZ /d "cmd /c \"%~f0\"" /f >nul 2>&1
    shutdown /r /t 5 /c "testsigning reboot"
    exit /b 0
)

:: ────────────────────────────────────────────────────────────────
:: STEP 2: Python
:: ────────────────────────────────────────────────────────────────
call :step 2 8 "Python 확인 및 설치"
python --version >nul 2>&1
if not errorlevel 1 (
    for /f "tokens=*" %%v in ('python --version 2^>^&1') do call :ok "이미 설치됨 -- %%v"
    goto :pip_install
)

echo         Python 없음 -- winget 으로 자동 설치...
winget install -e --id Python.Python.3.12 --silent ^
    --accept-package-agreements --accept-source-agreements
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
:: STEP 3: pip
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
:: STEP 4: VS2022 + WDK
:: ────────────────────────────────────────────────────────────────
call :step 4 8 "Visual Studio 2022 + WDK 확인 및 설치"

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
) else (
    call :ok "VS2022 이미 설치됨"
)

call :check_wdk_vs
if "!WDK_VS_OK!"=="1" (
    call :ok "WDK VS 통합 이미 됨 -- 건너뜀"
    goto :build
)

:: WDK binary check (makecert.exe = WDK installed)
set WDK_BIN_OK=0
for /d %%v in ("%ProgramFiles(x86)%\Windows Kits\10\bin\10.*") do (
    if exist "%%v\x64\makecert.exe" set WDK_BIN_OK=1
)

set WDK_JUST_INSTALLED=0
if "!WDK_BIN_OK!"=="0" (
    echo         WDK 없음 -- 자동 설치 중... (수분 소요)
    set "WDK_SETUP=%TEMP%\wdksetup.exe"
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
        "Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/?linkid=2272234' -OutFile '%TEMP%\wdksetup.exe' -UseBasicParsing"
    if not exist "%TEMP%\wdksetup.exe" (
        call :fail "WDK 다운로드 실패 -- 네트워크 확인 후 재실행"
        pause & exit /b 1
    )
    "%TEMP%\wdksetup.exe" /quiet /norestart
    del /f /q "%TEMP%\wdksetup.exe" >nul 2>&1
    set WDK_JUST_INSTALLED=1
    call :ok "WDK 설치 완료"
) else (
    call :ok "WDK 이미 설치됨 -- VS 통합만 재시도"
)

call :install_wdk_vsix

:: VSIX installed OK (exit code 0) -> trust it, proceed to build
if "!VSIX_OK!"=="1" (
    reg delete "%REG_KEY%" /v "WDKRebootDone" /f >nul 2>&1
    goto :build
)

:: VSIX file not found -> reboot won't help
if "!VSIX_NOT_FOUND!"=="1" (
    reg delete "%REG_KEY%" /v "WDKRebootDone" /f >nul 2>&1
    call :fail "WDK.vsix 파일 없음 -- WDK 수동 재설치 필요"
    echo.
    echo         수동 설치: https://learn.microsoft.com/windows-hardware/drivers/download-the-wdk
    echo.
    pause & exit /b 1
)

:: VSIX found but installer failed
:: If WDK was already installed (not just now), reboot won't help
if "!WDK_JUST_INSTALLED!"=="0" (
    reg delete "%REG_KEY%" /v "WDKRebootDone" /f >nul 2>&1
    call :fail "VSIXInstaller 실패 -- WDK 수동 재설치 필요"
    echo.
    echo         수동 설치: https://learn.microsoft.com/windows-hardware/drivers/download-the-wdk
    echo.
    pause & exit /b 1
)

:: WDK just installed + VSIX failed -> try reboot once
reg query "%REG_KEY%" /v "WDKRebootDone" >nul 2>&1
if not errorlevel 1 (
    reg delete "%REG_KEY%" /v "WDKRebootDone" /f >nul 2>&1
    call :fail "재부팅 후에도 WDK VS 통합 실패 -- WDK 수동 재설치 필요"
    echo.
    echo         수동 설치: https://learn.microsoft.com/windows-hardware/drivers/download-the-wdk
    echo.
    pause & exit /b 1
)

call :warn "WDK VS 통합 적용을 위해 재부팅 필요 -- 5초 후 자동 재부팅"
reg add "%REG_KEY%" /v "WDKRebootDone" /t REG_SZ /d "1" /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" ^
    /v "KernelInputDemoSetup" /t REG_SZ /d "cmd /c \"%~f0\"" /f >nul 2>&1
timeout /t 5 /nobreak >nul
shutdown /r /t 0 /c "WDK VS integration reboot"
exit /b 0

:: ────────────────────────────────────────────────────────────────
:: STEP 5: Build driver
:: ────────────────────────────────────────────────────────────────
:build
reg delete "%REG_KEY%" /v "WDKRebootDone" /f >nul 2>&1

call :step 5 8 "드라이버 빌드"
if not exist "%DRIVER_SRC%\KeyFilter.vcxproj" (
    call :fail "KeyFilter.vcxproj 없음: %DRIVER_SRC%"
    pause & exit /b 1
)

if exist "%DRIVER_SYS%" (
    call :ok "KeyFilter.sys 이미 존재 -- 빌드 건너뜀"
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
:: STEP 6: Sign driver
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

"%SIGNTOOL%" verify /pa "%DRIVER_SYS%" >nul 2>&1
if not errorlevel 1 (
    call :ok "이미 서명됨 -- 건너뜀"
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
:: STEP 7: Install driver
:: ────────────────────────────────────────────────────────────────
call :step 7 8 "드라이버 설치"

sc query %SERVICE% 2>nul | findstr /i "RUNNING" >nul 2>&1
if not errorlevel 1 (
    call :ok "드라이버 이미 실행 중 -- 건너뜀"
    goto :step8
)

sc query %SERVICE% >nul 2>&1
if not errorlevel 1 (
    sc stop %SERVICE% >nul 2>&1
    timeout /t 2 /nobreak >nul
    sc delete %SERVICE% >nul 2>&1
    timeout /t 1 /nobreak >nul
)

sc create %SERVICE% type= kernel start= demand binPath= "%DRIVER_SYS%" ^
    DisplayName= "Kernel Input Demo Driver" >nul 2>&1
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

:step8
:: ────────────────────────────────────────────────────────────────
:: STEP 8: PATH
:: ────────────────────────────────────────────────────────────────
call :step 8 8 "kernel_keylogger 명령 PATH 등록"
echo %PATH% | findstr /i "%ROOT:~0,-1%" >nul 2>&1
if errorlevel 1 (
    setx PATH "%PATH%;%ROOT:~0,-1%" >nul 2>&1
    call :ok "등록 완료 -- 새 CMD 창에서 kernel_keylogger 사용 가능"
) else (
    call :ok "이미 등록됨"
)

echo.
echo  =========================================
echo    설치 완료!
echo  -----------------------------------------
echo    설치 없이 바로 실행:
echo      gui_demo.bat
echo      kernel_keylogger on
echo      kernel_keylogger off
echo.
echo    콘솔 포터블:
echo      portable_demo.bat
echo.
echo    로그 조회 (새 CMD):
echo      kernel_keylogger           (최근 200개)
echo      kernel_keylogger --tail 50 (최근 50개)
echo      kernel_keylogger --stats   (통계)
echo      kernel_keylogger --find Enter
echo.
echo    드라이버 제거:
echo      sc stop KeyFilter
echo      sc delete KeyFilter
echo  =========================================
echo.

set /p GORUN="지금 바로 GUI 데모 실행? [Y/N]: "
if /i "!GORUN!"=="Y" (
    call "%ROOT%gui_demo.bat"
)
pause
goto :eof

:: ────────────────────────────────────────────────────────────────
:: Subroutines
:: ────────────────────────────────────────────────────────────────

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

:install_wdk_vsix
set VSIX_OK=0
set VSIX_NOT_FOUND=0

:: Find WDK.vsix
set WDK_VSIX=
if exist "%ProgramFiles(x86)%\Windows Kits\10\vsix\WDK.vsix" (
    set "WDK_VSIX=%ProgramFiles(x86)%\Windows Kits\10\vsix\WDK.vsix"
)
if not defined WDK_VSIX (
    if exist "%ProgramFiles(x86)%\Windows Kits\10\vsix\vs17\WDK.vsix" (
        set "WDK_VSIX=%ProgramFiles(x86)%\Windows Kits\10\vsix\vs17\WDK.vsix"
    )
)
if not defined WDK_VSIX (
    for /d %%v in ("%ProgramFiles(x86)%\Windows Kits\10\vsix\*") do (
        if exist "%%v\WDK.vsix" set "WDK_VSIX=%%v\WDK.vsix"
    )
)
if not defined WDK_VSIX (
    for /f "usebackq delims=" %%f in (`powershell -NoProfile -Command ^
        "Get-ChildItem '%ProgramFiles(x86)%\Windows Kits\10' -Recurse -Filter 'WDK.vsix' 2>$null | Select-Object -First 1 -ExpandProperty FullName"`) do (
        set "WDK_VSIX=%%f"
    )
)
if not defined WDK_VSIX (
    set VSIX_NOT_FOUND=1
    call :warn "WDK.vsix 없음"
    goto :eof
)
echo         WDK.vsix: !WDK_VSIX!

:: Find VS MSBuild root
set VS_MSDIR=
for %%p in ("%ProgramFiles%" "%ProgramFiles(x86)%") do (
    for %%e in (Community Professional Enterprise BuildTools) do (
        if exist "%%~p\Microsoft Visual Studio\2022\%%e\MSBuild\Current\Bin\MSBuild.exe" (
            set "VS_MSDIR=%%~p\Microsoft Visual Studio\2022\%%e\MSBuild"
        )
    )
)
if not defined VS_MSDIR (
    call :warn "VS MSBuild 디렉토리 없음"
    goto :eof
)
echo         VS MSBuild: !VS_MSDIR!

:: Write Python script via setlocal DisableDelayedExpansion
set "PY=%TEMP%\wdk_install.py"
setlocal DisableDelayedExpansion
> "%PY%" (
echo import zipfile, os, shutil, sys
echo.
echo def merge_copy^(src, dst^):
echo     os.makedirs^(dst, exist_ok=True^)
echo     for item in os.listdir^(src^):
echo         s = os.path.join^(src, item^)
echo         d = os.path.join^(dst, item^)
echo         if os.path.isdir^(s^): merge_copy^(s, d^)
echo         else: shutil.copy2^(s, d^)
echo.
echo vsix = sys.argv[1]
echo dest = sys.argv[2]
echo tmp  = os.path.join^(os.environ.get^('TEMP','C:\\Temp'^),'WDKVsixExtract'^)
echo try:
echo     if os.path.exists^(tmp^): shutil.rmtree^(tmp,ignore_errors=True^)
echo     os.makedirs^(tmp,exist_ok=True^)
echo     print^('Extracting:',vsix^)
echo     with zipfile.ZipFile^(vsix,'r'^) as z:
echo         z.extractall^(tmp^)
echo         tops=sorted^(set^(n.split^('/'^)[0] for n in z.namelist^(^)^)^)
echo         print^('VSIX top-level:',tops^)
echo     found=False
echo     for root,dirs,files in os.walk^(tmp^):
echo         for d in dirs:
echo             if '$MSBuild$' in d:
echo                 src=os.path.join^(root,d^)
echo                 print^('$MSBuild$ found:',src,'->',dest^)
echo                 merge_copy^(src,dest^)
echo                 found=True
echo                 break
echo         if found: break
echo     if not found:
echo         print^('No $MSBuild$ dir. Trying WindowsDriver...'^)
echo         for root,dirs,files in os.walk^(tmp^):
echo             for d in dirs:
echo                 if d=='WindowsDriver':
echo                     src=os.path.join^(root,d^)
echo                     wd=os.path.join^(dest,'Microsoft','WindowsDriver'^)
echo                     print^('WindowsDriver:',src,'->',wd^)
echo                     if os.path.exists^(wd^): shutil.rmtree^(wd^)
echo                     shutil.copytree^(src,wd^)
echo                     found=True
echo                     break
echo             if found: break
echo     if not found:
echo         print^('Fallback: dump all VSIX dirs:'^)
echo         for root,dirs,files in os.walk^(tmp^): print^(' ',root^)
echo         sys.exit^(1^)
echo     ts=os.path.join^(dest,'Microsoft','VC','v170','Platforms','x64',
echo                    'PlatformToolsets','WindowsKernelModeDriver10.0'^)
echo     if os.path.exists^(ts^): print^('Toolset OK:',ts^)
echo     else: print^('WARNING: toolset path not found:',ts^)
echo     shutil.rmtree^(tmp,ignore_errors=True^)
echo     print^('Done'^)
echo except Exception as e:
echo     import traceback; print^('FAIL:',e^); traceback.print_exc^(^); sys.exit^(1^)
)
endlocal

python "%PY%" "%WDK_VSIX%" "%VS_MSDIR%"
if errorlevel 1 (
    call :warn "VSIX 추출 실패 -- 위 출력으로 원인 확인"
) else (
    set VSIX_OK=1
    call :ok "WDK VS 통합 완료 (WindowsKernelModeDriver10.0)"
)
del /f /q "%PY%" >nul 2>&1
goto :eof

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
