@echo off
chcp 65001 >nul
title 手机摄像头 — 电脑端服务
cd /d "%~dp0"

set ADB=D:\leidian\LDPlayer14\adb.exe
set PORT=8080

echo ============================================================
echo    手机摄像头 · 电脑端服务
echo ============================================================
echo.

echo [1/3] 检查手机连接 ...
if not exist "%ADB%" (
    echo     [错误] 找不到 adb.exe，请用记事本修改本文件里的 ADB 路径
    pause
    exit /b 1
)
"%ADB%" devices
echo.

echo [2/3] 建立端口转发 ...
"%ADB%" reverse tcp:%PORT% tcp:%PORT%
echo.

echo [3/3] 启动服务 ...
echo.
echo    --------------------------------------------------------
echo     在手机的「手机摄像头」App 里：
echo       电脑地址填  127.0.0.1
echo       端口填      %PORT%
echo       然后点「启动」
echo    --------------------------------------------------------
echo.

".venv\Scripts\python.exe" server.py --port %PORT% --virtual-mic
pause
