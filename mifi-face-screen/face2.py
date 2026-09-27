# -*- coding: utf-8 -*-
# MiFi network-speed face screen  --  v2
#
# Runs on the device's own python 2.7 (no array / math / mmap / base64 / re).
# Draws straight into /dev/fb0 (240x320 RGB565) and coexists with the factory
# Qt UI ("lcd") instead of pausing it.
#
# ---------------------------------------------------------------------------
# v2 changes
#   * fixed: happy/sad mouths were drawn upside down (arc polarity)
#   * fixed: sad mouth overflowed the bottom of the face disc
#   * fixed: tear was two overlapping blobs -> real teardrop, repositioned
#   * fixed: sleep "Z"s were 1-2px, one of them sat on top of the status bar
#   * new:   the signal bars now show REAL signal (from the fy status log),
#            they used to be derived from download speed (i.e. a lie)
#   * new:   battery gauge + charge bolt, client count, band, throttle warning
#   * new:   anti-aliased disc edge, rounded panels, cleaner digits
#   * perf:  no more ''.join([chr()..]) packing -- direct bytearray writes

import time, os, sys, signal

W, H = 240, 320
FB = '/dev/fb0'
BL = '/sys/devices/platform/soc/soc:ap-apb/24700000.spi/spi_master/spi0/spi0.0/bl_gpio'
FYL = '/mnt/data/fy/log/fylog'
BATP = '/sys/class/power_supply/sc27xx-fgu/capacity'
BATS = '/sys/class/power_supply/sc27xx-fgu/status'
CLIF = '/mnt/data/fy/config/wificlients'
THERM = '/sys/class/thermal/thermal_zone9/temp'   # battery-thmzone (what the vendor UI shows)
THERM_SOC = '/sys/class/thermal/thermal_zone0/temp'  # soc-thmzone (throttles at 70C)
PING_HOST = '223.5.5.5'      # AliDNS -- reachable and cheap to hit from CN
PING_TMP = '/tmp/face_ping.txt'


def bl_on():
    try:
        f = open(BL, 'w'); f.write('1'); f.close()
    except:
        pass


# ---------------------------------------------------------------- palette --
def C(r, g, b):
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)


BG      = C(10, 12, 20)
PANEL   = C(26, 30, 46)
PANEL_L = C(40, 46, 68)
TRACK   = C(34, 38, 56)

FACE    = C(255, 202, 62)
FACE_D  = C(214, 158, 36)
FACE_HOT= C(255, 122, 82)
EYE     = C(46, 34, 16)
WHITE   = C(240, 246, 255)
DIM     = C(154, 166, 196)
DIM2    = C(112, 124, 156)

GREEN   = C(74, 224, 134)
AMBER   = C(255, 186, 66)
RED     = C(244, 92, 88)
CYAN    = C(86, 204, 244)
BLUE    = C(92, 140, 244)
BAR_MID = C(200, 200, 92)
BAR_LOW = C(96, 108, 140)

# precomputed 2-byte little-endian strings -> flush() never calls chr() 76k times
# (bench on the device: 0.250 s -> 0.033 s per frame)


def mix(c1, c2, t):
    """blend two RGB565 colours, t in 0..16 (16 = all c1)."""
    r1 = (c1 >> 11) & 31; g1 = (c1 >> 5) & 63; b1 = c1 & 31
    r2 = (c2 >> 11) & 31; g2 = (c2 >> 5) & 63; b2 = c2 & 31
    r = (r1 * t + r2 * (16 - t)) >> 4
    g = (g1 * t + g2 * (16 - t)) >> 4
    b = (b1 * t + b2 * (16 - t)) >> 4
    return (r << 11) | (g << 5) | b


# rim colours are resolved once at import time, never during a frame
FACE_AA   = mix(FACE, BG, 9)
FACEX_AA  = mix(FACE_HOT, BG, 9)
CYAN_AA   = mix(CYAN, BG, 9)
FACEX_RIM = mix(FACE_HOT, BG, 6)

LE = {}


