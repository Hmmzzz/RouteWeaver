#!/usr/bin/env python3
"""Reproduce RouteWeaver's pinned domestic DNS suffix list (Python 3.9+).

Example (all paths are supplied by the caller):
    python3 build_domestic_domains.py --source /path/to/domain-list-community \
        --psl /path/to/public_suffix_list.dat --output /path/to/domestic-domains.txt

This tool is offline: it never downloads, updates its inputs, or applies DNS or
route configuration. Both the complete data tree and PSL bytes are pinned. A
Git checkout must also have the pinned HEAD; a source archive is authenticated
by the same data-tree and license hashes. Updating the upstream version requires
an explicit review and update of these pins and the expected output hash.

The list contains literal domain suffixes, not exact-host rules. Nested @!cn
rules cannot subtract names from an included parent suffix. Address eligibility
and DNS fallback must be enforced separately by the runtime helper.
"""

import argparse
from collections import Counter
from functools import lru_cache
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


SOURCE_REPOSITORY = "https://github.com/v2fly/domain-list-community"
SOURCE_COMMIT = "e8f6d1e5c4a01cda943c0784ffa834340eeab5ae"
# SHA-256 of sorted UTF-8 rows: filename + NUL + SHA256(file bytes) + LF.
DATA_TREE_SHA256 = "ef70ca6fa0b892000672ffee23f2911855ee0d643e34e1ab9d73a22881f83cf4"
SOURCE_LICENSE_SHA256 = "b9d84a22870d3f21c91a4c6e410c9cc51d00902f5233ad0c84011479244bf7d2"
PSL_SHA256 = "8228e4bdac6024c058a1e67859157e468a2613b826b53de0e5cae298e1b70755"
OUTPUT_SHA256 = "a714c11aa381eff872ef7dc93af5f69deb8e429ab94da42a5e50adf3029fc321"
OUTPUT_COUNT = 7726

FOREIGN_GROUPS = (
    "apple", "microsoft", "google", "github", "openai", "anthropic",
    "cloudflare", "aws", "aws-cn", "amazon", "facebook", "meta", "netflix",
    "spotify", "dropbox", "telegram", "discord", "tailscale", "adobe",
    "paypal", "visa", "mastercard", "zoom", "slack", "notion",
)
EXPLICIT_FOREIGN = {
    "ts.net", "tailscale.com", "tailscale.io", "openai.com", "chatgpt.com",
    "github.com", "githubusercontent.com", "apple.com", "apple.cn",
    "apple.com.cn", "microsoft.com", "google.com", "cloudflare.com",
}
SHARED_NAMESPACES = {
    "myqcloud.com", "aliyuncs.com", "amazonaws.com", "cloudfront.net",
    "azureedge.net", "windows.net", "github.io", "workers.dev", "pages.dev",
    "vercel.app", "netlify.app", "onrender.com", "herokuapp.com", "appspot.com",
    "cloudfunctions.net", "myhuaweicloud.com", "myhuaweicloud.cn",
    "myhuaweicloud.com.cn", "tencentcos.com", "tencentcos.cn",
    "tencentcos.com.cn", "tripcdn.com",
}
DOMAIN_LITERAL = re.compile(
    r"(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+"
    r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
)


def sha256(payload):
    return hashlib.sha256(payload).hexdigest()


def require_hash(label, payload, expected):
    actual = sha256(payload)
    if actual != expected:
        raise ValueError(f"{label} SHA-256 mismatch: expected {expected}, got {actual}")


def load_inputs(source, psl_path):
    """Verify inputs before parsing; retain verified bytes to avoid rereading."""
    git_checkout = (source / ".git").exists()
    if git_checkout:
        try:
            result = subprocess.run(
                ["git", "-C", str(source), "rev-parse", "--verify", "HEAD"],
                check=True, capture_output=True, text=True,
            )
        except (OSError, subprocess.CalledProcessError) as error:
            raise ValueError(f"Cannot verify source Git HEAD: {error}") from error
        actual_commit = result.stdout.strip()
        if actual_commit != SOURCE_COMMIT:
            raise ValueError(
                f"Source commit mismatch: expected {SOURCE_COMMIT}, got {actual_commit}"
            )

    require_hash("source MIT license", (source / "LICENSE").read_bytes(), SOURCE_LICENSE_SHA256)
    data = {}
    for path in sorted((source / "data").iterdir(), key=lambda item: item.name):
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Source data entry must be a regular file: {path}")
        data[path.name] = path.read_bytes()
    manifest = "".join(name + "\0" + sha256(payload) + "\n" for name, payload in data.items())
    require_hash("complete source data tree", manifest.encode("utf-8"), DATA_TREE_SHA256)
    psl_bytes = psl_path.read_bytes()
    require_hash("Public Suffix List", psl_bytes, PSL_SHA256)
    return (
        {name: payload.decode("utf-8") for name, payload in data.items()},
        psl_bytes.decode("utf-8"),
        git_checkout,
    )


