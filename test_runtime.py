"""Protocol v3 validation using serialized UART pins and unchanged backend."""
import json
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import grn_protocol as v3
from grn_frontend import Network, parse_expression
from grn_reference import attractor
from grn_run import DEFAULT_PROFILE, compile_network, run_packet
from runtime_cases import cases, file_cases, ring

ROOT = Path(__file__).parent
HW = json.loads(DEFAULT_PROFILE.read_text())


class BytesPort:
    def __init__(self, data=b''): self.data = bytearray(data)
    def read(self, n):
        part = bytes(self.data[:min(n, 3)])
        del self.data[:len(part)]
        return part
    def write(self, data): return len(data)
    def flush(self): pass


class HostTests(unittest.TestCase):
    def test_parser_independent_of_capacity(self):
        for generated,parsed in zip(cases(),file_cases()):
            self.assertEqual(generated,parsed)
    def test_capability_discovery_and_failures(self):
        profile = v3.discover(BytesPort(v3.frame(0x81, 1, v3.capability_payload(HW), b'FR')))
        self.assertEqual(profile['capacities'], [2]*64)
        self.assertEqual(profile['capability_crc'], HW['capability_crc'])
        for reply in [b'\x15', v3.frame(0xff, 1, b'\x04', b'FR'),
                      v3.frame(0x81, 2, b'', b'FR')]:
            with self.assertRaises(ValueError): v3.discover(BytesPort(reply))
        corrupt = bytearray(v3.frame(0x81, 1, v3.capability_payload(HW), b'FR'))
        corrupt[-1] ^= 1
        with self.assertRaises(ValueError): v3.discover(BytesPort(corrupt))

    def test_capacity_and_rules(self):
        for n in [4, 20, 50, 54, 64]:
            cfg = compile_network(ring(n), HW)
            packet = run_packet(cfg, 1 << (n-1), n, HW)
            self.assertEqual(cfg['genes'], 64)
            self.assertEqual(int.from_bytes(packet[16:24], 'little'), 1 << (n-1))
        with self.assertRaisesRegex(ValueError, '65 genes'):
            compile_network(ring(65), HW)
        with self.assertRaisesRegex(ValueError, 'G0'):
            compile_network(Network(['G0'], [parse_expression('!G0')]), HW)
        with self.assertRaisesRegex(ValueError, 'Seed|seed'):
            run_packet(compile_network(ring(4), HW), 16, 4, HW)
        # A broad broadcast requires >32 substeps because source copies are
        # finite. This is a scheduling rejection, not an arbitrary gene limit.
        net = Network([f'G{i}' for i in range(64)], [parse_expression('G0')]*64)
        cfg = compile_network(net, HW)
        self.assertEqual(cfg['substeps'], 32)
        too_dense = Network([f'G{i}' for i in range(64)],
            [parse_expression('('+'|'.join(f'G{i}' for i in range(64))+') & !G0')]+
            [parse_expression('0')]*63)
        with self.assertRaisesRegex(ValueError,'fan-in 65 exceeds 2 lanes x 32 substeps'):
            compile_network(too_dense,HW)


