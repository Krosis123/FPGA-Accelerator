# Runtime interface v3

The physical array is fixed by synthesis. `grn_board_top` defaults to 64 PEs,
two lanes per PE, 128 MIN lines, 32 substeps and MAX_DEGREE=256. At runtime the
host supplies active count, seed, rules, degrees, routing and substep count.
No network edges or update functions are present in this top's Verilog.
`ferreira_system`, `ferreira_engine`, `ferreira_min` and `ferreira_pe` are reused.
The two-state-bank Floyd detector and two-clock routing substep are unchanged.

An optional `PIPE_ROUTING=2` mode registers the middle of the same MIN and aligns
the valid/inhibitor masks, using wait/capture/commit (three clocks per substep).
It is available for timing experiments and the 128-slot simulation pathway.
The selected mode is reported in capabilities; it does not alter Boolean
semantics or the Floyd algorithm. The 64-slot default retains mode 1.

`N`, PE layout, routing geometry and RAM depth are module parameters. The same
source elaborates at 128 slots in integrated simulation. That does not declare
a 128-slot image physically supported or timing validated.

## Layer contracts

* `grn_frontend.Network`: names and Boolean ASTs in declaration order; independent
  of hardware. `load_network` reads CSV/BNET. First gene is state bit zero.
* `grn_reference.attractor`: evaluates ASTs using visited-state history. No
  routing compiler, FPGA transition function or Floyd implementation is reused.
* `compile_network`: exact supported-function lowering, active count validation,
  fan-in/fan-out bounds, then existing greedy MIN routing and route reconstruction.
* `grn_protocol.discover`: queries actual flashed capabilities. An explicitly
  supplied v3 profile is compared against discovery before configuration upload.
* `grn_protocol.run_packet`: packs the physical image plus active count and seed.
  Inactive PEs have zero seed, rule, degree and destination-valid bits.
* `grn_uart_runtime`: stages metadata and writes configuration while execution is
  disabled, validates the transaction, then commits metadata and requests a run.
* `grn_board_top`: automatically resets after programming, resets/arms the retained
  detector per run, counts execution clocks, and queues the result behind ACK.

Active size can be any positive count through the flashed capacity. It is not
restricted to 4/20/50/54/64; those are tested sizes. Each active gene maps to the
same-numbered physical slot. Zero-padding inactive slots preserves synchronous
network dynamics because their outputs stay zero and no valid edges target them.

AI semantics are OR of asserted activators AND NOT OR of asserted inhibitors.
Strict MAJ counts distinct positive inputs and outputs zero on ties. Unsupported
expressions remain in the frontend IR but are rejected during lowering. Functions
are never silently replaced. In particular pure NOT, positive multi-input AND,
XOR, constant one, signed majority and compound/repeated MAJ arguments are not
implemented by this PE backend.

There are two distinct connectivity limits: accumulator width (degree <=256) and
physical scheduling. With K=2 and 32 addresses, a destination can receive at most
64 inputs and a source can supply at most 64 connections per transition. Blocking
MIN conflicts can require additional substeps; routing may reject a graph even
below these necessary bounds. Compiler errors identify count, rule, fan-in,
fan-out, routing failure or exhausted configuration depth.

## Framing

All integers are little endian. UART is 115200 baud, 8N1 by default.

`magic[2] + version:u8 + opcode:u8 + request_id:u16 + payload_bytes:u32 + payload + crc:u16`

Requests use `FG`, responses use `FR`, version is 3. CRC16-CCITT (0x1021,
initial 0xffff) covers version through the last payload byte. Request IDs must
match responses. A response with an invalid CRC or excessive length is rejected
by the host. Only one transaction may be outstanding; there is no implicit retry.

| Request | Opcode | Payload | Response |
|---|---:|---|---|
| Capabilities | 0x01 | Empty | 0x81, capability payload |
| Configure and run | 0x02 | See below | 0x80 empty ACK, then 0x82 result |
| Any rejected request | — | — | 0xff, one-byte reason |

Capability payload, in order:

| Field | Encoding |
|---|---|
| Clock frequency | u32 Hz |
| Physical slots, configuration depth, maximum degree, routing lines | Four u16 values |
| Maximum PE lanes, degree counter width, supported rule bits, routing pipeline | Four u8 values |
| Physical PE capacity | One log2(capacity) byte per slot |

Rule bits are AI=1 and MAJ=2. Routing pipeline=1 denotes two-clock capture/commit;
2 denotes the extra MIN middle register and three-clock wait/capture/commit.
Protocol v3 identifies this particular shuffle-MIN and
AI/MAJ backend; it is not a universal protocol for unidentified architectures.

The profile signature is CRC16 of the entire capability payload. It catches
configuration/image geometry mismatch; full capabilities are also available to
the host. A later incompatible backend must use a new protocol or backend ID.

Run payload:

| Field | Encoding |
|---|---|
| Profile signature, active genes, substeps | Three u16 values |
| Seed, then rule mask | Each ceil(physical_slots/8) bytes |
| Packed degrees | ceil(physical_slots*CW/8) bytes; CW bits per slot |
| Routing rows | substeps * banks * 8 bytes, address order then bank order |

Each row packs `{inhibitor_mask, valid_mask, switch_bits}` with switch bits at the
LSB. Banks are little endian 64-bit words; padding beyond the meaningful width
must be zero. The 64-slot image uses 832-bit rows and 13 banks. Length is
`12 + 6 + 2*8 + 72 + substeps*13*8` bytes including the frame.

Result payload:

| Field | Encoding |
|---|---|
| Profile signature, active genes | Two u16 values |
| Cycle period | ceil((physical_slots+1)/8) bytes |
| Cycle member | ceil(physical_slots/8) bytes |
| Execution cycles | u64 |

The N+1-bit period can represent period 2^N. Results are padded to whole bytes.
The host checks period/state against active width and compares with the CPU
reference. A returned cycle member need not equal the CPU's attractor entry.
Transient length and complete cycle states are still CPU results, not hardware
μ/cycle extraction. This is single-seed detection, not complete enumeration.

## Rejection and reset

Reason codes: 1 CRC, 2 version, 3 opcode/length, 4 profile mismatch, 5 active
count/substeps bounds, 6 seed/rule/degree metadata, 7 routing masks/padding, 8
partial-frame timeout. Reserved and inactive bits must be zero. The FPGA compares
degrees with per-gene valid-lane counts and rejects inhibition on MAJ inputs.
The host independently reconstructs routed source identities; the FPGA does not
recompile the network to verify those logical identities.

During upload graph execution is disabled. Failed/truncated run frames invalidate
the graph. Timeout is 0.5 seconds of no received byte. A valid subsequent request
recovers. A frame start during execution or result transmission is ignored rather
than queued; the host must finish the outstanding result or reset after a timeout.
There is no execution abort/watchdog command yet.

The old four-slot loader/top and v1/v2 uploader are retained. An unframed legacy
NAK during automatic discovery selects the known fixed four-slot v2 profile.
An explicit v3 `--profile` does not fall back to another image. Legacy images
provide no capability query, so their geometry is checked against that fixed
profile and packet version.

## Measurement scope

Execution cycles exclude upload, reset/arm and UART response serialization. The
counter measures clocks following the detector's start edge through done
assertion. Reported execution seconds divide by discovered clock frequency.
Configuration-to-ACK and full transaction times are PC wall-clock observations;
they include serial/USB buffering and response overhead. Pure 8N1 request-wire
time is also recorded. CPU reference and compilation have separate measurements.
No Fmax-only or unrelated-workload speedup is claimed.
