#include <ap_int.h>

void mem_bw(ap_uint<32> mode, ap_uint<32> size, ap_uint<512>* gmem0) {
#pragma HLS interface mode=s_axilite port=mode
#pragma HLS interface mode=s_axilite port=size
#pragma HLS interface m_axi bundle=gmem0 port=gmem0 \
    num_read_outstanding=32 num_write_outstanding=32 \
    max_read_burst_length=64 max_write_burst_length=64
#pragma HLS interface mode=s_axilite port=return

    if (mode == 0) {
        ap_uint<512> acc = 0;
    read_loop:
        for (ap_uint<32> i = 0; i < size; i++) {
#pragma HLS pipeline II=1
            acc ^= gmem0[i];
        }
        gmem0[0] = acc;
    } else {
    write_loop:
        for (ap_uint<32> i = 0; i < size; i++) {
#pragma HLS pipeline II=1
            ap_uint<512> v = 0;
            v(31, 0) = i;
            gmem0[i] = v;
        }
    }
}
