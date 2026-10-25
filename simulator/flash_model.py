"""Read-only FAST_READ asset bank, matching the native simulator's SPI model."""
from collections import deque


class Flash:
    def __init__(self, assets):
        self.bank = b'ASR1\x00\x40\x00\x00' + bytes(assets)
        self.rx = deque()
        self.state = self.addr = self.naddr = 0

    def write(self, val):
        if val & (1 << 11):
            if val & 128:
                self.state = self.addr = self.naddr = 0
        elif val & 256:
            b = val & 255
            if self.state == 0:
                self.state = 1 if b == 11 else 4
            elif self.state == 1:
                self.addr = (self.addr << 8) | b
                self.naddr += 1
                if self.naddr == 3:
                    self.state = 2
            elif self.state == 2:
                self.state = 3
        elif val & 512:
            offset = self.addr - 0x1F0000
            self.rx.append(self.bank[offset] if self.state == 3 and 0 <= offset < len(self.bank) else 255)
            if self.state == 3:
                self.addr += 1
