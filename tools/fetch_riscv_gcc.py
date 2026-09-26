#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
tools/fetch_riscv_gcc.py  --  xPack riscv-none-elf GCC bootstrapper

Replaces the legacy "hand-assembled machine code from Python" firmware flow
with a real GCC toolchain flow (C -> ELF -> BIN -> BRAM lane init).

  python tools/fetch_riscv_gcc.py                 # install newest stable
  python tools/fetch_riscv_gcc.py --force         # reinstall
  python tools/fetch_riscv_gcc.py --tag v12.4.0-2 # pin a release

Installs into <target>/riscv-gcc/bin/riscv-none-elf-gcc.exe (default target
E:\\FPGA\\toolchain).  Multi-threaded ranged download with per-chunk resume and
sha256 verification against the release .sha asset.
"""
import argparse
import concurrent.futures as cf
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request
import zipfile

DEFAULT_TARGET = r"E:\FPGA\toolchain"
PINNED_TAG = "v15.2.0-1"
ASSET_RE = re.compile(r"^xpack-riscv-none-elf-gcc-.*-win32-x64\.zip$")
UA = {"User-Agent": "Mozilla/5.0 (ti60-fetch-riscv-gcc)"}

# This machine exports stale *_PROXY variables pointing at a local proxy that is
# not running (WinINET itself is configured direct).  Use an explicit no-proxy
# opener so the download works regardless of the inherited environment.
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def log(m):
    print("[riscv-gcc] %s" % m, flush=True)


def api_get(url, timeout=30):
    with OPENER.open(urllib.request.Request(url, headers=UA),
                                timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def resolve_release(tag):
    """-> (tag, asset_name, asset_url, sha_url|None)"""
    rel = None
    if tag is None:
        try:
            rel = api_get("https://api.github.com/repos/xpack-dev-tools/"
                          "riscv-none-elf-gcc-xpack/releases/latest")
            tag = rel["tag_name"]
            log("newest stable release: %s (%s)" % (tag, rel.get("published_at", "?")))
        except Exception as exc:
            log("GitHub API unavailable (%s); using %s" % (exc, PINNED_TAG))
            tag = PINNED_TAG
    if rel is None:
        base = ("https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/"
                "releases/download/%s/" % tag)
        name = "xpack-riscv-none-elf-gcc-%s-win32-x64.zip" % tag.lstrip("v")
        return tag, name, base + name, base + name + ".sha"
    names = {a["name"]: a["browser_download_url"] for a in rel.get("assets", [])}
    for name, url in names.items():
        if ASSET_RE.match(name):
            return tag, name, url, names.get(name + ".sha")
    raise RuntimeError("no win32-x64 zip asset in %s" % tag)


def remote_size(url):
    req = urllib.request.Request(url, headers=UA, method="HEAD")
    with OPENER.open(req, timeout=30) as r:
        return int(r.headers["Content-Length"])


def fetch_range(url, start, end, path, attempts=6):
    want = end - start + 1
    for attempt in range(1, attempts + 1):
        have = os.path.getsize(path) if os.path.exists(path) else 0
        if have > want:
            have = 0
        if have == want:
            return want
        headers = dict(UA, Range="bytes=%d-%d" % (start + have, end))
        try:
            with OPENER.open(urllib.request.Request(url, headers=headers),
                                        timeout=60) as r:
                with open(path, "ab" if have else "wb") as fh:
                    while True:
                        chunk = r.read(256 * 1024)
                        if not chunk:
                            break
                        fh.write(chunk)
            if os.path.getsize(path) >= want:
                return want
        except Exception as exc:
            if attempt == attempts:
                raise
            log("chunk retry %d/%d (%s)" % (attempt, attempts, exc))
            time.sleep(2 * attempt)
    return os.path.getsize(path) if os.path.exists(path) else 0


def download(url, dest, threads=16):
    total = remote_size(url)
    log("downloading %.1f MB with %d threads -> %s" % (total / 1048576.0, threads, dest))
    pdir = dest + ".parts"
    os.makedirs(pdir, exist_ok=True)
    span = (total + threads - 1) // threads
    jobs = []
    for i in range(threads):
        s = i * span
        e = min(total - 1, s + span - 1)
        if s <= e:
            jobs.append((s, e, os.path.join(pdir, "part_%02d" % i)))
    done = [0] * len(jobs)
    t0 = time.time()
    with cf.ThreadPoolExecutor(max_workers=threads) as pool:
        futs = {pool.submit(fetch_range, url, s, e, p): k
                for k, (s, e, p) in enumerate(jobs)}
        for fut in cf.as_completed(futs):
            done[futs[fut]] = fut.result()
            moved = sum(done)
            print("\r[riscv-gcc] %5.1f%%  %7.1f/%.1f MB  %5.2f MB/s"
                  % (moved * 100.0 / total, moved / 1048576.0, total / 1048576.0,
                     moved / 1048576.0 / max(0.001, time.time() - t0)),
                  end="", flush=True)
    print("", flush=True)
    log("assembling parts")
    with open(dest, "wb") as out:
        for _, _, p in jobs:
            with open(p, "rb") as fh:
                shutil.copyfileobj(fh, out, 4 * 1024 * 1024)
    shutil.rmtree(pdir, ignore_errors=True)
    if os.path.getsize(dest) != total:
        raise RuntimeError("size mismatch %d != %d" % (os.path.getsize(dest), total))
    log("download finished in %.0f s" % (time.time() - t0))
    return dest


def verify_sha(dest, sha_url):
    if not sha_url:
        log("no .sha asset; skipping checksum")
        return
    try:
        with OPENER.open(urllib.request.Request(sha_url, headers=UA),
                                    timeout=30) as r:
            expect = r.read().decode("utf-8", "replace").split()[0].lower()
    except Exception as exc:
        log("checksum fetch failed (%s); skipping" % exc)
        return
    h = hashlib.sha256()
    with open(dest, "rb") as fh:
        for blk in iter(lambda: fh.read(4 * 1024 * 1024), b""):
            h.update(blk)
    if h.hexdigest().lower() != expect:
        raise RuntimeError("sha256 mismatch")
    log("sha256 verified %s" % expect)


def install(zip_path, final_dir):
    log("extracting")
    staging = final_dir + ".staging"
    shutil.rmtree(staging, ignore_errors=True)
    os.makedirs(staging, exist_ok=True)
    with zipfile.ZipFile(zip_path) as z:
        z.extractall(staging)
    tops = [e for e in os.listdir(staging) if os.path.isdir(os.path.join(staging, e))]
    if len(tops) != 1:
        raise RuntimeError("unexpected archive layout %s" % tops)
    shutil.rmtree(final_dir, ignore_errors=True)
    os.rename(os.path.join(staging, tops[0]), final_dir)
    shutil.rmtree(staging, ignore_errors=True)


def probe(final_dir):
    gcc = os.path.join(final_dir, "bin", "riscv-none-elf-gcc.exe")
    if not os.path.exists(gcc):
        return None
    try:
        return subprocess.run([gcc, "--version"], capture_output=True, text=True,
                              timeout=60).stdout.strip().splitlines()[0]
    except Exception as exc:
        return "present but not runnable: %s" % exc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", default=DEFAULT_TARGET)
    ap.add_argument("--tag", default=None)
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--threads", type=int, default=16)
    a = ap.parse_args()

    final_dir = os.path.join(a.target, "riscv-gcc")
    if not a.force:
        head = probe(final_dir)
        if head:
            log("already installed: %s" % head)
            return 0
    os.makedirs(a.target, exist_ok=True)
    tag, name, url, sha = resolve_release(a.tag)
    zip_path = os.path.join(a.target, name)
    if a.force and os.path.exists(zip_path):
        os.remove(zip_path)
    try:
        complete = os.path.getsize(zip_path) == remote_size(url)
    except Exception:
        complete = False
    if complete:
        log("reusing complete archive")
    else:
        download(url, zip_path, a.threads)
    verify_sha(zip_path, sha)
    install(zip_path, final_dir)
    try:
        os.remove(zip_path)
    except OSError:
        pass
    head = probe(final_dir)
    log("installed -> %s" % final_dir)
    log(head or "WARNING: gcc binary missing")
    return 0 if head else 1


if __name__ == "__main__":
    sys.exit(main())
