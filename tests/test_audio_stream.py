"""Exercise the actual firmware C parser against zlib and mocked MMIO."""
import ctypes
from pathlib import Path
import struct
import sys
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from upload_bgm import BEGIN, FINISH, QUERY, packet, decode_reply


class AudioStreamTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib = ctypes.CDLL(str(ROOT / "work_sim/audio_stream_host.dll"))

    def setUp(self):
        self.lib.test_reset()
        self.data = bytes(range(128))

    def raw(self, frame):
        self.lib.test_receive(frame, len(frame))
        self.lib.audio_stream_service()
        buf = ctypes.create_string_buffer(256)
        count = self.lib.test_reply(buf)
        return decode_reply(buf.raw[:count]) if count else None

    def send(self, offset, data=b""):
        reply = self.raw(packet(offset, data))
        self.assertIsNotNone(reply)
        return reply

    def begin(self, crc=None):
        return self.send(BEGIN, struct.pack("<II", len(self.data),
                          zlib.crc32(self.data) if crc is None else crc))

    def test_load_retries_mix_feed_and_wrap(self):
        self.assertEqual(self.begin()["error"], 0)
        self.assertEqual(self.send(0, self.data[:64])["loaded_bytes"], 64)
        self.assertEqual(self.send(0, self.data[:64])["loaded_bytes"], 64)
        self.assertEqual(self.send(FINISH)["error"], 3)
        self.assertEqual(self.send(64, self.data[64:])["loaded_bytes"], 128)
        self.assertTrue(self.send(FINISH)["ready"])
        clears = self.lib.test_clears()
        self.assertTrue(self.send(FINISH)["ready"])
        self.assertEqual(self.lib.test_clears(), clears)
        for _ in range(6): self.lib.audio_stream_service()
        buf = ctypes.create_string_buffer(8192)
        count = self.lib.test_samples(buf)
        self.assertEqual(count, 2048)
        self.assertEqual(buf.raw[:count], self.data * 16)
        self.assertEqual(self.lib.test_byte(128), 0x55)
        self.assertEqual(self.send(QUERY)["level"], 2048)

    def test_corruption_sequence_and_bounds(self):
        for size in (0, 65, 8388672):
            self.assertEqual(self.send(BEGIN, struct.pack("<II", size, 0))["error"], 2)
        self.begin()
        bad = bytearray(packet(0, self.data[:64])); bad[10] ^= 1
        self.assertEqual(self.raw(bytes(bad))["error"], 1)
        self.assertEqual(self.lib.test_byte(0), 0x55)
        for offset in (1, 64, 128, 0x80000000):
            self.assertEqual(self.send(offset)["error"], 2)
        self.assertEqual(self.send(QUERY)["loaded_bytes"], 0)

    def test_whole_track_crc(self):
        self.begin(crc=0)
        self.send(0, self.data[:64]); self.send(64, self.data[64:])
        self.assertEqual(self.send(FINISH)["error"], 3)
        self.assertFalse(self.send(QUERY)["ready"])

    def test_resume_checks_track_identity(self):
        self.begin()
        self.send(0, self.data[:64])
        info = struct.pack("<II", len(self.data), zlib.crc32(self.data))
        self.assertEqual(self.send(QUERY, info)["loaded_bytes"], 64)
        self.assertEqual(self.send(QUERY, struct.pack("<II", len(self.data), 0))["error"], 2)

    def test_partial_timeout_resync_and_tx_backpressure(self):
        self.assertIsNone(self.raw(packet(QUERY)[:18]))
        self.lib.test_time(50000001)
        self.assertEqual(self.send(QUERY)["error"], 0)
        self.lib.test_room(0)
        self.assertIsNone(self.raw(b"noiseB" + packet(QUERY)))
        self.lib.test_room(128)
        self.lib.audio_stream_service()
        buf = ctypes.create_string_buffer(256)
        size = self.lib.test_reply(buf)
        self.assertEqual(decode_reply(buf.raw[:size])["offset"], QUERY)

    def test_timeout_across_one_second_timer_wrap(self):
        self.lib.test_time(90000000)
        self.assertIsNone(self.raw(packet(QUERY)[:20]))
        self.lib.test_time(45000000)
        self.assertEqual(self.send(QUERY)["error"], 0)


if __name__ == "__main__":
    unittest.main()
