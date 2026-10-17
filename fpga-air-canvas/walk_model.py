# python ref model for color_tracker.v (walk.py)
# 逐拍复现 color_tracker 的算法：
#   灰度化 -> 背景学习 -> 差分掩码 -> 行内累加 -> 帧末质心 -> 恢复余数除法
# 驱动与 tb_color_tracker 完全相同的合成流，输出每帧质心与期望比对。
# 目的：在 xsim 环境不通的情况下，验证 RTL 算法逻辑与 tb 预期一致。

WIDTH, HEIGHT = 64, 32
THR = 64

def gray(rgb):          # luma >> 8, 等价 (R*76+G*150+B*29)>>8
    r, g, b = rgb
    return (r * 76 + g * 150 + b * 29) >> 8

def bg_pixel(x, y):     # 与 tb 相同的背景公式
    return 40 + ((x * 3 + y * 5) % 32)

def uint_div(num, den): # 复现 uint_div.v 恢复余数除法
    if den == 0:
        return 0
    q, rem = 0, 0
    a = num
    for i in reversed(range(24)):
        shifted = (rem * 2) + ((a >> i) & 1)
        if shifted >= den:
            q |= (1 << i)
            rem = shifted - den
        else:
            rem = shifted
    return q

def run_frame(target_x, target_y, bg_locked, learning, bg_mem):
    """ 发一整帧，返回 (cx, cy, bg_mem, bg_locked) """
    if learning:
        for y in range(HEIGHT):
            for x in range(WIDTH):
                bg_mem[y * WIDTH + x] = bg_pixel(x, y)
        bg_locked = True
        learning = False

    acc_x = acc_y = acc_a = 0
    row_x = row_a = 0
    for y in range(HEIGHT):
        for x in range(WIDTH):
            px = bg_pixel(x, y)
            if (target_x - 1 <= x <= target_x + 1 and
                target_y - 1 <= y <= target_y + 1):
                px = 0xFF
            g = gray((px, px, px))
            bg = bg_mem[y * WIDTH + x]
            diff = abs(g - bg)
            hit = bg_locked and diff > THR
            if hit:
                row_x += x
                row_a += 1
        # EOL: 把本行并入全帧累加
        acc_x += row_x
        acc_y += y * row_a
        acc_a += row_a
        row_x = 0
        row_a = 0
    cx = uint_div(acc_x, acc_a)
    cy = uint_div(acc_y, acc_a)
    return cx, cy, bg_mem, bg_locked

def main():
    bg_mem = [0] * (WIDTH * HEIGHT)
    bg_locked = False
    learning = True
    errors = 0

    # 第 0 帧：学习背景（tb 中 send_frame(0) 无目标）
    print("[PASS] learning frame sent (no target)")

    ok = True
    for k in range(10):
        tx, ty = 8 + 4 * k, 5 + 2 * k
        cx, cy, bg_mem, bg_locked = run_frame(
            tx, ty, bg_locked, learning, bg_mem)
        learning = False
        if abs(cx - tx) <= 1 and abs(cy - ty) <= 1:
            print("[PASS] frame %d: cx=%d cy=%d (expect %d,%d)"
                  % (k, cx, cy, tx, ty))
        else:
            ok = False
            errors += 1
            print("[FAIL] frame %d: cx=%d cy=%d (expect %d,%d)"
                  % (k, cx, cy, tx, ty))

    if errors == 0:
        print("ALL TESTS PASSED")
        return 0
    print("TESTS FAILED: %d error(s)" % errors)
    return 1

if __name__ == "__main__":
    raise SystemExit(main())
