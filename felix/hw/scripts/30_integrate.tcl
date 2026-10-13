current_bd_design [get_bd_designs top]
set ::felix_check_errors 0

foreach p {M04_INI_0 M05_INI_0 S00_INI_1 S00_INI_3 S00_INI_4 S00_INI_5 S00_INI_6 S00_INI_7 M00_INI_0 M00_INI_1 M00_INI_2 M00_INI_3 M00_INI_4} {
    catch {delete_bd_objs [get_bd_intf_ports $p]}
}

delete_bd_objs [get_bd_cells static_region/virt_noc]
foreach p {S00_INI1 S00_INI2 S00_INI3 S00_INI4 S00_INI5 M00_INI M00_INI1 M00_INI2 M00_INI3 M00_INI4} {
    catch {delete_bd_objs [get_bd_intf_pins static_region/$p]}
}

current_bd_instance /static_region/noc
for {set i 4} {$i <= 11} {incr i} {
    set p [format S%02d_INI $i]
    connect_bd_intf_net [get_bd_intf_pins axi_noc_cips/$p] \
        [create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:inimm_rtl:1.0 ${p}_0]
}

current_bd_instance /static_region
for {set i 0} {$i <= 19} {incr i} {
    set p [format S%02d_INI_0 $i]
    connect_bd_intf_net [get_bd_intf_pins noc/$p] \
        [create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:inimm_rtl:1.0 $p]
}
current_bd_instance /

create_bd_cell -type container -reference slash_base slash

connect_bd_intf_net [get_bd_intf_pins static_region/M04_INI_0] [get_bd_intf_pins slash/S_AXILITE_INI]
for {set i 0} {$i <= 3} {incr i} {
    connect_bd_intf_net [get_bd_intf_pins slash/[format M%02d_INI $i]] \
        [get_bd_intf_pins static_region/[format S%02d_INI_0 $i]]
}
for {set i 0} {$i <= 7} {incr i} {
    connect_bd_intf_net [get_bd_intf_pins slash/[format HBM_VNOC_INI_%02d $i]] \
        [get_bd_intf_pins static_region/[format S%02d_INI_0 [expr {$i + 4}]]]
}
for {set i 4} {$i <= 11} {incr i} {
    connect_bd_intf_net [get_bd_intf_pins slash/[format M%02d_INI $i]] \
        [get_bd_intf_pins static_region/[format S%02d_INI_0 [expr {$i + 8}]]]
}
connect_bd_intf_net [get_bd_intf_pins slash/QDMA_SLAVE_BRIDGE_0] [get_bd_intf_pins static_region/S00_INI6]
set_property APERTURES {{0x202_0000_0000 128M}} [get_bd_intf_pins slash/S_AXILITE_INI]

connect_bd_net [get_bd_pins static_region/clk_out3]            [get_bd_pins slash/user_clk]
connect_bd_net [get_bd_pins static_region/peripheral_aresetn2] [get_bd_pins slash/arstn]

foreach p {resetn_pl_periph_0 eos_0 clk_out1_0 clk_out1_1 clk_out1_2 Q_0 Q_1 pl3_resetn_0 pl3_ref_clk_0} {
    catch {delete_bd_objs [get_bd_ports $p]}
}

for {set i 0} {$i <= 19} {incr i} {
    set_property -dict [list CONFIG.CONNECTIONS {M01_INI {read_bw {100} write_bw {100}}}] \
        [get_bd_intf_pins static_region/noc/axi_noc_cips/[format S%02d_INI $i]]
}
foreach pin {S00_INI S01_INI} {
    set_property -dict [list CONFIG.CONNECTIONS {M01_INI {read_bw {2500} write_bw {2500}}}] \
        [get_bd_intf_pins static_region/noc/axi_noc_cips/$pin]
}
foreach pin {S20_INI S21_INI S22_INI S23_INI} {
    set_property -dict [list CONFIG.CONNECTIONS {}] [get_bd_intf_pins static_region/noc/axi_noc_cips/$pin]
}

set_property -dict [list CONFIG.CONNECTIONS {M02_INI {read_bw {500} write_bw {500} initial_boot {true}} M01_INI {read_bw {500} write_bw {500} initial_boot {true}} M06_INI {read_bw {500} write_bw {500} initial_boot {true}} M01_AXI {read_bw {500} write_bw {500} read_avg_burst {4} write_avg_burst {4} initial_boot {true}} M04_INI {read_bw {500} write_bw {500} initial_boot {true}} M05_INI {read_bw {500} write_bw {500} initial_boot {true}} M00_AXI {read_bw {5} write_bw {5}} M00_INI {read_bw {5000} write_bw {5000} initial_boot {false}}}] \
    [get_bd_intf_pins static_region/noc/axi_noc_cips/S00_AXI]
