# PL 全链逐拍验证模型（与 RTL 一一对应）：
#   cam_capture_ds 2x2 下采样寻址 -> tracker 质心算法 -> canvas Bresenham 落点
# 缩小比例跑：CMOS 64x32 -> DS 32x16 -> canvas 32x16
# 只验证自研 4 个模块的组合逻辑，例程模块（i2c/lcd）不含在内。

CMOS_W, CMOS_H = 64, 32
DS_W, DS_H = 32, 16
THR, MIN_AREA, LOST_FRAMES = 64, 3, 45
fails = 0

def check(cond, name):
    global fails
    print(("[PASS] " if cond else "[FAIL] ") + name)
    if not cond: fails += 1

# ---------- cam_capture_ds 模型（与 RTL 状态机逐句对应）--------------------
def capture_frame(frame, want_target, tx, ty):
    """frame[y][x]=gray 8bit；DVP 每像素 2 字节（偶字节=高）。
    返回 (frame_buf, ds_stream=[(addr, data)])"""
    fb = [0] * (DS_W * DS_H)
    stream = []
    rgb_h = 0
    take_row = True                       # 与 RTL 的 toggle 一致（帧首采）
    for y in range(CMOS_H):
        if not take_row:
            take_row = not take_row
            continue
        for b in range(2 * CMOS_W):       # href 内按字节
            pix = b // 2                  # 像素索引
            px = 255 if (want_target and abs(pix - tx) <= 1 and abs(y - ty) <= 1) else frame[y][pix]
            if b % 2 == 0:
                rgb_h = px                # 高字节
            else:
                if pix % 2 == 0:                    # 偶像素才收
                    ds_x = pix // 2
                    ds_y = y // 2
                    stream.append((ds_y * DS_W + ds_x, (rgb_h << 8) | px))
        take_row = not take_row
    for a, d in stream:
        fb[a] = d
    return fb, stream

# ---------- tracker 模型（PL 版算法，同 walk_model）------------------------
def gray565(d):
    r5, g6, b5 = (d >> 11) & 31, (d >> 5) & 63, d & 31
    r8, g8, b8 = (r5 << 3) | (r5 >> 2), (g6 << 2) | (g6 >> 4), (b5 << 3) | (b5 >> 2)
    return (r8 * 76 + g8 * 150 + b8 * 29) >> 8

def uint_div(num, den):
    if den == 0: return 0
    q, rem = 0, 0
    a = num
    for i in reversed(range(24)):
        shifted = (rem * 2) + ((a >> i) & 1)
        if shifted >= den:
            q |= (1 << i); rem = shifted - den
        else:
            rem = shifted
    return q

def track(stream, bg_locked, bg_mem, learning):
    if learning:
        for a, d in stream:
            bg_mem[a] = gray565(d)
        bg_locked = True
    acc_x = acc_y = acc_a = 0
    for a, d in stream:
        g = gray565(d)
        if bg_locked and abs(g - bg_mem[a]) > THR:
            x, y = a % DS_W, a // DS_W
            acc_x += x; acc_y += y; acc_a += 1
    cx = uint_div(acc_x, acc_a)
    cy = uint_div(acc_y, acc_a)
    valid = bg_locked and acc_a >= MIN_AREA
    return cx, cy, valid, bg_mem, bg_locked

# ---------- canvas Bresenham 模型（与 FSM 等价）---------------------------
def bresenham(cv, x0, y0, x1, y1, color, w=DS_W):
    dx, dy = abs(x1-x0), abs(y1-y0)
    sx, sy = (1 if x0 < x1 else -1), (1 if y0 < y1 else -1)
    err = dx - dy
    pts = []
    while True:
        pts.append((x0, y0))
        if x0 == x1 and y0 == y1: break
        e2 = 2 * err
        if e2 > -dy: err -= dy; x0 += sx
        if e2 <  dx: err += dx; y0 += sy
    for p in pts:
        cv[p[1]*w + p[0]] = color
    return pts

# ======================= 主流程 ===========================================
# 合成背景（稳定纹理）
bg = [[40 + ((x*3 + y*5) % 32) for x in range(CMOS_W)] for y in range(CMOS_H)]

# --- 1) capture 采样验证：目标在 (9,5) 处 3x3 -> stream 里出现该点 --------
fb, stream = capture_frame(bg, True, 9, 5)
check(len(stream) == DS_W * DS_H, "capture emits full DS frame (%d/%d)" % (len(stream), DS_W*DS_H))
# 目标 (9,5) 在 DS 域 = (9//2, 5//2) = (4,2)
tgt_addr = (5//2) * DS_W + (9//2)
vals = [d for a, d in stream if a == tgt_addr]
check(any(gray565(d) >= 250 for d in vals), "downsampled target pixel present at ds(4,2)")

# --- 2) 学习 + 5 帧追踪 ------------------------------------------------
bg_mem = [0]*(DS_W*DS_H)
stream0, = [capture_frame(bg, False, 0, 0)[1]]
bg_mem = [0]*(DS_W*DS_H)
_, s0 = capture_frame(bg, False, 0, 0)
bg_mem = [0]*(DS_W*DS_H)
cx, cy, valid, bg_mem, locked = track(s0, False, bg_mem, True)
check(locked, "tracker locks background on learning frame")

for k in range(5):
    tx, ty = 5 + 2*k, 3 + k
    tx_cm, ty_cm = tx*2-1, ty*2-1           # cam 域目标中心（3x3 亮区）
    fb, st = capture_frame(bg, True, tx_cm, ty_cm)
    cx, cy, valid, bg_mem, locked = track(st, locked, bg_mem, False)
    # 3x3 亮区过 2x2 采样成 2x2 块，质心 = (cam//2, cam//2) 附近
    check(valid and abs(cx - tx_cm//2) <= 1 and abs(cy - ty_cm//2) <= 1,
          "track centroid frame %d -> (%d,%d) expect (~%d,%d)" % (k, cx, cy, tx_cm//2, ty_cm//2))

# --- 3) canvas Bresenham 从 (2,3) 到 (10,7) --------------------------------
cv = [0]*(DS_W*DS_H)
pts = bresenham(cv, 2, 3, 10, 7, 0x55)
check(len(pts) == 9, "bresenham point count = max(dx,dy) (got %d)" % len(pts))
check(all(cv[p[1]*DS_W+p[0]] == 0x55 for p in pts), "all line pixels written")
check(cv[3*DS_W+2] == 0x55 and cv[7*DS_W+10] == 0x55, "endpoints hit")

# --- 4) 画笔链：帧间坐标差 -> 线连续 --------------------------------------
cv = [0]*(DS_W*DS_H)
prev = None
for k in range(5):
    cur = (4 + k*3, 6 + k*2)
    if prev: bresenham(cv, prev[0], prev[1], cur[0], cur[1], 0x77)
    else:    cv[cur[1]*DS_W+cur[0]] = 0x77
    prev = cur
# (16,14) 终点
check(cv[14*DS_W+16] == 0x77, "chain endpoint written")
# 中间点 (10,10) 应在线上（从 (7,8) 到 (10,10)）
check(cv[10*DS_W+10] == 0x77, "chain midpoint continuous")

print()
if fails == 0: print("ALL PL CHAIN TESTS PASSED")
else:          print("PL CHAIN TESTS FAILED: %d" % fails)
raise SystemExit(1 if fails else 0)
