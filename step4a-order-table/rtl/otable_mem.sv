// One way of the order table's storage: simple dual-port, registered read.
//
// This wrapper exists because the real memory is an `xpm_memory_sdpram` macro
// and Verilator cannot compile Vivado's XPM library, while Verilator is what
// runs the multi-million-message replays. So there are two implementations
// behind one interface:
//
//   `OTABLE_XPM defined   -> xpm_memory_sdpram, MEMORY_PRIMITIVE "ultra"
//   otherwise             -> a behavioural array with the SAME read latency
//
// WHICH ONE YOU GET IS NOT WHAT THE NAME SUGGESTS. The define reaches only
// step 5's out-of-context synthesis. Simulations never set it, and Vitis drops
// it -- ipx::package_project carries sources, not the packaging project's
// verilog_define -- so the CARD build compiles the behavioural branch. Both
// carry ram_style="ultra" and therefore report the same URAM count, which is
// exactly why this went unnoticed: the obvious check cannot tell them apart.
// Measured and written up in data/FINDINGS.md §4.5. It is believed harmless --
// the two are interchangeable by the contract just below -- but it means the
// card and the fMAX sweeps are built from different memory descriptions.
//
// The important property is that the two are interchangeable from the FSM's
// point of view: identical depth, identical width, identical RD_LAT. The
// earlier divergence this project is fixing was of a different kind — a table
// 128x smaller in synthesis than in simulation. Here the size and the timing
// match and only the primitive differs, which is the difference XPM's own
// simulation model would introduce anyway.
//
// `make test-xsim` runs the real XPM path so the two are checked against each
// other rather than assumed equivalent.
//
// NOTE ON INITIALISATION. UltraRAM has no INIT: contents come up
// indeterminate on the device. The behavioural model below deliberately does
// NOT zero itself either, so simulation cannot paper over a missing clear —
// order_table sweeps every address after reset, and if that sweep were removed
// the Verilator run would show garbage rather than passing quietly.
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

`ifdef OTABLE_XPM
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
`else
  // Behavioural equivalent: read_first, then RD_LAT stages of output register.
  (* ram_style = "ultra" *) logic [WIDTH-1:0] mem [DEPTH];
  logic [WIDTH-1:0] pipe [RD_LAT];

  always_ff @(posedge clk) begin
    pipe[0] <= mem[raddr];                 // read_first: sees the old contents
    if (we) mem[waddr] <= wdata;
    for (int i = 1; i < RD_LAT; i++) pipe[i] <= pipe[i-1];
  end
  assign rdata = pipe[RD_LAT-1];
`endif

endmodule
