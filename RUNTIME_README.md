# Runtime-configurable Ferreira-style FPGA prototype

The physical hardware remains a four-gene array with PE capacities
`[1,2,4,8]`, `ROUTE_N=16`, `MAX_DEGREE=256`, and 32 configuration
addresses (up to 32 active substeps). It accepts different graphs
without re-synthesizing: routing bits, valid/inhibitor masks, Boolean
rules, degrees and substep count change at runtime. It does **not**
change the number of genes or PE capacities at runtime. It supports
only the AI and MAJ rule types from the existing compiler.

## Files that changed

- `ferreira_engine.v`: optional dynamic last-substep index; original
  parameterized behavior preserved for legacy tests (`RUNTIME_CONFIG=0`).
- `ferreira_system.v`: passes runtime last-substep index through.
- `ferreira_board_top.v`: new UART-driven top replacing startup ROM.
- `ferreira_uart.v`: synthesizable 8N1 115200-baud UART RX/TX.
- `ferreira_uart_loader.v`: framed CRC-checked graph loader.
- `ferreira_upload.py`: Python host uploader, validates hardware compatibility.
- `pins.xdc`: adds C4 PC->FPGA UART and D4 FPGA->PC UART.
- `apio.ini`: uses flatten (worked around a previous CARRY4 placement failure).

The legacy board top was renamed to `ferreira_board_top_original.v.bak`
so it is not synthesized as a duplicate top-level module.

## Quick start

1. Run `apio test ferreira_system_tb.v` for the legacy integration test.
2. Run `apio test ferreira_runtime_tb.v` for full UART / graph-swapping
   simulation. This has **not been run in the authoring environment**;
   if it fails, share the exact log before hardware upload.
3. `apio build` and `apio upload` (or `apio build -e sa` if necessary).
4. Install uploader dependency: `py -m pip install pyserial`.
5. Discover serial port: `py ferreira_upload.py --list-ports`.
6. Load swap graph: `py ferreira_upload.py --port COM5 swap_config.json`
   (replace COM5 with the board's USB Serial COM port).
7. Set SW0..SW3 as the seed and press BTNC. LED0..4 = period,
   LED5 = done, LED7 = ready, LED14 = upload error,
   LED15 = graph successfully loaded. LED8..11 = seed.
8. Load a DIFFERENT graph **without calling apio build/upload**:
   `py ferreira_upload.py --port COM5 identity_config.json`.
   Set seed=0001 and press BTNC: swap period=2, identity period=1.
9. Check rule-bit reconfiguration: `py ferreira_upload.py --port COM5 majority_config.json`.
10. Try 4-substep graph: `py ferreira_upload.py --port COM5 multistep_config.json`.

After power-up the board needs a graph upload before BTNC does anything.
An invalid/partial frame disables the accelerator until a new valid
upload; CPU_RESETN resets the loader and leaves it waiting for upload.
Do not send another packet while computation is running; the loader
rejects new frame starts until ready or showing a result.

For a new graph, keep the same `genes=4` and `capacities=[1,2,4,8]`:

```
py ferreira_compile.py your_graph.json --output your_config.json
py ferreira_upload.py --port COM5 your_config.json
```

## Packet format and integrity

`FG` (ASCII) + `01` + 1-byte substep count + 1-byte rule mask
+ 5-byte packed degree + for each substep: two little-endian 64-bit bank words
+ CRC16-CCITT little-endian, initial CRC=0xffff. CRC covers payload
starting from version. FPGA replies `0x06` (ACK) or `0x15` (NAK).
A stalled transfer times out after ~500 ms; it disables the active
graph. This is a reliability check, not cryptographic authentication.

The first bitstream is now graph-independent **within the fixed capacity**.
Reproducing Ferreira et al. (2010) exactly still requires matching the
paper's unpublished routing details and full-scale benchmarks.

## Regression test coverage

`ferreira_runtime_tb.v` sends UART frames for:

- swap: period 2 from seed `0001`
- identity: period 1 from seed `0001`, **same FPGA bitstream**
- four-substep graph: period 1 from seed `0010`, checks runtime degree=4
- majority graph: checks `rule[0]=1`, `degree[0]=2`, and resulting state
- corrupt CRC: NAK, error LED, disabled computation

The testbench also monitors UART ACK/NAK bytes.

All compiled graph output JSONs and packets were checked by Python.
The Verilog regression must still be run on a machine with APIO/Icarus.
