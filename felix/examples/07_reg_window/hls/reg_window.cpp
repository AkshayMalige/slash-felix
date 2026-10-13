#include <ap_int.h>

void reg_window(ap_uint<32> a0, ap_uint<32> a1, ap_uint<32> a2, ap_uint<32> a3, ap_uint<32> a4, ap_uint<32> a5, ap_uint<32> a6, ap_uint<32> a7, ap_uint<32> a8, ap_uint<32> a9, ap_uint<32> a10, ap_uint<32> a11, ap_uint<32> a12, ap_uint<32> a13, ap_uint<32> a14, ap_uint<32> a15, ap_uint<32> a16, ap_uint<32> a17, ap_uint<32> a18, ap_uint<32> a19, ap_uint<32> a20, ap_uint<32> a21, ap_uint<32> a22, ap_uint<32> a23,
                ap_uint<32>& sum) {
#pragma hls interface mode=s_axilite port=a0
#pragma hls interface mode=s_axilite port=a1
#pragma hls interface mode=s_axilite port=a2
#pragma hls interface mode=s_axilite port=a3
#pragma hls interface mode=s_axilite port=a4
#pragma hls interface mode=s_axilite port=a5
#pragma hls interface mode=s_axilite port=a6
#pragma hls interface mode=s_axilite port=a7
#pragma hls interface mode=s_axilite port=a8
#pragma hls interface mode=s_axilite port=a9
#pragma hls interface mode=s_axilite port=a10
#pragma hls interface mode=s_axilite port=a11
#pragma hls interface mode=s_axilite port=a12
#pragma hls interface mode=s_axilite port=a13
#pragma hls interface mode=s_axilite port=a14
#pragma hls interface mode=s_axilite port=a15
#pragma hls interface mode=s_axilite port=a16
#pragma hls interface mode=s_axilite port=a17
#pragma hls interface mode=s_axilite port=a18
#pragma hls interface mode=s_axilite port=a19
#pragma hls interface mode=s_axilite port=a20
#pragma hls interface mode=s_axilite port=a21
#pragma hls interface mode=s_axilite port=a22
#pragma hls interface mode=s_axilite port=a23
#pragma hls interface mode=s_axilite port=sum
#pragma hls interface mode=s_axilite port=return
    sum = a0 * ap_uint<32>(1) +
          a1 * ap_uint<32>(3) +
          a2 * ap_uint<32>(5) +
          a3 * ap_uint<32>(7) +
          a4 * ap_uint<32>(9) +
          a5 * ap_uint<32>(11) +
          a6 * ap_uint<32>(13) +
          a7 * ap_uint<32>(15) +
          a8 * ap_uint<32>(17) +
          a9 * ap_uint<32>(19) +
          a10 * ap_uint<32>(21) +
          a11 * ap_uint<32>(23) +
          a12 * ap_uint<32>(25) +
          a13 * ap_uint<32>(27) +
          a14 * ap_uint<32>(29) +
          a15 * ap_uint<32>(31) +
          a16 * ap_uint<32>(33) +
          a17 * ap_uint<32>(35) +
          a18 * ap_uint<32>(37) +
          a19 * ap_uint<32>(39) +
          a20 * ap_uint<32>(41) +
          a21 * ap_uint<32>(43) +
          a22 * ap_uint<32>(45) +
          a23 * ap_uint<32>(47);
}
