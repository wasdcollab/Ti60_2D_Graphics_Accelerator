@echo off
setlocal
cd /d "%~dp0"

echo ========================================================
echo 1. Building RISC-V C Firmware Symbols
echo ========================================================
call sw\build_firmware.bat
if %errorlevel% neq 0 (
    echo [ERROR] Firmware build failed!
    exit /b %errorlevel%
)

echo ========================================================
echo 2. Setting Efinity Environment
echo ========================================================
rem setup.bat must always be sourced: it is what exports PYTHONHOME, PATH and
rem the EFX*_HOME variables Efinity's own python needs.  Skipping it whenever
rem EFINITY_HOME happens to be set in the shell makes efx_run die with
rem "ModuleNotFoundError: No module named 'encodings'".
set "EFINITY_SETUP=%EFINITY_HOME%\bin\setup.bat"
if not exist "%EFINITY_SETUP%" set "EFINITY_SETUP=D:\Efinix\efinity\2026.1\bin\setup.bat"
if not exist "%EFINITY_SETUP%" set "EFINITY_SETUP=D:\FPGAqiansai\efinity-2026.1.132-windows-x64\efinity\2026.1\bin\setup.bat"
if not exist "%EFINITY_SETUP%" (
    echo [ERROR] Efinity setup not found: %EFINITY_SETUP%
    echo         Set EFINITY_HOME first or update EFINITY_SETUP in build_hw.bat.
    exit /b 1
)
call "%EFINITY_SETUP%"
if %errorlevel% neq 0 (
    echo [ERROR] Efinity environment setup failed!
    exit /b %errorlevel%
)

echo ========================================================
echo 3. Running Efinity Full System Flow (Map -> PNR -> PGM)
echo ========================================================
call "%EFINITY_HOME%/bin/efx_run.bat" --prj -f compile ti60_top
if %errorlevel% neq 0 (
    echo [ERROR] Efinity compile failed!
    exit /b %errorlevel%
)

echo ========================================================
echo [SUCCESS] Full system compiled!
echo Bitstream: outflow\ti60_top.bit
echo Flash HEX: outflow\ti60_top.hex
echo ========================================================
endlocal