set_property -dict [list CONFIG.CONNECTIONS {M01_INI {read_bw {500} write_bw {500} initial_boot {true}} M06_INI {read_bw {500} write_bw {500} initial_boot {true}} M01_AXI {read_bw {500} write_bw {500} read_avg_burst {4} write_avg_burst {4} initial_boot {true}} M03_INI {read_bw {500} write_bw {500} initial_boot {true}} M04_INI {read_bw {500} write_bw {500} initial_boot {true}} M05_INI {read_bw {500} write_bw {500} initial_boot {true}} M00_AXI {read_bw {5} write_bw {5}} M00_INI {read_bw {500} write_bw {500} initial_boot {true}}}] \
    [get_bd_intf_pins static_region/noc/axi_noc_cips/S01_AXI]
set_property -dict [list CONFIG.CATEGORY {ps_rpu}] \
    [get_bd_intf_pins static_region/noc/axi_noc_cips/S03_AXI]

set_property -dict [list \
  CONFIG.REMAPS {M01_INI {{0x20108000000 0x00038000000 0x08000000} {0x60000000000 0x60000000000 0x400000000}}} \
] [get_bd_intf_pins static_region/noc/axi_noc_cips/S00_AXI]

save_bd_design
puts "TOP_CELLS: [get_bd_cells /*]"
assign_bd_address
puts "ASSIGN_DONE"

proc pin_seg {space segpat off rng} {
    set sp [get_bd_addr_spaces $space]
    foreach seg [get_bd_addr_segs -quiet -of_objects $sp -filter "NAME =~ $segpat"] {
        if {[catch {assign_bd_address -target_address_space $sp -offset $off -range $rng $seg -force} e]} {
            puts "PIN_WARN $space $segpat: $e"
        } else {
            puts "PIN_OK $segpat -> [get_property OFFSET $seg]"
        }
    }
}
foreach space {static_region/aved/cips/CPM_PCIE_NOC_0 static_region/aved/cips/CPM_PCIE_NOC_1} {
    pin_seg $space *hw_discovery*       0x0000020101000000 0x1000
    pin_seg $space *uuid_rom*           0x0000020101001000 0x1000
    pin_seg $space *gcq_m2r_S00*        0x0000020101010000 0x10000
    pin_seg $space *pdi_reset_gpio*     0x0000020101040000 0x10000
    pin_seg $space *clk_wizard_slash*   0x0000020400000000 0x10000
    pin_seg $space *clk_wizard_service* 0x0000020400010000 0x10000
    pin_seg $space *build_id_gpio*      0x0000020400020000 0x10000
}

set ddr_ch2 [get_bd_addr_segs static_region/noc/axi_noc_mc_ddr4_0/S01_INI/C0_DDR_CH2]
set sp0 [get_bd_addr_spaces static_region/aved/cips/CPM_PCIE_NOC_0]
foreach s [get_bd_addr_segs -quiet -excluded -of_objects $sp0 -filter {NAME =~ *C0_DDR_CH2*}] { delete_bd_objs $s }
if {[llength [get_bd_addr_segs -quiet -of_objects $sp0 -filter {NAME =~ *C0_DDR_CH2*}]] == 0} {
    assign_bd_address -target_address_space $sp0 -offset 0x0000060000000000 -range 0x380000000 $ddr_ch2 -force
    puts "PIN_OK C0_DDR_CH2 (14G, via identity REMAP) added to CPM_PCIE_NOC_0"
}

foreach space {static_region/aved/cips/PMC_NOC_AXI_0 static_region/aved/cips/LPD_AXI_NOC_0} {
    if {[llength [get_bd_addr_spaces -quiet $space]] == 0} {
        puts "PIN_WARN: address space $space not found -- PS-side DDR NOT mapped."
        continue
    }
    pin_seg $space *C0_DDR_LOW0* 0x00000000 0x80000000
}
puts "PIN_DONE"

