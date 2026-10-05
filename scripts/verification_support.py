"""Development-only persistent native-Nim client with checked process shutdown."""
import atexit
import hashlib
import json
import os
import pathlib
import queue
import subprocess
import threading
import time

from native_support import strict_json
from verify_reference import ROOT as PKG, snapshot, enrich, require

_CLIENTS = {}
_MAX_RESPONSE_BYTES = 96 * 1024 * 1024
_STDERR_PREVIEW_BYTES = 4096


def digest(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def binary_command(executable):
    return [str(pathlib.Path(executable).resolve())]


class _Client:
    def __init__(self, command, env):
        self.command = list(command)
        self.env = env
        self.proc = subprocess.Popen(command, cwd=PKG, env=env, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.lines = queue.Queue(maxsize=2)
        self.stop_reader = threading.Event()
        self.stdout_hash = hashlib.sha256()
        self.stderr_hash = hashlib.sha256()
        self.stdout_bytes = self.stderr_bytes = 0
        self.stderr_preview = bytearray()
        self.reader_errors = []
        self.query_timeout = False
        self.responses = 0
        self.stdout_reader = threading.Thread(target=self._read_stdout, daemon=True)
        self.stderr_reader = threading.Thread(target=self._read_stderr, daemon=True)
        self.stdout_reader.start()
        self.stderr_reader.start()

    def _queue(self, value):
        while not self.stop_reader.is_set():
            try:
                self.lines.put(value, timeout=0.1)
                return
            except queue.Full:
                pass

    def _read_stdout(self):
        try:
            while True:
                line = self.proc.stdout.readline(_MAX_RESPONSE_BYTES + 1)
                if not line:
                    break
                self.stdout_hash.update(line)
                self.stdout_bytes += len(line)
                if len(line) > _MAX_RESPONSE_BYTES:
                    self.reader_errors.append('Response exceeds the bounded line budget')
                    self.proc.kill()
                    break
                self._queue(line)
        except BaseException as error:
            self.reader_errors.append('stdout reader: ' + repr(error))
        finally:
            self._queue(None)

    def _read_stderr(self):
        try:
            while True:
                data = self.proc.stderr.read(65536)
                if not data:
                    break
                self.stderr_hash.update(data)
                self.stderr_bytes += len(data)
                room = _STDERR_PREVIEW_BYTES - len(self.stderr_preview)
                if room > 0:
                    self.stderr_preview.extend(data[:room])
        except BaseException as error:
            self.reader_errors.append('stderr reader: ' + repr(error))

    def kill(self):
        if self.proc.poll() is None:
            self.proc.kill()


def execute(command, requests, env=None, timeout=900):
    """Consume exactly one strict JSON response per request; shutdown is separate."""
    require(0 < timeout < float('inf'), 'Query timeout must be positive and finite')
    key = tuple(command)
    if key not in _CLIENTS:
        _CLIENTS[key] = _Client(command, env)
    client = _CLIENTS[key]
    require(client.env == env, 'Cannot reuse a native process with a different environment')
    results = []
    for request in requests:
        deadline = time.monotonic() + timeout
        def expire():
            client.query_timeout = True
            client.kill()
        timer = threading.Timer(timeout, expire)
        timer.start()
        try:
            client.proc.stdin.write((json.dumps(request, ensure_ascii=True) + '\n').encode())
            client.proc.stdin.flush()
            line = client.lines.get(timeout=max(0.001, deadline - time.monotonic()))
            require(line is not None, 'Native process stopped before its response')
            require(not client.query_timeout, 'Native request timed out')
            require(not client.reader_errors, '; '.join(client.reader_errors))
            results.append(enrich(strict_json(line)))
            client.responses += 1
        except queue.Empty as error:
            client.query_timeout = True
            client.kill()
            raise TimeoutError('Native request timed out') from error
        except BaseException:
            client.kill()
            raise
        finally:
            timer.cancel()
            timer.join()
    return results



def expected_fnc1_outcome(vector):
    """Independent byte-fallback bit arithmetic against the pinned fixture capacity."""
    options = vector['options']
    require('%' in vector['input'], 'Expected a literal-percent contract vector')
    mode = options['mode']
    require(mode in ('auto', 'byte', 'alphanumeric'), 'Unexpected FNC1 vector mode')
    if mode == 'alphanumeric':
        return 'INVALID_MODE'
    payload = bytes.fromhex(vector['expectedPayloadUtf8Hex'])
    require(payload == vector['input'].encode('utf-8'), 'Fixture payload text/bytes disagree')
    version = options['version']
    require(type(version) is int and 1 <= version <= 40, 'Unexpected fixture version')
    count_bits = 8 if version <= 9 else 16
    control_bits = 12 if 'fnc1Second' in options else 4
    bits = control_bits + 4 + count_bits + len(payload) * 8
    capacity = vector['capacityBits']
    require(type(capacity) is int and capacity > 0, 'Invalid pinned fixture capacity')
    return 'DATA_TOO_LONG' if bits > capacity or len(payload) >= 2**count_bits else 'success'


def check_fnc1_outcome(vector, response):
    expected = expected_fnc1_outcome(vector)
    if expected == 'success':
        require('error' not in response, 'Expected FNC1 encoding success: ' + vector['id'])
    else:
        require('error' in response and response.get('code') == expected,
                'Unexpected FNC1 outcome: ' + vector['id'] + '; expected ' + expected)
    return expected


def finish_clients(report=None, timeout=20, raise_errors=True):
    """Close input and require clean EOF, exit zero and empty stderr for every child.

    All children are finalized even when one fails. Attach outcomes before raising,
    so callers can preserve failure evidence without hiding an earlier exception.
    """
    require(0 < timeout < float('inf'), 'Shutdown timeout must be positive and finite')
    clients = list(_CLIENTS.values())
    _CLIENTS.clear()
    outcomes = []
    for client in clients:
        deadline = time.monotonic() + timeout
        errors = []
        trailing_hash = hashlib.sha256()
        trailing_bytes = trailing_lines = 0
        shutdown_timeout = False
        try:
            try:
                client.proc.stdin.close()
            except (BrokenPipeError, OSError):
                pass
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError('Native process did not reach stdout EOF')
                try:
                    line = client.lines.get(timeout=remaining)
                except queue.Empty as error:
                    raise TimeoutError('Native process did not reach stdout EOF') from error
                if line is None:
                    break
                trailing_hash.update(line)
                trailing_bytes += len(line)
                trailing_lines += 1
            client.proc.wait(timeout=max(0.001, deadline - time.monotonic()))
        except (TimeoutError, subprocess.TimeoutExpired) as error:
            shutdown_timeout = True
            errors.append(str(error))
            client.kill()
        except BaseException as error:
            errors.append(repr(error))
            client.kill()
        finally:
            try:
                client.proc.wait(timeout=5)
            except BaseException as error:
                errors.append('Unable to reap native process: ' + repr(error))
            # Drain any queued shutdown output before stopping the bounded reader.
            while True:
                try:
                    line = client.lines.get_nowait()
                except queue.Empty:
                    break
                if line is not None:
                    trailing_hash.update(line)
                    trailing_bytes += len(line)
                    trailing_lines += 1
            client.stop_reader.set()
            client.stdout_reader.join(timeout=5)
            client.stderr_reader.join(timeout=5)
            if client.stdout_reader.is_alive() or client.stderr_reader.is_alive():
                errors.append('Native stream reader did not finish')
            for stream in (client.proc.stdout, client.proc.stderr):
                if not (client.stdout_reader.is_alive() or client.stderr_reader.is_alive()):
                    stream.close()
        errors.extend(client.reader_errors)
        if client.proc.returncode != 0:
            errors.append('Native process exit code: ' + str(client.proc.returncode))
        if trailing_bytes:
            errors.append('Unexpected trailing stdout')
        if client.stderr_bytes:
            errors.append('Unexpected stderr')
        if client.query_timeout:
            errors.append('Native request timed out')
        outcome = {
            'argv': client.command, 'status': 'failed' if errors else 'passed',
            'exitCode': client.proc.returncode, 'responses': client.responses,
            'stdoutSha256': client.stdout_hash.hexdigest(), 'stdoutBytes': client.stdout_bytes,
            'stderrSha256': client.stderr_hash.hexdigest(), 'stderrBytes': client.stderr_bytes,
            'stderrPreview': client.stderr_preview.decode(errors='replace'),
            'trailingStdoutSha256': trailing_hash.hexdigest(),
            'trailingStdoutBytes': trailing_bytes, 'trailingStdoutLines': trailing_lines,
            'queryTimeout': client.query_timeout, 'shutdownTimeout': shutdown_timeout,
            'errors': errors,
        }
        outcomes.append(outcome)
    if report is not None and outcomes:
        report.setdefault('nativeProcesses', []).extend(outcomes)
    if raise_errors:
        require(all(row['status'] == 'passed' for row in outcomes),
                'Native process finalization failed: ' + repr(outcomes))
    return outcomes


def close_clients():
    """Last-resort cleanup only. Successful receipts require finish_clients()."""
    finish_clients(raise_errors=False)


atexit.register(close_clients)
