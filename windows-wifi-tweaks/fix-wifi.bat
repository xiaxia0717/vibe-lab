@echo off
title WLAN Performance Optimization
net session >nul 2>&1
if not %errorlevel%==0 goto noadmin
echo.
echo  ================================================
echo   WLAN Adapter Performance Optimization
echo  ================================================
echo.
echo  Applying settings to Intel Wi-Fi 6 AX200 ...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0nic_opt.ps1"
echo.
echo  ================================================
echo   Done. Restart the adapter or reboot to apply.
echo  ================================================
echo.
pause
exit /b 0

:noadmin
echo.
echo  [!] Administrator rights required.
echo.
echo      Right-click this file and select
echo      "Run as administrator".
echo.
pause
exit /b 1
