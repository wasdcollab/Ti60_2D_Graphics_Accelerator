"""
tests/demo_boxes.py
====================
Frozen copy of the 30 initial box records (x, y, vx, vy, w, h, colour) that the
legacy hand-written firmware used for the autonomous-right-renderer reference.

They used to be imported straight out of sw/legacy/generate_firmware.py, which
tied the RTL regression to the retired Python assembler.  The values below were
dumped from that module and are verified to match it bit for bit, so the test side
no longer depends on the legacy firmware generator at all.
"""

BOX_TABLE_30 = [
    (70, 372, 2, -3, 20, 20, 0xFF0000),
    (267, 150, -2, 3, 23, 23, 0x00FF00),
    (462, 159, 3, -1, 26, 26, 0xFFFF00),
    (468, 352, -3, 2, 29, 29, 0x00FFFF),
    (328, 329, 1, -4, 32, 32, 0xFF00FF),
    (225, 547, -1, 3, 20, 20, 0xFFA500),
    (394, 496, 4, -2, 23, 23, 0xFFFFFF),
    (132, 46, -4, 2, 26, 26, 0x00FF7F),
    (324, 86, 2, -3, 29, 29, 0xFF1493),
    (66, 192, -2, 3, 32, 32, 0x7FFF00),
    (428, 145, 3, -1, 20, 20, 0xFF4500),
    (240, 56, -3, 2, 23, 23, 0x00CED1),
    (427, 501, 1, -4, 26, 26, 0xFFD700),
    (360, 296, -1, 3, 29, 29, 0xADFF2F),
    (357, 205, 4, -2, 32, 32, 0xFF69B4),
    (117, 451, -4, 2, 20, 20, 0xE0FFFF),
    (138, 401, 2, -3, 23, 23, 0x9370DB),
    (192, 457, -2, 3, 26, 26, 0x32CD32),
    (272, 371, 3, -1, 29, 29, 0xFF6347),
    (49, 415, -3, 2, 32, 32, 0x40E0D0),
    (184, 136, 1, -4, 20, 20, 0xEE82EE),
    (295, 344, -1, 3, 23, 23, 0xF0E68C),
    (157, 279, 4, -2, 26, 26, 0x87CEEB),
    (82, 493, -4, 2, 29, 29, 0xFFB6C1),
    (340, 405, 2, -3, 32, 32, 0x98FB98),
    (376, 361, -2, 3, 20, 20, 0xDDA0DD),
    (22, 422, 3, -1, 23, 23, 0xFFA07A),
    (196, 281, -3, 2, 26, 26, 0x20B2AA),
    (226, 91, 1, -4, 29, 29, 0x87CEFA),
    (214, 501, -1, 3, 32, 32, 0xFF8C00),
]

if __name__ == "__main__":
    print(len(BOX_TABLE_30), "records")
