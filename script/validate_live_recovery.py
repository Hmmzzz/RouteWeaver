#!/usr/bin/env python3
"""Root-only bounded recovery integration checks, with saved exit-node restoration.
Run only after validate_live_routes.py succeeds and the service is disabled.
"""
import json, os, pathlib, subprocess, time
from live_service_session import LiveServiceSession, cleanup_confirmed, require
root = pathlib.Path(__file__).resolve().parents[1]
app = root / 'dist/RouteWeaver.app/Contents/MacOS/RouteWeaver'
uid = gid = None
user = ts = []
log = []
session = None

def run(args, timeout=30):
    p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if p.returncode:
        raise RuntimeError(f'{args[0]} ({p.returncode}): {p.stderr[:500]} {p.stdout[:500]}')
    return p.stdout

def rpc(command, routes=None):
    response = session.request(command, routes)
    log.append({'time': time.time(), 'command':command, 'response':response})
    require(response['failed'] == 0, response)
    return response

def wait_for(predicate, seconds=55, tolerate_connection=False):
    until = time.monotonic()+seconds
    while time.monotonic()<until:
        try:
            result = rpc('status')
            if predicate(result): return result
        except (RuntimeError, AssertionError):
            if not tolerate_connection: raise
        time.sleep(1)
    raise RuntimeError('Recovery condition timed out')

def active(r): return r['phase']=='active' and r['active']==1 and r['pending']==0 and r['verified']
def route_get():
    value=run(['/sbin/route','-n','get','223.5.5.254'])
    return dict(line.strip().split(': ',1) for line in value.splitlines() if ': ' in line)

def emit(name, **values):
    log.append({'test':name, **values}); print(name, values, flush=True)

def validate():
    initial=rpc('status')
    require(cleanup_confirmed(initial), 'Refusing to replace active, pending, or unverified network state')
    require(not initial.get('anotherSessionActive'), 'Exit the GUI before running this fixture')
    prefs=json.loads(run(ts+['debug','prefs']))
    original_id=prefs.get('ExitNodeID')
    require(original_id and not prefs.get('ExitNodeIP'), 'This fixture requires a fixed selected exit node')
    status=json.loads(run(ts+['status','--json']))
    peer=next(p for p in status['Peer'].values() if p.get('ID')==original_id)
    restore_ip=next(ip for ip in peer['TailscaleIPs'] if ':' not in ip)
    needs_restore=False
    attached=rpc('attach')
    require(attached.get('sessionAttached') is True and cleanup_confirmed(attached), 'State changed before attaching')
    try:
        rpc('apply',['223.5.5.254/32'])
        state=wait_for(active)
        actual=route_get()
        require(actual.get('gateway')==state['gateway'] and actual.get('interface')==state['interface'], actual)
        # Deliberately remove this exact test route to imitate kernel loss while suspended.
        started=time.monotonic()
        run(['/sbin/route','-n','delete','-net','223.5.5.254/32',state['gateway']])
        require(route_get().get('gateway') != state['gateway'], 'Route was not removed')
        until=time.monotonic()+40
        while time.monotonic()<until and route_get().get('gateway') != state['gateway']: time.sleep(1)
        require(route_get().get('gateway')==state['gateway'], 'Missing route not repaired')
        wait_for(active)
        emit('PASS missing-kernel-route repair',seconds=round(time.monotonic()-started,2))
        # Restart must clear old ownership and disable saved intent. A live
        # client must explicitly reattach and apply before routing resumes.
        started=time.monotonic()
        run(['/bin/launchctl','kickstart','-k','system/com.routeweaver.helper'])
        time.sleep(1)
        disabled=wait_for(cleanup_confirmed,tolerate_connection=True)
        require(disabled.get('sessionAttached') is False, disabled)
        require(route_get().get('gateway') != state['gateway'], 'Old owned route survived restart')
        attached=rpc('attach')
        require(attached.get('sessionAttached') is True and cleanup_confirmed(attached), attached)
        rpc('apply',['223.5.5.254/32'])
        state=wait_for(active)
        require(route_get().get('gateway')==state['gateway'], "Validation failed: route_get().get('gateway')==state['gateway']")
        emit('PASS launchd restart cleanup and explicit session recovery',seconds=round(time.monotonic()-started,2))
        # Preserve every other preference; disable only the selected exit node, then restore it.
        needs_restore=True
        started=time.monotonic()
        run(ts+['set','--exit-node='])
        offline=wait_for(lambda r: r['enabled'] and r['active']==r['pending']==0 and r['phase']=='waitingNetwork')
        emit('PASS real exit-node disconnect cleanup',seconds=round(time.monotonic()-started,2))
        started=time.monotonic()
        run(ts+['set','--exit-node='+restore_ip])
        restored=json.loads(run(ts+['debug','prefs']))
        require({k:v for k,v in prefs.items() if 'ExitNode' in k} == {k:v for k,v in restored.items() if 'ExitNode' in k}, 'Exit preferences differ')
        needs_restore=False
        state=wait_for(active)
        require(state['exitNodeID']==original_id, "Validation failed: state['exitNodeID']==original_id")
        emit('PASS real exit-node reconnect recovery',seconds=round(time.monotonic()-started,2))
    finally:
        try:
            if needs_restore: run(ts+['set','--exit-node='+restore_ip])
        finally:
            try:
                stopped=rpc('stopOwned')
                require(cleanup_confirmed(stopped) and not stopped.get('anotherSessionActive'), stopped)
                emit('PASS final cleanup; policy disabled and no owned routes')
            finally:
                dest=root/'work/validation/live-recovery-validation.json'
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_text(json.dumps(log,ensure_ascii=False,indent=2))
                os.chown(dest,uid,gid)

def main():
    global session, uid, gid, user, ts
    uid, gid = app.stat().st_uid, app.stat().st_gid
    require(os.geteuid() == 0 and uid >= 500, 'Validation failed: os.geteuid() == 0 and uid >= 500')
    user = ['/bin/launchctl', 'asuser', str(uid), '/usr/bin/sudo', '-n', '-H', '-u', '#'+str(uid), '--']
    ts = user + ['/usr/bin/env', 'TAILSCALE_BE_CLI=1', '/Applications/Tailscale.app/Contents/MacOS/Tailscale']
    with LiveServiceSession(user+[str(app)]) as session:
        validate()


if __name__=='__main__': main()