class RTLTests(unittest.TestCase):
    def simulate(self, profile, items, exercise_errors=True, label=''):
        n = len(profile['capacities'])
        suite = Path.home()/'.apio/packages/oss-cad-suite'
        if not (suite/'bin/iverilog.exe').exists(): self.skipTest('Icarus not installed')
        packets, expectations = [], []
        # Query then many unrelated graphs, no reset or resynthesis in between.
        packets.append(v3.frame(1, 1))
        expectations.append(('capability', 1, None))
        for ident, (name, net, seed) in enumerate(items, 2):
            cfg = compile_network(net, profile)
            packets.append(v3.run_packet(cfg, seed, len(net.names), profile, ident))
            expectations.append((name, ident, (net, seed, cfg)))
        if exercise_errors:
            valid = packets[1]
            # Integrity, profile, inactive seed, degree, inactive rules, routing mask.
            first_cfg=compile_network(items[0][1],profile)
            data_offset=16+2*((n+7)//8)+(n*9+7)//8
            row=int.from_bytes(valid[data_offset:data_offset+8*first_cfg['banks']],'little')
            valid_mask=(row>>first_cfg['switch_width'])&((1<<profile['route_n'])-1)
            free_lane=next(i for i in range(profile['route_n']) if not (valid_mask>>i)&1)
            inhibit_bit=first_cfg['switch_width']+profile['route_n']+free_lane
            mutations = [(-1, 1, False, 1), (10, 1, True, 4),
                         (16+(n+7)//8-1, 128, True, 6),
                         (16+2*((n+7)//8), 1, True, 6),
                         (16+(n+7)//8+(n+7)//8-1, 128, True, 6),
                         (12, valid[12], True, 5),
                         (12, valid[12]^(n+1), True, 5),
                         (14, valid[14], True, 5),
                         (14, valid[14]^33, True, 5),
                         (data_offset+inhibit_bit//8,1<<(inhibit_bit%8),True,7)]
            for index, delta, recalc, code in mutations:
                bad = bytearray(valid)
                bad[index] ^= delta
                if recalc: bad[-2:] = v3.crc(bad[2:-2]).to_bytes(2, 'little')
                packets.append(bytes(bad))
                expectations.append((f'invalid_{code}', 2, None))
            invalid_version=bytearray(v3.frame(1,2)); invalid_version[2]=4
            invalid_version[-2:]=v3.crc(invalid_version[2:-2]).to_bytes(2,'little')
            invalid_length=bytearray(v3.frame(2,2)); invalid_length[6:10]=(0xffffffff).to_bytes(4,'little')
            invalid_length[-2:]=v3.crc(invalid_length[2:-2]).to_bytes(2,'little')
            packets += [bytes(invalid_version),v3.frame(99,2),bytes(invalid_length)]
            expectations += [('invalid_2',2,None),('invalid_3',2,None),('invalid_3',2,None)]
            # Timeout after an incomplete frame, then complete recovery.
            packets += [valid[:22], valid]
            expectations += [('timeout', 2, None), ('recovery', 2, expectations[1][2])]
        else:
            bad=bytearray(packets[1]);bad[12:14]=(n+1).to_bytes(2,'little')
            bad[-2:]=v3.crc(bad[2:-2]).to_bytes(2,'little')
            packets.append(bytes(bad));expectations.append(('invalid_5',2,None))
        statements = []
        cursor = 0
        for packet, expectation in zip(packets, expectations):
            kind, ident, item = expectation
            statements.append(f'count=0; $fdisplay(log,"CASE {cursor}"); $fflush(log); '
                              f'$fdisplay(progress,"case {cursor}"); $fflush(progress);')
            if item:
                net, seed, cfg = item
                statements.append(f"expected_next={n}'h{net.next_state(seed):x}; checked=0;")
            else: statements.append('checked=1;')
            oracle=attractor(net,seed) if item else None
            deadline=max(40000,(4*(profile['pipe_routing']+1)*cfg['substeps']+2)*
                         (oracle['transient']+oracle['period']+1)+20000) if item else 40000
            statements.extend(f"send_byte(8'h{b:02x});" for b in packet)
            # Known total response lengths: query frame, or ACK+result frames.
            length = 12 + 16+n if kind=='capability' else (
                24 + 4+(n+8)//8+(n+7)//8+8 if item else 13)
            statements.append(f'''fork begin wait(count=={length}); end
begin repeat({deadline}) @(negedge clk); $fatal(1,"response timeout case {cursor}, count=%d state=%d",count,dut.loader.state); end
join_any disable fork;
repeat(40) @(negedge clk);
if(!checked) $fatal(1,"missing next-state check");
for(j=0;j<count;j=j+1) $fwrite(log,"%02x",response[j]);
$fwrite(log,"\\n"); $fflush(log);''')
            cursor += 1
        statements.append('$fclose(log); $display("PASS: integrated generic UART cases"); $finish;')
        with tempfile.TemporaryDirectory() as temporary:
            temp = Path(temporary)
            logfile = ROOT/'_build'/f'runtime{n}{label}_responses.txt'
            progressfile = ROOT/'_build'/f'runtime{n}{label}_progress.txt'
            source = f'''`timescale 1ns/1ps
module runtime_generated_tb;
reg clk=0; always #5 clk=~clk;
reg rx=1; wire tx; wire [15:0] led;
grn_board_top #(.N({n}),.BAUD(12500000),.PIPE_ROUTING({profile['pipe_routing']})) dut(
 .CLK100MHZ(clk),.CPU_RESETN(1'b1),.BTNC(1'b0),.SW(4'b0),
 .UART_TXD_IN(rx),.UART_RXD_OUT(tx),.LED(led));
defparam dut.loader.TIMEOUT_CYCLES=4000;
reg [7:0] response[0:2047], received;
integer count=0,b,j,log,progress,ticks=0; reg checked=1; reg [{n-1}:0] expected_next;
always @(posedge clk) begin
 ticks=ticks+1;
 if(ticks%10000==0) begin
  $fdisplay(progress,"tick %d core stage %d period %d",ticks,dut.accelerator.engine.stage,dut.period);
  $fflush(progress);
 end
end
always @(posedge clk) if(dut.stage==3 && !checked &&
 dut.accelerator.engine.update && !dut.accelerator.engine.active_fast) begin
 #1; if(dut.slow_state !== expected_next) $fatal(1,"wrong synchronous transition"); checked=1;
end
initial forever begin
 @(negedge tx); repeat(12) @(posedge clk);
 for(b=0;b<8;b=b+1) begin received[b]=tx; repeat(8) @(posedge clk); end
 if(tx !== 1) $fatal(1,"stop bit"); response[count]=received; count=count+1;
end
task send_byte(input [7:0] value);
 integer i;
 begin
 @(negedge clk); rx=0; repeat(8) @(negedge clk);
 for(i=0;i<8;i=i+1) begin rx=value[i]; repeat(8) @(negedge clk); end
 rx=1; repeat(8) @(negedge clk);
 end
endtask
initial begin
 log=$fopen("{logfile.as_posix()}","w");
 progress=$fopen("{progressfile.as_posix()}","w");
 repeat(40) @(negedge clk);
{chr(10).join(statements)}
end
initial begin #200000000; $fatal(1,"global timeout"); end
endmodule
'''
            tb=temp/'runtime_tb.v'; tb.write_text(source)
            out=temp/'sim.out'
            rtl=[str(ROOT/f) for f in ['grn_board_top.v','grn_uart_runtime.v','ferreira_uart.v',
                                      'ferreira_system.v','ferreira_engine.v','ferreira_min.v','ferreira_pe.v']]
            source_hashes={Path(f).name:hashlib.sha256(Path(f).read_bytes()).hexdigest() for f in rtl}
            env={**os.environ, 'PATH':str(suite/'bin')+os.pathsep+str(suite/'lib')+os.pathsep+os.environ['PATH']}
            for command in [[str(suite/'bin/iverilog.exe'),'-g2012','-s','runtime_generated_tb','-o',str(out),*rtl,str(tb)],
                            [str(suite/'bin/vvp.exe'),str(out)]]:
                result=subprocess.run(command,capture_output=True,text=True,env=env,timeout=1200)
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            verified=[]
            lines=logfile.read_text().splitlines()
            for index,(kind,ident,item) in enumerate(expectations):
                data=bytes.fromhex(lines[2*index+1])
                if kind=='capability':
                    discovered=v3.discover(BytesPort(data))
                    self.assertEqual(v3.capability_payload(discovered),v3.capability_payload(profile))
                elif item:
                    net,seed,cfg=item
                    cpu=attractor(net,seed)
                    hardware=v3.execute(BytesPort(data),v3.run_packet(cfg,seed,len(net.names),profile,ident),len(net.names),profile)
                    self.assertEqual(hardware['period'],cpu['period'],kind)
                    self.assertIn(hardware['cycle_member'],cpu['cycle_states'],kind)
                    self.assertGreater(hardware['execution_cycles'],0)
                    meeting=cpu['period']*max(1,(cpu['transient']+cpu['period']-1)//cpu['period'])
                    update_clocks=cfg['substeps']*(profile['pipe_routing']+1)
                    expected_cycles=meeting*(3*update_clocks+1)+cpu['period']*(update_clocks+1)
                    self.assertEqual(hardware['execution_cycles'],expected_cycles,kind)
                    verified.append({'case':kind,'active':len(net.names),'seed':hex(seed),
                                     'period':cpu['period'],'transient':cpu['transient'],
                                     'execution_cycles':hardware['execution_cycles']})
                else:
                    code=8 if kind=='timeout' else int(kind.split('_')[1])
                    with self.assertRaisesRegex(ValueError,f'code {code}'):
                        v3.receive(BytesPort(data),ident)
            (ROOT/'_build'/f'runtime{n}{label}_simulation_manifest.json').write_text(json.dumps({
                'profile':profile,'uart_simulation_baud':12500000,
                'source_sha256':source_hashes,'testbench_sha256':hashlib.sha256(source.encode()).hexdigest(),
                'transactions':len(expectations),'request_sha256':[hashlib.sha256(p).hexdigest() for p in packets],
                'verified_runs':verified},indent=2)+'\n')
            print(f'PASS: {n}-slot integrated UART simulation, {len(expectations)} transactions')

    def test_runtime64(self):
        self.simulate(HW,file_cases())

    def test_small_v3_rejections(self):
        profile={**HW,'capacities':[2]*4,'route_n':8,'seed_bytes':1}
        self.simulate(profile,[('ring4',ring(4),1)])

    def test_zero_degree_control_flags(self):
        net=Network([f'G{i}' for i in range(4)],[parse_expression('0')]*4)
        for pipeline in (1,2):
            profile={**HW,'capacities':[2]*4,'route_n':8,'seed_bytes':1,'pipe_routing':pipeline}
            self.simulate(profile,[('constant4',net,15)])

    def test_fanin64_boundary(self):
        items=file_cases()
        self.simulate(HW,[items[0]]+[item for item in items if item[0].startswith('majority64')],
                      exercise_errors=False,label='_fanin64')

    def test_parameterized128_path(self):
        profile={**HW,'capacities':[2]*128,'route_n':256,'seed_bytes':16,'pipe_routing':2}
        # A small network and a high-bit full-capacity seed use identical RTL.
        self.simulate(profile,[('small4',ring(4),1),('ring128',ring(128),1<<127)],exercise_errors=False)


if __name__=='__main__': unittest.main()
