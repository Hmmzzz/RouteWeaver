#!/usr/bin/env bash
# Signed temporary fixtures only: no installed helper, authorization, or network.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/routeweaver-identity-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -module-cache-path "$CHECK_DIR/modules" \
  "$ROOT_DIR/Sources/RouteHelper/SignedCodeIdentity.swift" \
  "$ROOT_DIR/Tests/InstallerIdentityChecks/main.swift" -o "$CHECK_DIR/probe"
/usr/bin/codesign --force --sign - "$CHECK_DIR/probe" 2>/dev/null
python3 - "$CHECK_DIR" <<'PY'
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys

root = Path(sys.argv[1])
for mode in ('unchanged', 'replace-after-capture', 'replace-before-capture', 'replace-staged'):
    folder = root / mode
    folder.mkdir()
    executable = folder / 'installer'
    candidate = folder / 'staged' if mode == 'replace-staged' else executable
    shutil.copy2(root / 'probe', executable)
    if candidate != executable:
        shutil.copy2(executable, candidate)
    process = subprocess.Popen([str(executable), mode, str(candidate)],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True)
    try:
        if not select.select([process.stdout], [], [], 15)[0] or process.stdout.readline().strip() != 'READY':
            raise RuntimeError(f'{mode}: fixture did not become ready')
        if mode != 'unchanged':
            replacement = folder / 'replacement'
            shutil.copyfile('/usr/bin/true', replacement)
            replacement.chmod(0o755)
            os.replace(replacement, candidate)
        output, errors = process.communicate('CONTINUE\n', timeout=15)
        expected = 'ACCEPTED' if mode == 'unchanged' else 'REJECTED'
        if process.returncode != 0 or output.strip() != expected:
            raise RuntimeError(f'{mode}: unexpected result {process.returncode}: {output} {errors}')
        print(f'PASS installer identity: {mode}')
    finally:
        if process.poll() is None:
            process.kill()
        process.wait()
PY
