#!/usr/bin/env bash
# One-time host setup so xsim/Vivado run on this WSL image.
#
# Vivado's bin wrapper (rdiArgs.sh) hard-codes `export LC_ALL=en_US.UTF-8`.
# This image only ships C / C.utf8 / POSIX, so the xsim binaries abort with
#   terminate ... what(): locale::facet::_S_create_c_locale name not valid
# Generating the locale system-wide needs root; instead we build a private
# copy under $LOCPATH, which glibc searches without root.
#
# Idempotent. Run once per machine; the Makefiles and ~/.bashrc already
# export LOCPATH=$HOME/.locale.
set -euo pipefail

LOC_DIR="${LOCPATH:-$HOME/.locale}"
TARGET="$LOC_DIR/en_US.UTF-8"

if [ -d "$TARGET" ]; then
    echo "locale already present: $TARGET"
    exit 0
fi

mkdir -p "$LOC_DIR"
echo "building en_US.UTF-8 into $LOC_DIR (no root needed) ..."
localedef -i en_US -f UTF-8 "$TARGET"
echo "done. ensure your shell has: export LOCPATH=\"$LOC_DIR\""
