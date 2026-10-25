"""Load unsigned 8-bit / 12 kHz mono PCM via bounded, CRC-checked UART packets."""
import argparse
import json
from pathlib import Path
import struct
import time
import zlib

BEGIN, FINISH, QUERY = 0xFFFFFFFF, 0xFFFFFFFE, 0xFFFFFFFD
CAPACITY = 8 * 1024 * 1024


def packet(offset, data=b""):
    body = b"BGM2" + struct.pack("<I", offset) + data.ljust(64, b"\0")
    if len(body) != 72:
        raise ValueError("payload exceeds 64 bytes")
    return body + struct.pack("<I", zlib.crc32(body))


def decode_reply(raw):
    if len(raw) != 32 or raw[:4] != b"BGA2":
        return None
    fields = struct.unpack("<8I", raw)
    if zlib.crc32(raw[:28]) != fields[7]:
        return None
    return dict(offset=fields[1], loaded_bytes=fields[2],
                size=fields[3] & 0x7FFFFFFF, ready=bool(fields[3] >> 31),
                level=fields[4] & 0xFFF, playing=bool(fields[4] & (1 << 16)),
                overflow=bool(fields[4] & (1 << 17)), error=fields[4] >> 28,
                underflows=fields[5], played_samples=fields[6])


class Link:
    def __init__(self, serial_port):
        self.port = serial_port
        self.buffer = bytearray()

    def exchange(self, offset, data=b"", retries=4):
        for attempt in range(retries):
            self.port.write(packet(offset, data))
            deadline = time.monotonic() + 1.5
            while time.monotonic() < deadline:
                self.buffer.extend(self.port.read(max(1, self.port.in_waiting)))
                while len(self.buffer) >= 32:
                    start = self.buffer.find(b"BGA2")
                    if start < 0:
                        del self.buffer[:-3]
                        break
                    if start:
                        del self.buffer[:start]
                    if len(self.buffer) < 32:
                        break
                    reply = decode_reply(self.buffer[:32])
                    if reply is None:
                        del self.buffer[0]
                        continue
                    del self.buffer[:32]
                    if reply["offset"] != offset:
                        continue
                    if reply["error"]:
                        raise RuntimeError(f"board rejected packet: {reply}")
                    return reply
            print(f"retry {attempt + 1}: offset={offset:#x}", flush=True)
        raise TimeoutError(f"no valid board reply for {offset:#x}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True)
    parser.add_argument("--input", type=Path)
    parser.add_argument("--start-seconds", type=float, default=0)
    parser.add_argument("--seconds", type=float)
    parser.add_argument("--status", action="store_true")
    parser.add_argument("--resume", action="store_true", help="resume a matching size/CRC upload on the running board")
    parser.add_argument("--observe", type=float, default=5)
    parser.add_argument("--log", type=Path)
    args = parser.parse_args()
    if not args.status and args.input is None:
        parser.error("provide --input or --status")
    if args.start_seconds < 0 or (args.seconds is not None and args.seconds <= 0):
        parser.error("invalid clip interval")
    import serial
    observations = []
    with serial.Serial(args.port, 115200, timeout=0.05, write_timeout=2) as port:
        link = Link(port)
        if not args.status:
            with args.input.open("rb") as stream:
                stream.seek(round(args.start_seconds * 12000))
                pcm = stream.read(CAPACITY + 1 if args.seconds is None else round(args.seconds * 12000))
            if not pcm or len(pcm) > CAPACITY:
                parser.error("clip must contain 1..8388608 bytes")
            pcm += b"\x80" * (-len(pcm) % 64)
            info = struct.pack("<II", len(pcm), zlib.crc32(pcm))
            state = link.exchange(QUERY if args.resume else BEGIN, info)
            first = state["loaded_bytes"] if args.resume else 0
            if first > len(pcm) or first % 64:
                raise RuntimeError(f"invalid resume position: {state}")
            started = time.monotonic()
            for offset in range(first, len(pcm), 64):
                reply = link.exchange(offset, pcm[offset:offset + 64])
                if reply["loaded_bytes"] != offset + 64:
                    raise RuntimeError(f"unexpected acknowledged offset: {reply}")
                if offset % 12032 == 0:
                    print(f"loaded {offset + 64}/{len(pcm)} bytes", flush=True)
            print(json.dumps(link.exchange(FINISH)), flush=True)
            print(f"upload completed in {time.monotonic() - started:.1f}s", flush=True)
        end = time.monotonic() + args.observe
        while True:
            reply = link.exchange(QUERY)
            observations.append(reply)
            print(json.dumps(reply), flush=True)
            if time.monotonic() >= end:
                break
            time.sleep(1)
    if args.log:
        args.log.parent.mkdir(parents=True, exist_ok=True)
        args.log.write_text(json.dumps(observations, indent=2) + "\n", encoding="ascii")


if __name__ == "__main__":
    main()
