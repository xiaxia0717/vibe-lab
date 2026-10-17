//=============================================================================
// air_canvas.c - 空中画板 ARM 端主程序（Vitis standalone / Xilinx SDK）
//---------------------------------------------------------------------------
// 流水线：OV5640 -> tracker(PL) -> VDMA(S2MM, raw) -> ARM 合成 -> VDMA(MM2S, out) -> 屏
//         ARM 每 33ms：读 tracker 坐标 -> canvas 画彩虹线 -> 叠加到 out -> 翻帧
//
// 手势：
//   - 笔尖移动      -> 彩虹拖尾连续画线（Bresenham 不断线）
//   - 目标丢失>1.5s -> 自动清屏（相当于"握拳停一秒擦黑板"）
//
// 上板前必改（搜 TODO_USER）：
//   1. TRACKER_BASE / VDMA 基址：block design 地址编辑器里点开 IP 抄
//   2. TRK_W/TRK_H：你送给 tracker 的分辨率（决定坐标→屏幕的缩放）
//   3. VDMA 初始化：engine 里换成你 42_ov5640_udp_pc 例程的配置（或照抄 setup_vdma）
//   4. fb_raw/fb_out/canvas 的内存：用 link script 的 DDR 高地址区，64B 对齐
//=============================================================================
#include <stdio.h>
#include <string.h>
#include "line_draw.h"

#include "xparameters.h"        /* TODO_USER: 你的工程版本 */
#include "xil_io.h"
#include "xil_cache.h"
#include "sleep.h"
#include "xaxivdma.h"           /* TODO_USER: bsp 勾选 axi_vdma */

/*---- 硬件基址（按你工程实际改）--------------------------------------------*/
#define TRACKER_BASE   0x43C00000u        /* TODO_USER: tracker IP 的 AXI 基址 */

/*---- 分辨率（按你工程实际改）----------------------------------------------*/
#define TRK_W          320                /* TODO_USER: tracker 输入流宽度 */
#define TRK_H          240                /* TODO_USER: tracker 输入流高度 */
#define LCD_W          800                /* 7 寸屏宽 */
#define LCD_H          480                /* 7 寸屏高 */

#define FRAME_PIXELS   (LCD_W * LCD_H)
#define FRAME_BYTES    (FRAME_PIXELS * 3)

/* tracker 寄存器偏移（与 color_tracker.v 一致）-----------------------------*/
#define TRK_CTRL       0x00
#define TRK_STATUS     0x04
#define TRK_X          0x08
#define TRK_Y          0x0C
#define TRK_MINAREA    0x18

#define ST_BG_LOCKED   0x1
#define ST_TARGET_VALID 0x2

/*---- 帧缓冲（TODO_USER: 换成 link script 中 DDR 高地址，避免堆冲突）-------*/
static u8 fb_raw[2][FRAME_BYTES] __attribute__((aligned(64)));
static u8 fb_out[2][FRAME_BYTES] __attribute__((aligned(64)));
static u8 canvas[FRAME_BYTES]   __attribute__((aligned(64)));

static XAxiVdma Vdma;
static int out_back = 0;

/*---- tracker 读写 ----------------------------------------------------------*/
static u32 tracker_r32(int off) { return Xil_In32(TRACKER_BASE + off); }
static void tracker_w32(int off, u32 v) { Xil_Out32(TRACKER_BASE + off, v); }

static int tracker_get(u16 *x, u16 *y)
{
    u32 st = tracker_r32(TRK_STATUS);
    if (!(st & ST_TARGET_VALID)) return 0;
    *x = tracker_r32(TRK_X) & 0xFFFF;
    *y = tracker_r32(TRK_Y) & 0xFFFF;
    return 1;
}

/* 学习背景：摄像头预热后让 PL 冻结一帧 */
static void tracker_learn(void)
{
    tracker_w32(TRK_CTRL, (64u << 8) | 0x1);       /* thr=64, learn=1 */
    tracker_w32(TRK_MINAREA, 9);
}

/*---- VDMA（简化封装；TODO_USER: 换成你例程的配置）-------------------------*/
/* 查询当前写帧号：VDMA S2MM 的 FRMSTORE 寄存器 */
static int current_raw_frame(void)
{
    u32 cr = Xil_In32(XPAR_AXI_VDMA_0_BASEADDR + 0x30);   /* S2MM VDMA_CR */
    return (cr >> 24) & 0x3;
}

/* MM2S 切换到指定显示帧（parking 模式） */
static void mm2s_flip(int idx)
{
    /* TODO_USER: 若你的 VDMA 配置了 parking，取消注释按 IP 版本二选一：
       XAxiVdma_StartParking(&Vdma, XAXIVDMA_READ, idx);
       XAxiVdma_StopParking (&Vdma, XAXIVDMA_READ);           */
    Xil_Out32(XPAR_AXI_VDMA_0_BASEADDR + 0x00,               /* MM2S VDMA_CR */
              (Xil_In32(XPAR_AXI_VDMA_0_BASEADDR + 0x00) & ~(3u << 22))
              | ((u32)idx << 22));
}

/* 合成 + 翻帧：raw 当前帧 + canvas -> out 背缓冲，然后切过去 */
static void compose_and_flip(void)
{
    int raw_i = current_raw_frame();
    memcpy(fb_out[out_back], fb_raw[raw_i], FRAME_BYTES);
    overlay_canvas(fb_out[out_back], canvas, FRAME_PIXELS);
    Xil_DCacheFlushRange((INTPTR)fb_out[out_back], FRAME_BYTES);
    mm2s_flip(out_back);
    out_back ^= 1;
}

/*---- 主循环 ----------------------------------------------------------------*/
int main(void)
{
    int hue = 0, lost = 0, have_prev = 0;
    int px = -1, py = -1;
    u16 tx, ty;

    init_platform();
    xil_printf("air canvas: boot\r\n");

    /* TODO_USER: VDMA 初始化 —— 抄你 42_ov5640_udp_pc 例程的这段：
       setup_vdma();
       - S2MM: circular 2 帧 = fb_raw[0..1], stride=LCD_W*3
       - MM2S: circular 2 帧 = fb_out[0..1], parking 模式
       摄像头出流分辨率需与 LCD_W/TRK_W 匹配（例程里先降采样再进 tracker）*/
    canvas_clear(canvas, FRAME_PIXELS);

    MB_Sleep(2000);            /* 摄像头自动曝光稳定 */
    tracker_learn();
    MB_Sleep(100);             /* 学完整一帧 */
    if (!(tracker_r32(TRK_STATUS) & ST_BG_LOCKED))
        xil_printf("warn: background not locked\r\n");

    for (;;) {
        MB_Sleep(33);          /* ~30fps */

        if (tracker_get(&tx, &ty)) {
            lost = 0;
            int sx = (int)tx * LCD_W / TRK_W;
            int sy = (int)ty * LCD_H / TRK_H;
            if (have_prev)
                draw_line_rgb888(canvas, LCD_W, px, py, sx, sy,
                                 hsv2rgb(hue, 1.0f, 1.0f));
            px = sx; py = sy; have_prev = 1;
            hue += 3; if (hue >= 360) hue -= 360;
        } else {
            have_prev = 0;
            if (++lost > 45) {          /* 1.5s 无目标 = 清屏手势 */
                canvas_clear(canvas, FRAME_PIXELS);
                lost = 0;
            }
        }
        compose_and_flip();
    }
    cleanup_platform();
    return 0;
}
