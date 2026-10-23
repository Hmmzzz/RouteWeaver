#!/usr/bin/env python3
"""Bounded controller for the signed app's persistent diagnostic session.

Importing this module has no side effects. Starting a session does not attach,
install a helper, or change routing. Live fixtures explicitly attach only after
checking that the service has no active policy or recovery state.
"""

import base64
import json
import os
import select
import signal
import subprocess
import tempfile
import time


def require(condition, detail):
    """Safety gates must remain active under python -O / PYTHONOPTIMIZE."""
    if not condition:
        raise RuntimeError(detail)


def cleanup_confirmed(response):
    return (
        response.get('enabled') is False
        and response.get('phase') == 'disabled'
        and response.get('verified') is True
        and response.get('active') == response.get('pending') == response.get('failed') == 0
        and response.get('dnsActive') is False
        and response.get('dnsWithdrawn') is True
    )


class LiveServiceSession:
    """All requests share one app process and therefore one helper owner."""

    maximum_response = 1_048_576
    maximum_request = 1_400_000

    def __init__(self, command, timeout=130):
        self.timeout = timeout
        self._buffer = bytearray()
        self._closed = False
        self._broken = False
        self._stderr = tempfile.TemporaryFile()
        try:
            self.process = subprocess.Popen(
                [*command, '--service-session'], stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=self._stderr, bufsize=0,
                start_new_session=True,
            )
        except BaseException:
            self._stderr.close()
            raise
        os.set_blocking(self.process.stdin.fileno(), False)
        os.set_blocking(self.process.stdout.fileno(), False)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def _wait(self, fd, writing, deadline):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('Diagnostic session response timed out')
        readable, writable, _ = select.select(
            [] if writing else [fd], [fd] if writing else [], [], remaining,
        )
        if not (writable if writing else readable):
            raise TimeoutError('Diagnostic session response timed out')

    def request(self, command, routes=None):
        if self._closed or self._broken:
            raise RuntimeError('Diagnostic session is closed or no longer synchronized')
        request = {'version': 1, 'command': command}
        if routes is not None:
            request['routes'] = routes
        payload = base64.b64encode(json.dumps(request).encode())
        if len(payload) > self.maximum_request:
            raise ValueError('Diagnostic request exceeds the frame limit')
        payload += b'\n'
        deadline = time.monotonic() + self.timeout
        try:
            offset = 0
            fd = self.process.stdin.fileno()
            while offset < len(payload):
                self._wait(fd, True, deadline)
                try:
                    count = os.write(fd, payload[offset:])
                except (BlockingIOError, InterruptedError):
                    continue
                if count <= 0:
                    raise RuntimeError('Diagnostic session input closed')
                offset += count
            while True:
                newline = self._buffer.find(b'\n')
                if newline >= 0:
                    if newline > self.maximum_response:
                        raise RuntimeError('Diagnostic response exceeds the frame limit')
                    raw = bytes(self._buffer[:newline])
                    del self._buffer[:newline + 1]
                    response = json.loads(raw)
                    if not isinstance(response, dict) or response.get('version') != 1:
                        raise RuntimeError('Invalid diagnostic response')
                    return response
                if len(self._buffer) > self.maximum_response:
                    raise RuntimeError('Diagnostic response exceeds the frame limit')
                fd = self.process.stdout.fileno()
                self._wait(fd, False, deadline)
                try:
                    chunk = os.read(fd, 65536)
                except (BlockingIOError, InterruptedError):
                    continue
                if not chunk:
                    self._stderr.seek(0)
                    detail = self._stderr.read(2048).decode(errors='replace').strip()
                    raise RuntimeError('Diagnostic session exited before replying' + (': ' + detail if detail else ''))
                self._buffer.extend(chunk)
        except BaseException:
            # A late response must never be mistaken for a subsequent request.
            self._broken = True
            raise

    def close(self):
        if self._closed:
            return
        self._closed = True
        try:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                # Only this fixture's newly created process group is signalled.
                for sig in (signal.SIGTERM, signal.SIGKILL):
                    try:
                        os.killpg(self.process.pid, sig)
                    except ProcessLookupError:
                        pass
                    try:
                        self.process.wait(timeout=5)
                        break
                    except subprocess.TimeoutExpired:
                        continue
        finally:
            self.process.stdout.close()
            self._stderr.close()
