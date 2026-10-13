proc inject_boot_device_pcie {impl_dir} {
    set bif [file join $impl_dir top_wrapper.bif]
    set pdi [file join $impl_dir top_wrapper.pdi]

    if {![file exists $bif]} {
        return -code error "inject_boot_device_pcie: BIF not found: $bif (run write_device_image first)"
    }

    set fh [open $bif r]; set lines [split [read $fh] "\n"]; close $fh

    foreach l $lines {
        if {[regexp {boot_device\s*\{\s*pcie\s*\}} $l]} {
            puts "INJECT_BOOT_DEVICE: already present in [file tail $bif] -- nothing to do"
            return 0
        }
    }

    set out {}; set in_master 0; set done 0
    foreach l $lines {
        lappend out $l
        if {[string trim $l] eq "bitstream_master:"} { set in_master 1 }
        if {$in_master && !$done && [regexp {^(\s*)id\s*=\s*0x2\s*$} $l -> indent]} {
            lappend out "${indent}boot_device { pcie }"
            set done 1
        }
    }
    if {!$done} {
        return -code error "inject_boot_device_pcie: could not find 'bitstream_master: ... id = 0x2' anchor in $bif -- BIF layout changed, inspect it before trusting the base PDI"
    }

    file copy -force $bif "${bif}.orig"
    set fh [open $bif w]; puts -nonewline $fh [join $out "\n"]; close $fh
    puts "INJECT_BOOT_DEVICE: added 'boot_device { pcie }' to [file tail $bif] (orig saved as [file tail $bif].orig)"

    set cwd [pwd]
    cd $impl_dir
    if {[catch {exec bootgen -arch versal -image top_wrapper.bif -w -o top_wrapper.pdi} msg]} {
        cd $cwd
        return -code error "inject_boot_device_pcie: bootgen failed: $msg"
    }
    cd $cwd

    if {[catch {exec bootgen -arch versal -read $pdi} rd]} {
        puts "INJECT_BOOT_DEVICE: WARNING could not read back $pdi to verify: $rd"
    } elseif {![regexp {boot_device\s*\[pcie\]} $rd]} {
        return -code error "inject_boot_device_pcie: regenerated PDI does NOT report boot_device\[pcie\] -- fix did not take"
    } else {
        puts "INJECT_BOOT_DEVICE: verified boot_device\[pcie\] present in regenerated top_wrapper.pdi"
    }
    return 0
}

if {[info exists impl_dir]} {
    inject_boot_device_pcie $impl_dir
}
