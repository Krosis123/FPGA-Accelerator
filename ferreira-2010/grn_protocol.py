"""Width-independent protocol v3 shared by discovery, compilation and execution."""
import binascii
import struct
import time

from ferreira_upload import verilog_hex


def crc(data):
    return binascii.crc_hqx(data, 0xffff)


def frame(opcode, request_id, payload=b'', magic=b'FG'):
    body = struct.pack('<BBHI', 3, opcode, request_id, len(payload)) + payload
    return magic + body + struct.pack('<H', crc(body))


def read_exact(port, count):
    data = bytearray()
    while len(data) < count:
        part = port.read(count - len(data))
        if not part:
            raise TimeoutError(f'UART timeout: received {len(data)} of {count} bytes')
        data.extend(part)
    return bytes(data)


ERRORS = {1: 'CRC mismatch', 2: 'unsupported protocol version',
          3: 'invalid command or frame length', 4: 'hardware profile mismatch',
          5: 'active count, substeps, or seed outside hardware bounds',
          6: 'invalid seed/rule/degree metadata', 7: 'invalid routing masks or padding',
          8: 'partial-frame timeout'}


class LegacyImage(ValueError):
    """An older image sent its unframed NAK instead of a v3 response."""


def receive(port, request_id):
    first = read_exact(port, 1)
    if first == b'\x15':
        raise LegacyImage('Legacy FPGA image rejected v3; upload the runtime64 image '
                          'or select --profile hardware_profile.json for the four-slot image')
    header = first + read_exact(port, 9)
    if header[:2] != b'FR' or header[2] != 3:
        raise ValueError('Invalid v3 response framing')
    _, opcode, ident, length = struct.unpack('<BBHI', header[2:])
    if ident != request_id or length > 65536:
        raise ValueError('Response request ID or length mismatch')
    payload = read_exact(port, length)
    checksum = int.from_bytes(read_exact(port, 2), 'little')
    if crc(header[2:] + payload) != checksum:
        raise ValueError('Response CRC mismatch')
    if opcode == 0xff:
        code = payload[0] if len(payload) == 1 else -1
        raise ValueError(
            f'FPGA rejected request: {ERRORS.get(code, "unknown error")} (code {code})')
    return opcode, payload


def capability_payload(profile):
    caps = profile['capacities']
    return struct.pack('<IHHHHBBBB', profile['clock_hz'], len(caps), profile['depth'],
                       profile['max_degree'], profile['route_n'], max(caps),
                       profile['cw'], 3, profile['pipe_routing']) + bytes(c.bit_length()-1 for c in caps)


def profile_from_capabilities(payload):
    if len(payload) < 16:
        raise ValueError('Truncated hardware capability response')
    clock, n, depth, degree, route_n, kmax, cw, flags, pipeline = struct.unpack(
        '<IHHHHBBBB', payload[:16])
    if not 1 <= n <= 4096 or len(payload) != 16+n:
        raise ValueError('Invalid hardware capacity declaration')
    if any(log > 5 for log in payload[16:]):
        raise ValueError('Unsupported physical PE capacity encoding')
    profile = {'id': f'ferreira-v3-{n}-slots-{crc(payload):04x}', 'protocol': 3,
               'capacities': [1 << log for log in payload[16:]], 'depth': depth,
               'max_degree': degree, 'clock_hz': clock, 'route_n': route_n,
               'cw': cw, 'pipe_routing': pipeline, 'seed_bytes': (n+7)//8,
               'rules': [name for bit, name in [(1, 'AI'), (2, 'MAJ')] if flags & bit],
               'capability_crc': crc(payload)}
    validate_profile(profile)
    if max(profile['capacities']) != kmax or flags != 3:
        raise ValueError('Incompatible PE/rule capability declaration')
    return profile


