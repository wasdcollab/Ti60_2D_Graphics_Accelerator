#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""B2: the HUD's dynamic elements, the backdrop's baked labels, and the gutters.

Three layouts, one screen:

  * the labels baked into the 683x384 backdrop (tools/build_visual_assets.py,
    exported to assets/processed/hud_labels.json), blitted at 2x, so a label's
    screen box is its source box doubled;
  * the HUD's dynamic elements, which live in one table in sw/app/main.c -
    HUD_BOXES - and whose drawing code reads its coordinates from it;
  * the playfield band itself, GAME_LEFT..GAME_RIGHT, which under the
    1366x768-native layout carries NO HUD at all.

Checks, in order:

  1. no two HUD elements overlap;
  2. no HUD element overlaps a baked label;
  3. no HUD element intrudes into the playfield band;
  4. every HUD element is fully on screen.

It runs on every `build_firmware.py`, so moving anything is caught at the
point of the change rather than on the board.

1.5 was one of these collisions (the score's new digits over its old ones, and
the FPS token over the backdrop's RENDER BACKEND), and so were two earlier
rounds of "the spell bar is drawn over the backdrop's FOCUS label".  None of
them were caught by a machine.  Check 3 is new with the 1366x768 rebuild: the
whole point of that rebuild is that the playfield is clean, so a HUD element
drifting into it has to be a build failure and not a screenshot.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAIN = ROOT / "sw" / "app" / "main.c"
LABELS = ROOT / "assets" / "processed" / "hud_labels.json"


def hud_boxes():
    """The HUD_BOXES table, as {name: (x, y, w, h)}."""
    txt = MAIN.read_text(encoding="utf-8")
    m = re.search(r"#define HUD_BOXES\(X\)(.*?)\n\n", txt, re.S)
    if not m:
        raise SystemExit("could not find HUD_BOXES in %s" % MAIN)
    boxes = {}
    for name, x, y, w, h in re.findall(
            r"X\(\s*([A-Z][A-Z_0-9]*)\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*,"
            r"\s*(-?\d+)\s*,\s*(-?\d+)\s*\)", m.group(1)):
        boxes[name] = (int(x), int(y), int(w), int(h))
    if len(boxes) < 10:
        raise SystemExit("HUD_BOXES parsed as only %d entries - has the format "
                         "changed?" % len(boxes))
    return boxes


def label_boxes():
    if not LABELS.exists():
        raise SystemExit("%s is missing - run tools/build_visual_assets.py first"
                         % LABELS)
    out = []
    for label, x0, y0, x1, y1 in json.loads(LABELS.read_text(encoding="utf-8")):
        out.append((label, int(x0), int(y0), int(x1), int(y1)))
    return out


def hits(a, b):
    return (a[0] < b[0] + b[2] and b[0] < a[0] + a[2] and
            a[1] < b[1] + b[3] and b[1] < a[1] + a[3])


def _defines(path, names):
    txt = path.read_text(encoding="utf-8", errors="replace")
    out = {}
    for name in names:
        m = re.search(r"^#define\s+%s\s+(\d+)\s*$" % name, txt, re.M)
        if not m:
            raise SystemExit("could not find #define %s in %s" % (name, path))
        out[name] = int(m.group(1))
    return out


def screen_geometry():
    """Screen size and the playfield band, read from the real definitions.

    SCREEN_WIDTH/HEIGHT live in sw/driver/gpu2d.h next to SCREEN_STRIDE;
    GAME_LEFT/GAME_RIGHT are plain integers in main.c.  Reading both keeps this
    checker honest when the layout moves - which is exactly what happened in
    the 1366x768-native rebuild.
    """
    geo = _defines(ROOT / "sw" / "driver" / "gpu2d.h",
                   ("SCREEN_WIDTH", "SCREEN_HEIGHT"))
    geo.update(_defines(MAIN, ("GAME_LEFT", "GAME_RIGHT")))
    return geo


def main():
    boxes = hud_boxes()
    labels = label_boxes()
    geo = screen_geometry()
    sw, sh = geo["SCREEN_WIDTH"], geo["SCREEN_HEIGHT"]
    gl, gr = geo["GAME_LEFT"], geo["GAME_RIGHT"]
    bad = []

    names = sorted(boxes)
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            if hits(boxes[a], boxes[b]):
                bad.append("HUD %s %s overlaps HUD %s %s"
                           % (a, boxes[a], b, boxes[b]))

    for a in names:
        for label, x0, y0, x1, y1 in labels:
            if hits(boxes[a], (x0, y0, x1 - x0, y1 - y0)):
                bad.append("HUD %s %s overlaps the baked label %r at (%d,%d)-(%d,%d)"
                           % (a, boxes[a], label, x0, y0, x1, y1))

    for a in names:
        x, y, w, h = boxes[a]
        if hits((x, y, w, h), (gl, 0, gr - gl, sh)):
            bad.append("HUD %s %s intrudes into the playfield band x=%d..%d"
                       % (a, boxes[a], gl, gr))
        if x < 0 or y < 0 or x + w > sw or y + h > sh:
            bad.append("HUD %s %s is not fully on screen (%dx%d)"
                       % (a, boxes[a], sw, sh))

    print("  HUD layout: %d elements, %d baked label(s) to check against, "
          "playfield band x=%d..%d on a %dx%d screen"
          % (len(names), len(labels), gl, gr, sw, sh))
    if not labels:
        # This is the expected state, not a broken input: the backdrop has been
        # painted by the firmware since 1366x768, and its labels are drawn with
        # the same vector font as the numbers beside them, so nothing is baked
        # into a plate any more (see HUD_LABELS.clear() in
        # tools/build_visual_assets.py).  Saying so matters because the check
        # below otherwise reports a pass over an empty list, which is how this
        # line read for as long as the table has been empty.
        print("    (no baked labels: the plates are painted by the firmware and"
              " its labels are drawn at run time, so there is nothing baked to"
              " collide with)")
    if bad:
        print("  *** %d layout collision(s):" % len(bad))
        for line in bad:
            print("      " + line)
        return 1
    print("  HUD layout: no overlap, nothing in the playfield, nothing off screen")
    return 0


if __name__ == "__main__":
    sys.exit(main())
