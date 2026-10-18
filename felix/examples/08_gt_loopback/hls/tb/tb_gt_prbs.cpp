// C simulation: generator -> model of the GT receiver -> checker.
// The model puts zero words and random bits in front of each lane (what the RX stream carries
// before the generator runs) and starts each lane at a different bit offset, as the GT receiver
// lands on an arbitrary bit. Expected: lock, 3 error bits for the one injected flip, nothing else.
#include <ap_axi_sdata.h>
#include <ap_int.h>
#include <hls_stream.h>
#include <cstdio>
#include <cstdlib>
#include <vector>

typedef ap_axiu<512, 0, 0, 0> beat_t;

void gt_prbs_gen(hls::stream<beat_t> &axis_out, ap_uint<64> nbeats, ap_uint<64> inject_at,
                 ap_uint<32> inject_lane);
void gt_prbs_check(hls::stream<beat_t> &axis_in, ap_uint<64> nbeats, ap_uint<32> lock_beats,
                   ap_uint<64> max_wait, ap_uint<32> &locked, ap_uint<64> &wait_beats, ap_uint<64> &beats,
                   ap_uint<64> &err0, ap_uint<64> &err1, ap_uint<64> &err2, ap_uint<64> &err3,
                   ap_uint<64> &zero0, ap_uint<64> &zero1, ap_uint<64> &zero2, ap_uint<64> &zero3);

struct Result {
    unsigned locked;
    unsigned long long wait, beats, err[4], zero[4];
};

static Result run_check(hls::stream<beat_t> &s, unsigned long long n, unsigned long long max_wait) {
    ap_uint<32> lk;
    ap_uint<64> w, b, e0, e1, e2, e3, z0, z1, z2, z3;
    gt_prbs_check(s, n, 64, max_wait, lk, w, b, e0, e1, e2, e3, z0, z1, z2, z3);
    Result r{(unsigned)lk, (unsigned long long)w, (unsigned long long)b,
             {(unsigned long long)e0, (unsigned long long)e1, (unsigned long long)e2, (unsigned long long)e3},
             {(unsigned long long)z0, (unsigned long long)z1, (unsigned long long)z2, (unsigned long long)z3}};
    return r;
}

int main() {
    const int GEN = 6000, N = 5000, INJECT_AT = 1000, INJECT_LANE = 3;
    const int slip[4] = {0, 7, 33, 100};
    const int junk_bits[4] = {300, 4000, 1000, 2500};
    const int zero_words = 20;
    int fails = 0;

    hls::stream<beat_t> g;
    gt_prbs_gen(g, GEN, INJECT_AT, INJECT_LANE);

    std::vector<std::vector<int>> lane(4);
    std::vector<beat_t> beats_in;
    while (!g.empty()) beats_in.push_back(g.read());
    srand(1);
    for (int l = 0; l < 4; l++) {
        for (int i = 0; i < zero_words * 128; i++) lane[l].push_back(0);
        for (int i = 0; i < junk_bits[l]; i++) lane[l].push_back(rand() & 1);
        int skip = slip[l];
        for (auto &b : beats_in)
            for (int i = 0; i < 128; i++) {
                if (skip > 0) { skip--; continue; }
                lane[l].push_back((int)b.data[128 * l + i]);
            }
    }
    size_t nwords = lane[0].size() / 128;
    for (int l = 1; l < 4; l++) nwords = std::min(nwords, lane[l].size() / 128);

    hls::stream<beat_t> rx;
    for (size_t k = 0; k < nwords; k++) {
        beat_t b;
        for (int l = 0; l < 4; l++)
            for (int i = 0; i < 128; i++) b.data[128 * l + i] = lane[l][128 * k + i];
        b.keep = -1; b.strb = -1; b.last = 1;
        rx.write(b);
    }
    Result r = run_check(rx, N, 500);
    printf("run 1: locked %u after %llu beats, checked %llu, err %llu %llu %llu %llu, zero %llu %llu %llu %llu\n",
           r.locked, r.wait, r.beats, r.err[0], r.err[1], r.err[2], r.err[3], r.zero[0], r.zero[1], r.zero[2],
           r.zero[3]);
    if (!r.locked || r.beats != (unsigned long long)N) fails++;
    for (int l = 0; l < 4; l++) {
        unsigned long long want = (l == INJECT_LANE) ? 3 : 0;
        if (r.err[l] != want || r.zero[l] != 0) fails++;
    }

    hls::stream<beat_t> zeros;
    for (int k = 0; k < 2000; k++) {
        beat_t b;
        b.data = 0; b.keep = -1; b.strb = -1; b.last = 1;
        zeros.write(b);
    }
    Result z = run_check(zeros, 500, 1000);
    printf("run 2 (all zero input): locked %u, read %llu beats without lock\n", z.locked, z.wait);
    if (z.locked || z.wait != 1500 || z.beats != 0) fails++;

    printf("CSIM_RESULT: %s\n", fails ? "FAIL" : "PASS");
    return fails ? 1 : 0;
}
