#!/usr/bin/env python3
"""Generate, but do not run, debugfs removal commands for the lab image.

The verified partition is opened read-only. The generated commands must only
be applied to a separate disposable copy, followed by an ext4 allocation-map
repair. This is an experiment, not a general-purpose Android image builder.
"""

import argparse
import hashlib
import re
import subprocess
from pathlib import Path

PRODUCT_SIZE = 2_144_882_688
PRODUCT_SHA256 = "6d96ca62024b634a46730e1be79771ff3a8a49acfdcca0aebd8d459822b254c7"
OPTIONAL_APPS = ("Drive", "Maps", "Photos", "PrebuiltGmail", "YouTube", "YouTubeMusicPrebuilt")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--product-image", type=Path, required=True, help="detached product image to inspect read-only")
    parser.add_argument("--output", type=Path, required=True, help="new command file inside this project's build directory")
    args = parser.parse_args()
    image = args.product_image.resolve(strict=True)
    output = args.output.resolve()
    build_root = (Path(__file__).resolve().parents[2] / "build").resolve()
    if not output.is_relative_to(build_root) or output == image:
        parser.error("output must be a new file under the project build directory")
    if image.stat().st_size != PRODUCT_SIZE:
        parser.error("unexpected product image size")

    # Verify ext4 geometry before consulting inode numbers. Exact package paths
    # and inodes are checked below; never infer them from another image version.
    with image.open("rb") as stream:
        stream.seek(1080)
        if stream.read(2) != b"\x53\xef":
            parser.error("product image does not contain the expected ext4 superblock")
        stream.seek(0)
        digest = hashlib.sha256()
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
        if digest.hexdigest() != PRODUCT_SHA256:
            parser.error("product image is not the exact version tested by this experiment")

    commands = []
    inodes = set()
    for name in OPTIONAL_APPS:
        paths = (f"/app/{name}/{name}.apk", f"/app/{name}/oat/x86_64/{name}.odex",
                 f"/app/{name}/oat/x86_64/{name}.vdex")
        for path in paths:
            result = subprocess.run(["rtk", "proxy", "debugfs", "-R", f"stat {path}", str(image)],
                                    check=True, capture_output=True, text=True)
            match = re.search(r"^Inode:\s*(\d+)\s+Type:\s+regular", result.stdout, re.MULTILINE)
            if not match:
                raise SystemExit(f"Expected regular file missing: {path}\n{result.stderr}")
            inode = int(match.group(1))
            if inode < 12 or inode in inodes:
                raise SystemExit(f"Unexpected inode {inode}: {path}")
            inodes.add(inode)
            # Unlike rm, unlink plus clri does not free blocks that may be
            # shared. e2fsck must recalculate allocation maps after the edits.
            commands.extend((f"unlink {path}", f"clri <{inode}>"))

    with output.open("x", encoding="ascii", newline="\n") as stream:
        stream.write("\n".join(commands) + "\n")
    print(f"Prepared {len(inodes)} file removals in {output}; no image was modified.")


if __name__ == "__main__":
    main()
