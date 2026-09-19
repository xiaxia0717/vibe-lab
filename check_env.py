# -*- coding: utf-8 -*-
"""环境自检：手机连接 / 虚拟摄像头 / 虚拟声卡 / Python 依赖。

改进点：
  - OBS 安装位置从注册表读取，不再写死 C 盘（用户实际装在 D 盘）
  - 虚拟摄像头用「真实打开一次」来验证，而不是只看目录存在
  - 提示语对齐桌面上的编号脚本名
"""
import shutil
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent

ADB_CANDIDATES = [
    Path(r"D:\leidian\LDPlayer14\adb.exe"),
    HERE / "phone-as-webcam" / "platform-tools" / "adb.exe",
]

OK = "  [OK]"
NO = "  [!!]"


def find_adb():
    for p in ADB_CANDIDATES:
        if p.exists():
            return p
    w = shutil.which("adb")
    return Path(w) if w else None


def find_obs_dir():
    """优先从注册表读 OBS 安装路径，其次扫各盘常见位置。"""
    try:
        import winreg
        for sub in (r"SOFTWARE\OBS Studio", r"SOFTWARE\WOW6432Node\OBS Studio"):
            try:
                with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, sub) as k:
                    p = Path(winreg.QueryValueEx(k, "")[0])
                    if (p / "bin" / "64bit" / "obs64.exe").exists():
                        return p
            except OSError:
                pass
    except ImportError:
        pass
    for drive in ("C", "D", "E", "F", "G"):
        p = Path(f"{drive}:/Program Files/obs-studio")
        if (p / "bin" / "64bit" / "obs64.exe").exists():
            return p
    return None


def main():
    print("=" * 62)
    print("   手机摄像头 · 环境自检")
    print("=" * 62)

    problems = []

    # ---------------- 1 手机连接 ----------------
    print("\n[1/4] 手机连接")
    adb = find_adb()
    if adb is None:
        print(f"{NO} 找不到 adb.exe")
        problems.append("找不到 adb")
    else:
        print(f"{OK} adb 位置: {adb}")
        try:
            r = subprocess.run([str(adb), "devices"], capture_output=True,
                               text=True, timeout=15)
            lines = [l for l in r.stdout.splitlines()[1:] if l.strip()]
            devices = [l for l in lines if "\tdevice" in l]
            if devices:
                print(f"{OK} 已连接 {len(devices)} 台设备")
            else:
                print(f"{NO} 没有已授权设备")
                print("       检查：数据线是否插好、手机是否开启 USB 调试")
                problems.append("手机未连接")
        except Exception as e:
            print(f"{NO} 查询失败: {e}")
            problems.append("adb 查询失败")

    # ---------------- 2 虚拟摄像头 ----------------
    print("\n[2/4] 虚拟摄像头（需要 OBS）")
    obs_dir = find_obs_dir()
    if obs_dir:
        print(f"{OK} OBS Studio 已安装 -> {obs_dir}")
    else:
        print(f"{NO} 未安装 OBS Studio")
        print("       请双击桌面「备用-驱动安装（一般用不到）」里的")
        print("       「安装虚拟摄像头（OBS）.bat」")

    cam_ok = False
    try:
        import pyvirtualcam
        print(f"{OK} pyvirtualcam 已安装")
        try:
            cam = pyvirtualcam.Camera(width=640, height=480, fps=10, print_fps=False)
            print(f"{OK} 虚拟摄像头可用 -> {cam.device}")
            cam.close()
            cam_ok = True
        except Exception as e:
            print(f"{NO} 无法打开虚拟摄像头: {e}")
            if obs_dir:
                print("       修复：以管理员身份运行")
                print(f"       {obs_dir}\\data\\obs-plugins\\win-dshow\\virtualcam-install.bat")
            problems.append("虚拟摄像头打不开")
    except ImportError:
        print(f"{NO} pyvirtualcam 未安装")
        problems.append("缺少 pyvirtualcam")

    if not obs_dir and not cam_ok:
        problems.append("OBS 未安装（虚拟摄像头不可用）")

    # ---------------- 3 虚拟声卡 ----------------
    print("\n[3/4] 虚拟声卡（需要 VB-Cable）")
    try:
        import sounddevice as sd
        devs = sd.query_devices()
        cable = sorted({d["name"] for d in devs if "CABLE" in d["name"].upper()})
        if cable:
            print(f"{OK} 找到虚拟声卡: {', '.join(cable)}")
            print('       在微信/会议软件里把「麦克风」选成 "CABLE Output"')
        else:
            print(f"{NO} 未找到 CABLE 设备")
            print("       请双击桌面「备用-驱动安装（一般用不到）」里的")
            print("       「安装虚拟麦克风（VB-Cable）.bat」，装完重启电脑")
            problems.append("虚拟声卡未安装（对方听不到手机麦克风）")
    except Exception as e:
        print(f"{NO} 查询失败: {e}")

    # ---------------- 4 Python 依赖 ----------------
    print("\n[4/4] Python 依赖")
    for mod, pkg in [("aiohttp", "aiohttp"), ("numpy", "numpy"),
                     ("PIL", "Pillow"), ("sounddevice", "sounddevice"),
                     ("pyvirtualcam", "pyvirtualcam"), ("soundcard", "soundcard")]:
        try:
            __import__(mod)
            print(f"{OK} {pkg}")
        except ImportError:
            print(f"{NO} {pkg} 缺失")
            problems.append(f"缺少 {pkg}")

    # ---------------- 总结 ----------------
    print("\n" + "=" * 62)
    if problems:
        print("  还有 %d 项需要处理：" % len(problems))
        for p in problems:
            print(f"    · {p}")
    else:
        print("  全部就绪，可以正常使用了！")
        print("\n  使用流程：")
        print("    1. 手机插数据线（或连同一个 WiFi）")
        print("    2. 双击桌面「1-启动服务.bat」")
        print("    3. 手机打开「手机摄像头」App，点「启动」")
        print("    4. 微信/会议软件里选：")
        print("         摄像头 -> OBS Virtual Camera")
        print("         麦克风 -> CABLE Output")
    print("=" * 62)


if __name__ == "__main__":
    main()
