// GT streams of the shell (one per quad, 4 lanes each) checked end to end, in near-end PMA loopback
// inside the chip (default) or over cables (--external), all quads at once:
//   1. reference clock inputs (meter), FireFly modules, and per quad: clocks, power good, reset done
//   2. the GT's own PRBS-31 on every lane: lock (the RX polarity of each lane is found here and kept
//      for step 3), no errors in 1 s, and a forced TX error on lane 0 of every quad is counted
//   3. kernel path: gt_prbs_gen_k -> NoC -> quad k TX -> GT -> loopback -> RX -> NoC -> gt_prbs_check_k,
//      once with one flipped bit per quad (3 error bits each), then a long run that must be error
//      free (default 40 s, about 1e12 bits per lane)
// --park: only loads the image, holds every quad and starts the generators, then ends with them
// running against the held TX adapters (data on the TX side only). The next kernel load must work.
#include "../../tools/gt_link/gt_regs.hpp"

#include <vrt/device.hpp>
#include <vrt/kernel.hpp>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <memory>
#include <string>
#include <vector>

using namespace felix_gt;

namespace {

constexpr double BEATS_PER_S = 25.78125e9 / 128;  // one 512-bit beat = 128 bits per lane

// The generator and checker kernels of one quad.
struct Pair {
    std::unique_ptr<vrt::Kernel> gen, chk;
};

// On exit the streams must be held and the RX paths empty: a later kernel load fails while RX data
// wait in the NoC at the kernel region's entry, and a checker stops reading before its stream
// stops. Each idle checker is started once more and keeps reading while the adapters are held, so
// the NoC path drains into it; it then waits for data until the next kernel load replaces it.
struct StopStreams {
    std::vector<Quad> quads;
    std::vector<Pair> *pairs;
    bool active = true;
    ~StopStreams() {
        if (!active) return;
        try {
            bool draining = false;
            for (auto &p : *pairs) {
                if (p.chk->read(0x00) & 0x4) {  // ap_idle
                    p.chk->setArg("nbeats", ~uint64_t{0} >> 1);
                    p.chk->setArg("lock_beats", 64u);
                    p.chk->setArg("max_wait", uint64_t{0});
                    p.chk->start();
                    draining = true;
                }
            }
            if (draining) sleep_ms(20);
            for (const auto &q : quads) q.write(CTRL, CTRL_HOLD);
            if (draining) sleep_ms(20);
            for (const auto &q : quads) q.write(LOOPBACK, 0);
        } catch (const std::exception &e) {
            std::fprintf(stderr, "08_gt_loopback: stopping the streams failed: %s\n", e.what());
        }
    }
};

// A 64-bit kernel result register (low word at off, high word at off + 4).
uint64_t read64(vrt::Kernel &k, uint32_t off) {
    return static_cast<uint64_t>(k.read(off)) | (static_cast<uint64_t>(k.read(off + 4)) << 32);
}

// Checker results of one run, per quad.
struct CheckResult {
    bool locked;
    uint64_t wait, beats, err[4], zero[4];
};

// One run of all generator/checker pairs at once: n counted beats each; inject_at = beat with one
// flipped bit on inject_lane (or none).
std::vector<CheckResult> run_kernels(std::vector<Pair> &pairs, uint64_t n, uint64_t inject_at, uint32_t inject_lane) {
    const uint64_t max_wait = 50'000'000;  // ~0.25 s at the line rate, covers the start-up gap
    // The previous checker stops while its generator still runs, so the RX path still holds that
    // run's data. Read it away first (~5 ms of line data), or the checker locks on it.
    for (auto &p : pairs) {
        p.chk->setArg("nbeats", uint64_t{0});
        p.chk->setArg("lock_beats", 64u);
        p.chk->setArg("max_wait", uint64_t{1'000'000});
        p.chk->start();
    }
    for (auto &p : pairs) p.chk->wait();
    for (auto &p : pairs) {
        p.chk->setArg("nbeats", n);
        p.chk->setArg("lock_beats", 64u);
        p.chk->setArg("max_wait", max_wait);
        p.gen->setArg("nbeats", n + max_wait);
        p.gen->setArg("inject_at", inject_at);
        p.gen->setArg("inject_lane", inject_lane);
    }
    for (auto &p : pairs) p.chk->start();
    for (auto &p : pairs) p.gen->start();
    for (auto &p : pairs) p.gen->wait();
    for (auto &p : pairs) p.chk->wait();
    std::vector<CheckResult> res;
    for (auto &p : pairs) {
        CheckResult r{};
        r.locked = (p.chk->read(0x30) & 1) != 0;
        r.wait = read64(*p.chk, 0x40);
        r.beats = read64(*p.chk, 0x58);
        for (int l = 0; l < 4; ++l) {
            r.err[l] = read64(*p.chk, 0x70 + 0x18 * l);
            r.zero[l] = read64(*p.chk, 0xd0 + 0x18 * l);
        }
        res.push_back(r);
    }
    return res;
}

// One line per quad: lock, beats checked, error bits and all-zero words per lane.
void print_result(uint32_t bank, const CheckResult &r) {
    std::printf("    quad %u: locked %s after %llu beats, checked %llu beats (%.3g bits per lane); error bits %llu %llu %llu %llu, all-zero words %llu %llu %llu %llu\n",
                bank, r.locked ? "yes" : "NO", (unsigned long long)r.wait, (unsigned long long)r.beats,
                128.0 * double(r.beats), (unsigned long long)r.err[0], (unsigned long long)r.err[1],
                (unsigned long long)r.err[2], (unsigned long long)r.err[3], (unsigned long long)r.zero[0],
                (unsigned long long)r.zero[1], (unsigned long long)r.zero[2], (unsigned long long)r.zero[3]);
}

}  // namespace

