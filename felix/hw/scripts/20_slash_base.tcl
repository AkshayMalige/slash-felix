create_bd_design slash_base
current_bd_design slash_base

set ini inimm_rtl:1.0
create_bd_intf_port -mode Slave  -vlnv xilinx.com:interface:$ini S_AXILITE_INI
set ddr_ports {}
for {set i 0} {$i < 12} {incr i} {
    set p [format M%02d_INI $i]
    create_bd_intf_port -mode Master -vlnv xilinx.com:interface:$ini $p
    lappend ddr_ports $p
}
set mem_ports {}
for {set i 0} {$i < 8} {incr i} {
    set p [format HBM_VNOC_INI_%02d $i]
    create_bd_intf_port -mode Master -vlnv xilinx.com:interface:$ini $p
    lappend mem_ports $p
}
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:$ini QDMA_SLAVE_BRIDGE_0
create_bd_port -dir I -type clk -freq_hz [expr {$::felix_user_clk_mhz * 1000000}] user_clk
create_bd_port -dir I -type rst arstn

set_property APERTURES {{0x202_0000_0000 128M}} [get_bd_intf_ports S_AXILITE_INI]

proc felix_door_noc {name port} {
    set n [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_noc:1.1 $name]
    set_property -dict {CONFIG.NUM_SI {1} CONFIG.NUM_MI {0} CONFIG.NUM_NSI {0} CONFIG.NUM_NMI {1} CONFIG.NUM_CLKS {1}} $n
    set_property -dict {CONFIG.CONNECTIONS {M00_INI {read_bw {500} write_bw {500}}} CONFIG.NOC_PARAMS {} CONFIG.CATEGORY {pl}} [get_bd_intf_pins $name/S00_AXI]
    set_property CONFIG.INI_STRATEGY {driver} [get_bd_intf_pins $name/M00_INI]
    set_property CONFIG.ASSOCIATED_BUSIF {S00_AXI} [get_bd_pins $name/aclk0]
    connect_bd_intf_net [get_bd_intf_pins $name/M00_INI] [get_bd_intf_ports $port]
}
proc felix_terminate {name dst_pin} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 $name
    connect_bd_intf_net [get_bd_intf_pins $name/M_AXI] [get_bd_intf_pins $dst_pin]
}

for {set i 0} {$i < 12} {incr i} {
    felix_door_noc ddr_noc_$i [lindex $ddr_ports $i]
    if {$i < 4} {
        create_bd_cell -type ip -vlnv xilinx.com:hls:hbm_bandwidth:1.0 ddr_bandwidth_$i
        connect_bd_intf_net [get_bd_intf_pins ddr_bandwidth_$i/m_axi_gmem0] [get_bd_intf_pins ddr_noc_$i/S00_AXI]
    } else {
        felix_terminate axi_register_slice_ddrterm_$i ddr_noc_$i/S00_AXI
    }
}
for {set i 0} {$i < 8} {incr i} {
    felix_door_noc hbm_vnoc_0$i [lindex $mem_ports $i]
    felix_terminate axi_register_slice_memterm_$i hbm_vnoc_0$i/S00_AXI
}
felix_door_noc qdma_slave_bridge_noc QDMA_SLAVE_BRIDGE_0
felix_terminate axi_register_slice_hostterm qdma_slave_bridge_noc/S00_AXI

set nc [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_noc:1.1 axi_noc_0]
set_property -dict {CONFIG.NUM_SI {0} CONFIG.NUM_MI {1} CONFIG.NUM_NSI {1} CONFIG.NUM_NMI {0} CONFIG.NUM_CLKS {1}} $nc
set_property -dict {CONFIG.APERTURES {{0x202_0000_0000 128M}} CONFIG.CATEGORY {pl}} [get_bd_intf_pins axi_noc_0/M00_AXI]
set_property -dict {CONFIG.INI_STRATEGY {load} CONFIG.CONNECTIONS {M00_AXI {read_bw {5} write_bw {5} read_avg_burst {4} write_avg_burst {4}}}} [get_bd_intf_pins axi_noc_0/S00_INI]
set_property CONFIG.ASSOCIATED_BUSIF {M00_AXI} [get_bd_pins axi_noc_0/aclk0]
connect_bd_intf_net [get_bd_intf_ports S_AXILITE_INI] [get_bd_intf_pins axi_noc_0/S00_INI]

