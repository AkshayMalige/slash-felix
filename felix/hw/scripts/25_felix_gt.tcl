# GT quads in the static shell, one hierarchy gt_<bank> per entry of ::felix_gt_quads, the
# reference clock meter (felix_refclk_meter) that owns the input buffers of all 8 reference clock
# pin pairs of the FireFly quads (REFCLK0 = Si5395, REFCLK1 = Si570 via a Si53344 splitter), and
# felix_board_io, which drives the FireFly control lines in bank 703.
# Each quad: gtwiz_versal (raw 64-bit, 25.78125 Gb/s) fed by its REFCLK1 buffer in the meter, user
# clock buffers, felix_gt_quad_if (lane adapters + host registers) and two NoC stream cells to the
# kernel region. The wizard's register port (256 KB, too big for the BAR4 window) sits behind
# felix_gt_quad_if, which reaches it one word at a time (GT_ADDR/GT_CMD). Stream k of the kernel region (slash/S_GT_INIS<k>, slash/M_GT_INIS<k>) is quad k.
# Sourced from 30_integrate.tcl after the slash container exists; felix_gt_check_addresses runs
# after assign_bd_address.

if {![info exists ::felix_gt_quads]} { set ::felix_gt_quads {} }
# NoC bandwidth per stream in MB/s: the line rate is 12890, so leave some margin
if {![info exists ::felix_gt_stream_mbps]} { set ::felix_gt_stream_mbps 14000 }

# bank -> GT quad site, meter input of its REFCLK1, static NoC sites next to the quad (clock
# regions X1Y4, X1Y5 and X1Y7; felix_pblock.xdc keeps X1Y7 out of the kernel region)
set ::felix_gt_quad_table {
    106 {GTYP_QUAD_X0Y6  1 NOC_NMU512_X0Y6 NOC_NSU512_X0Y6}
    110 {GTYP_QUAD_X0Y10 3 NOC_NMU512_X0Y7 NOC_NSU512_X0Y7}
    111 {GTYP_QUAD_X0Y11 5 NOC_NMU512_X0Y11 NOC_NSU512_X0Y11}
    112 {GTYP_QUAD_X0Y12 7 NOC_NMU512_X0Y12 NOC_NSU512_X0Y12}
}
# meter input i: quad, REFCLK0/1, P and N pins (schematic pp.3-4)
set ::felix_refclk_pins {
    {106 0 AF11 AF10} {106 1 AE13 AE12} {110 0 N13 N12} {110 1 M11 M10}
    {111 0 L13 L12}   {111 1 K11 K10}   {112 0 J13 H13} {112 1 J15 H15}
}
# Board pins driven with fixed levels (bank 707, 1.5 V; schematic pp.11-12, 38). The Si53344
# splitters choose between CLK0 (the 156.25 MHz Si570) and CLK1 (not connected) with CLK_SEL,
# which comes from these FPGA pins through a level shifter: left floating (bank unused), the
# splitters pass noise. si53344_sel = 0 selects the Si570. Using the bank pulls its unused pins
# low, so the I2C mux reset (BP40) is driven high (i2c_mux_rst_b = 1), as in the FELIX firmware.
# Bank 703 (1.5 V, schematic pp.31, 46-49): reset, I2C select, present and interrupt of the
# FireFly 1/2 TX and RX modules (bit order FF1 TX, FF1 RX, FF2 TX, FF2 RX), driven as in the FELIX
# firmware. FireFly 6 and the two I/O expander resets share the bank and would be pulled low, so
# they get their FELIX levels too.
set ::felix_board_pins {
    {si53344_sel[0]    BK39}
    {si53344_sel[1]    BJ39}
    {i2c_mux_rst_b     BP40}
    {ff_rst_b[0]       BP18} {ff_sel_b[0]   BU18} {ff_prsnt_b[0] BR18} {ff_intr_b[0] BU19}
    {ff_rst_b[1]       BN20} {ff_sel_b[1]   BT20} {ff_prsnt_b[1] BR19} {ff_intr_b[1] BP21}
    {ff_rst_b[2]       BL19} {ff_sel_b[2]   BJ20} {ff_prsnt_b[2] BL20} {ff_intr_b[2] BK19}
    {ff_rst_b[3]       BJ19} {ff_sel_b[3]   BG20} {ff_prsnt_b[3] BK18} {ff_intr_b[3] BH19}
    {ff6_rst_b         BE19} {ff6_sel_b     BF19} {ff6_prsnt_b   BE20} {ff6_intr_b   BG19}
    {ioexp_rst_b[0]    BV19} {ioexp_intr_b[0] BV18}
    {ioexp_rst_b[1]    BT19} {ioexp_intr_b[1] BV20}
}

