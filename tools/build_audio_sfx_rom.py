#!/usr/bin/env python3
"""Convert selected game audio SFX files into an 8-bit signed PCM ROM image."""

from pathlib import Path
import array
import math
import subprocess
import tempfile
import wave

ROOT = Path(__file__).resolve().parents[1]
SRC_DIR = ROOT / "assets" / "audio" / "source"
OUT_HEX = ROOT / "rtl" / "audio" / "sfx_rom.hex"
OUT_VH = ROOT / "rtl" / "audio" / "sfx_rom.vh"

TARGET_RATE = 1600
ROM_DEPTH = 8192
ASSETS = [
    ("SHOT", "shoot2.mp3", 600),
    ("KILL", "game_explosion3.mp3", 2200),
    ("BOSS", "large_destruction1.mp3", 4400),
    ("HIT",  "hit_bell.wav", 320),
    ("LASER", "laser_beam.mp3", 1200),
]


def ensure_hit_bell_wav(path: Path) -> None:
    """Synthesize a crisp, high-recognition crystal/metallic impact chime (hit_bell.wav)."""
    sr = 16000
    dur = 0.20  # 320 samples at 1600 Hz
    n_samples = int(sr * dur)
    samples = array.array("h")
    for i in range(n_samples):
        t = i / sr
        # Stage 1 (0..18ms): ultra-crisp metallic transient + high-energy snap
        env_attack = math.exp(-t * 65.0)
        # Stage 2 (0..110ms): Touhou-style urgent pitch-swept biu-chuu core (680Hz -> 310Hz)
        f_sweep = 310.0 + 370.0 * math.exp(-t * 18.0)
        env_body = math.exp(-t * 11.5)
        # Stage 3: resonant crystal fifth harmonic (540Hz + 720Hz shimmer, below 800Hz Nyquist)
        sig = (
            0.52 * env_body * math.sin(2.0 * math.pi * f_sweep * t)
            + 0.30 * env_body * math.sin(2.0 * math.pi * 540.0 * t + 0.8 * math.sin(2.0 * math.pi * 90.0 * t))
            + 0.28 * env_attack * math.sin(2.0 * math.pi * 720.0 * t)
            + 0.18 * env_attack * (1.0 if (i % 22) < 11 else -1.0)
        )
        # Smooth tail fade over last 15ms to guarantee zero click
        if t > dur - 0.015:
            sig *= max(0.0, (dur - t) / 0.015)
        v = int(max(-1.0, min(1.0, sig * 1.15)) * 32767)
        samples.append(v)

    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sr)
        wf.writeframes(samples.tobytes())


_MF_C_SRC = r"""
#define COBJMACROS
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <stdio.h>
#include <stdint.h>

int main(int argc, char **argv) {
    if (argc < 3) return 1;
    wchar_t wpath[1024];
    MultiByteToWideChar(CP_UTF8, 0, argv[1], -1, wpath, 1024);
    CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET);
    IMFSourceReader *reader = NULL;
    if (FAILED(MFCreateSourceReaderFromURL(wpath, NULL, &reader))) return 2;
    IMFMediaType *pcmType = NULL;
    MFCreateMediaType(&pcmType);
    IMFMediaType_SetGUID(pcmType, &MF_MT_MAJOR_TYPE, &MFMediaType_Audio);
    IMFMediaType_SetGUID(pcmType, &MF_MT_SUBTYPE, &MFAudioFormat_PCM);
    IMFSourceReader_SetCurrentMediaType(reader, MF_SOURCE_READER_FIRST_AUDIO_STREAM, NULL, pcmType);
    IMFMediaType_Release(pcmType);
    IMFMediaType *actualType = NULL;
    IMFSourceReader_GetCurrentMediaType(reader, MF_SOURCE_READER_FIRST_AUDIO_STREAM, &actualType);
    UINT32 channels = 0, sampleRate = 0, bits = 0;
    IMFMediaType_GetUINT32(actualType, &MF_MT_AUDIO_NUM_CHANNELS, &channels);
    IMFMediaType_GetUINT32(actualType, &MF_MT_AUDIO_SAMPLES_PER_SECOND, &sampleRate);
    IMFMediaType_GetUINT32(actualType, &MF_MT_AUDIO_BITS_PER_SAMPLE, &bits);
    IMFMediaType_Release(actualType);
    FILE *fp = fopen(argv[2], "wb");
    if (!fp) return 3;
    fwrite(&sampleRate, 4, 1, fp);
    fwrite(&channels, 4, 1, fp);
    fwrite(&bits, 4, 1, fp);
    while (1) {
        DWORD flags = 0;
        IMFSample *sample = NULL;
        HRESULT hr = IMFSourceReader_ReadSample(reader, MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0, NULL, &flags, NULL, &sample);
        if (FAILED(hr) || (flags & MF_SOURCE_READERF_ENDOFSTREAM)) {
            if (sample) IMFSample_Release(sample);
            break;
        }
        if (sample) {
            IMFMediaBuffer *buf = NULL;
            if (SUCCEEDED(IMFSample_ConvertToContiguousBuffer(sample, &buf))) {
                BYTE *ptr = NULL;
                DWORD len = 0;
                if (SUCCEEDED(IMFMediaBuffer_Lock(buf, &ptr, NULL, &len))) {
                    fwrite(ptr, 1, len, fp);
                    IMFMediaBuffer_Unlock(buf);
                }
                IMFMediaBuffer_Release(buf);
            }
            IMFSample_Release(sample);
        }
    }
    fclose(fp);
    IMFSourceReader_Release(reader);
    MFShutdown();
    CoUninitialize();
    return 0;
}
"""


