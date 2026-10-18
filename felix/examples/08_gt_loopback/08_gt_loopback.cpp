// GT stream 0 of the shell (one quad, 4 lanes) in near-end PMA loopback, checked end to end:
//   1. shell registers: all 8 FireFly reference clock inputs (meter, PF2 BAR4 + 0x70000), then the
//      quad (PF2 BAR4 + 0x30000): its reference/user clocks, power good, reset done
//   2. the GT's own PRBS-31 generator and checker (no kernel in the path), plus a forced error
//   3. kernel path: gt_prbs_gen -> NoC -> TX lane adapter -> GT -> loopback -> RX lane adapter
//      -> NoC -> gt_prbs_check, once with one injected bit flip (3 error bits on that lane),
//      then a long run that must be error free (default 40 s, about 1e12 bits per lane).
#include <vrt/device.hpp>
#include <vrt/kernel.hpp>
#include <vrtd/bar_file.hpp>
#include <vrtd/session.hpp>

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <string>
#include <thread>

namespace {

constexpr double BEATS_PER_S = 25.78125e9 / 128;  // one 512-bit beat = 128 bits per lane

// Shell registers of one GT quad (felix/hw/rtl/felix_gt_quad_if.v).
class GtRegs {
public:
    explicit GtRegs(const std::string &bdf)
        : dev_(session_.getDeviceByBdf(bdf)), bar_(dev_.getBar(4)), file_(bar_.openBarFile()) {}
    // Hold the lane adapters again on exit: the next kernel load fails while the RX stream runs.
    ~GtRegs() { write(CTRL, 0x100); }
    uint32_t read(uint32_t off) { return bar_read(BASE + off); }
    void write(uint32_t off, uint32_t v) {
        auto p = file_.getPtr<uint32_t>(vrtd::BarFile::Direction::Write, BASE + off);
        *p = v;
    }
    uint32_t bar_read(uint32_t addr) {
        auto p = file_.getPtr<uint32_t>(vrtd::BarFile::Direction::Read, addr);
        return p[0];
    }

