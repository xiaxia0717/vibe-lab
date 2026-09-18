@echo off
chcp 65001 >nul
title 安装虚拟声卡（VB-Cable）
cd /d "%~dp0"

echo ============================================================
echo    安装 VB-Cable 虚拟声卡
echo ============================================================
echo.
echo  作用：
echo    装完后，微信 / 腾讯会议 等软件的「麦克风」列表里会多出一个
echo    "CABLE Output" 设备。选中它，对方就能听到你手机的声音。
echo.
echo  说明：
echo    1. 这个驱动免费（VB-Audio 出品）。
echo    2. 需要管理员权限，马上会弹授权窗口，请点「是」。
echo    3. 安装完成后**必须重启电脑**才能生效。
echo.
pause

set SETUP=drivers\VBCABLE\VBCABLE_Setup_x64.exe

if not exist "%SETUP%" (
    echo [错误] 找不到 %SETUP%
    echo        请确认 drivers\VBCABLE 目录完整。
    pause
    exit /b 1
)

echo 正在安装驱动（会弹管理员授权，请点「是」）...
powershell -NoProfile -Command "Start-Process -FilePath '%~dp0%SETUP%' -Verb RunAs -Wait"

echo.
echo ============================================================
echo  安装结束。请**重启电脑**，然后：
echo    1. 双击 phone-as-webcam\启动.bat
echo    2. 软件里把「麦克风」选成 CABLE Output
echo ============================================================
echo.
pause
