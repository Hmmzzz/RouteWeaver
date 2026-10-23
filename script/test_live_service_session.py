#!/usr/bin/env python3
"""Offline regression checks; never start the real app or modify networking."""

import contextlib
import io
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from live_service_session import LiveServiceSession, cleanup_confirmed
import validate_live_routes as routes_fixture
import validate_live_recovery as recovery_fixture


FAKE_APP = r'''
import base64, json, os, pathlib, sys, time
evidence = pathlib.Path(sys.argv[1])
mode = sys.argv[2]
assert sys.argv[3:] == ['--service-session']
attached = False
def record(command):
    with evidence.open('a') as out:
        out.write(json.dumps({'command': command, 'pid': os.getpid()}) + '\n')
try:
    for raw in sys.stdin.buffer:
        request = json.loads(base64.b64decode(raw))
        command = request['command']
        record(command)
        if mode == 'timeout':
            sys.stdout.write('{"version":'); sys.stdout.flush()
            time.sleep(0.5)
            break
        if mode == 'oversize':
            sys.stdout.write('x' * 1_048_577); sys.stdout.flush()
            break
        if mode == 'invalid':
            sys.stdout.write('[]\n'); sys.stdout.flush()
            continue
        if mode == 'exit':
            sys.stderr.write('fixture transport closed\n'); sys.stderr.flush()
            break
        failed = 0
        if command == 'attach': attached = True
        if command == 'apply' and not attached: failed = 1
        response = json.dumps({'version': 1, 'failed': failed,
            'sessionAttached': attached, 'pid': os.getpid(), 'command': command}) + '\n'
        # Force the controller to handle a response split across pipe reads.
        sys.stdout.write(response[:5]); sys.stdout.flush()
        time.sleep(0.002)
        sys.stdout.write(response[5:]); sys.stdout.flush()
finally:
    if attached: record('stopOwned-at-eof')
    record('eof')
'''


def disabled(**overrides):
    result = dict(version=1, enabled=False, phase='disabled', verified=True,
                  active=0, pending=0, failed=0, dnsActive=False, dnsWithdrawn=True,
                  anotherSessionActive=False, sessionAttached=False, removed=0)
    result.update(overrides)
    return result


class SessionTransportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='routeweaver-session-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.fake_app = self.root / 'fake_app.py'
        self.fake_app.write_text(FAKE_APP)
        self.evidence = self.root / 'calls.jsonl'

    def start(self, mode='normal', timeout=2):
        session = LiveServiceSession([sys.executable, str(self.fake_app), str(self.evidence), mode], timeout)
        self.addCleanup(session.close)
        return session

    def calls(self):
        return [json.loads(line) for line in self.evidence.read_text().splitlines()]

    def test_requests_keep_one_process_and_eof_cleans_its_owner(self):
        with self.start() as session:
            responses = [session.request('status'), session.request('attach'),
                         session.request('apply', ['223.5.5.254/32']), session.request('stopOwned')]
        self.assertEqual({r['pid'] for r in responses}, {session.process.pid})
        self.assertEqual([r['failed'] for r in responses], [0, 0, 0, 0])
        self.assertEqual([r['command'] for r in self.calls()],
                         ['status', 'attach', 'apply', 'stopOwned', 'stopOwned-at-eof', 'eof'])
        self.assertIsNotNone(session.process.returncode)

    def test_read_only_session_does_not_attach_or_cleanup_other_owners(self):
        with self.start() as session:
            session.request('status')
        self.assertEqual([r['command'] for r in self.calls()], ['status', 'eof'])

    def test_failure_response_keeps_transport_synchronized(self):
        with self.start() as session:
            self.assertEqual(session.request('apply', ['223.5.5.254/32'])['failed'], 1)
            self.assertEqual(session.request('attach')['failed'], 0)
            self.assertEqual(session.request('apply', ['223.5.5.254/32'])['failed'], 0)

    def test_transport_failures_cannot_reassign_late_responses(self):
        for mode, error in [('timeout', TimeoutError), ('oversize', RuntimeError),
                            ('invalid', RuntimeError), ('exit', RuntimeError)]:
            with self.subTest(mode=mode), self.start(mode, timeout=0.15 if mode == 'timeout' else 2) as session:
                with self.assertRaises(error):
                    session.request('status')
                with self.assertRaisesRegex(RuntimeError, 'synchronized'):
                    session.request('status')

    def test_request_limit_rejects_before_writing_and_session_can_continue(self):
        with self.start() as session:
            with self.assertRaises(ValueError):
                session.request('apply', ['x' * session.maximum_request])
            self.assertEqual(session.request('status')['failed'], 0)
        self.assertEqual([r['command'] for r in self.calls()], ['status', 'eof'])

    def test_closed_session_rejects_commands(self):
        session = self.start()
        session.close()
        session.close()
        with self.assertRaises(RuntimeError):
            session.request('attach')

    def test_cleanup_requires_dns_withdrawal_and_verified_empty_routes(self):
        self.assertTrue(cleanup_confirmed(disabled()))
        for override in [dict(dnsWithdrawn=False), dict(dnsWithdrawn=None), dict(dnsActive=True),
                         dict(verified=False), dict(active=1), dict(pending=1), dict(failed=1),
                         dict(enabled=True), dict(phase='restoring')]:
            with self.subTest(override=override):
                self.assertFalse(cleanup_confirmed(disabled(**override)))


