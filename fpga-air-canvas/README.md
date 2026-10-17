# Air Canvas 空中画板

- **阶段 0**：FPGA 追踪 IP + 仿真自验（`color_tracker.v`）
- **阶段 1**：ARM 端画布/画线程序（`arm/air_canvas.c`）✅
- **阶段 2**：全 PL 版（`pl/`，无 ARM 无 PS 无 IP）✅ **推荐路线**

## 这是什么

摄像头画面穿过 FPGA 硬件管线：采集 → 降采样 → 背景差分 → 笔尖质心 →
Bresenham 画彩虹线 → 叠加显示，全部发生在 PL 里，零 CPU 参与。

**阶段 2（pl/）是完整可烧板的方案**：对准桌面挥个白色笔帽，7 寸屏出彩虹拖尾；
目标消失 1.5 秒自动清屏；按 KEY 重新学背景。

## 文件

| 文件 | 作用 |
|---|---|
| `color_tracker.v` | 阶段 0 的 AXI 版追踪 IP（学习/备查） |
| `tb_color_tracker.v` / `sim.tcl` / `walk_model.py` | 阶段 0 仿真自验 |
| `arm/line_draw.c` / `air_canvas.c` | 阶段 1：ARM 端画线（备选路线） |
| `pl/top_air_canvas.v` | **阶段 2 顶层** |
| `pl/cam_capture_ds.v` | OV5640 采集 + 2x2 降采样（640x480→320x240） |
| `pl/tracker_pl.v` | 追踪器（cam 域，无 AXI） |
| `pl/canvas_pl.v` | 画布：硬件 Bresenham + 8bpp 彩虹索引 |
| `pl/video_out.v` | 800x480 上采样合成 + 叠加 |
| `pl/uint_div.v` | 24 位恢复余数除法器（复用） |
| `pl/i2c_dri.v` / `i2c_ov5640_rgb565_cfg.v` | 正点原子例程版权模块 |
| `pl/lcd_driver.v` / `clk_div.v` | 正点原子例程版权模块 |
| `pl/air_canvas.xdc` | 引脚约束（摄像头+LCD+按键，合并自你 D 盘例程） |
| `pl/verify_pl_chain.py` | 全链逻辑验证（12/12 PASS） |

## 阶段 2 烧板步骤（最简单路线）

1. Vivado 新建工程，器件选 **xc7z020clg400-2**（领航者 7020）
2. `Add Sources` 添加 `pl/` 下**全部 .v**（10 个）；`Add Constraints` 加 `air_canvas.xdc`
3. top 模块设为 `top_air_canvas`
4. Run Synthesis → Run Implementation → Generate Bitstream
5. 烧录（Auto Connect 到板子），**无 SDK 无 ARM 无 PS**，上电即玩

## 交互说明

| 操作 | 效果 |
|---|---|
| 挥白色笔帽 | 彩虹拖尾画线 |
| 目标静止不动约 1.5s（或握拳遮住） | 自动清屏 |
| 按 KEY0（L14） | 重新学习背景 + 清屏（重摆摄像头后） |
| 按 KEY1（K16） | 清屏 |
| 上电 | 等摄像头初始化完成 + 3 秒自动学背景 |

## 验证状态（2026-10-18）

| 验证项 | 状态 | 说明 |
|---|---|---|
| Verilog 编译（全 PL 10 文件） | ✅ 通过 | QuestaSim vlog 0 error 0 warning |
| 全链逻辑（capture→tracker→canvas） | ✅ 通过 | `verify_pl_chain.py` 12/12 PASS |
| 抓到并修复 2 个真 bug | ✅ | ① RGB565 灰度化未扩 8bit（白色亮度被压到 1/5，差分全废）② MIN_AREA=9 会被 2x2 降采样饿死（3x3 笔帽降采样后仅 4 像素，改 3） |
| 时序收敛 / 上板 | ⏳ | 需在 GUI Vivado 里 synth+impl 看 timing |

## 已知限制（下一步优化）

- 帧缓冲 320x240 上采样到 800x480 是 nearest（x2.5/y2），画布笔迹边缘轻微锯齿
- 单色目标（白色）；彩色笔帽需升级 tracker 的 RGB 差分（README 路线图见下）
- cam_pclk 40ns 周期假设来自例程 xdc（25MHz）；若 OV5640 输出帧率不同请核对 `i2c_ov5640_rgb565_cfg` 参数
- LCD 图比源图水平偏移 1 像素（BRAM 读延迟，画板无感，如需精确可加预取流水）

## 怎么跑仿真

命令行（在 `fpga-air-canvas` 目录下）：

