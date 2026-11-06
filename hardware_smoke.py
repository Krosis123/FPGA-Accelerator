"""Explicit physical FPGA regression: py hardware_smoke.py --port COM6."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path

import serial

from grn_frontend import Network, load_network, parse_expression
from grn_reference import attractor
from grn_run import PROFILE, compile_network, execute, run_packet

ROOT = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'reports/hardware_smoke.json')
    args = parser.parse_args()
    profile = json.loads(PROFILE.read_text())
    networks = [(path.stem, load_network(path)) for path in
                [ROOT / 'examples/swap.bnet', ROOT / 'examples/inhibition.csv',
                 ROOT / 'examples/majority.csv']]
    networks += [('four_gene_swap', Network(list('ABCD'),
                  [parse_expression(s) for s in ['B', 'A', 'C', 'D']])),
                 ('transient', Network(list('AB'),
                  [parse_expression(s) for s in ['B', '0']]))]
    results = []
    with serial.Serial(args.port, 115200, timeout=2, write_timeout=2) as port:
        port.reset_input_buffer()
        for name, network in networks:
            cfg = compile_network(network, profile)
            for seed in range(1 << len(network.names)):
                reference = attractor(network, seed)
                result = execute(port, run_packet(cfg, seed, len(network.names), profile),
                                 len(network.names))
                if (result['period'] != reference['period'] or
                        result['cycle_member'] not in reference['cycle_states']):
                    raise RuntimeError(f'{name} seed={seed}: {result} vs {reference}')
                results.append({'network': name, 'seed': seed, 'reference': reference,
                                'hardware': result})
    bitstream = ROOT / '_build/default/hardware.bit'
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({
        'timestamp_utc': datetime.now(timezone.utc).isoformat(),
        'port': args.port, 'profile': profile['id'],
        'scope': 'Physical single-seed periods and cycle members; CPU-only transient/cycle extraction',
        'bitstream_sha256': hashlib.sha256(bitstream.read_bytes()).hexdigest(),
        'passed': len(results), 'results': results}, indent=2) + '\n')
    print(f'PASS: {len(results)} physical FPGA executions; {args.output}')


if __name__ == '__main__':
    main()
