# Functional qualification at a generated lower clock

The simulation-verified 64-slot RTL checkpoint is `8ab1481`. All seven core
RTL source hashes match the saved 64-slot, fan-in boundary, and 128-slot
simulation manifests in `reports/checkpoint_8ab1481_simulation.json`.
This checkpoint alone does not establish physical 64-slot operation.

No PE, MIN, Floyd, or pipeline changes are made for the lower-clock image.
`grn_clock25_top.v` wraps the existing `grn_board_top`:

* Board oscillator: 100 MHz; `pins.xdc` still specifies 10.000 ns.
* MMCME2_BASE: input divide 1, feedback multiply 8, output divide 32.
* VCO: 800 MHz; accelerator clock: 25 MHz, routed through BUFG.
* A separate BUFG closes the MMCM feedback path.
* Runtime reset remains asserted until MMCM LOCKED and external reset release.
* Entire runtime, including UART, executes in the 25 MHz domain.
* UART remains nominal 115200 baud, divider 217; actual TX baud is
  115207.373 (approximately +0.0064%). Clock capability advertises 25000000 Hz.

Nextpnr automatically derives the MMCM clocks from the unchanged 100 MHz
input constraint and primitive parameters. The pack-stage clock-check log
explicitly reports 25.0 MHz for both `clock_raw` and `clock25`. Final routed
timing must also report the 25 MHz constraint and pass it before programming.
This is a changed physical clock, not a relaxed constraint on a 100 MHz design.

The clock primitive settings follow AMD's
[MMCME2_BASE documentation](https://docs.amd.com/r/2024.2-English/ug953-vivado-7series-libraries/MMCME2_BASE).
Behavioral integration simulations drive the runtime directly at 25 MHz;
they do not model analog MMCM behavior or verify electrical clock quality.
The UART testbench separately exercises all 256 byte values against nominal
115200-baud waveforms at the actual 25 MHz clock.

```powershell
cd C:\fpga-projects\ferr_config
apio build -e runtime64-25-spread
apio upload -e runtime64-25-spread
py runtime_validate.py --port COM6 --build-env runtime64-25-spread
py grn_run.py --network examples\runtime\ring50.bnet --seed 0x2000000000000 --port COM6
py grn_run.py --network examples\runtime\mixed54.csv --seed 0x20000000201021 --port COM6
py grn_run.py --network examples\runtime\broadcast64.bnet --seed 1 --port COM6
```

The regression uses one serial connection without reprogramming. Its file-backed
inputs include ring50, mixed54, broadcast64, and majority64: distinct feedback,
mixed-rule/component, fan-out, and fan-in topologies, plus smaller graphs.
It compares FPGA period and cycle member with the independent AST/visited-state
CPU implementation, and measured execution clocks with the Floyd schedule.
Hardware does not yet return transient length; that field is from the CPU.

## Evidence preservation

Existing source and results remain in place. The unfinished 100 MHz routing
attempt was stopped at iteration 68 (1,138 overused wires), without a final
timing result. Its build directory is copied to
`artifacts/checkpoint-64-100mhz/build`, and its log to
`reports/build-runtime64-100mhz-preserved.log`. Earlier failed reports and logs
are retained. An additional queued 100 MHz build was also stopped; it did not
produce a qualified bitstream. The 100 MHz image remains a later performance
target. The lower-frequency build uses its own `_build/runtime64-25` directory.

## Physical qualification: 2026-11-07

The full image was loaded through JTAG with openFPGALoader `--verify`, then
tested on COM6. The FPGA was identified as XC7A100T (JTAG ID 0x03631093).
One serial connection performed 27 runs without any programming calls between
graphs, followed by corrupt-CRC rejection and successful recovery. All FPGA
periods and returned cycle members matched the independent CPU oracle. All
measured execution clocks matched the independently calculated Floyd schedule.
The four networks below were also run individually through `grn_run.py`, still
without reprogramming. See `reports/*_physical_cli.json` for those full results.

| Network | Genes | Edges | Substeps | FPGA period | CPU transient | FPGA clocks | Compute time at 25 MHz | Observed request-to-ACK |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| ring50 | 50 | 50 | 2 | 50 | 0 | 1300 | 52 us | 37.295 ms |
| mixed54 | 54 | 113 | 4 | 3465 | 2 | 173250 | 6.930 ms | 61.532 ms |
| broadcast64 | 64 | 64 | 32 | 1 | 1 | 386 | 15.44 us | 308.747 ms |
| majority64_full | 64 | 127 | 32 | 1 | 0 | 386 | 15.44 us | 303.838 ms |

Request sizes are 314, 522, 3434 and 3434 bytes respectively. Their nominal
115200-baud 8N1 wire times are 27.257, 45.313, 298.090 and 298.090 ms. ACK and
transaction times are PC observations: USB/driver buffering can deliver the
ACK after computation has already finished. They do not isolate pure FPGA
configuration time. CPU/reference/compile and transaction times remain separate
in `reports/runtime64_physical.json`. No end-to-end speedup is established here.

The qualified build uses nextpnr's `--placer-heap-congestion-spread` and router2.
This tool-level change resolved the observed routing congestion without changing
the RTL. Routing ended with zero overused wires, and router1 legality checking
passed. Total build time was 442.65 s. Other unfinished 25 MHz tool attempts
were stopped after this success and copied to `artifacts/lower-clock-unfinished`;
their logs remain in `reports`. They have no final Fmax, rather than a measured
timing failure.

* Operating frequency: generated 25 MHz; original oscillator constraint: 100 MHz.
* Final routed Fmax estimate: 123.137543 MHz at the 25 MHz constraint.
* Yosys primitives: 7015 LUT2..LUT6, 6584 FFs, 12 RAMB36E1, 0 DSPs, 783 CARRY4.
* Nextpnr reports 11464 SLICE_LUTX BELs, 6584 SLICE_FFX, 12 RAMB36E1,
  785 CARRY4, one MMCM and two BUFGCTRLs. Its LUTX availability/count convention
  differs from the synthesis primitive count; both raw reports are retained.
* Bitstream SHA256:
  `998ba901453945cd00f4649d9d1f9ab019d707cc3a8e0376267d45da2d749b24`.
* Integrated 25 MHz UART simulation: 43 transactions, source-hash matched.
* Host/legacy integration: 10 Python tests, including 106 legacy UART runs.
* APIO: six testbenches passed, including all 256 UART bytes at 25 MHz/115200.

The routed estimate does not qualify a separate 100 MHz image or establish
silicon Fmax. 128 slots remain simulation-only. Hardware still returns period,
a cycle member and execution clocks; transient/entry/cycle lists come from the
CPU. Supported functions remain exact AI/MAJ with the declared routing limits,
not unrestricted Boolean expressions or complete attractor enumeration.
