"""Physical same-bitstream regression and timings: py runtime_validate.py --port COM6."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import time

import serial

import grn_protocol as v3
from grn_reference import attractor
from grn_run import compile_network
from runtime_cases import file_cases

ROOT=Path(__file__).parent


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port',required=True)
    parser.add_argument('--build-env',default='runtime64-25-spread',choices=['runtime64','runtime64-sa','runtime64-25','runtime64-25-r2','runtime64-25-sa','runtime64-25-spread'])
    parser.add_argument('--output',type=Path,default=ROOT/'reports/runtime64_physical.json')
    args=parser.parse_args()
    image=ROOT/'_build'/args.build_env/'hardware.bit'
    pnr=ROOT/'_build'/args.build_env/'hardware.pnr'
    timing=json.loads(pnr.read_text())
    if not image.exists() or not timing['fmax'] or any(
            value['achieved']<value['constraint'] for value in timing['fmax'].values()):
        raise RuntimeError('Refusing hardware qualification: selected build has no timing-passing bitstream')
    results=[]
    source_sha256={path.name:hashlib.sha256(path.read_bytes()).hexdigest()
                   for path in ROOT.glob('*.v') if not path.name.endswith('_tb.v')}
    with serial.Serial(args.port,115200,timeout=3,write_timeout=3) as port:
        port.reset_input_buffer()
        query_start=time.perf_counter()
        profile=v3.discover(port)
        query_seconds=time.perf_counter()-query_start
        if len(profile['capacities'])!=64:
            raise RuntimeError('Physical capacity regression expects the 64-slot image')
        if args.build_env.startswith('runtime64-25') and profile['clock_hz']!=25000000:
            raise RuntimeError('Selected 25 MHz build does not match the running FPGA clock declaration')
        if not any(abs(value['constraint']-profile['clock_hz']/1e6)<0.001
                   for value in timing['fmax'].values()):
            raise RuntimeError('Running clock declaration does not match routed timing constraint')
        for ident,(name,network,seed) in enumerate(file_cases(),2):
            start=time.perf_counter()
            cfg=compile_network(network,profile)
            compile_seconds=time.perf_counter()-start
            packet=v3.run_packet(cfg,seed,len(network.names),profile,ident)
            start=time.perf_counter()
            reference=attractor(network,seed)
            cpu_seconds=time.perf_counter()-start
            hardware=v3.execute(port,packet,len(network.names),profile)
            if (hardware['period']!=reference['period'] or
                    hardware['cycle_member'] not in reference['cycle_states']):
                raise RuntimeError(f'{name} seed {seed:x}: FPGA {hardware} vs CPU {reference}')
            meeting=reference['period']*max(1,(reference['transient']+reference['period']-1)//reference['period'])
            update_clocks=cfg['substeps']*(profile['pipe_routing']+1)
            expected_cycles=meeting*(3*update_clocks+1)+reference['period']*(update_clocks+1)
            if hardware['execution_cycles']!=expected_cycles:
                raise RuntimeError(f'{name}: measured cycles differ from independent Floyd schedule count')
            hardware['execution_seconds_at_profile_clock']=hardware['execution_cycles']/profile['clock_hz']
            results.append({'network':name,'active_genes':len(network.names),'seed':hex(seed),
                'substeps':cfg['substeps'],'edges':cfg['edge_count'],'configuration_bytes':len(packet),
                'configuration_wire_seconds_8n1':len(packet)*10/115200,
                'configuration_sha256':hashlib.sha256(packet).hexdigest(),
                'compile_seconds':compile_seconds,'reference_seconds':cpu_seconds,
                'reference':reference,'hardware':hardware,'verified':True})
            print(f"PASS {name:20s} genes={len(network.names):2d} period={hardware['period']:3d} "
                  f"substeps={cfg['substeps']:2d} cycles={hardware['execution_cycles']:6d}",flush=True)
        # Error handling on the actual FPGA, then a valid graph on the same image.
        bad=bytearray(packet); bad[-1]^=1
        port.write(bad); port.flush()
        try: v3.receive(port,ident)
        except ValueError as exc:
            if 'CRC mismatch' not in str(exc): raise
        else: raise RuntimeError('Physical FPGA accepted a corrupt CRC')
        recovery=v3.execute(port,packet,len(network.names),profile)
        if recovery['period']!=reference['period']:
            raise RuntimeError('Physical recovery failed')
    report={'timestamp_utc':datetime.now(timezone.utc).isoformat(),'port':args.port,
            'profile':profile,'capability_query_seconds':query_seconds,
            'programming_calls_during_test':0,'passed':len(results),'build_env':args.build_env,
            'crc_rejection_and_recovery':True,
            'bitstream_sha256':hashlib.sha256(image.read_bytes()).hexdigest(),
            'source_sha256':source_sha256,
            'constraints_sha256':hashlib.sha256((ROOT/'pins.xdc').read_bytes()).hexdigest(),
            'place_route':timing,'results':results}
    # Keep the machine report compact; full timing paths remain in the .pnr file.
    del report['place_route']['critical_paths']
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(report,indent=2)+'\n')
    print(f'PASS: {len(results)} physical executions, bad-CRC rejection and recovery; {args.output}')


if __name__=='__main__': main()
