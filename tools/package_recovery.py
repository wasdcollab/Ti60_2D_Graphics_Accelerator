"""Create a source archive and hashes without modifying the historical backup."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import zipfile

ROOT = Path(__file__).resolve().parents[1]
BASE = Path(r"D:\Ti60_2D_Graphics_Accelerator (3)(1)\Ti60_2D_Graphics_Accelerator")
OUT = ROOT.parent / "release_drop65535_fix_20261024"
SKIP = {".git", "__pycache__", "cache", "output", "build", "outflow",
        "work_pnr", "work_syn", "work_sim", "rtl_runtime", "tmp"}
TOP = {"rtl", "sw", "ip", "assets", "simulator", "tools", "tests", "sdc", "docs"}


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def sources(root):
    result = {}
    for folder, dirs, names in os.walk(root):
        relative = Path(folder).relative_to(root)
        dirs[:] = sorted(d for d in dirs if d not in SKIP and
                         (relative.parts or d in TOP))
        for name in sorted(names):
            path = Path(folder) / name
            if path.suffix.lower() in {".log", ".pyd", ".dll", ".o", ".pyc", ".vvp"}:
                continue
            if not relative.parts and path.suffix.lower() not in {".md", ".bat", ".xml", ".json", ".txt"}:
                continue
            result[path.relative_to(root).as_posix()] = digest(path)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--busdiag", action="store_true")
    mode.add_argument("--cmd-latch", action="store_true")
    args = parser.parse_args()
    out = ROOT.parent / "release_busdiag_20261025" if args.busdiag else OUT
    prefix = "ti60_busdiag" if args.busdiag else "ti60_drop65535_fix"
    archive_name = "Ti60_busdiag_source_20261025.zip" if args.busdiag else "Ti60_drop65535_fix_source.zip"
    build_log = "hardware_busdiag_20261025.log" if args.busdiag else "hardware_drop65535_fix.log"
    if args.cmd_latch:
        out = ROOT.parent / "release_cmd_latch_20261025"
        prefix = "ti60_cmd_latch_fix"
        archive_name = "Ti60_cmd_latch_source_20261025.zip"
        build_log = "hardware_cmd_latch_20261025.log"
    evidence = ROOT / "docs/recovery_evidence"
    evidence.mkdir(parents=True, exist_ok=True)
    logs = ["hardware_recovery_final2.log"] + ["work_sim/" + name for name in (
        "frame_stability_final.log", "bucket_mux_final.log", "scanline_current.log",
        "bitblt_final.log", "bitblt_large_final.log", "alpha_rtl_final.log", "add_rtl_final.log",
        "write_abort_final.log", "bloom_final.log", "audio_current.log", "attack_effects_final.log",
        "boss8000_final.log", "settings_final.log", "menu_visual_final.log", "alpha_game_final.log")]
    logs += ["hardware_drop65535_fix.log"] + ["work_sim/" + name for name in (
        "board_before.log", "board_fixed.log", "batch_small.log", "batch_large.log", "batch_errors_small.log",
        "guard_liveness_before.log", "guard_liveness_fixed.log", "guard_protocol.log", "guard_legacy.log")]
    if args.busdiag:
        logs += [build_log] + ["work_sim/" + name for name in (
            "read_busy_before.log", "read_busy_fixed.log", "read_drain_large.log",
            "busdiag_1300.log", "busdiag_vendor.log", "busdiag_bucket_large.log",
            "busdiag_snapshot.log", "busdiag_apb.log")]
        logs += ["outflow/ti60_top." + name + ".rpt" for name in ("timing", "place", "hier_util")]
        saved = evidence / "busdiag_before"
        saved.mkdir(parents=True, exist_ok=True)
        for path in (ROOT.parent / "before_busdiag_20261025").rglob("*"):
            if path.is_file():
                dest = saved / path.relative_to(ROOT.parent / "before_busdiag_20261025")
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, dest)
    if args.cmd_latch:
        logs += [build_log] + ["work_sim/" + name for name in (
            "cmd_overlap_before.log", "cmd_overlap_fixed.log", "cmd_latch_vectors.log", "cmd_latch_large.log")]
        saved = evidence / "cmd_latch_before"
        for path in (ROOT.parent / "before_cmd_latch_20261025").rglob("*"):
            if path.is_file():
                dest = saved / path.relative_to(ROOT.parent / "before_cmd_latch_20261025")
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, dest)
        for name in ("timing", "place", "hier_util"):
            shutil.copy2(ROOT / ("outflow/ti60_top." + name + ".rpt"),
                         evidence / ("cmd_latch_" + name + ".txt"))
    for relative in logs:
        shutil.copy2(ROOT / relative, evidence / (Path(relative).stem + ".txt"))
    shutil.copy2(ROOT / "work_sim/boss8000_final.json", evidence / "boss8000.json")
    shutil.copy2(ROOT / "simulator/output/recovered_pause.png", evidence / "recovered_pause.png")
    before=evidence / "dropfix_before"
    before.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "work_sim/bucket_before_65535.v", before / "dma_bucket_coprocessor.v")
    shutil.copy2(ROOT / "work_sim/write_guard_before_65535.v", before / "video_write_guard.v")
    current, baseline = sources(ROOT), sources(BASE)
    changed = [k for k in current if k in baseline and current[k] != baseline[k]]
    added = [k for k in current if k not in baseline]
    removed = [k for k in baseline if k not in current]
    artifacts = {k: digest(ROOT / k) for k in (
        "sw/build/firmware.bin", "sw/build/firmware.elf", "outflow/ti60_top.bit",
        "outflow/ti60_top.hex", "outflow/ti60_top.timing.rpt",
        "outflow/ti60_top.hier_util.rpt", "outflow/ti60_top.place.rpt", build_log)}
    manifest = dict(original_backup=str(BASE), recovery=str(ROOT),
                    original_source_sha256=baseline, recovered_source_sha256=current,
                    changed=changed, added=added, removed=removed, artifact_sha256=artifacts,
                    provenance="Historical backup + local session evidence + reconstructed code; not byte-identical recovery.")
    out.mkdir(parents=True, exist_ok=True)
    release_names={"sw/build/firmware.bin":"firmware.bin", "sw/build/firmware.elf":"firmware.elf",
        "sw/build/firmware.sym":"firmware.sym", "outflow/ti60_top.bit":prefix + ".bit",
        "outflow/ti60_top.hex":prefix + ".hex"}
    for relative,name in release_names.items():
        shutil.copy2(ROOT / relative, out / name)
    manifest["release_files_sha256"]={name:digest(out/name) for name in release_names.values()}
    (out / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    archive = out / archive_name
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as target:
        for relative in current:
            target.write(ROOT / relative, "Ti60_2D_Graphics_Accelerator/" + relative)
        target.write(out / "manifest.json", "manifest.json")
    (out / "SHA256SUMS.txt").write_text(
        digest(archive) + "  " + archive.name + "\n" +
        digest(out / "manifest.json") + "  manifest.json\n" +
        "".join(value+"  "+name+"\n" for name,value in manifest["release_files_sha256"].items()), encoding="ascii")
    second = Path.home() / "Ti60_recovery_20261024" / out.name
    second.mkdir(parents=True, exist_ok=True)
    for name in (archive.name, "manifest.json", "SHA256SUMS.txt"):
        shutil.copy2(out / name, second / name)
    print("Recovery package: %d sources, %d changed, %d added, %.1f MiB" %
          (len(current), len(changed), len(added), archive.stat().st_size / 1048576))
    print(archive)
    print("Original source files missing from recovery: %d" % len(removed))
    print("Second source package: %s" % (second / archive.name))


if __name__ == "__main__":
    main()
