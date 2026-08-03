# Package t2t_kernel as a Vitis .xo -- the object v++ links into an .xclbin.
#
# This is the IP-packager dance every RTL kernel needs: build a throwaway
# project, let Vivado infer bus interfaces from the port names, fix up the bits
# it cannot infer, and emit the .xo. The parts that actually need thought:
#
#  * TWO CLOCKS. Vivado infers ap_clk/ap_rst_n by name, but ap_clk_2/ap_rst_n_2
#    are inferred explicitly below and the reset associated with its clock.
#    Without that the second clock is packaged as an ordinary input and v++ has
#    no idea it must drive it, so the datapath core would sit unclocked.
#  * The AXI interfaces are associated with ap_clk, which is where the control
#    plane and both HBM masters live (t2t_kernel.sv keeps ap_clk_2 to the
#    datapath core only).
#  * User parameters are stripped: DATA_W and friends are compile-time facts of
#    this design, not knobs for the linker to set.
#
#   vivado -mode batch -source syn/package_kernel.tcl
set here [file dirname [file normalize [info script]]]
set root [file dirname $here]
set repo [file dirname $root]

set part        xcu55c-fsvh2892-2L-e
set kernel_name t2t_kernel
set packaged    $root/packaged_kernel
set tmp_proj    $root/tmp_kernel_pack
set xo          $root/$kernel_name.xo

file delete -force $packaged $tmp_proj $xo

set srcs [list \
  $repo/step2-rtl-decoder/rtl/itch5_pkg.sv \
  $repo/step2-rtl-decoder/rtl/itch_decoder.sv \
  $repo/step3b-splitter/rtl/mold_splitter.sv \
  $repo/step4a-order-table/rtl/otable_mem.sv \
  $repo/step4a-order-table/rtl/order_table.sv \
  $repo/step4a-order-table/rtl/order_table_pipe.sv \
  $repo/step4b-book/rtl/price_ladder.sv \
  $repo/step5-board/rtl/drop_fifo.sv \
  $repo/step5-board/rtl/fh_core.sv \
  $repo/step5-board/rtl/eth_ip_udp_rx.sv \
  $repo/step5-board/rtl/cdc_fifo.sv \
  $repo/step6-strategy/rtl/strategy.sv \
  $repo/step6-strategy/rtl/sweep_detect.sv \
  $repo/step6-strategy/rtl/ouch_builder.sv \
  $repo/step6-strategy/rtl/tcp_tx.sv \
  $repo/step5-board/rtl/feed_ab_arb.sv \
  $repo/step5-board/rtl/igmp_query_detect.sv \
  $repo/step5-board/rtl/t2t_top.sv \
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
  $root/rtl/t2t_kernel.sv ]

create_project -force kernel_pack $tmp_proj -part $part
add_files -norecurse $srcs
# the order table's URAM instantiation, same as every synthesis run in step 5
set_property verilog_define {OTABLE_XPM} [current_fileset]
set_property top $kernel_name [current_fileset]
update_compile_order -fileset sources_1

ipx::package_project -root_dir $packaged -vendor xilinx.com -library RTLKernel \
  -taxonomy /KernelIP -import_files -set_current false
ipx::unload_core $packaged/component.xml
ipx::edit_ip_in_project -upgrade true -name tmp_edit_project \
  -directory $packaged $packaged/component.xml

set core [ipx::current_core]
set_property core_revision 1 $core
foreach up [ipx::get_user_parameters] {
  ipx::remove_user_parameter [get_property NAME $up] $core
}
set_property sdx_kernel      true $core
set_property sdx_kernel_type rtl  $core
ipx::create_xgui_files $core

# the second clock/reset pair, which name-based inference does not pick up
ipx::infer_bus_interface ap_clk_2   xilinx.com:signal:clock_rtl:1.0 $core
ipx::infer_bus_interface ap_rst_n_2 xilinx.com:signal:reset_rtl:1.0 $core
set_property value ap_rst_n_2 [ipx::add_bus_parameter ASSOCIATED_RESET \
  [ipx::get_bus_interfaces ap_clk_2 -of_objects $core]]

# every AXI interface runs on ap_clk
ipx::associate_bus_interfaces -busif s_axi_control -clock ap_clk $core
ipx::associate_bus_interfaces -busif m_axi_gmem0   -clock ap_clk $core
ipx::associate_bus_interfaces -busif m_axi_gmem1   -clock ap_clk $core

# ---- CDC timing exceptions, shipped INSIDE the .xo ----
# Without this the implementation times every cdc_fifo crossing between ap_clk
# and ap_clk_2 as a synchronous transfer and fails by nanoseconds on paths that
# are not real (see t2t_kernel_cdc.xdc for the measured evidence). The file has
# to travel with the kernel, because v++ builds the platform's constraint set and
# knows nothing about this design's internal domains.
#   SCOPED_TO_REF   -- so get_ports ap_clk resolves inside the IP instance
#   PROCESSING_ORDER late -- the cell-based exceptions need the netlist
# The file must be COPIED INSIDE the packaged IP first. component.xml stores the
# path relative to the component root, so adding it from syn/ records
# "../syn/t2t_kernel_cdc.xdc" -- a path that escapes the IP, and that v++ cannot
# resolve once it unpacks the .xo into its own ip_repo:
#   CRITICAL WARNING: [IP_Flow 19-663] Failed to copy file
#     '.../_x/link/int/xo/ip_repo/syn/t2t_kernel_cdc.xdc', it does not exist.
#   ERROR: [IP_Flow 19-167] Failed to deliver one or more file(s).
# which kills the link a minute in, long before any synthesis happens.
file copy -force $here/t2t_kernel_cdc.xdc $packaged/src/t2t_kernel_cdc.xdc
set xdc_grp [ipx::add_file_group -type implementation {} $core]
set xdc_f   [ipx::add_file src/t2t_kernel_cdc.xdc $xdc_grp]
set_property type             xdc          $xdc_f
set_property used_in          {implementation out_of_context} $xdc_f
set_property scoped_to_ref    t2t_kernel    $xdc_f
set_property processing_order late          $xdc_f

set_property xpm_libraries {XPM_CDC XPM_MEMORY XPM_FIFO} $core
set_property supported_families { } $core
set_property auto_family_support_level level_2 $core
ipx::update_checksums $core
ipx::check_integrity -kernel $core
ipx::save_core $core
close_project -delete

package_xo -xo_path $xo -kernel_name $kernel_name -ip_directory $packaged \
  -kernel_xml $here/kernel.xml
puts "=== PACKAGED: $xo ==="
