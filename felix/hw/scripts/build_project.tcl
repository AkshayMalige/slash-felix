set here [file dirname [info script]]

add_files -fileset constrs_1 -norecurse [list \
  [file normalize [file join $here .. constraints felix_slash_pinout.xdc]] \
  [file normalize [file join $here .. constraints felix_pblock.xdc]]]

set_property used_in_synthesis false [get_files felix_pblock.xdc]

generate_target all [get_files top.bd]

create_pr_configuration -name config_1 -partitions [list \
  top_i/slash:slash_base_inst_0]
set_property PR_CONFIGURATION config_1 [get_runs impl_1]
set_property strategy {Vivado Advanced Implementation Defaults} [get_runs impl_1]

puts "BUILD_PROJECT_DONE: top=[get_property top [current_fileset]] cfg=[get_property PR_CONFIGURATION [get_runs impl_1]] strategy=[get_property strategy [get_runs impl_1]]"
