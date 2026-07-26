// Lint/sim stub for the core-clock MMCM (t2t_core_clk).
//
// The real t2t_core_clk is a Vivado Clocking Wizard IP (see
// create_t2t_core_clk.tcl) that generates 200 MHz core_clk from the 322.265625
// MHz cmac_clk. Verilator cannot elaborate the IP, so this stub with identical
// ports lets `make lint-opennic` prove the box wiring. It is NOT used in the
// Vivado build -- there the IP of the same module name wins.
`timescale 1ns/1ps
module t2t_core_clk (
  input  logic clk_in1,
  input  logic reset,      // active high
  output logic clk_out1,
  output logic locked
);
  assign clk_out1 = clk_in1;   // no real division in the stub
  assign locked   = ~reset;
endmodule