int main(int argc, char *argv[]) {
    double seconds = 40.0;
    bool external = false, park = false;
    std::vector<std::string> pos;
    for (int i = 1; i < argc; ++i) {
        if (!std::strcmp(argv[i], "--external")) external = true;
        else if (!std::strcmp(argv[i], "--park")) park = true;
        else pos.push_back(argv[i]);
    }
    if (pos.size() < 2) {
        std::fprintf(stderr, "Usage: %s <BDF> <vbin> [seconds of the long run, default 40] [--external | --park]\n",
                     argv[0]);
        return 2;
    }
    if (pos.size() > 2) seconds = std::atof(pos[2].c_str());
    int failures = 0;
    auto check = [&](bool ok, const std::string &what) {
        std::printf("  %-62s %s\n", what.c_str(), ok ? "OK" : "FAIL");
        failures += ok ? 0 : 1;
        return ok;
    };

    try {
        vrt::Device device(pos[0], pos[1]);
        Bar4 bar(pos[0]);
        std::vector<Pair> pairs;
        StopStreams stop{find_quads(bar), &pairs};
        const auto &quads = stop.quads;
        off_on_signal(bar, quads);
        for (const auto &q : quads) {
            try {
                Pair p;
                p.gen = std::make_unique<vrt::Kernel>(device, "gt_prbs_gen_" + std::to_string(q.index()));
                p.chk = std::make_unique<vrt::Kernel>(device, "gt_prbs_check_" + std::to_string(q.index()));
                pairs.push_back(std::move(p));
            } catch (const std::exception &) {
                break;
            }
        }
        std::printf("Mode: %s; %zu quad(s) in the shell, %zu generator/checker pair(s) in the image\n",
                    park       ? "park (generators only, quads held)"
                    : external ? "external (cables)"
                               : "in-chip near-end PMA loopback",
                    quads.size(), pairs.size());
        if (!check(!quads.empty() && pairs.size() == quads.size(), "one kernel pair per GT quad")) {
            std::printf("GT_LOOPBACK: FAIL\n");
            return 1;
        }
        if (park) {
            stop.active = false;
            std::vector<uint32_t> tx0;
            for (const auto &q : quads) {
                q.write(CTRL, CTRL_HOLD);
                tx0.push_back(q.read(TX_BEATS));
            }
            for (auto &p : pairs) {
                p.gen->setArg("nbeats", uint64_t{1'000'000'000});
                p.gen->setArg("inject_at", ~uint64_t{0});
                p.gen->setArg("inject_lane", 0u);
                p.gen->start();
            }
            sleep_ms(1000);
            for (size_t i = 0; i < quads.size(); ++i)
                std::printf("  quad %u: CTRL 0x%03x, TX beats taken by the shell %u, generator %s\n", quads[i].bank(),
                            quads[i].read(CTRL), quads[i].read(TX_BEATS) - tx0[i],
                            (pairs[i].gen->read(0x00) & 0x4) ? "idle" : "running");
            std::printf("GT_LOOPBACK: PARKED (quads held, generators started; load another image next)\n");
            return 0;
        }

        std::printf("1. Reference clock inputs, FireFly modules, GT quads\n");
        if (bar.read(METER) == METER_ID) {
            static const char *names[8] = {"106 REFCLK0 (Si5395)", "106 REFCLK1 (Si570)", "110 REFCLK0 (Si5395)",
                                           "110 REFCLK1 (Si570)",  "111 REFCLK0 (Si5395)", "111 REFCLK1 (Si570)",
                                           "112 REFCLK0 (Si5395)", "112 REFCLK1 (Si570)"};
            for (int i = 0; i < 8; ++i)
                std::printf("     %-22s %9.3f MHz\n", names[i], bar.read(METER + 0x10 + 4 * i) / 1000.0);
        }
        if (bar.read(BOARD) == BOARD_ID) {
            const uint32_t st = bar.read(BOARD + 0x08);
            std::printf("     FireFly modules present:");
            for (int i = 0; i < 4; ++i) std::printf(" %s %s;", module_name(i), (st >> i) & 1 ? "yes" : "no");
            std::printf("\n");
            if (external && (st & 0xF) != 0xF)
                std::printf("     (an external test needs the TX and RX modules of the FireFly sites of these quads)\n");
        }
        bool all_done = true;
        for (const auto &q : quads) {
            q.write(TX_PRBS, 0);
            q.write(RX_PRBS, 0);
            q.write(POLARITY, 0);
            q.write(LOOPBACK, external ? 0 : LOOPBACK_NEAR_PMA);
            const bool done = q.reset(CTRL_HOLD);  // streams stay held until the kernels read them (step 3)
            all_done = all_done && done;
            const uint32_t st = q.read(STATUS);
            const double ref = 1e-3 * q.read(REFCLK_KHZ), txc = 1e-3 * q.read(TX_USRCLK_KHZ),
                         rxc = 1e-3 * q.read(RX_USRCLK_KHZ);
            std::printf("     quad %u: reference %.3f MHz, TX user %.3f MHz, RX user %.3f MHz, status 0x%02x\n",
                        q.bank(), ref, txc, rxc, st);
            const std::string b = "quad " + std::to_string(q.bank()) + ": ";
            check(ref > 156.0 && ref < 156.5 && (st & 1) && done, b + "reference 156.25 MHz, power good, reset done");
            check(txc > 402.0 && txc < 403.7 && rxc > 402.0 && rxc < 403.7, b + "user clocks 402.832 MHz");
        }

        std::printf("2. GT internal PRBS-31 on every lane (checkers inside the GT)\n");
        const auto locked = prbs31_lock_with_polarity(quads);
        std::vector<std::vector<uint32_t>> e0(quads.size(), std::vector<uint32_t>(4));
        for (size_t i = 0; i < quads.size(); ++i)
            for (uint32_t l = 0; l < 4; ++l) e0[i][l] = quads[i].prbs_err(l);
        sleep_ms(1000);
        for (size_t i = 0; i < quads.size(); ++i) {
            const auto &q = quads[i];
            uint32_t e[4];
            for (uint32_t l = 0; l < 4; ++l) e[l] = q.prbs_err(l) - e0[i][l];
            std::printf("     quad %u: locked 0x%x, RX polarity inverted 0x%x, error cycles in 1 s: %u %u %u %u\n",
                        q.bank(), locked[i], q.read(POLARITY) >> 4, e[0], e[1], e[2], e[3]);
            const std::string b = "quad " + std::to_string(q.bank()) + ": ";
            check(locked[i] == 0xF, b + "all 4 lanes PRBS locked");
            check(!e[0] && !e[1] && !e[2] && !e[3], b + "no PRBS errors in 1 s");
            check(q.tx_pma_data_sel(0) == 5, b + "GT register port works (TX_PMA_DATA_SEL = 5)");
        }
        for (size_t j = 0; j < quads.size(); ++j) {
            // a forced error on TX lane 0 must reach a locked RX lane: the same lane in the chip
            // loopback, any lane of these quads over cables
            const auto &q = quads[j];
            std::vector<uint32_t> before;
            for (const auto &r : quads)
                for (uint32_t l = 0; l < 4; ++l) before.push_back(r.prbs_err(l));
            const bool ok = q.force_tx_error(0);
            sleep_ms(10);
            uint32_t same = q.prbs_err(0) - before[j * 4], any = 0;
            for (size_t i = 0, k = 0; i < quads.size(); ++i)
                for (uint32_t l = 0; l < 4; ++l, ++k) any += quads[i].prbs_err(l) - before[k];
            std::printf("     quad %u: forced error on TX lane 0%s: %u error cycles on RX lane 0, %u on all lanes\n",
                        q.bank(), ok ? "" : " (register access FAILED)", same, any);
            check(external ? any > 0 : same > 0, "quad " + std::to_string(q.bank()) + ": forced error seen by a GT checker");
        }
        for (const auto &q : quads) {
            q.write(TX_PRBS, 0);
            q.write(RX_PRBS, 0);
        }

        if (!all_done) {
            // Without reset done the lane adapters stay in reset and the kernels would wait forever.
            std::printf("3. Kernel path skipped: a quad is not out of reset (no reference clock or PLL lock)\n");
            std::printf("GT_LOOPBACK: FAIL\n");
            return 1;
        }

        std::printf("3. Kernel path, all quads at once (gt_prbs_gen_k -> GT -> gt_prbs_check_k), 250 MHz kernels\n");
        for (const auto &q : quads) q.write(CTRL, 0);  // release the streams; run_kernels drains first
        const uint32_t inject_lane = 2;
        auto a = run_kernels(pairs, 10'000'000, 1'000'000, inject_lane);
        std::printf("  short run, one flipped bit per quad on lane %u:\n", inject_lane);
        bool ok_a = true;
        int threes = 0;
        for (size_t i = 0; i < a.size(); ++i) {
            print_result(quads[i].bank(), a[i]);
            ok_a = ok_a && a[i].locked && a[i].beats == 10'000'000;
            for (uint32_t l = 0; l < 4; ++l) {
                ok_a = ok_a && a[i].zero[l] == 0;
                if (external) {
                    ok_a = ok_a && (a[i].err[l] == 0 || a[i].err[l] == 3);
                    threes += a[i].err[l] == 3;
                } else {
                    ok_a = ok_a && a[i].err[l] == (l == inject_lane ? 3u : 0u);
                }
            }
        }
        if (external) ok_a = ok_a && threes == int(a.size());
        check(ok_a, "every flipped bit seen once (3 error bits), nothing else");

        const uint64_t n = static_cast<uint64_t>(seconds * BEATS_PER_S);
        std::vector<uint32_t> drops0, under0;
        for (const auto &q : quads) {
            drops0.push_back(q.read(RX_DROPS));
            under0.push_back(q.read(TX_UNDERFLOWS));
        }
        auto b = run_kernels(pairs, n, ~0ull, 0);
        std::printf("  long run:\n");
        bool ok_b = true;
        for (size_t i = 0; i < b.size(); ++i) {
            print_result(quads[i].bank(), b[i]);
            std::printf("      RX adapter drops %u (while no checker runs), TX underflow cycles %u (incl. after the generator ends)\n",
                        quads[i].read(RX_DROPS) - drops0[i], quads[i].read(TX_UNDERFLOWS) - under0[i]);
            ok_b = ok_b && b[i].locked && b[i].beats == n;
            for (uint32_t l = 0; l < 4; ++l) ok_b = ok_b && b[i].err[l] == 0 && b[i].zero[l] == 0;
        }
        check(ok_b, "long run error free on all " + std::to_string(4 * quads.size()) + " lanes");

        std::printf("GT_LOOPBACK: %s\n", failures == 0 ? "PASS" : "FAIL");
        return failures == 0 ? 0 : 1;
    } catch (const std::exception &e) {
        std::fprintf(stderr, "08_gt_loopback: %s\n", e.what());
        std::printf("GT_LOOPBACK: ERROR\n");
        return 2;
    }
}
