#include <ap_int.h>
#include <stdint.h>

#define DATA_WIDTH 512
typedef ap_uint<DATA_WIDTH> uint512_t;

extern "C" void mem_bw(ap_uint<32> mode, ap_uint<32> size, uint512_t* gmem0) {
#pragma HLS INTERFACE m_axi port=gmem0 offset=slave bundle=gmem0 \
    max_read_burst_length=64 max_write_burst_length=64
#pragma HLS INTERFACE s_axilite port=gmem0  bundle=control
#pragma HLS INTERFACE s_axilite port=mode   bundle=control
#pragma HLS INTERFACE s_axilite port=size   bundle=control
#pragma HLS INTERFACE s_axilite port=return bundle=control

    if (mode == 0) {
    write_loop:
        for (uint32_t i = 0; i < size; i++) {
#pragma HLS PIPELINE II=1
            uint512_t v = 0;
            v.range(31, 0) = i;
            gmem0[i] = v;
        }
    } else {
        uint512_t acc = 0;
    read_loop:
        for (uint32_t i = 0; i < size; i++) {
#pragma HLS PIPELINE II=1
            acc ^= gmem0[i];
        }
        gmem0[0] = acc;
    }
}
