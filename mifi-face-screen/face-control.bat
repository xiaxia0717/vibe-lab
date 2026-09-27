@echo off
setlocal enabledelayedexpansion
title WiFi Face Screen v2 - Control Panel

rem ---------------------------------------------------------------------------
rem  finds adb: first the one bundled with LDPlayer, then whatever is on PATH
rem ---------------------------------------------------------------------------
set ADB=
if exist "D:\leidian\LDPlayer14\adb.exe" set ADB=D:\leidian\LDPlayer14\adb.exe
if "%ADB%"=="" for %%i in (adb.exe) do if not "%%~$PATH:i"=="" set ADB=%%~$PATH:i
if "%ADB%"=="" (
  echo.
  echo   [X] adb.exe not found.
  echo       Install Android platform-tools, or put adb.exe next to this file.
  echo.
  pause
  exit /b 1
)

set T=192.168.0.1:5555
set BL=/sys/devices/platform/soc/soc:ap-apb/24700000.spi/spi_master/spi0/spi0.0/bl_gpio
set SCRIPT=/mnt/data/face2.py

rem  the kill pattern is [f]ace, NOT [f]ace.py -- the latter does not match
rem  "face2.py" because the '.' would have to eat the '2' and then there is
rem  nothing left for the 'p'.  [f]ace covers every version and still cannot
rem  match its own command line.
set KILL=pkill -f '[f]ace'

:menu
cls
echo.
echo   ==============================================
echo     WiFi Face Screen v2  -  Control Panel
echo   ==============================================
echo.
echo     1 . Start    (auto-restart keeper -- recommended)
echo     2 . Start    (one-shot, no auto-restart)
echo     3 . Stop     (back to the factory clock UI)
echo     4 . Status   (what is running? temps, cpu, clients)
echo     5 . Fix      (black screen / keys dead)
echo     6 . Exit
echo.
set c=
set /p c=   Choose 1-6 :

if "%c%"=="1" goto keeper
if "%c%"=="2" goto start
if "%c%"=="3" goto stop
if "%c%"=="4" goto status
if "%c%"=="5" goto fix
if "%c%"=="6" exit /b 0
goto menu

:keeper
echo.
if not exist "%~dp0face-keeper.bat" (
  echo   [X] face-keeper.bat not found next to this file.
  echo.
  pause
  goto menu
)
echo   Launching the keeper in a new window ...
echo.
echo   It pushes face2.py, starts it, and RESTARTS IT AUTOMATICALLY
echo   if the device reboots or the link drops.
echo.
echo   *** LEAVE THAT WINDOW OPEN. ***
echo.
start "Face Screen Keeper" /min cmd /c "%~dp0face-keeper.bat"
timeout /t 12 >nul
echo   --- keeper window opened. current state: ---
echo   --- face2.py ---
"%ADB%" -s %T% shell "ps | grep '[f]ace'"
echo   --- lcd (must stay S = running) ---
"%ADB%" -s %T% shell "ps | grep '[l]cd'"
echo   --- backlight (1 = on) ---
"%ADB%" -s %T% shell "cat %BL%"
echo.
echo   [OK] Look at the device.
echo.
pause
goto menu

:start
echo.
"%ADB%" start-server >nul 2>&1
"%ADB%" connect %T%
echo   [1/3] clearing any old instance ...
"%ADB%" -s %T% shell "%KILL%"
timeout /t 1 >nul
echo   [2/3] starting face2.py ...
start "" /min "%ADB%" -s %T% shell "python %SCRIPT%"
timeout /t 5 >nul
echo   [3/3] checking ...
echo   --- face2.py (should be listed) ---
"%ADB%" -s %T% shell "ps | grep '[f]ace'"
echo   --- lcd  (must stay S = running) ---
"%ADB%" -s %T% shell "ps | grep '[l]cd'"
echo   --- backlight (1 = on) ---
"%ADB%" -s %T% shell "cat %BL%"
echo   --- errors (empty = good) ---
"%ADB%" -s %T% shell "cat /tmp/face_err.log 2>/dev/null; echo ."
echo.
echo   [OK] Look at the device.
echo        Do NOT close the minimized "adb.exe" window - it is what keeps
echo        face2.py alive. It will NOT restart by itself if the link drops;
echo        use option 1 (the keeper) if you want that.
echo.
pause
goto menu

