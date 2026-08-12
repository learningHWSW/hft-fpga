# Package t2t_kernel_b as a Vitis .xo -- the Phase B kernel, with a real MAC.
#
# Everything package_kernel.tcl does, plus the three things a GT-attached kernel
# needs and a fabric-only one does not:
#
#  * THE CMAC IP TRAVELS INSIDE THE .xo. ip/cmac_usplus_0 is added as a source
#    like any other file; the packager pulls its output products into the
#    component, so v++ needs no ip_repo path and no separate generation step.
#    Generate it first with `make cmac` -- syn/gen_cmac.tcl records the GT quad
#    and reference clock that this card's platform actually declares.
#  * THE GT SERIAL PORT AND ITS REFERENCE CLOCK are declared as bus interfaces of
#    the types Xilinx's own MAC IP uses, and NAMED AFTER THE PLATFORM RESOURCES
#    (io_gt_qsfp0_00, io_clk_qsfp0_refclka_00). The names are what syn/gt_connect.tcl
#    matches on. Declaring them does not by itself make v++ connect anything --
#    that was measured, see gt_connect.tcl -- but they are what there is to
#    connect.
#  * gt_refclk_p/n are NOT associated with any kernel clock. They are a
#    differential reference into the GT, not a clock the platform drives logic
#    with, and associating them would have v++ try to supply them from the
#    clocking wizard.
#
# The CDC exception file is package_kernel.tcl's, unchanged: its content refers
# only to the ap_clk/ap_clk_2 ports and to cell-name patterns that exist in both
# kernels. The wire domain is handled in syn/impl_cdc_hook_b.tcl instead, because
# the CMAC's clock has no port to hang a scoped constraint on and finding it
# needs control flow an .xdc cannot express.
#
#   vivado -mode batch -source syn/package_kernel_b.tcl
set here [file dirname [file normalize [info script]]]
set root [file dirname $here]
set repo [file dirname $root]

set part        xcu55c-fsvh2892-2L-e
set kernel_name t2t_kernel_b
set packaged    $root/packaged_kernel_b
set tmp_proj    $root/tmp_kernel_b_pack
set xo          $root/$kernel_name.xo

# gen_cmac.tcl may have been run more than once, leaving cmac_usplus_0/ beside
# cmac_usplus_0_1/ -- one of which holds only the .xci and no output products.
# Take the one that has actually been generated, rather than the first found.
set cmac_xci ""
foreach cand [lsort [glob -nocomplain $root/ip/*/cmac_usplus_0.xci]] {
  set d [file dirname $cand]
  if {[file isdirectory $d/synth] || [file isdirectory $d/hdl]} { set cmac_xci $cand }
}
if {$cmac_xci eq ""} {
  error "CMAC IP not generated (no ip/*/cmac_usplus_0.xci with output products). Run: make cmac"
}
puts "=== using CMAC IP: $cmac_xci ==="

file delete -force $packaged $tmp_proj $xo

set srcs [list \
  $root/rtl/t2t_geom_pkg.sv \
  $repo/step2-rtl-decoder/rtl/itch5_pkg.sv \
  $repo/step2-rtl-decoder/rtl/itch_decoder.sv \
  $repo/step3b-splitter/rtl/mold_splitter.sv \
  $repo/step4a-order-table/rtl/otable_mem.sv \
  $repo/step4a-order-table/rtl/order_table.sv \
  $repo/step4a-order-table/rtl/order_table_pipe.sv \
  $repo/step4b-book/rtl/price_ladder.sv $repo/step4b-book/rtl/fast_bbo.sv \
  $repo/step4b-book/rtl/bbo_merge.sv \
  $repo/step4b-book/rtl/bbo_arb.sv \
  $repo/step5-board/rtl/drop_fifo.sv \
  $repo/step5-board/rtl/fh_core.sv \
  $repo/step5-board/rtl/eth_ip_udp_rx.sv \
  $repo/step5-board/rtl/cdc_fifo.sv \
  $repo/step6-strategy/rtl/strategy.sv \
  $repo/step6-strategy/rtl/sweep_detect.sv \
  $repo/step6-strategy/rtl/ouch_builder.sv \
  $repo/step6-strategy/rtl/tcp_tx.sv $repo/step6-strategy/rtl/tx_replay_buf.sv $repo/step6-strategy/rtl/tx_rto.sv $repo/step6-strategy/rtl/ack_latency.sv \
  $repo/step5-board/rtl/feed_ab_arb.sv \
  $repo/step5-board/rtl/igmp_query_detect.sv \
  $repo/step5-board/rtl/tcp_rx.sv $repo/step5-board/rtl/t2t_top.sv \
  $repo/step5-board/rtl/axil_regfile.sv \
  $repo/step5-board/rtl/cfg_cdc.sv \
  $repo/step5-board/rtl/axis_tx_arb.sv \
  $repo/step5-board/rtl/igmp_join.sv \
  $repo/step5-board/rtl/arp_responder.sv \
  $repo/step5-board/rtl/t2t_axil.sv \
  $root/rtl/eth_replay.sv \
  $root/rtl/eth_capture.sv \
  $root/rtl/lat_probe.sv \
  $root/rtl/lat_loaded.sv \
  $root/rtl/axis_sf_fifo.sv \
  $root/rtl/axis_frame_filter.sv \
  $root/rtl/cmac_wrap.sv \
  $root/rtl/t2t_kernel_b.sv ]

