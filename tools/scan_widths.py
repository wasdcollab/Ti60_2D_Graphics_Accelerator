import re, os, sys

ROOT = r"E:\FPGA\Ti60_2D_Graphics_Accelerator\rtl"
SKIP = {"ddr3_controller", "_v1_backup"}
FILES = []
for dp, dn, fn in os.walk(ROOT):
    dn[:] = [d for d in dn if d not in SKIP]
    for f in fn:
        if f.endswith((".v", ".vh")):
            FILES.append(os.path.join(dp, f))
FILES.sort()

def rel(p):
    return os.path.relpath(p, r"E:\FPGA\Ti60_2D_Graphics_Accelerator")

lit_re = re.compile(r"(\d+)'([bodhBODH])([0-9a-fA-F_xzXZ]+)")

print("=" * 78)
print("A. SIZED-LITERAL OVERFLOW (value does not fit declared width)")
print("=" * 78)
nfound = 0
for path in FILES:
    for ln, line in enumerate(open(path, encoding="utf-8-sig", errors="replace"), 1):
        for m in lit_re.finditer(line):
            w = int(m.group(1)); base = m.group(2).lower(); digits = m.group(3)
            if any(c in digits.lower() for c in "xz_"):
                continue
            try:
                v = int(digits, {"d":10,"h":16,"b":2,"o":8}[base])
            except ValueError:
                continue
            if w > 0 and v >= (1 << w):
                nfound += 1
                print("OVERFLOW %s:%d  %s   width=%d  max=%d  value=%d  -> TRUNCATES TO %d"
                      % (rel(path), ln, m.group(0), w, (1 << w) - 1, v, v % (1 << w)))
                print("         %s" % line.strip())
if nfound == 0:
    print("  (none)")

print()
print("=" * 78)
print("B. WIDTH DECLARATIONS in rtl/v_dma + rtl/bitblt + rtl/ti60_top.v")
print("=" * 78)
decl_re = re.compile(r"\b(localparam|parameter|input|output|inout|wire|reg|logic)\s+(?:signed\s+)?(\[[^\]]{1,40}\])\s+([A-Za-z_][A-Za-z0-9_]*)")
targets = [p for p in FILES if ("v_dma" in p or "bitblt" in p or p.endswith("ti60_top.v"))]
for path in targets:
    print("--- %s" % rel(path))
    for ln, line in enumerate(open(path, encoding="utf-8-sig", errors="replace"), 1):
        s = line.split("//")[0]
        for m in decl_re.finditer(s):
            print("   %5d  %-10s %-12s %s" % (ln, m.group(1), m.group(2), m.group(3)))
