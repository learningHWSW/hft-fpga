# Gate 4: may this design's IP be turned into a BITSTREAM?
#
# WHY THIS EXISTS, and it is not a happy reason. Phase B was gated three ways
# before a line of it was written -- is cmac_usplus in the catalogue, will v++
# connect a kernel to the QSFP, does the MAC configure for this card's quad --
# specifically so that an hours-long build would never be the thing that
# discovered a blocker. All three passed. The kernel then synthesised, placed,
# routed and MET EVERY TIMING CONSTRAINT, and write_bitstream refused it:
#
#   ERROR: [Common 17-69] This design contains one or more cells for which
#   bitstream generation is not permitted:
#     .../u_cmac/u_cmac/inst/i_cmac_usplus_0_top (<encrypted cellview>)
#   The following IP(s) require licenses greater than a Design Linking license
#   to generate bitstream:  cmac_usplus
#
# 68 minutes of implementation to learn something a licence query answers in
# seconds. "The IP exists and can be configured" and "the IP may be built into a
# bitstream" are DIFFERENT QUESTIONS, and only the second one gates delivery.
# Vivado's default entitlement with no licence file present is Design Linking,
# which permits synthesis and implementation and nothing beyond -- so every
# earlier step succeeding tells you nothing about the last one.
#
# Run this before committing to any build that introduces a new licensed IP.
#
#   vivado -mode batch -source syn/gate_license.tcl
set part xcu55c-fsvh2892-2L-e

# IPs this project builds into a bitstream. Add to the list, do not replace it.
set wanted {cmac_usplus}

create_project -in_memory -part $part

puts "=== LICENCE GATE: environment ==="
foreach v {XILINXD_LICENSE_FILE LM_LICENSE_FILE} {
  if {[info exists ::env($v)]} {
    puts "  $v = $::env($v)"
  } else {
    puts "  $v = <unset>"
  }
}

# Ask FlexLM whether the feature can actually be CHECKED OUT.
#
# The obvious query -- get_property LICENSE_STATUS on the ipdef -- is not
# reliable here: on this install it reads EMPTY whether or not a valid licence is
# present, so a gate built on it fails a correctly licensed machine. That is
# worse than no gate, because the standard response to a gate that cries wolf is
# to disable it, and this one exists to prevent a 68-minute build from ending at
# write_bitstream.
#
# lmutil lmdiag performs a real checkout against the licence file and says so in
# words. Two wrinkles: lmutil is built against the LSB loader
# (/lib64/ld-lsb-x86-64.so.3) which Ubuntu does not ship, so it is invoked
# through the real loader when a direct exec fails; and the licence file has to
# be located, since XILINXD_LICENSE_FILE is commonly unset and Vivado falls back
# to ~/.Xilinx.
proc licence_files {} {
  set out {}
  foreach v {XILINXD_LICENSE_FILE LM_LICENSE_FILE} {
    if {[info exists ::env($v)]} {
      foreach p [split $::env($v) ":"] { if {[file exists $p]} { lappend out $p } }
    }
  }
  foreach p [glob -nocomplain [file join $::env(HOME) .Xilinx *.lic]] { lappend out $p }
  return [lsort -unique $out]
}

proc lmutil_path {} {
  set root $::env(XILINX_VIVADO)
  foreach c [list $root/bin/unwrapped/lnx64.o/lmutil $root/bin/lmutil] {
    if {[file executable $c]} { return $c }
  }
  return ""
}

# Returns 1 if FlexLM will grant $feature from $licfile.
proc feature_ok {feature licfile} {
  set lm [lmutil_path]
  if {$lm eq ""} { return -1 }
  set out ""
  if {[catch {set out [exec -ignorestderr $lm lmdiag -c $licfile $feature]}]} {
    # LSB loader missing: go through the system loader instead
    set ld /lib64/ld-linux-x86-64.so.2
    if {![file executable $ld]} { return -1 }
    if {[catch {set out [exec -ignorestderr $ld $lm lmdiag -c $licfile $feature]}]} {
      return -1
    }
  }
  if {[string match "*correct node for this node-locked license*" $out] ||
      [string match "*Checkout permitted*" $out]} { return 1 }
  return 0
}

set licfiles [licence_files]
puts "  licence files  : [expr {[llength $licfiles] ? $licfiles : "<none found>"}]"

set ok 1
foreach ipname $wanted {
  set defs [get_ipdefs -quiet *:${ipname}:*]
  if {[llength $defs] == 0} {
    puts "=== LICENCE GATE: $ipname NOT FOUND in the catalogue ==="
    set ok 0
    continue
  }
  set d [lindex $defs 0]
  puts "=== LICENCE GATE: [get_property NAME $d] ==="
  puts "  VLNV           : [get_property VLNV $d]"
  # LICENSE_KEYS is the IP's SUPERSET -- every feature any configuration could
  # need. Ours disables the fee-based ones (INCLUDE_AUTO_NEG_LT_LOGIC=0,
  # INCLUDE_RS_FEC=0), so requiring all of them would fail a machine that is
  # perfectly able to build this design. Only the base feature is gated; the
  # rest are reported so a future configuration change is not a silent surprise.
  puts "  all keys       : [get_property -quiet LICENSE_KEYS $d]"
  puts "  gated feature  : $ipname   (optional AN/LT and RS-FEC keys not required
                   by this design's configuration)"

  set verdict -1
  foreach lf $licfiles {
    set r [feature_ok $ipname $lf]
    if {$r == 1} { set verdict 1; break }
    if {$r == 0} { set verdict 0 }
  }
  if {$verdict == 1} {
    puts "  ---> LICENSED. FlexLM grants a checkout of '$ipname'."
  } elseif {$verdict == 0} {
    puts "  ---> NOT LICENSED FOR BITSTREAM. Synthesis and implementation will"
    puts "       succeed and write_bitstream will refuse the design. Obtain the"
    puts "       no-charge UltraScale+ 100G Ethernet licence (feature"
    puts "       '$ipname', NOT plain 'cmac' which is the UltraScale core) and"
    puts "       install it in ~/.Xilinx or set XILINXD_LICENSE_FILE."
    set ok 0
  } else {
    puts "  ---> UNKNOWN: could not run lmutil to test a checkout. Treating as a"
    puts "       failure so a build is not started on a guess. Check by hand with"
    puts "       'grep INCREMENT ~/.Xilinx/*.lic' -- the feature must be '$ipname'."
    set ok 0
  }
}

if {$ok} {
  puts "=== LICENCE GATE: PASS -- every listed IP may be built into a bitstream ==="
} else {
  puts "=== LICENCE GATE: FAIL -- do not start a build that needs the IP above ==="
}
