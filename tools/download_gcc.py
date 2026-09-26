import os
import sys
import time
import zipfile
import urllib.request
import concurrent.futures

URL = 'https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v12.4.0-2/xpack-riscv-none-elf-gcc-12.4.0-2-win32-x64.zip'
TARGET_DIR = r'E:\FPGA\toolchain'
ZIP_PATH = os.path.join(TARGET_DIR, 'riscv-gcc.zip')
EXTRACT_DIR = os.path.join(TARGET_DIR, 'riscv-gcc')

def get_file_size(url):
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
    with urllib.request.urlopen(req, timeout=15) as r:
        return int(r.headers.get('Content-Length'))

def download_range(url, start, end, part_path):
    req = urllib.request.Request(url, headers={
        'User-Agent': 'Mozilla/5.0',
        'Range': f'bytes={start}-{end}'
    })
    with urllib.request.urlopen(req, timeout=30) as r:
        with open(part_path, 'wb') as f:
            while True:
                chunk = r.read(64 * 1024)
                if not chunk:
                    break
                f.write(chunk)
    return end - start + 1

def main():
    os.makedirs(TARGET_DIR, exist_ok=True)
    bin_check = os.path.join(EXTRACT_DIR, 'bin', 'riscv-none-elf-gcc.exe')
    if os.path.exists(bin_check):
        print(f'[FOUND] Toolchain already installed at: {bin_check}')
        return 0

    print(f'[INFO] Querying file size from {URL} ...')
    total_size = get_file_size(URL)
    print(f'[INFO] Total size: {total_size / (1024*1024):.1f} MB')

    num_threads = 16
    chunk_size = total_size // num_threads
    parts = []
    
    t0 = time.time()
    print(f'[INFO] Downloading with {num_threads} concurrent threads ...')
    with concurrent.futures.ThreadPoolExecutor(max_workers=num_threads) as executor:
        futures = []
        for i in range(num_threads):
            start = i * chunk_size
            end = total_size - 1 if i == num_threads - 1 else (start + chunk_size - 1)
            part_path = os.path.join(TARGET_DIR, f'part_{i}.tmp')
            parts.append(part_path)
            futures.append(executor.submit(download_range, URL, start, end, part_path))

        done_bytes = 0
        for f in concurrent.futures.as_completed(futures):
            b = f.result()
            done_bytes += b
            pct = (done_bytes / total_size) * 100
            elapsed = time.time() - t0
            speed = (done_bytes / (1024 * 1024)) / (elapsed if elapsed > 0 else 1)
            print(f'\r[PROGRESS] {pct:.1f}% ({done_bytes / (1024*1024):.1f}/{total_size / (1024*1024):.1f} MB, {speed:.2f} MB/s)', end='', flush=True)

    print(f'\n[INFO] Download finished in {time.time()-t0:.1f}s. Assembling parts into {ZIP_PATH} ...')
    with open(ZIP_PATH, 'wb') as out_f:
        for p in parts:
            with open(p, 'rb') as in_f:
                while True:
                    buf = in_f.read(1024 * 1024)
                    if not buf:
                        break
                    out_f.write(buf)
            try:
                os.remove(p)
            except Exception:
                pass

    print(f'[INFO] Extracting to {EXTRACT_DIR} ...')
    with zipfile.ZipFile(ZIP_PATH, 'r') as z:
        top_folder = z.namelist()[0].split('/')[0]
        z.extractall(TARGET_DIR)
        
    extracted_folder = os.path.join(TARGET_DIR, top_folder)
    if extracted_folder != EXTRACT_DIR and os.path.exists(extracted_folder):
        if os.path.exists(EXTRACT_DIR):
            import shutil
            shutil.rmtree(EXTRACT_DIR)
        os.rename(extracted_folder, EXTRACT_DIR)

    try:
        os.remove(ZIP_PATH)
    except Exception:
        pass
    print(f'[SUCCESS] RISC-V GCC toolchain installed successfully at: {EXTRACT_DIR}')
    return 0

if __name__ == '__main__':
    sys.exit(main())