proc felix_gt_quad {bank k nmu nsu} {
    current_bd_instance /
    set h [create_bd_cell -type hier gt_$bank]
    current_bd_instance $h

    create_bd_pin -dir I -type clk aclk
    create_bd_pin -dir I -type rst aresetn
    create_bd_pin -dir I -type clk refclk
    create_bd_pin -dir I -type clk refclk_mon
    create_bd_intf_pin -mode Slave  -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI
    create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:inis_rtl:1.0 M_INIS
    create_bd_intf_pin -mode Slave  -vlnv xilinx.com:interface:inis_rtl:1.0 S_INIS
    create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:gt_rtl:1.0 GT_SERIAL

    # the clock is on the quad's REFCLK1 pin: refclk source R1 puts the LCPLL on GTREFCLK1
    # (HS0/HS1_LCPLL_IPS_REFCLK_SEL = 2), as in the FELIX firmware; with the default (R0) it
    # listens to GTREFCLK0 and never locks. The wizard port stays QUAD0_GTREFCLK0.
    set g [create_bd_cell -type ip -vlnv xilinx.com:ip:gtwiz_versal:1.0 gtwiz_versal]
    set_property -dict [list \
        CONFIG.INTF0_GT_SETTINGS(LR0_SETTINGS) {RX_LINE_RATE 25.78125 TX_LINE_RATE 25.78125 RX_USER_DATA_WIDTH 64 RX_INT_DATA_WIDTH 64 TX_USER_DATA_WIDTH 64 TX_INT_DATA_WIDTH 64 RX_EQ_MODE LPM RX_REFCLK_SOURCE R1 TX_REFCLK_SOURCE R1} \
        CONFIG.QUAD0_CH0_LOOPBACK_EN {true} CONFIG.QUAD0_CH1_LOOPBACK_EN {true} \
        CONFIG.QUAD0_CH2_LOOPBACK_EN {true} CONFIG.QUAD0_CH3_LOOPBACK_EN {true} \
        CONFIG.ENABLE_REG_INTERFACE {true} CONFIG.REG_CONF_INTF {AXI_LITE} \
    ] $g
    set txbuf [create_bd_cell -type ip -vlnv xilinx.com:ip:bufg_gt:1.0 bufg_gt_tx]
    set rxbuf [create_bd_cell -type ip -vlnv xilinx.com:ip:bufg_gt:1.0 bufg_gt_rx]

    set q [create_bd_cell -type module -reference felix_gt_quad_if quad_if]
    set_property CONFIG.BANK $bank $q

    set rx [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_noc:1.0 rx_noc]
    set_property -dict {CONFIG.NUM_MI {0} CONFIG.NUM_NMI {1}} $rx
    set_property -dict [list CONFIG.TDATA_NUM_BYTES {64} CONFIG.CATEGORY {pl} CONFIG.PHYSICAL_LOC $nmu \
        CONFIG.CONNECTIONS "M00_INIS {write_bw {$::felix_gt_stream_mbps}}"] [get_bd_intf_pins rx_noc/S00_AXIS]
    set_property CONFIG.INI_STRATEGY {load} [get_bd_intf_pins rx_noc/M00_INIS]
    set tx [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_noc:1.0 tx_noc]
    set_property -dict {CONFIG.NUM_SI {0} CONFIG.NUM_NSI {1}} $tx
    set_property -dict [list CONFIG.TDATA_NUM_BYTES {64} CONFIG.TDEST_WIDTH {0} CONFIG.TID_WIDTH {0} \
        CONFIG.CATEGORY {pl} CONFIG.PHYSICAL_LOC $nsu] [get_bd_intf_pins tx_noc/M00_AXIS]
    # kernel -> static streams take their bandwidth from this (static) end
    set_property -dict [list CONFIG.INI_STRATEGY {driver} \
        CONFIG.CONNECTIONS "M00_AXIS {write_bw {$::felix_gt_stream_mbps}}"] [get_bd_intf_pins tx_noc/S00_INIS]

    connect_bd_intf_net [get_bd_intf_pins GT_SERIAL] [get_bd_intf_pins gtwiz_versal/Quad0_GT_Serial]
    connect_bd_intf_net [get_bd_intf_pins S_AXI] [get_bd_intf_pins quad_if/s_axi]
    connect_bd_intf_net [get_bd_intf_pins quad_if/m_axi_gt] [get_bd_intf_pins gtwiz_versal/Quad0_AXI_LITE]
    connect_bd_intf_net [get_bd_intf_pins quad_if/m_axis_rx] [get_bd_intf_pins rx_noc/S00_AXIS]
    connect_bd_intf_net [get_bd_intf_pins rx_noc/M00_INIS] [get_bd_intf_pins M_INIS]
    connect_bd_intf_net [get_bd_intf_pins S_INIS] [get_bd_intf_pins tx_noc/S00_INIS]
    connect_bd_intf_net [get_bd_intf_pins tx_noc/M00_AXIS] [get_bd_intf_pins quad_if/s_axis_tx]

    connect_bd_net [get_bd_pins refclk] [get_bd_pins gtwiz_versal/QUAD0_GTREFCLK0]
    connect_bd_net [get_bd_pins refclk_mon] [get_bd_pins quad_if/refclk_mon]

    connect_bd_net [get_bd_pins aclk] [get_bd_pins gtwiz_versal/gtwiz_freerun_clk] [get_bd_pins quad_if/s_axi_aclk]
    connect_bd_net [get_bd_pins aresetn] [get_bd_pins quad_if/s_axi_aresetn] \
        [get_bd_pins gtwiz_versal/QUAD0_s_axi_lite_resetn]

    connect_bd_net [get_bd_pins gtwiz_versal/QUAD0_TX0_outclk] [get_bd_pins bufg_gt_tx/outclk]
    connect_bd_net [get_bd_pins gtwiz_versal/QUAD0_RX0_outclk] [get_bd_pins bufg_gt_rx/outclk]
    connect_bd_net [get_bd_pins bufg_gt_tx/usrclk] \
        [get_bd_pins gtwiz_versal/QUAD0_TX0_usrclk] [get_bd_pins gtwiz_versal/QUAD0_TX1_usrclk] \
        [get_bd_pins gtwiz_versal/QUAD0_TX2_usrclk] [get_bd_pins gtwiz_versal/QUAD0_TX3_usrclk] \
        [get_bd_pins quad_if/tx_usrclk] [get_bd_pins tx_noc/aclk0]
    connect_bd_net [get_bd_pins bufg_gt_rx/usrclk] \
        [get_bd_pins gtwiz_versal/QUAD0_RX0_usrclk] [get_bd_pins gtwiz_versal/QUAD0_RX1_usrclk] \
        [get_bd_pins gtwiz_versal/QUAD0_RX2_usrclk] [get_bd_pins gtwiz_versal/QUAD0_RX3_usrclk] \
        [get_bd_pins quad_if/rx_usrclk] [get_bd_pins rx_noc/aclk0]

    foreach {qpin gpin} {
        gt_rst_all                 INTF0_rst_all_in
        gt_rst_tx_pll_and_datapath INTF0_rst_tx_pll_and_datapath_in
        gt_rst_tx_datapath         INTF0_rst_tx_datapath_in
        gt_rst_rx_pll_and_datapath INTF0_rst_rx_pll_and_datapath_in
        gt_rst_rx_datapath         INTF0_rst_rx_datapath_in
        gt_rst_tx_done             INTF0_rst_tx_done_out
        gt_rst_rx_done             INTF0_rst_rx_done_out
        gtpowergood                gtpowergood
    } {
        connect_bd_net [get_bd_pins quad_if/$qpin] [get_bd_pins gtwiz_versal/$gpin]
    }
    for {set c 0} {$c < 4} {incr c} {
        connect_bd_net [get_bd_pins quad_if/ch${c}_loopback]    [get_bd_pins gtwiz_versal/QUAD0_ch${c}_loopback]
        connect_bd_net [get_bd_pins quad_if/txdata$c]          [get_bd_pins gtwiz_versal/INTF0_TX${c}_ch_txdata]
        connect_bd_net [get_bd_pins quad_if/txprbssel$c]       [get_bd_pins gtwiz_versal/INTF0_TX${c}_ch_txprbssel]
        connect_bd_net [get_bd_pins quad_if/txpolarity$c]      [get_bd_pins gtwiz_versal/INTF0_TX${c}_ch_txpolarity]
        connect_bd_net [get_bd_pins quad_if/rxdata$c]          [get_bd_pins gtwiz_versal/INTF0_RX${c}_ch_rxdata]
        connect_bd_net [get_bd_pins quad_if/rxprbssel$c]       [get_bd_pins gtwiz_versal/INTF0_RX${c}_ch_rxprbssel]
        connect_bd_net [get_bd_pins quad_if/rxprbscntreset$c]  [get_bd_pins gtwiz_versal/INTF0_RX${c}_ch_rxprbscntreset]
        connect_bd_net [get_bd_pins quad_if/rxpolarity$c]      [get_bd_pins gtwiz_versal/INTF0_RX${c}_ch_rxpolarity]
        connect_bd_net [get_bd_pins quad_if/rxprbslocked$c]    [get_bd_pins gtwiz_versal/INTF0_RX${c}_ch_rxprbslocked]
        connect_bd_net [get_bd_pins quad_if/rxprbserr$c]       [get_bd_pins gtwiz_versal/INTF0_RX${c}_ch_rxprbserr]
    }
    current_bd_instance /
}

