`timescale 1ns/1ps


module ferreira_pe_tb;

reg clk = 0;
always #5 clk = ~clk;

reg reset = 1;
reg load_seed = 0;
reg seed = 0;

reg step_valid = 0;
reg first_substep = 0;
reg last_substep = 0;

reg [3:0] inputs = 0;
reg [3:0] valid_mask = 0;
reg [3:0] inhibitor_mask = 0;

reg rule = 0;
reg [8:0] degree = 0;

wire state;

ferreira_pe #(
.K(4),
.MAX_DEGREE(256)
) dut (
.clk(clk),
.reset(reset),
.load_seed(load_seed),
.seed(seed),
.step_valid(step_valid),
.first_substep(first_substep),
.last_substep(last_substep),
.inputs(inputs),
.valid_mask(valid_mask),
.inhibitor_mask(inhibitor_mask),
.rule(rule),
.degree(degree),
.state(state)
);

task load_initial;
input value;
begin
@(negedge clk);
reset = 0;
load_seed = 1;
seed = value;

@(posedge clk);
#1;
load_seed = 0;
end
endtask

task apply_step;
input first;
input last;
input [3:0] data;
input [3:0] valid;
input [3:0] inhibit;
begin
@(negedge clk);
step_valid = 1;
first_substep = first;
last_substep = last;
inputs = data;
valid_mask = valid;
inhibitor_mask = inhibit;

@(posedge clk);
#1;
step_valid = 0;
end
endtask

initial begin

// Allow reset to reach a clock edge
repeat (2) @(posedge clk);

// =====================================
// TEST 1: Inhibitor overrides activator
// =====================================

load_initial(1'b1);

rule = 0;
degree = 6;

// Four activator inputs.
// Only input 1 is active.
apply_step(1, 0, 4'b0010,
4'b1111, 4'b0000);

if (state !== 1)
$fatal(1, "State changed too early");

// Two more inputs; input 0 is inhibitory
// and active, so the result must be zero.
apply_step(0, 1, 4'b0001,
4'b0011, 4'b0001);

if (state !== 0)
$fatal(1, "Inhibitor test failed");

$display("PASS: Inhibitor priority");

// =====================================
// TEST 2: Activator with no inhibition
// =====================================

load_initial(0);

rule = 0;
degree = 6;

apply_step(1, 0, 4'b0010,
4'b1111, 4'b0000);

apply_step(0, 1, 4'b0000,
4'b0011, 4'b0001);

if (state !== 1)
$fatal(1, "Activator test failed");

$display("PASS: Activator accumulation");

// =====================================
// TEST 3: Majority, 3 out of 5
// =====================================

load_initial(0);

rule = 1;
degree = 5;

// First chunk: two active inputs
apply_step(1, 0, 4'b0011,
4'b1111, 4'b0000);

if (state !== 0)
$fatal(1, "Premature majority update");

// Second chunk: one active input
// Total = 3, so 3 > 5/2
apply_step(0, 1, 4'b0001,
4'b0001, 4'b0000);

if (state !== 1)
$fatal(1, "Majority-3 test failed");

$display("PASS: Majority 3/5");

// =====================================
// TEST 4: Majority, 2 out of 5
// =====================================

load_initial(1);

rule = 1;
degree = 5;

apply_step(1, 0, 4'b0001,
4'b1111, 4'b0000);

apply_step(0, 1, 4'b0001,
4'b0001, 4'b0000);

if (state !== 0)
$fatal(1, "Majority-2 test failed");

$display("PASS: Majority 2/5");

$display("------------------------------");
$display("ALL FERREIRA PE TESTS PASSED");
$display("------------------------------");

$finish;
end


endmodule