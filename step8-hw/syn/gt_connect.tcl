# Connect the kernel's GT interface to the platform's QSFP0 serial port.
#
# WHY THIS IS NEEDED. The platform exposes both QSFP GT groups to user logic --
# ext_metadata declares io_gt_qsfp0_00 on QUAD_X0Y6 with refclk
# io_clk_qsfp0_refclka_00, and the ULP block design carries the matching boundary
# ports (io_gt_qsfp0_00_grx_p/n, _gtx_p/n). The platform's postopt.tcl even
# package-pins them. What does NOT exist is any automation that wires a user
# kernel to them:
#
#   * v++ has no --connectivity.gt directive (the connectivity family is nk,
#     noc.*, region, sc, slr, sp, spalloc.* and nothing else);
#   * declaring a gt_serial_port bus interface of the correct type on the kernel
#     changes nothing -- the generated dr.bd.tcl instantiates the kernel and makes
#     no GT connection at all;
#   * naming the interface after the platform resource (io_gt_qsfp0_00) does not
#     help either.
#
# So the connection is made here, by hand, at the one point where both sides
# exist as block-design objects. This is the same lever that fixed the CDC
# constraints -- a Tcl hook running where the tool can see the design -- rather
# than a property that gets recorded and ignored.
#
# Wired in via: --advanced.param compiler.userPostSysLinkOverlayTcl=<this file>

puts "=== GT hook: looking for kernel GT pins and platform GT ports ==="

set gt_pin  [get_bd_intf_pins  -quiet */io_gt_qsfp0_00]
set gt_port [get_bd_intf_ports -quiet io_gt_qsfp0_00]
set rc_pin  [get_bd_intf_pins  -quiet */io_clk_qsfp0_refclka_00]
set rc_port [get_bd_intf_ports -quiet io_clk_qsfp0_refclka_00]

puts "=== GT hook: gt_pin=[llength $gt_pin] gt_port=[llength $gt_port] \
rc_pin=[llength $rc_pin] rc_port=[llength $rc_port] ==="

# List what is actually there, so a failure says why rather than just failing.
puts "=== GT hook: intf ports on the BD: [get_bd_intf_ports -quiet *] ==="

if {[llength $gt_pin] && [llength $gt_port]} {
  connect_bd_intf_net $gt_pin $gt_port
  puts "=== GT hook: SERIAL PORT CONNECTED ==="
} else {
  puts "=== GT hook: serial port NOT connected ==="
}

if {[llength $rc_pin] && [llength $rc_port]} {
  connect_bd_intf_net $rc_pin $rc_port
  puts "=== GT hook: REFCLK CONNECTED ==="
} else {
  puts "=== GT hook: refclk NOT connected ==="
}
