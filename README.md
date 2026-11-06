# Runtime-configurable Boolean GRN accelerator

Active: `C:\fpga-projects\ferr_config`. Reference: `C:\fpga-projects\2010_paper`.
The original four-slot code is retained; see `LEGACY_RUNTIME2.md` for its history.

Status: the parameterized 64-slot UART implementation has passed integrated
simulation, including a mixed 54-gene network with period 3,465. A generated
25 MHz full-image build is being qualified; 100 MHz remains a later performance
target. Physical verification is pending. Isolated-core timing alone
does not establish full-image support.

## Build and run

```powershell
cd C:\fpga-projects\ferr_config
py -m pip install -r requirements.txt
py -m unittest -v test_grn test_runtime
apio test
apio build -e runtime64-25
apio upload -e runtime64-25
py ferreira_upload.py --list-ports
py grn_run.py --network examples\swap.bnet --seed 0x01 --port COM6
py grn_run.py --network examples\runtime\ring50.bnet --seed 0x2000000000000 --port COM6
py grn_run.py --network examples\runtime\mixed54.csv --seed 0x20000000201021 --port COM6 > mixed54_result.json
```

Use the actual board COM port. Startup reset is automatic. After programming,
different networks and seeds need only another `grn_run.py` command. No switch
settings, source edits or resynthesis are involved. A power cycle can discard the
SRAM image; upload the intended image again when needed.

The host queries the flashed capacity, validates resources and rules, compiles
with the existing router, uploads and runs, then checks the results against an
independent Python model. The image has 64 physical PEs with two lanes each and
32 configuration addresses; active count is separate from physical capacity.

Without an explicit environment, APIO still selects the preserved four-slot image.
Automatic CLI discovery recognizes its legacy NAK and selects the fixed v2
profile. Explicit legacy selection is `--profile hardware_profile.json`.

```powershell
py grn_run.py --network examples\runtime\ring50.bnet --seed 0x2000000000000 --dry-run
```

Dry-run defaults to `profiles/runtime64.json` and never claims FPGA execution.
Use `--profile profiles/runtime64-25.json` for a 25 MHz dry-run packet. Live
execution discovers the installed clock and capacities automatically.
An explicit live v3 `--profile` must match discovery. A JSON profile alone cannot
extend a hardware image's capacity.

## Inputs and supported rules

CSV is `gene,expression`; BNET is `targets,factors` (header optional). First
declaration is bit zero. Gene indices remain stable; quote expressions containing
commas. All referenced genes must be declared exactly once. Updates are synchronous.

The hardware-independent AST represents NOT, AND, OR, XOR, constants and MAJ.
The current backend implements exactly:

* AI: `(A | B | ...) & !(C | D | ...)`, positive OR/variables, and zero.
* MAJ: strict majority of distinct positive gene inputs; ties produce zero.

Other expressions are rejected with the failing gene named. Pure NOT, constant
one, positive multi-input AND, XOR, signed majority and compound/repeated MAJ
arguments are not approximated.

Active size can be any positive count through the flashed capacity, subject to
connectivity and scheduling. With two lanes and 32 substeps, necessary bounds are
64 inputs per destination and 64 outgoing connections per source. Blocking MIN
conflicts can impose stricter limits. Errors identify count, rule, fan-in,
fan-out, routing failure or exhausted configuration RAM.

## Results and validation

The retained Floyd engine advances slow/fast/fast until a meeting, then counts a
cycle. Hardware returns period, a cycle member and execution cycles. The period
field uses N+1 bits. Python independently evaluates ASTs using visited-state
history and supplies transient length, entry and cycle states under `reference`.
Hardware transient/cycle-state extraction is unfinished. This is single-seed
detection, not enumeration of every attractor.

JSON separates reference time, transfer-to-ACK and transaction wall time from
hardware cycles/time at the declared clock. `--timeout` controls serial timeouts;
`--max-reference-states` bounds CPU memory. Errors, unsupported inputs and result
disagreements cause nonzero exit. No Fmax-only speedup is claimed.

```powershell
py runtime_validate.py --port COM6 --build-env runtime64-25
```

This regression uses one connection and no programming calls between different
4/20/50/54/64-gene graphs. Cases include a 50-node ring, a 54-node network with
four feedback components driving a majority/inhibition chain, and a 64-gene
broadcast using all 32 substeps. Results, timings and image hash are written to
`reports/runtime64_physical.json`; bad-CRC rejection and recovery are checked.

`test_runtime.py` exercises actual UART pins and the integrated backend. The same
RTL also elaborates at 128 slots with seed bit 127 set. That is a pathway check,
not a claim of 128-slot timing or physical support. See `RUNTIME_V3.md` for wire
format and layer contracts, `AUDIT.md` for history, and `reports/` for evidence.
