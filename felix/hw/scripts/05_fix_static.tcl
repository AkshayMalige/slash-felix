current_bd_design [get_bd_designs top]

set_property -dict [list \
  CONFIG.C_CAP_BASE_ADDR {0x600} \
  CONFIG.C_INJECT_ENDPOINTS {0} \
  CONFIG.C_MANUAL {1} \
  CONFIG.C_NEXT_CAP_ADDR {0x000} \
  CONFIG.C_NUM_PFS {1} \
  CONFIG.C_PF0_BAR_INDEX {0} \
  CONFIG.C_PF0_ENDPOINT_NAMES {0} \
  CONFIG.C_PF0_ENTRY_ADDR_0 {0x000001001000} \
  CONFIG.C_PF0_ENTRY_ADDR_1 {0x000001010000} \
  CONFIG.C_PF0_ENTRY_ADDR_2 {0x000008000000} \
  CONFIG.C_PF0_ENTRY_BAR_0 {0} \
  CONFIG.C_PF0_ENTRY_BAR_1 {0} \
  CONFIG.C_PF0_ENTRY_BAR_2 {0} \
  CONFIG.C_PF0_ENTRY_MAJOR_VERSION_0 {1} \
  CONFIG.C_PF0_ENTRY_MAJOR_VERSION_1 {1} \
  CONFIG.C_PF0_ENTRY_MAJOR_VERSION_2 {1} \
  CONFIG.C_PF0_ENTRY_MINOR_VERSION_0 {0} \
  CONFIG.C_PF0_ENTRY_MINOR_VERSION_1 {2} \
  CONFIG.C_PF0_ENTRY_MINOR_VERSION_2 {0} \
  CONFIG.C_PF0_ENTRY_RSVD0_0 {0x0} \
  CONFIG.C_PF0_ENTRY_RSVD0_1 {0x0} \
  CONFIG.C_PF0_ENTRY_RSVD0_2 {0x0} \
  CONFIG.C_PF0_ENTRY_TYPE_0 {0x50} \
  CONFIG.C_PF0_ENTRY_TYPE_1 {0x54} \
  CONFIG.C_PF0_ENTRY_TYPE_2 {0x55} \
  CONFIG.C_PF0_ENTRY_VERSION_TYPE_0 {0x01} \
  CONFIG.C_PF0_ENTRY_VERSION_TYPE_1 {0x01} \
  CONFIG.C_PF0_ENTRY_VERSION_TYPE_2 {0x01} \
  CONFIG.C_PF0_HIGH_OFFSET {0x00000000} \
  CONFIG.C_PF0_LOW_OFFSET {0x0100000} \
  CONFIG.C_PF0_NUM_SLOTS_BAR_LAYOUT_TABLE {3} \
  CONFIG.C_PF0_S_AXI_ADDR_WIDTH {32} \
] [get_bd_cells static_region/aved/base_logic/hw_discovery]

set_property CONFIG.MC_INIT_MEM_USING_ECC_SCRUB {true} \
  [get_bd_cells static_region/noc/axi_noc_mc_ddr4_0]

set_property CONFIG.NUM_MCP {1} [get_bd_cells static_region/noc/axi_noc_mc_ddr4_0]
set_property -dict [list CONFIG.CONNECTIONS {}] \
  [get_bd_intf_pins static_region/noc/axi_noc_mc_ddr4_0/S00_INI]
set_property -dict [list CONFIG.CONNECTIONS \
  {MC_0 {read_bw {800} write_bw {800} read_avg_burst {4} write_avg_burst {4} initial_boot {true}}}] \
  [get_bd_intf_pins static_region/noc/axi_noc_mc_ddr4_0/S01_INI]
set_property CONFIG.MC_CHAN_REGION1 {DDR_CH2} [get_bd_cells static_region/noc/axi_noc_mc_ddr4_0]

set_property -dict [list CONFIG.CONNECTIONS \
  {M02_INI {read_bw {500} write_bw {500} initial_boot {true}} \
   M01_INI {read_bw {500} write_bw {500} initial_boot {true}}}] \
  [get_bd_intf_pins static_region/noc/axi_noc_cips/S02_AXI]
set_property -dict [list CONFIG.CONNECTIONS \
  {M01_INI {read_bw {500} write_bw {500} initial_boot {true}}}] \
  [get_bd_intf_pins static_region/noc/axi_noc_cips/S03_AXI]

puts "FIX_STATIC_DONE"
