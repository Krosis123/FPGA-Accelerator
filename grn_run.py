"""Compile and execute a synchronous Boolean GRN on the existing runtime backend."""
import argparse
import binascii
import json
import time
from pathlib import Path

from ferreira_compile import compile_graph
from ferreira_upload import build_packet
from grn_frontend import load_network, lower_ai
from grn_reference import attractor

PROFILE = Path(__file__).with_name('hardware_profile.json')


def state_bytes(seed, active, width):
    if seed < 0 or seed.bit_length() > active:
        raise ValueError(f"Seed exceeds active network width ({active} bits)")
    if active > width * 8:
        raise ValueError("Hardware seed transport width is insufficient")
    return seed.to_bytes(width, 'little')


def compile_network(network, profile):
    # The existing routing compiler operates on physical slots. Inactive PEs
    # receive zero inputs and zero seed, so their state stays zero.
    required = {'protocol': 2, 'capacities': [1, 2, 4, 8], 'depth': 32,
                'max_degree': 256, 'seed_bytes': 1, 'clock_hz': 100000000}
    for field, value in required.items():
        if profile.get(field) != value:
            raise ValueError(f"Unsupported hardware profile {field}={profile.get(field)!r}; "
                             f"implemented run backend requires {value!r}")
    n = len(network.names)
    caps = profile['capacities']
    if not 1 <= n <= len(caps):
        raise ValueError(f"Network has {n} genes; profile has {len(caps)} slots")
    edges = []
    rules = ['AI'] * len(caps)
    indices = {name: i for i, name in enumerate(network.names)}
    for dst, tree in enumerate(network.expressions):
        try:
            if tree[0] == 'maj':
                if any(t[0] != 'var' for t in tree[1:]):
                    raise ValueError('MAJ backend accepts gene inputs only')
                activation, inhibition = [t[1] for t in tree[1:]], []
                if len(set(activation)) != len(activation):
                    raise ValueError('Repeated MAJ inputs are not supported')
                rules[dst] = 'MAJ'
            else:
                activation, inhibition = lower_ai(tree)
        except ValueError as exc:
            raise ValueError(f"{network.names[dst]}: {exc}") from exc
        degree = len(activation) + len(inhibition)
        if rules[dst] not in profile['rules']:
            raise ValueError(f"Rule {rules[dst]} is unsupported by this hardware profile")
        if degree > profile['max_degree']:
            raise ValueError(f"{network.names[dst]}: fan-in exceeds hardware maximum")
        for typ, sources in [('A', activation), ('I', inhibition)]:
            edges.extend({'src': indices[src], 'dst': dst, 'type': typ} for src in sources)
    cfg = compile_graph({'genes': len(caps), 'capacities': caps,
                         'rules': rules, 'edges': edges},
                        depth=profile['depth'])
    # This checks the actual transport/backend geometry, not just a profile label.
    build_packet(cfg)
    return cfg


def run_packet(cfg, seed, active, profile):
    if profile['protocol'] != 2 or profile['seed_bytes'] != 1:
        raise ValueError("This installed backend requires run protocol v2, one seed byte")
    legacy = build_packet(cfg)
    payload = bytes([2, active]) + state_bytes(seed, active, profile['seed_bytes']) + legacy[3:-2]
    return b'FG' + payload + binascii.crc_hqx(payload, 0xffff).to_bytes(2, 'little')


def decode_result(frame, active):
    if len(frame) != 16 or frame[:3] != b'FR\x02':
        raise ValueError("Invalid result framing or incompatible bitstream")
    payload = frame[2:-2]
    if binascii.crc_hqx(payload, 0xffff) != int.from_bytes(frame[-2:], 'little'):
        raise ValueError("Result CRC mismatch")
    if frame[3] != active or not 1 <= frame[4] <= (1 << active) or frame[5] >> active:
        raise ValueError("Result metadata exceeds active network bounds")
    return {'period': frame[4], 'cycle_member': frame[5],
            'execution_cycles': int.from_bytes(frame[6:14], 'little')}


def read_exact(port, count):
    data = bytearray()
    while len(data) < count:
        part = port.read(count - len(data))
        if not part:
            raise TimeoutError(f"UART timeout: received {len(data)} of {count} bytes")
        data.extend(part)
    return bytes(data)


def execute(port, packet, active):
    started = time.perf_counter()
    if port.write(packet) != len(packet):
        raise IOError("Incomplete UART write")
    port.flush()
    ack = read_exact(port, 1)
    uploaded = time.perf_counter()
    if ack != b'\x06':
        raise ValueError(f"FPGA rejected configuration (response {ack.hex()})")
    result = decode_result(read_exact(port, 16), active)
    result['configuration_ack_seconds'] = uploaded - started
    result['transaction_seconds'] = time.perf_counter() - started
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--network', required=True, type=Path)
    parser.add_argument('--seed', required=True, type=lambda s: int(s, 0))
    parser.add_argument('--port')
    parser.add_argument('--profile', type=Path, default=PROFILE)
    parser.add_argument('--baud', type=int, default=115200)
    parser.add_argument('--timeout', type=float, default=10)
    parser.add_argument('--max-reference-states', type=int, default=1000000)
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--emit-hex', type=Path)
    args = parser.parse_args()
    try:
        profile = json.loads(args.profile.read_text())
        network = load_network(args.network)
        cfg = compile_network(network, profile)
        packet = run_packet(cfg, args.seed, len(network.names), profile)
        cpu_started = time.perf_counter()
        reference = attractor(network, args.seed, args.max_reference_states)
        output = {'profile': profile['id'], 'gene_indices': dict(enumerate(network.names)),
                  'active_genes': len(network.names), 'physical_slots': len(profile['capacities']),
                  'substeps': cfg['substeps'], 'configuration_bytes': len(packet),
                  'reference': reference, 'reference_seconds': time.perf_counter() - cpu_started}
        if args.emit_hex:
            args.emit_hex.write_text(''.join(f'{b:02x}\n' for b in packet))
        if not args.dry_run:
            if not args.port:
                parser.error('--port is required unless --dry-run is used')
            import serial
            with serial.Serial(args.port, args.baud, timeout=args.timeout,
                               write_timeout=args.timeout) as port:
                port.reset_input_buffer()
                hardware = execute(port, packet, len(network.names))
            if (hardware['period'] != reference['period'] or
                    hardware['cycle_member'] not in reference['cycle_states']):
                raise ValueError(f"FPGA/CPU disagreement: {hardware} vs {reference}")
            hardware['execution_seconds_at_profile_clock'] = hardware['execution_cycles'] / profile['clock_hz']
            output.update(hardware=hardware, verified=True)
        else:
            output['status'] = 'compiled and CPU evaluated; FPGA not executed'
        print(json.dumps(output, indent=2))
    except (ValueError, RuntimeError, OSError, ImportError, TimeoutError) as exc:
        parser.exit(1, f'grn_run: {exc}\n')


if __name__ == '__main__':
    main()