# One register window per quad and one for the meter, on more master ports of the management
# smartconnect that already serves the clock wizards and the build-ID register (pl0_ref_clk).
proc felix_gt_axi_port {k name} {
    set sc [get_bd_cells static_region/clk_rst_shell/smartconnect_0]
    set mi [format M%02d_AXI $k]
    current_bd_instance /static_region/clk_rst_shell
    create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 $name
    connect_bd_intf_net [get_bd_intf_pins smartconnect_0/$mi] [get_bd_intf_pins $name]
    current_bd_instance /static_region
    create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 $name
    connect_bd_intf_net [get_bd_intf_pins clk_rst_shell/$name] [get_bd_intf_pins $name]
    current_bd_instance /
}

# Fixed host addresses, assigned before the automatic pass so that pass does not move the clock
# wizards and the build-ID register (vrtd reads it at PF2 BAR4 + 0x20000).
proc felix_gt_assign {seg offset {range 64K}} {
    foreach space {CPM_PCIE_NOC_0 CPM_PCIE_NOC_1} {
        assign_bd_address -offset [format 0x%X $offset] -range $range \
            -target_address_space [get_bd_addr_spaces static_region/aved/cips/$space] [get_bd_addr_segs $seg]
    }
}

proc felix_gt_build {} {
    set nq [llength $::felix_gt_quads]
    if {$nq == 0} { return }
    set sc [get_bd_cells static_region/clk_rst_shell/smartconnect_0]
    set base_mi [get_property CONFIG.NUM_MI $sc]
    set_property CONFIG.NUM_MI [expr {$base_mi + $nq + 2}] $sc

    current_bd_instance /static_region/clk_rst_shell
    create_bd_pin -dir O -type rst gt_aresetn
    connect_bd_net [get_bd_pins proc_sys_reset_axi/peripheral_aresetn] [get_bd_pins gt_aresetn]
    current_bd_instance /static_region
    create_bd_pin -dir O -type rst gt_aresetn
    connect_bd_net [get_bd_pins clk_rst_shell/gt_aresetn] [get_bd_pins gt_aresetn]
    current_bd_instance /

    # reference clock meter: all 8 refclk pin pairs
    set m [create_bd_cell -type module -reference felix_refclk_meter refclk_meter]
    create_bd_port -dir I -from 7 -to 0 gt_refclk_p
    create_bd_port -dir I -from 7 -to 0 gt_refclk_n
    connect_bd_net [get_bd_ports gt_refclk_p] [get_bd_pins refclk_meter/refclk_p]
    connect_bd_net [get_bd_ports gt_refclk_n] [get_bd_pins refclk_meter/refclk_n]
    felix_gt_axi_port [expr {$base_mi + $nq}] M_AXI_REFCLK
    connect_bd_intf_net [get_bd_intf_pins static_region/M_AXI_REFCLK] [get_bd_intf_pins refclk_meter/s_axi]
    connect_bd_net [get_bd_pins static_region/pl0_ref_clk] [get_bd_pins refclk_meter/s_axi_aclk]
    connect_bd_net [get_bd_pins static_region/gt_aresetn] [get_bd_pins refclk_meter/s_axi_aresetn]
    felix_gt_assign refclk_meter/s_axi/reg0 0x20400070000 32K

    # board lines: same 64 KB slot as the meter, upper half
    set b [create_bd_cell -type module -reference felix_board_io board_io]
    foreach {port dir width} {ff_rst_b O 4 ff_sel_b O 4 ff_prsnt_b I 4 ff_intr_b I 4
                              ff6_rst_b O 1 ff6_sel_b O 1 ff6_prsnt_b I 1 ff6_intr_b I 1
                              ioexp_rst_b O 2 ioexp_intr_b I 2} {
        if {$width > 1} {
            create_bd_port -dir $dir -from [expr {$width - 1}] -to 0 $port
        } else {
            create_bd_port -dir $dir $port
        }
        connect_bd_net [get_bd_ports $port] [get_bd_pins board_io/$port]
    }
    felix_gt_axi_port [expr {$base_mi + $nq + 1}] M_AXI_BOARD
    connect_bd_intf_net [get_bd_intf_pins static_region/M_AXI_BOARD] [get_bd_intf_pins board_io/s_axi]
    connect_bd_net [get_bd_pins static_region/pl0_ref_clk] [get_bd_pins board_io/s_axi_aclk]
    connect_bd_net [get_bd_pins static_region/gt_aresetn] [get_bd_pins board_io/s_axi_aresetn]
    felix_gt_assign board_io/s_axi/reg0 0x20400078000 32K

    create_bd_port -dir O -from 1 -to 0 si53344_sel
    create_bd_port -dir O i2c_mux_rst_b
    set c0 [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 si53344_sel_const]
    set_property -dict {CONFIG.CONST_WIDTH {2} CONFIG.CONST_VAL {0}} $c0
    set c1 [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 i2c_mux_rst_b_const]
    set_property -dict {CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}} $c1
    connect_bd_net [get_bd_pins si53344_sel_const/dout] [get_bd_ports si53344_sel]
    connect_bd_net [get_bd_pins i2c_mux_rst_b_const/dout] [get_bd_ports i2c_mux_rst_b]

    set k 0
    foreach bank $::felix_gt_quads {
        lassign [dict get $::felix_gt_quad_table $bank] site ref nmu nsu
        felix_gt_axi_port [expr {$base_mi + $k}] M_AXI_GT$k
        felix_gt_quad $bank $k $nmu $nsu

        create_bd_intf_port -mode Master -vlnv xilinx.com:interface:gt_rtl:1.0 gt_serial_$bank
        connect_bd_intf_net [get_bd_intf_ports gt_serial_$bank] [get_bd_intf_pins gt_$bank/GT_SERIAL]
        connect_bd_net [get_bd_pins refclk_meter/refclk_o$ref] [get_bd_pins gt_$bank/refclk]
        connect_bd_net [get_bd_pins refclk_meter/refclk_mon$ref] [get_bd_pins gt_$bank/refclk_mon]
        connect_bd_intf_net [get_bd_intf_pins static_region/M_AXI_GT$k] [get_bd_intf_pins gt_$bank/S_AXI]
        connect_bd_net [get_bd_pins static_region/pl0_ref_clk] [get_bd_pins gt_$bank/aclk]
        connect_bd_net [get_bd_pins static_region/gt_aresetn] [get_bd_pins gt_$bank/aresetn]
        connect_bd_intf_net [get_bd_intf_pins gt_$bank/M_INIS] [get_bd_intf_pins slash/S_GT_INIS$k]
        connect_bd_intf_net [get_bd_intf_pins slash/M_GT_INIS$k] [get_bd_intf_pins gt_$bank/S_INIS]
        felix_gt_assign gt_$bank/quad_if/s_axi/reg0 [expr {0x20400030000 + $k * 0x10000}]
        assign_bd_address -offset 0 -range 256K -target_address_space [get_bd_addr_spaces gt_$bank/quad_if/m_axi_gt] \
            [get_bd_addr_segs gt_$bank/gtwiz_versal/Quad0_AXI_LITE/Reg]
        incr k
    }
    felix_gt_write_xdc
    puts "FELIX_GT: [llength $::felix_gt_quads] quad(s): $::felix_gt_quads, refclk meter at 0x20400070000, board lines at 0x20400078000"
}