def matches(domain, suffixes):
    labels = domain.split(".")
    return any(".".join(labels[index:]) in suffixes for index in range(len(labels)))


def build(data, psl_text):
    @lru_cache(None)
    def expand(name):
        result = []
        for line in data[name].splitlines():
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            head, *attributes = line.split()
            attributes = tuple(sorted(attribute[1:] for attribute in attributes))
            if head.startswith("include:"):
                for row in expand(head[8:]):
                    if all(
                        attribute[1:] not in row[2] if attribute.startswith("-")
                        else attribute in row[2]
                        for attribute in attributes
                    ):
                        result.append(row)
            else:
                kind, value = head.split(":", 1) if ":" in head else ("domain", head)
                result.append((kind, value.lower().rstrip("."), attributes))
        return tuple(result)

    all_rows = expand("geolocation-cn")
    foreign_domains = set(EXPLICIT_FOREIGN)
    for group in FOREIGN_GROUPS:
        if group in data:
            foreign_domains.update(row[1] for row in expand(group) if row[0] == "domain")
    public_suffixes = set()
    for line in psl_text.splitlines():
        if not line or line.startswith("//"):
            continue
        line = line.removeprefix("!").removeprefix("*.")
        try:
            public_suffixes.add(line.encode("idna").decode("ascii"))
        except UnicodeError:
            continue

    removed = Counter()
    chosen = set()
    for kind, domain, attributes in all_rows:
        if kind != "domain":
            removed["unsupported_" + kind] += 1
        elif "." not in domain:
            removed["single_label"] += 1
        elif not DOMAIN_LITERAL.fullmatch(domain):
            removed["invalid_literal"] += 1
        else:
            try:
                ipaddress.ip_address(domain)
            except ValueError:
                pass
            else:
                removed["ip_literal"] += 1
                continue
            if "!cn" in attributes:
                removed["non_cn_attribute"] += 1
            elif matches(domain, foreign_domains):
                removed["foreign_vendor"] += 1
            elif domain in public_suffixes:
                removed["public_suffix"] += 1
            elif matches(domain, SHARED_NAMESPACES):
                removed["shared_customer_namespace"] += 1
            else:
                chosen.add(domain)

    kept = set()
    for domain in sorted(chosen, key=lambda item: (item.count("."), item)):
        if not matches(domain, kept):
            kept.add(domain)
    payload = ("\n".join(sorted(kept)) + "\n").encode("ascii")
    require_hash("generated suffix list", payload, OUTPUT_SHA256)
    if len(kept) != OUTPUT_COUNT:
        raise ValueError(f"Expected {OUTPUT_COUNT} suffixes, got {len(kept)}")
    return payload, {
        "source_expanded_records": len(all_rows),
        "removed_record_counts": dict(sorted(removed.items())),
        "candidate_before_parent_collapse": len(chosen),
        "redundant_children_removed": len(chosen) - len(kept),
        "suffix_count": len(kept),
    }


def write_output(path, payload):
    """Replace only the explicitly requested output after all checks succeed."""
    if not path.parent.is_dir():
        raise ValueError(f"Output parent directory does not exist: {path.parent}")
    if path.is_file() and path.read_bytes() == payload:
        return "unchanged"
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix="." + path.name + ".", delete=False) as file:
            temporary = Path(file.name)
            file.write(payload)
            file.flush()
            os.fsync(file.fileno())
        temporary.chmod(0o644)
        os.replace(temporary, path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()
    return "written"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", required=True, type=Path, help="Pinned v2fly checkout/archive root containing data/ and LICENSE")
    parser.add_argument("--psl", required=True, type=Path, help="Pinned public_suffix_list.dat (exact bytes required)")
    parser.add_argument("--output", required=True, type=Path, help="Destination UTF-8 suffix-list file; parent must exist")
    args = parser.parse_args()
    try:
        source = args.source.expanduser().resolve(strict=True)
        psl_path = args.psl.expanduser().resolve(strict=True)
        output = args.output.expanduser().absolute()
        if output.is_symlink():
            raise ValueError("Output must not be a symbolic link")
        output = output.resolve()
        if source == output or source in output.parents or output == psl_path:
            raise ValueError("Output must be outside the source checkout and must not overwrite PSL")
        data, psl_text, git_checkout = load_inputs(source, psl_path)
        payload, stats = build(data, psl_text)
        status = write_output(output, payload)
    except (OSError, ValueError, KeyError, RecursionError) as error:
        parser.exit(1, f"error: {error}\n")
    print(json.dumps({
        "source_repository": SOURCE_REPOSITORY,
        "source_commit": SOURCE_COMMIT,
        "git_head_verified": git_checkout,
        "source_data_tree_sha256": DATA_TREE_SHA256,
        "psl_sha256": PSL_SHA256,
        "output": str(output),
        "output_status": status,
        "output_sha256": sha256(payload),
        "output_bytes": len(payload),
        **stats,
    }, indent=2))


if __name__ == "__main__":
    main()
