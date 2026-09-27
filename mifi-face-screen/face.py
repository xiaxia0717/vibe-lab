import time, os, sys, signal

W, H = 240, 320
FB = '/dev/fb0'
BL = '/sys/devices/platform/soc/soc:ap-apb/24700000.spi/spi_master/spi0/spi0.0/bl_gpio'

def bl_on():
    # the panel backlight is a gpio node, not /sys/class/backlight
    try:
        f = open(BL, 'w')
        f.write('1')
        f.close()
    except:
        pass

def C(r, g, b):
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)

BG     = C(8, 10, 18)
BAR    = C(20, 24, 40)
FACE   = C(255, 206, 64)
FACE_D = C(226, 172, 44)
EYE    = C(58, 44, 22)
WHITE  = C(238, 244, 255)
DIM    = C(110, 122, 148)
GREEN  = C(72, 222, 132)
AMBER  = C(255, 182, 62)
RED    = C(240, 84, 84)
CYAN   = C(84, 200, 240)
TRACK  = C(44, 50, 68)

FONT = {
    '0': (0x0E,0x11,0x11,0x11,0x11,0x11,0x0E),
    '1': (0x04,0x0C,0x04,0x04,0x04,0x04,0x0E),
    '2': (0x0E,0x11,0x01,0x02,0x04,0x08,0x1F),
    '3': (0x1F,0x02,0x04,0x02,0x01,0x11,0x0E),
    '4': (0x02,0x06,0x0A,0x12,0x1F,0x02,0x02),
    '5': (0x1F,0x10,0x1E,0x01,0x01,0x11,0x0E),
    '6': (0x06,0x08,0x10,0x1E,0x11,0x11,0x0E),
    '7': (0x1F,0x01,0x02,0x04,0x08,0x08,0x08),
    '8': (0x0E,0x11,0x11,0x0E,0x11,0x11,0x0E),
    '9': (0x0E,0x11,0x11,0x0F,0x01,0x02,0x0C),
    '.': (0x00,0x00,0x00,0x00,0x00,0x0C,0x0C),
    'G': (0x0E,0x11,0x10,0x17,0x11,0x11,0x0F),
    'M': (0x11,0x1B,0x15,0x15,0x11,0x11,0x11),
    'B': (0x1E,0x11,0x11,0x1E,0x11,0x11,0x1E),
    'P': (0x1E,0x11,0x11,0x1E,0x10,0x10,0x10),
    'S': (0x0F,0x10,0x10,0x0E,0x01,0x01,0x1E),
    'C': (0x0E,0x11,0x10,0x10,0x10,0x11,0x0E),
    'T': (0x1F,0x04,0x04,0x04,0x04,0x04,0x04),
    'K': (0x11,0x12,0x14,0x18,0x14,0x12,0x11),
    'Z': (0x1F,0x01,0x02,0x04,0x08,0x10,0x1F),
}

buf = [BG] * (W * H)

def rect(x0, y0, x1, y1, c):
    if x0 > x1: x0, x1 = x1, x0
    if y0 > y1: y0, y1 = y1, y0
    if x0 < 0: x0 = 0
    if y0 < 0: y0 = 0
    if x1 > W - 1: x1 = W - 1
    if y1 > H - 1: y1 = H - 1
    for y in range(y0, y1 + 1):
        base = y * W
        for x in range(x0, x1 + 1):
            buf[base + x] = c

def disc(cx, cy, r, c):
    r2 = r * r
    for y in range(cy - r, cy + r + 1):
        if y < 0 or y >= H: continue
        dy2 = (y - cy) * (y - cy)
        base = y * W
        for x in range(cx - r, cx + r + 1):
            if 0 <= x < W and (x - cx) * (x - cx) + dy2 <= r2:
                buf[base + x] = c

