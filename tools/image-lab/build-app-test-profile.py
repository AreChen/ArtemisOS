#!/usr/bin/env python3
"""Build a disposable app-test image from the exact 0.3.5 pilot candidate.

This experiment removes the Google Personal Safety and Data Restore Tool apps.
It is not a release image. Only newly created files under build/image-slim-exp
are written; inputs may be hard-linked to a working installation and are never
modified. Run in the development WSL environment, not on a user's computer.
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
DISK_SIZE = 3_576_692_736
DISK_SHA256 = "ab633cc0504a61c6006cd39d2b371dff8e341f0176e70384597692d7d90a2752"
PRODUCT_SHA256 = "57af1faeea287147c423b1e3460f7c79ffff9049a303325755349cd1752020d0"
CHUNK = 8 * 1024 * 1024
GROUPS = (
    ("/priv-app", "SafetyHubPrebuilt"),
    ("/priv-app", "GoogleRestorePrebuilt-v526684"),
)
PROTECTED = (
    "/priv-app/PrebuiltGmsCore/PrebuiltGmsCore.apk",
    "/priv-app/PrebuiltBugle/PrebuiltBugle.apk",
    "/priv-app/GoogleDialer/GoogleDialer.apk",
    "/app/LatinIMEGooglePrebuilt/LatinIMEGooglePrebuilt.apk",
    "/app/GoogleTTS/GoogleTTS.apk",
    "/app/TrichromeLibrary/TrichromeLibrary.apk.gz",
    "/app/WebViewGoogle/WebViewGoogle.apk.gz",
    "/app/Camera2/Camera2.apk",
    "/app/CalendarGooglePrebuilt/CalendarGooglePrebuilt.apk",
    "/app/GoogleContacts/GoogleContacts.apk",
    "/app/talkback/talkback.apk",
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--disk", type=Path, required=True)
    parser.add_argument("--product", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rtk", default="rtk")
    parser.add_argument("--debugfs", default="debugfs")
    parser.add_argument("--e2fsck", default="e2fsck")
    parser.add_argument("--dumpe2fs", default="dumpe2fs")
    parser.add_argument("--zerofree", type=Path, required=True)
    args = parser.parse_args()
    disk, product = args.disk.resolve(strict=True), args.product.resolve(strict=True)
    output = args.output.resolve()
    experiment_root = (Path(__file__).resolve().parents[2] / "build/image-slim-exp").resolve()
    if output == experiment_root or not output.is_relative_to(experiment_root) or output.exists():
        parser.error("output must be a new directory inside build/image-slim-exp")
    if not disk.is_file() or not product.is_file() or disk.samefile(product):
        parser.error("disk and product must be distinct regular files")
    if disk.stat().st_size != DISK_SIZE or product.stat().st_size != SIZE:
        parser.error("unexpected image size")
    if OFFSET + SIZE > DISK_SIZE:
        parser.error("product extent is outside the disk")
    zerofree = args.zerofree.resolve(strict=True)
    output.mkdir(parents=True)

    def command(name, argv, accepted=(0,)):
        result = subprocess.run([args.rtk, "proxy", *map(str, argv)],
                                capture_output=True, text=True)
        (output / f"{name}.log").write_text(result.stdout + result.stderr, encoding="utf-8")
        if result.returncode not in accepted:
            raise SystemExit(f"{name}: return code {result.returncode}; inspect output")
        return result

    def read_stat(image, path):
        result = subprocess.run([args.rtk, "proxy", args.debugfs, "-R", f"stat {path}", str(image)],
                                check=True, capture_output=True, text=True)
        inode = re.search(r"^Inode:\s*(\d+)\s+Type:\s+regular", result.stdout, re.MULTILINE)
        links = re.search(r"Links:\s*(\d+)", result.stdout)
        size = re.search(r"Size:\s*(\d+)", result.stdout)
        if not inode or not links or not size or int(links.group(1)) != 1:
            raise SystemExit(f"unexpected type, hard links or size: {path}")
        return int(inode.group(1)), int(size.group(1))

    def content_hash(image, path, expected_size):
        # debugfs writes bytes to stdout; stream them rather than retaining an
        # entire APK in memory or exposing the binary to a shell pipeline.
        proc = subprocess.Popen([args.rtk, "proxy", args.debugfs, "-R",
                                 f"dump {path} /dev/stdout", str(image)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        digest, total = hashlib.sha256(), 0
        while True:
            block = proc.stdout.read(CHUNK)
            if not block:
                break
            digest.update(block)
            total += len(block)
        errors = proc.stderr.read().decode("utf-8", errors="replace")
        status = proc.wait()
        if status or total != expected_size or re.search(r"(?i)(not found|error|failed|invalid)", errors):
            raise SystemExit(f"debugfs dump failed for {path}: {errors}")
        return digest.hexdigest()

    removals, inodes = [], set()
    for base, name in GROUPS:
        for path in (f"{base}/{name}/{name}.apk",
                     f"{base}/{name}/oat/x86_64/{name}.odex",
                     f"{base}/{name}/oat/x86_64/{name}.vdex"):
            inode, size = read_stat(product, path)
            if inode < 12 or inode in inodes:
                raise SystemExit(f"invalid or duplicate inode: {path}")
            inodes.add(inode)
            removals.append({"path": path, "inode": inode, "logical_bytes": size})

    protected = {}
    for path in PROTECTED:
        _, size = read_stat(product, path)
        protected[path] = {"logical_bytes": size, "sha256": content_hash(product, path, size)}

    out_product, out_disk = output / "product.img", output / "system.img"
    product_digest = hashlib.sha256()
    with disk.open("rb") as ds, product.open("rb") as ps, out_product.open("xb") as dst:
        ds.seek(OFFSET)
        while chunk := ps.read(CHUNK):
            if ds.read(len(chunk)) != chunk:
                raise SystemExit("product does not match the system image extent")
            product_digest.update(chunk)
            dst.write(chunk)
    if product_digest.hexdigest() != PRODUCT_SHA256:
        raise SystemExit("product SHA-256 differs from the known baseline")
    if out_product.samefile(product):
        raise SystemExit("product output unexpectedly aliases its input")

    before = command("product-before", [args.dumpe2fs, "-h", product]).stdout
    commands = output / "removal.debugfs"
    commands.write_text("".join(f"unlink {item['path']}\nclri <{item['inode']}>\n" for item in removals),
                        encoding="ascii")
    result = command("debugfs", [args.debugfs, "-w", "-f", commands, out_product])
    if re.search(r"(?i)(not found|error|failed|invalid)", result.stdout + result.stderr):
        raise SystemExit("debugfs reported a failure")
    # The source ext4 uses shared_blocks. Never use debugfs rm: rebuild the
    # allocation bitmap before zeroing only blocks known to be free.
    command("repair", [args.e2fsck, "-fy", out_product], accepted=(0, 1))
    command("zerofree", [zerofree, out_product])
    command("check", [args.e2fsck, "-fn", out_product])
    after = command("product-after", [args.dumpe2fs, "-h", out_product]).stdout

    for item in removals:
        result = subprocess.run([args.rtk, "proxy", args.debugfs, "-R", f"stat {item['path']}",
                                 str(out_product)], capture_output=True, text=True)
        if result.returncode or "File not found by ext2_lookup" not in result.stderr:
            raise SystemExit(f"could not verify removed file is absent: {item['path']}")
    for path, item in protected.items():
        _, size = read_stat(out_product, path)
        if size != item["logical_bytes"] or content_hash(out_product, path, size) != item["sha256"]:
            raise SystemExit(f"protected file differs after removal: {path}")

    def number(output_text, field):
        match = re.search(rf"^{re.escape(field)}:\s*(\d+)", output_text, re.MULTILINE)
        if not match:
            raise SystemExit(f"missing filesystem statistic: {field}")
        return int(match.group(1))

    disk_digest = hashlib.sha256()
    with disk.open("rb") as src, out_disk.open("xb") as dst:
        while chunk := src.read(CHUNK):
            dst.write(chunk)
            disk_digest.update(chunk)
    if disk_digest.hexdigest() != DISK_SHA256 or out_disk.samefile(disk):
        raise SystemExit("disk hash or output identity differs from expected baseline")
    with out_disk.open("r+b") as ds, out_product.open("rb") as ps:
        ds.seek(OFFSET)
        shutil.copyfileobj(ps, ds, CHUNK)

    result = {
        "status": "experimental; filesystem and protected files checked; boot not yet tested",
        "source_system_sha256": DISK_SHA256,
        "source_product_sha256": PRODUCT_SHA256,
        "product_offset": OFFSET,
        "product_length": SIZE,
        "removed_files": removals,
        "removed_logical_bytes": sum(item["logical_bytes"] for item in removals),
        "protected_files_sha256": protected,
        "free_blocks_before": number(before, "Free blocks"),
        "free_blocks_after": number(after, "Free blocks"),
        "block_size": number(after, "Block size"),
        "limitations": "logical lengths and freed ext4 blocks do not equal installer savings; no performance claim",
    }
    (output / "manifest.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
