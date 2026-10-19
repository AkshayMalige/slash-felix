#!/bin/bash
# Simulate the GT quad glue (lane adapters + registers) and the board line block with xsim.
# Needs Vivado 2025.1 settings.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
XPM=$XILINX_VIVADO/data/ip/xpm
OUT=${OUT:-$HERE/build}
mkdir -p "$OUT" && cd "$OUT"
xvlog -sv "$XPM/xpm_cdc/hdl/xpm_cdc.sv" "$XPM/xpm_memory/hdl/xpm_memory.sv" "$XPM/xpm_fifo/hdl/xpm_fifo.sv" > xvlog_xpm.log
xvlog "$XILINX_VIVADO/data/verilog/src/glbl.v" \
    "$HERE/../felix_gt_rx_adapter.v" "$HERE/../felix_gt_tx_adapter.v" "$HERE/../felix_gt_quad_if.v" \
    "$HERE/../felix_board_io.v" > xvlog_rtl.log
xvlog -sv "$HERE/tb_felix_gt_quad_if.sv" "$HERE/tb_felix_board_io.sv" > xvlog_tb.log
rc=0
for tb in tb_felix_gt_quad_if tb_felix_board_io; do
    xelab -debug off -L unisims_ver $tb glbl -s $tb > xelab_$tb.log
    xsim $tb -R | tee xsim_$tb.log | grep -E "TB_RESULT|FAIL|words received|RX_BEATS|TX_UNDERFLOWS|REFCLK|TX_USRCLK" | sed "s/^/$tb: /"
    grep -q "TB_RESULT: PASS" xsim_$tb.log || rc=1
done
exit $rc
