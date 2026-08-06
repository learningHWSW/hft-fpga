// Host driver for the tick-to-trade kernel on a real Alveo U55C.
//
// WHAT IT DOES, in the order it matters:
//   1. loads the .xclbin into the card's reconfigurable partition
//   2. checks BOTH identity registers -- the harness ("T2K1") and the datapath
//      ("T2T0") -- before trusting anything else on the bus
//   3. uploads the packed replay image to HBM and configures the datapath over
//      AXI-Lite, using the same values step 6's golden scripts assume
//   4. waits for the order table's self-clear, starts the replay, waits for it
//      to reach the terminator
//   5. reads back every counter and dumps the capture buffer, which
//      scripts/pack_eth.py then parses and diffs against the golden
//
// WHY C++ AND NOT PYTHON. The register plane is the whole point of this run, and
// the pyxrt shipped with this XRT (2.18.179) exposes no xrt::ip binding -- its
// kernel class has no register accessors at all. The C++ API does. The register
// OFFSETS still come from step7-host/host/regmap.py, generated into t2t_regs.h,
// so there is one source of truth and not a second hand-typed map.
//
// WHY xrt::ip AND NOT xrt::kernel. The kernel is declared user_managed (see
// syn/kernel.xml): there is no ap_start/ap_done handshake to run, because the
// datapath is resident and driven by registers. xrt::ip is the class for that,
// and it refuses accesses below offset 0x10, which is why the harness registers
// start at 0x40.
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include "xrt/xrt_bo.h"
#include "xrt/xrt_device.h"
#include "xrt/xrt_uuid.h"
#include "experimental/xrt_ip.h"
#include "experimental/xrt_xclbin.h"

#include "t2t_regs.h"

namespace {

struct Options {
  std::string xclbin  = "t2t.xclbin";
  std::string replay  = "replay.bin";
  std::string capture = "capture.bin";
  std::string device  = "0000:08:00.1";   // the U55C in this machine
  unsigned    gap     = 48;               // idle cycles between frames
  unsigned    locate  = 13;               // tracked stock locate
  unsigned    band    = 2800000;          // price ladder base
  unsigned    records = 8192;             // capture capacity, in records
  bool        sweep   = false;            // sweep signal on/off
  unsigned    quiet   = 256;              // idle RX cycles a latency sample needs
  double      clk_mhz = 300.0;            // ap_clk, for the cycles -> ns conversion
  bool        clk_mhz_set = false;        // ...unless the bitstream implies another
  double      core_mhz = 200.0;           // ap_clk_2, for the loaded probe
};

void usage() {
  std::cerr <<
    "usage: t2t_run [options]\n"
    "  --xclbin <f>   bitstream (default t2t.xclbin)\n"
    "  --replay <f>   packed replay image from pack_eth.py (default replay.bin)\n"
    "  --capture <f>  where to write the capture image (default capture.bin)\n"
    "  --device <bdf> card to use (default 0000:08:00.1)\n"
    "  --gap <n>      idle cycles between injected frames (default 48)\n"
    "  --loc <n>      tracked locate (default 13; use 1 for the synthetic feed)\n"
    "  --base <n>     price band base (default 2800000; 1500000 synthetic)\n"
    "  --records <n>  capture capacity in records (default 8192)\n"
    "  --sweep        enable the sweep signal as well as imbalance\n"
    "  --quiet <n>    idle RX cycles a latency sample requires (default 256);\n"
    "                 --gap must be at least this or samples are excluded\n"
    "  --clk-mhz <f>  ap_clk in MHz, for the cycles->ns report (default 300)\n";
}

std::vector<char> read_file(const std::string& path) {
  std::ifstream f(path, std::ios::binary | std::ios::ate);
  if (!f) throw std::runtime_error("cannot open " + path);
  const auto n = static_cast<size_t>(f.tellg());
  f.seekg(0);
  std::vector<char> buf(n);
  if (!f.read(buf.data(), static_cast<std::streamsize>(n)))
    throw std::runtime_error("short read on " + path);
  return buf;
}

// Find a memory bank by its topology tag ("HBM[0]"). With a user-managed kernel
// there is no xrt::kernel::group_id() to ask, so the bank index is looked up in
// the xclbin's own memory topology rather than assumed to be 0 and 1 -- the
// assumption that silently puts a buffer on the wrong bank and reads zeroes.
uint32_t mem_index(const xrt::xclbin& xb, const std::string& tag) {
  for (const auto& m : xb.get_mems()) {
    if (m.get_tag().rfind(tag, 0) == 0 && m.get_used())
      return static_cast<uint32_t>(m.get_index());
  }
  throw std::runtime_error("no used memory bank tagged " + tag);
}

class Device {
 public:
  Device(const Options& o)
      : xb_(o.xclbin), dev_(o.device) {
    const auto uuid = dev_.load_xclbin(o.xclbin);
    // Phase A and Phase B are separate kernels with separate compute-unit
    // names, and the host is otherwise identical for both -- same registers,
    // same stimulus, same golden. Rather than make the caller name the CU,
    // try each and keep the one the bitstream actually contains.
    for (const char* nm : {"t2t_kernel:{t2t_kernel_1}",
                           "t2t_kernel_b:{t2t_kernel_b_1}"}) {
      try {
        ip_ = xrt::ip(dev_, uuid, nm);
        return;
      } catch (const std::exception&) {
      }
    }
    throw std::runtime_error(
        "no t2t compute unit in " + o.xclbin +
        " (looked for t2t_kernel_1 and t2t_kernel_b_1)");
  }

