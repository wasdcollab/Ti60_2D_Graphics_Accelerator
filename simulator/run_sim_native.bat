@echo off
setlocal
cd /d "%~dp0"

rem ============================================================
rem  run_sim_native.bat -- the fastest path: C++ core + CPython.
rem
rem  simulator/_socvm.cp313-win_amd64.pyd is a C++ port of the
rem  simulation kernel.  rv32i_soc_vm.py picks it up automatically,
rem  so the scenarios and their assertions are untouched.
rem
rem  Measured on this machine (full suite, --jobs 8):
rem      original CPython   336.8 s
rem      PyPy (JIT)          88.9 s
rem      C++ native          15.7 s
rem  Serial sum: 1005.7 -> 261.3 -> 78.4 s.
rem
rem  Build/rebuild the core with:  python build_native.py
rem
rem  Falls back silently to the pure-Python kernel if the .pyd is
rem  missing, so this script is always safe to run.
rem
rem  Usage:  run_sim_native.bat render
rem          run_sim_native.bat --suite
rem ============================================================

set "ARG=%*"
if "%ARG%"=="" set "ARG=--group render"
if not "%ARG:~0,2%"=="--" set "ARG=--group %ARG%"

set "PY="
if exist "D:\Anaconda\python.exe" set "PY=D:\Anaconda\python.exe"
if not defined PY (
    where python.exe >nul 2>nul && set "PY=python.exe"
)
if not defined PY (
    echo [ERROR] no python interpreter found
    if not defined SIM_NO_PAUSE pause
    exit /b 1
)

set "CORE=_socvm.cp313-win_amd64.pyd"
if exist "%CORE%" (
    echo [core] native C++ kernel found: %CORE%
) else (
    echo [warn] %CORE% not built -- falling back to the pure-Python kernel
    echo        build it with:  python build_native.py
)

if not defined SIM_JOBS set "SIM_JOBS=8"

echo ========================================================
echo Ti60 2D engine workbench   [native C++ core]
echo   args: %ARG%   jobs: %SIM_JOBS%
echo ========================================================

"%PY%" test_runner.py %ARG% --jobs %SIM_JOBS% --export-images
if %errorlevel% neq 0 (
    echo.
    echo [NOTE] test_runner returned a non-zero exit code.
    echo        As of the 2026-09-27 firmware, two scenarios -- impactfx and
    echo        hudfx -- already fail on firmware-level assertions.  23/25 is
    echo        the known-good figure for this firmware.
    if not defined SIM_NO_PAUSE pause
    exit /b %errorlevel%
)

echo.
echo Generated frame images are saved in simulator\output\
dir output\*.png output\*.bmp 2>nul
echo ========================================================
echo [SUCCESS] Simulator completed!
echo ========================================================
endlocal