proc felix_gt_write_xdc {} {
    set f [file join [get_property DIRECTORY [current_project]] felix_gt.xdc]
    set fh [open $f w]
    set i 0
    foreach entry $::felix_refclk_pins {
        lassign $entry bank r p n
        puts $fh "set_property PACKAGE_PIN $p \[get_ports {gt_refclk_p\[$i\]}\]"
        puts $fh "set_property PACKAGE_PIN $n \[get_ports {gt_refclk_n\[$i\]}\]"
        puts $fh "create_clock -period 6.400 -name refclk_${bank}_$r \[get_ports {gt_refclk_p\[$i\]}\]"
        incr i
    }
    foreach entry $::felix_board_pins {
        lassign $entry port pin
        puts $fh "set_property PACKAGE_PIN $pin \[get_ports {$port}\]"
        puts $fh "set_property IOSTANDARD LVCMOS15 \[get_ports {$port}\]"
    }
    foreach bank $::felix_gt_quads {
        lassign [dict get $::felix_gt_quad_table $bank] site ref nmu nsu
        puts $fh "set_property LOC $site \[get_cells -hierarchical -filter {REF_NAME == GTYP_QUAD && NAME =~ top_i/gt_$bank/*}\]"
    }
    close $fh
    add_files -fileset constrs_1 -norecurse $f
    set_property used_in_synthesis false [get_files $f]
}