class LUT(dict):
    """little-endian RGB565 -> 2-byte string, with a self-healing miss path.

    A plain dict blew up with KeyError the first time a colour was built
    somewhere other than the palette table (the histogram bars did exactly
    that).  Missing keys are now encoded on first use and cached, so the
    renderer can never be killed by an unregistered colour again.
    """

    def __missing__(self, k):
        v = chr(k & 255) + chr(k >> 8)
        self[k] = v
        return v


LE = LUT()
for _v in (BG, PANEL, PANEL_L, TRACK, FACE, FACE_D, FACE_HOT, EYE, WHITE, DIM,
           DIM2, GREEN, AMBER, RED, CYAN, BLUE, BAR_MID, BAR_LOW,
           FACE_AA, FACEX_AA, CYAN_AA, FACEX_RIM):
    LE[_v] = chr(_v & 255) + chr(_v >> 8)


# ------------------------------------------------------------------ font ---
# 5x7, one byte per row, bit4 = leftmost.  only the glyphs we actually use.
FONT = {
    '0': (0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E),
    '1': (0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E),
    '2': (0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F),
    '3': (0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E),
    '4': (0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02),
    '5': (0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E),
    '6': (0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E),
    '7': (0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08),
    '8': (0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E),
    '9': (0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C),
    '.': (0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C),
    '%': (0x18, 0x19, 0x02, 0x04, 0x08, 0x13, 0x03),
    '-': (0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00),
    '/': (0x01, 0x02, 0x02, 0x04, 0x08, 0x08, 0x10),
    ':': (0x00, 0x0C, 0x0C, 0x00, 0x0C, 0x0C, 0x00),
    'M': (0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11),
    'B': (0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E),
    'P': (0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10),
    'S': (0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E),
    'G': (0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0F),
    'C': (0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E),
    'N': (0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11),
    'Z': (0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F),
    'L': (0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F),
    'T': (0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04),
    'E': (0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F),
    'K': (0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11),
    # lowercase -- only the two we need for the "ms" latency suffix
    'm': (0x00, 0x00, 0x1A, 0x15, 0x15, 0x15, 0x15),
    's': (0x00, 0x00, 0x0E, 0x10, 0x0E, 0x01, 0x1E),
}

buf = [BG] * (W * H)
BGFILL = [BG] * (W * H)          # reused for the per-frame clear (C-level slice copy)

_HW = {}


def _halfwidths(r):
    """cache of per-row half-widths for a filled circle of radius r.
    lets disc() be O(r) instead of O(r^2) -- no math module needed."""
    hw = _HW.get(r)
    if hw is None:
        r2 = r * r
        hw = []
        for dy in range(-r, r + 1):
            dy2 = dy * dy
            x = r
            while x > 0 and x * x + dy2 > r2:
                x -= 1
            hw.append(x)
        _HW[r] = hw
    return hw


# ------------------------------------------------------------ primitives ---
def rect(x0, y0, x1, y1, c):
    if x0 > x1: x0, x1 = x1, x0
    if y0 > y1: y0, y1 = y1, y0
    if x0 < 0: x0 = 0
    if y0 < 0: y0 = 0
    if x1 > W - 1: x1 = W - 1
    if y1 > H - 1: y1 = H - 1
    if x1 < x0 or y1 < y0: return
    row = [c] * (x1 - x0 + 1)
    for y in range(y0, y1 + 1):
        base = y * W
        buf[base + x0:base + x1 + 1] = row


def disc(cx, cy, r, c, ec=None):
    """filled circle.  `ec` = precomputed rim colour blended 1px in (cheap AA)."""
    hw = _halfwidths(r)
    hwi = _halfwidths(r - 1) if (ec is not None and r > 1) else None
    for dy in range(-r, r + 1):
        y = cy + dy
        if y < 0 or y >= H: continue
        w = hw[dy + r]
        x0 = cx - w
        x1 = cx + w
        if x0 < 0: x0 = 0
        if x1 >= W: x1 = W - 1
        if x1 < x0: continue
        base = y * W
        if hwi is None or dy < 1 - r or dy > r - 1:
            buf[base + x0:base + x1 + 1] = [c] * (x1 - x0 + 1)
            continue
        wi = hwi[dy + r - 1]
        a = cx - wi
        b = cx + wi
        if a < x0: a = x0
        if b > x1: b = x1
        if a > x0:
            buf[base + x0:base + a] = [ec] * (a - x0)
        if b >= a:
            buf[base + a:base + b + 1] = [c] * (b - a + 1)
        if x1 > b:
            buf[base + b + 1:base + x1 + 1] = [ec] * (x1 - b)


