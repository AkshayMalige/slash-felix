#include <iostream>
#include <iomanip>
#include <vector>
#include <string>
#include <cstdint>
#include <cstdlib>
#include <chrono>
#include <stdexcept>

#include <vrt/device.hpp>
#include <vrt/buffer.hpp>
#include <vrt/kernel.hpp>

using Clock = std::chrono::high_resolution_clock;
static inline double secs(Clock::time_point a, Clock::time_point b) {
    return std::chrono::duration<double>(b - a).count();
}
static inline uint32_t pat(size_t idx) {
    return static_cast<uint32_t>(idx * 2654435761u + 1013904223u);
}
static bool waitKernel(vrt::Kernel& k, double timeoutSec = 15.0) {
    const auto t0 = Clock::now();
    while ((k.read(0x00) & 0x2u) == 0u)
        if (secs(t0, Clock::now()) > timeoutSec) return false;
    return true;
}

static const size_t MB             = 1u << 20;
static const size_t U32_PER_WORD   = 16;
static const size_t BYTES_PER_WORD = 64;

struct Result { std::string name; bool pass; std::string note; };
static std::vector<Result> g_results;
static void record(const std::string& n, bool p, const std::string& note = "") {
    g_results.push_back({n, p, note});
}
static std::string sizeLabel(size_t bytes) {
    if (bytes >= MB)   return std::to_string(bytes / MB) + " MB";
    if (bytes >= 1024) return std::to_string(bytes / 1024) + " KB";
    return std::to_string(bytes) + " B";
}

