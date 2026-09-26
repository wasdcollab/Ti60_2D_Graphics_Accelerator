@echo off
setlocal
cd /d "%~dp0"

echo ========================================================
echo  Building RISC-V firmware (riscv-none-elf-gcc flow)
echo ========================================================
set PYTHONHOME=
set PYTHONPATH=

where python.exe >nul 2>nul
if %errorlevel% equ 0 (
    set PY=python.exe
) else if exist "D:\Anaconda\python.exe" (
    set PY="D:\Anaconda\python.exe"
) else (
    echo [ERROR] python.exe not found in PATH or D:\Anaconda!
    exit /b 1
)

%PY% build_firmware.py
if %errorlevel% neq 0 (
    echo [ERROR] Firmware build failed!
    exit /b %errorlevel%
)

echo [SUCCESS] firmware.elf/.bin built and BRAM lanes regenerated.
endlocal