#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
手机当摄像头 / 麦克风 / 扬声器 —— PC 端服务

手机浏览器打开页面后，把摄像头画面与麦克风音频推到本机；
本机再转成「虚拟摄像头」供微信、腾讯会议等软件使用。

用法:
    python server.py                # 启动服务（默认端口 8080）
    python server.py --port 9000
    python server.py --no-speaker   # 关闭「电脑声音传回手机」
"""

import argparse
import asyncio
import io
import queue
import socket
import sys
import threading
import time
from pathlib import Path

import numpy as np
from aiohttp import WSMsgType, web
from PIL import Image

TAG_VIDEO = 0x01
TAG_AUDIO = 0x02
PCM_RATE = 16000

HERE = Path(__file__).resolve().parent
STATIC_DIR = HERE / "static"


# --------------------------------------------------------------------------
# 工具
# --------------------------------------------------------------------------
def lan_ip() -> str:
    """取本机在局域网中的 IP（不实际发包）。"""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except Exception:
        return "127.0.0.1"
    finally:
        s.close()


# --------------------------------------------------------------------------
# 音频播放（把手机的麦克风声音放出来 / 交给系统）
# --------------------------------------------------------------------------
class _OutputSink:
    """一路音频输出（可以是扬声器，也可以是虚拟声卡）。"""

    def __init__(self, device, rate, name):
        import sounddevice as sd

        self.name = name
        self.rate = rate
        self.lock = threading.Lock()
        self.buf = np.zeros(0, dtype=np.float32)
        self.max_len = rate * 2
        self.stream = sd.OutputStream(
            samplerate=rate, channels=1, dtype="float32",
            blocksize=1024, device=device, callback=self._cb,
        )
        self.stream.start()

    def push(self, f: np.ndarray):
        with self.lock:
            self.buf = np.concatenate([self.buf, f])
            if len(self.buf) > self.max_len:
                self.buf = self.buf[-self.max_len:]

    def _cb(self, outdata, frames, time_info, status):
        with self.lock:
            n = min(frames, len(self.buf))
            if n:
                outdata[:n, 0] = self.buf[:n]
                self.buf = self.buf[n:]
            if n < frames:
                outdata[n:, 0] = 0.0

    def close(self):
        try:
            self.stream.stop()
            self.stream.close()
        except Exception:
            pass


def is_virtual_audio_name(name: str) -> bool:
    """判断某个音频设备名是不是虚拟声卡/映射器（不是真实扬声器）。"""
    low = name.lower()
    for k in ("cable", "vb-audio", "voicemeeter", "virtual audio",
              "声音映射器", "sound mapper", "主声音驱动程序", "primary sound"):
        if k in low:
            return True
    return False


class PcmPlayer:
    """把手机的麦克风声音送出去。

    - 送到系统默认扬声器（本机监听）；如果默认播放设备被 VB-Cable 抢占，
      会自动改用一个真实扬声器，避免"本机听不到声音"。
    - 如果装了 VB-Cable 并开启 --virtual-mic，则同时送到
      "CABLE Input"，这样微信/会议软件把麦克风选成 "CABLE Output"
      就能听到手机的声音。
    """

    def __init__(self, rate: int = PCM_RATE, virtual_mic: bool = False):
        import sounddevice as sd

        self.rate = rate
        self.sinks = []

        out_idx = self._pick_monitor_output(sd)
        try:
            self.sinks.append(_OutputSink(out_idx, rate, "本机扬声器"))
            if out_idx is None:
                print("  [麦克风] 已输出到系统扬声器（本机可监听）")
            else:
                name = str(sd.query_devices(out_idx).get("name", ""))
                print(f"  [麦克风] 默认播放设备是虚拟声卡，已自动改用 -> {name}")
        except Exception as e:
            print(f"  [麦克风] 扬声器输出失败: {e}")

        if virtual_mic:
            idx = self._find_cable_input(sd)
            if idx is None:
                print("  [虚拟麦克风] 未找到 CABLE Input 设备")
                print("               请先安装 VB-Cable（运行 安装虚拟声卡.bat）")
            else:
                try:
                    self.sinks.append(_OutputSink(idx, rate, "CABLE Input"))
                    print("  [虚拟麦克风] 已输出到 CABLE Input")
                    print('               在微信/会议软件里把「麦克风」选成 "CABLE Output" 即可')
                except Exception as e:
                    print(f"  [虚拟麦克风] 打开失败: {e}")

    @classmethod
    def _pick_monitor_output(cls, sd):
        """返回本机监听该用的输出设备索引；None 表示直接用系统默认。

        VB-Cable 装完后 Windows 常把 "CABLE Input" 设成默认播放设备，
        这时若还往默认设备送手机麦克风的声音，本机就听不见，
        而且会和回环捕获互相喂声音（回声）。所以这里主动挑一个真实扬声器。
        """
        try:
            devs = sd.query_devices()
            default_out = sd.default.device[1]
        except Exception:
            return None
        if default_out is None or default_out < 0:
            return None
        try:
            d0 = devs[default_out]
            if not is_virtual_audio_name(str(d0.get("name", ""))):
                return None                      # 默认就是真实设备，照旧
            hostapi = d0.get("hostapi")
        except Exception:
            return None

        fallback = None
        for i, d in enumerate(devs):
            if d.get("max_output_channels", 0) <= 0:
                continue
            if is_virtual_audio_name(str(d.get("name", ""))):
                continue
            if d.get("hostapi") == hostapi:
                return i
            if fallback is None:
                fallback = i
        return fallback

    @staticmethod
    def _find_cable_input(sd):
        try:
            devices = sd.query_devices()
        except Exception:
            return None
        for i, d in enumerate(devices):
            name = str(d.get("name", ""))
            if "CABLE Input" in name and d.get("max_output_channels", 0) > 0:
                return i
        return None

    @property
    def has_virtual_mic(self) -> bool:
        return any(s.name == "CABLE Input" for s in self.sinks)

    def push(self, pcm_i16: np.ndarray):
        f = pcm_i16.astype(np.float32) / 32768.0
        for s in self.sinks:
            s.push(f)

    def close(self):
        for s in self.sinks:
            s.close()
        self.sinks = []


# --------------------------------------------------------------------------
# 核心桥接
# --------------------------------------------------------------------------
class Bridge:
    def __init__(self, args):
        self.args = args
        self.phone = None                 # 当前手机 WebSocket
        self.frame_q = queue.Queue(maxsize=2)
        self.stats = {"fps": 0, "w": 0, "h": 0, "connected": False,
                      "rx_frames": 0, "audio_chunks": 0}
        self.running = True
        self.loop = None
        self._vcam = None
        self._vcam_fmt = None
        self.player = None
        self._speaker_thread = None
        self._speaker_ready = False
        self._last_fps_at = time.time()
        self._fps_acc = 0

    # ---------------- 虚拟摄像头 ----------------
    def init_virtual_cam(self, width, height, fps):
        try:
            import pyvirtualcam
        except ImportError:
            print("  [虚拟摄像头] 未安装 pyvirtualcam，跳过")
            print("               需要虚拟摄像头功能请运行: pip install pyvirtualcam")
            return False
        try:
            self._vcam = pyvirtualcam.Camera(
                width=width, height=height, fps=fps, print_fps=False
            )
            print(f"  [虚拟摄像头] 已启用 -> {self._vcam.device}")
            print(f"               在微信/会议软件里选择这个设备即可")
            return True
        except Exception as e:
            print(f"  [虚拟摄像头] 启用失败: {e}")
            print("               需要先安装 OBS Studio（它自带虚拟摄像头驱动）")
            return False

    # ---------------- 手机声音 -> 本机播放 ----------------
    def init_player(self):
        if self.args.no_mic:
            return
        try:
            self.player = PcmPlayer(PCM_RATE, virtual_mic=self.args.virtual_mic)
        except Exception as e:
            print(f"  [麦克风] 初始化失败: {e}")

    # ---------------- 本机声音 -> 手机（扬声器） ----------------
    def start_speaker(self):
        if self.args.no_speaker:
            return
        try:
            import soundcard as sc
        except ImportError:
            print("  [扬声器] 未安装 soundcard，跳过（pip install soundcard）")
            return

        def worker():
            try:
                import warnings
                warnings.filterwarnings("ignore", category=sc.SoundcardRuntimeWarning)

                speaker = sc.default_speaker()
                # 默认播放设备若是虚拟声卡，回环捕获到的会是自己送进去的
                # 手机麦克风声音 -> 手机听到自己 -> 回声。改用真实扬声器。
                if is_virtual_audio_name(str(speaker.name)):
                    real = None
                    for sp in sc.all_speakers():
                        if not is_virtual_audio_name(str(sp.name)):
                            real = sp
                            break
                    if real is not None:
                        print(f"  [扬声器] 默认播放设备是虚拟声卡，已自动改用 -> {real.name}")
                        speaker = real
                loop = sc.get_microphone(id=str(speaker.name), include_loopback=True)
                if loop is None:
                    print("  [扬声器] 找不到回环设备，跳过")
                    return
                print(f"  [扬声器] 正在捕获系统声音 -> {speaker.name}")
                self._speaker_ready = True
                chunk = 1600  # 100ms
                with loop.recorder(samplerate=PCM_RATE, channels=1,
                                   blocksize=chunk) as rec:
                    while self.running:
                        data = rec.record(numframes=chunk)
                        if not self.running:
                            break
                        ws = self.phone
                        if ws is None or ws.closed:
                            time.sleep(0.1)
                            continue
                        i16 = (np.clip(data[:, 0], -1, 1) * 32767).astype(np.int16)
                        pkt = bytes([TAG_AUDIO]) + i16.tobytes()
                        asyncio.run_coroutine_threadsafe(self._safe_send(ws, pkt), self.loop)
            except Exception as e:
                print(f"  [扬声器] 异常: {e}")

        self._speaker_thread = threading.Thread(target=worker, daemon=True)
        self._speaker_thread.start()

    async def _safe_send(self, ws, data):
        try:
            if not ws.closed:
                await ws.send_bytes(data)
        except Exception:
            pass

    # ---------------- 消息处理 ----------------
    def on_video(self, jpeg: bytes):
        try:
            img = Image.open(io.BytesIO(jpeg))
            img.load()
            frame = np.asarray(img.convert("RGB"))
        except Exception:
            return
        self.stats["rx_frames"] += 1
        h, w = frame.shape[:2]
        self.stats["w"], self.stats["h"] = w, h

        # 虚拟摄像头
        if self._vcam is not None:
            try:
                if (self._vcam.width, self._vcam.height) != (w, h):
                    self._vcam.close()
                    self._vcam = None
                    self.init_virtual_cam(w, h, self.args.fps)
                if self._vcam is not None:
                    self._vcam.send(frame)
            except Exception:
                pass

        # 送 GUI 预览（丢旧帧，只留最新）
        try:
            self.frame_q.put_nowait(frame)
        except queue.Full:
            try:
                self.frame_q.get_nowait()
                self.frame_q.put_nowait(frame)
            except Exception:
                pass

        # FPS
        self._fps_acc += 1
        now = time.time()
        if now - self._last_fps_at >= 1.0:
            self.stats["fps"] = round(self._fps_acc / (now - self._last_fps_at))
            self._fps_acc = 0
            self._last_fps_at = now

    def on_audio(self, pcm: bytes):
        if self.player is None:
            return
        n = len(pcm) // 2
        if n == 0:
            return
        arr = np.frombuffer(pcm[: n * 2], dtype=np.int16)
        self.stats["audio_chunks"] += 1
        self.player.push(arr)

    # ---------------- HTTP / WebSocket ----------------
    async def handle_index(self, request):
        return web.FileResponse(STATIC_DIR / "index.html")

    async def handle_ws(self, request):
        ws = web.WebSocketResponse(max_msg_size=16 * 1024 * 1024, heartbeat=20)
        await ws.prepare(request)
        peer = request.remote
        print(f"\n[+] 手机已连接: {peer}")
        self.phone = ws
        self.stats["connected"] = True

        try:
            async for msg in ws:
                if msg.type == WSMsgType.BINARY:
                    data = msg.data
                    if not data:
                        continue
                    tag, payload = data[0], data[1:]
                    if tag == TAG_VIDEO:
                        self.on_video(payload)
                    elif tag == TAG_AUDIO:
                        self.on_audio(payload)
                elif msg.type == WSMsgType.ERROR:
                    break
        finally:
            self.stats["connected"] = False
            if self.phone is ws:
                self.phone = None
            print(f"[-] 手机已断开: {peer}")
        return ws

    async def handle_stats(self, request):
        """供自检 / 调试使用。"""
        return web.json_response(self.stats)

    def make_app(self):
        app = web.Application()
        app.router.add_get("/", self.handle_index)
        app.router.add_get("/ws", self.handle_ws)
        app.router.add_get("/stats", self.handle_stats)
        if STATIC_DIR.exists():
            app.router.add_static("/static", STATIC_DIR)
        return app


# --------------------------------------------------------------------------
# GUI 预览
# --------------------------------------------------------------------------
def run_gui(bridge: Bridge, url_local: str, url_lan: str):
    import tkinter as tk
    from PIL import ImageTk

    root = tk.Tk()
    root.title("手机当摄像头 — 预览")
    root.configure(bg="#111111")
    root.geometry("900x620")

    info = tk.Label(root, text="", bg="#111111", fg="#9aa0a6",
                    font=("Microsoft YaHei", 10), justify="left", anchor="w")
    info.pack(fill="x", padx=14, pady=(10, 6))

    holder = tk.Label(root, bg="#000000")
    holder.pack(fill="both", expand=True, padx=14, pady=(0, 10))

    tips = tk.Label(
        root,
        text=f"数据线模式（手机浏览器打开）: {url_local}     |     同一 WiFi 模式: {url_lan}",
        bg="#111111", fg="#5f6368", font=("Microsoft YaHei", 9), anchor="w",
    )
    tips.pack(fill="x", padx=14, pady=(0, 12))

    state = {"photo": None}

    def tick():
        try:
            frame = bridge.frame_q.get_nowait()
            img = Image.fromarray(frame)
            # 等比缩放到窗口内
            w = holder.winfo_width() or 860
            h = holder.winfo_height() or 480
            if w > 10 and h > 10:
                iw, ih = img.size
                scale = min(w / iw, h / ih)
                if scale < 1:
                    img = img.resize((max(1, int(iw * scale)), max(1, int(ih * scale))),
                                     Image.BILINEAR)
            state["photo"] = ImageTk.PhotoImage(img)
            holder.configure(image=state["photo"])
        except queue.Empty:
            pass
        except Exception:
            pass

        s = bridge.stats
        status = "已连接" if s["connected"] else "等待手机连接…"
        vcam = "开" if bridge._vcam is not None else "关"
        spk = "开" if bridge._speaker_ready else "关"
        info.configure(
            text=(f"状态: {status}    分辨率: {s['w']}x{s['h']}    "
                  f"帧率: {s['fps']} fps    已收帧: {s['rx_frames']}\n"
                  f"虚拟摄像头: {vcam}    扬声器回传: {spk}    "
                  f"麦克风音频块: {s['audio_chunks']}")
        )
        root.after(30, tick)

    def on_close():
        bridge.running = False
        root.destroy()

    root.protocol("WM_DELETE_WINDOW", on_close)
    root.after(60, tick)
    root.mainloop()


# --------------------------------------------------------------------------
# 局域网自动发现：手机不用手填电脑 IP
# --------------------------------------------------------------------------
DISCOVERY_PORT = 47823
_DISCOVERY_REQ = b"PHONECAM?"


def start_discovery_responder(port: int, is_running):
    """监听手机的发现请求，回一个带端口的应答。

    手机端广播 "PHONECAM?"，本机收到后单播回 "PHONECAM1|<port>"，
    手机据此拿到电脑的局域网 IP —— 免去手动填地址，也不怕 DHCP 换 IP。
    用 UDP 而不是靠 mDNS，是因为不依赖任何第三方库。
    """

    def worker():
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind(("", DISCOVERY_PORT))
            sock.settimeout(0.5)
        except Exception as e:
            print(f"  [自动发现] 未开启（不影响使用）: {e}")
            return

        print("  [自动发现] 已开启：手机连同一个 WiFi 时会自动找到电脑")
        reply = b"PHONECAM1|" + str(port).encode()
        try:
            while is_running():
                try:
                    data, addr = sock.recvfrom(256)
                except socket.timeout:
                    continue
                except OSError:
                    break
                if data.startswith(_DISCOVERY_REQ):
                    try:
                        sock.sendto(reply, addr)
                    except Exception:
                        pass
        finally:
            try:
                sock.close()
            except Exception:
                pass

    t = threading.Thread(target=worker, daemon=True, name="discovery")
    t.start()
    return t


# --------------------------------------------------------------------------
# 入口
# --------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="把手机变成电脑的摄像头/麦克风/扬声器")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--fps", type=int, default=24, help="虚拟摄像头帧率")
    ap.add_argument("--no-gui", action="store_true", help="不显示预览窗口")
    ap.add_argument("--no-vcam", action="store_true", help="不启用虚拟摄像头")
    ap.add_argument("--no-mic", action="store_true", help="不播放手机麦克风声音")
    ap.add_argument("--no-speaker", action="store_true", help="不把电脑声音传回手机")
    ap.add_argument("--virtual-mic", action="store_true",
                    help="把手机麦克风输出到 VB-Cable 虚拟声卡，供微信等软件当麦克风用")
    args = ap.parse_args()

    ip = lan_ip()
    url_local = f"http://localhost:{args.port}"
    url_lan = f"http://{ip}:{args.port}"

    print("=" * 66)
    print("  手机当摄像头 / 麦克风 / 扬声器")
    print("=" * 66)
    print(f"  服务端口 : {args.port}")
    print(f"  本机 IP  : {ip}")
    print()

    bridge = Bridge(args)
    bridge.loop = asyncio.new_event_loop()

    if not args.no_vcam:
        # 先用默认尺寸开，收到实际分辨率会自动重建
        bridge.init_virtual_cam(1280, 720, args.fps)
    bridge.init_player()
    bridge.start_speaker()
    start_discovery_responder(args.port, lambda: bridge.running)

    app = bridge.make_app()
    runner = web.AppRunner(app)

    def server_thread():
        asyncio.set_event_loop(bridge.loop)

        async def boot():
            await runner.setup()
            site = web.TCPSite(runner, "0.0.0.0", args.port)
            await site.start()

        bridge.loop.run_until_complete(boot())
        print()
        print("-" * 66)
        print("  手机端打开以下地址（推荐先用数据线模式）:")
        print(f"    {url_local}")
        print()
        print("  数据线模式请先在电脑上执行一次:")
        print(f"    adb reverse tcp:{args.port} tcp:{args.port}")
        print()
        print(f"  同一 WiFi 时可用: {url_lan}")
        print("-" * 66)
        print("  按 Ctrl+C 或关闭预览窗口退出")
        print()
        bridge.loop.run_forever()

    t = threading.Thread(target=server_thread, daemon=True)
    t.start()
    time.sleep(1.2)

    try:
        if args.no_gui:
            while bridge.running:
                time.sleep(1)
        else:
            run_gui(bridge, url_local, url_lan)
    except KeyboardInterrupt:
        pass
    finally:
        bridge.running = False
        if bridge._vcam is not None:
            try:
                bridge._vcam.close()
            except Exception:
                pass
        if bridge.player is not None:
            bridge.player.close()
        print("\n已退出。")


if __name__ == "__main__":
    main()
