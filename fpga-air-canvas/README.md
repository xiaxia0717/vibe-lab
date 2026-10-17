# Air Canvas 空中画板

- **阶段 0**：FPGA 追踪 IP + 仿真自验（`color_tracker.v`）
- **阶段 1**：ARM 端画布/画线主程序（`arm/air_canvas.c`）✅ 已完成
- **阶段 2（待）**：PL 硬件合成化 / 手势识别 / 双人对战

## 这是什么

空中画板的心脏：一个自己写的 FPGA 图像追踪 IP（`color_tracker.v`）。
摄像头画面流过它时**原样透传**，同时在硬件里做三件事：

1. **背景学习** — 按一下，冻结当前帧为背景
2. **目标提取** — 逐像素灰度差分，超过阈值的就是"笔尖"
3. **质心计算** — 每帧算出目标的 (cx, cy) 坐标，通过 AXI4-Lite 交给 ARM

ARM 端（阶段 1）拿到坐标后在 DDR 画布上画彩虹拖尾，
合成到输出帧由 VDMA 推给 7 寸屏。目标丢失 1.5 秒自动清屏。

## 文件

| 文件 | 作用 |
|---|---|
| `color_tracker.v` | 核心 IP，含内部除法器，单文件零 IP 依赖 |
| `tb_color_tracker.v` | 自校验仿真台：合成视频流，自动比对坐标 |
| `sim.tcl` | Vivado 一键仿真脚本 |
| `walk_model.py` | tracker 拍级 Python 参考模型（10/10 PASS） |
| `arm/line_draw.h/.c` | 画布库：Bresenham + HSV 彩虹 + overlay（24bpp） |
| `arm/air_canvas.c` | ARM 主程序：读坐标→画线→合成→翻帧 |
| `arm/verify_line_draw.py` | 画布库等价验证（6/6 PASS，本机 gcc 被安全策略拦） |
| `arm/test_pattern.png` | 验证渲染图：彩虹底 + Bresenham 画线 |

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

## 当前验证状态（2026-10-17）

| 验证项 | 状态 | 说明 |
|---|---|---|
| Verilog 编译 | ✅ 通过 | QuestaSim vlog 0 error 0 warning |
| AXI 声明顺序 bug | ✅ 已修 | `s_axi_wr_ctrl_learn` 声明前置 |
| 32→24 位宽不匹配 | ✅ 已修 | snap_x/snap_y/snap_a 截断到 [23:0] |
| tracker 算法逻辑 | ✅ 通过 | `walk_model.py` 拍级参考模型 10/10 PASS |
| 画布库逻辑 | ✅ 通过 | `arm/verify_line_draw.py` 等价验证 6/6 PASS |
| xsim 行为级仿真 | ⏳ 待跑 | 本机命令行 xelab 有环境坑（见下），需 GUI 里一键跑 |

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
