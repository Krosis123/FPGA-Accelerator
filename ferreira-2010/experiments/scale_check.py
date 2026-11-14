"""Simulate and optionally synthesize/place the existing core at chosen capacities.

Run from active project: py experiments/scale_check.py --genes 54 100 --synth
--pnr adds actual 100 MHz timing using a serial-access experiment top.
Neither result establishes production UART support or physical FPGA validation.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from ferreira_compile import compile_graph


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--genes', type=int, nargs='+', default=[54, 100])
    p.add_argument('--synth', action='store_true')
    p.add_argument('--pnr', action='store_true')
    args = p.parse_args()
    packages = Path.home() / '.apio/packages'
    suite = packages / 'oss-cad-suite'
    openxc7 = packages / 'openxc7'
    env = {**os.environ, 'PATH': os.pathsep.join(map(str, [suite/'bin', suite/'lib',
                                                           openxc7/'bin', openxc7/'lib'])) + os.pathsep + os.environ['PATH']}
    out = ROOT / '_build/scale'
    out.mkdir(parents=True, exist_ok=True)
    sources = [str(ROOT / name) for name in ['ferreira_system.v', 'ferreira_min.v',
                                             'ferreira_engine.v', 'ferreira_pe.v']]
    summary = []

    def run(command, log, timeout=600):
        with log.open('w') as stream:
            subprocess.run(command, cwd=ROOT, env=env, stdout=stream,
                           stderr=subprocess.STDOUT, check=True, timeout=timeout)

    for n in args.genes:
        if n < 2:
            raise ValueError('Capacity experiment requires at least two genes')
        cfg = compile_graph({'genes': n, 'capacities': [2]*n,
                             'edges': [{'src': i, 'dst': (i+1) % n, 'type': 'A'} for i in range(n)]})
        statements = []
        for word in cfg['writes']:
            statements.append(
                f"@(negedge clk); we=1; addr={word['addr']}; bank={word['bank']}; data=64'h{word['data']};")
        # Two seeds including the highest physical bit, loaded without switches.
        # Both networks are full-width rings; no graph information in core RTL.
        source = f'''module scale_tb;
reg clk=0; always #5 clk=~clk;
reg reset=1,start=0,we=0;
reg [{n-1}:0] seed=1;
reg [4:0] addr=0; reg [{max(1, (cfg['banks']-1).bit_length())-1}:0] bank=0;
reg [63:0] data=0;
wire done; wire [{n}:0] period; wire [{n-1}:0] state;
ferreira_system #(.N({n}),.KMAX(2),.ROUTE_N({cfg['route_n']}),
 .SUBSTEPS(32),.RUNTIME_CONFIG(1),.PIPE_ROUTING(1),.DEPTH(32),
 .CAP_LOG2({3*n}'h{int(cfg['cap_log2_verilog'].split("'h")[1], 16):x})) core(
 .clk(clk),.reset(reset),.start(start),.seed(seed),
 .last_substep_index(5'd{cfg['substeps']-1}),.cfg_write_en(we),
 .cfg_write_addr(addr),.cfg_write_bank(bank),.cfg_write_data(data),
 .rule({n}'d0),.degree({cfg['degree_verilog']}),
 .done(done),.period(period),.slow_state(state),.fast_state(),.substep(),.phase2());
task launch;
 begin
 @(negedge clk); reset=1; repeat(3) @(negedge clk);
 reset=0; start=1; @(negedge clk); start=0;
 wait(done); #1;
 if(period !== {n}) $fatal(1,"Wrong ring period");
 if(state == 0 || (state & (state-1)) != 0) $fatal(1,"Invalid ring cycle state");
 end
endtask
initial begin
 repeat(3) @(negedge clk);
 {chr(10).join(statements)}
 @(negedge clk); we=0;
 launch(); seed={n}'h{1 << (n-1):x}; launch();
 $display("PASS: N={n}, ring period={n}, low and high seed bits, substeps={cfg['substeps']}"); $finish;
end
initial begin #10000000; $fatal(1,"Capacity simulation timeout"); end
endmodule'''
        tb = out / f'n{n}_tb.v'
        tb.write_text(source)
        sim = out / f'n{n}.out'
        run([str(suite/'bin/iverilog.exe'), '-g2012', '-s', 'scale_tb', '-o', str(sim),
             *sources, str(tb)], out / f'n{n}_compile.log')
        run([str(suite/'bin/vvp.exe'), str(sim)], out / f'n{n}_simulation.log')
        record = {'genes': n, 'capacities': [2]*n, 'route_n': cfg['route_n'],
                  'banks': cfg['banks'], 'substeps': cfg['substeps'],
                  'simulation': (out / f'n{n}_simulation.log').read_text().strip(),
                  'production_uart_supported': False}
        print(record['simulation'], flush=True)
        if args.synth or args.pnr:
            design = out / f'n{n}.json'
            ys = out / f'n{n}.ys'
            ys.write_text('read_verilog ' + ' '.join('"'+s.replace('\\', '/')+'"' for s in
                          [*sources, str(ROOT/'experiments/scale_top.v')]) + '\n' +
                          f'chparam -set N {n} scale_top\n' +
                          'synth_xilinx -family xc7 -top scale_top -flatten\n' +
                          f'write_json "{design.as_posix()}"\n')
            run([str(suite/'bin/yosys.exe'), '-s', str(ys)], out / f'n{n}_synthesis.log')
            import collections
            cells = collections.Counter(c['type'] for c in
                                        json.loads(design.read_text())['modules']['scale_top']['cells'].values())
            record['synthesis_cells'] = dict(sorted(cells.items()))
            if args.pnr:
                xdc = out / 'scale.xdc'
                xdc.write_text('create_clock -period 10.000 [get_ports {clk}]\n' + '\n'.join(
                    f'set_property -dict {{PACKAGE_PIN {pin} IOSTANDARD LVCMOS33}} [get_ports {{{port}}}]'
                    for port, pin in zip(['clk', 'reset', 'start', 'shift_en', 'shift_bit', 'write_en', 'read_en', 'result_bit', 'done'],
                                         ['E3', 'C12', 'N17', 'J15', 'L16', 'M13', 'R15', 'H17', 'K15'])))
                report = out / f'n{n}.pnr'
                command = [str(openxc7/'bin/nextpnr-xilinx.exe'), '--device', 'xc7a100tcsg324-1',
                           '-o', f'xdc={xdc}', '--json', str(design), '--report', str(report)]
                try:
                    run(command, out / f'n{n}_pnr.log')
                    record['place_route_pass'] = True
                except subprocess.CalledProcessError:
                    record['place_route_pass'] = False
                if report.exists():
                    report_data = json.loads(report.read_text())
                    record['fmax'] = report_data['fmax']
                    record['utilization'] = {k: v for k,
                                             v in report_data['utilization'].items() if v['used']}
        summary.append(record)
        (ROOT/'reports/scale_results.json').write_text(json.dumps(summary, indent=2))
    if any(record.get('place_route_pass') is False for record in summary):
        print('Timing/place-route failure recorded; target remains 100 MHz.', file=sys.stderr)
        raise SystemExit(1)


if __name__ == '__main__':
    main()