def decode_raw_samples(path: Path) -> tuple[int, list[float]]:
    """Decode WAV or MP3 file into (sample_rate, mono_float_samples)."""
    if path.suffix.lower() == ".wav":
        with wave.open(str(path), "rb") as wf:
            sr = wf.getframerate()
            ch = wf.getnchannels()
            sw = wf.getsampwidth()
            raw = wf.readframes(wf.getnframes())
        if sw == 2:
            arr = array.array("h")
            arr.frombytes(raw)
            mono = [
                sum(arr[i + c] for c in range(ch)) / (ch * 32768.0)
                for i in range(0, len(arr) - ch + 1, ch)
            ]
            return sr, mono

    try:
        import pygame
        if not pygame.mixer.get_init():
            pygame.mixer.init(frequency=TARGET_RATE, size=-16, channels=1)
        snd = pygame.mixer.Sound(str(path))
        arr = array.array("h")
        arr.frombytes(snd.get_raw())
        return TARGET_RATE, [x / 32768.0 for x in arr]
    except ImportError:
        pass

    with tempfile.TemporaryDirectory() as tmpdir:
        c_file = Path(tmpdir) / "mfdec.c"
        exe_file = Path(tmpdir) / "mfdec.exe"
        raw_file = Path(tmpdir) / "out.raw"
        c_file.write_text(_MF_C_SRC, encoding="utf-8")
        gcc_candidates = [
            r"C:\msys64\mingw64\bin\gcc.exe",
            "gcc",
        ]
        gcc_bin = next((g for g in gcc_candidates if Path(g).exists() or g == "gcc"), "gcc")
        subprocess.run(
            [gcc_bin, str(c_file), "-o", str(exe_file), "-lmfplat", "-lmfreadwrite", "-lmfuuid", "-lole32"],
            check=True,
        )
        subprocess.run([str(exe_file), str(path), str(raw_file)], check=True)
        blob = raw_file.read_bytes()
        import struct
        sr, ch, bits = struct.unpack("<III", blob[:12])
        pcm = blob[12:]
        arr = array.array("h")
        arr.frombytes(pcm)
        mono = [
            sum(arr[i + c] for c in range(ch)) / (ch * 32768.0)
            for i in range(0, len(arr) - ch + 1, ch)
        ]
        return sr, mono


def load_clip(path: Path, max_samples: int) -> list[int]:
    sr, mono = decode_raw_samples(path)
    if sr != TARGET_RATE:
        # Box-filter anti-aliased downsample to TARGET_RATE (1600 Hz)
        ratio = sr / float(TARGET_RATE)
        out_len = max(1, int(len(mono) / ratio))
        resampled = []
        for i in range(out_len):
            s0 = int(i * ratio)
            s1 = max(s0 + 1, min(len(mono), int((i + 1) * ratio)))
            resampled.append(sum(mono[s0:s1]) / (s1 - s0))
        mono = resampled

    truncated = len(mono) > max_samples
    mono = mono[:max_samples]
    peak = max((abs(x) for x in mono), default=1e-6)
    scale = 118.0 / peak if peak > 1e-6 else 1.0

    # Apply smooth 32-sample tail fade if truncated so SFX never clicks on stop
    fade_len = min(32, len(mono) // 4) if truncated else 0
    out = []
    for idx, x in enumerate(mono):
        env = 1.0
        if fade_len > 0 and idx >= len(mono) - fade_len:
            env = (len(mono) - 1 - idx) / float(fade_len)
        v = int(round(x * scale * env))
        out.append(max(-127, min(127, v)) & 0xFF)
    return out


def main() -> None:
    ensure_hit_bell_wav(SRC_DIR / "hit_bell.wav")
    rom: list[int] = []
    vh_lines = ["// Generated by tools/build_audio_sfx_rom.py; do not edit."]

    for name, filename, max_samples in ASSETS:
        clip = load_clip(SRC_DIR / filename, max_samples)
        start = len(rom)
        rom.extend(clip)
        vh_lines.append(f"localparam [12:0] SFX_{name}_START = 13'd{start};")
        vh_lines.append(f"localparam [12:0] SFX_{name}_LEN = 13'd{len(clip)};")
        print(f"SFX_{name:5s}: start={start:4d}, len={len(clip):4d} ({filename})")

    if len(rom) > ROM_DEPTH:
        raise SystemExit(f"SFX ROM overflow: {len(rom)} > {ROM_DEPTH}")

    print(f"Total SFX ROM usage: {len(rom)} / {ROM_DEPTH} bytes ({ROM_DEPTH - len(rom)} bytes free)")
    rom.extend([0] * (ROM_DEPTH - len(rom)))
    OUT_HEX.write_text("\n".join(f"{b:02x}" for b in rom) + "\n", encoding="ascii")
    OUT_VH.write_text("\n".join(vh_lines) + "\n", encoding="ascii")


if __name__ == "__main__":
    main()
