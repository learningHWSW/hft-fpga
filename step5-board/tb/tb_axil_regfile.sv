// Self-checking TB for axil_regfile. Runs under xsim and Verilator --binary.
//
// Proves the register file without a card: write every config word with a
// distinct pattern and read it back (round-trip), check the assembled wide
// outputs (cfg_stock/gap/mac) match their lo/hi words, check CTRL writes pulse
// cfg_load / cfg_order_ack for exactly one cycle each, and drive the status
// inputs to known values and read them through the AXI read mux. Any mismatch
// prints FAIL with the offending register; the run ends "PASS" only if clean.
`timescale 1ns/1ps
module tb_axil_regfile;
  localparam int ADDR_W = 12;

  logic aclk = 0, aresetn = 0;
  always #2 aclk = ~aclk;

  logic [ADDR_W-1:0] awaddr, araddr;
  logic              awvalid, awready, wvalid, wready, bvalid, bready;
  logic              arvalid, arready, rvalid, rready;
  logic [31:0]       wdata, rdata;
  logic [3:0]        wstrb;
  logic [1:0]        bresp, rresp;

  // config outputs
  logic [31:0] cfg_group_ip, cfg_band_base, cfg_max_spread, cfg_min_qty;
  logic [31:0] cfg_order_qty, cfg_pos_limit, cfg_sweep_min_levels, cfg_firm;
  logic [31:0] cfg_tif, cfg_ouch_min_qty, cfg_src_ip, cfg_dst_ip;
  logic [31:0] cfg_init_seq, cfg_ack_num;
  logic [15:0] cfg_udp_port, cfg_track_locate, cfg_max_inflight;
  logic [15:0] cfg_src_port, cfg_dst_port, cfg_window, cfg_init_id;
  logic [47:0] cfg_sweep_gap, cfg_token_prefix, cfg_dst_mac, cfg_src_mac;
  logic [63:0] cfg_stock;
  logic [7:0]  cfg_display, cfg_capacity, cfg_sweep, cfg_cross, cfg_cust;
  logic [3:0]  cfg_ratio_shift;
  logic        cfg_enable, cfg_sweep_en, cfg_load, cfg_order_ack;

  // status inputs
  logic [31:0] st_rx_drop, st_rx_hwm, st_frames_in, st_frames_kept;
  logic [31:0] st_gap_total, st_ot_overflow, st_pl_oob, st_beat_drop;
  logic [31:0] st_msg_drop, st_delta_drop, st_sent, st_blk_pos;
  logic [31:0] st_blk_inflight, st_blk_txfull, st_seq_num, st_frame_cnt;
  logic [31:0] st_tx_drop;
  logic signed [31:0] st_position;
  logic        st_init_done;

  int errors = 0;
  int load_cycles = 0, ack_cycles = 0;

  axil_regfile #(.ADDR_W(ADDR_W)) dut (
    .aclk(aclk), .aresetn(aresetn),
    .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
    .s_axil_wdata(wdata), .s_axil_wstrb(wstrb), .s_axil_wvalid(wvalid), .s_axil_wready(wready),
    .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
    .s_axil_araddr(araddr), .s_axil_arvalid(arvalid), .s_axil_arready(arready),
    .s_axil_rdata(rdata), .s_axil_rresp(rresp), .s_axil_rvalid(rvalid), .s_axil_rready(rready),
    .cfg_group_ip(cfg_group_ip), .cfg_udp_port(cfg_udp_port),
    .cfg_track_locate(cfg_track_locate), .cfg_band_base(cfg_band_base),
    .cfg_enable(cfg_enable), .cfg_max_spread(cfg_max_spread),
    .cfg_ratio_shift(cfg_ratio_shift), .cfg_min_qty(cfg_min_qty),
    .cfg_order_qty(cfg_order_qty), .cfg_pos_limit(cfg_pos_limit),
    .cfg_max_inflight(cfg_max_inflight), .cfg_sweep_en(cfg_sweep_en),
    .cfg_sweep_min_levels(cfg_sweep_min_levels), .cfg_sweep_gap(cfg_sweep_gap),
    .cfg_token_prefix(cfg_token_prefix), .cfg_stock(cfg_stock),
    .cfg_firm(cfg_firm), .cfg_tif(cfg_tif), .cfg_ouch_min_qty(cfg_ouch_min_qty),
    .cfg_display(cfg_display), .cfg_capacity(cfg_capacity), .cfg_sweep(cfg_sweep),
    .cfg_cross(cfg_cross), .cfg_cust(cfg_cust),
    .cfg_dst_mac(cfg_dst_mac), .cfg_src_mac(cfg_src_mac),
    .cfg_src_ip(cfg_src_ip), .cfg_dst_ip(cfg_dst_ip),
    .cfg_src_port(cfg_src_port), .cfg_dst_port(cfg_dst_port),
    .cfg_init_seq(cfg_init_seq), .cfg_ack_num(cfg_ack_num),
    .cfg_window(cfg_window), .cfg_init_id(cfg_init_id),
    .cfg_load(cfg_load), .cfg_order_ack(cfg_order_ack),
    .st_rx_drop(st_rx_drop), .st_rx_hwm(st_rx_hwm), .st_init_done(st_init_done),
    .st_frames_in(st_frames_in), .st_frames_kept(st_frames_kept),
    .st_gap_total(st_gap_total), .st_ot_overflow(st_ot_overflow),
    .st_pl_oob(st_pl_oob), .st_beat_drop(st_beat_drop), .st_msg_drop(st_msg_drop),
    .st_delta_drop(st_delta_drop), .st_sent(st_sent), .st_blk_pos(st_blk_pos),
    .st_blk_inflight(st_blk_inflight), .st_blk_txfull(st_blk_txfull),
    .st_position(st_position), .st_seq_num(st_seq_num),
    .st_frame_cnt(st_frame_cnt), .st_tx_drop(st_tx_drop)
  );

  // count the config-commit pulses over the whole run
  always @(posedge aclk) if (aresetn) begin
    if (cfg_load)      load_cycles++;
    if (cfg_order_ack) ack_cycles++;
  end

  task automatic axi_write(input logic [ADDR_W-1:0] addr, input logic [31:0] data);
    @(negedge aclk);
    awaddr = addr; wdata = data; wstrb = 4'hF;
    awvalid = 1; wvalid = 1; bready = 1;
    // wait for the write to be accepted
    do @(posedge aclk); while (!(awready && wready));
    @(negedge aclk); awvalid = 0; wvalid = 0;
    // wait for the response
    do @(posedge aclk); while (!bvalid);
    @(negedge aclk); bready = 0;
  endtask

  task automatic axi_read(input logic [ADDR_W-1:0] addr, output logic [31:0] data);
    @(negedge aclk);
    araddr = addr; arvalid = 1; rready = 1;
    do @(posedge aclk); while (!arready);
    @(negedge aclk); arvalid = 0;
    do @(posedge aclk); while (!rvalid);
    data = rdata;
    @(negedge aclk); rready = 0;
  endtask

  task automatic check_eq(input string nm, input logic [63:0] got, exp);
    if (got !== exp) begin
      $display("FAIL %s: got %h exp %h", nm, got, exp);
      errors++;
    end
  endtask

  logic [31:0] rb;

  initial begin
    awvalid=0; wvalid=0; bready=0; arvalid=0; rready=0;
    awaddr=0; araddr=0; wdata=0; wstrb=0;
    {st_rx_drop,st_rx_hwm,st_frames_in,st_frames_kept,st_gap_total,
     st_ot_overflow,st_pl_oob,st_beat_drop,st_msg_drop,st_delta_drop,
     st_sent,st_blk_pos,st_blk_inflight,st_blk_txfull,st_seq_num,
     st_frame_cnt,st_tx_drop,st_position} = '0;
    st_init_done = 0;

    repeat (4) @(negedge aclk);
    aresetn = 1;
    repeat (2) @(negedge aclk);

    // 1) round-trip every config word 0..38 with a distinct pattern
    for (int i = 0; i < 39; i++) begin
      axi_write(i*4, 32'hC0DE_0000 | i);
      axi_read (i*4, rb);
      check_eq($sformatf("cfgw[%0d] readback", i), rb, 32'hC0DE_0000 | i);
    end

    // 2) assembled wide outputs match their lo/hi words
    axi_write('h44, 32'h1122_3344);   // stock_lo
    axi_write('h48, 32'h5566_7788);   // stock_hi
    check_eq("cfg_stock", cfg_stock, 64'h5566_7788_1122_3344);
    axi_write('h34, 32'hAABB_CCDD);   // sweep_gap_lo
    axi_write('h38, 32'h0000_9911);   // sweep_gap_hi (only low 16 used)
    check_eq("cfg_sweep_gap", cfg_sweep_gap, 48'h9911_AABB_CCDD);
    axi_write('h6C, 32'h0123_4567);   // dst_mac_lo
    axi_write('h70, 32'h0000_89AB);   // dst_mac_hi
    check_eq("cfg_dst_mac", cfg_dst_mac, 48'h89AB_0123_4567);

    // narrow outputs truncate correctly
    axi_write('h04, 32'hFFFF_1234);   // udp_port: only [15:0]
    check_eq("cfg_udp_port", cfg_udp_port, 16'h1234);
    axi_write('h18, 32'hFFFF_FFF5);   // ratio_shift: only [3:0]
    check_eq("cfg_ratio_shift", cfg_ratio_shift, 4'h5);
    axi_write('h10, 32'h0000_0001);
    check_eq("cfg_enable", cfg_enable, 1'b1);

    // 3) CTRL pulses: bit0 -> cfg_load, bit1 -> cfg_order_ack, one cycle each
    axi_write('h9C, 32'h0000_0001);   // load
    axi_write('h9C, 32'h0000_0002);   // order_ack
    axi_write('h9C, 32'h0000_0000);   // no pulse
    check_eq("cfg_load pulse count",      load_cycles, 1);
    check_eq("cfg_order_ack pulse count", ack_cycles,  1);

    // 4) status read-back through the read mux
    st_rx_drop     = 32'hDEAD_0001;
    st_ot_overflow = 32'hDEAD_0006;
    st_position    = -32'sd7;
    st_init_done   = 1'b1;
    st_tx_drop     = 32'hDEAD_0012;
    @(negedge aclk);
    axi_read('h100, rb); check_eq("st_rx_drop",     rb, 32'hDEAD_0001);
    axi_read('h118, rb); check_eq("st_ot_overflow", rb, 32'hDEAD_0006);
    axi_read('h13C, rb); check_eq("st_position",    rb, 32'hFFFF_FFF9);  // -7 as u32
    axi_read('h108, rb); check_eq("st_init_done",   rb, 32'h1);
    axi_read('h148, rb); check_eq("st_tx_drop",     rb, 32'hDEAD_0012);

    // 5) ID sanity read
    axi_read('h1FC, rb); check_eq("ID", rb, 32'h5432_5430);

    if (errors == 0) $display("PASS: axil_regfile round-trip, pulses, status, ID");
    else             $display("FAIL: %0d error(s)", errors);
    $finish;
  end

  // watchdog
  initial begin
    repeat (100000) @(posedge aclk);
    $display("FAIL: timeout");
    $finish;
  end
endmodule
