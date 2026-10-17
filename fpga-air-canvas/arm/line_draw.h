//=============================================================================
// line_draw.h - 空中画板画布绘制库（纯 C，零硬件依赖，PC 可编译自测）
//---------------------------------------------------------------------------
// 帧缓冲按 24bpp packed 排布：每像素 3 字节连续 (R,G,B)。
// VDMA 直接 MM2S 该缓冲驱动 RGB 屏，无需中间转换。
//  - Bresenham 直线
//  - HSV -> 0xRRGGBB 彩虹色
//  - canvas 叠加：黑像素透明，其余覆盖到输出帧
//=============================================================================
#ifndef LINE_DRAW_H
#define LINE_DRAW_H

typedef unsigned int  u32;
typedef unsigned char u8;

// 画线（含端点）。fb 为帧缓冲基址，stride 为一行像素数。color=0x00RRGGBB。
void draw_line_rgb888(u8 *fb, int stride,
                      int x0, int y0, int x1, int y1, u32 color);

// 画单点
void draw_point_rgb888(u8 *fb, int stride, int x, int y, u32 color);

// HSV(色相 0..359, S/V 0..1) -> 0x00RRGGBB
u32 hsv2rgb(int hue, float s, float v);

// 把 canvas 叠加到 out。canvas 中黑色像素视为透明。
void overlay_canvas(u8 *out, const u8 *canvas, int pixel_count);

// 画布清空（黑色 = 透明）
void canvas_clear(u8 *canvas, int pixel_count);

#endif
