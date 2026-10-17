# line_draw.c 的逐行等价 Python 验证（本机 gcc/clang 被安全策略拦，无法编译原生 exe）
# 语义与 line_draw.c 一一对应：Bresenham / HSV->RGB / overlay / clear（24bpp packed）

W, H = 300, 200
RED, CYAN = 0xFF0000, 0x00FFFF
fails = 0

def check(cond, name):
    global fails
    if cond:
        print("[PASS]", name)
    else:
        print("[FAIL]", name); fails += 1

def _px(fb, stride, x, y, color):
    if x < 0 or y < 0:
        return
    o = 3 * (y * stride + x)
    fb[o]     = (color >> 16) & 0xFF
    fb[o + 1] = (color >> 8) & 0xFF
    fb[o + 2] = color & 0xFF

def _get(fb, stride, x, y):
    o = 3 * (y * stride + x)
    return (fb[o] << 16) | (fb[o + 1] << 8) | fb[o + 2]

def draw_line(fb, stride, x0, y0, x1, y1, color):
    dx, dy = abs(x1 - x0), abs(y1 - y0)
    sx = 1 if x0 < x1 else -1
    sy = 1 if y0 < y1 else -1
    err = dx - dy
    for _ in range(200000):
        _px(fb, stride, x0, y0, color)
        if x0 == x1 and y0 == y1:
            break
        e2 = 2 * err
        if e2 > -dy:
            err -= dy; x0 += sx
        if e2 < dx:
            err += dx; y0 += sy

def hsv2rgb(hue, s, v):
    hue = hue % 360
    i = int(hue / 60)
    f = hue / 60.0 - i
    p = v * (1.0 - s)
    q = v * (1.0 - f * s)
    t = v * (1.0 - (1.0 - f) * s)
    r, g, b = [(v,t,p),(q,v,p),(p,v,t),(p,q,v),(t,p,v),(v,p,q)][i]
    return (int(r*255) << 16) | (int(g*255) << 8) | int(b*255)

def overlay(out, canvas):
    for i in range(len(out) // 3):
        c = canvas[3*i:3*i+3]
        if c[0] or c[1] or c[2]:
            out[3*i:3*i+3] = c

# ---- 测试 1：竖线连续（只查已画区间）---------------------------------------
fb = bytearray(H * W * 3)
draw_line(fb, W, 50, 10, 50, 180, RED)
gaps = sum(1 for i in range(10, 181) if _get(fb, W, 50, i) != RED)
check(gaps == 0, "vertical line gap-free")

# ---- 测试 2：斜线点数 = max(|dx|,|dy|) --------------------------------------
fb = bytearray(H * W * 3)
draw_line(fb, W, 0, 0, 99, 149, RED)
n = sum(1 for i in range(H*W) if _get(fb, W, i % W, i // W) == RED)
check(n == 150, "diagonal max(nx,ny) points (got %d)" % n)

# ---- 测试 3：overlay 只覆盖非黑 ---------------------------------------------
out = bytearray([0x11,0x11,0x11, 0x22,0x22,0x22, 0x33,0x33,0x33, 0x44,0x44,0x44])
overlay(out, bytes([0,0,0, 0xAB,0xCD,0xEF, 0,0,0, 0x12,0x34,0x56]))
check(list(out) == [0x11,0x11,0x11, 0xAB,0xCD,0xEF, 0x33,0x33,0x33, 0x12,0x34,0x56],
      "overlay skips black canvas pixels")

# ---- 测试 4：HSV 彩虹 --------------------------------------------------------
bad = sum(1 for i in range(360) if hsv2rgb(i, 1.0, 1.0) == 0)
check(bad == 0, "hsv rainbow non-black across full circle")
check((hsv2rgb(0, 1, 1) & 0xFF0000) == 0xFF0000 and
      (hsv2rgb(120, 1, 1) & 0x00FF00) == 0x00FF00 and
      (hsv2rgb(240, 1, 1) & 0x0000FF) == 0x0000FF,
      "hsv red/green/blue primary hues")

# ---- 测试 5：生成 PPM（彩虹底 + 画线）----------------------------------------
with open("test_pattern.ppm", "wb") as f:
    f.write(b"P6\n%d %d\n255\n" % (W, H))
    for y in range(H):
        row = bytearray()
        for x in range(W):
            c = _get(fb, W, x, y)
            if c == 0:
                c = hsv2rgb(x * 360 // W, 0.7, 0.9)
            row += bytes(((c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF))
        f.write(row)
print("[PASS] test_pattern.ppm written")

if fails == 0:
    print("ALL TESTS PASSED")
else:
    print("TESTS FAILED:", fails)
raise SystemExit(1 if fails else 0)
