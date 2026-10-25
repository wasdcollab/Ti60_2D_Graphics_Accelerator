@echo off
setlocal
cd /d "%~dp0"

rem ============================================================
rem  run_sim_fast.bat -- same workbench, PyPy (JIT) backend.
rem
rem  Same scenarios, same assertions, same firmware as run_sim.bat;
rem  only the interpreter changes.  Measured on this machine:
rem     full suite   CPython 337 s   ->   PyPy 89~92 s
rem     serial sum   CPython 1006 s  ->   PyPy 261 s
rem  Long scenarios gain the most (skills x10, settings x3.8);
rem  very short ones pay a fixed JIT warm-up (alpha x1.5).
rem
rem  Does NOT rebuild the firmware -- build it once with
rem  sw\build_firmware.bat (or just use run_sim.bat once).
rem
rem  Usage:  run_sim_fast.bat render
rem          run_sim_fast.bat --suite
rem          set SIM_NO_PAUSE=1   to keep the window from waiting
rem ============================================================

set "ARG=%*"
if "%ARG%"=="" set "ARG=--group render"
rem A bare word is a group name; anything starting with -- passes through.
if not "%ARG:~0,2%"=="--" set "ARG=--group %ARG%"

set "PYPY=..\tools\pypy\pypy.exe"
if not exist "%PYPY%" (
    echo [ERROR] PyPy not found at %PYPY%
    echo         install it with:  powershell -File tools\setup_pypy_portable.ps1
    if not defined SIM_NO_PAUSE pause
    exit /b 1
)

if not defined SIM_JOBS set "SIM_JOBS=8"

echo ========================================================
echo Ti60 2D engine workbench   [PyPy JIT backend]
echo   args: %ARG%   jobs: %SIM_JOBS%
echo ========================================================

"%PYPY%" test_runner.py %ARG% --jobs %SIM_JOBS% --export-images
if %errorlevel% neq 0 (
    echo.
    echo [NOTE] test_runner returned a non-zero exit code.
    echo        As of the 2026-09-27 firmware, two scenarios -- impactfx and
    echo        hudfx -- already fail BEFORE any simulator optimisation, with
    echo        firmware-level assertion messages.  Count the PASS/FAIL lines
    echo        above: 23/25 is the known-good figure for this firmware.
    if not defined SIM_NO_PAUSE pause
    exit /b %errorlevel%
)

echo.
echo Generated frame images are saved in simulator\output\:
dir output\*.png output\*.bmp 2>nul
echo ========================================================
echo [SUCCESS] Simulator completed!
echo ========================================================
endlocal
