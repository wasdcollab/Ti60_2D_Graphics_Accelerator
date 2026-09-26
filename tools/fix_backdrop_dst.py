import sys
P = r"E:\FPGA\Ti60_2D_Graphics_Accelerator\tools\build_visual_assets.py"
data = open(P, "rb").read()
crlf = data.count(b"\r\n") > 0
NL = "\r\n" if crlf else "\n"
print("build_visual_assets.py: %s (%d bytes)" % ("CRLF" if crlf else "LF", len(data)))

def patch(data, old, new, tag):
    ob, nb = old.encode("utf-8"), new.encode("utf-8")
    n = data.count(ob)
    if n != 1:
        print("FAIL %-24s : %d matches" % (tag, n)); sys.exit(1)
    data = data.replace(ob, nb, 1)
    open(P, "wb").write(data)
    print("OK   %-24s : %d bytes" % (tag, len(data)))
    return data

# 1) import re
data = patch(data,
    "from pathlib import Path" + NL + "import json" + NL + "import hashlib",
    "from pathlib import Path" + NL + "import json" + NL + "import hashlib" + NL + "import re",
    "import re")

# 2) the helper that removes the second source of truth
data = patch(data,
    "KEY = 0x00FF00FF" + NL,
    "KEY = 0x00FF00FF" + NL + NL + NL +
    "def mm_const(name):" + NL +
    "    \"\"\"Read one #define out of sw/driver/memory_map.h." + NL +
    "" + NL +
    "    The backdrop destination used to be a literal in this file.  When the" + NL +
    "    framebuffer grew to 1366x768 the firmware moved MM_VISUAL_BACKGROUND to" + NL +
    "    0x03800000 (the new surface no longer fits in the old scratch slot) while" + NL +
    "    this generator kept decoding to the old 0x01640000: the backdrop was" + NL +
    "    written to one address and scanned from another, so the boot menu came up" + NL +
    "    over DDR residue.  Read the address from the header the firmware itself" + NL +
    "    uses, so the two cannot drift apart again." + NL +
    "    \"\"\"" + NL +
    "    text = (ROOT / 'sw/driver/memory_map.h').read_text(encoding='utf-8'," + NL +
    "                                                    errors='replace')" + NL +
    "    m = re.search(r'^#define\\s+%s\\s+(0x[0-9A-Fa-f]+)UL' % re.escape(name)," + NL +
    "                  text, re.M)" + NL +
    "    if not m:" + NL +
    "        raise SystemExit('memory_map.h: %s not found' % name)" + NL +
    "    return int(m.group(1), 16)" + NL,
    "mm_const() helper")

# 3) use it
data = patch(data,
    "    assets = [('background', bg, 0x01640000, 2)]",
    "    assets = [('background', bg, mm_const('MM_VISUAL_BACKGROUND'), 2)]",
    "backdrop destination")
