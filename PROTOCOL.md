# Interface contract, first execution milestone

## Frontend, compiler, and profile

`Network(names, expressions)` preserves stable declaration indices and Boolean
expression trees. The independent reference evaluates those trees directly.
`compile_network(network, profile)` lowers only supported forms, checks active
count, supported rules and fan-in, and calls the existing `compile_graph`.

The profile describes synthesized physical capacities, RAM depth, maximum
degree, clock and protocol. Networks are padded to physical slots with zero
degree, AI rule and zero seed. No edges target those inactive slots. As a result,
inactive states stay zero without changing the existing PE/engine interface.
The existing compiler emits bank writes plus explicit geometry; `build_packet`
checks that geometry against the implemented transport before any serial I/O.
Routing failures and excess substeps/RAM raise errors, not truncated images.

The current layout is four PEs of capacities `[1,2,4,8]`, 16 routing lines,
six stages, 80 meaningful configuration bits, two 64-bit banks and 32 addresses.
MAX_DEGREE is 256, encoded in nine bits per slot. Achievable fan-in is further
bounded by physical lanes, scheduling and the 32-address RAM. Input count is
not inferred from a requested benchmark size.

There is no capability-query command yet. `hardware_profile.json` must match
the flashed image. Version 2 identifies this specific four-slot wire layout;
it must not be reused for a wider layout. An older v1 loader rejects v2.
The CLI remains unchanged when a future wider transport is added behind it.

## UART transaction

8N1, default 115200 baud. All integers are little endian. CRC is CRC16-CCITT
(polynomial 0x1021, initial 0xffff, no reflection/xorout).

Run request:

| Field | Bytes |
|---|---:|
| Magic `FG` | 2 |
| Version `02` | 1 |
| Active genes, 1–4 | 1 |
| Seed (unused bits zero) | 1 |
| Substeps, 1–32 | 1 |
| Rule mask (MAJ=1) | 1 |
| Four packed nine-bit degrees; high four bits zero | 5 |
| For each substep: bank 0 then bank 1 | 16 |
| CRC over version through final bank byte | 2 |

The bank row repeats for every substep: total bytes = `14 + 16*substeps`.
Legacy graph upload v1 omits active count and seed and does not autostart.

An accepted request commits metadata, returns `06` ACK and pulses `run_request`.
The board resets/arms the existing core, launches with the received seed, and
measures rising edges after the start edge through the core's done assertion.
UART transmission and board reset/arm time are excluded from execution cycles.
The result is buffered until the ACK has finished, then sent as:

| Field | Bytes |
|---|---:|
| Magic `FR` | 2 |
| Version `02` | 1 |
| Active genes | 1 |
| Period | 1 |
| Cycle member | 1 |
| Execution cycles | 8 |
| CRC over version through cycles | 2 |

Exactly 16 result bytes follow the ACK. Period/state widths here are properties
of this hardware profile, not limits on the frontend integer representation.

## Failure and lifecycle

A frame disables graph execution before BRAM writes. CRC failure, unsupported
version/metadata, invalid active/seed bits, invalid lane masks, nonzero padding,
inhibitor bits without valid bits, or degrees inconsistent with valid-lane
counts produce `15` NAK and leave computation disabled. Inactive rule/degree
and destination bits must be zero for a run request. A stalled frame times out
after 0.5 seconds at the declared clock, NAKs, and invalidates the graph.
The FPGA does not independently recompile switch paths or check logical source
identities; the host compiler verifies them by reconstruction.

Only one transaction may be outstanding. Frame starts during compute/result
transmission are ignored; the host must wait for the full result. Such a caller
receives a timeout, not a queued execution. After a partial upload, leave at
least the 0.5-second timeout before retrying; no automatic replay occurs.
Reset aborts computation and invalidates the graph. A complete valid upload
recovers from a failed upload. Existing switches/button remain a legacy manual
path; `grn_run.py` needs neither.

The retained core has a terminal done state. The board controller resets and
re-arms it on each run; this behavior is covered by repeated graph/seed tests.
The board also asserts reset for 15 startup clocks after FPGA configuration,
using an initialized saturating counter. External CPU RESET asserts
asynchronously and releases through two synchronizer registers. The startup
reset was added after physical testing found that a fresh upload needed a manual
reset before UART would respond.
The accelerator interface still reports period only, plus pointer states.
Adding hardware μ/entry, alternate detector algorithms, watchdog/abort commands,
request IDs and negotiated capability discovery remains future work.
