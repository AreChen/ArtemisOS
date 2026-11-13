#!/usr/bin/env python3
"""Read-only GPT, dynamic partition and ext4 usage inspection for the pilot.

Uses standard Python only. The GPT and dynamic metadata checksums are checked;
multi-extent/non-ext4 partitions report their lengths without ext4 usage. Usage
is a filesystem block count, not a compressed download or host disk estimate.
"""
import argparse
import hashlib
import json
import struct
import zlib
from pathlib import Path

SECTOR = 512


def read_at(stream, offset, count):
    stream.seek(offset)
    value = stream.read(count)
    if len(value) != count:
        raise ValueError("truncated image")
    return value


def checked_sha(data, start, stop):
    expected = data[start:stop]
    zeroed = bytearray(data)
    zeroed[start:stop] = bytes(stop - start)
    if hashlib.sha256(zeroed).digest() != expected:
        raise ValueError("metadata SHA-256 mismatch")


def gpt_entries(stream):
    raw = read_at(stream, SECTOR, SECTOR)
    if raw[:8] != b"EFI PART":
        raise ValueError("image does not contain GPT")
    size, expected_crc = struct.unpack_from("<II", raw, 12)
    if not 92 <= size <= SECTOR:
        raise ValueError("unexpected GPT header size")
    header = bytearray(raw[:size])
    header[16:20] = b"\0" * 4
    if zlib.crc32(header) != expected_crc:
        raise ValueError("GPT header CRC mismatch")
    entry_lba, count, entry_size, entries_crc = struct.unpack_from("<QIII", raw, 72)
    if count > 4096 or not 128 <= entry_size <= 4096:
        raise ValueError("unexpected GPT partition table size")
    entries = read_at(stream, entry_lba * SECTOR, count * entry_size)
    if zlib.crc32(entries) != entries_crc:
        raise ValueError("GPT entries CRC mismatch")
    result = []
    for index in range(count):
        entry = entries[index * entry_size : (index + 1) * entry_size]
        if entry[:16] == bytes(16):
            continue
        first, last = struct.unpack_from("<QQ", entry, 32)
        if last < first:
            raise ValueError("invalid GPT entry extent")
        result.append({"name": entry[56:128].decode("utf-16-le").split("\0", 1)[0],
                       "offset": first * SECTOR, "length": (last - first + 1) * SECTOR})
    return result


def ext4_usage(stream, offset):
    sb = read_at(stream, offset + 1024, 1024)
    if sb[56:58] != b"\x53\xef":
        return None
    blocks, free, log_block = (struct.unpack_from("<I", sb, i)[0] for i in (4, 12, 24))
    if log_block > 6:
        raise ValueError("unexpected ext4 block size")
    incompat = struct.unpack_from("<I", sb, 96)[0]
    if incompat & 0x80:
        blocks |= struct.unpack_from("<I", sb, 336)[0] << 32
        free |= struct.unpack_from("<I", sb, 344)[0] << 32
    if free > blocks:
        raise ValueError("invalid ext4 free count")
    block_size = 1024 << log_block
    return {"block_size": block_size, "filesystem_bytes": blocks * block_size,
            "free_bytes": free * block_size, "used_bytes": (blocks - free) * block_size}


def inspect_system(path, super_offset):
    with path.open("rb") as stream:
        gpt = gpt_entries(stream)
        matching = [entry for entry in gpt if entry["offset"] == super_offset]
        if len(matching) != 1:
            raise ValueError("super offset is not a GPT partition boundary")
        geometry = read_at(stream, super_offset + 4096, 52)
        magic, geometry_size = struct.unpack_from("<II", geometry)
        if magic != 0x616C4467 or geometry_size != 52:
            raise ValueError("unsupported dynamic-partition geometry")
        checked_sha(geometry, 8, 40)
        max_size, slots, block_size = struct.unpack_from("<III", geometry, 40)
        if max_size < 128 or max_size > 16 * 1024 * 1024 or not 1 <= slots <= 4:
            raise ValueError("unsupported dynamic-partition metadata dimensions")
        meta_offset = super_offset + 4096 + 2 * 4096
        initial = read_at(stream, meta_offset, 128)
        magic, major, minor, size = struct.unpack_from("<IHHI", initial)
        if magic != 0x414C5030 or major != 10 or size < 128 or size > max_size:
            raise ValueError("unsupported dynamic-partition metadata version")
        header = read_at(stream, meta_offset, size)
        checked_sha(header, 12, 44)
        tables_size = struct.unpack_from("<I", header, 44)[0]
        if size + tables_size > max_size:
            raise ValueError("dynamic-partition tables exceed metadata size")
        tables = read_at(stream, meta_offset + size, tables_size)
        if hashlib.sha256(tables).digest() != header[48:80]:
            raise ValueError("dynamic-partition tables SHA-256 mismatch")
        p_offset, p_count, p_size = struct.unpack_from("<III", header, 80)
        e_offset, e_count, e_size = struct.unpack_from("<III", header, 92)
        if p_size < 52 or e_size < 24 or p_count > 1000 or e_count > 10000:
            raise ValueError("unexpected dynamic table entries")
        if p_offset + p_count * p_size > tables_size or e_offset + e_count * e_size > tables_size:
            raise ValueError("dynamic table outside checksummed region")
        partitions = []
        for index in range(p_count):
            pos = p_offset + index * p_size
            name, attributes, first, count, group = struct.unpack_from("<36sIIII", tables, pos)
            if first + count > e_count:
                raise ValueError("partition references nonexistent extents")
            extents = []
            for eindex in range(first, first + count):
                sectors, target_type, sector, source = struct.unpack_from("<QIQI", tables, e_offset + eindex * e_size)
                extents.append({"length": sectors * SECTOR, "target_type": target_type,
                                "source": source, "offset": super_offset + sector * SECTOR if target_type == 0 else None})
            record = {"name": name.split(b"\0", 1)[0].decode("ascii"), "attributes": attributes,
                      "group": group, "length": sum(e["length"] for e in extents), "extents": extents}
            if len(extents) == 1 and extents[0]["target_type"] == 0 and extents[0]["source"] == 0:
                entry = extents[0]
                if entry["offset"] < super_offset or entry["offset"] + entry["length"] > super_offset + matching[0]["length"]:
                    raise ValueError("dynamic extent falls outside GPT partition")
                record["ext4"] = ext4_usage(stream, entry["offset"])
            partitions.append(record)
        return {"gpt": gpt, "geometry": {"metadata_max_size": max_size, "slots": slots,
                                        "block_size": block_size, "metadata_version": f"{major}.{minor}"},
                "partitions": partitions}


def inspect_vendor(path):
    with path.open("rb") as stream:
        entries = gpt_entries(stream)
        for entry in entries:
            entry["ext4"] = ext4_usage(stream, entry["offset"])
        return {"gpt": entries}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--system", type=Path, required=True)
    parser.add_argument("--vendor", type=Path, required=True)
    parser.add_argument("--super-offset", type=int, default=2_097_152)
    args = parser.parse_args()
    system, vendor = args.system.resolve(strict=True), args.vendor.resolve(strict=True)
    result = {"system_image": str(system), "vendor_image": str(vendor),
              "note": "ext4 counts are filesystem allocation, not compressed sizes or measured host disk usage",
              "system": inspect_system(system, args.super_offset), "vendor": inspect_vendor(vendor)}
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