set sc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 smartconnect_0]
set_property -dict {CONFIG.NUM_SI {1} CONFIG.NUM_MI {4}} $sc
connect_bd_intf_net [get_bd_intf_pins axi_noc_0/M00_AXI] [get_bd_intf_pins smartconnect_0/S00_AXI]
foreach i {0 1 2 3} { connect_bd_intf_net [get_bd_intf_pins smartconnect_0/M0${i}_AXI] [get_bd_intf_pins ddr_bandwidth_${i}/s_axi_control] }

# GT streams from the static shell (25_felix_gt.tcl): gt_axis_noc_s_<k> receives quad k's RX
# stream, gt_axis_noc_<k> sends the kernel's TX stream. Strategy and bandwidth as on the static end.
# Keep these cells' settings textually identical to linker slash_compute.tcl (e.g. write_bw {N}):
# a kernel image's stream cells join the shell's locked NoC paths only if the text matches;
# otherwise the paths stop at the region boundary and the streams carry no data.
if {![info exists ::felix_gt_quads]} { set ::felix_gt_quads {} }
for {set k 0} {$k < [llength $::felix_gt_quads]} {incr k} {
    create_bd_intf_port -mode Slave  -vlnv xilinx.com:interface:inis_rtl:1.0 S_GT_INIS$k
    create_bd_intf_port -mode Master -vlnv xilinx.com:interface:inis_rtl:1.0 M_GT_INIS$k
    set r [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_noc:1.0 gt_axis_noc_s_$k]
    set_property -dict {CONFIG.NUM_NSI {1} CONFIG.NUM_SI {0}} $r
    set_property -dict {CONFIG.TDATA_NUM_BYTES {64} CONFIG.TDEST_WIDTH {0} CONFIG.TID_WIDTH {0} CONFIG.CATEGORY {pl}} [get_bd_intf_pins gt_axis_noc_s_$k/M00_AXIS]
    set_property -dict [list CONFIG.INI_STRATEGY {load} CONFIG.CONNECTIONS "M00_AXIS {write_bw {$::felix_gt_stream_mbps}}"] [get_bd_intf_pins gt_axis_noc_s_$k/S00_INIS]
    connect_bd_intf_net [get_bd_intf_ports S_GT_INIS$k] [get_bd_intf_pins gt_axis_noc_s_$k/S00_INIS]
    set t [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_noc:1.0 gt_axis_noc_$k]
    set_property -dict {CONFIG.NUM_MI {0} CONFIG.NUM_NMI {1}} $t
    set_property -dict [list CONFIG.TDATA_NUM_BYTES {64} CONFIG.CATEGORY {pl} CONFIG.CONNECTIONS "M00_INIS {write_bw {$::felix_gt_stream_mbps}}"] [get_bd_intf_pins gt_axis_noc_$k/S00_AXIS]
    set_property CONFIG.INI_STRATEGY {driver} [get_bd_intf_pins gt_axis_noc_$k/M00_INIS]
    connect_bd_intf_net [get_bd_intf_pins gt_axis_noc_$k/M00_INIS] [get_bd_intf_ports M_GT_INIS$k]
}

set rstpins [dict create]
foreach c [get_bd_cells *] {
    set grp [expr {[string match ddr_bandwidth_* [get_property NAME $c]] ? [get_property NAME $c] : "infra"}]
    foreach pin {aresetn ap_rst_n} { foreach p [get_bd_pins -quiet $c/$pin] { dict lappend rstpins $grp $p } }
}
dict for {grp pins} $rstpins {
    set r [create_bd_cell -type ip -vlnv xilinx.com:ip:c_shift_ram:12.0 rst_repl_$grp]
    set_property -dict {CONFIG.Width {1} CONFIG.Depth {1}} $r
    connect_bd_net [get_bd_ports arstn] [get_bd_pins $r/D]
    connect_bd_net [get_bd_pins $r/Q] {*}$pins
}
set clkpins {}
foreach c [get_bd_cells *] {
    foreach pin {aclk0 aclk ap_clk CLK} { foreach p [get_bd_pins -quiet $c/$pin] { lappend clkpins $p } }
}
connect_bd_net [get_bd_ports user_clk] {*}$clkpins

save_bd_design
puts "SLASH_BASE_CELLS: [llength [get_bd_cells *]]"
validate_bd_design
puts "SLASH_BASE_VALIDATE_DONE"
