"""Host and real UART RTL regressions. Run: py -m unittest -v test_grn."""
import binascii
import json
import os
import random
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from grn_frontend import Network, load_network, parse_expression
from grn_reference import attractor
from grn_run import PROFILE, compile_network, decode_result, execute, run_packet, state_bytes

ROOT = Path(__file__).parent
HW = json.loads(PROFILE.read_text())


def network(expressions):
    return Network(list('ABCD')[:len(expressions)], [parse_expression(s) for s in expressions])


class HostTests(unittest.TestCase):
    def test_reference_transient_and_cycle(self):
        self.assertEqual(attractor(network(['B', '0']), 2),
                         dict(transient=2, period=1, entry_state=0, cycle_states=[0]))
        self.assertEqual(attractor(network(['B', 'A']), 1)['cycle_states'], [1, 2])

    def test_parse_and_lower(self):
        for file in (ROOT / 'examples').iterdir():
            if not file.is_file():
                continue
            net = load_network(file)
            cfg = compile_network(net, HW)
            self.assertEqual(cfg['genes'], 4)
            self.assertGreater(len(run_packet(cfg, 0, len(net.names), HW)), 0)

    def test_unsupported_and_capacity(self):
        for expr in ['!A', 'A ^ B', 'A & B', '1', 'MAJ(A,!B)']:
            with self.subTest(expr=expr), self.assertRaises(ValueError):
                compile_network(network([expr, 'B']), HW)
        with self.assertRaises(ValueError):
            compile_network(Network(list('ABCDE'), [parse_expression('A')]*5), HW)
        with self.assertRaises((ValueError, RuntimeError)):
            compile_network(network(['A']), {**HW, 'depth': 1})

    def test_arbitrary_width_state(self):
        value = (1 << 99) | 1
        self.assertEqual(int.from_bytes(state_bytes(value, 100, 13), 'little'), value)
        for value in [-1, 16]:
            with self.assertRaises(ValueError):
                state_bytes(value, 4, 1)

    def test_bad_source(self):
        for source in ['A && B', 'A + B', '__import__(A)', '(A', 'A B', 'MAJ()']:
            with self.subTest(source=source), self.assertRaises(ValueError):
                parse_expression(source)
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'bad.csv'
            for text in ['gene,expression\nA,B\n', 'A,A\nA,A\n', '']:
                path.write_text(text)
                with self.assertRaises(ValueError):
                    load_network(path)

    def test_transport_errors(self):
        class Port:
            def __init__(self, reply): self.reply = bytearray(reply)
            def write(self, packet): return len(packet)
            def flush(self): pass

            def read(self, count):
                part = bytes(self.reply[:min(count, 2)])
                del self.reply[:len(part)]
                return part
        payload = bytes([2, 2, 2, 1]) + (36).to_bytes(8, 'little')
        frame = b'FR' + payload + binascii.crc_hqx(payload, 0xffff).to_bytes(2, 'little')
        self.assertEqual(execute(Port(b'\x06' + frame), b'packet', 2)['period'], 2)
        with self.assertRaises(ValueError):
            execute(Port(b'\x15'), b'packet', 2)
        with self.assertRaises(TimeoutError):
            execute(Port(b''), b'packet', 2)
        with self.assertRaises(ValueError):
            decode_result(frame[:-1] + bytes([frame[-1] ^ 1]), 2)