  uint32_t rd(uint32_t off) const { return ip_.read_register(off); }
  void     wr(uint32_t off, uint32_t v) { ip_.write_register(off, v); }

  // the datapath's own register file, forwarded through the kernel's window
  uint32_t rd_t2t(uint32_t off) const { return rd(T2T_WINDOW + off); }
  void     wr_t2t(uint32_t off, uint32_t v) { wr(T2T_WINDOW + off, v); }

  xrt::device&       dev() { return dev_; }
  const xrt::xclbin& xclbin() const { return xb_; }

 private:
  xrt::xclbin xb_;
  xrt::device dev_;
  xrt::ip     ip_;
};

// Every cfg_* register, in regmap order, with the values step 6's golden
// scripts use (stock AAPL, firm HFT1, token FPGA01, 10.0.0.2 -> 10.0.0.9).
// Keeping these identical to tb_t2t_axil_full.sv is what makes the hardware
// output diffable against the same golden as the simulation.
void configure(Device& d, const Options& o) {
  const uint32_t GROUP = 0xE9360C01u;            // 233.54.12.1

  d.wr_t2t(CFG_GROUP_IP,         GROUP);
  d.wr_t2t(CFG_UDP_PORT,         26477);
  d.wr_t2t(CFG_TRACK_LOCATE,     o.locate);
  d.wr_t2t(CFG_BAND_BASE,        o.band);
  d.wr_t2t(CFG_ENABLE,           1);
  d.wr_t2t(CFG_MAX_SPREAD,       2000);
  d.wr_t2t(CFG_RATIO_SHIFT,      1);
  d.wr_t2t(CFG_MIN_QTY,          100);
  d.wr_t2t(CFG_ORDER_QTY,        100);
  d.wr_t2t(CFG_POS_LIMIT,        1000);
  // The in-flight limiter is disabled: acknowledgements come from a live
  // exchange session, and nothing drives cfg_order_ack in this harness, so the
  // counter would saturate and stop trading a few orders in. Same choice, and
  // same reason, as tb_t2t.sv.
  d.wr_t2t(CFG_MAX_INFLIGHT,     0xFFFF);
  d.wr_t2t(CFG_SWEEP_EN,         o.sweep ? 1 : 0);
  d.wr_t2t(CFG_SWEEP_MIN_LEVELS, 3);
  d.wr_t2t(CFG_SWEEP_GAP_LO,     1000000);
  d.wr_t2t(CFG_SWEEP_GAP_HI,     0);
  d.wr_t2t(CFG_TOKEN_PREFIX_LO,  0x41475046u);   // "FPGA", byte 0 in bits 7:0
  d.wr_t2t(CFG_TOKEN_PREFIX_HI,  0x00003130u);   // "01"
  d.wr_t2t(CFG_STOCK_LO,         0x4C504141u);   // "AAPL"
  d.wr_t2t(CFG_STOCK_HI,         0x20202020u);   // "    "
  d.wr_t2t(CFG_FIRM,             0x31544648u);   // "HFT1"
  d.wr_t2t(CFG_TIF,              0);
  d.wr_t2t(CFG_OUCH_MIN_QTY,     0);
  d.wr_t2t(CFG_DISPLAY,          'A');   // Attributable-Price to Display
  d.wr_t2t(CFG_CAPACITY,         'P');
  d.wr_t2t(CFG_SWEEP,            'N');
  d.wr_t2t(CFG_CROSS,            'N');
  d.wr_t2t(CFG_CUST,             'N');
  d.wr_t2t(CFG_DST_MAC_LO,       0xCCDDEEFFu);   // aa:bb:cc:dd:ee:ff
  d.wr_t2t(CFG_DST_MAC_HI,       0x0000AABBu);
  d.wr_t2t(CFG_SRC_MAC_LO,       0x22334455u);   // 00:11:22:33:44:55
  d.wr_t2t(CFG_SRC_MAC_HI,       0x00000011u);
  d.wr_t2t(CFG_SRC_IP,           0x0A000002u);   // 10.0.0.2
  d.wr_t2t(CFG_DST_IP,           0x0A000009u);   // 10.0.0.9
  d.wr_t2t(CFG_SRC_PORT,         40001);
  d.wr_t2t(CFG_DST_PORT,         4001);
  d.wr_t2t(CFG_INIT_SEQ,         0x10000000u);
  d.wr_t2t(CFG_ACK_NUM,          0x20000000u);
  d.wr_t2t(CFG_WINDOW,           0xFFFF);
  d.wr_t2t(CFG_INIT_ID,          0x1000);
  d.wr_t2t(CFG_IGMP_EN,          1);
  d.wr_t2t(CFG_IGMP_INTERVAL,    0x40000000u);   // effectively no periodic report
  d.wr_t2t(CFG_GROUP_IP_B,       GROUP);         // B == A: single-feed replay
  d.wr_t2t(T2T_CTRL,             T2T_CTRL_LOAD); // commit
}

int run(Options o) {
  Device d(o);

  const uint32_t kid = d.rd(K_ID);
  const uint32_t tid = d.rd_t2t(T2T_ID);
  const bool phase_b = (kid == K_ID_VALUE_B);
  std::printf("harness id  = %08x (%s)\n", kid,
              phase_b ? "T2K2, Phase B: through the CMAC"
                      : "T2K1, Phase A: HBM replay");
  std::printf("datapath id = %08x (expect %08x)\n", tid, T2T_ID_VALUE);
  if ((kid != K_ID_VALUE && !phase_b) || tid != T2T_ID_VALUE) {
    std::cerr << "FAIL: identity register mismatch -- wrong bitstream, or the "
                 "control bus is not working\n";
    return 1;
  }
  // The wire clock differs between the two, and the latency probe counts wire
  // cycles: Phase A's tap is on ap_clk, Phase B's on the CMAC's gt_txusrclk2.
  // Defaulting from the ID rather than from the command line means a Phase B
  // run reported in nanoseconds cannot silently be scaled by the wrong clock.
  if (phase_b && !o.clk_mhz_set) o.clk_mhz = 322.265625;

  // ---- buffers ----
  const auto image = read_file(o.replay);
  if (image.size() % 64) {
    std::cerr << "FAIL: replay image is not a whole number of 64-byte beats\n";
    return 1;
  }
  const size_t cap_bytes = static_cast<size_t>(o.records) * CAPTURE_RECORD_BYTES;

  xrt::bo rp(d.dev(), image.size(), xrt::bo::flags::normal,
             mem_index(d.xclbin(), "HBM[0]"));
  xrt::bo cp(d.dev(), cap_bytes, xrt::bo::flags::normal,
             mem_index(d.xclbin(), "HBM[1]"));

  std::memcpy(rp.map<char*>(), image.data(), image.size());
  std::memset(cp.map<char*>(), 0, cap_bytes);
  rp.sync(XCL_BO_SYNC_BO_TO_DEVICE);
  cp.sync(XCL_BO_SYNC_BO_TO_DEVICE);

  const uint64_t rp_addr = rp.address();
  const uint64_t cp_addr = cp.address();
  std::printf("replay  : %zu bytes (%zu beats) at 0x%lx\n",
              image.size(), image.size() / 64, rp_addr);
  std::printf("capture : %zu bytes (%u records) at 0x%lx\n",
              cap_bytes, o.records, cp_addr);

  // ---- harness setup. cfg_beats is a safety bound; the zero-length
  //      terminator inside the image is what actually ends the run.
  d.wr(K_CTRL,        K_CTRL_SOFT_RESET);
  std::this_thread::sleep_for(std::chrono::milliseconds(10));
  d.wr(K_RP_BASE_LO,  static_cast<uint32_t>(rp_addr));
  d.wr(K_RP_BASE_HI,  static_cast<uint32_t>(rp_addr >> 32));
  d.wr(K_RP_BEATS,    static_cast<uint32_t>(image.size() / 64));
  d.wr(K_RP_GAP,      o.gap);
  d.wr(K_CP_BASE_LO,  static_cast<uint32_t>(cp_addr));
  d.wr(K_CP_BASE_HI,  static_cast<uint32_t>(cp_addr >> 32));
  d.wr(K_CP_RECS,     o.records);
  d.wr(K_L_QUIET,     o.quiet);
  d.wr(K_CTRL,        K_CTRL_CLEAR_CAPTURE | K_CTRL_CLEAR_LATENCY);

  configure(d, o);

  // UltraRAM comes up with no defined contents, so the order table clears
  // itself after reset. Enabling the feed before that finishes corrupts it.
  bool ready = false;
  for (int i = 0; i < 10000 && !ready; i++) {
    ready = (d.rd_t2t(ST_INIT_DONE) & 1u) != 0;
    if (!ready) std::this_thread::sleep_for(std::chrono::microseconds(200));
  }
  if (!ready) {
    std::cerr << "FAIL: st_init_done never asserted (order table never cleared)\n";
    return 1;
  }
  std::printf("order table initialised\n");

  // ---- Phase B: the MAC has to be up before the injector runs ----
  // The kernel refuses a start while the link is down, because frames offered
  // to a transmitter that is still sending fault ordered sets are discarded
  // inside the IP -- and the run would then look like a datapath that produced
  // nothing rather than a link that had not finished training. Near-end PMA
  // loopback still has to do the real work: block lock on four lanes, then
  // alignment-marker lock across them, which takes milliseconds.
  if (phase_b) {
    bool up = false;
    for (int i = 0; i < 5000 && !up; i++) {
      up = (d.rd(K_C_STATUS) & K_C_STATUS_LINK_UP) != 0;
      if (!up) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    const uint32_t cs = d.rd(K_C_STATUS);
    std::printf("CMAC link   : aligned=%u link_up=%u\n",
                (cs & K_C_STATUS_ALIGNED) ? 1u : 0u,
                (cs & K_C_STATUS_LINK_UP) ? 1u : 0u);
    if (!up) {
      std::cerr << "FAIL: CMAC never aligned in near-end loopback -- the GT did "
                   "not come up, and nothing downstream of it can be trusted\n";
      return 1;
    }
  }

  // ---- replay ----
  d.wr(K_CTRL, K_CTRL_START);
  bool done = false;
  for (int i = 0; i < 600000 && !done; i++) {
    done = (d.rd(K_STATUS) & K_STATUS_DONE) != 0;
    if (!done) std::this_thread::sleep_for(std::chrono::microseconds(100));
  }
  if (!done) {
    std::cerr << "FAIL: replay did not complete (status "
              << d.rd(K_STATUS) << ")\n";
    return 1;
  }
  // let the tail of the pipeline drain and the last capture burst retire
  std::this_thread::sleep_for(std::chrono::milliseconds(50));

  // ---- results ----
  const uint32_t inj   = d.rd(K_RP_FRAMES);
  const uint32_t ncap  = d.rd(K_CP_FRAMES);
  const uint32_t ovf   = d.rd(K_CP_OVF);
  const uint32_t stall = d.rd(K_CP_STALL);
  std::printf("\nharness : injected=%u captured=%u overflow=%u stalls=%u\n",
              inj, ncap, ovf, stall);
  std::printf("rx      : frames_in=%u kept=%u cdc_drop=%u hwm=%u\n",
              d.rd_t2t(ST_FRAMES_IN), d.rd_t2t(ST_FRAMES_KEPT),
              d.rd_t2t(ST_RX_DROP),   d.rd_t2t(ST_RX_HWM));
  std::printf("feed    : gap=%u ot_overflow=%u oob=%u drops(beat=%u msg=%u delta=%u)\n",
              d.rd_t2t(ST_GAP_TOTAL), d.rd_t2t(ST_OT_OVERFLOW),
              d.rd_t2t(ST_PL_OOB),    d.rd_t2t(ST_BEAT_DROP),
              d.rd_t2t(ST_MSG_DROP),  d.rd_t2t(ST_DELTA_DROP));
  // st_position is a SIGNED counter in the RTL (t2t_top declares it
  // `output logic signed [31:0]`), so it must be printed as one. Read as %u a
  // short position of -200 comes out as 4294967096, which is not merely ugly --
  // it silently reads as a huge long position, the opposite of the truth.
  std::printf("strategy: sent=%u pos=%d blocked(pos=%u inflight=%u txfull=%u)\n",
              d.rd_t2t(ST_SENT),
              static_cast<int32_t>(d.rd_t2t(ST_POSITION)),
              d.rd_t2t(ST_BLK_POS),    d.rd_t2t(ST_BLK_INFLIGHT),
              d.rd_t2t(ST_BLK_TXFULL));
  std::printf("tx      : frames=%u next_seq=%08x cdc_drop=%u\n",
              d.rd_t2t(ST_FRAME_CNT), d.rd_t2t(ST_SEQ_NUM), d.rd_t2t(ST_TX_DROP));

  if (phase_b) {
    const uint32_t unf = d.rd(K_C_UNF);
    const uint32_t rxe = d.rd(K_C_RXERR);
    const uint32_t cdr = d.rd(K_C_CAPDROP);
    std::printf("mac     : tx=%u rx=%u rx_err=%u underrun=%u overflow=%u\n",
                d.rd(K_C_TXPKT), d.rd(K_C_RXPKT), rxe, unf, d.rd(K_C_OVFL));
    std::printf("loopback: filter passed=%u dropped=%u cap_cdc_drop=%u "
                "hwm(feed=%u ord=%u)\n",
                d.rd(K_C_FLT_P), d.rd(K_C_FLT_D), cdr,
                d.rd(K_C_FEEDHWM), d.rd(K_C_ORDHWM));
    // Each of these invalidates the capture in a different way, so each is
    // called out rather than folded into one "something went wrong".
    if (unf) std::printf("WARN: %u TX underruns -- frames went onto the wire "
                         "corrupted; the store-and-forward guarantee broke\n", unf);
    if (rxe) std::printf("WARN: %u frames came back with FCS or alignment "
                         "errors\n", rxe);
    if (cdr) std::printf("WARN: %u beats lost in the capture CDC -- the golden "
                         "diff will show holes that are not the datapath's\n", cdr);
  }

  // ---- latency, measured on silicon (see rtl/lat_probe.sv) ----
  // A sample is only accepted if its frame arrived into a provably empty
  // pipeline, so `excluded` is the honesty check: non-zero means --gap was below
  // --quiet and the run should be repeated with a bigger gap, not reinterpreted.
  const uint32_t nlat = d.rd(K_L_SAMPLES);
  const uint32_t lexc = d.rd(K_L_EXCLUDED);
  const uint32_t lorp = d.rd(K_L_ORPHANS);
  const double   ns   = 1000.0 / o.clk_mhz;      // ns per RX cycle
  std::printf("\nlatency : samples=%u excluded=%u orphans=%u (quiet=%u gap=%u)\n",
              nlat, lexc, lorp, o.quiet, o.gap);
  if (nlat) {
    const uint32_t lmin = d.rd(K_L_MIN);
    const uint32_t lmax = d.rd(K_L_MAX);
    const uint64_t sum  = (static_cast<uint64_t>(d.rd(K_L_SUM_HI)) << 32) |
                          d.rd(K_L_SUM_LO);
    const double   avg  = static_cast<double>(sum) / nlat;
    std::printf("          min=%u cyc (%.1f ns)  avg=%.1f cyc (%.1f ns)  "
                "max=%u cyc (%.1f ns)\n",
                lmin, lmin * ns, avg, avg * ns, lmax, lmax * ns);
    for (unsigned b = 0; b < K_L_NBUCKET; b++) {
      const uint32_t h = d.rd(K_L_HIST + 4 * b);
      if (h) std::printf("          hist[2^%u..] = %u\n", b, h);
    }
  }
  if (lexc) {
    std::cerr << "WARNING: " << lexc << " latency samples excluded -- raise "
                 "--gap above --quiet for an attributable measurement\n";
  }

  // ---- loaded latency: the same path while the pipeline is BUSY ----
  // No quiet window here -- lat_loaded correlates on the ITCH timestamp the
  // datapath already carries, so it reports at any offered load, which is what
  // FINDINGS 7.2's burst tail needs. Measured in CORE cycles (the clock the
  // queues drain at), and it excludes the fixed front end that lat_probe's
  // number includes -- the two are complementary, not comparable.
  const uint32_t mn = d.rd(K_M_SAMPLES);
  const uint32_t mm = d.rd(K_M_MISSES);
  const double   cns = 1000.0 / o.core_mhz;
  std::printf("\nloaded  : samples=%u misses=%u\n", mn, mm);
  if (mn) {
    const uint32_t lo = d.rd(K_M_MIN), hi = d.rd(K_M_MAX);
    const uint64_t sm = (static_cast<uint64_t>(d.rd(K_M_SUM_HI)) << 32) |
                        d.rd(K_M_SUM_LO);
    const double   av = static_cast<double>(sm) / mn;
    std::printf("          decode->order  min=%u cyc (%.1f ns)  avg=%.1f cyc "
                "(%.1f ns)  max=%u cyc (%.1f ns)\n",
                lo, lo * cns, av, av * cns, hi, hi * cns);
    for (unsigned b = 0; b < K_M_NBUCKET; b++) {
      const uint32_t h = d.rd(K_M_HIST + 4 * b);
      if (h) std::printf("          hist[2^%u..] = %u\n", b, h);
    }
  }

  // ---- capture image out, for pack_eth.py to parse and diff ----
  cp.sync(XCL_BO_SYNC_BO_FROM_DEVICE);
  {
    const size_t used = static_cast<size_t>(ncap) * CAPTURE_RECORD_BYTES;
    std::ofstream f(o.capture, std::ios::binary);
    if (!f) { std::cerr << "FAIL: cannot write " << o.capture << "\n"; return 1; }
    f.write(cp.map<char*>(), static_cast<std::streamsize>(
                                 used ? used : CAPTURE_RECORD_BYTES));
  }
  std::printf("capture image written to %s\n", o.capture.c_str());

  int rc = 0;
  if (inj == 0)   { std::cerr << "FAIL: no frames injected\n";        rc = 1; }
  if (ncap == 0)  { std::cerr << "FAIL: no frames captured\n";        rc = 1; }
  if (ovf != 0)   { std::cerr << "FAIL: capture overflowed\n";        rc = 1; }
  if (d.rd_t2t(ST_TX_DROP) != 0) {
    std::cerr << "FAIL: TX clock crossing dropped beats\n";           rc = 1;
  }
  if (ncap < d.rd_t2t(ST_FRAME_CNT)) {
    std::cerr << "FAIL: fewer frames captured than the engine built\n"; rc = 1;
  }
  return rc;
}

}  // namespace

int main(int argc, char** argv) {
  Options o;
  for (int i = 1; i < argc; i++) {
    const std::string a = argv[i];
    auto next = [&]() -> std::string {
      if (i + 1 >= argc) throw std::runtime_error("missing value for " + a);
      return argv[++i];
    };
    try {
      if      (a == "--xclbin")  o.xclbin  = next();
      else if (a == "--replay")  o.replay  = next();
      else if (a == "--capture") o.capture = next();
      else if (a == "--device")  o.device  = next();
      else if (a == "--gap")     o.gap     = std::stoul(next());
      else if (a == "--loc")     o.locate  = std::stoul(next());
      else if (a == "--base")    o.band    = std::stoul(next());
      else if (a == "--records") o.records = std::stoul(next());
      else if (a == "--sweep")   o.sweep   = true;
      else if (a == "--quiet")   o.quiet   = std::stoul(next());
      else if (a == "--clk-mhz") { o.clk_mhz = std::stod(next()); o.clk_mhz_set = true; }
      else if (a == "--core-mhz") o.core_mhz = std::stod(next());
      else { usage(); return 2; }
    } catch (const std::exception& e) {
      std::cerr << e.what() << "\n";
      return 2;
    }
  }

  try {
    return run(o);
  } catch (const std::exception& e) {
    std::cerr << "FAIL: " << e.what() << "\n";
    return 1;
  }
}
