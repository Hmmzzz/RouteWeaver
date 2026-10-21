#!/usr/bin/env python3
"""Explicit live integration test. Requires installed authorized service and active exit node.
Tests refuse to replace any enabled policy or nonempty journal state. Always stop in finally.
"""
import base64, json, pathlib, subprocess, sys, time
root = pathlib.Path(__file__).resolve().parents[1]
app = root / 'dist/RouteWeaver.app/Contents/MacOS/RouteWeaver'
log = []

def call(command, routes=None):
    request = {'version': 1, 'command': command}
    if routes is not None:
        request['routes'] = routes
    encoded = base64.b64encode(json.dumps(request).encode()).decode()
    process = subprocess.run([str(app), '--service-command', encoded], capture_output=True, text=True, timeout=130)
    if process.returncode not in (0, 1):
        raise RuntimeError(process.stderr or process.stdout)
    response = json.loads(process.stdout)
    log.append({'time': time.time(), 'command': command, 'response': response})
    if response['failed']:
        raise RuntimeError(response['message'])
    return response

def wait_active(count):
    deadline = time.monotonic() + 50
    while time.monotonic() < deadline:
        result = call('status')
        if result['phase'] == 'active':
            assert result['verified'] and result['active'] == count, result
            return result
        time.sleep(1)
    raise RuntimeError('Service did not become active')

def route_get(address):
    result = subprocess.run(['/sbin/route', '-n', 'get', address], capture_output=True, text=True, check=True)
    return dict(line.strip().split(': ', 1) for line in result.stdout.splitlines() if ': ' in line)

def main():
    initial = call('status')
    assert not initial['enabled'] and initial['active'] == initial['pending'] == 0, 'Refusing to replace existing active/pending policy'
    before = route_get('223.5.5.254')
    baseline_probe = route_get('8.8.8.8')
    print('Initial service disabled, no owned routes; beginning scoped /32 test.', flush=True)
    try:
        call('apply', ['223.5.5.254/32'])
        first = wait_active(1)
        after = route_get('223.5.5.254')
        assert after.get('gateway') == first['gateway'] and after.get('interface') == first['interface'], after
        repeated = call('apply', ['223.5.5.254/32'])
        assert repeated['phase'] == 'active' and repeated['active'] == 1, repeated
        stopped = call('stop')
        assert not stopped['enabled'] and stopped['active'] == stopped['pending'] == 0 and stopped['removed'] == 1, stopped
        restored = route_get('223.5.5.254')
        assert restored.get('interface') == before.get('interface') and restored.get('gateway') == before.get('gateway'), restored
        print('PASS: /32 add, verified physical gateway, idempotent apply, rollback and original path restored.', flush=True)
        if '--full' in sys.argv:
            routes = [line for line in (root/'Sources/RouteWeaver/Resources/cn-ipv4.txt').read_text().splitlines() if line and not line.startswith('#')]
            call('apply', routes)
            result = wait_active(len(routes))
            probe = route_get('8.8.8.8')
            assert probe.get('interface') == baseline_probe.get('interface'), probe
            print(f"PASS: {result['active']} routes verified, apply {result['durationMilliseconds']} ms; exit-node probe remains on tunnel.", flush=True)
            stopped = call('stop')
            assert stopped['active'] == stopped['pending'] == 0 and stopped['removed'] == len(routes), stopped
            print(f"PASS: full rollback {stopped['durationMilliseconds']} ms, no owned/pending routes.", flush=True)
    finally:
        try:
            cleanup = call('stop')
            assert not cleanup['enabled'] and cleanup['active'] == cleanup['pending'] == 0, cleanup
        finally:
            destination = root / 'work/validation/live-validation.json'
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(json.dumps(log, ensure_ascii=False, indent=2))
            print(f'Validation evidence: {destination}', flush=True)

if __name__ == '__main__':
    main()
