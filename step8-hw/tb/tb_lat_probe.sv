// Unit test for lat_probe -- the instrument, not the datapath.
//
// WHY THIS EXISTS SEPARATELY. lat_probe produces a number that will be quoted as
// "measured tick-to-trade latency", so it is exactly the wrong thing to leave
// tested-by-implication. The full-chain TB shows it produces plausible values on
// real traffic, but it cannot construct the cases that matter for trusting them:
// a frame arriving into a pipeline that is NOT empty, an order with no frame
// before it, two orders from one frame, or a TX frame that is an IGMP report
// rather than an order. Those are the paths that decide whether a reported
// latency is attributable, and each is driven directly here.
//
// The expected latency is RE-DERIVED INDEPENDENTLY rather than copied from the
// DUT: the testbench watches the same two observable events the probe watches
// (first RX beat of a frame, first accepted TX beat) with its own cycle counter
// and its own framing trackers, and requires the DUT's answer to equal its own.
// A shared bug would have to be a shared misreading of the interface, not a
// shared line of code.
`timescale 1ns/1ps
module tb_lat_probe;
  localparam int DATA_W  = 512;
  localparam int KEEP_W  = DATA_W / 8;
  localparam int NBUCKET = 16;
  localparam int QUIET   = 64;          // idle cycles a sample must be preceded by

  logic clk = 0, rst_n = 0, clear = 0;
  initial forever #1.6665 clk = ~clk;   // 300 MHz, the kernel's ap_clk

  logic [DATA_W-1:0] rx_tdata = '0;
  logic              rx_tvalid = 0, rx_tlast = 0;
  logic [DATA_W-1:0] tx_tdata = '0;
  logic              tx_tvalid = 0, tx_tlast = 0, tx_tready = 1;

  logic [31:0] lat_min, lat_max, lat_last, lat_sum_lo, lat_sum_hi;
  logic [31:0] samples, excluded, orphans;
  logic [31:0] hist [NBUCKET];

  lat_probe #(.DATA_W(DATA_W), .NBUCKET(NBUCKET)) dut (
    .clk(clk), .rst_n(rst_n), .clear(clear), .cfg_quiet(16'(QUIET)),
    .rx_tdata(rx_tdata), .rx_tvalid(rx_tvalid), .rx_tlast(rx_tlast),
    .tx_tdata(tx_tdata), .tx_tvalid(tx_tvalid), .tx_tlast(tx_tlast),
    .tx_tready(tx_tready),
    .lat_min(lat_min), .lat_max(lat_max), .lat_last(lat_last),
    .lat_sum_lo(lat_sum_lo), .lat_sum_hi(lat_sum_hi),
    .samples(samples), .excluded(excluded), .orphans(orphans), .hist(hist)
  );

  // ---------------- independent re-derivation ----------------
  // The TB's own cycle counter and framing trackers, built from the interface
  // signals alone. t_rx/t_tx are what the DUT's stamp and resolve should use.
  int  cyc = 0;
  bit  rx_inf = 0, tx_inf = 0;
  int  t_rx = -1, t_tx = -1;

  // only a UDP frame starts a measurement -- see lat_probe's rx_is_feed and the
  // loopback case it exists for. Re-derived here from the interface, not copied
  // from the DUT's expression.
  wire rx_feed = (rx_tdata[8*12 +: 8] == 8'h08) && (rx_tdata[8*13 +: 8] == 8'h00) &&
                 (rx_tdata[8*23 +: 8] == 8'd17);

  always @(posedge clk) begin
    if (rst_n) begin
      cyc <= cyc + 1;
      if (rx_tvalid && !rx_inf && rx_feed) t_rx <= cyc;
      if (rx_tvalid)            rx_inf <= !rx_tlast;
      if (tx_tvalid && tx_tready && !tx_inf) t_tx <= cyc;
      if (tx_tvalid && tx_tready)            tx_inf <= !tx_tlast;
    end
  end

  int errors = 0;
  task automatic expect_eq(input string what, input int got, input int exp);
    if (got !== exp) begin
      $display("FAIL: %s = %0d, expected %0d", what, got, exp);
      errors++;
    end
  endtask

  // ---------------- stimulus helpers ----------------
  task automatic idle(input int n);
    repeat (n) @(negedge clk);
  endtask

  // proto defaults to 17 (UDP), which is what a feed frame is. Passing 6 models
  // one of our own order frames coming back in on RX, which is what near-end
  // loopback does in Phase B and which must NOT re-stamp.
  task automatic rx_frame(input int nbeats, input int proto = 17);
    for (int i = 0; i < nbeats; i++) begin
      @(negedge clk);
      rx_tdata = '0;
      if (i == 0) begin
        rx_tdata[8*12 +: 8] = 8'h08;
        rx_tdata[8*13 +: 8] = 8'h00;
        rx_tdata[8*23 +: 8] = 8'(proto);
      end
      rx_tvalid = 1'b1;
      rx_tlast  = (i == nbeats - 1);
    end
    @(negedge clk);
    rx_tvalid = 1'b0; rx_tlast = 1'b0; rx_tdata = '0;
  endtask

  // proto goes at byte 23, matching the IPv4 header position the probe reads.
  // 6 = TCP (an order), 2 = IGMP (a membership report), and an ARP frame is
  // selected by ethertype 0x0806 at bytes 12..13 instead.
  task automatic tx_frame(input int proto, input bit arp = 0, input int nbeats = 2);
    for (int i = 0; i < nbeats; i++) begin
      @(negedge clk);
      tx_tdata = '0;
      if (i == 0) begin
        tx_tdata[8*23 +: 8] = 8'(proto);
        if (arp) begin
          tx_tdata[8*12 +: 8] = 8'h08;
          tx_tdata[8*13 +: 8] = 8'h06;
        end
      end
      tx_tvalid = 1'b1;
      tx_tlast  = (i == nbeats - 1);
    end
    @(negedge clk);
    tx_tvalid = 1'b0; tx_tlast = 1'b0;
  endtask

  int exp_samples = 0, exp_excluded = 0, exp_orphans = 0;
  int lat_a, lat_b;

  initial begin
    idle(4); rst_n = 1; idle(4);

    // ---- 1. an order with no frame before it is an orphan, not a sample ----
    // Guards the case where the probe would otherwise subtract from a zero stamp
    // and report an enormous or nonsense latency.
    tx_frame(6);
    exp_orphans++;
    idle(20);
    expect_eq("orphans after bare order", orphans, exp_orphans);
    expect_eq("samples after bare order", samples, exp_samples);

    // ---- 2. a properly quiet frame produces one attributable sample ----
    idle(QUIET + 20);                  // pipeline provably empty
    rx_frame(1);
    idle(30);
    tx_frame(6);
    exp_samples++;
    idle(20);
    expect_eq("samples", samples, exp_samples);
    expect_eq("excluded", excluded, exp_excluded);
    // the DUT must agree with the TB's own reading of the same two events
    expect_eq("lat_last == t_tx - t_rx", lat_last, t_tx - t_rx);
    lat_a = lat_last;

    // ---- 3. a second order from the SAME frame is also a real event ----
    // One MoldUDP64 frame carries many messages, so this must be counted, and
    // measured from the same arrival -- hence a strictly larger latency.
    idle(40);
    tx_frame(6);
    exp_samples++;
    idle(20);
    expect_eq("samples after 2nd order from one frame", samples, exp_samples);
    expect_eq("lat_last == t_tx - t_rx (2nd)", lat_last, t_tx - t_rx);
    lat_b = lat_last;
    if (!(lat_b > lat_a)) begin
      $display("FAIL: 2nd order latency %0d not greater than 1st %0d", lat_b, lat_a);
      errors++;
    end
    expect_eq("max is the later sample", lat_max, lat_b);
    expect_eq("min is the earlier sample", lat_min, lat_a);

    // ---- 4. IGMP and ARP on the TX port are not orders ----
    // axis_tx_arb merges them onto the same port; counting them would inflate
    // the sample count with frames that have no causing market-data message.
    idle(QUIET + 20);
    rx_frame(1);
    idle(10);
    tx_frame(2);                       // IGMP report
    tx_frame(0, 1);                    // ARP reply
    idle(20);
    expect_eq("samples unchanged by IGMP/ARP", samples, exp_samples);
    expect_eq("orphans unchanged by IGMP/ARP", orphans, exp_orphans);

    // ---- 5. THE GUARD: a frame arriving into a busy pipe is excluded ----
    // The condition that must trigger exclusion is a frame arriving too soon
    // after ANOTHER FRAME -- so a preceding RX frame is required to set it up.
    // Idling here would not do it: cfg_quiet is compared against consecutive
    // idle *RX* cycles, and TX traffic does not reset that count (correctly -- it
    // is a previous frame still being processed that makes attribution unsafe,
    // not an outgoing report). The first version of this test idled QUIET-1 after
    // case 4's TX frames and wrongly expected an exclusion, when the probe had in
    // fact seen a long quiet RX period and was right to accept the sample.
    idle(QUIET + 20);
    rx_frame(1);                       // frame A: legitimately quiet
    idle(QUIET - 10);                  // too soon: A may still be in the pipe
    rx_frame(1);                       // frame B: stamp_ok must be false
    idle(15);
    tx_frame(6);                       // cannot be attributed -> excluded
    exp_excluded++;
    idle(20);
    expect_eq("excluded when gap too small", excluded, exp_excluded);
    expect_eq("samples NOT incremented", samples, exp_samples);

    // ---- 6. histogram buckets and the running sum ----
    begin
      automatic int total = 0;
      for (int b = 0; b < NBUCKET; b++) total += hist[b];
      expect_eq("histogram total == samples", total, exp_samples);
    end
    expect_eq("sum == lat_a + lat_b", lat_sum_lo, lat_a + lat_b);
    // both samples are tens of cycles, so both belong in the 2^5 or 2^6 bucket
    if (hist[5] + hist[6] != 2) begin
      $display("FAIL: expected both samples in bucket 2^5/2^6, got %0d/%0d",
               hist[5], hist[6]);
      errors++;
    end

    // ---- 7. our own order coming BACK on RX must not steal the stamp ----
    // This is the Phase B case. The GT is in near-end loopback, so every order
    // frame the design transmits reappears on the RX port a few hundred
    // nanoseconds later -- in the middle of the window where the second, third
    // and later orders caused by the same feed frame are still being emitted.
    // If a returning TCP frame re-stamped, it would arrive into a manifestly
    // busy pipe, stamp_ok would go false, and every one of those later orders
    // would be thrown away as `excluded` rather than measured. The feed filter
    // in lat_probe is what prevents that, and this is what proves it.
    idle(QUIET + 20);
    rx_frame(1);                       // the feed frame: stamped, quiet, valid
    idle(10);
    rx_frame(1, 6);                    // our own order, looped back: ignored
    idle(15);
    tx_frame(6);                       // still attributable to the FEED frame
    exp_samples++;
    idle(20);
    expect_eq("loopback return does not exclude", excluded, exp_excluded);
    expect_eq("loopback return still yields a sample", samples, exp_samples);
    expect_eq("measured from the feed frame, not the return",
              lat_last, t_tx - t_rx);

    // ---- 8. clear zeroes everything ----
    @(negedge clk); clear = 1'b1;
    @(negedge clk); clear = 1'b0;
    idle(4);
    expect_eq("samples after clear",  samples,  0);
    expect_eq("excluded after clear", excluded, 0);
    expect_eq("orphans after clear",  orphans,  0);
    expect_eq("max after clear",      lat_max,  0);

    if (errors == 0)
      $display("PASS: lat_probe -- attribution, exclusion, orphans, buckets, clear");
    else
      $display("FAIL: %0d checks failed", errors);
    $finish;
  end

  initial begin
    repeat (100000) @(posedge clk);
    $display("FAIL: timeout");
    $finish;
  end
endmodule