class RTLTests(unittest.TestCase):
    def test_uart_against_independent_reference(self):
        """No switch/button actions: serialize actual compiler packets into RTL.

        All states of six networks plus random 4-gene AI graphs; check the first
        slow transition AND period/cycle membership, CRC and cycle accounting.
        """
        suite = Path.home() / '.apio/packages/oss-cad-suite/bin'
        iverilog = shutil.which('iverilog') or str(suite / 'iverilog.exe')
        vvp = shutil.which('vvp') or str(suite / 'vvp.exe')
        if not Path(iverilog).exists():
            self.skipTest('Icarus Verilog unavailable')
        cases = []
        nets = [network(['A']), network(['B', 'A']), network(['B', '0']),
                network(['(A|B)&!C', 'A', 'C']),
                network(['MAJ(A,B,C)', 'B', 'C']),
                network(['A|B|C|D', 'B', 'C', 'D'])]
        rng = random.Random(2010)
        for _ in range(4):
            expressions = []
            for _ in range(4):
                act = rng.sample(list('ABCD'), rng.randint(1, 4))
                inh = rng.sample(list('ABCD'), rng.randint(0, 2))
                expressions.append('(' + '|'.join(act) + ')' +
                                   (' & !(' + '|'.join(inh) + ')' if inh else ''))
            nets.append(network(expressions))
        for net in nets:
            cfg = compile_network(net, HW)
            for seed in range(1 << len(net.names)):
                cases.append((net, seed, run_packet(cfg, seed, len(net.names), HW)))
        statements = []
        for net, seed, packet in cases:
            reference = attractor(net, seed)
            statements += [f'expected_next = 4\'d{net.next_state(seed)}; checked_next = 0; count=0;',
                           *[f'send_byte(8\'h{b:02x});' for b in packet],
                           'fork begin wait(count == 17); end begin repeat(10000) @(negedge clk); $fatal(1,"Result timeout state=%d count=%d", dut.controller_state,count); end join_any disable fork; repeat(20) @(negedge clk);',
                           f'if (response[0] !== 6 || response[5] !== {reference["period"]}) $fatal(1,"ACK/period");',
                           'if (!checked_next) $fatal(1,"Missing next state check");',
                           'if ({response[1],response[2],response[3]} !== 24\'h465202) $fatal(1,"Result header");',
                           f'if (response[4] !== {len(net.names)}) $fatal(1,"Active metadata");',
                           'crc=16\'hffff; for (j=3;j<15;j=j+1) crc=crc_byte(crc,response[j]);',
                           'if ({response[16],response[15]} !== crc) $fatal(1,"Result CRC");',
                           'if (response[7] !== measured_cycles || response[8] !== 0) $fatal(1,"Cycle count");',
                           'if (!(' + ' || '.join(f'response[6] == {s}' for s in reference['cycle_states']) + ')) $fatal(1,"Cycle membership");']
        # CRC-valid semantic failures as well as bad CRC. Recovery is exercised
        # by the next upload, all on the same simulated device.
        packet = cases[0][2]
        bad_packets = [packet[:-1] + bytes([packet[-1] ^ 1])]
        for index, value in [(3, 5), (4, 16), (7, 2), (24, 128)]:
            corrupt = bytearray(packet)
            corrupt[index] = value
            corrupt[-2:] = binascii.crc_hqx(corrupt[2:-2], 0xffff).to_bytes(2, 'little')
            bad_packets.append(bytes(corrupt))
        for packet in bad_packets:
            statements += ['count=0;', *[f'send_byte(8\'h{b:02x});' for b in packet],
                           'wait(count == 1); repeat(20) @(negedge clk);',
                           'if(response[0] !== 21 || leds[15] !== 0) $fatal(1,"Invalid frame accepted");']
        statements += ['count=0;', *[f'send_byte(8\'h{b:02x});' for b in cases[0][2][:8]],
                       'repeat(4500) @(negedge clk);',
                       'if(count !== 1 || response[0] !== 21 || leds[15] !== 0) $fatal(1,"Partial upload timeout");',
                       'count=0;', *[f'send_byte(8\'h{b:02x});' for b in cases[0][2]],
                       'repeat(3000) @(negedge clk);',
                       'if(count !== 17 || response[0] !== 6) $fatal(1,"Recovery after partial upload");']
        source = r'''
module uart_generated_tb;
reg clk=0; always #5 clk=~clk;
// Intentionally never press reset: exercise FPGA power-on initialization.
reg resetn=1, rx=1; wire tx; wire [15:0] leds;
defparam dut.loader.TIMEOUT_CYCLES=3000;
ferreira_board_top #(.BAUD(10000000)) dut(
 .CLK100MHZ(clk),.CPU_RESETN(resetn),.BTNC(1'b0),.SW(4'b1111),
 .UART_TXD_IN(rx),.UART_RXD_OUT(tx),.LED(leds));
reg [7:0] response[0:16]; integer count=0, bitnum, j;
reg [7:0] byte_value; reg [15:0] crc;
reg [3:0] expected_next; reg checked_next=1;
integer measured_cycles=0;
always @(negedge clk) begin
 if (dut.controller_state == 2) measured_cycles=0;
 else if (dut.controller_state == 3 && !dut.core_done) measured_cycles=measured_cycles+1;
end
always @(posedge clk) begin
 if (dut.controller_state == 3 && !checked_next &&
     dut.accelerator.engine.update && !dut.accelerator.engine.active_fast) begin
   #1;
   if (dut.slow_state !== expected_next) $fatal(1,"Wrong first synchronous transition got %h expected %h",dut.slow_state,expected_next);
   checked_next=1;
 end
end
function [15:0] crc_byte(input [15:0] prior,input [7:0] b);
 reg [15:0] c; integer k;
 begin c=prior^{b,8'd0}; for(k=0;k<8;k=k+1) c=c[15]? (c<<1)^16'h1021:c<<1; crc_byte=c; end
endfunction
initial forever begin
 @(negedge tx); repeat(15) @(posedge clk);
 for(bitnum=0;bitnum<8;bitnum=bitnum+1) begin
  byte_value[bitnum]=tx; repeat(10) @(posedge clk);
 end
 if(tx !== 1) $fatal(1,"Stop bit");
 response[count]=byte_value; count=count+1;
end
task send_byte(input [7:0] value);
 integer i;
 begin
  @(negedge clk); rx=0; repeat(10) @(negedge clk);
  for(i=0;i<8;i=i+1) begin rx=value[i]; repeat(10) @(negedge clk); end
  rx=1; repeat(10) @(negedge clk);
 end
endtask
initial begin
 repeat(10) @(negedge clk); resetn=1; repeat(10) @(negedge clk);
''' + '\n'.join(statements) + f'\n$display("PASS: {len(cases)} CPU/RTL UART executions, {len(bad_packets)} invalid frames, timeout and recovery"); $finish; end\n' + '''
initial begin #100000000; $fatal(1,"Global timeout"); end
endmodule
'''
        with tempfile.TemporaryDirectory() as directory:
            tb = Path(directory) / 'uart_generated_tb.v'
            out = Path(directory) / 'sim.out'
            tb.write_text(source)
            rtl = [str(ROOT / f) for f in ['ferreira_board_top.v', 'ferreira_uart.v',
                   'ferreira_uart_loader.v', 'ferreira_engine.v', 'ferreira_system.v',
                                           'ferreira_pe.v', 'ferreira_min.v']]
            env = {**os.environ, 'PATH': str(suite) + os.pathsep +
                   str(suite.parent / 'lib') + os.pathsep + os.environ['PATH']}
            for cmd in [[iverilog, '-g2012', '-s', 'uart_generated_tb', '-o', str(out), *rtl, str(tb)],
                        [vvp, str(out)]]:
                result = subprocess.run(cmd, capture_output=True, text=True, timeout=180, env=env)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                if result.stdout:
                    print(result.stdout.strip())


if __name__ == '__main__':
    unittest.main()
