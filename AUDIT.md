# Codebase audit and development evidence — 2026-11-06

## Physical bring-up update: startup reset

After the initial milestone below, the user connected the Nexys A7 on COM6.
The current bitstream was uploaded successfully, but a run still timed out
waiting for ACK. Pressing CPU RESET restored communication: swap seed 1 returned
period 2, cycle member 1 and 36 execution cycles, matching Python. This isolates
missing startup reset as a cause of the observed timeout for that programmed
image; simulation had previously always applied external reset.

`ferreira_board_top.v` now holds the design in reset for 15 clocks after FPGA
configuration and synchronizes external reset release. The 106-transaction UART
simulation now starts with CPU_RESETN high and never presses reset. Seven Python
tests and all five legacy APIO tests pass. The new image builds at 104.47 MHz
against the unchanged 100 MHz constraint, was programmed successfully, and ran
immediately without a manual reset.

`hardware_smoke.py --port COM6` then passed 40 physical executions: all seeds of
the two-gene swap, three-gene inhibition and majority, four-gene swap/hold, and a
two-gene transient network. Hardware periods and cycle members matched the
independent CPU reference. Hardware μ/cycle extraction remains unimplemented.
Results and bitstream hash are in `reports/hardware_smoke.json`. The current
build report is `reports/runtime_results.json`; the initial milestone report is
preserved as `reports/runtime_results_before_startup_reset.json`. Historical
no-board statements and the 107.74 MHz figure below refer to that earlier stage.

## Selection and preservation

`C:\fpga-projects\ferr_config` is active. `C:\fpga-projects\2010_paper`
is reference; its `ferr/` and `ferr.zip` hold the earlier ROM-loaded four-gene
architecture. Neither folder had a Git repository. The received active source
was committed as `400920f` before edits. Received bitstream and timing report
were copied into `artifacts/received/` before rebuilding (ignored by Git).
Reference source files were not changed; simulation outputs were regenerated.

The available history is file snapshots, a backup board top, a patch file, and
build/resource artifacts. There is no prior commit history to reconstruct or
proof that a received bitstream was produced by the neighboring source snapshot.

## Components inspected

| Component | Finding on receipt |
|---|---|
| `ferreira_pe.v` | Working chunk accumulation; AI is OR activators AND NOT OR inhibitors. MAJ counts raw asserted valid inputs and ignores inhibitor polarity. State commits at last substep. |
| `ferreira_min.v` | Straight/cross 2x2 switches; perfect shuffle between stages; log2(lines)+2 stages. A blocking network, not demonstrated to be the paper's exact MIN. Includes older routed-MIN/BRAM modules used by tests. |
| `ferreira_system.v` | Parameterized fixed source replication, heterogeneous slots, banked synchronous configuration RAM, lookahead reads. Source and destination slot mapping agrees with compiler. |
| `ferreira_engine.v` | Two state banks time-share routing. Sequential slow, fast, fast transitions; meeting search followed by cycle-length count. Optional routing capture/commit pipeline. Terminal done requires external reset before another run. No hardware μ/entry/cycle extraction. |
| `ferreira_board_top.v` | Runtime graph metadata and routing, but hardcoded four-slot layout. Seed from switches, button launch, LED results. Pipeline enabled. |
| `ferreira_uart.v` | Synchronized RX and 8N1 TX with integer clock divider. Invalid stop bit is discarded; no separate UART framing-error status. |
| `ferreira_uart_loader.v` | v1 CRC-framed graph upload, ACK/NAK, partial-frame timeout. Fixed four-slot protocol. Writes RAM before CRC; reset gating prevents execution of partial configuration. Initially lacked degree-vs-lane validation. |
| `ferreira_compile.py` | Greedy layered path search with switch/wire reservation and deferred substeps. Reconstructs routed sources and edge multiset. JSON integer gene IDs, physical capacities supplied by caller. Assertions and AI/MAJ only; no CSV/BNET frontend or installed-image discovery. Preserved unchanged. |
| `ferreira_upload.py` | Validates fixed four-slot geometry, emits packet, uploads graph. No execution or result reception. Preserved unchanged. |
| Profiles | No separate hardware profile on receipt. Existing uploader embodied the profile. |
| `2010_paper/grn_scalable.v` | Separate two-input-per-gene configurable butterfly backend (AND/OR/XOR/NOT), not the heterogeneous multi-substep backend. Useful reference; not substituted into the active design. |
| `grn_bench_top.v`, `random_logs/` | Serial configuration benchmark and synthesis cell counts at N=4/8/16/32/64. Not evidence of Ferreira UART support or timing/physical correctness at those capacities. |
| Earlier `main`, `configurable_network`, `min_switch2`, board tops | Small fixed-function prototypes and routing tests. Keep as references; no production frontend/protocol. Reference `board_top.v` requires a `GENE_N` macro. |

PE capacities and MIN topology are parameterized hardware choices; graph rules,
degrees, edges, routing and substeps belong in configuration. The new code keeps
that distinction. No new hand-written backend per gene count was introduced.

## Baseline validation rerun

* Reference `ferr/`: all four APIO testbenches pass, including all 16 seeds in
  the integrated four-gene system.
* Received active folder: all five APIO testbenches pass, including pipelined
  integration, UART graph swaps, majority, four substeps, and bad CRC rejection.
  Previously unexecuted-test statements in historical READMEs are now superseded.
* Reference root: all five testbenches pass under Icarus with explicit top
  selection. This includes 8,192 configuration/seed next-state and period checks,
  and scalable-backend smoke tests at 4/8/16/32 genes. Parsing the unused board
  wrapper emits its pre-existing undefined `GENE_N` warning.
