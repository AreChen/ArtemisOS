#!/usr/bin/env python3
"""Read-only inventory of app files in an ext4 product partition.

File lengths are logical lengths, not exclusive ext4 disk usage; shared blocks
and compression mean these numbers are not estimates of reclaimable bytes.
"""
import argparse
import json
import re
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    parser.add_argument("--rtk", default="rtk")
    parser.add_argument("--debugfs", default="debugfs")
    args = parser.parse_args()
    image = args.image.resolve(strict=True)
    if not image.is_file():
        parser.error("input must be a regular, detached ext4 image")
    with image.open("rb") as stream:
        stream.seek(1080)
        if stream.read(2) != b"\x53\xef":
            parser.error("input is not an ext4 filesystem image")

    entries = []

    def visit(path, group):
        result = subprocess.run(
            [args.rtk, "proxy", args.debugfs, "-R", f"ls -p -l {path}", str(image)],
            check=True, capture_output=True, text=True,
        )
        parsed = []
        for line in result.stdout.splitlines():
            if not line:
                continue
            match = re.fullmatch(r"/(\d+)/([0-7]+)/\d+/\d+/([^/]+)/([0-9]*)/", line)
            if not match:
                raise SystemExit(f"Unexpected debugfs listing at {path}: {line!r}")
            inode, mode, name, size = match.groups()
            parsed.append((int(inode), int(mode, 8), name, size))
        if not parsed or not any(e[2] == "." for e in parsed):
            raise SystemExit(f"Could not list {path}: {result.stderr}")
        for inode, mode, name, size in parsed:
            if name in (".", ".."):
                continue
            if not re.fullmatch(r"[A-Za-z0-9._+-]+", name):
                raise SystemExit(f"Unsupported filename in {path}: {name!r}")
            child = f"{path}/{name}"
            kind = mode & 0o170000
            child_group = group or child
            if kind == 0o040000:
                visit(child, child_group)
            elif kind == 0o100000:
                entries.append({"group": child_group, "path": child,
                                "inode": inode, "logical_bytes": int(size)})

    for root in ("/app", "/priv-app"):
        visit(root, None)
    groups = {}
    for entry in entries:
        group = groups.setdefault(entry["group"], {"logical_bytes": 0, "files": []})
        group["logical_bytes"] += entry["logical_bytes"]
        group["files"].append({k: v for k, v in entry.items() if k != "group"})
    print(json.dumps({"source": str(image), "basis": "ext4 logical file sizes; not exclusive usage",
                      "groups": groups}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
