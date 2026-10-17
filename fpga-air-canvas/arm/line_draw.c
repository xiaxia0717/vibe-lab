//=============================================================================
// line_draw.c - 画布绘制库实现（24bpp packed）
//=============================================================================
#include "line_draw.h"

void draw_point_rgb888(u8 *fb, int stride, int x, int y, u32 color)
{
    u8 *p;
    if (x < 0 || y < 0) return;
    p = fb + 3 * ((u32)y * stride + x);
    p[0] = (color >> 16) & 0xFF;   // R
    p[1] = (color >> 8)  & 0xFF;   // G
    p[2] =  color        & 0xFF;   // B
}

void draw_line_rgb888(u8 *fb, int stride,
                      int x0, int y0, int x1, int y1, u32 color)
{
    int dx =  x1 - x0; if (dx < 0) dx = -dx;
    int dy =  y1 - y0; if (dy < 0) dy = -dy;
    int sx = (x0 < x1) ? 1 : -1;
    int sy = (y0 < y1) ? 1 : -1;
    int err = dx - dy;
    int e2;

    for (;;) {
        draw_point_rgb888(fb, stride, x0, y0, color);
        if (x0 == x1 && y0 == y1) break;
        e2 = 2 * err;
        if (e2 > -dy) { err -= dy; x0 += sx; }
        if (e2 <  dx) { err += dx; y0 += sy; }
    }
}

u32 hsv2rgb(int hue, float s, float v)
{
    float r, g, b;
    int   i;
    float f, p, q, t;

    hue %= 360; if (hue < 0) hue += 360;
    i = hue / 60;
    f = (hue / 60.0f) - i;
    p = v * (1.0f - s);
    q = v * (1.0f - f * s);
    t = v * (1.0f - (1.0f - f) * s);

    switch (i) {
        case 0:  r = v; g = t; b = p; break;
        case 1:  r = q; g = v; b = p; break;
        case 2:  r = p; g = v; b = t; break;
        case 3:  r = p; g = q; b = v; break;
        case 4:  r = t; g = p; b = v; break;
        default: r = v; g = p; b = q; break;
    }
    return ((u32)(r * 255) << 16) | ((u32)(g * 255) << 8) | (u32)(b * 255);
}

void overlay_canvas(u8 *out, const u8 *canvas, int pixel_count)
{
    int i;
    for (i = 0; i < pixel_count; i++) {
        const u8 *c = canvas + 3 * i;
        u8 *o = out + 3 * i;
        if (c[0] || c[1] || c[2]) {   // 黑 = 透明
            o[0] = c[0]; o[1] = c[1]; o[2] = c[2];
        }
    }
}

void canvas_clear(u8 *canvas, int pixel_count)
{
    int i;
    for (i = 0; i < 3 * pixel_count; i++)
        canvas[i] = 0;
}
