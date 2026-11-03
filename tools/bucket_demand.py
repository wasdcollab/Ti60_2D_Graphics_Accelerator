"""Independent bucket demand from live pools and boot-built tile pixels."""
from collections import Counter
import struct


def aim_index(dx, dy):
    ax, ay = abs(dx), abs(dy)
    if ax == ay == 0:
        return 4
    q = (0 if 5 * ay <= ax else 1 if 3 * ay <= 2 * ax else
         2 if 2 * ay <= 3 * ax else 3 if ay <= 5 * ax else 4)
    if dx >= 0:
        return q if dy >= 0 else (16 - q) & 15
    return 8 - q if dy >= 0 else 8 + q


def snapshot(vm, sym, T):
    """Call after natural frame publication, before any state-mutating probes.

    Hues are labels, NOT proven origins: normal boss patterns reuse them.
    Assert exact agreement with the firmware's current ledger and DROP count.
    """
    occupied = []
    for slot in range(37):
        if slot < 16:
            base = T.mm_value("MM_EBULLET_DIRTILE") + slot * 832
            pitch, width, height = 32, 26, 26
        elif slot < 19:
            key, pitch, width, height = (("MM_PBULLET_TILE", 8, 7, 26),
                                        ("MM_ORB_TILE", 16, 16, 16),
                                        ("MM_MISSILE_TILE", 16, 13, 26))[slot - 16]
            base = T.mm_value(key)
        else:
            base = 14368 + (slot - 19) * 832
            pitch, width, height = 32, 26 if slot >= 29 else 16 if slot >= 27 else 24, 26
        if slot >= 19:
            live = [y for y in range(height) if any(vm.btile[base+y*pitch:base+y*pitch+width])]
        else:
            off = base - T.SCRATCH_BASE
            live = [y for y in range(height)
                    if any(vm.scratch[off + y * pitch:off + y * pitch + width])]
        bounds = min(live), max(live) + 1
        if 19 <= slot < 27:
            assert 0 <= bounds[0] < bounds[1] <= 24
            bounds = (0, 24)
        if slot >= 29: bounds = (0, 26)  # conservative spark/tail bounds
        packed = vm.load(sym["bt_tile_rows"] + slot * 2, 2)
        # The hardware row interval may conservatively include transparent
        # padding (lances and glow tails do this deliberately). Demand must
        # use that declared interval, while ensuring it clips no live texels.
        declared = (packed & 31, packed >> 5)
        assert declared[0] <= bounds[0] < bounds[1] <= declared[1], (slot, bounds, packed)
        occupied.append(declared)

    rows, group = T.mm_value("MM_BUCKET_ROWS"), T.mm_value("MM_BUCKET_GROUP_ROWS")
    slots = T.mm_value("MM_BUCKET_SLOTS")
    demand = [0] * rows
    by_hue = [Counter() for _ in range(rows)]
    by_slot = [Counter() for _ in range(rows)]
    px = vm.load(sym["player_x"], 2, signed=True)
    py = vm.load(sym["player_y"], 2, signed=True)
    for enemy, base, count in ((False, T.PBULLET_BASE, T.PBULLET_COUNT),
                               (True, T.EBULLET_BASE, T.EBULLET_COUNT)):
        for i in range(count):
            x, y, vx, vy, flags, color = struct.unpack_from(
                "<hhbbBB", vm.scratch, base - T.SCRATCH_BASE + i * 8)
            if not flags & 1:
                continue
            if not enemy:
                slot, top = (18 if flags & 2 else 16), y
            elif flags & 128:
                slot, top = (28 if color & 128 else 27), y - 8
            elif flags & 8:
                slot, top = 19 + (aim_index(vx, vy) >> 1), y - 12
            elif flags & 32:
                slot, top = 29 + (aim_index(vx, vy) >> 1), y - 13
            elif flags & 64:
                slot, top = 17, y - 8
            elif color & 192 == 64:
                slot, top = 29 + ((aim_index(px-x, py-y) if flags & 4 or vx == vy == 0 else aim_index(vx, vy)) >> 1), y - 13
            else:
                slot = (aim_index(px - x, py - y) if flags & 4 or vx == vy == 0 else
                        (color >> 3) & 15 if color & 128 else aim_index(vx, vy))
                top = y - 13
            first, end = occupied[slot]
            start, stop = max(0, top + first), min(T.SCREEN_H, top + end)
            if start >= stop:
                continue
            label = "enemy_hue_%d" % (color & 7) if enemy else "player"
            for g in range(start // group, (stop - 1) // group + 1):
                demand[g] += 1
                by_hue[g][label] += 1
                by_slot[g][slot] += 1

    dropped = sum(max(0, d - slots) for d in demand)
    actual = vm.load(sym["bt_dropped"], 4)
    assert dropped == actual, ("demand DROP differs from firmware", dropped, actual)
    buf = vm.load(sym["bt_buf"], 4)
    used = T.mm_value("MM_BUCKET_USED") + buf * rows * 2
    ledger = [vm.load(used + g * 2, 2) for g in range(rows)]
    assert ledger == [min(d, slots) for d in demand], "demand differs from bucket ledger"
    return dict(demand=demand, by_hue=by_hue, by_slot=by_slot, buffer=buf,
                ledger=ledger, slots=slots, predicted_drops=dropped,
                peak=max(demand), entries=sum(demand),
                note="Natural published frame; hues do not uniquely identify spawn sources.")
