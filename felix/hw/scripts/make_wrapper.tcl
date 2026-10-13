add_files -norecurse [make_wrapper -files [get_files top.bd] -top]
update_compile_order -fileset sources_1
set_property top top_wrapper [current_fileset]
puts "MAKE_WRAPPER_DONE: top = [get_property top [current_fileset]]"
