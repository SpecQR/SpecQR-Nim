"""Strict captured auxiliary-tool execution for verification only."""
import hashlib
import math
import re
import struct
import subprocess
import time
import zlib

from native_support import strict_json


def run_auxiliary(command, report, label, *, input=None, env=None, timeout=120,
                  validator=None):
    """Return exact stdout (or validated value), recording failure before raising."""
    if not 0 < timeout < float('inf'):
        raise ValueError('Auxiliary timeout must be positive and finite')
    argv = [str(value) for value in command]
    row = {'label': label, 'argv': argv, 'status': 'running', 'exitCode': None,
           'timeout': False}
    report.setdefault('auxiliaryProcesses', []).append(row)
    stdout = stderr = b''
    start = time.monotonic()
    try:
        process = subprocess.run(argv, input=input, env=env, capture_output=True,
                                 timeout=timeout, check=False)
        stdout, stderr = process.stdout, process.stderr
        row['exitCode'] = process.returncode
        if process.returncode != 0:
            raise RuntimeError(label + ': nonzero exit ' + str(process.returncode))
        if stderr:
            raise RuntimeError(label + ': unexpected stderr')
        value = validator(stdout) if validator is not None else stdout
        row['status'] = 'passed'
        return value
    except subprocess.TimeoutExpired as error:
        stdout, stderr = error.stdout or b'', error.stderr or b''
        row.update(status='failed', timeout=True, error=repr(error))
        report.update(status='failed', error=repr(error))
        raise
    except BaseException as error:
        row.update(status='failed', error=repr(error))
        report.update(status='failed', error=repr(error))
        raise
    finally:
        row.update(stdoutBytes=len(stdout), stdoutSha256=hashlib.sha256(stdout).hexdigest(),
                   stderrBytes=len(stderr), stderrSha256=hashlib.sha256(stderr).hexdigest(),
                   stderrPreview=stderr[:4096].decode('utf-8', errors='replace'),
                   elapsedSeconds=round(time.monotonic() - start, 3))
        if input is not None:
            row.update(inputBytes=len(input), inputSha256=hashlib.sha256(input).hexdigest())


def json_records(data, count):
    lines = data.splitlines()
    if len(lines) != count:
        raise ValueError('Expected exactly ' + str(count) + ' JSON output records')
    rows = [strict_json(line) for line in lines]
    if not all(isinstance(row, dict) for row in rows):
        raise ValueError('Expected JSON object records')
    return rows


def version_text(data, prefix, single_line=False):
    text = data.decode('utf-8').strip()
    lines = text.splitlines()
    if not lines or not lines[0].startswith(prefix) or '\x00' in text:
        raise ValueError('Malformed version output')
    if single_line and len(lines) != 1:
        raise ValueError('Unexpected extra version output')
    return text


def exact_number(data, expected):
    text = data.decode('ascii').strip()
    if not re.fullmatch(r'[+]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?', text):
        raise ValueError('Malformed numeric probe output')
    value = float(text)
    if not math.isfinite(value) or value != expected:
        raise ValueError('Numeric probe did not match its required value')
    return value


def png_stream(data):
    """Validate complete PNG framing/CRCs and reject appended auxiliary output."""
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('Rasterizer did not return a PNG')
    position = 8
    header = ended = False
    while position < len(data):
        if position + 12 > len(data):
            raise ValueError('Truncated rasterizer PNG chunk')
        length = struct.unpack('>I', data[position:position + 4])[0]
        end = position + length + 12
        if end > len(data):
            raise ValueError('Truncated rasterizer PNG payload')
        kind = data[position + 4:position + 8]
        payload = data[position + 8:end - 4]
        crc = struct.unpack('>I', data[end - 4:end])[0]
        if zlib.crc32(kind + payload) != crc:
            raise ValueError('Rasterizer PNG CRC mismatch')
        if not header:
            if kind != b'IHDR' or length != 13:
                raise ValueError('Rasterizer PNG lacks initial IHDR')
            header = True
        elif kind == b'IHDR':
            raise ValueError('Repeated rasterizer PNG IHDR')
        if kind == b'IEND':
            if length != 0 or end != len(data):
                raise ValueError('Unexpected trailing rasterizer PNG output')
            ended = True
        position = end
    if not header or not ended:
        raise ValueError('Incomplete rasterizer PNG')
    return data
