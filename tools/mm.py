#!/usr/bin/env python
# -*- coding: utf-8 -*-
r"""Read the firmware's own DDR constants out of sw/driver/memory_map.h.

One parser, used by every tool that needs an address or a size, so a name that
moves in the map cannot leave a stale copy behind in a checker.  Expressions are
expanded through the other names in the same file and only then evaluated:
MM_BUCKET_USED_BYTES is written (2UL * MM_BUCKET_ROWS), and reading the first
number out of it gives 2 instead of 1536.

Run:  python tools/mm.py MM_LASER_BAR_H MM_BUCKET_USED_BYTES
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MMH = ROOT / "sw" / "driver" / "memory_map.h"

_DEFINE = re.compile(r"^#define\s+([A-Za-z_][A-Za-z_0-9]*)\s+(.*)$")
_NAME = re.compile(r"\b([A-Za-z_][A-Za-z_0-9]*)\b")
_ARITH = re.compile(r"[\d\s+*/()\-]+")


def _strip_comment(text):
    if "/*" in text:
        text = text.split("/*", 1)[0]
    if "//" in text:
        text = text.split("//", 1)[0]
    return text.strip()


def _bodies():
    out = []
    for line in MMH.read_text(encoding="utf-8").split("\n"):
        m = _DEFINE.match(line)
        if m:
            out.append((m.group(1), _strip_comment(m.group(2))))
    return dict(out)


def _eval(name, body, bodies, seen):
    if name in seen:
        raise SystemExit("memory_map.h: %s is a circular definition" % name)
    expanded = _NAME.sub(
        lambda mo: str(_eval(mo.group(1), bodies[mo.group(1)], bodies,
                             seen | {name})) if mo.group(1) in bodies
        else mo.group(1), body)
    expanded = re.sub(r"(?<=\d)[UL]+\b", "", expanded)
    hexlit = re.fullmatch(r"\s*(0[xX][0-9A-Fa-f]+)[uUlL]*\s*", expanded)
    if hexlit:
        return int(hexlit.group(1), 16)
    if not _ARITH.fullmatch(expanded):
        raise SystemExit("memory_map.h: %s = %r is not an address expression"
                         % (name, body))
    try:
        return int(eval(expanded))
    except Exception as exc:
        raise SystemExit("memory_map.h: cannot evaluate %s = %r (%s)"
                         % (name, body, exc))


def mm_eval(name):
    """Value of #define <name> in memory_map.h, expression or literal."""
    bodies = _bodies()
    if name not in bodies:
        raise SystemExit("sw/driver/memory_map.h has no %s" % name)
    return _eval(name, bodies[name], bodies, frozenset())


def mm_all(prefix="MM_"):
    """{name: value} for every define whose name starts with the prefix."""
    out = {}
    for name in _bodies():
        if name.startswith(prefix):
            out[name] = mm_eval(name)
    return out


if __name__ == "__main__":
    if len(sys.argv) > 1:
        for arg in sys.argv[1:]:
            print("%-30s %#010x  (%d)" % (arg, mm_eval(arg), mm_eval(arg)))
    else:
        for k, v in sorted(mm_all().items()):
            print("%-30s %#010x  (%d)" % (k, v, v))