class FakeService:
    """Models peer ownership, restart cleanup, and route loss without any IPC."""
    physical = dict(gateway='192.0.2.1', interface='en0')
    baseline = dict(gateway='100.64.0.1', interface='utun0')

    def __init__(self):
        self.events = []
        self.attached = False
        self.enabled = False
        self.count = 0
        self.online = True
        self.exit_id = 'test-exit'
        self.loss_reads = 0
        self.initial = disabled()

    def response(self, **values):
        active = self.count if self.enabled and self.online else 0
        return disabled(enabled=self.enabled,
                        phase=('active' if self.online else 'waitingNetwork') if self.enabled else 'disabled',
                        active=active, sessionAttached=self.attached, exitNodeID=self.exit_id,
                        gateway=self.physical['gateway'], interface=self.physical['interface'],
                        durationMilliseconds=1, **values)

    def request(self, command, routes=None):
        self.events.append(command)
        if len(self.events) == 1:
            return self.initial
        if command == 'attach':
            self.attached = True
        elif command == 'apply':
            if not self.attached:
                raise AssertionError('apply must use the attached process')
            self.enabled = True
            self.count = len(routes)
        elif command == 'stopOwned':
            removed = self.count if self.enabled else 0
            self.enabled = False
            self.count = 0
            return self.response(removed=removed)
        return self.response()

    def route(self, address='223.5.5.254'):
        if self.loss_reads:
            self.loss_reads -= 1
            return self.baseline
        return self.physical if self.enabled and self.online and address == '223.5.5.254' else self.baseline

    def run(self, args, timeout=30):
        if args[:3] == ['/sbin/route', '-n', 'get']:
            return '\n'.join(f'{k}: {v}' for k, v in self.route().items())
        if args[:3] == ['/sbin/route', '-n', 'delete']:
            self.loss_reads = 1
        elif args[:3] == ['/bin/launchctl', 'kickstart', '-k']:
            self.events.append('helper-restart')
            self.attached = self.enabled = False
            self.count = 0
        elif args[-2:] == ['debug', 'prefs']:
            return json.dumps(dict(ExitNodeID=self.exit_id, ExitNodeIP='', OtherPreference='preserved'))
        elif args[-2:] == ['status', '--json']:
            return json.dumps({'Peer': {'test': {'ID': self.exit_id, 'TailscaleIPs': ['100.64.0.2']}}})
        elif args[-2:] == ['set', '--exit-node=']:
            self.online = False
        elif args[-2:] == ['set', '--exit-node=100.64.0.2']:
            self.online = True
        else:
            raise AssertionError(f'Unexpected external command: {args}')
        return ''


class LiveFixtureContractTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='routeweaver-live-contract-')
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name)

    def test_routes_fixture_attaches_before_apply_and_uses_only_scoped_stop(self):
        service = FakeService()
        with patch.multiple(routes_fixture, root=self.root, session=service, log=[]), \
             patch.object(routes_fixture, 'route_get', service.route), \
             patch.object(sys, 'argv', ['validate_live_routes.py']), contextlib.redirect_stdout(io.StringIO()):
            routes_fixture.validate()
        self.assertEqual(service.events[:3], ['status', 'attach', 'apply'])
        self.assertNotIn('stop', service.events)
        self.assertFalse(service.enabled)
        self.assertTrue((self.root / 'work/validation/live-validation.json').exists())

    def test_both_fixtures_refuse_existing_ownership_or_unwithdrawn_dns(self):
        for fixture in [routes_fixture, recovery_fixture]:
            for state in [disabled(anotherSessionActive=True), disabled(dnsWithdrawn=False)]:
                service = FakeService()
                service.initial = state
                with self.subTest(fixture=fixture.__name__, state=state), \
                     patch.multiple(fixture, root=self.root, session=service, log=[]):
                    with self.assertRaises(RuntimeError):
                        fixture.validate()
                    self.assertEqual(service.events, ['status'])

    def test_failed_attach_stops_before_any_apply_or_external_mutation(self):
        for fixture, rpc in [(routes_fixture, routes_fixture.call), (recovery_fixture, recovery_fixture.rpc)]:
            class DeniedService:
                def request(self, command, routes=None):
                    return disabled(failed=1, message='another session owns this helper')
            with self.subTest(fixture=fixture.__name__), patch.multiple(fixture, session=DeniedService(), log=[]):
                with self.assertRaises(RuntimeError):
                    rpc('attach')

    def test_safety_gates_are_active_under_python_optimization(self):
        checked = subprocess.run([sys.executable, '-O', str(pathlib.Path(__file__).resolve()),
            'LiveFixtureContractTests.test_both_fixtures_refuse_existing_ownership_or_unwithdrawn_dns',
            'LiveFixtureContractTests.test_failed_attach_stops_before_any_apply_or_external_mutation'],
            capture_output=True, text=True, timeout=10)
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)

    def test_recovery_fixture_waits_for_disabled_then_reattaches_and_reapplies(self):
        service = FakeService()
        with patch.multiple(recovery_fixture, root=self.root, session=service, log=[],
                            uid=501, gid=20, ts=['fixture-tailscale']), \
             patch.object(recovery_fixture, 'run', service.run), \
             patch.object(recovery_fixture.time, 'sleep'), \
             patch.object(recovery_fixture.os, 'chown'), contextlib.redirect_stdout(io.StringIO()):
            recovery_fixture.validate()
        restart = service.events.index('helper-restart')
        self.assertEqual(service.events[restart + 1:restart + 5], ['status', 'attach', 'apply', 'status'])
        self.assertEqual(service.events.count('attach'), 2)
        self.assertNotIn('stop', service.events)
        self.assertTrue(service.online)
        self.assertFalse(service.enabled)
        self.assertEqual(service.events[-1], 'stopOwned')

    def test_failed_live_assertion_still_cleans_owned_policy(self):
        service = FakeService()
        def wrong_route(address):
            return dict(gateway='wrong', interface='wrong') if service.enabled else service.baseline
        with patch.multiple(routes_fixture, root=self.root, session=service, log=[]), \
             patch.object(routes_fixture, 'route_get', wrong_route), \
             contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(RuntimeError):
                routes_fixture.validate()
        self.assertEqual(service.events[-1], 'stopOwned')
        self.assertFalse(service.enabled)


if __name__ == '__main__':
    unittest.main(verbosity=2)