    static constexpr uint32_t ID = 0x00, CTRL = 0x04, LOOPBACK = 0x08, TX_PRBS = 0x0C, RX_PRBS = 0x10,
                              PRBS_CTRL = 0x18, STATUS = 0x20, RX_DROPS = 0x28, TX_UNDERFLOWS = 0x30,
                              BANK = 0x3C, REFCLK_KHZ = 0x40, TX_USRCLK_KHZ = 0x44, RX_USRCLK_KHZ = 0x48,
                              PRBS_ERR0 = 0x50, GT_ADDR = 0x60, GT_WDATA = 0x64, GT_CMD = 0x68,
                              GT_RDATA = 0x6C;
    static constexpr uint32_t METER = 0x70000;  // felix_refclk_meter: ID 0x434C4B4D, 8 x kHz

private:
    static constexpr uint32_t BASE = 0x30000;
    vrtd::Session session_;
    vrtd::Device dev_;
    vrtd::Bar bar_;
    vrtd::BarFile file_;
};

void sleep_ms(int ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }

bool wait_status(GtRegs &g, uint32_t mask, int timeout_ms) {
    for (int t = 0; t < timeout_ms; t += 10) {
        if ((g.read(GtRegs::STATUS) & mask) == mask)
            return true;
        sleep_ms(10);
    }
    return false;
}

// Reset the whole quad and wait for TX and RX reset done.
bool reset_quad(GtRegs &g) {
    g.write(GtRegs::CTRL, 0x1);
    sleep_ms(1);
    g.write(GtRegs::CTRL, 0x0);
    return wait_status(g, 0x6, 2000);
}

// One access to a GT attribute register (address as in AM002) through the shell's GT_* registers.
bool gt_attr(GtRegs &g, uint32_t attr, bool write, uint32_t &val) {
    g.write(GtRegs::GT_ADDR, attr * 4);
    if (write) g.write(GtRegs::GT_WDATA, val);
    g.write(GtRegs::GT_CMD, write ? 2 : 1);
    for (int i = 0; i < 1000; ++i) {
        const uint32_t st = g.read(GtRegs::GT_CMD);
        if ((st & 1) == 0) {
            if (!write) val = g.read(GtRegs::GT_RDATA);
            return (st & 2) == 0;
        }
    }
    return false;
}

// GT attributes used here (AMD AR 76629): CH0_TX_PCS_CFG0[31:29] TX_PMA_DATA_SEL is 5 while the
// TX PRBS generator runs; CH0_CHL_RSV_CFG1[5] forces TX PRBS errors (the TXPRBSFORCEERR pin does not).
constexpr uint32_t CH0_TX_PCS_CFG0 = 0x0C77, CH0_CHL_RSV_CFG1 = 0x0C62;

uint64_t read64(vrt::Kernel &k, uint32_t off) {
    return static_cast<uint64_t>(k.read(off)) | (static_cast<uint64_t>(k.read(off + 4)) << 32);
}

struct CheckResult {
    bool locked;
    uint64_t wait, beats, err[4], zero[4];
};

// One generator/checker run of n counted beats; inject_at = beat with one flipped bit (or none).
CheckResult run_kernels(vrt::Kernel &gen, vrt::Kernel &chk, uint64_t n, uint64_t inject_at, uint32_t lane) {
    const uint64_t max_wait = 50'000'000;  // ~0.25 s at the line rate, covers the start-up gap
    // The previous checker stops while its generator still runs, so the RX path still holds that
    // run's data. Read it away first (~5 ms of line data), or the checker locks on it.
    chk.setArg("nbeats", uint64_t{0});
    chk.setArg("lock_beats", 64u);
    chk.setArg("max_wait", uint64_t{1'000'000});
    chk.start();
    chk.wait();
    chk.setArg("nbeats", n);
    chk.setArg("lock_beats", 64u);
    chk.setArg("max_wait", max_wait);
    gen.setArg("nbeats", n + max_wait);
    gen.setArg("inject_at", inject_at);
    gen.setArg("inject_lane", lane);
    chk.start();
    gen.start();
    gen.wait();
    chk.wait();
    CheckResult r{};
    r.locked = (chk.read(0x30) & 1) != 0;
    r.wait = read64(chk, 0x40);
    r.beats = read64(chk, 0x58);
    for (int l = 0; l < 4; ++l) {
        r.err[l] = read64(chk, 0x70 + 0x18 * l);
        r.zero[l] = read64(chk, 0xd0 + 0x18 * l);
    }
    return r;
}

void print_result(const char *name, const CheckResult &r) {
    std::printf("  %s: locked %s after %llu beats, checked %llu beats (%.3g bits per lane)\n", name,
                r.locked ? "yes" : "NO", (unsigned long long)r.wait, (unsigned long long)r.beats,
                128.0 * double(r.beats));
    std::printf("    error bits per lane: %llu %llu %llu %llu   all-zero words: %llu %llu %llu %llu\n",
                (unsigned long long)r.err[0], (unsigned long long)r.err[1], (unsigned long long)r.err[2],
                (unsigned long long)r.err[3], (unsigned long long)r.zero[0], (unsigned long long)r.zero[1],
                (unsigned long long)r.zero[2], (unsigned long long)r.zero[3]);
}

}  // namespace

