@echo off
title Screen Fix  -  black screen recovery
set ADB=D:\leidian\LDPlayer14\adb.exe
set T=192.168.0.1:5555
set BL=/sys/devices/platform/soc/soc:ap-apb/24700000.spi/spi_master/spi0/spi0.0/bl_gpio

echo.
echo   =============================================
echo     Screen Fix  -  black screen recovery
echo   =============================================
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
echo.
echo   --- lcd process (S = running, T = PAUSED) ---
"%ADB%" -s %T% shell "ps | grep '[l]cd'"
echo   --- backlight (1 = on, 0 = dark) ---
"%ADB%" -s %T% shell "cat %BL%"
echo.
echo   [OK] Done.
echo.
echo   If the screen is STILL dark, long-press the power button
echo   on the device to reboot it - that always restores the UI.
echo.
pause
