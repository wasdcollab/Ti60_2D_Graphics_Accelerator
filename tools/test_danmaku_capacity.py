"""20000-bullet stress cap: APB count packing and per-group slot headroom.

The coprocessor testbench owns the cycle measurement. This checks the two
things a Python process can decide without a firmware image: the 15-bit
count survives the APB 0x120 packing, and the stress-stage birth pattern
keeps a 20000-bullet field under the 1024-entry scanline-group cap.
"""
DIR_X = [16, 15, 11, 6, 0, -6, -11, -15, -16, -15, -11, -6, 0, 6, 11, 15]
DIR_Y = [0, 6, 11, 15, 16, 15, 11, 6, 0, -6, -11, -15, -16, -15, -11, -6]
SCHED = [0, 128, 64, 198, 1, 129, 65, 199, 2, 130, 66, 200,
         3, 131, 67, 201, 4, 132, 68, 202, 5, 133, 69, 203]
SPD = 3
BUDGET = 224
X0, X1, Y0, Y1 = 182, 1169, 1, 767


def pack_eb(count):
    return ((count & 0x1FFF) << 16) | ((count & 0x6000) << 1)


def unpack_eb(word):
    return ((word >> 16) & 0x1FFF) | ((word & 0xC000) >> 1)


def groups_of(y):
    lo, hi = max(y - 6, 0), min(y + 7, 768)
    if lo >= hi:
        return range(0)
    return range(lo // 8, (hi - 1) // 8 + 1)


def occupancy(frames=500, target=20000, player_y=640, boss_y=120):
    bullets = []
    step = 0
    peak = 0
    px, cx = 683, 683
    for _ in range(frames):
        bullets = [(x + vx, y + vy, vx, vy)
                   for x, y, vx, vy in bullets
                   if X0 <= x + vx <= X1 and Y0 <= y + vy <= Y1]
        room = target + (64 if target >= 4000 else 0) - len(bullets)
        if room < 0:
            room = 0
        if room > BUDGET:
            room = BUDGET
        dx, dy = px - cx, player_y - boss_y
        ax, ay = abs(dx), abs(dy)
        if dy == 0:
            aim = 8 if dx < 0 else (0 if dx else 4)
        else:
            q = 0 if 5 * ay <= ax else 1 if 3 * ay <= 2 * ax else 2 if 2 * ay <= 3 * ax else 3 if ay <= 5 * ax else 4
            if dx < 0:
                q = 8 - q
            aim = (-q if dy < 0 else q) & 15
        for i in range(room):
            st = step + i
            kind = SCHED[st % 24] >> 6
            sub = SCHED[st % 24] & 0x3F
            y = ((st * 5) % 96) * 8 + 4
            if kind == 0:
                a = (st * 2) & 15
                x = 189 + (st * 17) % 960
            elif kind == 1:
                a = (aim + ((st & 12) >> 2) - 1 + (8 if sub & 1 else 0)) & 15
                x = 189 + (st * 17 + 400) % 960
            else:
                a = None
                x = 182 if kind == 2 else 1169
            if a is None:
                vx, vy = (SPD, 0) if kind == 2 else (-SPD, 0)
                vy = 1 if (st & 1) == 0 else -1
                if not (Y0 <= y + vy <= Y1):
                    vy = -vy
            else:
                vx, vy = (DIR_X[a] * SPD) >> 4, (DIR_Y[a] * SPD) >> 4
            # spawn_ebullet's playfield clamp.
            x = min(max(x, 182), 1169)
            y = min(max(y, 1), 766)
            bullets.append((x, y, vx, vy))
        step = (step + room) & 0xFFFF
        counts = [0] * 96
        for _x, y, _vx, _vy in bullets:
            for g in groups_of(y):
                counts[g] += 1
        peak = max(peak, max(counts))
    return len(bullets), peak


def main():
    for n in (0, 1, 8191, 8192, 10240, 16383, 16384, 20000, 20480, 32767):
        word = pack_eb(n)
        assert unpack_eb(word) == n, (n, hex(word), unpack_eb(word))
        assert (word & 0x20000000) == 0
        assert unpack_eb(word | 0x20000000) == n
    pop, peak = occupancy()
    assert pop >= 20000, pop
    assert peak <= 900, peak
    print("PASS danmaku capacity: count round-trips through 32767; "
          "20000-bullet storm peak group %d <= 900, population %d" % (peak, pop))


if __name__ == "__main__":
    main()
