@echo off
chcp 65001 >nul
title 安装虚拟声卡（VB-Cable）
cd /d "%~dp0"

echo ============================================================
echo    安装 VB-Cable 虚拟声卡
echo ============================================================
echo.
echo  作用：
echo    装完之后，微信 / 腾讯会议 等软件的「麦克风」列表里会多出
echo    一个 "CABLE Output" 设备。选中它，对方就能听到你手机的声音。
echo.
echo  说明：
echo    1. 这个驱动是免费的（VB-Audio 出品）。
echo    2. 需要管理员权限，马上会弹授权窗口，请点「是」。
echo    3. 安装完成后**必须重启电脑**才能生效。
echo.
pause

set ZIP=VBCABLE_Driver_Pack43.zip
set DIR=VBCABLE

if not exist "%ZIP%" (
    echo [错误] 找不到 %ZIP%
    echo        请把它和本文件放在同一目录。
    pause
    exit /b 1
)

echo 正在解压 ...
if exist "%DIR%" rd /s /q "%DIR%"
powershell -NoProfile -Command "Expand-Archive -Path '%ZIP%' -DestinationPath '%DIR%' -Force"
if not exist "%DIR%" (
    echo [错误] 解压失败。
    pause
    exit /b 1
)

echo 正在安装驱动（会弹管理员授权）...
pushd "%DIR%"
if exist "VBCABLE_Setup_x64.exe" (
    powershell -NoProfile -Command "Start-Process -FilePath 'VBCABLE_Setup_x64.exe' -Verb RunAs -Wait"
) else (
    echo [错误] 解压后没找到 VBCABLE_Setup_x64.exe
    dir /b
)
popd

echo.
echo ============================================================
echo  安装结束。请**重启电脑**，然后：
echo    1. 双击 phone-as-webcam\启动.bat
echo    2. 微信里把「麦克风」选成 CABLE Output
echo ============================================================
echo.
pause
