// Link-level checks of the shell's GT quads, without a kernel: GT PRBS-31 on every lane in
// near-end loopback (in the chip) or over cables (--external), RX polarity found per lane,
// error counts, which TX lane arrives on which RX lane, and the FireFly module lines.
// The lane adapters stay held (CTRL[8]), so nothing reaches the kernel region.
#include "gt_regs.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <string>
#include <vector>

using namespace felix_gt;

namespace {

void usage(const char *p) {
    std::fprintf(stderr,
                 "Usage: %s <BDF> <command> [options]\n"
                 "  status                  clocks, reset, lock and settings of every quad, FireFly lines\n"
                 "  prbs [--external] [--seconds N]\n"
                 "                          GT PRBS-31 on every lane, in-chip loopback or --external\n"
                 "                          (cables), RX polarity found per lane, errors over N s (10)\n"
                 "  map [--external]        which RX lane each TX lane arrives on (forced TX errors)\n"
                 "  firefly [--reset]       FireFly module present/interrupt; --reset pulses the resets\n"
                 "  off                     PRBS, loopback and polarity back to 0, streams held (as after boot)\n",
                 p);
}

std::string lane_name(const Quad &q, uint32_t lane) { return std::to_string(q.bank()) + "." + std::to_string(lane); }

// FireFly module lines from felix_board_io: present, interrupt, reset and I2C select per module.
void print_firefly(Bar4 &bar) {
    if (bar.read(BOARD) != BOARD_ID) {
        std::printf("FireFly lines: not in this shell\n");
        return;
    }
    const uint32_t ctrl = bar.read(BOARD + 0x04), st = bar.read(BOARD + 0x08);
    std::printf("FireFly modules (FF_CTRL 0x%03x, FF_STATUS 0x%08x)\n", ctrl, st);
    for (int i = 0; i < 4; ++i)
        std::printf("  %-13s %-11s %-13s reset %-8s I2C %s\n", module_name(i), (st >> i) & 1 ? "present" : "not present",
                    (st >> (8 + i)) & 1 ? "INTERRUPT" : "no interrupt", (ctrl >> i) & 1 ? "released" : "HELD",
                    (ctrl >> (8 + i)) & 1 ? "off" : "on");
    std::printf("  FireFly 6 (TTC) %s, I/O expander interrupts %u %u\n", (st >> 16) & 1 ? "present" : "not present",
                (st >> 24) & 1, (st >> 25) & 1);
}

// Reference clocks, then per quad: settings, reset state, lock and clock frequencies; then the FireFly lines.
void cmd_status(Bar4 &bar, const std::vector<Quad> &quads) {
    if (bar.read(METER) == METER_ID) {
        std::printf("Reference clock inputs (kHz):");
        for (int i = 0; i < 8; ++i) std::printf(" %u", bar.read(METER + 0x10 + 4 * i));
        std::printf("   (106 R0 R1, 110 R0 R1, 111 R0 R1, 112 R0 R1; R1 = Si570 156250)\n");
    }
    for (const auto &q : quads) {
        const uint32_t st = q.read(STATUS);
        std::printf("Quad %u (BAR4 + 0x%05x): CTRL 0x%03x LOOPBACK 0x%03x TX_PRBS 0x%04x RX_PRBS 0x%04x POLARITY 0x%02x\n",
                    q.bank(), QUAD_BASE + q.index() * QUAD_STRIDE, q.read(CTRL), q.read(LOOPBACK), q.read(TX_PRBS),
                    q.read(RX_PRBS), q.read(POLARITY));
        std::printf("  power good %u, TX reset done %u, RX reset done %u, PRBS locked lanes 0x%x\n", st & 1,
                    (st >> 1) & 1, (st >> 2) & 1, (st >> 4) & 0xF);
        std::printf("  clocks kHz: reference %u, TX user %u, RX user %u; RX beats %u drops %u, TX beats %u underflows %u\n",
                    q.read(REFCLK_KHZ), q.read(TX_USRCLK_KHZ), q.read(RX_USRCLK_KHZ), q.read(RX_BEATS),
                    q.read(RX_DROPS), q.read(TX_BEATS), q.read(TX_UNDERFLOWS));
    }
    print_firefly(bar);
}

// Back to the state after boot: streams held, PRBS, loopback and polarity off.
void cmd_off(const std::vector<Quad> &quads) {
    for (const auto &q : quads) {
        q.write(CTRL, CTRL_HOLD);
        q.write(TX_PRBS, 0);
        q.write(RX_PRBS, 0);
        q.write(POLARITY, 0);
        q.write(LOOPBACK, 0);
    }
}

// Loopback mode, quad reset (adapters held), PRBS-31 and polarity search; prints the lock table.
bool setup_prbs(const std::vector<Quad> &quads, bool external, std::vector<uint32_t> &locked) {
    bool all_done = true;
    for (const auto &q : quads) {
        q.write(TX_PRBS, 0);
        q.write(RX_PRBS, 0);
        q.write(LOOPBACK, external ? 0 : LOOPBACK_NEAR_PMA);
        if (!q.reset(CTRL_HOLD)) {
            std::printf("Quad %u: TX/RX reset not done (STATUS 0x%02x): no reference clock or PLL lock\n", q.bank(),
                        q.read(STATUS));
            all_done = false;
        }
    }
    locked = prbs31_lock_with_polarity(quads);
    std::printf("GT PRBS-31, %s:\n", external ? "external (cables)" : "in-chip near-end PMA loopback");
    for (size_t i = 0; i < quads.size(); ++i) {
        const uint32_t pol = quads[i].read(POLARITY) >> 4;
        std::printf("  quad %u:", quads[i].bank());
        for (uint32_t l = 0; l < 4; ++l)
            std::printf("  lane %u %s", l,
                        (locked[i] >> l) & 1 ? ((pol >> l) & 1 ? "locked (RX inverted)" : "locked") : "NO SIGNAL");
        std::printf("\n");
    }
    return all_done;
}

// GT PRBS-31 on every lane, error words counted over the given time; PASS if every lane locks with 0 errors.
int cmd_prbs(const std::vector<Quad> &quads, bool external, double seconds) {
    std::vector<uint32_t> locked;
    bool ok = setup_prbs(quads, external, locked);
    std::vector<std::vector<uint32_t>> e0(quads.size(), std::vector<uint32_t>(4));
    for (size_t i = 0; i < quads.size(); ++i)
        for (uint32_t l = 0; l < 4; ++l) e0[i][l] = quads[i].prbs_err(l);
    std::printf("Counting errors for %.0f s ...\n", seconds);
    sleep_ms(int(seconds * 1000));
    const double bits = seconds * 25.78125e9;
    int good = 0, total = 0;
    for (size_t i = 0; i < quads.size(); ++i) {
        const uint32_t still = quads[i].locks();
        std::printf("  quad %u error words:", quads[i].bank());
        for (uint32_t l = 0; l < 4; ++l) {
            ++total;
            if (!((locked[i] >> l) & 1)) {
                std::printf("   -");
                continue;
            }
            const uint32_t e = quads[i].prbs_err(l) - e0[i][l];
            const bool lane_ok = e == 0 && ((still >> l) & 1);
            good += lane_ok ? 1 : 0;
            std::printf("  %u", e);
        }
        std::printf("\n");
    }
    std::printf("  %d of %d lanes locked and error free over %.3g bits each (BER < %.1e at 95%% if 0 errors)\n", good,
                total, bits, 3.0 / bits);
    cmd_off(quads);
    ok = ok && good == total;
    std::printf("GT_LINK_PRBS: %s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}

// Forces an error on one TX lane at a time and reports which RX lane counters moved.
int cmd_map(const std::vector<Quad> &quads, bool external) {
    std::vector<uint32_t> locked;
    setup_prbs(quads, external, locked);
    for (const auto &q : quads) {
        if (q.tx_pma_data_sel(0) != 5) {
            std::printf("Quad %u: GT register port not answering as expected; cannot force errors\n", q.bank());
            cmd_off(quads);
            std::printf("GT_LINK_MAP: FAIL\n");
            return 1;
        }
    }
    std::printf("Lane map (a forced error on one TX lane, then which RX error counter moved):\n");
    int mapped = 0, total = 0;
    for (const auto &src : quads) {
        for (uint32_t l = 0; l < 4; ++l) {
            ++total;
            std::vector<uint32_t> before;
            for (const auto &q : quads)
                for (uint32_t r = 0; r < 4; ++r) before.push_back(q.prbs_err(r));
            const bool forced = src.force_tx_error(l);
            sleep_ms(20);
            std::string hit;
            size_t k = 0;
            for (size_t i = 0; i < quads.size(); ++i)
                for (uint32_t r = 0; r < 4; ++r, ++k)
                    if ((locked[i] >> r) & 1 && quads[i].prbs_err(r) != before[k]) {
                        const bool inv = (quads[i].read(POLARITY) >> (4 + r)) & 1;
                        hit += (hit.empty() ? "" : ", ") + lane_name(quads[i], r) + (inv ? " (inverted)" : "");
                    }
            mapped += hit.empty() ? 0 : 1;
            std::printf("  TX %-6s -> %s\n", lane_name(src, l).c_str(),
                        !forced ? "register access FAILED" : hit.empty() ? "no locked RX lane" : ("RX " + hit).c_str());
        }
    }
    cmd_off(quads);
    std::printf("GT_LINK_MAP: %d of %d TX lanes arrive on a lane of these quads\n", mapped, total);
    return mapped == total ? 0 : 1;
}

// Prints the FireFly lines; with --reset pulses the module resets low for 100 ms first.
int cmd_firefly(Bar4 &bar, bool reset) {
    if (reset) {
        if (bar.read(BOARD) != BOARD_ID) {
            std::printf("FireFly lines: not in this shell\n");
            return 1;
        }
        const uint32_t ctrl = bar.read(BOARD + 0x04);
        bar.write(BOARD + 0x04, ctrl & ~0xFu);
        sleep_ms(100);
        bar.write(BOARD + 0x04, ctrl | 0xFu);
        sleep_ms(500);
        std::printf("FireFly 1/2 modules reset (100 ms)\n");
    }
    print_firefly(bar);
    return 0;
}

}  // namespace

// gt_link <BDF> <command> [options]
int main(int argc, char *argv[]) {
    if (argc < 3) {
        usage(argv[0]);
        return 2;
    }
    const std::string cmd = argv[2];
    bool external = false, reset = false;
    double seconds = 10;
    for (int i = 3; i < argc; ++i) {
        if (!std::strcmp(argv[i], "--external")) external = true;
        else if (!std::strcmp(argv[i], "--reset")) reset = true;
        else if (!std::strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = std::atof(argv[++i]);
        else {
            usage(argv[0]);
            return 2;
        }
    }
    try {
        Bar4 bar(argv[1]);
        const auto quads = find_quads(bar);
        if (cmd == "prbs" || cmd == "map") off_on_signal(bar, quads);
        if (quads.empty() && cmd != "firefly") {
            std::printf("No GT quad in this shell\n");
            return 1;
        }
        if (cmd == "status") {
            cmd_status(bar, quads);
            return 0;
        }
        if (cmd == "prbs") return cmd_prbs(quads, external, seconds);
        if (cmd == "map") return cmd_map(quads, external);
        if (cmd == "firefly") return cmd_firefly(bar, reset);
        if (cmd == "off") {
            cmd_off(quads);
            return 0;
        }
        usage(argv[0]);
        return 2;
    } catch (const std::exception &e) {
        std::fprintf(stderr, "gt_link: %s\n", e.what());
        return 2;
    }
}