def ring(cx, cy, r, c, t):
    ro2 = r * r
    ri2 = (r - t) * (r - t)
    for y in range(cy - r, cy + r + 1):
        if y < 0 or y >= H: continue
        dy2 = (y - cy) * (y - cy)
        base = y * W
        for x in range(cx - r, cx + r + 1):
            if 0 <= x < W:
                d = (x - cx) * (x - cx) + dy2
                if ri2 < d <= ro2:
                    buf[base + x] = c

def arc(cx, cy, r, c, t, upper):
    ro2 = r * r
    ri2 = (r - t) * (r - t)
    y0 = cy - r if upper else cy
    y1 = cy if upper else cy + r
    for y in range(y0, y1 + 1):
        if y < 0 or y >= H: continue
        dy2 = (y - cy) * (y - cy)
        base = y * W
        for x in range(cx - r, cx + r + 1):
            if 0 <= x < W:
                d = (x - cx) * (x - cx) + dy2
                if ri2 < d <= ro2:
                    buf[base + x] = c

def char(x, y, ch, c, sc):
    rows = FONT.get(ch)
    if not rows: return
    for ry in range(7):
        bits = rows[ry]
        for rx in range(5):
            if bits & (1 << (4 - rx)):
                rect(x + rx * sc, y + ry * sc, x + rx * sc + sc - 1, y + ry * sc + sc - 1, c)

def text(x, y, s, c, sc):
    cx = x
    for ch in s:
        char(cx, y, ch, c, sc)
        cx += 6 * sc

def tw(s, sc):
    return len(s) * 6 * sc

def flush():
    f = open(FB, 'wb')
    f.write(''.join([chr(v & 255) + chr(v >> 8) for v in buf]))
    f.close()

def net_bytes():
    f = open('/proc/net/dev', 'r')
    d = f.read()
    f.close()
    for ln in d.split('\n'):
        if 'sipa_eth0' in ln:
            p = ln.split(':')[1].split()
            return int(p[0]), int(p[8])
    return 0, 0

def temp():
    try:
        f = open('/sys/class/thermal/thermal_zone0/temp', 'r')
        v = int(f.read().strip())
        f.close()
        return v / 1000.0
    except:
        return 0.0

def bars(n, x, y, c):
    for i in range(4):
        h = 5 + i * 4
        col = c if i < n else TRACK
        rect(x + i * 8, y + 19 - h, x + i * 8 + 5, y + 19, col)

def arrow(x, y, c, up):
    for i in range(8):
        if up:
            rect(x - i, y + i, x + i, y + i, c)
        else:
            rect(x - i, y + 15 - i, x + i, y + 15 - i, c)
    if up:
        rect(x - 1, y + 8, x + 1, y + 15, c)
    else:
        rect(x - 1, y, x + 1, y + 7, c)

hist = [0] * 46

