#!/usr/bin/env python3
"""Measure XZ stream sizes without creating additional compressed images.

Run each image with the same XZ executable and settings.  These sizes are a
controlled comparison, not the size of an installer produced by Inno Setup.
"""

import argparse
import json
import pathlib
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rtk", default="rtk")
    parser.add_argument("--xz", default="xz")
    parser.add_argument("images", nargs="+")
    args = parser.parse_args()
    for filename in args.images:
        path = pathlib.Path(filename)
        started = time.monotonic()
        command = [args.rtk, "proxy", args.xz, "-0", "-T4", "--stdout", str(path)]
        count = 0
        with subprocess.Popen(command, stdout=subprocess.PIPE) as process:
            while True:
                chunk = process.stdout.read(1024 * 1024)
                if not chunk:
                    break
                count += len(chunk)
            status = process.wait()
        if status:
            raise RuntimeError(f"xz failed with exit status {status}: {path}")
        print(json.dumps({"image": str(path), "raw_bytes": path.stat().st_size,
                          "xz_bytes": count, "xz_options": "-0 -T4",
                          "seconds": round(time.monotonic() - started, 2)}), flush=True)


if __name__ == "__main__":
    main()
