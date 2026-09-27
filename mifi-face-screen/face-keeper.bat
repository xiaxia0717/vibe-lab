@echo off
title Face Screen Keeper  -  keep this window open
setlocal enabledelayedexpansion
set ADB=
if exist "D:\leidian\LDPlayer14\adb.exe" set ADB=D:\leidian\LDPlayer14\adb.exe
if "%ADB%"=="" for %%i in (adb.exe) do if not "%%~$PATH:i"=="" set ADB=%%~$PATH:i
if "%ADB%"=="" (echo   [X] adb.exe not found. & pause & exit /b 1)
set T=192.168.0.1:5555
set SCRIPT=/mnt/data/face2.py

echo.
echo   =============================================
echo     Face Screen Keeper
echo   =============================================
echo.
echo   Keeps face2.py running on %T%.
echo   If the device reboots or the link drops, it reconnects
echo   and starts the face screen again by itself.
echo.
echo   *** LEAVE THIS WINDOW OPEN. Closing it stops the face screen. ***
echo.

:loop
echo.
echo   [%TIME%] connecting ...
"%ADB%" connect %T% >nul 2>&1

rem -- make sure the script is on the device (cheap, and survives a factory reset)
if not exist "%~dp0face2.py" goto have_script
"%ADB%" -s %T% push "%~dp0face2.py" %SCRIPT% >nul 2>&1
:have_script

rem -- clear any stale instance. MUST be its own adb call: if the pkill and the
rem    python start share one command line, the pattern matches that very line
rem    and the shell kills itself.
"%ADB%" -s %T% shell "pkill -f '[f]ace'" >nul 2>&1
timeout /t 1 >nul

echo   [%TIME%] starting %SCRIPT%  (Ctrl+C or close the window to stop)
echo.
rem -- this blocks until the device-side process dies
"%ADB%" -s %T% shell "python %SCRIPT%"

echo.
echo   [%TIME%] face screen exited -- link lost or device rebooted.
echo             retrying in 5 s ...
timeout /t 5 >nul
goto loop
