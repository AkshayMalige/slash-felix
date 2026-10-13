#include <ap_int.h>

void clk_count(ap_uint<32> cycles, ap_uint<32>& out) {
#pragma hls interface mode=s_axilite port=cycles
#pragma hls interface mode=s_axilite port=out
#pragma hls interface mode=s_axilite port=return
    ap_uint<32> acc = 0;
    for (ap_uint<32> i = 0; i < cycles; i++) {
#pragma hls pipeline II=1
        acc = (acc >> 1) ^ ap_uint<32>(i);
    }
    out = acc;
}