* Received active `.pnr`: reported 109.24 MHz against 100 MHz. This corroborates
  a routed artifact for a pipeline-era design, not a physical-board test or
  reproducible source-to-bitstream provenance. The reported 85.35/72.39 MHz
  failures remain historical handoff evidence, not rerun measurements here.

## Implementation plan and first stage delivered

1. Preserve the strongest baseline; establish frontend/profile/compiler/protocol
   contracts before changing the engine.
2. Add expression IR, CSV/BNET parsing, exact AI/MAJ lowering, active-slot padding,
   arbitrary-width seed parsing and capacity rejection. Reuse existing routing.
3. Add a backwards-compatible CRC-framed run request and result channel; retain
   the core PE/MIN/engine and existing graph uploader.
4. Verify through actual serialized compiler packets and an independent CPU
   reference. Build and route at the unchanged 100 MHz constraint.
5. Measure the existing generic core at 54/100 genes before choosing a wider
   UART protocol or a more substantial memory/time-multiplexed architecture.

Steps 1–4 are implemented in `grn_frontend.py`, `grn_reference.py`, `grn_run.py`,
`hardware_profile.json`, and the board/loader changes. The parser IR represents
arbitrary Boolean functions through NOT/AND/OR (also XOR/MAJ), but lowering
deliberately accepts only an exact supported subset. The CPU uses visited-state
history and expression evaluation, independently of RTL Floyd/routing logic.

Regression: seven Python unittest cases pass. The generated RTL test executes
106 transactions on one device instance across 1/2/3/4 active genes, all seeds
of six defined networks and four deterministic random AI graphs. It checks the
first synchronous transition, hardware period, membership of the returned cycle
state, result CRC, active count and measured cycles. It also checks five invalid
frames, stalled-upload timeout and successful recovery. All five legacy APIO
tests pass after changes. Tests run against the UART pins, not an ideal byte-only
mock; a separate short-read host test checks ACK/NAK, CRC failure and timeouts.

The first implementation attempt misplaced the result-transmitter branch in
reset. The UART regression exposed the missing result; it was corrected before
the passing regression/build. Early build timing from that attempt was discarded;
the final build is the one recorded in `reports/runtime_results.json`.

The final runtime image built successfully with Yosys/nextpnr-xilinx/APIO.
`pins.xdc` still specifies 10.000 ns. Refer to `reports/runtime_results.json`
for Fmax, mapped cells, hashes and exact measurement scope. There is no claimed
speedup: no equivalent end-to-end physical CPU/FPGA benchmark was performed.

## Larger-capacity evidence and remaining work

`experiments/scale_top.v` instantiates the unchanged backend with two lanes per
PE and serial-access configuration registers. `scale_check.py` generates the
same wrapper at requested capacities, compiles ring configuration with the
existing compiler, and tests low/high seed bits. The 100-gene high seed exercises
bit 99. Results are in `reports/scale_results.json`. These are correctness smoke
tests and real synthesis/timing experiments, not exhaustive larger-network
verification, production UART images, or an established maximum capacity.

| Exact tested top | Mapped LUT2–6 cells | FF cells | BRAM36 | DSP | Routed Fmax | 100 MHz |
|---|---:|---:|---:|---:|---:|---|
| Production four-slot UART v2 | 1,247 | 845 | 2 | 1 | 107.74 MHz | Pass |
| 54-slot serial experiment, K=2 | 3,488 | 2,472 | 12 | 0 | 115.83 MHz | Pass |
| 100-slot serial experiment, K=2 | 6,871 | 4,497 | 26 | 0 | 81.61 MHz | Fail |

LUT counts are Yosys mapped LUT2–6 cell sums; nextpnr reports different packed
site accounting. Fmax is routed static timing, not a measured board frequency.
The 100-slot critical path is approximately 12.254 ns and begins at the
registered PE input path. The target was not relaxed, the failing result was
retained, and 100 genes is not a supported 100 MHz profile. Resource use and
timing depend on the exact PE layout and wrapper; these rows are not an
equivalent-workload throughput comparison. The full source and parameterized
measurement script are included for reproduction.

Next work: design a versioned width-independent transport with explicit hardware
ID/capability query, lengths and request IDs; parameterize production loader and
result widths; connect 54/100-slot profiles behind the same `grn_run.py` command;
add broader random/full-transition tests on those profiles; validate physically.
Then add hardware μ/entry and a replaceable detector contract. Evaluate memory
or PE time sharing if measured capacity/timing requires it. Do not advertise a
profile as installed based on a software-only JSON change.

Other limitations: no complete enumeration; CPU reference can exhaust its state
budget; no device abort/watchdog command or resume/retry protocol; no hardware
cycle-state extraction; fixed production v2 packet widths; no independent FPGA
source-path semantic validator. UART is stopped-and-waited, not queued.

## Research records

| Classification | Evidence/status |
|---|---|
| Reproduced literature | Ferreira-inspired only. Exact paper MIN, PE allocation, routing algorithm and detector fidelity have not been established from the original paper in this session. Do not label all these mechanisms as Ferreira contributions. |
| Working historical prototype | Four-gene physical demonstration is user-provided evidence; source snapshots and simulations are locally inspectable. No new physical test here. |
| Correctness-validated changes | New frontend/CPU/host transaction and UART execution RTL at 1–4 active genes; tests above. |
| Performance-validated measurements | Routed Fmax/utilization for each report's exact top. Not an end-to-end speedup comparison. |
| Candidate improvements | Wider transport, hardware μ, replaceable detector, time/memory sharing. Unimplemented unless explicitly recorded elsewhere. |
| Failed/negative experiments | Historical unpipelined timing failures; any larger-profile timing failures remain recorded with the 100 MHz target unchanged. |
| Novelty | No novelty claim. Literature comparison and reproducible equivalent-workload benchmarks remain necessary. |
