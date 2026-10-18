// Checks the GT RX stream. The RX side never pauses, so the stream first carries whatever the
// lanes received before the generator ran. The checker locks first (lock_beats beats in a row with
// no PRBS error and no all-zero lane, at most 65535), then checks exactly nbeats beats. It always reads
// max_wait + nbeats beats (a fixed loop length lets HLS pipeline it at one beat per clock); if it
// does not lock in that window it returns locked = 0.
// Results per lane: err = recurrence errors (one flipped line bit gives 3), zero = all-zero words.
#include <ap_axi_sdata.h>
#include <ap_int.h>
#include <hls_stream.h>

typedef ap_axiu<512, 0, 0, 0> beat_t;

// PRBS-31 (x^31 + x^28 + 1), 128 bits per lane per clock. Bit i of a word is sent before
// bit i+1, and each lane is one continuous bit stream across words, so the checker works for any
// bit offset the GT receiver lands on.
// Balanced adder tree (a plain loop becomes a 128-deep adder chain).
static ap_uint<8> popcount128(ap_uint<128> x) {
#pragma HLS INLINE
    ap_uint<2> l1[64];
    ap_uint<3> l2[32];
    ap_uint<4> l3[16];
    ap_uint<5> l4[8];
    ap_uint<6> l5[4];
    ap_uint<7> l6[2];
    for (int i = 0; i < 64; i++) l1[i] = ap_uint<2>(x[2 * i]) + ap_uint<2>(x[2 * i + 1]);
    for (int i = 0; i < 32; i++) l2[i] = ap_uint<3>(l1[2 * i]) + l1[2 * i + 1];
    for (int i = 0; i < 16; i++) l3[i] = ap_uint<4>(l2[2 * i]) + l2[2 * i + 1];
    for (int i = 0; i < 8; i++) l4[i] = ap_uint<5>(l3[2 * i]) + l3[2 * i + 1];
    for (int i = 0; i < 4; i++) l5[i] = ap_uint<6>(l4[2 * i]) + l4[2 * i + 1];
    for (int i = 0; i < 2; i++) l6[i] = ap_uint<7>(l5[2 * i]) + l5[2 * i + 1];
    return ap_uint<8>(l6[0]) + l6[1];
}

// Received bits that break the recurrence (bit i set = error at bit i). One flipped bit on the
// line breaks it three times (at the bit itself and 28 and 31 bits later). prev holds the last
// 31 bits received.
static ap_uint<128> prbs31_errors(ap_uint<31> &prev, ap_uint<128> r) {
#pragma HLS INLINE
    ap_uint<128> e;
    for (int i = 0; i < 128; i++) {
#pragma HLS UNROLL
        ap_uint<1> a = (i < 31) ? prev[i] : r[i - 31];
        ap_uint<1> b = (i < 28) ? prev[i + 3] : r[i - 28];
        e[i] = r[i] ^ a ^ b;
    }
    prev = r.range(127, 97);
    return e;
}

void gt_prbs_check(hls::stream<beat_t> &axis_in, ap_uint<64> nbeats, ap_uint<32> lock_beats,
                   ap_uint<64> max_wait, ap_uint<32> &locked, ap_uint<64> &wait_beats, ap_uint<64> &beats,
                   ap_uint<64> &err0, ap_uint<64> &err1, ap_uint<64> &err2, ap_uint<64> &err3,
                   ap_uint<64> &zero0, ap_uint<64> &zero1, ap_uint<64> &zero2, ap_uint<64> &zero3) {
#pragma HLS INTERFACE mode=axis port=axis_in
#pragma HLS INTERFACE mode=s_axilite port=nbeats
#pragma HLS INTERFACE mode=s_axilite port=lock_beats
#pragma HLS INTERFACE mode=s_axilite port=max_wait
#pragma HLS INTERFACE mode=s_axilite port=locked
#pragma HLS INTERFACE mode=s_axilite port=wait_beats
#pragma HLS INTERFACE mode=s_axilite port=beats
#pragma HLS INTERFACE mode=s_axilite port=err0
#pragma HLS INTERFACE mode=s_axilite port=err1
#pragma HLS INTERFACE mode=s_axilite port=err2
#pragma HLS INTERFACE mode=s_axilite port=err3
#pragma HLS INTERFACE mode=s_axilite port=zero0
#pragma HLS INTERFACE mode=s_axilite port=zero1
#pragma HLS INTERFACE mode=s_axilite port=zero2
#pragma HLS INTERFACE mode=s_axilite port=zero3
#pragma HLS INTERFACE mode=s_axilite port=return

    ap_uint<31> prev[4] = {0, 0, 0, 0};
    ap_uint<64> err[4] = {0, 0, 0, 0};
    ap_uint<64> zero[4] = {0, 0, 0, 0};
#pragma HLS ARRAY_PARTITION variable=prev type=complete
#pragma HLS ARRAY_PARTITION variable=err type=complete
#pragma HLS ARRAY_PARTITION variable=zero type=complete

    bool lk = false;
    bool counting = nbeats != 0;
    ap_uint<16> streak = 0;
    ap_uint<64> waited = 0;
    ap_uint<64> counted = 0;

    const ap_uint<64> total = max_wait + nbeats;
    const ap_uint<64> last = nbeats - 1;
    const ap_uint<16> lock_at = lock_beats > 0xFFFF ? ap_uint<16>(0xFFFF) : ap_uint<16>(lock_beats);
    for (ap_uint<64> n = 0; n < total; n++) {
#pragma HLS PIPELINE II=1
        beat_t b = axis_in.read();
        bool clean = true;
        ap_uint<8> pc[4];
        bool z[4];
        for (int l = 0; l < 4; l++) {
#pragma HLS UNROLL
            ap_uint<128> r = b.data.range(128 * l + 127, 128 * l);
            ap_uint<128> e = prbs31_errors(prev[l], r);
            z[l] = (r == 0);
            pc[l] = popcount128(e);
            if (e != 0 || z[l])
                clean = false;
        }
        if (!lk) {
            waited++;
            streak = clean ? ap_uint<16>(streak + 1) : ap_uint<16>(0);
            if (streak == lock_at)
                lk = true;
        } else if (counting) {
            if (counted == last)
                counting = false;
            counted++;
            for (int l = 0; l < 4; l++) {
#pragma HLS UNROLL
                err[l] += pc[l];
                zero[l] += z[l];
            }
        }
    }

    locked = lk;
    wait_beats = waited;
    beats = counted;
    err0 = err[0];
    err1 = err[1];
    err2 = err[2];
    err3 = err[3];
    zero0 = zero[0];
    zero1 = zero[1];
    zero2 = zero[2];
    zero3 = zero[3];
}