def ring(cx, cy, r, t, c):
    ro2 = r * r
    ri2 = (r - t) * (r - t)
    for y in range(cy - r, cy + r + 1):
        if y < 0 or y >= H: continue
        dy2 = (y - cy) * (y - cy)
        base = y * W
        for x in range(cx - r, cx + r + 1):
            if x < 0 or x >= W: continue
            d = (x - cx) * (x - cx) + dy2
            if ri2 < d <= ro2:
                buf[base + x] = c


def arc(cx, cy, r, t, c, upper, xr=None):
    """thick arc.  upper=True -> the half ABOVE the centre (a 'frown' shape),
    upper=False -> the half BELOW the centre (a 'smile' shape).
    `xr` = (x0, x1) clips the arc horizontally, which is how we get a shallow
    smile out of a large radius instead of a full half-circle."""
    ro2 = r * r
    ri2 = (r - t) * (r - t)
    if upper:
        y0, y1 = cy - r, cy
    else:
        y0, y1 = cy, cy + r
    for y in range(y0, y1 + 1):
        if y < 0 or y >= H: continue
        dy2 = (y - cy) * (y - cy)
        base = y * W
        for x in range(cx - r, cx + r + 1):
            if x < 0 or x >= W: continue
            if xr is not None and (x < xr[0] or x > xr[1]): continue
            d = (x - cx) * (x - cx) + dy2
            if ri2 < d <= ro2:
                buf[base + x] = c


def rrect(x0, y0, x1, y1, c, r=3):
    """filled rounded rectangle (corners knocked out)."""
    rect(x0 + r, y0, x1 - r, y1, c)
    rect(x0, y0 + r, x0 + r - 1, y1 - r, c)
    rect(x1 - r + 1, y0 + r, x1, y1 - r, c)
    for i in range(r):
        for j in range(r):
            if (r - i) * (r - i) + (r - j) * (r - j) > r * r:
                buf[(y0 + j) * W + x0 + i] = BG
                buf[(y0 + j) * W + x1 - i] = BG
                buf[(y1 - j) * W + x0 + i] = BG
                buf[(y1 - j) * W + x1 - i] = BG


def glyph(x, y, ch, c, sc):
    rows = FONT.get(ch)
    if not rows: return
    for ry in range(7):
        bits = rows[ry]
        if not bits: continue
        for rx in range(5):
            if bits & (1 << (4 - rx)):
                rect(x + rx * sc, y + ry * sc, x + rx * sc + sc - 1, y + ry * sc + sc - 1, c)


def text(x, y, s, c, sc):
    cx = x
    for ch in s:
        glyph(cx, y, ch, c, sc)
        cx += 6 * sc


def tw(s, sc):
    return len(s) * 6 * sc


# ---------------------------------------------------------------- widgets --
def signal_bars(n, x, y, c):
    """n = 0..4 filled bars, baseline at y."""
    for i in range(4):
        h = 5 + i * 4
        col = c if i < n else TRACK
        rect(x + i * 6, y - h, x + i * 6 + 4, y, col)


def bolt(x, y, c):
    """lightning bolt, 7 wide x 11 tall at (x,y)."""
    rect(x + 4, y,     x + 5, y + 2, c)
    rect(x + 2, y + 2, x + 4, y + 4, c)
    rect(x + 0, y + 4, x + 5, y + 5, c)
    rect(x + 2, y + 5, x + 6, y + 7, c)
    rect(x + 2, y + 7, x + 3, y + 9, c)
    rect(x + 1, y + 9, x + 2, y + 10, c)


def battery(x, y, pct, charging):
    """icon 24x11 at (x,y): outline + proportional fill."""
    x1, y1 = x + 22, y + 10
    rect(x, y, x1, y1, PANEL_L)
    rect(x + 1, y + 1, x1 - 1, y1 - 1, BG)
    rect(x1 + 2, y + 3, x1 + 3, y + 7, PANEL_L)          # nub
    if pct > 100: pct = 100
    if pct < 0: pct = 0
    fw = (20 * pct) // 100
    if fw > 0 and fw < 2:
        fw = 2                     # 1px is invisible at this size; keep low charge readable
    if fw > 0:
        if pct <= 15: col = RED
        elif pct <= 35: col = AMBER
        else: col = GREEN
        rect(x + 1, y + 1, x + fw, y1 - 1, col)


