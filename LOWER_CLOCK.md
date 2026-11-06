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
apio build -e runtime64-25
apio upload -e runtime64-25
py runtime_validate.py --port COM6 --build-env runtime64-25
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

Physical results are pending. A successful build or simulation is not a board
test. `reports/runtime64_physical.json` is written only when the full physical
regression and bad-CRC rejection/recovery pass.
