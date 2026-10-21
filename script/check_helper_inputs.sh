#!/usr/bin/env bash
# Validation-only checks. Refuses root execution, never requests authorization.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${1:-$ROOT_DIR/.build/debug/RouteWeaverHelper}"
[[ -x "$HELPER" ]] || { echo "Build RouteWeaverHelper first, or pass its executable path." >&2; exit 2; }
[[ "$(id -u)" != "0" ]] || { echo "This test must run as a non-root user." >&2; exit 2; }
/usr/bin/python3 - "$HELPER" <<'PY'
import base64, json, os, pathlib, subprocess, sys, tempfile
helper = sys.argv[1]
passed = 0

def reject(label, args, expected):
    global passed
    result = subprocess.run([helper] + args, capture_output=True, text=True, timeout=4)
    payload = json.loads(result.stdout)
    assert result.returncode != 0, (label, 'unexpected success', payload)
    assert payload['failed'] == 1 and payload['added'] == 0 and payload['removed'] == 0, (label, payload)
    assert expected in payload['message'], (label, payload['message'])
    passed += 1
    print('PASS ' + label)

valid = dict(routes=['223.5.5.0/24'], gateway='192.168.1.1', interface='en0', exitNodeID='validation-fixture')
def encoded(value):
    return base64.b64encode(json.dumps(value).encode()).decode()
reject('root guard / rollback', ['rollback'], '管理员授权')
reject('root guard / apply', ['apply', encoded(valid)], '管理员授权')
reject('unknown action', ['execute', '/bin/sh'], '不支持的操作')
reject('invalid base64', ['apply', '!!!'], '编码无效')
reject('default route blocked', ['apply', encoded(dict(valid, routes=['0.0.0.0/0']))], 'unsafeCIDR')
reject('Tailscale address blocked', ['apply', encoded(dict(valid, routes=['100.64.0.0/10']))], 'unsafeCIDR')
reject('untrusted tunnel gateway', ['apply', encoded(dict(valid, interface='utun0'))], '物理接口')
with tempfile.TemporaryDirectory(prefix='routeweaver-input-check-') as tmp:
    root = pathlib.Path(tmp)
    request = root / 'request.json'
    request.write_text(json.dumps(valid)); request.chmod(0o644)
    reject('public request file', ['check-file', str(request)], '0600')
    request.chmod(0o600)
    request.write_text(json.dumps(dict(valid, routes=['223.5.5.0/24'] * 20_001)))
    reject('excessive route count', ['check-file', str(request)], '路由数量')
    request.write_text(json.dumps(valid))
    symlink = root / 'symlink.json'; symlink.symlink_to(request)
    reject('symlink request', ['check-file', str(symlink)], '安全打开')
    hardlink = root / 'hardlink.json'; os.link(request, hardlink)
    reject('hardlinked request', ['check-file', str(request)], '0600')
    hardlink.unlink()
    request.write_bytes(b' ' * (1024 * 1024 + 1))
    reject('oversized request', ['check-file', str(request)], '大小不合法')
    request.write_text(json.dumps(dict(valid, routes=['127.0.0.0/8'])))
    reject('private file unsafe payload', ['check-file', str(request)], 'unsafeCIDR')
print(f'{passed} rejection checks passed. No administrator authorization or route mutations occurred.')
PY