def validate_profile(profile):
    caps = profile.get('capacities', [])
    if not caps or any(type(c) is not int or c <= 0 or c > 32 or c & (c-1) for c in caps):
        raise ValueError('Hardware PE capacities must be powers of two in 1..32')
    required_route = 1 << (max(2, sum(caps))-1).bit_length()
    if profile.get('route_n') != required_route:
        raise ValueError('Hardware routing size does not match this compiler backend')
    # The existing compiler's counters are nine bits with MAX_DEGREE=256.
    if profile.get('max_degree') != 256 or profile.get('cw') != 9:
        raise ValueError('This compiler backend requires MAX_DEGREE=256, CW=9')
    depth = profile.get('depth', 0)
    if not 2 <= depth <= 65535 or depth & (depth-1):
        raise ValueError('Hardware configuration depth must be a power of two in 2..32768')
    if profile.get('seed_bytes') != (len(caps)+7)//8:
        raise ValueError('Seed byte width differs from hardware state width')
    if profile.get('protocol') != 3 or profile.get('pipe_routing') not in (1, 2):
        raise ValueError('Unsupported hardware protocol or routing pipeline')
    if profile.get('clock_hz', 0) <= 0 or profile.get('rules') != ['AI', 'MAJ']:
        raise ValueError('Invalid hardware clock or rule capabilities')


def discover(port, request_id=1):
    packet = frame(1, request_id)
    if port.write(packet) != len(packet):
        raise IOError('Incomplete capability-query write')
    port.flush()
    opcode, payload = receive(port, request_id)
    if opcode != 0x81:
        raise ValueError('Expected capability response')
    return profile_from_capabilities(payload)


def routing_bytes(cfg):
    words = {(w['addr'], w['bank']): int(w['data'], 16) for w in cfg['writes']}
    expected = cfg['substeps'] * cfg['banks']
    if len(words) != len(cfg['writes']) or len(words) != expected:
        raise ValueError('Incomplete or duplicate routing bank writes')
    result = bytearray()
    for address in range(cfg['substeps']):
        row = 0
        for bank in range(cfg['banks']):
            value = words.get((address, bank))
            if value is None or not 0 <= value < 1 << 64:
                raise ValueError('Missing/out-of-range routing word')
            row |= value << (64*bank)
            result.extend(value.to_bytes(8, 'little'))
        if row >> cfg['mem_width']:
            raise ValueError('Nonzero configuration padding bits')
    return bytes(result)


def run_packet(cfg, seed, active, profile, request_id=2):
    validate_profile(profile)
    n = len(profile['capacities'])
    if not 1 <= active <= n or seed < 0 or seed.bit_length() > active:
        raise ValueError(f'Active count/seed exceeds installed {n}-slot hardware')
    for field in ('capacities', 'depth', 'route_n', 'max_degree', 'cw'):
        if cfg[field] != profile[field]:
            raise ValueError(f'Compiled {field} differs from installed image')
    if not 1 <= cfg['substeps'] <= profile['depth']:
        raise ValueError('Compiled substeps exceed installed configuration RAM')
    width = profile['seed_bytes']
    payload = struct.pack('<HHH', crc(capability_payload(profile)), active, cfg['substeps'])
    payload += seed.to_bytes(width, 'little')
    payload += verilog_hex(cfg['rule_verilog']).to_bytes(width, 'little')
    payload += verilog_hex(cfg['degree_verilog']).to_bytes((n*profile['cw']+7)//8, 'little')
    return frame(2, request_id, payload + routing_bytes(cfg))


def execute(port, packet, active, profile):
    request_id = int.from_bytes(packet[4:6], 'little')
    start = time.perf_counter()
    if port.write(packet) != len(packet):
        raise IOError('Incomplete UART write')
    port.flush()
    opcode, payload = receive(port, request_id)
    ack_time = time.perf_counter()
    if opcode != 0x80 or payload:
        raise ValueError('Expected run acknowledgment')
    opcode, payload = receive(port, request_id)
    n = len(profile['capacities'])
    state_width, period_width = (n+7)//8, (n+8)//8
    if opcode != 0x82 or len(payload) != 4 + period_width + state_width + 8:
        raise ValueError('Invalid run-result dimensions')
    signature, returned_active = struct.unpack('<HH', payload[:4])
    if signature != crc(capability_payload(profile)) or returned_active != active:
        raise ValueError('Result hardware profile or active count mismatch')
    period = int.from_bytes(payload[4:4+period_width], 'little')
    state = int.from_bytes(payload[4+period_width:4+period_width+state_width], 'little')
    if not 1 <= period <= 1 << active or state >> active:
        raise ValueError('Result exceeds active network bounds')
    return {'period': period, 'cycle_member': state,
            'execution_cycles': int.from_bytes(payload[-8:], 'little'),
            'configuration_ack_seconds': ack_time-start,
            'transaction_seconds': time.perf_counter()-start}
