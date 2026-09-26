import re, collections
LOG = r"E:\FPGA\Ti60_2D_Graphics_Accelerator\outflow\ti60_top.log"
lines = open(LOG, encoding="utf-8", errors="replace").read().splitlines()

ours_keys = ("rtl\\v_dma", "rtl\\bitblt", "rtl\\ti60_top.v", "rtl\\hdmi", "rtl\\common\\i2c",
             "/v_dma/", "/bitblt/", "/ti60_top.v", "/hdmi/")

warn_by_file = collections.Counter()
our_warnings = []
for ln in lines:
    if "WARNING" not in ln.upper():
        continue
    m = re.search(r"([A-Za-z]:\\[^(]*?\.(?:v|vh|sv))\((\d+)\)", ln)
    f = m.group(1) if m else "<no-file>"
    warn_by_file[f] += 1
    if any(k in ln for k in ours_keys):
        our_warnings.append(ln.strip())

print("=== WARNING count by source file (top 12) ===")
for f, n in warn_by_file.most_common(12):
    print("   %5d  %s" % (n, f.replace(r"E:\FPGA\Ti60_2D_Graphics_Accelerator\\", "")))

print()
print("=== WARNINGS in OUR hand-written RTL (v_dma / bitblt / ti60_top / hdmi / i2c) ===")
if our_warnings:
    for w in our_warnings:
        print("   " + w.replace(r"E:\FPGA\Ti60_2D_Graphics_Accelerator\\", ""))
else:
    print("   (none)")

print()
print("=== ERROR lines ===")
for ln in lines:
    if "ERROR" in ln.upper():
        print("   " + ln.strip()[:300])
