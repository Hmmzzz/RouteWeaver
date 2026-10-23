#!/usr/bin/env python3
"""Explicit live integration test. Requires installed authorized service and active exit node.
Tests refuse to replace any enabled policy or nonempty journal state. Always stop in finally.
"""
import json, pathlib, subprocess, sys, time
from live_service_session import LiveServiceSession, cleanup_confirmed, require
root = pathlib.Path(__file__).resolve().parents[1]
app = root / 'dist/RouteWeaver.app/Contents/MacOS/RouteWeaver'
log = []
session = None

def call(command, routes=None):
    response = session.request(command, routes)
    log.append({'time': time.time(), 'command': command, 'response': response})
    if response['failed']:
        raise RuntimeError(response['message'])
    return response

def wait_active(count):
    deadline = time.monotonic() + 50
    while time.monotonic() < deadline:
        result = call('status')
        if result['phase'] == 'active':
            require(result['verified'] and result['active'] == count, result)
            return result
        time.sleep(1)
    raise RuntimeError('Service did not become active')

def route_get(address):
    result = subprocess.run(['/sbin/route', '-n', 'get', address], capture_output=True, text=True, check=True)
    return dict(line.strip().split(': ', 1) for line in result.stdout.splitlines() if ': ' in line)

def validate():
    initial = call('status')
    require(cleanup_confirmed(initial), 'Refusing to replace active, pending, or unverified network state')
    require(not initial.get('anotherSessionActive'), 'Exit the GUI before running this fixture')
    before = route_get('223.5.5.254')
    baseline_probe = route_get('8.8.8.8')
    print('Initial service disabled, no owned routes; beginning scoped /32 test.', flush=True)
    attached = call('attach')
    require(attached.get('sessionAttached') is True and cleanup_confirmed(attached), 'State changed before attaching')
    try:
        call('apply', ['223.5.5.254/32'])
        first = wait_active(1)
        after = route_get('223.5.5.254')
        require(after.get('gateway') == first['gateway'] and after.get('interface') == first['interface'], after)
        repeated = call('apply', ['223.5.5.254/32'])
        require(repeated['phase'] == 'active' and repeated['active'] == 1, repeated)
        stopped = call('stopOwned')
        require(cleanup_confirmed(stopped) and stopped['removed'] == 1, stopped)
        restored = route_get('223.5.5.254')
        require(restored.get('interface') == before.get('interface') and restored.get('gateway') == before.get('gateway'), restored)
        print('PASS: /32 add, verified physical gateway, idempotent apply, rollback and original path restored.', flush=True)
        if '--full' in sys.argv:
            routes = [line for line in (root/'Sources/RouteWeaver/Resources/cn-ipv4.txt').read_text().splitlines() if line and not line.startswith('#')]
            call('apply', routes)
            result = wait_active(len(routes))
            probe = route_get('8.8.8.8')
            require(probe.get('interface') == baseline_probe.get('interface'), probe)
            print(f"PASS: {result['active']} routes verified, apply {result['durationMilliseconds']} ms; exit-node probe remains on tunnel.", flush=True)
            stopped = call('stopOwned')
            require(cleanup_confirmed(stopped) and stopped['removed'] == len(routes), stopped)
            print(f"PASS: full rollback {stopped['durationMilliseconds']} ms, no owned/pending routes.", flush=True)
    finally:
        try:
            cleanup = call('stopOwned')
            require(cleanup_confirmed(cleanup) and not cleanup.get('anotherSessionActive'), cleanup)
        finally:
            destination = root / 'work/validation/live-validation.json'
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(json.dumps(log, ensure_ascii=False, indent=2))
            print(f'Validation evidence: {destination}', flush=True)

def main():
    global session
    with LiveServiceSession([str(app)]) as session:
        validate()


if __name__ == '__main__':
    main()
