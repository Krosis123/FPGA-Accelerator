# Ferreira runtime timing experiment — registered routing boundary

## Why
The `sa` report shows a 13.81 ns critical path from slow_bank.state[2] through the combinational MIN, input counter, accumulator and majority-rule comparator to a PE flop (Fmax 72.39 MHz). The 100 MHz clock requires <=10 ns.

## What changed
- `ferreira_engine.v`: added optional PIPE_ROUTING parameter, a capture register for routed inputs/valid/inhibitor masks, and a two-clock control for each routing substep. The BRAM lookahead read remains tied to the commit edge. Parameter default is 0 to preserve legacy tests.
- `ferreira_system.v`: forwards PIPE_ROUTING parameter.
- `ferreira_board_top.v`: sets PIPE_ROUTING=1. MAX_DEGREE=256, PE capacities, graph packet format, UART, routing compiler and metadata remain unchanged.
- `ferreira_system_tb.v`: tests integrated path with pipeline enabled.

## First run
```
apio test ferreira_system_tb.v
apio test ferreira_runtime_tb.v
apio clean
apio build
```
If timing passes, run `apio upload`; then upload swap and identity configurations with `ferreira_upload.py`. No toolchain is available here to run the RTL tests, synthesis, or place-and-route. The pipeline is a proposed fix, not yet validated at 100 MHz.

## Important measurement
The update interval doubles from one clock to two clocks per routing substep. Record total attractor latency in cycles AND ns, and LUT/FF/BRAM/Fmax. Do not describe increased Fmax alone as speedup.

## Technical details
Input registers are populated only during routing substep capture cycles; PE accumulation/state updates and engine substep advance happen on the subsequent commit cycle. The synchronous configuration memory fetches the next substep at commit, matching the new substep number after the edge. The design remains fully graph-configurable within the existing fixed four-gene hardware capacity.
