#!/bin/bash
# Emit the Phase B v++ --config ini, with ABSOLUTE hook paths.
#
# Two hooks, at two different stages, because they need two different things to
# exist:
#
#   userPostSysLinkOverlayTcl  runs on the BLOCK DESIGN, right after sys_link has
#                              instantiated the kernel. That is the only moment
#                              at which both the kernel's GT interface pins and
#                              the platform's QSFP boundary ports exist as
#                              objects that can be connected -- see gt_connect.tcl
#                              for why nothing connects them automatically.
#   OPT_DESIGN.TCL.PRE         runs on the elaborated NETLIST, where the clocks
#                              exist and the CDC exceptions can name them.
#
# Absolute paths are mandatory: Vivado resolves TCL.PRE relative to the
# implementation run directory, several levels down inside
# _x/link/vivado/vpl/prj/prj.runs/impl_1, so a repo-relative path silently
# resolves to nothing and the hook never runs.
here="$(cd "$(dirname "$0")" && pwd)"
cat <<INI
[vivado]
prop=run.impl_1.STEPS.OPT_DESIGN.TCL.PRE=$here/impl_cdc_hook_b.tcl

[advanced]
param=compiler.userPostSysLinkOverlayTcl=$here/gt_connect.tcl
INI
