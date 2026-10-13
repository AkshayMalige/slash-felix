set here [file dirname [info script]]
open_project [file join $here .. proj felix_slash.xpr]

if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    launch_runs synth_1 -jobs 8
    wait_on_run synth_1
} else {
    puts "STAGE 1: synth_1 already complete -- reusing"
}

if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    launch_runs impl_1 -jobs 8
    wait_on_run impl_1
} else {
    puts "STAGE 2: impl_1 already complete -- reusing"
}

launch_runs impl_1 -to_step write_device_image -jobs 8
wait_on_run impl_1
open_run impl_1
set _od [get_property DIRECTORY [get_runs impl_1]]

source [file join $here inject_boot_device_pcie.tcl]
inject_boot_device_pcie $_od

write_abstract_shell -cell top_i/slash -force [file join $_od static_shell_slash.dcp]
report_timing_summary -delay_type min_max -max_paths 1 -file [file join $_od report_timing_summary_static.txt]

write_hw_platform -fixed -include_bit -force [file join $_od felix_slash.xsa]

update_design -black_box -cell top_i/slash
write_checkpoint -force [file join $_od top_wrapper_routed_bb.dcp]

puts "RUN_IMPL_DONE"
puts "  device image (.pdi), abstract shell, XSA, routed_bb.dcp in: $_od"