def render(down, up, mood, tp, sig):
    for i in range(W * H):
        buf[i] = BG
    rect(0, 0, W - 1, 34, BAR)
    text(10, 9, '5G', CYAN if sig >= 3 else DIM, 2)
    bars(sig, 44, 7, GREEN if sig >= 3 else AMBER)
    t = '%.0fC' % tp
    text(W - 10 - tw(t, 2), 9, t, AMBER if tp < 72 else RED, 2)

    cx, cy, r = 120, 120, 74
    disc(cx, cy, r, FACE)
    ring(cx, cy, r, FACE_D, 3)

    if mood == 'happy':
        arc(cx - 30, cy - 16, 19, EYE, 6, True)
        arc(cx + 30, cy - 16, 19, EYE, 6, True)
        arc(cx, cy + 42, 44, EYE, 7, True)
    elif mood == 'sad':
        disc(cx - 30, cy - 18, 10, EYE)
        disc(cx + 30, cy - 18, 10, EYE)
        arc(cx, cy + 54, 42, EYE, 7, False)
        disc(cx - 30, cy - 4, 5, CYAN)
        disc(cx - 30, cy + 8, 4, CYAN)
    elif mood == 'sleep':
        rect(cx - 44, cy - 18, cx - 16, cy - 13, EYE)
        rect(cx + 16, cy - 18, cx + 44, cy - 13, EYE)
        disc(cx, cy + 34, 13, EYE)
        text(cx + 48, cy - 76, 'Z', DIM, 2)
        text(cx + 64, cy - 92, 'Z', DIM, 1)
    else:
        disc(cx - 30, cy - 18, 11, EYE)
        disc(cx + 30, cy - 18, 11, EYE)
        rect(cx - 28, cy + 32, cx + 28, cy + 39, EYE)

    if down >= 100:
        s = '%.0f' % down
    elif down >= 10:
        s = '%.1f' % down
    else:
        s = '%.2f' % down
    sc = 4
    if tw(s, sc) > W - 30:
        s = '%.1f' % down
        if tw(s, sc) > W - 30:
            s = '%.0f' % down
    if mood == 'happy':
        col = GREEN
    elif mood == 'normal':
        col = AMBER
    elif mood == 'sleep':
        col = DIM
    else:
        col = RED
    text((W - tw(s, sc)) / 2, 206, s, col, sc)
    text((W - tw('MBPS', 1)) / 2, 242, 'MBPS', DIM, 1)

    arrow(30, 258, CYAN, True)
    text(46, 258, '%.1f' % up, CYAN, 1)
    arrow(128, 258, GREEN, False)
    text(144, 258, '%.1f' % down, GREEN, 1)

    hist.append(down)
    while len(hist) > 46:
        hist.pop(0)
    mx = max(hist)
    if mx < 1: mx = 1
    rect(6, 308, 6 + 45 * 5 + 3, 309, TRACK)
    for i in range(len(hist)):
        v = hist[i]
        h = int(v / mx * 36)
        x = 6 + i * 5
        if h > 0:
            rect(x, 308 - h, x + 3, 308, GREEN if v >= 2 else AMBER)

    flush()

# SAFE MODE (default): never pause lcd.  lcd only repaints on events (button
# wake), while we repaint every second -- so we simply draw over it.  If this
# process dies for any reason the device stays perfectly usable: the clock
# comes back on the next key press and the backlight is untouched.
# Pass "--own" to take the screen over completely (pauses lcd).  Do NOT use
# that mode unless you have a way to resume lcd afterwards: if this process
# is killed while lcd is paused the panel stays frozen.
OWN = '--own' in sys.argv

def cleanup(sig, frame):
    if OWN:
        try:
            os.system('kill -CONT $(pidof lcd)')
        except:
            pass
    bl_on()
    sys.exit(0)

signal.signal(signal.SIGTERM, cleanup)
signal.signal(signal.SIGINT, cleanup)
signal.signal(signal.SIGHUP, cleanup)

if OWN:
    os.system('kill -STOP $(pidof lcd) 2>/dev/null')
bl_on()

prev_rx, prev_tx = net_bytes()
prev_t = time.time()
bl_t = time.time()
time.sleep(1)

while True:
    try:
        rx, tx = net_bytes()
        t = time.time()
        dt = t - prev_t
        if dt <= 0: dt = 1
        down = (rx - prev_rx) * 8.0 / dt / 1000000.0
        up = (tx - prev_tx) * 8.0 / dt / 1000000.0
        if down < 0: down = 0
        if up < 0: up = 0
        prev_rx, prev_tx, prev_t = rx, tx, t

        if down < 0.05 and up < 0.05:
            mood = 'sleep'
        elif down >= 10:
            mood = 'happy'
        elif down >= 2:
            mood = 'normal'
        else:
            mood = 'sad'

        tp = temp()
        sig = 4 if down >= 10 else (3 if down >= 4 else (2 if down >= 1 else 1))
        render(down, up, mood, tp, sig)

        # safety net: keep the backlight on even if something else flips it off
        if t - bl_t > 5:
            bl_on()
            bl_t = t

        time.sleep(1)
    except Exception, e:
        try:
            f = open('/tmp/face_err.log', 'a')
            f.write(str(e) + '\n')
            f.close()
        except:
            pass
        time.sleep(2)
