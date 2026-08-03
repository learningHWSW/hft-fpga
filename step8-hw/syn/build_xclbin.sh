#!/bin/bash
# Link the .xo into an .xclbin for the U55C. Hours, so it runs detached.
set -x
unset LD_LIBRARY_PATH
source /opt/Xilinx/2025.2.1/Vitis/settings64.sh
cd /home/wlstjr4425/00_Download/hft-fpga/step8-hw
make xclbin 2>&1
echo "=== XCLBIN EXIT: $? ==="
ls -la t2t.xclbin && echo "XCLBIN_BUILD_OK"