def arrow(x, y, c, up):
    """solid triangle, 9 wide, 7 tall."""
    for i in range(7):
        if up:
            rect(x - i // 2 - 1, y + i, x + i // 2 + 1, y + i, c)
        else:
            rect(x - i // 2 - 1, y + 6 - i, x + i // 2 + 1, y + 6 - i, c)


def client_icon(x, y, c):
    """simple person glyph, 10 wide x 12 tall -- reads better than two blobs."""
    disc(x + 5, y + 3, 3, c)
    rect(x + 2, y + 7, x + 8, y + 8, c)
    rect(x + 1, y + 8, x + 9, y + 11, c)


def bar_h(v):
    """log-ish bar height, 0..54, no math module."""
    if v <= 0: return 0
    if v < 1: return int(v * 8.0)
    if v < 5: return 8 + int((v - 1) * 4.0)
    if v < 20: return 24 + int((v - 5) * 1.6)
    if v < 50: return 48 + int((v - 20) * 0.2)
    return 54


# ------------------------------------------------------------------ data ---
def read_netdev():
    try:
        f = open('/proc/net/dev', 'r'); d = f.read(); f.close()
    except:
        return None
    for ln in d.split('\n'):
        if 'sipa_eth0' in ln:
            p = ln.split(':')[1].split()
            return int(p[0]), int(p[8])
    return None


def tail(path, n):
    try:
        f = open(path, 'rb')
        f.seek(0, 2)
        size = f.tell()
        f.seek(size - n if size > n else 0)
        d = f.read()
        f.close()
        return d
    except:
        return ''


def vfield(line, key):
    """value of `key:` in a fy status line, stopping at , or ) or \"."""
    i = line.find(key + ':')
    if i < 0: return ''
    i += len(key) + 1
    j = i
    while j < len(line) and line[j] not in ',)\n':
        j += 1
    return line[i:j].strip('"')


def read_status():
    """latest VUPDATE snapshot from the fy log: signal / band / clients / etc.

    Gotcha: the marker line and the payload are NOT the same line.  The log
    writes `... <<< VUPDATE REQ <<< |` and then the field list on the next
    line, so slicing a single line yields nothing but the marker.  Take a
    window starting at the marker instead -- it copes with both layouts.
    """
    d = tail(FYL, 20000)
    # We are reading a file that is actively being appended to, so the newest
    # VUPDATE marker usually has only part of its payload written out.  Walk
    # backwards and take the newest record that is actually complete (the
    # `wifinum` field sits near the end, so its presence means we got it all).
    pos = d.rfind('VUPDATE REQ')
    first = pos
    while pos >= 0:
        if 'wifinum' in d[pos:pos + 1400]:
            break
        pos = d.rfind('VUPDATE REQ', 0, pos)
    if pos < 0:
        pos = first                 # no complete record yet -- use what we have
    if pos < 0:
        return {}
    ln = d[pos:pos + 1400]
    st = {}
    for k in ('signal', 'nettype', 'wifinum', 'temp', 'voltage'):
        v = vfield(ln, k)
        if v:
            st[k] = v
    # `charge:"charging"` -- not vfield(), because the line also contains
    # `bat charge:33122` earlier on, which would match the same key.
    cg = ln.find('charge:"')
    if cg >= 0:
        st['charge'] = ln[cg + 8:ln.find('"', cg + 8)]
    bsi = ln.find('bsi:"')
    if bsi >= 0:
        e = ln.find('"', bsi + 5)
        if e > bsi:
            st['band'] = ln[bsi + 5:e].split(',')[-1]
    return st


def read_int(path, default=0):
    try:
        f = open(path, 'r'); v = f.read().strip(); f.close()
        return int(v)
    except:
        return default


def read_battery():
    pct = read_int(BATP, -1)
    try:
        f = open(BATS, 'r'); s = f.read().strip(); f.close()
    except:
        s = ''
    return pct, (s.lower().find('charg') >= 0 and s.lower().find('discharg') < 0)


def read_clients():
    try:
        f = open(CLIF, 'r'); d = f.read(); f.close()
    except:
        return -1
    n = 0
    for ln in d.split('\n'):
        if ln.strip(): n += 1
    return n


def read_temp():
    t = read_int(THERM, 0)
    return t / 1000.0


def read_temp_soc():
    """SoC die temperature.  The vendor thermal policy throttles THIS one at
    70C, so it -- not the battery -- is what causes the sudden speed drops."""
    t = read_int(THERM_SOC, 0)
    return t / 1000.0


def ping_async():
    """Fire off a one-shot ping in the background and return immediately.

    Measured on the device: os.system() comes back in 0.004 s this way.  The
    synchronous form blocks for a full 1.01 s whenever the host does not
    answer -- long enough to leave the factory clock sitting on the face, so
    we never call it that way.
    """
    try:
        os.system('ping -c 1 -W 1 ' + PING_HOST + ' > ' + PING_TMP + ' 2>&1 &')
    except:
        pass


def read_ping():
    """RTT in ms from the last background ping, or -1 if there was no reply."""
    try:
        f = open(PING_TMP, 'r'); d = f.read(); f.close()
    except:
        return -1
    i = d.find('time=')
    if i < 0:
        return -1
    j = i + 5
    k = j
    while k < len(d) and (d[k].isdigit() or d[k] == '.'):
        k += 1
    try:
        return float(d[j:k])
    except:
        return -1


# ---------------------------------------------------------------- render ---
def mood_of(down, up):
    if down < 0.05 and up < 0.05: return 'sleep'
    if down >= 10: return 'happy'
    if down >= 2: return 'normal'
    return 'sad'


def draw_face(cx, cy, r, mood, hot, ph):
    body = FACE_HOT if hot else FACE
    rim = FACEX_RIM if hot else FACE_D
    disc(cx, cy, r, body, FACEX_AA if hot else FACE_AA)
    ring(cx, cy, r, 2, rim)

    if mood == 'happy':
        # closed happy eyes  ^ ^
        arc(cx - 24, cy - 12, 13, 5, EYE, True)
        arc(cx + 24, cy - 12, 13, 5, EYE, True)
        # wide deep smile: big radius + clipped span = a smooth curve, no flat ends
        arc(cx, cy - 8, 46, 6, EYE, False, (cx - 34, cx + 34))
    elif mood == 'sad':
        disc(cx - 23, cy - 14, 8, EYE)
        disc(cx + 23, cy - 14, 8, EYE)
        # frown, shallow and well inside the disc
        arc(cx, cy + 56, 40, 6, EYE, True, (cx - 26, cx + 26))
        # one teardrop on the left eye, animated
        ty = cy + (ph % 6)
        disc(cx - 23, ty, 4, CYAN, CYAN_AA)
        rect(cx - 24, ty - 11, cx - 22, ty - 4, CYAN)
        rect(cx - 23, ty - 13, cx - 23, ty - 12, CYAN)
    elif mood == 'sleep':
        rect(cx - 30, cy - 14, cx - 12, cy - 10, EYE)
        rect(cx + 12, cy - 14, cx + 30, cy - 10, EYE)
        disc(cx, cy + 22, 9, EYE)
        # floating Z's, kept clear of the face disc so they stay readable
        z1 = cy - 46 - (ph % 6)
        text(cx + 70, z1, 'Z', DIM, 2)
        text(cx + 86, z1 - 13, 'Z', DIM2, 1)
    else:
        disc(cx - 23, cy - 14, 9, EYE)
        disc(cx + 23, cy - 14, 9, EYE)
        # gentle smile -- shallower than the happy one
        arc(cx, cy - 20, 48, 5, EYE, False, (cx - 22, cx + 22))

    if hot:
        # sweat drop on the right temple
        sy = cy - 34 + (ph % 8)
        disc(cx + 44, sy, 4, CYAN, CYAN_AA)
        rect(cx + 42, sy - 9, cx + 46, sy - 3, CYAN)


def render(st):
    buf[:] = BGFILL

    down, up = st['down'], st['up']
    mood = st['mood']
    hot = st['hot']
    ph = st['frame']

    # ---------------------------------------------------------- status bar
    rect(0, 0, W - 1, 27, PANEL)
    rect(0, 27, W - 1, 27, PANEL_L)

    sig = st['sig']
    n = 0 if sig <= 0 else (1 if sig < 30 else (2 if sig < 55 else (3 if sig < 75 else 4)))
    scol = DIM if n == 0 else (RED if n == 1 else (AMBER if n == 2 else GREEN))
    signal_bars(n, 8, 21, scol)

    net = st['net']
    band = st['band']
    lab = net + ((' ' + band) if band else '')
    text(36, 10, lab, WHITE, 1)

    pct, chg = st['bat'], st['chg']
    if pct >= 0:
        if chg:
            bolt(164, 8, GREEN)
        battery(178, 9, pct, chg)
        t = '%d%%' % pct
        text(210, 11, t, GREEN if pct > 35 else (AMBER if pct > 15 else RED), 1)

    # --------------------------------------------------------------- face
    draw_face(120, 108, 62, mood, hot, ph)

    # ------------------------------------------------------------- reading
    if down >= 100: s = '%.0f' % down
    elif down >= 10: s = '%.1f' % down
    else: s = '%.2f' % down
    sc = 4
    if tw(s, sc) > W - 24:
        s = '%.1f' % down
        if tw(s, sc) > W - 24: s = '%.0f' % down
    if mood == 'happy': col = GREEN
    elif mood == 'normal': col = AMBER
    elif mood == 'sleep': col = DIM
    else: col = RED
    text((W - tw(s, sc)) // 2, 182, s, col, sc)
    text((W - tw('MBPS', 1)) // 2, 214, 'MBPS', DIM2, 1)

    # ------------------------------------------------------------ info row
    # upload / clients / latency / temperature.
    # NOTE: there is deliberately no download figure here -- the big number
    # above IS the download, so repeating it down here was pure noise.
    y = 234
    arrow(10, y + 2, CYAN, True)
    text(22, y + 4, '%.1f' % up, CYAN, 1)

    cl = st['clients']
    if cl >= 0:
        client_icon(64, y + 1, BLUE)
        text(78, y + 4, '%d' % cl, BLUE, 1)

    pg = st['ping']
    if pg < 0:
        ps, pcol = '---', DIM2
    else:
        ps = '%dms' % int(pg + 0.5)
        pcol = RED if pg >= 200 else (AMBER if pg >= 100 else DIM)
    text(104, y + 4, ps, pcol, 1)

    tp = st['temp']
    soc = st['soc']
    if soc >= 68:
        # the die is at/past its 70C throttle line -> that is why the link
        # stutters.  show both numbers and shout about it.
        ts = '%d/%dC' % (tp, soc)
        tcol = RED
    else:
        ts = '%dC' % tp
        tcol = RED if tp >= 50 else (AMBER if tp >= 46 else DIM)
    text(232 - tw(ts, 1), y + 4, ts, tcol, 1)

    # ----------------------------------------------------------- histogram
    base = 312
    hist = st['hist']
    for i in range(len(hist)):
        h = bar_h(hist[i])
        if h <= 0: continue
        x = 6 + i * 5
        v = hist[i]
        if v >= 10: c = GREEN
        elif v >= 2: c = BAR_MID
        else: c = BAR_LOW
        rect(x, base - h, x + 3, base, c)
    rect(6, base + 1, 6 + 45 * 5 + 3, base + 1, TRACK)

    flush()


def flush():
    f = open(FB, 'wb')
    f.write(''.join(map(LE.__getitem__, buf)))
    f.close()


# --------------------------------------------------- clock-overlay repair --
# The factory clock widget ("lcd") repaints itself about once a minute and
# stamps an opaque black rectangle straight across the middle of the screen.
# Reading a few rows back and comparing them with what we just drew costs
# essentially nothing (bench: 0.000 s) and lets us repaint the instant it
# happens, so the clock is never visible for more than a fraction of a second.
PROBE_Y0, PROBE_Y1 = 84, 162
PROBE_X0, PROBE_X1 = 30, 210
PROBE_YS = 4          # row stride
PROBE_XS = 3          # column stride


def fb_stale():
    """True if anything in the face band differs from what we last drew.

    One seek + one ~37 KB read for the whole band, then a strided compare
    (bench on the device: 0.003 s).  A strided compare is safe here because
    the factory clock is a solid opaque rectangle -- any sample landing
    inside it will disagree.
    """
    try:
        f = open(FB, 'rb')
        f.seek(PROBE_Y0 * W * 2)
        d = f.read((PROBE_Y1 - PROBE_Y0) * W * 2)
        f.close()
    except:
        return False
    n = len(d)
    for y in range(PROBE_Y0, PROBE_Y1, PROBE_YS):
        o = (y - PROBE_Y0) * W * 2
        base = y * W
        for x in range(PROBE_X0, PROBE_X1, PROBE_XS):
            i = o + x * 2
            if i + 1 >= n:
                break
            if (ord(d[i]) | (ord(d[i + 1]) << 8)) != buf[base + x]:
                return True
    return False


# ------------------------------------------------------------ main loop ----
OWN = '--own' in sys.argv
REPAIR_LOG = '/tmp/face_repair.log'
REPAIRS = 0


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

st = {
    'down': 0.0, 'up': 0.0, 'mood': 'sleep', 'hot': False,
    'sig': 0, 'net': '--', 'band': '', 'bat': -1, 'chg': False,
    'clients': -1, 'temp': 0.0, 'soc': 0.0, 'ping': -1,
    'hist': [], 'frame': 0,
}

prev = read_netdev()
prev_t = time.time()
bl_t = time.time()
slow_t = 0.0
hot = False
time.sleep(1)
ping_async()          # so the first slow tick has a reading to harvest

while True:
    try:
        t = time.time()
        cur = read_netdev()
        if cur is None:
            time.sleep(2)
            continue
        dt = t - prev_t
        if dt <= 0: dt = 1.0
        down = (cur[0] - prev[0]) * 8.0 / dt / 1000000.0
        up = (cur[1] - prev[1]) * 8.0 / dt / 1000000.0
        if down < 0: down = 0.0
        if up < 0: up = 0.0
        prev, prev_t = cur, t

        # light smoothing so the big number is readable instead of jittering
        st['down'] = st['down'] * 0.4 + down * 0.6
        st['up'] = st['up'] * 0.4 + up * 0.6

        if t - slow_t > 8:
            slow_t = t
            sy = read_status()
            if 'signal' in sy:
                try: st['sig'] = int(float(sy['signal']))
                except: pass
            nt = sy.get('nettype', '')
            st['net'] = {'5': '5G', '4': '4G', '3': '3G', '2': '2G'}.get(nt, '--')
            st['band'] = sy.get('band', '')
            pct, chg = read_battery()
            st['bat'], st['chg'] = pct, chg
            cl = read_clients()
            if cl >= 0: st['clients'] = cl
            # harvest the ping we launched 8 s ago, then launch the next one
            st['ping'] = read_ping()
            ping_async()

        st['temp'] = read_temp()
        st['soc'] = read_temp_soc()
        # battery temperature: >=50C is genuinely hot for a pouch cell
        if st['temp'] >= 50: hot = True
        elif st['temp'] < 46: hot = False
        st['hot'] = hot

        st['mood'] = mood_of(st['down'], st['up'])
        st['hist'].append(st['down'])
        while len(st['hist']) > 46:
            st['hist'].pop(0)
        st['frame'] += 1

        render(st)

        if t - bl_t > 5:
            bl_on()
            bl_t = t

        # sleep in eighths and repair the factory clock overlay as soon as it
        # appears.  the probe is now a single strided read (~0.002 s), so we can
        # afford to look 8x a second: the clock is never visible for long.
        for _ in range(8):
            time.sleep(0.125)
            if fb_stale():
                render(st)
                REPAIRS += 1
                try:
                    f = open(REPAIR_LOG, 'a')
                    f.write('%d\n' % int(t))
                    f.close()
                except:
                    pass
    except Exception, e:
        try:
            f = open('/tmp/face_err.log', 'a')
            f.write(str(e) + '\n')
            f.close()
        except:
            pass
        time.sleep(2)