create_project -force kernel_b_pack $tmp_proj -part $part
add_files -norecurse $srcs
add_files -norecurse $cmac_xci
# The kernel geometry travels as rtl/t2t_geom_pkg.sv, first in the source list
# above -- a GENERATED SOURCE, because that is the only thing that reaches v++.
# Two other mechanisms were tried and both failed silently, each producing a
# bitstream that reported one geometry and elaborated another:
#   * -generic / set_property generic: ipx::package_project packages sources,
#     not a synthesised netlist, and the packager then strips user parameters,
#     so the module's own defaults are what v++ elaborates;
#   * set_property verilog_define here: it applies to THIS project's synthesis,
#     and v++ re-synthesises the kernel in its own project where it is unset.
# (OTABLE_XPM appeared to prove verilog_define worked. It did not prove it:
#  both branches of otable_mem carried ram_style="ultra", so the URAM count was
#  the same either way and said nothing about which branch was compiled. That
#  define is gone -- otable_mem has one implementation now, the XPM macro, and
#  the line that set it here has gone with it. It never reached v++ anyway,
#  which is exactly how the card spent its whole history building the branch
#  the fMAX sweeps did not. FINDINGS 4.5.)
set_property top $kernel_name [current_fileset]

update_compile_order -fileset sources_1

ipx::package_project -root_dir $packaged -vendor xilinx.com -library RTLKernel \
  -taxonomy /KernelIP -import_files -set_current false
ipx::unload_core $packaged/component.xml
ipx::edit_ip_in_project -upgrade true -name tmp_edit_project_b \
  -directory $packaged $packaged/component.xml

set core [ipx::current_core]
set_property core_revision 1 $core
foreach up [ipx::get_user_parameters] {
  ipx::remove_user_parameter [get_property NAME $up] $core
}
set_property sdx_kernel      true $core
set_property sdx_kernel_type rtl  $core
ipx::create_xgui_files $core

ipx::infer_bus_interface ap_clk_2   xilinx.com:signal:clock_rtl:1.0 $core
ipx::infer_bus_interface ap_rst_n_2 xilinx.com:signal:reset_rtl:1.0 $core
set_property value ap_rst_n_2 [ipx::add_bus_parameter ASSOCIATED_RESET \
  [ipx::get_bus_interfaces ap_clk_2 -of_objects $core]]

ipx::associate_bus_interfaces -busif s_axi_control -clock ap_clk $core
ipx::associate_bus_interfaces -busif m_axi_gmem0   -clock ap_clk $core
ipx::associate_bus_interfaces -busif m_axi_gmem1   -clock ap_clk $core

# ---- the GT serial port, named after the platform resource ----
set gt [ipx::add_bus_interface io_gt_qsfp0_00 $core]
set_property abstraction_type_vlnv xilinx.com:interface:gt_rtl:1.0 $gt
set_property bus_type_vlnv        xilinx.com:interface:gt:1.0      $gt
set_property interface_mode       master                           $gt
foreach {logical physical} {GRX_N gt_rxn_in GRX_P gt_rxp_in
                            GTX_N gt_txn_out GTX_P gt_txp_out} {
  set pm [ipx::add_port_map $logical $gt]
  set_property physical_name $physical $pm
}

# ---- the differential reference clock that feeds the quad ----
set rc [ipx::add_bus_interface io_clk_qsfp0_refclka_00 $core]
set_property abstraction_type_vlnv xilinx.com:interface:diff_clock_rtl:1.0 $rc
set_property bus_type_vlnv        xilinx.com:interface:diff_clock:1.0      $rc
set_property interface_mode       slave                                    $rc
foreach {logical physical} {CLK_P gt_refclk_p CLK_N gt_refclk_n} {
  set pm [ipx::add_port_map $logical $rc]
  set_property physical_name $physical $pm
}

# ---- CDC timing exceptions, shipped INSIDE the .xo ----
# Copied into the component first: component.xml stores the path relative to the
# component root, and adding it from syn/ records a path that escapes the IP and
# that v++ cannot resolve when it unpacks the .xo (IP_Flow 19-663 / 19-167).
file copy -force $here/t2t_kernel_cdc.xdc $packaged/src/t2t_kernel_cdc.xdc
set xdc_grp [ipx::add_file_group -type implementation {} $core]
set xdc_f   [ipx::add_file src/t2t_kernel_cdc.xdc $xdc_grp]
set_property type             xdc            $xdc_f
set_property used_in          {implementation out_of_context} $xdc_f
set_property scoped_to_ref    t2t_kernel_b   $xdc_f
set_property processing_order late           $xdc_f

set_property xpm_libraries {XPM_CDC XPM_MEMORY XPM_FIFO} $core
set_property supported_families { } $core
set_property auto_family_support_level level_2 $core
ipx::update_checksums $core
ipx::check_integrity -kernel $core
ipx::save_core $core
close_project -delete

package_xo -xo_path $xo -kernel_name $kernel_name -ip_directory $packaged \
  -kernel_xml $here/kernel_b.xml
puts "=== PACKAGED: $xo ==="
