#!/usr/bin/env python3
"""Recreate the pinned publicsuffix.org export from its fixed Git source.

Offline: only adds the verified website VERSION/COMMIT header. Neither suffix
rules nor the original MPL notice are changed. Output is validated bytewise.
"""

import argparse
import hashlib
from pathlib import Path

COMMIT = "5dd321ffe02039e2431382a095cf80e27ff5eb94"
VERSION = "2026-10-20_08-40-56_UTC"
SOURCE_SHA256 = "9b4827a9e428a0192a9ea0a6b7804a4cc653d5f39a03456d3b17447b86d78de9"
OUTPUT_SHA256 = "8228e4bdac6024c058a1e67859157e468a2613b826b53de0e5cae298e1b70755"


def prepare(source):
    actual = hashlib.sha256(source).hexdigest()
    if actual != SOURCE_SHA256:
        raise ValueError(f"Git source SHA-256 mismatch: {actual}")
    marker = b"// Instructions on pulling"
    header = f"// VERSION: {VERSION}\n// COMMIT: {COMMIT}\n\n".encode("ascii")
    output = source.replace(marker, header + marker, 1)
    actual = hashlib.sha256(output).hexdigest()
    if actual != OUTPUT_SHA256:
        raise ValueError(f"Website export SHA-256 mismatch: {actual}")
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        output = prepare(args.source.read_bytes())
        with args.output.open("xb") as target:
            target.write(output)
    except (OSError, ValueError) as error:
        parser.exit(1, f"error: {error}\n")
    print(f"Verified PSL website export; SHA-256 {OUTPUT_SHA256}")


if __name__ == "__main__":
    main()
