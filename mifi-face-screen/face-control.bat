@echo off
title WiFi Face Screen Control
set ADB=D:\leidian\LDPlayer14\adb.exe
set T=192.168.0.1:5555
set BL=/sys/devices/platform/soc/soc:ap-apb/24700000.spi/spi_master/spi0/spi0.0/bl_gpio

:menu
cls
echo.
echo   =============================================
echo     WiFi Face Screen  -  Control Panel
echo   =============================================
echo.
echo     1 . Start   (face screen on, keeps a hidden adb session alive)
echo     2 . Stop    (back to the original clock UI)
echo     3 . Status  (what is running?)
echo     4 . Fix Screen  (black screen / keys dead)
echo     5 . Exit
echo.
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
echo   [1/2] clearing any old instance ...
"%ADB%" -s %T% shell "pkill -f '[f]ace.py'"
timeout /t 1 >nul
echo   [2/2] starting face.py ...
start "" /min "%ADB%" -s %T% shell "python /mnt/data/face.py"
timeout /t 4 >nul
echo.
echo   --- face.py ---
"%ADB%" -s %T% shell "ps | grep '[f]ace.py'"
echo   --- lcd (must stay S = running) ---
"%ADB%" -s %T% shell "ps | grep '[l]cd'"
echo   --- backlight (1 = on) ---
"%ADB%" -s %T% shell "cat %BL%"
echo.
echo   [OK] Look at the device.
echo        Do NOT close the minimized "adb.exe" window - it keeps
echo        face.py alive. Closing it just stops the face screen.
echo.
pause
goto menu

:stop
echo.
"%ADB%" start-server >nul 2>&1
"%ADB%" connect %T%
"%ADB%" -s %T% shell "pkill -f '[f]ace.py'; sleep 1; kill -CONT $(pidof lcd); if [ -f /mnt/data/fb.raw ]; then dd if=/mnt/data/fb.raw of=/dev/fb0 bs=1024 count=150 2>/dev/null; else dd if=/dev/zero of=/dev/fb0 bs=1024 count=150 2>/dev/null; fi; echo 1 > %BL%"
timeout /t 3 >nul
echo.
echo   --- lcd (S = running) ---
"%ADB%" -s %T% shell "ps | grep '[l]cd'"
echo   --- backlight ---
"%ADB%" -s %T% shell "cat %BL%"
echo.
echo   [OK] Stopped. Original clock UI restored.
echo.
pause
goto menu

:status
echo.
"%ADB%" start-server >nul 2>&1
"%ADB%" connect %T%
echo   --- face.py (empty = not running) ---
"%ADB%" -s %T% shell "ps | grep '[f]ace.py'"
echo   --- lcd  (S = running, T = PAUSED) ---
"%ADB%" -s %T% shell "ps | grep '[l]cd'"
echo   --- backlight (1 = on, 0 = dark) ---
"%ADB%" -s %T% shell "cat %BL%"
echo.
pause
goto menu

:fix
echo.
"%ADB%" start-server >nul 2>&1
"%ADB%" connect %T%
echo   [1/4] stopping face.py and resuming lcd ...
"%ADB%" -s %T% shell "pkill -f '[f]ace.py'; kill -CONT $(pidof lcd)"
timeout /t 2 >nul
echo   [2/4] restoring the clock picture ...
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
echo   If the screen is STILL dark, long-press the power button
echo   on the device to reboot it - that always restores the UI.
echo.
pause
goto menu
