@echo off
setlocal
cd /d "%~dp0"

echo ========================================================
echo Ti60 2D engine workbench
echo   1/2  build the RISC-V firmware with GCC
echo   2/2  run one short simulation batch (default: render)
echo ========================================================

call ..\sw\build_firmware.bat
if %errorlevel% neq 0 (
    echo [ERROR] firmware build failed
    pause
    exit /b %errorlevel%
)

rem Usage:  run_sim.bat [group]
rem   group defaults to "render"; a batch is sized to finish well inside ten
rem   minutes.  Run "python test_runner.py --list" for every id and group.
set "GROUP=%~1"
if "%GROUP%"=="" set "GROUP=render"

rem Scenarios are independent machines, so running them on several processes
rem gives the same verdict in a fraction of the time (all 24: 1477 s serial,
rem 475 s on 8 processes).  Set SIM_JOBS=1 for the serial order back.
if not defined SIM_JOBS set "SIM_JOBS=8"

python test_runner.py --group %GROUP% --jobs %SIM_JOBS% --export-images
if %errorlevel% neq 0 (
    echo [ERROR] Simulation failed!
    pause
    exit /b %errorlevel%
)

echo.
echo Generated frame images are saved in simulator\output\:
dir output\*.png output\*.bmp 2>nul

echo ========================================================
echo [SUCCESS] Simulator completed!
echo ========================================================
endlocal