// Two-clock testbench for cdc_fifo — the CMAC-to-core crossing.
//
// What this has to prove is narrower than "it works": a dual-clock FIFO that
// is broken usually still passes a lazy test, because the failure modes only
// appear when the two slots between the memory and the port are both occupied
// and the reader stalls. So the checks are:
//   1. nothing is lost when the offered load is below the core's capacity;
//   2. nothing is lost, duplicated or reordered when the reader stalls at
//      random — the case that caught a real bug in the read side while this
//      module was being written (a stalled m_tready overwrote an unaccepted
//      word);
//   3. when the reader is stalled long enough to overflow, every beat is
//      either delivered or counted in drop_cnt, never silently dropped.
// The payload is a monotonically increasing counter, so (2) reduces to
// "received values are strictly increasing" and (3) to an exact accounting
// identity: offered == received + dropped.
//
// Clocks are deliberately incommensurate and phase-offset. Two clocks whose
// edges coincide exactly are the one case a real crossing never sees and the
// one case a TB race would hide.
`timescale 1ns/1ps
module tb_cdc_fifo;
  localparam int DATA_W = 512;
  localparam int DEPTH  = 256;

  // 322.265625 MHz -> 3.103 ns; 1 ps precision cannot express half of it, so
  // the write clock is 3.104 ns. The 0.03% error is irrelevant here.
  localparam realtime W_HALF = 1.552ns;   // ~322.16 MHz (CMAC)
  localparam realtime R_HALF = 2.309ns;   // ~216.5 MHz (measured core Fmax)

  logic w_clk = 0, r_clk = 0, w_rst_n = 0, r_rst_n = 0;
  initial forever #W_HALF w_clk = ~w_clk;
  initial begin #0.7ns; forever #R_HALF r_clk = ~r_clk; end   // phase offset

  logic [DATA_W-1:0]   s_tdata;
  logic [DATA_W/8-1:0] s_tkeep;
  logic                s_tvalid, s_tlast;
  logic [31:0]         drop_cnt, hwm;

  logic [DATA_W-1:0]   m_tdata;
  logic [DATA_W/8-1:0] m_tkeep;
  logic                m_tvalid, m_tlast, m_tready;

  cdc_fifo #(.DATA_W(DATA_W), .DEPTH(DEPTH)) dut (
    .w_clk(w_clk), .w_rst_n(w_rst_n),
    .s_tdata(s_tdata), .s_tkeep(s_tkeep), .s_tvalid(s_tvalid), .s_tlast(s_tlast),
    .drop_cnt(drop_cnt), .hwm(hwm),
    .r_clk(r_clk), .r_rst_n(r_rst_n),
    .m_tdata(m_tdata), .m_tkeep(m_tkeep), .m_tvalid(m_tvalid), .m_tlast(m_tlast),
    .m_tready(m_tready)
  );

  // Deterministic xorshift, one state per side. NOT $urandom(seed): that form
  // RESEEDS on every call, so it returns the same value forever — with it the
  // write side ran at 100% duty regardless of the duty setting, which looked
  // exactly like a FIFO that drops below capacity.
  function automatic int unsigned nextrand(ref int unsigned s);
    s ^= s << 13; s ^= s >> 17; s ^= s << 5;
    return s;
  endfunction

  // ---- write side ----
  int unsigned tx      = 0;      // beats offered (accepted or dropped)
  int unsigned duty    = 0;      // percent of cycles carrying a beat
  bit          w_run   = 0;
  int unsigned w_seed  = 32'hC0FFEE;

  // tlast every 8th beat, so the sideband is exercised rather than assumed
  function automatic bit last_of(input int unsigned n); return (n % 8) == 7; endfunction

  always @(posedge w_clk) begin
    if (!w_rst_n) begin
      s_tvalid <= 1'b0; s_tdata <= '0; s_tkeep <= '0; s_tlast <= 1'b0;
    end else begin
      if (w_run && (nextrand(w_seed) % 100) < duty) begin
        s_tdata  <= DATA_W'(tx);
        s_tkeep  <= '1;
        s_tlast  <= last_of(tx);
        s_tvalid <= 1'b1;
        tx       <= tx + 1;
      end else begin
        s_tvalid <= 1'b0;
      end
    end
  end

  // ---- read side ----
  int unsigned rx        = 0;
  int unsigned stall_pct = 0;
  int unsigned r_seed    = 32'hBEEF01;
  bit          seen      = 0;
  int unsigned prev_val  = 0;
  int unsigned errs      = 0;

  always @(posedge r_clk) begin
    if (!r_rst_n) m_tready <= 1'b0;
    else          m_tready <= (nextrand(r_seed) % 100) >= stall_pct;
  end

  always @(posedge r_clk) begin
    if (r_rst_n && m_tvalid && m_tready) begin
      automatic int unsigned v = m_tdata[31:0];
      if (seen && v <= prev_val) begin
        $display("FAIL: value %0d after %0d (duplicate or reordered)", v, prev_val);
        errs++;
      end
      if (m_tlast != last_of(v)) begin
        $display("FAIL: value %0d has tlast=%0b, expected %0b", v, m_tlast, last_of(v));
        errs++;
      end
      if (m_tkeep !== '1) begin
        $display("FAIL: value %0d has tkeep=%h", v, m_tkeep);
        errs++;
      end
      prev_val <= v; seen <= 1; rx <= rx + 1;
    end
  end

  // ---- drive ----
  task automatic drain();
    w_run = 0;                 // the write block deasserts s_tvalid itself
    @(posedge w_clk);
    stall_pct = 0;
    repeat (2000) @(posedge r_clk);
  endtask

  task automatic check(input string name, input bit expect_no_drop);
    automatic int unsigned pushed = tx - drop_cnt;
    $display("%-22s offered=%0d received=%0d dropped=%0d hwm=%0d/%0d",
             name, tx, rx, drop_cnt, hwm, DEPTH);
    if (rx != pushed) begin
      $display("FAIL: %s accounting — received %0d, expected %0d", name, rx, pushed);
      errs++;
    end
    if (expect_no_drop && drop_cnt != 0) begin
      $display("FAIL: %s dropped %0d beats below capacity", name, drop_cnt);
      errs++;
    end
  endtask

  initial begin
    repeat (10) @(posedge w_clk);
    w_rst_n = 1; r_rst_n = 1;
    repeat (10) @(posedge r_clk);

    // 1. offered load below capacity: 100 Gb/s into a 322 MHz interface is a
    //    beat on ~61% of cycles, and the reader keeps up. Nothing may drop.
    duty = 61; stall_pct = 0; w_run = 1;
    repeat (20000) @(posedge w_clk);
    drain();
    check("below capacity", 1);

    // 2. random reader stalls — the ordering/duplication case
    duty = 61; stall_pct = 40; w_run = 1;
    repeat (20000) @(posedge w_clk);
    drain();
    check("reader stalling", 0);

    // 3. deliberate overflow: write every cycle, reader mostly stalled.
    //    Beats must be either delivered or counted, never lost silently.
    duty = 100; stall_pct = 90; w_run = 1;
    repeat (20000) @(posedge w_clk);
    drain();
    check("overflow", 0);
    if (drop_cnt == 0) begin
      $display("FAIL: overflow phase dropped nothing — the test did not overflow");
      errs++;
    end

    if (errs == 0) $display("PASS: cdc_fifo (%0d beats, hwm %0d/%0d)", rx, hwm, DEPTH);
    else           $display("FAIL: %0d error(s)", errs);
    $finish;
  end

endmodule
