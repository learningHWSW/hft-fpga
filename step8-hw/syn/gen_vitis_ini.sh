#!/bin/bash
# Emit the v++ --config ini with an ABSOLUTE hook path.
#
# The path must be absolute: Vivado resolves TCL.PRE relative to the
# implementation run directory, which sits several levels down inside
# _x/link/vivado/vpl/prj/prj.runs/impl_1, so a repo-relative path silently
# resolves to nothing and the hook never runs -- the same class of failure as the
# packaged XDC that was delivered but never applied.
here="$(cd "$(dirname "$0")" && pwd)"
cat <<INI
[vivado]
prop=run.impl_1.STEPS.OPT_DESIGN.TCL.PRE=$here/impl_cdc_hook.tcl
INI
