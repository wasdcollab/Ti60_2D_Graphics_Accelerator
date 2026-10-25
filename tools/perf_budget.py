# -*- coding: utf-8 -*-
"""压力测试：同屏 sprite 上限的三条约束推导 + 最坏帧分析。

三条约束分别来自：
  1. BitBlt 吞吐  —— 一帧里能发多少条 COPY/FILL，每条几个 128-bit beat
  2. DDR 带宽     —— VDMA 扫描读 + BitBlt 读写 + CPU 写，总和不能超过可用带宽
  3. CPU 指令预算 —— 100 MHz 一帧 1,333,333 步（75 Hz 逻辑帧）

数字分两类，每处都写清楚是哪一类：从 RTL 和固件源码读出来的（帧长、像素数、
逻辑帧步数），和必须是假设值的（DDR 可用带宽、每个 sprite 的 CPU 步数）。
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(r"E:\FPGA\Ti60_2D_Graphics_Accelerator")
sys.path.insert(0, str(ROOT / "simulator"))
import test_runner as T   # noqa: E402

FW = ROOT / "sw" / "build" / "firmware.bin"

def _from_source(path, pattern, what):
    m = re.search(pattern, Path(path).read_text(encoding="utf-8", errors="replace"),
                  re.M)
    if not m:
        raise SystemExit("%s: cannot find %s - the timing constants moved, and "
                         "this budget is meant to follow them" % (path, what))
    return float(m.group(1))


# Frame timing comes out of the RTL that generates it, not out of a literal.
# These four numbers were 59.94 Hz, 1,429,616 px and 1,668,000 steps - the
# 640x600/60 Hz screen - through the whole 1366x768 rebuild: the pixel budget
# was a quarter too generous and the CPU budget a fifth too generous, which is
# exactly the direction this file's conclusion is read in.
_RTL = ROOT / "rtl" / "v_dma" / "video_dma_read.v"
PIX_CLK = _from_source(_RTL, r"([0-9.]+)\s*MHz pixel clock", "the pixel clock")
H_TOTAL = int(_from_source(_RTL, r"parameter\s+H_TOTAL\s*=\s*(\d+)", "H_TOTAL"))
V_TOTAL = int(_from_source(_RTL, r"parameter\s+V_TOTAL\s*=\s*(\d+)", "V_TOTAL"))

# The logical frame the game simulates on, straight from the firmware.
_MAIN_C = ROOT / "sw" / "app" / "main.c"
CPU_CLK = _from_source(_MAIN_C, r"#define\s+LOGIC_STEP_CYCLES\s*\(\s*(\d+)u",
                       "LOGIC_STEP_CYCLES")

PIX_HZ = PIX_CLK * 1e6                     # 85.7118 MHz
FRAME_HZ = PIX_HZ / (H_TOTAL * V_TOTAL)    # 85.7118e6 / (1456 * 782)
LOGIC_HZ = 1e8 / CPU_CLK                   # 75 Hz
FRAME_US = 1e6 / FRAME_HZ                  # ~13,284 us
PIX_PER_FRAME = H_TOTAL * V_TOTAL          # pixels the scanout clocks out
CPU_STEPS_PER_FRAME = int(round(CPU_CLK))  # steps the game may spend in one

# The one number here that is a policy choice rather than a measurement: what
# the DDR3 side is assumed to deliver.  Everything the engine can reach is
# measured; this is not, and the budget is only as good as it.
DDR_MB_S = 800.0


def beats(w, h):
    """一次 COPY/FILL 的 128-bit beat 数（每行按 16 字节对齐向上取整）。"""
    return ((w * 4 + 15) // 16) * h


def measure_engine(vm, frames=30):
    f0, c0, s0 = vm.blit_fill_calls, vm.blit_copy_calls, vm.steps
    T.wait_frames(vm, frames)
    return dict(fills=(vm.blit_fill_calls - f0) / frames,
                copies=(vm.blit_copy_calls - c0) / frames,
                steps_per_frame=(vm.steps - s0) / frames)


def scenario():
    code = T.load_code_from_source(str(FW))
    T.build_boot_snapshot(code)
    vm = T.new_vm(code)
    T.menu_enter(vm, 1)
    vm.joy = (128 << 8) | 128
    T.wait_frames(vm, 10)
    idle = measure_engine(vm, 30)

    n = 0
    for i in range(T.EBULLET_COUNT):
        x = T.GAME_LEFT + 20 + (i * 37) % (T.GAME_RIGHT - T.GAME_LEFT - 40)
        y = 140 + (i * 53) % 400
        T.inject_ebullet(vm, x, y, vx=1 if i & 1 else -1, vy=2, color=i & 7)
        n += 1
    T.wait_frames(vm, 3)
    heavy = measure_engine(vm, 30)
    return idle, heavy, n


def main():
    print("=" * 74)
    print(" SPRITE STRESS: the three constraints on simultaneous sprites")
    print("=" * 74)

    full = beats(T.SCREEN_W, T.SCREEN_H)
    print("\n[1] BitBlt throughput")
    print("    full-screen COPY : %8d write beats (= %d B)"
          % (full, T.SCREEN_W * T.SCREEN_H * 4))
    for (w, h, label) in ((9, 9, "enemy bullet tile"),
                          (4, 10, "player shot trail"),
                          (24, 24, "minion / lance"),
                          (48, 48, "player craft"),
                          (112, 112, "impact burst frame")):
        b = beats(w, h)
        print("    COPY %-22s: %6d beats  (%.4f%% of full screen)"
              % ("%dx%d %s" % (w, h, label), b, 100.0 * b / full))

    idle, heavy, n = scenario()
    print("\n[2] measured engine activity")
    print("    idle  frame: %6.1f FILLs %6.1f COPYs %10.0f CPU steps"
          % (idle["fills"], idle["copies"], idle["steps_per_frame"]))
    print("    heavy frame: %6.1f FILLs %6.1f COPYs %10.0f CPU steps"
          % (heavy["fills"], heavy["copies"], heavy["steps_per_frame"]))
    print("    (%d sprites injected)" % n)

    engine_beats_avail = PIX_PER_FRAME * 0.5
    per_sprite_beats = beats(9, 9) + beats(4, 10)
    limit_blit = engine_beats_avail / per_sprite_beats

    vdma_mb = T.SCREEN_H * (T.SCREEN_W * 4) * FRAME_HZ / 1e6
    free_mb = DDR_MB_S - vdma_mb
    per_sprite_mb = per_sprite_beats * 2 * 16 * FRAME_HZ / 1e6
    limit_ddr = free_mb / per_sprite_mb

    # ASSUMED, not measured: an earlier version of this comment claimed every
    # per-sprite cost here came from the simulator.  Nothing in this file ever
    # timed one.  What the file does measure is the whole frame (above).
    steps_per_sprite = 45
    limit_cpu = (CPU_STEPS_PER_FRAME - heavy["steps_per_frame"]) / steps_per_sprite

    print("\n[3] the three limits")
    print("    %-30s %14s %14s" % ("constraint", "budget", "sprite cap"))
    print("    " + "-" * 60)
    print("    %-30s %14.0f %14.0f" % ("BitBlt (beats/frame)",
                                       engine_beats_avail, limit_blit))
    print("    %-30s %14.1f %14.0f" % ("DDR (MB/s free)", free_mb, limit_ddr))
    print("    %-30s %14d %14.0f" % ("CPU (steps/frame)",
                                     CPU_STEPS_PER_FRAME, limit_cpu))
    print("    " + "-" * 60)
    best = min(limit_blit, limit_ddr, limit_cpu)
    which = ["BitBlt", "DDR", "CPU"][[limit_blit, limit_ddr, limit_cpu].index(best)]
    print("    %-30s %14s %14.0f  <-- binding" % ("MINIMUM", which, best))

    out = dict(full_screen_beats=full, engine_beats_avail=engine_beats_avail,
               idle=idle, heavy=heavy, limit_blit=limit_blit,
               limit_ddr=limit_ddr, limit_cpu=limit_cpu, binding=which,
               sprite_cap=best, vdma_mb_s=vdma_mb, injected=n)
    dest = ROOT / "simulator" / "output" / "perf_budget.json"
    dest.write_text(json.dumps(out, indent=2), encoding="utf-8")
    print("\n    written %s" % dest)


if __name__ == "__main__":
    main()
