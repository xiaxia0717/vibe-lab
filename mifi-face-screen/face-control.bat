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

:menu
cls
echo.
echo   ==============================================
echo     WiFi Face Screen v2  -  Control Panel
echo   ==============================================
echo.
echo     1 . Start    (face screen on, keeps a hidden adb session alive)
echo     2 . Stop     (back to the factory clock UI)
echo     3 . Status   (what is running? temps, cpu, clients)
echo     4 . Fix      (black screen / keys dead)
echo     5 . Exit
echo.
set c=
set /p c=   Choose 1-5 :

if "%c%"=="1" goto start
if "%c%"=="2" goto stop
if "%c%"=="3" goto status
if "%c%"=="4" goto fix
if "%c%"=="5" exit /b 0
goto menu

:start
echo.
"%ADB%" start-server >nul 2>&1
"%ADB%" connect %T%
echo   [1/3] clearing any old instance ...
"%ADB%" -s %T% shell "pkill -f '[f]ace2.py'"
timeout /t 1 >nul
echo   [2/3] starting face2.py ...
start "" /min "%ADB%" -s %T% shell "python %SCRIPT%"
timeout /t 5 >nul
echo   [3/3] checking ...
echo   --- face2.py (should be listed) ---
"%ADB%" -s %T% shell "ps | grep '[f]ace2'"
echo   --- lcd  (must stay S = running) ---
"%ADB%" -s %T% shell "ps | grep '[l]cd'"
echo   --- backlight (1 = on) ---
"%ADB%" -s %T% shell "cat %BL%"
echo   --- errors (empty = good) ---
"%ADB%" -s %T% shell "cat /tmp/face_err.log 2>/dev/null; echo ."
echo.
echo   [OK] Look at the device.
echo        Do NOT close the minimized "adb.exe" window - it is what
echo        keeps face2.py alive. Closing it just stops the face screen.
echo.
pause
goto menu

:stop
echo.
"%ADB%" start-server >nul 2>&1
"%ADB%" connect %T%
"%ADB%" -s %T% shell "pkill -f '[f]ace2.py'; sleep 1; kill -CONT $(pidof lcd) 2>/dev/null; if [ -f /mnt/data/fb.raw ]; then dd if=/mnt/data/fb.raw of=/dev/fb0 bs=1024 count=150 2>/dev/null; fi; echo 1 > %BL%"
timeout /t 3 >nul
echo   --- lcd (S = running) ---
"%ADB%" -s %T% shell "ps | grep '[l]cd'"
echo   --- backlight ---
"%ADB%" -s %T% shell "cat %BL%"
echo.
echo   [OK] Stopped. Factory clock UI restored.
echo.
pause
goto menu

:status
echo.
"%ADB%" start-server >nul 2>&1
"%ADB%" connect %T%
echo   --- face2.py (empty = not running) ---
"%ADB%" -s %T% shell "ps | grep '[f]ace2'"
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
echo   --- clock-overlay repairs since start ---
"%ADB%" -s %T% shell "wc -l /tmp/face_repair.log 2>/dev/null || echo '    0 (no repairs yet)'"
echo.
pause
goto menu

:fix
echo.
"%ADB%" start-server >nul 2>&1
"%ADB%" connect %T%
echo   [1/4] stopping face2.py and resuming lcd ...
"%ADB%" -s %T% shell "pkill -f '[f]ace2.py'; kill -CONT $(pidof lcd) 2>/dev/null"
timeout /t 2 >nul
echo   [2/4] restoring the factory clock picture ...
"%ADB%" -s %T% shell "if [ -f /mnt/data/fb.raw ]; then dd if=/mnt/data/fb.raw of=/dev/fb0 bs=1024 count=150 2>/dev/null; fi"
timeout /t 1 >nul
echo   [3/4] turning the backlight back on ...
"%ADB%" -s %T% shell "echo 1 > %BL%"
timeout /t 1 >nul
echo   [4/4] checking ...
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