int main(int argc, char *argv[]) {
    if (argc < 3) {
        std::fprintf(stderr, "Usage: %s <BDF> <vbin> [seconds of the long run, default 40]\n", argv[0]);
        return 2;
    }
    const double seconds = argc > 3 ? std::atof(argv[3]) : 40.0;
    int failures = 0;
    auto check = [&](bool ok, const char *what) {
        std::printf("  %-58s %s\n", what, ok ? "OK" : "FAIL");
        failures += ok ? 0 : 1;
        return ok;
    };

    try {
        vrt::Device device(argv[1], argv[2]);
        vrt::Kernel gen(device, "gt_prbs_gen_0");
        vrt::Kernel chk(device, "gt_prbs_check_0");
        GtRegs g(argv[1]);

        std::printf("1. Reference clock inputs (meter) and shell GT registers\n");
        if (g.bar_read(GtRegs::METER) == 0x434C4B4D) {
            static const char *names[8] = {"106 REFCLK0 (Si5395 U79)", "106 REFCLK1 (Si570 U39)",
                                           "110 REFCLK0 (Si5395 U79)", "110 REFCLK1 (Si570 U40)",
                                           "111 REFCLK0 (Si5395 U80)", "111 REFCLK1 (Si570 U40)",
                                           "112 REFCLK0 (Si5395 U79)", "112 REFCLK1 (Si570 U40)"};
            for (int i = 0; i < 8; ++i) {
                const uint32_t a = g.bar_read(GtRegs::METER + 0x10 + 4 * i);
                sleep_ms(2);
                const uint32_t b = g.bar_read(GtRegs::METER + 0x10 + 4 * i);
                std::printf("     quad %-26s %9.3f MHz then %9.3f MHz\n", names[i], a / 1000.0, b / 1000.0);
            }
        } else {
            std::printf("     no reference clock meter in this shell\n");
        }
        const uint32_t id = g.read(GtRegs::ID);
        if (!check(id == 0x46475431, "register block ID 0x46475431")) {
            std::printf("     read 0x%08x: this shell has no GT quad\n", id);
            std::printf("GT_LOOPBACK: FAIL\n");
            return 1;
        }
        g.write(GtRegs::TX_PRBS, 0);
        g.write(GtRegs::RX_PRBS, 0);
        g.write(GtRegs::LOOPBACK, 0x492);  // near-end PMA loopback on all 4 lanes
        const bool done = reset_quad(g);
        sleep_ms(5);
        const uint32_t st = g.read(GtRegs::STATUS);
        const uint32_t bank = g.read(GtRegs::BANK);
        const double ref = 1e-3 * g.read(GtRegs::REFCLK_KHZ);
        const double txc = 1e-3 * g.read(GtRegs::TX_USRCLK_KHZ);
        const double rxc = 1e-3 * g.read(GtRegs::RX_USRCLK_KHZ);
        std::printf("     quad %u: reference clock %.3f MHz, TX user clock %.3f MHz, RX user clock %.3f MHz, status 0x%02x\n",
                    bank, ref, txc, rxc, st);
        check(ref > 156.0 && ref < 156.5, "reference clock 156.25 MHz");
        check((st & 1) != 0, "GT power good");
        check(done, "TX and RX reset done after loopback on");
        check(txc > 402.0 && txc < 403.7 && rxc > 402.0 && rxc < 403.7, "user clocks 402.832 MHz");

        std::printf("2. GT internal PRBS-31 (lane checkers inside the GT)\n");
        uint32_t pcs_off = 0, pcs_on = 0;
        bool regs_ok = gt_attr(g, CH0_TX_PCS_CFG0, false, pcs_off);
        g.write(GtRegs::TX_PRBS, 0x5555);
        g.write(GtRegs::RX_PRBS, 0x5555);
        g.write(GtRegs::PRBS_CTRL, 0x1);
        sleep_ms(1);
        g.write(GtRegs::PRBS_CTRL, 0x0);
        sleep_ms(100);
        uint32_t e0[4], e1[4];
        for (int l = 0; l < 4; ++l) e0[l] = g.read(GtRegs::PRBS_ERR0 + 4 * l);
        sleep_ms(1000);
        for (int l = 0; l < 4; ++l) e1[l] = g.read(GtRegs::PRBS_ERR0 + 4 * l);
        const uint32_t locks = (g.read(GtRegs::STATUS) >> 4) & 0xF;
        std::printf("     PRBS lock 0x%x, error cycles in 1 s: %u %u %u %u\n", locks, e1[0] - e0[0], e1[1] - e0[1],
                    e1[2] - e0[2], e1[3] - e0[3]);
        check(locks == 0xF, "all 4 lanes PRBS locked");
        check(e1[0] == e0[0] && e1[1] == e0[1] && e1[2] == e0[2] && e1[3] == e0[3], "no PRBS errors in 1 s");
        regs_ok = gt_attr(g, CH0_TX_PCS_CFG0, false, pcs_on) && regs_ok;
        std::printf("     GT register CH0_TX_PCS_CFG0: 0x%08x with PRBS off, 0x%08x with PRBS on\n", pcs_off, pcs_on);
        // only write a GT register once a read has shown the addresses are right
        const bool regs_known = regs_ok && (pcs_on >> 29) == 5;
        check(regs_known, "GT register port works (TX_PMA_DATA_SEL = 5 while PRBS runs)");
        uint32_t forced = 0;
        if (regs_known) {
            uint32_t rsv = 0;
            bool ok = gt_attr(g, CH0_CHL_RSV_CFG1, false, rsv);
            const uint32_t before = g.read(GtRegs::PRBS_ERR0);
            uint32_t v = rsv | 0x20;
            ok = ok && gt_attr(g, CH0_CHL_RSV_CFG1, true, v);
            v = rsv;
            ok = gt_attr(g, CH0_CHL_RSV_CFG1, true, v) && ok;
            sleep_ms(10);
            forced = g.read(GtRegs::PRBS_ERR0) - before;
            std::printf("     forced error on lane 0 (CH0_CHL_RSV_CFG1 0x%08x, bit 5 set and cleared%s): %u error cycles\n",
                        rsv, ok ? "" : ", register access FAILED", forced);
        }
        check(forced > 0, "a forced error is seen by the GT checker");
        if (forced == 0) {
            // Does the GT error output count at all? Send PRBS-7 to the PRBS-31 checker for 10 ms.
            const uint32_t w0 = g.read(GtRegs::PRBS_ERR0);
            g.write(GtRegs::TX_PRBS, 0x1111);
            sleep_ms(10);
            g.write(GtRegs::TX_PRBS, 0x5555);
            sleep_ms(10);
            std::printf("     wrong pattern (PRBS-7) for 10 ms on lane 0: %u error cycles\n",
                        g.read(GtRegs::PRBS_ERR0) - w0);
        }
        g.write(GtRegs::TX_PRBS, 0);
        g.write(GtRegs::RX_PRBS, 0);

        if (!done || (g.read(GtRegs::STATUS) & 0x6) != 0x6) {
            // Without reset done the lane adapters are held in reset and the kernels would wait forever.
            std::printf("3. Kernel path skipped: the GT is not out of reset (no reference clock or PLL lock)\n");
            g.write(GtRegs::LOOPBACK, 0);
            std::printf("GT_LOOPBACK: FAIL\n");
            return 1;
        }

        std::printf("3. Kernel path (gt_prbs_gen -> GT loopback -> gt_prbs_check), 250 MHz kernels\n");
        const uint32_t inject_lane = 2;
        CheckResult a = run_kernels(gen, chk, 10'000'000, 1'000'000, inject_lane);
        print_result("short run, one flipped bit on lane 2", a);
        bool ok_a = a.locked && a.beats == 10'000'000;
        for (int l = 0; l < 4; ++l)
            ok_a = ok_a && a.zero[l] == 0 && a.err[l] == (l == (int)inject_lane ? 3u : 0u);
        check(ok_a, "locked, the one flipped bit seen (3 error bits), nothing else");

        const uint64_t n = static_cast<uint64_t>(seconds * BEATS_PER_S);
        const uint32_t drops0 = g.read(GtRegs::RX_DROPS);
        const uint32_t under0 = g.read(GtRegs::TX_UNDERFLOWS);
        CheckResult b = run_kernels(gen, chk, n, ~0ull, 0);
        const uint32_t drops = g.read(GtRegs::RX_DROPS) - drops0;
        const uint32_t under = g.read(GtRegs::TX_UNDERFLOWS) - under0;
        print_result("long run", b);
        bool ok_b = b.locked && b.beats == n;
        for (int l = 0; l < 4; ++l) ok_b = ok_b && b.err[l] == 0 && b.zero[l] == 0;
        std::printf("     RX lane adapter drops: %u (while no checker runs)\n", drops);
        std::printf("     TX lane adapter underflow cycles: %u (includes the zeros sent after the generator ends)\n", under);
        check(ok_b, "long run error free on all 4 lanes");

        g.write(GtRegs::LOOPBACK, 0);
        std::printf("GT_LOOPBACK: %s\n", failures == 0 ? "PASS" : "FAIL");
        return failures == 0 ? 0 : 1;
    } catch (const std::exception &e) {
        std::fprintf(stderr, "08_gt_loopback: %s\n", e.what());
        std::printf("GT_LOOPBACK: ERROR\n");
        return 2;
    }
}
