"""Decode Q/B/T UART fields from the 2026-10-25 bus diagnostic image."""
import argparse
import json
from pathlib import Path
import re

STATES = "IDLE INIT POOL READ_AR READ_R LOAD LOAD_WAIT DISPATCH MOVE CHECK CANDIDATE EVAL WRITE_GROUPS REC_WR NEXT CLEAR_SETUP CLEAR_LOAD CLEAR_WAIT CLEAR_WRITE WRITE_USED DRAIN DONE PACK_WAIT PACK0 PACK1 PACK2 PACK_SEND".split()
CAUSES = {0: "none captured", 1: "watchdog", 2: "RRESP error", 3: "RLAST mismatch", 4: "BRESP error"}
OWNERS = ["video", "CPU", "BitBlt", "bucket"]


def decode(line):
    fields = {k: int(v) for k, v in re.findall(r"(?:^|\s)([A-Za-z])(\d+)(?=\s|$)", line)}
    if not all(k in fields for k in "QBT"):
        raise ValueError("Q/B/T fields required; use the busdiag image")
    q, b, ticks = (fields[k] for k in "QBT")
    state = (q >> 24) & 31
    flags = dict(zip(("arvalid", "arready", "rvalid", "rready", "awvalid", "awready", "wvalid", "wready", "bvalid", "bready"),
                     (bool(q & (1 << i)) for i in range(19, 9, -1))))
    return dict(frame=fields.get("F"), status=hex(b), currently_busy=bool(b >> 31),
                currently_fault=bool(b & (1 << 28)), drops=b & 65535,
                task_cycles=ticks, task_ms=ticks / 100000,
                snapshot=hex(q), first_cause=CAUSES.get(q >> 29, "unknown"),
                first_state=STATES[state] if state < len(STATES) else state,
                pending_writes=(q >> 20) & 15, bucket_handshake=flags,
                bus_context=dict(read_owner=OWNERS[(q >> 8) & 3],
                    bitblt_reads=(q >> 5) & 7, bitblt_rready=bool(q & 16),
                    ddr_rready=bool(q & 8), guard_pending=bool(q & 4),
                    video_priority=bool(q & 2), ddr_rvalid=bool(q & 1)))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--line")
    p.add_argument("--file", type=Path)
    args = p.parse_args()
    if bool(args.line) == bool(args.file):
        p.error("provide exactly one of --line / --file")
    lines = [args.line] if args.line else args.file.read_text(encoding="utf-8").splitlines()
    found = False
    for line in lines:
        try:
            result = decode(line)
        except ValueError:
            if args.line:
                raise
            continue
        found = True
        print(json.dumps(result, indent=2))
    if not found:
        p.error("no Q/B/T records found")


if __name__ == "__main__":
    main()
