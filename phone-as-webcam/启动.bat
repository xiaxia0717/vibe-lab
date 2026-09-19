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
echo   启动后会自动弹浏览器给你看画面。
echo   手机上的 App 打开点「启动」即可，不用填任何地址。
echo.
echo   微信里这样选：
echo     摄像头 -^> OBS Virtual Camera
echo     麦克风 -^> CABLE Output (VB-Audio Virtual Cable)
echo.
echo   关掉这个窗口 = 停止服务。
echo ============================================================
echo.

echo [1/3] 检查手机连接 ...
if not exist "%ADB%" (
    echo     [提示] 没找到 adb.exe，跳过数据线模式。
    echo            手机连同一个 WiFi 也能用（会自动找到电脑）。
    echo.
) else (
    "%ADB%" devices
    echo.
    echo [2/3] 建立端口转发（数据线模式用）...
    "%ADB%" reverse tcp:%PORT% tcp:%PORT% 2>nul
    echo.
)

echo [3/3] 启动服务 ...
echo.
".venv\Scripts\python.exe" -u server.py --port %PORT% --virtual-mic --open-preview
pause