foreach space {static_region/aved/cips/PMC_NOC_AXI_0 static_region/aved/cips/LPD_AXI_NOC_0} {
    set sp [get_bd_addr_spaces -quiet $space]
    if {[llength $sp] == 0} {
        incr ::felix_check_errors; puts "ERROR: address space $space does not exist. The AMC will not load (PLM stall)."
        continue
    }
    set low [get_bd_addr_segs -quiet -of_objects $sp -filter {NAME =~ *C0_DDR_LOW0*}]
    if {[llength $low] == 0} {
        incr ::felix_check_errors; puts "ERROR: $space has NO C0_DDR_LOW0 segment. The AMC will not load (PLM stall)."
        continue
    }
    set off [get_property OFFSET [lindex $low 0]]
    set rng [get_property RANGE  [lindex $low 0]]
    if {$off <= 0x40000000 && ($off + $rng) >= 0x41501000} {
        puts [format "DDR_OK %s C0_DDR_LOW0 @ 0x%llx range 0x%llx (covers amc.elf 0x40000000)" \
              $space $off $rng]
    } else {
        incr ::felix_check_errors; puts [format "ERROR: %s C0_DDR_LOW0 @ 0x%llx range 0x%llx does NOT cover amc.elf's 0x40000000 load." \
              $space $off $rng]
    }
}

foreach {segpat want} {
    *hw_discovery*       0x20101000000
    *gcq_m2r_S00*        0x20101010000
    *pdi_reset_gpio*     0x20101040000
    *clk_wizard_slash*   0x20400000000
    *clk_wizard_service* 0x20400010000
    *build_id_gpio*      0x20400020000
} {
    set sp  [get_bd_addr_spaces static_region/aved/cips/CPM_PCIE_NOC_0]
    set seg [get_bd_addr_segs -quiet -of_objects $sp -filter "NAME =~ $segpat"]
    if {[llength $seg] == 0} {
        incr ::felix_check_errors; puts "ERROR: no $segpat segment in CPM_PCIE_NOC_0 (expected @ $want)"
    } elseif {[get_property OFFSET [lindex $seg 0]] != $want} {
        incr ::felix_check_errors; puts "ERROR: $segpat @ [get_property OFFSET [lindex $seg 0]], expected $want"
    } else {
        puts "MAP_OK $segpat @ $want"
    }
}
foreach space {CPM_PCIE_NOC_0 CPM_PCIE_NOC_1} {
    set sp  [get_bd_addr_spaces static_region/aved/cips/$space]
    set seg [get_bd_addr_segs -quiet -of_objects $sp -filter {NAME =~ *C0_DDR_CH2*}]
    if {[llength $seg] == 0 || [get_property OFFSET [lindex $seg 0]] != 0x60000000000 ||
        [get_property RANGE [lindex $seg 0]] != 0x380000000} {
        incr ::felix_check_errors; puts "ERROR: $space does not reach exactly the 14 GB of card DDR at 0x600_0000_0000 (QDMA MM channel [string index $space end]): [get_property RANGE [lindex $seg 0]]"
    } else {
        puts "MAP_OK DDR via $space @ 0x60000000000 range [get_property RANGE [lindex $seg 0]]"
    }
}

set remaps [get_property CONFIG.REMAPS [get_bd_intf_pins static_region/noc/axi_noc_cips/S00_AXI]]
if {[string first {0x20108000000 0x00038000000 0x08000000} $remaps] < 0 ||
    [string first {0x60000000000 0x60000000000 0x400000000} $remaps] < 0} {
    incr ::felix_check_errors; puts "ERROR: S00_AXI REMAPS lost an entry (GCQ payload window and/or DDR identity window): $remaps"
} else {
    puts "MAP_OK S00_AXI REMAPS = $remaps"
}

if {$::felix_check_errors > 0} {
    error "30_integrate: $::felix_check_errors build-time check(s) failed -- see the ERROR lines above"
}

validate_bd_design
puts "INTEGRATE_VALIDATE_DONE"

set_property -dict [list CONFIG.ENABLE_DFX {true}]     [get_bd_cells slash]
set_property -dict [list CONFIG.LOCK_PROPAGATE {true}] [get_bd_cells slash]
save_bd_design
validate_bd_design
puts "DFX_VALIDATE_DONE"

set outdir [file dirname [info script]]
current_bd_design [get_bd_designs slash_base]
write_bd_tcl -force [file join $outdir export_slash_base.tcl]
current_bd_design [get_bd_designs top]
write_bd_tcl -force [file join $outdir export_top.tcl]
puts "EXPORT_DONE"
