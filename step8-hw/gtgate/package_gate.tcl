# Package the GT feasibility gate as a .xo, with a real gt_serial_port interface.
#
# The interface contract is taken from Xilinx's own MAC IP (xxv_ethernet's
# component.xml), which is where `gt_serial_port` is defined as a bus interface:
#   busType         xilinx.com:interface:gt:1.0
#   abstractionType xilinx.com:interface:gt_rtl:1.0
#   logical GRX_N/GRX_P/GTX_N/GTX_P mapped to the RTL's rx/tx differential pins
# The platform declares the matching resource (io_gt_qsfp0_00, QUAD_X0Y6, refclk
# io_clk_qsfp0_refclka_00), so if the naming is right v++ should connect them.
set here [file dirname [file normalize [info script]]]
set part xcu55c-fsvh2892-2L-e
set kernel_name gt_gate
set packaged $here/packaged
set tmp_proj $here/tmp_pack
set xo       $here/gt_gate.xo

file delete -force $packaged $tmp_proj $xo

create_project -force gate_pack $tmp_proj -part $part
add_files -norecurse [list $here/gt_gate.sv]
set_property top $kernel_name [current_fileset]
update_compile_order -fileset sources_1

ipx::package_project -root_dir $packaged -vendor xilinx.com -library RTLKernel \
  -taxonomy /KernelIP -import_files -set_current false
ipx::unload_core $packaged/component.xml
ipx::edit_ip_in_project -upgrade true -name tmp_edit -directory $packaged \
  $packaged/component.xml

set core [ipx::current_core]
set_property core_revision 1 $core
foreach up [ipx::get_user_parameters] {
  ipx::remove_user_parameter [get_property NAME $up] $core
}
set_property sdx_kernel true $core
set_property sdx_kernel_type rtl $core
ipx::create_xgui_files $core

# ---- the GT serial port ----
set gt [ipx::add_bus_interface io_gt_qsfp0_00 $core]
set_property abstraction_type_vlnv xilinx.com:interface:gt_rtl:1.0 $gt
set_property bus_type_vlnv        xilinx.com:interface:gt:1.0      $gt
set_property interface_mode       master                           $gt
foreach {logical physical} {GRX_N gt_rxn_in GRX_P gt_rxp_in GTX_N gt_txn_out GTX_P gt_txp_out} {
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

ipx::associate_bus_interfaces -busif s_axi_control -clock ap_clk $core

set_property supported_families { } $core
set_property auto_family_support_level level_2 $core
ipx::update_checksums $core
ipx::check_integrity -kernel $core
ipx::save_core $core
close_project -delete

package_xo -xo_path $xo -kernel_name $kernel_name -ip_directory $packaged \
  -kernel_xml $here/kernel.xml
puts "=== GATE PACKAGED: $xo ==="
