create_pblock pblock_slash
add_cells_to_pblock [get_pblocks pblock_slash] [get_cells -quiet [list top_i/slash]]
resize_pblock [get_pblocks pblock_slash] -add {CLOCKREGION_X2Y5:CLOCKREGION_X9Y5}
resize_pblock [get_pblocks pblock_slash] -add {CLOCKREGION_X1Y6:CLOCKREGION_X9Y7}
resize_pblock [get_pblocks pblock_slash] -add {CLOCKREGION_X3Y1:CLOCKREGION_X9Y2}
resize_pblock [get_pblocks pblock_slash] -add {CLOCKREGION_X4Y3:CLOCKREGION_X9Y4}
set_property SNAPPING_MODE ON [get_pblocks pblock_slash]
set_property IS_SOFT FALSE [get_pblocks pblock_slash]
