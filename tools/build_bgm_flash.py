"""Pack the complete song and Efinity byte-per-line configuration into one flash image."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BASE = 0x200000
LIMIT = 0x800000
RATE = 12000


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--config', type=Path, default=ROOT / 'outflow/ti60_top.hex')
    p.add_argument('--song', type=Path)
    p.add_argument('--out', type=Path, default=ROOT / 'sw/build/bgm_flash')
    args = p.parse_args()
    songs = sorted((ROOT / 'bgm').glob('*.mp3'))
    song = args.song or (songs[0] if len(songs) == 1 else None)
    if song is None:
        p.error('Specify --song when bgm does not contain exactly one MP3')
    ffmpeg = shutil.which('ffmpeg')
    if not ffmpeg:
        import imageio_ffmpeg
        ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()
    args.out.mkdir(parents=True, exist_ok=True)
    pcm_path = args.out / 'bgm.u8'
    subprocess.run([ffmpeg, '-v', 'error', '-y', '-i', str(song), '-map', '0:a:0',
                    '-ac', '1', '-ar', str(RATE), '-c:a', 'pcm_u8', '-f', 'u8', str(pcm_path)], check=True)
    pcm = pcm_path.read_bytes()
    config = bytes.fromhex(args.config.read_text(encoding='ascii'))
    if not config.startswith(b'Version:') or b'Width: 1\n' not in config[:1024]:
        raise ValueError('Expected Efinity x1 flash configuration')
    if len(config) > BASE or not pcm or BASE + 8 + len(pcm) > LIMIT:
        raise ValueError('Configuration/song overlaps or exceeds 8 MiB flash')
    bank = b'BGM1' + struct.pack('<I', len(pcm)) + pcm
    image = config + b'\xff' * (BASE - len(config)) + bank
    output = args.out / 'ti60_10000_bgm_card.hex'
    output.write_text(''.join('%02X\n' % b for b in image), encoding='ascii', newline='\n')
    verify = bytes.fromhex(output.read_text(encoding='ascii'))
    assert verify[:len(config)] == config
    assert verify[BASE:BASE+8] == b'BGM1' + struct.pack('<I', len(pcm))
    assert verify[BASE+8:] == pcm
    manifest = dict(song=song.name, song_sha256=digest(song.read_bytes()), pcm_sha256=digest(pcm),
                    rate=RATE, channels=1, format='unsigned 8-bit PCM', pcm_bytes=len(pcm),
                    seconds=len(pcm)/RATE, flash_base=BASE, flash_end=len(image), flash_capacity=LIMIT,
                    config_file=str(args.config), config_sha256=digest(args.config.read_bytes()),
                    config_flash_bytes=len(config), combined_sha256=digest(output.read_bytes()))
    (args.out / 'bgm_manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(manifest, ensure_ascii=False, indent=2))
    print(output)


if __name__ == '__main__':
    main()
