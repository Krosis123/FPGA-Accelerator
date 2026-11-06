# Runtime Boolean GRN accelerator

Active development: `C:\fpga-projects\ferr_config`. The folder
`C:\fpga-projects\2010_paper` is the reference implementation.
Read [AUDIT.md](AUDIT.md) for evidence, limitations, and the implementation plan.

The first software-driven milestone uses the existing heterogeneous four-slot
Ferreira-inspired backend. Networks of 1–4 active genes use the same hardware
image. The interface accepts Python integers of arbitrary width and rejects
seeds/networks that exceed the installed profile; this image has four state bits.
The 54/100-gene experiments are separate core experiments, **not UART profiles**.

```powershell
cd C:\fpga-projects\ferr_config
py -m pip install -r requirements.txt
py grn_run.py --network examples\swap.bnet --seed 0x01 --dry-run
py -m unittest -v test_grn
apio test
apio build
# Program the board once with this new image, when connected:
apio upload
py grn_run.py --network examples\swap.bnet --seed 0x01 --port COM5
```

The received bitstream predates run protocol v2 and must be replaced once.
Subsequent network changes do not need synthesis. No board was programmed during
this development session; only Bluetooth serial ports were visible.

## Network input and semantics

CSV columns are `gene,expression`; BNET columns are `targets,factors` (optional
header). The first declared gene is bit 0, followed by declaration order. Blank
lines and full-line `#` comments are ignored. Quote expressions containing commas.
All referenced genes must be declared exactly once. Updates are synchronous.

The expression IR supports `!`/`~`, `&`, `^`, `|`, parentheses, constants `0`/`1`,
and strict `MAJ(A,B,C)`. Operator precedence is NOT, AND, XOR, OR. No Python code
evaluation is used. The current hardware accepts exactly these recognized forms:

* AI: `(A | B | ...) & !(C | D | ...)`, including a single positive variable,
  a positive OR, and constant zero. Active inhibitor wins. No positive inputs
  means zero. Distinct activation and inhibition edges may share a source.
* MAJ: strict majority of distinct positive gene inputs; ties produce zero.
  Signed majority, repeated inputs, and compound MAJ arguments are rejected.

Other expressions are retained by the parser but rejected by the backend, with
the failing gene named. In particular, pure NOT, constant one, XOR, and AND of
distinct positive inputs are unsupported. They are never approximated.
The older JSON edge compiler/uploader remains usable with protocol v1.

## Results and validation

`grn_run.py` validates the profile, compiles routes with the existing compiler,
computes an independent visited-state CPU reference, uploads, and verifies the
hardware period and returned cycle member. It returns JSON with:

* `hardware`: period, cycle member, 64-bit execution cycles, time at the declared
  clock, upload-to-ACK wall time, and full transaction wall time.
* `reference`: transient length, period, attractor entry, and cycle states.
* Gene indices, active count, physical capacity, substeps, and transmitted bytes.

Transient length and entry/cycle states are **CPU results**, not hardware μ or
cycle extraction. The hardware cycle member can differ from the reference entry.
`--dry-run` never contacts the board and does not claim FPGA verification.
`--max-reference-states` bounds reference memory (default one million visited
states); a reference budget failure stops execution before upload. `--timeout`
sets serial read/write timeout (default 10 seconds). `--emit-hex` writes the exact
run packet for inspection. A mismatch or timeout gives a nonzero process exit.
There are no automatic retries or assumptions that a timeout means completion.

## Reproducible capacity experiments

```powershell
py experiments\scale_check.py --genes 54 100 --pnr
```

The recorded 100-slot layout fails 100 MHz timing; this command records the
failure and exits nonzero after completing the measurements.

This simulates two full-width ring seeds per capacity, then synthesizes and
places/routes a common parameterized experiment wrapper with dynamic serial
configuration registers. Results go to `reports/scale_results.json`; raw logs,
netlists and simulations go to `_build/scale`. Constraints remain 10 ns. The
wrapper provides a way to measure the existing core with few I/O pins; it does
not replace the production UART protocol. Its graph configuration is runtime
writable and is not tied to the ring used in simulation. Synthesis includes
seed/rule/degree/configuration access and period/state readout, but excludes the
production UART controller and its safety checks.

The files `RUNTIME_README.md` and `TIMING_PATCH_README.md` describe received
historical stages. Current behavior and verification are recorded here and in
`AUDIT.md`, `PROTOCOL.md`, and `reports/`.