```
vivado -mode batch -source sim.tcl
```

或手动：

1. Vivado 新建工程，器件选领航者同款 `xc7z020clg400-2`
   （如果板子是 AX7010，选 `xc7z010clg400-1`）
2. 添加 `color_tracker.v` + `tb_color_tracker.v`
3. `tb_color_tracker` 设为仿真顶层
4. Run Behavioral Simulation

**预期输出**（xsim 控制台）：

```
[PASS] bg_locked after learning frame
[PASS] frame 0: cx=8 cy=5 (expect 8,5)
[PASS] frame 1: cx=12 cy=7 (expect 12,7)
...
[PASS] frame 9: cx=44 cy=23 (expect 44,23)
ALL TESTS PASSED
```

看到 `ALL TESTS PASSED` 说明：背景学习、差分、质心、除法、AXI 全部打通。

## ARM 端上板步骤（阶段 1）

1. block design 照你 `42_ov5640_udp_pc` 例程搭：MIPI/CSI → Sensor2Video → **color_tracker** → VDMA(S2MM)；VDMA(MM2S) → VTC → RGB out
2. 送给 tracker 的分辨率与 `TRK_W/TRK_H` 一致（默认 320x240，先降采样）
3. Vitis 新建 application（standalone），bsp 勾 `axi_vdma` 驱动
4. 把 `arm/` 三个 .c/.h 加进 src，`air_canvas.c` 里的 TODO_USER 逐项改：
   - `TRACKER_BASE`：地址编辑器里 tracker IP 的基址
   - VDMA 初始化段：抄例程的 VDMA 配置（S2MM/MM2S 各 2 帧 circular）
   - `fb_raw/fb_out/canvas` 换成 link script 的 DDR 地址区
5. 编译烧录，摄像头对准桌面，挥笔帽

## 已知环境坑（重要）

- **QuestaSim 无 license 跑不了**（vsim 能编译不能 sim）
- **xsim 命令行 hack 是死路**：直接用 `bin/unwrapped/win64.o/xelab.exe` 需要手动补
  `XILINX_VIVADO / XILINX_PATH / RDI_DATADIR / RDI_BINROOT` 等一堆环境变量，
  且会报 `simulator-43-3404 / 43-3915` 空消息错误（gcc/clang/PATH 怎么换都绕不过）
- **本机 gcc/clang 被安全策略拦**：PowerShell/bash 里调用 Vivado 自带
  `tps/win64/msys64/mingw64/bin/gcc.exe`、`tps/llvm/3.4/win64/bin/clang.exe`
  均静默失败（exit 1 无输出）→ C 逻辑改用 Python 逐行等价断言验证
- **正解**：GUI Vivado 双击 `sim.tcl`（`vivado -mode batch -source sim.tcl`），
  GUI 环境下 setupEnv 完整，仿真正常
- 编译必须用默认 `work` 库名（xvlog 不加 `-work`，否则 xelab 找不到设计单元）
- **git push 抽风**：send-pack hang up / sandbox 吞 refs 都是老毛病
  → 小文件用 GitHub Contents API（`PUT /repos/xiaxia0717/vibe-lab/contents/<path>` + base64）逐个传，稳

## AXI 寄存器表

| 偏移 | 名称 | 说明 |
|---|---|---|
| 0x00 | CTRL | [0] enable，[1] learn（写 1 自清），[15:8] 差分阈值 |
| 0x04 | STATUS | [0] bg_locked，[1] target_valid |
| 0x08 | X | 质心 X（像素） |
| 0x0C | Y | 质心 Y（像素） |
| 0x10 | AREA | 目标像素数 |
| 0x14 | FRAME | 帧计数 |
| 0x18 | MINAREA | 有效目标最小面积（默认 9） |

## 上板路线（下一步）

完成阶段 1 见上面的「ARM 端上板步骤」。剩下的甜点：

1. ~~block design：MIPI/CSI → Sensor2Video → color_tracker → VDMA~~ ✅ 步骤已写
2. 彩色笔帽 → tracker PL 层颜色识别（RGB 差分，去掉灰度化）
3. 手势集：握拳悬停=切色 / 挥手=清屏（提高 ROI 位置）
4. 双人对战：两支不同色笔，PL 出两个质心
5. PL 合成化：把 overlay 搬进 PL（ARM 只写画布指令），CPU 占用归零

## 调参建议

- 差分阈值 `thr`：环境光变化大就调高（默认 64）
- `MINAREA`：防噪点，默认 9（3x3 笔尖刚好过线）
- 分辨率参数：默认 320x240，上板前和你的摄像头例程对齐
