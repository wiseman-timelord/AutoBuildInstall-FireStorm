@echo off
setlocal enabledelayedexpansion

REM ===========================================================================
REM  AutoBuildInstall-FireStorm - launcher
REM
REM  Deliberately minimal. Its only jobs are to find a usable Python 3 and
REM  hand control to autobuild_firestorm.py.
REM
REM  Notes:
REM   * Administrator is NOT required and NOT wanted. Running the build
REM     elevated causes pip cache and file-ownership problems.
REM   * PowerShell is not used anywhere. Firestorm's build system mis-detects
REM     the Visual Studio toolchain when driven from PowerShell.
REM ===========================================================================

title AutoBuildInstall-FireStorm

set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
cd /d "%SCRIPT_DIR%" || (echo Could not change to script directory. & goto :fatal)

set "EXITCODE=1"
set "PY_EXE="

echo.
echo ===============================================================================
echo     AutoBuildInstall-FireStorm
echo ===============================================================================
echo.

REM ---- Warn if elevated -----------------------------------------------------
net session >nul 2>&1
if %errorLevel% EQU 0 (
    echo [WARN] Running as Administrator is not recommended for building.
    echo        Close this and run normally if you hit permission errors.
    echo.
)

REM ---- Locate Python 3 ------------------------------------------------------
echo Locating Python 3...

REM Prefer the py launcher, which resolves the newest install correctly.
py -3 --version >nul 2>&1
if !errorLevel! EQU 0 (
    for /f "delims=" %%v in ('py -3 --version 2^>^&1') do set "PY_VER=%%v"
    set "PY_EXE=py"
    set "PY_ARGS=-3"
    echo   Found via py launcher: !PY_VER!
    goto :got_python
)

python --version >nul 2>&1
if !errorLevel! EQU 0 (
    for /f "delims=" %%v in ('python --version 2^>^&1') do set "PY_VER=%%v"
    REM The Windows Store stub prints nothing useful and exits 9009 on use.
    echo !PY_VER! | findstr /i "Python 3" >nul
    if !errorLevel! EQU 0 (
        set "PY_EXE=python"
        set "PY_ARGS="
        echo   Found on PATH: !PY_VER!
        goto :got_python
    )
)

echo.
echo ERROR: No Python 3 installation was found.
echo.
echo   Install Python 3 from https://www.python.org/downloads/windows
echo     - Tick "Add Python to PATH" during installation
echo     - Tick "pip" under Optional Features
echo.
echo   If you installed it from the Microsoft Store, open Settings,
echo   search "Manage app execution aliases", and disable the
echo   python.exe / python3.exe aliases.
echo.
goto :fatal

:got_python
if not exist "%SCRIPT_DIR%\autobuild_firestorm.py" (
    echo.
    echo ERROR: autobuild_firestorm.py is missing from:
    echo   %SCRIPT_DIR%
    echo Keep both files together in the same folder.
    echo.
    goto :fatal
)

echo.
echo Starting builder...
echo.

REM Pass through any arguments given to this batch file.
%PY_EXE% %PY_ARGS% "%SCRIPT_DIR%\autobuild_firestorm.py" %*
set "EXITCODE=!errorLevel!"

echo.
if "!EXITCODE!"=="0" (
    echo ===============================================================================
    echo     BUILD COMPLETED SUCCESSFULLY
    echo ===============================================================================
) else (
    echo ===============================================================================
    echo     FINISHED WITH ERRORS ^(exit code !EXITCODE!^)
    echo ===============================================================================
)
echo.

:fatal
echo Press any key to close...
pause >nul
exit /b %EXITCODE%