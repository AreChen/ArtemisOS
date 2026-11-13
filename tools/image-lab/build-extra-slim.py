#!/usr/bin/env python3
"""Build a disposable extra-slim experiment from the exact 0.3.4 lab image.

Never edit inputs. The resulting image removes optional user-facing features and
is not a production image; test compatibility and distribution rights first.
"""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path

SIZE = 2_144_882_688
OFFSET = 1_232_076_800
SHA256 = "866b6f259100e8d56f911832be2f7756cd716a86281bf4f9e116cc98e37aea96"
GROUPS = (
    ("/priv-app", "Velvet"),
    ("/priv-app", "DevicePersonalizationPrebuiltPixel2021-aiai_20240329.00_RC16"),
    ("/priv-app", "DeviceIntelligenceNetworkPrebuilt-astrea_20240329.00_RC02"),
    ("/priv-app", "WellbeingPrebuilt"),
    ("/priv-app", "AndroidAutoStubPrebuilt"),
    ("/app", "MarkupGoogle_v2"),
)
CHUNK = 8 * 1024 * 1024


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--disk", type=Path, required=True)
    p.add_argument("--product", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--rtk", default="rtk")
    p.add_argument("--debugfs", default="debugfs")
    p.add_argument("--e2fsck", default="e2fsck")
    p.add_argument("--zerofree", type=Path, required=True)
    args = p.parse_args()
    disk, product = args.disk.resolve(strict=True), args.product.resolve(strict=True)
    output = args.output.resolve()
    build_root = (Path(__file__).resolve().parents[2] / "build").resolve()
    if not output.is_relative_to(build_root) or output == build_root or output.exists():
        p.error("output must be a new directory within the project build directory")
    if disk.samefile(product) or product.stat().st_size != SIZE:
        p.error("unexpected or aliased product image")
    if OFFSET + SIZE > disk.stat().st_size:
        p.error("product extent is outside the disk")

    # Verify every byte of the detached image and of its disk extent before any
    # output is created. This also prevents silently patching a new image layout.
    digest = hashlib.sha256()
    with disk.open("rb") as ds, product.open("rb") as ps:
        ds.seek(OFFSET)
        while chunk := ps.read(CHUNK):
            if ds.read(len(chunk)) != chunk:
                raise SystemExit("disk extent is not the expected product image")
            digest.update(chunk)
    if digest.hexdigest() != SHA256:
        raise SystemExit("product SHA-256 differs from the tested baseline")

    removals = []
    inodes = set()
    for base, name in GROUPS:
        paths = (f"{base}/{name}/{name}.apk", f"{base}/{name}/oat/x86_64/{name}.odex",
                 f"{base}/{name}/oat/x86_64/{name}.vdex")
        for path in paths:
            result = subprocess.run([args.rtk, "proxy", args.debugfs, "-R", f"stat {path}", str(product)],
                                    check=True, capture_output=True, text=True)
            inode_match = re.search(r"^Inode:\s*(\d+)\s+Type:\s+regular", result.stdout, re.MULTILINE)
            links_match = re.search(r"Links:\s*(\d+)", result.stdout)
            if not inode_match or not links_match or int(links_match.group(1)) != 1:
                raise SystemExit(f"unexpected file type or hard-link count: {path}")
            inode = int(inode_match.group(1))
            if inode < 12 or inode in inodes:
                raise SystemExit(f"unexpected or duplicate inode: {path}")
            inodes.add(inode)
            removals.append((path, inode))

    output.mkdir()
    out_product = output / "product.img"
    out_disk = output / "system.img"
    commands = output / "removal.debugfs"
    commands.write_text("".join(f"unlink {path}\nclri <{inode}>\n" for path, inode in removals), encoding="ascii")
    with product.open("rb") as src, out_product.open("xb") as dst:
        shutil.copyfileobj(src, dst, CHUNK)
    if out_product.samefile(product):
        raise SystemExit("output unexpectedly aliases input")

    def run(name, command, accepted=(0,)):
        result = subprocess.run([args.rtk, "proxy", *map(str, command)], capture_output=True, text=True)
        (output / f"{name}.log").write_text(result.stdout + result.stderr, encoding="utf-8")
        if result.returncode not in accepted:
            raise SystemExit(f"{name} returned {result.returncode}; output retained for inspection")
        return result

    result = run("debugfs", [args.debugfs, "-w", "-f", commands, out_product])
    if re.search(r"(?i)(not found|error|failed|invalid)", result.stdout + result.stderr):
        raise SystemExit("debugfs reported an error; output retained for inspection")
    # These filesystems use ext4 shared_blocks. Never use debugfs rm here.
    # Repair the free-block and inode maps before zeroing the newly free blocks.
    run("repair", [args.e2fsck, "-fy", out_product], accepted=(0, 1))
    run("zerofree", [args.zerofree.resolve(strict=True), out_product])
    run("check", [args.e2fsck, "-fn", out_product])

    with disk.open("rb") as src, out_disk.open("xb") as dst:
        shutil.copyfileobj(src, dst, CHUNK)
    if out_disk.samefile(disk):
        raise SystemExit("output unexpectedly aliases input")
    with out_disk.open("r+b") as ds, out_product.open("rb") as ps:
        ds.seek(OFFSET)
        shutil.copyfileobj(ps, ds, CHUNK)
    info = {"source_product_sha256": SHA256, "product_offset": OFFSET, "product_length": SIZE,
            "removed_groups": [f"{base}/{name}" for base, name in GROUPS],
            "removed_files": [path for path, _ in removals],
            "notes": "Experimental only; GMS, WebView, input method, SMS and ARM translation retained."}
    (output / "manifest.json").write_text(json.dumps(info, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(info, indent=2))


if __name__ == "__main__":
    main()
