// One way of the order table's storage: simple dual-port, registered read.
//
// ONE IMPLEMENTATION, ON PURPOSE. This wrapper used to hold two -- the XPM
// macro below and a behavioural array -- selected by `` `ifdef OTABLE_XPM ``.
// The behavioural branch existed for one reason: Verilator cannot compile
// Vivado's XPM library, and Verilator ran the multi-million-message replays.
// Verilator is gone, and xsim elaborates the macro with `-L xpm`, so the
// branch had no remaining purpose.
//
// It also had a cost that was not visible until it was looked for. The define
// reached exactly one of the three flows that build this file: step 5's
// out-of-context synthesis honoured it, while every simulation and the Vitis
// card build silently compiled the OTHER branch -- ipx::package_project
// carries sources, not the packaging project's verilog_define. So the fMAX
// sweeps and the card measurements, two things data/FINDINGS.md compares
// directly, were built from different memory descriptions for the whole of
// their history. It went unnoticed because both branches carried
// ram_style="ultra" and therefore reported the same URAM count, which is the
// check anyone would reach for and the one check that cannot tell them apart
// (§4.5). Nothing is known to have been wrong because of it. The point is
// that nothing could have told us if something had been.
//
// A knob that one flow drops in silence is worse than no knob, so there is now
// nothing to select: every flow gets the macro. Any xelab that reaches this
// file needs `-L xpm`.
//
// NOTE ON INITIALISATION. UltraRAM has no INIT: contents come up indeterminate
// on the device, and USE_MEM_INIT(0) below makes the simulation model come up
// indeterminate too. That is deliberate -- order_table sweeps every address
// after reset, and if that sweep were ever removed, simulation must show
// garbage rather than pass quietly on a memory that zeroed itself.
`timescale 1ns/1ps
module otable_mem #(
  parameter int WIDTH  = 130,
  parameter int DEPTH  = 65536,
  parameter int AW     = 16,
  parameter int RD_LAT = 3
)(
  input  logic            clk,
  input  logic            we,
  input  logic [AW-1:0]   waddr,
  input  logic [WIDTH-1:0] wdata,
  input  logic [AW-1:0]   raddr,
  output logic [WIDTH-1:0] rdata
);

  xpm_memory_sdpram #(
    .MEMORY_SIZE        (DEPTH * WIDTH),
    .MEMORY_PRIMITIVE   ("ultra"),
    .CLOCKING_MODE      ("common_clock"),
    .MEMORY_INIT_FILE   ("none"),
    .USE_MEM_INIT       (0),
    .WAKEUP_TIME        ("disable_sleep"),
    .WRITE_DATA_WIDTH_A (WIDTH),
    .BYTE_WRITE_WIDTH_A (WIDTH),
    .ADDR_WIDTH_A       (AW),
    .READ_DATA_WIDTH_B  (WIDTH),
    .ADDR_WIDTH_B       (AW),
    .READ_LATENCY_B     (RD_LAT),
    .WRITE_MODE_B       ("read_first")
  ) u_xpm (
    .clka(clk), .clkb(clk),
    .ena(1'b1), .wea(we), .addra(waddr), .dina(wdata),
    .enb(1'b1), .addrb(raddr), .doutb(rdata),
    .rstb(1'b0), .regceb(1'b1),
    .injectsbiterra(1'b0), .injectdbiterra(1'b0),
    .sbiterrb(), .dbiterrb(), .sleep(1'b0)
  );

endmodule
