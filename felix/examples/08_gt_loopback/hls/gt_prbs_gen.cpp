// Sends nbeats beats of PRBS-31 on the GT TX stream: 4 lanes x 128 bits per 512-bit beat
// (lane L = bits [128L+127:128L]), one independent sequence per lane. If inject_at < nbeats,
// bit 0 of lane inject_lane is flipped in that beat, so the checker must report it.
#include <ap_axi_sdata.h>
#include <ap_int.h>
#include <hls_stream.h>

typedef ap_axiu<512, 0, 0, 0> beat_t;

// PRBS-31 (x^31 + x^28 + 1), 128 bits per lane per clock. Bit i of a word is sent before
// bit i+1, and each lane is one continuous bit stream across words, so the checker works for any
// bit offset the GT receiver lands on.
// Next 128 bits of the sequence. state[j] holds the last 31 bits sent, state[30] the newest.
static ap_uint<128> prbs31_word(ap_uint<31> &state) {
#pragma HLS INLINE
    ap_uint<128> w = 0;
    for (int i = 0; i < 128; i++) {
#pragma HLS UNROLL
        ap_uint<1> a = (i < 31) ? state[i] : w[i - 31];
        ap_uint<1> b = (i < 28) ? state[i + 3] : w[i - 28];
        w[i] = a ^ b;
    }
    state = w.range(127, 97);
    return w;
}

void gt_prbs_gen(hls::stream<beat_t> &axis_out, ap_uint<64> nbeats, ap_uint<64> inject_at,
                 ap_uint<32> inject_lane) {
#pragma HLS INTERFACE mode=axis port=axis_out
#pragma HLS INTERFACE mode=s_axilite port=nbeats
#pragma HLS INTERFACE mode=s_axilite port=inject_at
#pragma HLS INTERFACE mode=s_axilite port=inject_lane
#pragma HLS INTERFACE mode=s_axilite port=return

    ap_uint<31> state[4] = {0x00000001, 0x2468ACE1, 0x13579BDF, 0x7FFF0001};
#pragma HLS ARRAY_PARTITION variable=state type=complete

    for (ap_uint<64> n = 0; n < nbeats; n++) {
#pragma HLS PIPELINE II=1
        beat_t b;
        for (int l = 0; l < 4; l++) {
#pragma HLS UNROLL
            ap_uint<128> w = prbs31_word(state[l]);
            if (n == inject_at && inject_lane == l)
                w[0] = ~w[0];
            b.data.range(128 * l + 127, 128 * l) = w;
        }
        b.keep = -1;
        b.strb = -1;
        b.last = 1;
        axis_out.write(b);
    }
}
