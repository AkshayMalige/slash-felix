set here   [file dirname [file normalize [info script]]]
set repo   [file normalize [file join $here .. .. ..]]
set iprepo [file join $repo linker slashkit resources base common iprepo]

if {[llength [glob -nocomplain -directory [file join $iprepo hbm_bandwidth ip] *]] == 0} {
    error "hbm_bandwidth HLS IP not built. Run first:\n  make -C $iprepo build-hbm_bandwidth"
}

proc felix_build_id {repo} {
    if {[catch {exec git -C $repo rev-parse HEAD} sha]} {
        puts "WARNING: not a git checkout; shell build-ID = 0 (dirty)"
        return [list 0x00000000 0x90000000]
    }
    set v  [expr "0x[string range $sha 0 14]"]
    set lo [expr {$v & 0xFFFFFFFF}]
    set hi [expr {($v >> 32) & 0x0FFFFFFF}]
    # uncommitted: changed, staged or new files (the build takes every rtl/*.v it finds)
    if {[catch {exec git -C $repo status --porcelain --ignore-submodules=dirty} st] || $st ne ""} {
        set hi [expr {$hi | 0x80000000}]
    }
    set hi [expr {$hi | 0x10000000}]
    return [list [format 0x%08x $lo] [format 0x%08x $hi]]
}
lassign [felix_build_id $repo] ::build_id_lo ::build_id_hi
puts "SHELL_BUILD_ID: lo=$::build_id_lo hi=$::build_id_hi"

set ::felix_user_clk_mhz 400
# GT quads in the shell (kernel stream gt_k is the k-th quad) and NoC bandwidth per stream in MB/s
set ::felix_gt_quads {106 110 111 112}
set ::felix_gt_stream_mbps 14000

create_project felix_slash [file join $here .. proj] -part xcvp1552-vsva3340-2MHP-e-S -force
# staged with the shell; build_examples.sh copies it next to every vbin linked against this shell
set fh [open [file join $here .. proj shell_build_id] w]
puts $fh "$::build_id_lo $::build_id_hi"
close $fh
set_property ip_repo_paths $iprepo [current_project]
update_ip_catalog -rebuild
add_files -norecurse [glob [file join $here .. rtl *.v]]
update_compile_order -fileset sources_1
source [file join $here 00_felix_cips_static_region.tcl]
set_property ip_repo_paths $iprepo [current_project]
update_ip_catalog -rebuild
source [file join $here 05_fix_static.tcl]
source [file join $here 20_slash_base.tcl]
source [file join $here 30_integrate.tcl]
source [file join $here make_wrapper.tcl]
source [file join $here build_project.tcl]
puts "=== FELIX SLASH DFX project build complete (compute shell) ==="
