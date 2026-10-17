# Air Canvas 空中画板 - 阶段 0：核心追踪 IP + 仿真自验

## 这是什么

空中画板的心脏：一个自己写的 FPGA 图像追踪 IP（`color_tracker.v`）。
摄像头画面流过它时**原样透传**，同时在硬件里做三件事：

1. **背景学习** — 按一下，冻结当前帧为背景
2. **目标提取** — 逐像素灰度差分，超过阈值的就是"笔尖"
3. **质心计算** — 每帧算出目标的 (cx, cy) 坐标，通过 AXI4-Lite 交给 ARM

不需要板子，本目录就是一个可仿真、可自验的最小交付。

## 文件

| 文件 | 作用 |
|---|---|
| `color_tracker.v` | 核心 IP，含内部除法器，单文件零 IP 依赖 |
| `tb_color_tracker.v` | 自校验仿真台：合成视频流，自动比对坐标 |
| `sim.tcl` | Vivado 一键仿真脚本 |

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
| 算法逻辑（拍级） | ✅ 通过 | `walk_model.py` Python 参考模型 10/10 PASS |
| xsim 行为级仿真 | ⏳ 待跑 | 本机命令行 xelab 有环境坑（见下），需 GUI 里一键跑 |

## 已知环境坑（重要）

- **QuestaSim 无 license 跑不了**（vsim 能编译不能 sim）
- **xsim 命令行 hack 是死路**：直接用 `bin/unwrapped/win64.o/xelab.exe` 需要手动补
  `XILINX_VIVADO / XILINX_PATH / RDI_DATADIR / RDI_BINROOT` 等一堆环境变量，
  且会报 `simulator-43-3404 / 43-3915` 空消息错误（gcc/clang/PATH 怎么换都绕不过）
- **正解**：用 GUI Vivado 双击 `sim.tcl`（`vivado -mode batch -source sim.tcl`），
  GUI 环境下 setupEnv 完整，仿真正常
- 编译必须用默认 `work` 库名（xvlog 不加 `-work`，否则 xelab 找不到设计单元）

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

仿真过了之后，板级集成顺序：

1. block design：MIPI/CSI → Sensor2Video → **color_tracker** → VDMA
2. 7寸屏走 VTC + RGB out，第二路 VDMA 读叠加层
3. ARM 裸机/Vitis 工程里：每 33ms 读一次 X/Y，往叠加帧画线
4. 笔尖用**彩色笔帽**（先用单色，日后升级颜色识别）

## 调参建议

- 差分阈值 `thr`：环境光变化大就调高（默认 64）
- `MINAREA`：防噪点，默认 9（3x3 笔尖刚好过线）
- 分辨率参数：默认 320x240，上板前和你的摄像头例程对齐
