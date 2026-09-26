@echo off
setlocal
cd /d "%~dp0\.."

if defined EFINITY_HOME if exist "%EFINITY_HOME%\bin\setup.bat" goto efinity_ready
set "EFINITY_SETUP=D:\FPGAqiansai\efinity-2026.1.132-windows-x64\efinity\2026.1\bin\setup.bat"
if not exist "%EFINITY_SETUP%" (
    echo [ERROR] Efinity setup not found: %EFINITY_SETUP%
    exit /b 1
)
call "%EFINITY_SETUP%"
if errorlevel 1 exit /b %errorlevel%

:efinity_ready
set "PYTHONPATH=%EFINITY_HOME%\ipm\bin;%EFINITY_HOME%\ipm\bin\rpc"
if not defined EFINITY_USER_DIR set "EFINITY_USER_DIR=%USERPROFILE%\.efinity"
python tools\regenerate_soc.py
exit /b %errorlevel%
