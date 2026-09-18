@echo off
chcp 65001 >nul
title 安装 OBS Studio（提供虚拟摄像头驱动）
cd /d "%~dp0"

echo ============================================================
echo    安装 OBS Studio
echo ============================================================
echo.
echo  说明：
echo    1. 这个软件是免费开源的，装它只是为了获得「虚拟摄像头驱动」，
echo       让微信 / 腾讯会议 能把手机画面识别成一个摄像头。
echo    2. 马上会弹出管理员授权窗口，请点「是」。
echo    3. 安装过程保持默认选项，一路下一步，装完关掉即可。
echo    4. 装好后不需要打开 OBS，直接用「启动.bat」跑本项目就行。
echo.
pause

if not exist "OBS-Studio-Installer.exe" (
    echo [错误] 找不到 OBS-Studio-Installer.exe，请确认它和本文件在同一目录。
    pause
    exit /b 1
)

start "" /wait "OBS-Studio-Installer.exe"

echo.
echo 安装程序已结束。
echo 接下来双击「启动.bat」，启动时会显示「虚拟摄像头 已启用」。
echo.
pause
