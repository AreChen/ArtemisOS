#!/usr/bin/env python3
"""Find and verify a detached product partition in a disk image, read-only."""
import argparse
import hashlib
import json
from pathlib import Path


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("disk", type=Path)
    p.add_argument("product", type=Path)
    args = p.parse_args()
    disk, product = args.disk.resolve(strict=True), args.product.resolve(strict=True)
    if disk.samefile(product):
        p.error("disk and detached partition must be different files")
    product_size = product.stat().st_size
    with product.open("rb") as source:
        sample = source.read(128 * 1024)
    if len(sample) != 128 * 1024 or sample[1080:1082] != b"\x53\xef":
        p.error("partition does not have the expected ext4 header")
    matches = []
    chunk_size = 8 * 1024 * 1024
    with disk.open("rb") as source:
        carry = b""
        offset = 0
        while chunk := source.read(chunk_size):
            data = carry + chunk
            start = 0
            while True:
                found = data.find(sample, start)
                if found < 0:
                    break
                matches.append(offset - len(carry) + found)
                start = found + 1
            carry = data[-(len(sample) - 1):]
            offset += len(chunk)
    if len(matches) != 1:
        raise SystemExit(f"expected a unique partition header, found {len(matches)}")
    extent = matches[0]
    if extent + product_size > disk.stat().st_size:
        raise SystemExit("partition extends beyond disk")
    digest = hashlib.sha256()
    with disk.open("rb") as disk_stream, product.open("rb") as product_stream:
        disk_stream.seek(extent)
        while chunk := product_stream.read(chunk_size):
            if disk_stream.read(len(chunk)) != chunk:
                raise SystemExit("candidate partition differs from disk extent")
            digest.update(chunk)
    print(json.dumps({"offset": extent, "length": product_size,
                      "product_sha256": digest.hexdigest(), "full_extent_verified": True}))


if __name__ == "__main__":
    main()
