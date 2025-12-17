@echo off
setlocal enabledelayedexpansion

REM ==== Static Configuration ====
set "TITLE=PhoenixFirestorm-DetectBuildInstall"
title %TITLE%

REM ==== DP0 TO SCRIPT BLOCK ====
set "ScriptDirectory=%~dp0"
set "ScriptDirectory=%ScriptDirectory:~0,-1%"
cd /d "%ScriptDirectory%"
echo Dp0'd to Script.

REM ==== Admin Check ====
net session >nul 2>&1
if %errorLevel% NEQ 0 (
    echo Error: Admin Required!echo Launching PowerShell Script in 5 seconds...
for /L %%i in (4,-1,1) do (
    timeout /t 1 /nobreak >nul
    <nul set /p "=Launching PowerShell Script in %%i seconds...   " >con
)
echo.
    timeout /t 2 >nul
    echo Right Click, Run As Administrator.
    timeout /t 2 >nul
    goto :end_of_script
)
echo Status: Administrator
timeout /t 1 >nul

REM ==== Clear screen for clean display ====
cls

REM ==== Display header ====
echo ================================================================================
echo     AutoBuildInstall-FireStorm
echo ================================================================================
echo.

REM ==== Detect PowerShell Versions ====
echo Detecting PowerShell versions...
echo.

set "PWSH_FOUND=0"
set "PS_FOUND=0"
set "PWSH_VERSION="
set "PS_VERSION="

REM Check for PowerShell Core/7+ pwsh
pwsh.exe -Command "$PSVersionTable.PSVersion.ToString()" >nul 2>&1
if %errorLevel% EQU 0 (
    set "PWSH_FOUND=1"
    for /f "delims=" %%i in ('pwsh.exe -Command "$PSVersionTable.PSVersion.ToString()"') do set "PWSH_VERSION=%%i"
    echo [FOUND] PowerShell Core/7+: v!PWSH_VERSION!
) else (
    echo [NOT FOUND] PowerShell Core/7+ ^(pwsh^)
)

REM Check for Windows PowerShell 5.1 powershell
powershell.exe -Command "$PSVersionTable.PSVersion.ToString()" >nul 2>&1
if %errorLevel% EQU 0 (
    set "PS_FOUND=1"
    for /f "delims=" %%i in ('powershell.exe -Command "$PSVersionTable.PSVersion.ToString()"') do set "PS_VERSION=%%i"
    echo [FOUND] Windows PowerShell: v!PS_VERSION!
) else (
    echo [NOT FOUND] Windows PowerShell ^(powershell^)
)

echo.

REM ==== Determine which PowerShell to use ====
if !PWSH_FOUND! EQU 1 (
    echo Priority: Using PowerShell Core/7+ ^(pwsh^) - v!PWSH_VERSION!
    set "PS_EXECUTABLE=pwsh.exe"
    set "PS_VERSION_ARG=7"
) else if !PS_FOUND! EQU 1 (
    echo Fallback: Using Windows PowerShell ^(powershell^) - v!PS_VERSION!
    set "PS_EXECUTABLE=powershell.exe"
    set "PS_VERSION_ARG=5"
) else (
    echo.
    echo ERROR: No PowerShell installation detected!
    echo Please install one of the following:
    echo   - PowerShell 7+ ^(Recommended^): https://github.com/PowerShell/PowerShell 
    echo   - Windows PowerShell 5.1 ^(Built into Windows 10+^)
    echo.
    goto :end_of_script
)

echo.

REM ==== Clean 5-second countdown ====
echo Launching Powershell in 5 Seconds...
>nul timeout /t 5 /nobreak
echo.

REM ==== Fixed: Use -File for both PowerShell versions with proper path handling ====
"%PS_EXECUTABLE%" -ExecutionPolicy Bypass -NoProfile -File "%ScriptDirectory%\phoenix_firestorm_build.ps1" -PSVersion %PS_VERSION_ARG%
set EXITCODE=%ERRORLEVEL%

REM ==== Display exit message ====
echo.
if %EXITCODE% NEQ 0 (
    echo BUILD FAILED ^(Exit Code: %EXITCODE%^)
) else (
    echo                          BUILD COMPLETED SUCCESSFULLY
)
echo.
echo ..PowerShell Script Exited.
echo.

REM BREAK FOR DEBUG
PAUSE

REM ==== Clean exit countdown ====
echo Exiting Batch in 5 Seconds...
>nul timeout /t 5 /nobreak
echo.

:end_of_script
REM ==== Exit with the same code as PowerShell script ====
exit /b %EXITCODE%