proc felix_gt_check_one {name slave want} {
    foreach space {CPM_PCIE_NOC_0 CPM_PCIE_NOC_1} {
        set got ""
        foreach s [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces static_region/aved/cips/$space]] {
            if {[get_bd_addr_segs -quiet -of_objects $s] eq $slave} { set got [get_property OFFSET $s] }
        }
        if {$got ne "" && $got == $want} {
            puts [format "MAP_OK %s registers via %s @ 0x%X" $name $space $want]
        } else {
            incr ::felix_check_errors
            puts [format "ERROR: %s registers via %s at '%s', expected 0x%X" $name $space $got $want]
        }
    }
}

# Quad k at 0x204_0003_0000 + k * 64 KB (PF2 BAR4 + 0x30000 + k * 0x10000), meter at BAR4 + 0x70000,
# board lines at BAR4 + 0x78000.
proc felix_gt_check_addresses {} {
    if {[llength $::felix_gt_quads] == 0} { return }
    felix_gt_check_one refclk_meter [get_bd_addr_segs refclk_meter/s_axi/reg0] 0x20400070000
    felix_gt_check_one board_io [get_bd_addr_segs board_io/s_axi/reg0] 0x20400078000
    set k 0
    foreach bank $::felix_gt_quads {
        felix_gt_check_one gt_$bank [get_bd_addr_segs gt_$bank/quad_if/s_axi/reg0] [expr {0x20400030000 + $k * 0x10000}]
        set slave [get_bd_addr_segs gt_$bank/gtwiz_versal/Quad0_AXI_LITE/Reg]
        set got ""
        foreach s [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces gt_$bank/quad_if/m_axi_gt]] {
            if {[get_bd_addr_segs -quiet -of_objects $s] eq $slave} { set got [get_property OFFSET $s] }
        }
        if {$got ne "" && $got == 0} {
            puts "MAP_OK gt_$bank GT register port at 0 behind quad_if"
        } else {
            incr ::felix_check_errors
            puts "ERROR: gt_$bank GT register port at '$got' behind quad_if, expected 0"
        }
        incr k
    }
}

felix_gt_build
