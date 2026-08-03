# Generate the 100G MAC for Phase B, configured for this card's QSFP0 quad.
#
# Every parameter here is taken from what the platform actually declares rather
# than from a datasheet default, because the GT placement has to match the
# platform's own resource description or the pins will not reach the cage:
#
#   ext_metadata.json  raptor2/resources/gts/0:
#     gt_group_select  QUAD_X0Y6          -> GT_GROUP_SELECT X0Y24~X0Y27
#       (the IP wants the LANE range, not the quad name: quad 6 = lanes 24..27,
#        and it rejects "X0Y6" outright -- valid values are X0Y24~X0Y27 for
#        qsfp0 and X0Y28~X0Y31 for qsfp1)
#     diff_clocks      io_clk_qsfp0_refclka_00
#     gt_serial_port   io_gt_qsfp0_00
#     slr_assignment   SLR1
#
# CAUI-4 (4 lanes x 25 Gb/s) is what a QSFP28 100 GbE port is, and it produces the
# 322.265625 MHz / 512-bit AXI-Stream user interface the whole datapath was
# designed around -- see cdc_fifo.sv, which exists precisely because the core does
# not run at that rate.
#
# NO RS-FEC and NO AXI4-Lite control interface. FEC is for a real link budget and
# this design's first bring-up is a near-end loopback inside the GT, where there
# is no cable to correct for; the ctl_* ports are driven directly, which keeps the
# control surface as plain wires instead of adding a second register bus to
# arbitrate against the kernel's own.
#
#   vivado -mode batch -source syn/gen_cmac.tcl
set here [file dirname [file normalize [info script]]]
set root [file dirname $here]
set part xcu55c-fsvh2892-2L-e
set ipdir $root/ip
set proj  $root/tmp_cmac

file delete -force $proj
file mkdir $ipdir

create_project -force cmac_gen $proj -part $part
set_property ip_repo_paths {} [current_project]

create_ip -name cmac_usplus -vendor xilinx.com -library ip \
  -module_name cmac_usplus_0 -dir $ipdir

set_property -dict [list \
  CONFIG.CMAC_CAUI4_MODE {1} \
  CONFIG.NUM_LANES {4x25} \
  CONFIG.GT_REF_CLK_FREQ {161.1328125} \
  CONFIG.GT_GROUP_SELECT {X0Y24~X0Y27} \
  CONFIG.LANE1_GT_LOC {X0Y24} \
  CONFIG.LANE2_GT_LOC {X0Y25} \
  CONFIG.LANE3_GT_LOC {X0Y26} \
  CONFIG.LANE4_GT_LOC {X0Y27} \
  CONFIG.INCLUDE_RS_FEC {0} \
  CONFIG.USER_INTERFACE {AXIS} \
  CONFIG.ENABLE_AXI_INTERFACE {0} \
  CONFIG.INCLUDE_STATISTICS_COUNTERS {0} \
  CONFIG.RX_FLOW_CONTROL {0} \
  CONFIG.TX_FLOW_CONTROL {0} \
] [get_ips cmac_usplus_0]

# Report what the IP actually accepted -- a silently-rejected CONFIG is the same
# class of failure as the clock frequency that was recorded and ignored.
foreach p {CMAC_CAUI4_MODE NUM_LANES GT_REF_CLK_FREQ GT_GROUP_SELECT \
           INCLUDE_RS_FEC USER_INTERFACE ENABLE_AXI_INTERFACE} {
  puts "CMAC_CFG $p = [get_property CONFIG.$p [get_ips cmac_usplus_0]]"
}

generate_target {instantiation_template synthesis} [get_ips cmac_usplus_0]
puts "=== CMAC GENERATED: $ipdir/cmac_usplus_0 ==="