:stop
echo.
"%ADB%" start-server >nul 2>&1
"%ADB%" connect %T%
"%ADB%" -s %T% shell "%KILL%; sleep 1; kill -CONT $(pidof lcd) 2>/dev/null; if [ -f /mnt/data/fb.raw ]; then dd if=/mnt/data/fb.raw of=/dev/fb0 bs=1024 count=150 2>/dev/null; fi; echo 1 > %BL%"
timeout /t 3 >nul
echo   --- face screen (should be empty) ---
"%ADB%" -s %T% shell "ps | grep '[f]ace'"
echo   --- lcd (S = running) ---
"%ADB%" -s %T% shell "ps | grep '[l]cd'"
echo   --- backlight ---
"%ADB%" -s %T% shell "cat %BL%"
echo.
echo   [OK] Stopped. Factory clock UI restored.
echo        (If the keeper window is still open it will restart the face
echo         screen in a few seconds - close that window first.)
echo.
pause
goto menu

:status
echo.
"%ADB%" start-server >nul 2>&1
"%ADB%" connect %T%
echo   --- face2.py (empty = not running) ---
"%ADB%" -s %T% shell "ps | grep '[f]ace'"
echo   --- lcd  (S = running, T = PAUSED) ---
"%ADB%" -s %T% shell "ps | grep '[l]cd'"
echo   --- backlight (1 = on, 0 = dark) ---
"%ADB%" -s %T% shell "cat %BL%"
echo   --- battery ---
"%ADB%" -s %T% shell "echo -n '    capacity: '; cat /sys/class/power_supply/sc27xx-fgu/capacity; echo -n '    status  : '; cat /sys/class/power_supply/sc27xx-fgu/status"
echo   --- temperatures (millidegrees) ---
"%ADB%" -s %T% shell "echo -n '    battery : '; cat /sys/class/thermal/thermal_zone9/temp; echo -n '    soc     : '; cat /sys/class/thermal/thermal_zone0/temp; echo -n '    pa5g    : '; cat /sys/class/thermal/thermal_zone8/temp"
echo   --- throttle trip points ---
"%ADB%" -s %T% shell "echo -n '    passive : '; cat /sys/class/thermal/thermal_zone0/trip_point_0_temp; echo -n '    critical: '; cat /sys/class/thermal/thermal_zone0/trip_point_2_temp"
echo   --- cpu (cur / max kHz, governor) ---
"%ADB%" -s %T% shell "echo -n '    cpu0: '; cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq; echo -n '    max : '; cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq; echo -n '    gov : '; cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
echo   --- wifi clients ---
"%ADB%" -s %T% shell "cat /mnt/data/fy/config/wificlients 2>/dev/null"
echo   --- clock-overlay repairs since start ---
"%ADB%" -s %T% shell "wc -l /tmp/face_repair.log 2>/dev/null || echo '    0 (no repairs yet)'"
echo.
pause
goto menu

:fix
echo.
"%ADB%" start-server >nul 2>&1
"%ADB%" connect %T%
echo   [1/4] stopping the face screen and resuming lcd ...
"%ADB%" -s %T% shell "%KILL%; kill -CONT $(pidof lcd) 2>/dev/null"
timeout /t 2 >nul
echo   [2/4] restoring the factory clock picture ...
"%ADB%" -s %T% shell "if [ -f /mnt/data/fb.raw ]; then dd if=/mnt/data/fb.raw of=/dev/fb0 bs=1024 count=150 2>/dev/null; fi"
timeout /t 1 >nul
echo   [3/4] turning the backlight back on ...
"%ADB%" -s %T% shell "echo 1 > %BL%"
timeout /t 1 >nul
echo   [4/4] checking ...
echo   --- face screen (should be empty) ---
"%ADB%" -s %T% shell "ps | grep '[f]ace'"
echo   --- lcd (S = running) ---
"%ADB%" -s %T% shell "ps | grep '[l]cd'"
echo   --- backlight (1 = on) ---
"%ADB%" -s %T% shell "cat %BL%"
echo.
echo   [OK] Done.
echo   If the screen is STILL dark, long-press the power button on the
echo   device to reboot it - that always restores the factory UI.
echo.
pause
goto menu
