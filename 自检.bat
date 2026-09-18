@echo off
chcp 65001 >nul
title 手机摄像头 · 环境自检
cd /d "%~dp0"

if not exist "phone-as-webcam\.venv\Scripts\python.exe" (
    echo [错误] 找不到 Python 环境 phone-as-webcam\.venv
    pause
    exit /b 1
)

"phone-as-webcam\.venv\Scripts\python.exe" check_env.py

echo.
pause