int main(int argc, char** argv) {
    if (argc < 3) {
        std::cerr << "Usage: " << argv[0] << " <BDF> <vbin> [--quick] [--clk <MHz>]\n";
        return 2;
    }
    const std::string bdf = argv[1], vbin = argv[2];
    bool quick = false;
    double clkMHzOverride = 0.0;
    for (int i = 3; i < argc; i++) {
        const std::string a = argv[i];
        if (a == "--quick") quick = true;
        else if (a == "--clk" && i + 1 < argc) clkMHzOverride = std::atof(argv[++i]);
        else { std::cerr << "Unknown argument: " << a << "\n"; return 2; }
    }
    double bestH2D = 0.0, bestD2H = 0.0, ddrRead = 0.0, ddrWrite = 0.0;
    double ddrRead2 = 0.0, ddrWrite2 = 0.0;

    std::cout << std::unitbuf << std::fixed;
    std::cout << "\n========================================================\n";
    std::cout <<   "  04_test_felix -- FELIX platform full test & benchmark" << (quick ? "  [QUICK]" : "") << "\n";
    std::cout <<   "========================================================\n";

    try {
        std::cout << "\n[0] Device program + platform info\n-----------------------------------\n";
        auto t0 = Clock::now();
        vrt::Device device(bdf, vbin);
        auto t1 = Clock::now();
        std::cout << "  BDF                : " << device.getBdf() << "\n";
        std::cout << "  PDI program time   : " << std::setprecision(1) << secs(t0, t1) * 1e3 << " ms\n";
        if (clkMHzOverride > 0.0) {
            device.setFrequency(static_cast<uint64_t>(clkMHzOverride * 1e6));
            std::cout << "  Clock override     : " << std::setprecision(1) << clkMHzOverride << " MHz (--clk)\n";
        }
        uint64_t f = 0, fmax = 0;
        try { f = device.getFrequency(); } catch (...) {}
        try { fmax = device.getMaxFrequency(); } catch (...) {}
        if (f)    std::cout << "  Kernel clock (hw)  : " << std::setprecision(1) << (f / 1e6)    << " MHz  <- actual, read back from the clk_wiz\n";
        if (fmax) std::cout << "  Requested (vbin)   : " << std::setprecision(1) << (fmax / 1e6) << " MHz  <- config.cfg freqhz, capped by timing\n";
        auto ta = Clock::now();
        vrt::Kernel k(device, "mem_bw_0");
        auto tb = Clock::now();
        vrt::Kernel k1(device, "mem_bw_1");
        std::cout << "  Kernel attach      : " << std::setprecision(2) << secs(ta, tb) * 1e3 << " ms\n";
        record("device program", true, std::to_string(static_cast<long>(secs(t0, t1) * 1e3)) + " ms");

        std::cout << "\n[1] QDMA host<->card DATA CORRECTNESS (round-trip)\n--------------------------------------------------\n";
        std::cout << "    fill host -> H2D -> wipe host -> D2H -> compare\n";
        std::vector<size_t> corrBytes = quick
            ? std::vector<size_t>{ 4 * 1024, 64 * 1024, 1 * MB, 16 * MB }
            : std::vector<size_t>{ 4 * 1024, 64 * 1024, 1 * MB, 16 * MB, 64 * MB, 256 * MB };
        for (size_t bytes : corrBytes) {
            const std::string label = sizeLabel(bytes);
            bool ok = false; std::string note;
            try {
                const size_t n = bytes / sizeof(uint32_t);
                vrt::Buffer<uint32_t> b(device, n, k.argMemoryConfig("gmem0"));
                for (size_t j = 0; j < n; j++) b[j] = pat(j);
                b.sync(vrt::SyncType::HOST_TO_DEVICE);
                for (size_t j = 0; j < n; j++) b[j] = 0xDEADBEEFu;
                b.sync(vrt::SyncType::DEVICE_TO_HOST);
                size_t bad = 0, firstBad = 0;
                for (size_t j = 0; j < n; j++) if (b[j] != pat(j)) { if (!bad) firstBad = j; bad++; }
                ok = (bad == 0);
                if (!ok) note = std::to_string(bad) + " mismatch, first word #" + std::to_string(firstBad);
            } catch (const std::exception& e) { note = std::string("EXC: ") + e.what(); }
            std::cout << "    " << std::left << std::setw(8) << label << std::right
                      << "   " << (ok ? "PASS" : ("FAIL  " + note)) << "\n";
            record("qdma-correctness " + label, ok, note);
        }

        std::cout << "\n[2] QDMA host<->card BANDWIDTH (best-of-" << (quick ? 3 : 5) << ")\n--------------------------------------------\n";
        const int bwIters = quick ? 3 : 5;
        std::vector<size_t> sweepMB = quick ? std::vector<size_t>{ 1, 16, 128 }
                                            : std::vector<size_t>{ 1, 2, 4, 8, 16, 32, 64, 128, 256, 512 };
        std::cout << "      " << std::setw(6) << "Size" << std::setw(16) << "H2D (host->card)"
                  << std::setw(16) << "D2H (card->host)" << "\n";
        for (size_t mb : sweepMB) {
            try {
                const size_t bytes = mb * MB, n = bytes / sizeof(uint32_t);
                vrt::Buffer<uint32_t> b(device, n, k.argMemoryConfig("gmem0"));
                for (size_t j = 0; j < n; j++) b[j] = pat(j);
                double bH = 0.0, bD = 0.0;
                for (int it = 0; it < bwIters; it++) {
                    auto s0 = Clock::now(); b.sync(vrt::SyncType::HOST_TO_DEVICE); auto s1 = Clock::now();
                    const double g = static_cast<double>(bytes) / secs(s0, s1) / 1e9; if (g > bH) bH = g;
                }
                for (int it = 0; it < bwIters; it++) {
                    auto s0 = Clock::now(); b.sync(vrt::SyncType::DEVICE_TO_HOST); auto s1 = Clock::now();
                    const double g = static_cast<double>(bytes) / secs(s0, s1) / 1e9; if (g > bD) bD = g;
                }
                if (bH > bestH2D) bestH2D = bH; if (bD > bestD2H) bestD2H = bD;
                std::cout << "      " << std::setw(4) << mb << " MB" << std::setprecision(2)
                          << std::setw(11) << bH << " GB/s" << std::setw(11) << bD << " GB/s\n";
            } catch (const std::exception& e) {
                std::cout << "      " << std::setw(4) << mb << " MB   FAILED: " << e.what() << "\n";
                record("qdma-bw " + std::to_string(mb) + "MB", false, e.what());
            }
        }

        std::cout << "\n[3] Kernel<->DDR CORRECTNESS\n----------------------------\n";
        {
            const size_t words = (quick ? 1 : 4) * MB / BYTES_PER_WORD;
            const size_t n = words * U32_PER_WORD;
            bool okW = false; std::string noteW;
            try {
                vrt::Buffer<uint32_t> b(device, n, k.argMemoryConfig("gmem0"));
                for (size_t j = 0; j < n; j++) b[j] = 0xA5A5A5A5u;
                b.sync(vrt::SyncType::HOST_TO_DEVICE);
                k.setArg(0, static_cast<uint32_t>(0));
                k.setArg(1, static_cast<uint32_t>(words));
                k.setArg(2, b);
                std::cout << "    running write (" << words << " words)..." << std::flush;
                k.start();
                if (!waitKernel(k)) throw std::runtime_error("mem_bw WRITE timeout (no ap_done in 15 s)");
                std::cout << " done\n";
                b.sync(vrt::SyncType::DEVICE_TO_HOST);
                size_t bad = 0, firstBad = 0;
                for (size_t i = 0; i < words; i++) {
                    if (b[i * U32_PER_WORD] != static_cast<uint32_t>(i)) { if (!bad) firstBad = i; bad++; continue; }
                    for (size_t kk = 1; kk < U32_PER_WORD; kk++)
                        if (b[i * U32_PER_WORD + kk] != 0u) { if (!bad) firstBad = i; bad++; break; }
                }
                okW = (bad == 0);
                if (!okW) noteW = std::to_string(bad) + " bad word(s), first #" + std::to_string(firstBad);
            } catch (const std::exception& e) { noteW = std::string("EXC: ") + e.what(); }
            std::cout << "    write-pattern   : " << (okW ? "PASS" : ("FAIL  " + noteW)) << "\n";
            record("kernel-ddr write", okW, noteW);
            bool okR = false; std::string noteR;
            try {
                vrt::Buffer<uint32_t> b(device, n, k.argMemoryConfig("gmem0"));
                for (size_t j = 0; j < n; j++) b[j] = pat(j);
                uint32_t expect[U32_PER_WORD] = {0};
                for (size_t i = 0; i < words; i++)
                    for (size_t kk = 0; kk < U32_PER_WORD; kk++)
                        expect[kk] ^= pat(i * U32_PER_WORD + kk);
                b.sync(vrt::SyncType::HOST_TO_DEVICE);
                k.setArg(0, static_cast<uint32_t>(1));
                k.setArg(1, static_cast<uint32_t>(words));
                k.setArg(2, b);
                std::cout << "    running read  (" << words << " words)..." << std::flush;
                k.start();
                if (!waitKernel(k)) throw std::runtime_error("mem_bw READ timeout (no ap_done in 15 s)");
                std::cout << " done\n";
                b.sync(vrt::SyncType::DEVICE_TO_HOST);
                size_t bad = 0;
                for (size_t kk = 0; kk < U32_PER_WORD; kk++) if (b[kk] != expect[kk]) bad++;
                okR = (bad == 0);
                if (!okR) noteR = std::to_string(bad) + "/16 accumulator lanes wrong";
            } catch (const std::exception& e) { noteR = std::string("EXC: ") + e.what(); }
            std::cout << "    read-accumulate : " << (okR ? "PASS" : ("FAIL  " + noteR)) << "\n";
            record("kernel-ddr read", okR, noteR);
        }

        std::cout << "\n[4] Kernel<->DDR BANDWIDTH (on-card, 512-bit ports, PCIe excluded)\n------------------------------------------------------------------\n";
        try {
            const size_t mb = quick ? 32 : 128;
            const size_t words = mb * MB / BYTES_PER_WORD;
            const size_t n = words * U32_PER_WORD;
            const int iters = quick ? 3 : 5;
            const double bytes = static_cast<double>(words) * BYTES_PER_WORD;
            vrt::Kernel* ks[2] = { &k, &k1 };
            vrt::Buffer<uint32_t> b0(device, n, k .argMemoryConfig("gmem0"));
            vrt::Buffer<uint32_t> b1(device, n, k1.argMemoryConfig("gmem0"));
            vrt::Buffer<uint32_t>* bs[2] = { &b0, &b1 };
            for (size_t j = 0; j < n; j++) { b0[j] = pat(j); b1[j] = pat(j); }
            b0.sync(vrt::SyncType::HOST_TO_DEVICE);
            b1.sync(vrt::SyncType::HOST_TO_DEVICE);

            auto runPorts = [&](int count, uint32_t mode) -> double {
                double best = 0.0;
                for (int it = 0; it < iters; it++) {
                    for (int i = 0; i < count; i++) {
                        ks[i]->setArg(0, mode);
                        ks[i]->setArg(1, static_cast<uint32_t>(words));
                        ks[i]->setArg(2, *bs[i]);
                    }
                    auto s0 = Clock::now();
                    for (int i = 0; i < count; i++) ks[i]->start();
                    for (int i = 0; i < count; i++)
                        if (!waitKernel(*ks[i]))
                            throw std::runtime_error("timeout: mode " + std::to_string(mode) +
                                                     ", " + std::to_string(count) + " port(s)");
                    auto s1 = Clock::now();
                    const double g = bytes * count / secs(s0, s1) / 1e9;
                    if (g > best) best = g;
                }
                return best;
            };

            std::cout << "    buffer: " << mb << " MB per port\n    running 1 port ..." << std::flush;
            ddrWrite  = runPorts(1, 0);
            ddrRead   = runPorts(1, 1);
            std::cout << " done\n    running 2 ports..." << std::flush;
            ddrWrite2 = runPorts(2, 0);
            ddrRead2  = runPorts(2, 1);
            std::cout << " done\n";
            std::cout << "                     " << std::setw(10) << "1 port" << std::setw(10) << "2 ports\n";
            std::cout << "    Write (GB/s) : " << std::setprecision(2)
                      << std::setw(10) << ddrWrite << std::setw(10) << ddrWrite2 << "\n";
            std::cout << "    Read  (GB/s) : " << std::setprecision(2)
                      << std::setw(10) << ddrRead  << std::setw(10) << ddrRead2  << "\n";
            record("ddr-bw write 1port", ddrWrite  > 0.0, std::to_string(ddrWrite)  + " GB/s");
            record("ddr-bw read 1port",  ddrRead   > 0.0, std::to_string(ddrRead)   + " GB/s");
            record("ddr-bw write 2port", ddrWrite2 > 0.0, std::to_string(ddrWrite2) + " GB/s");
            record("ddr-bw read 2port",  ddrRead2  > 0.0, std::to_string(ddrRead2)  + " GB/s");
        } catch (const std::exception& e) { std::cout << " FAILED: " << e.what() << "\n"; record("ddr-bw", false, e.what()); }

        std::cout << "\n[5] Kernel execution latency vs size (read)\n-------------------------------------------\n";
        std::cout << "      " << std::setw(6) << "Size" << std::setw(12) << "time" << std::setw(14) << "BW\n";
        std::vector<size_t> latMB = quick ? std::vector<size_t>{ 1, 16 } : std::vector<size_t>{ 1, 4, 16, 64, 256 };
        for (size_t mb : latMB) {
            try {
                const size_t words = mb * MB / BYTES_PER_WORD, n = words * U32_PER_WORD;
                vrt::Buffer<uint32_t> b(device, n, k.argMemoryConfig("gmem0"));
                for (size_t j = 0; j < n; j++) b[j] = pat(j);
                b.sync(vrt::SyncType::HOST_TO_DEVICE);
                k.setArg(0, static_cast<uint32_t>(1)); k.setArg(1, static_cast<uint32_t>(words)); k.setArg(2, b);
                double bestS = 1e30;
                for (int it = 0; it < (quick ? 2 : 3); it++) {
                    auto s0 = Clock::now(); k.start();
                    if (!waitKernel(k)) throw std::runtime_error("timeout at " + std::to_string(mb) + " MB");
                    auto s1 = Clock::now();
                    if (secs(s0, s1) < bestS) bestS = secs(s0, s1);
                }
                const double g = static_cast<double>(words * BYTES_PER_WORD) / bestS / 1e9;
                std::cout << "      " << std::setw(4) << mb << " MB" << std::setprecision(3)
                          << std::setw(9) << bestS * 1e3 << " ms" << std::setprecision(2) << std::setw(9) << g << " GB/s\n";
            } catch (const std::exception& e) {
                std::cout << "      " << std::setw(4) << mb << " MB   FAILED: " << e.what() << "\n";
            }
        }

        std::cout << "\n========================== SUMMARY ==========================\n";
        size_t passN = 0, failN = 0;
        for (const auto& r : g_results) (r.pass ? passN : failN)++;
        std::cout << "  Correctness / checks : " << passN << " passed, " << failN << " failed\n";
        if (failN) {
            std::cout << "  FAILURES:\n";
            for (const auto& r : g_results) if (!r.pass) std::cout << "    - " << r.name << (r.note.empty() ? "" : ("  (" + r.note + ")")) << "\n";
        }
        std::cout << std::setprecision(2);
        std::cout << "  QDMA host->card peak : " << bestH2D   << " GB/s\n";
        std::cout << "  QDMA card->host peak : " << bestD2H   << " GB/s\n";
        std::cout << "  DDR write  (1 / 2 p) : " << ddrWrite  << " / " << ddrWrite2 << " GB/s\n";
        std::cout << "  DDR read   (1 / 2 p) : " << ddrRead   << " / " << ddrRead2  << " GB/s\n";
        std::cout << "  ---------------------------------------------------------\n";
        std::cout << "  Reference: DDR4-2666 single channel = 21.3 GB/s peak\n";
        std::cout << "             (72 bits = 64 data + 8 ECC; ECC is not payload).\n";
        std::cout << "  Expected here (compute shell, 16 GB DIMM, 2026-10-13): write ~14.2\n";
        std::cout << "  (1 or 2 ports), read ~9.4 (1) / ~14.6 (2); QDMA H2D ~13, D2H ~9.8 GB/s.\n";
        std::cout << "  All DDR traffic -- both kernels AND QDMA -- shares ONE door into the\n";
        std::cout << "  DDRMC, so writes do not scale with port count and the aggregate stays\n";
        std::cout << "  near ~14.5 no matter how many kernels run. The Gen5 x8 link (~31.5 GB/s)\n";
        std::cout << "  is not the limit.\n";
        std::cout << "  VERDICT: " << (failN == 0 ? "ALL CHECKS PASSED" : "SOME CHECKS FAILED (see above)") << "\n";
        std::cout << "=============================================================\n\n";
        device.cleanup();
        return failN == 0 ? 0 : 1;
    } catch (const std::exception& e) {
        std::cerr << "\nFATAL: " << e.what() << std::endl;
        return 1;
    }
}
