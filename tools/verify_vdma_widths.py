# Static re-check of every VDMA width against the 1366x768 numbers, using
# Verilog's own truncation rule: a sized literal keeps only its low `w` bits.
H_ACT, V_ACT = 1366, 768
PITCH = 8192

def trunc(v, w):
    return v & ((1 << w) - 1)

print("== invariant 1: BURSTS_PER_ROW = ceil(H_ACT/64) ==")
bpr = (H_ACT + 63) // 64
print("   (1366+63)/64 = %d   fits in 5 bits (max 31): %s" % (bpr, bpr <= 31))

print("== invariant 2: TOTAL_BURSTS == V_ACT * BURSTS_PER_ROW ==")
tb = V_ACT * bpr
print("   %d * %d = %d   declared 15'd16896  %s   fits in 15 bits (max 32767): %s"
      % (V_ACT, bpr, tb, "MATCH" if tb == 16896 else "MISMATCH", tb <= 32767))

print("== invariant 3: col_off / next_col must fit 13 bits ==")
last_col = (bpr - 1) * 256
print("   max col_off = %d, next_col max = %d (13 bits max 8191): %s"
      % (last_col, last_col + 256, last_col + 256 <= 8191))

print("== ROW_STRIDE literal ==")
print("   13'd8192 -> %d   <-- the bug: row_addr never advances" % trunc(8192, 13))
print("   13'd8192 -> %d   <-- the fix" % trunc(8192, 14))

print()
print("== one whole frame, row_addr per line ==")
for label, bits, lit in (("BEFORE (13 bits)", 13, 8192), ("AFTER  (14 bits)", 14, 8192)):
    stride = trunc(lit, bits)
    row_addr = 0
    seen = []
    for row in range(V_ACT):
        seen.append(row_addr)
        row_addr = trunc(row_addr + stride, 28)      # 28-bit row_addr register
    uniq = len(set(seen))
    print("   %-16s ROW_STRIDE=%-5d  distinct row_addr over 768 lines = %-4d  line0=%-8d line767=%d"
          % (label, stride, uniq, seen[0], seen[767]))

print()
print("== 28-bit AXI address ceiling (AXI_ADDR_WIDTH=28, max 0x0FFFFFFF) ==")
for name, base in (("FB0", 0x00800000), ("FB1", 0x00E00000)):
    for tag, stride in (("old", 0), ("new", 8192)):
        top = base + 767 * stride + (bpr - 1) * 256 + 256   # last byte read of the frame
        print("   %s %-4s  last byte read = 0x%08X  %s"
              % (name, tag, top, "OK" if top <= 0x0FFFFFFF else "OVERFLOW"))
print("   NOTE: the tail burst reads 168 B of row padding past the scan line, which")
print("         stays well inside the 0x600000-byte-per-buffer allocation.")

print()
print("== the whole-screen symptom, stated as arithmetic ==")
print("   BEFORE: every one of the 768 lines reads base+0..base+5631 -> the same")
print("           5632 B repeated down the screen = the screen-wide garbage stripes.")
print("   AFTER : line n reads base + n*8192 + (0..5631) -> 768 distinct rows.")
