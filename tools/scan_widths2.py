import re, os
ROOT = r"E:\FPGA\Ti60_2D_Graphics_Accelerator\rtl"
FILES = []
for dp, dn, fn in os.walk(ROOT):
    dn[:] = [d for d in dn if d not in {"ddr3_controller", "_v1_backup"}]
    for f in fn:
        if f.endswith((".v", ".vh")) and not any(k in dp for k in ("v_dma", "bitblt")):
            FILES.append(os.path.join(dp, f))
FILES.sort()
decl_re = re.compile(r"\b(localparam|parameter|input|output|inout|wire|reg|logic)\s+(?:signed\s+)?(\[[^\]]{1,40}\])\s+([A-Za-z_][A-Za-z0-9_]*)")
for path in FILES:
    if path.endswith("Axi_Mux.v"):
        print("--- %s  (vendor arbiter, skipped)" % path); continue
    print("--- %s" % os.path.relpath(path, r"E:\FPGA\Ti60_2D_Graphics_Accelerator"))
    for ln, line in enumerate(open(path, encoding="utf-8-sig", errors="replace"), 1):
        s = line.split("//")[0]
        for m in decl_re.finditer(s):
            print("   %5d  %-10s %-12s %s" % (ln, m.group(1), m.group(2), m.group(3)))
