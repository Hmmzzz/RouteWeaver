#!/usr/bin/env python3
"""Rebuild the bundled CN IPv4 file from the pinned APNIC archive, offline.

Accepts the official .gz archive or its unmodified decompressed bytes. Uses
allocation-country records, not IP geolocation. No network or system changes.
"""

import argparse
import gzip
import hashlib
import ipaddress
from pathlib import Path

SOURCE_URL = "https://ftp.apnic.net/stats/apnic/2026/delegated-apnic-20261021.gz"
ARCHIVE_SHA256 = "d9832f96d3ba99c3b3468bd4713e08d274afd3c7f51c0ad52ffddcfa2d9cafa6"
SOURCE_SHA256 = "9905a8dad583cbee6e8685761822b1e7b3fcd9099b204d6962fc41fea0522ea3"
OUTPUT_SHA256 = "a9459dce5ce38670c434b0d4e611f4f9fe74b59e141d300eaece1544fcd30179"
OUTPUT_COUNT = 5499
HEADER = "# APNIC CN IPv4\n# Source: https://ftp.apnic.net/stats/apnic/delegated-apnic-latest\n# Retrieved: 2026-10-20\n"


def require_hash(data, expected, label):
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected:
        raise ValueError(f"{label} SHA-256 mismatch: expected {expected}, got {actual}")


def rebuild(source):
    if source.startswith(b"\x1f\x8b"):
        require_hash(source, ARCHIVE_SHA256, "archive")
        source = gzip.decompress(source)
    require_hash(source, SOURCE_SHA256, "source")
    networks = []
    for line in source.decode("utf-8").splitlines():
        fields = line.strip().split("|")
        if len(fields) < 7 or fields[:3] != ["apnic", "CN", "ipv4"]:
            continue
        if fields[6] not in ("allocated", "assigned"):
            continue
        first = ipaddress.IPv4Address(fields[3])
        count = int(fields[4])
        if count <= 0:
            raise ValueError("APNIC allocation count must be positive")
        last = ipaddress.IPv4Address(int(first) + count - 1)
        networks.extend(ipaddress.summarize_address_range(first, last))
    # Match APNICParser's union of ranges followed by minimal CIDR expansion.
    rows = [str(network) for network in ipaddress.collapse_addresses(networks)]
    if len(rows) != OUTPUT_COUNT:
        raise ValueError(f"Expected {OUTPUT_COUNT} CIDRs, got {len(rows)}")
    output = (HEADER + "\n".join(rows) + "\n").encode("utf-8")
    require_hash(output, OUTPUT_SHA256, "output")
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        output = rebuild(args.source.read_bytes())
        # Never overwrite an existing destination; caller chooses a fresh file.
        with args.output.open("xb") as target:
            target.write(output)
    except (OSError, ValueError, EOFError) as error:
        parser.exit(1, f"error: {error}\n")
    print(f"Verified {OUTPUT_COUNT} CIDRs; SHA-256 {OUTPUT_SHA256}")


if __name__ == "__main__":
    main()
