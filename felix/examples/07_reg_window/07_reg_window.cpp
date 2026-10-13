#include <vrt/device.hpp>
#include <vrt/kernel.hpp>

#include <cstdint>
#include <cstdio>
#include <exception>
#include <random>

namespace {
constexpr int N = 24;
constexpr uint32_t ARG0 = 0x10, ARG_STRIDE = 8;
constexpr uint32_t SUM_DATA = 0xd0, SUM_CTRL = 0xd4;
}

int main(int argc, char *argv[]) {
    if (argc < 3) {
        std::fprintf(stderr, "Usage: %s <BDF> <vbin>\n", argv[0]);
        return 2;
    }
    try {
        vrt::Device device(argv[1], argv[2]);
        vrt::Kernel k(device, "reg_window_0");

        int failures = 0;
        std::mt19937 rng(0xFE11C5u);
        for (int round = 0; round < 3; ++round) {
            uint32_t v[N];
            uint32_t want = 0;
            for (int i = 0; i < N; ++i) {
                v[i] = static_cast<uint32_t>(rng());
                want += v[i] * static_cast<uint32_t>(2 * i + 1);
                k.setArg(i, v[i]);
            }
            k.start();
            k.wait();
            const bool valid = (k.read(SUM_CTRL) & 1u) != 0;
            const uint32_t got = k.read(SUM_DATA);

            int readback_bad = 0;
            for (int i = 0; i < N; ++i) {
                const uint32_t off = ARG0 + ARG_STRIDE * static_cast<uint32_t>(i);
                const uint32_t r = k.read(off);
                if (r != v[i]) {
                    std::printf("  round %d: register 0x%02x (a%d) reads 0x%08x, wrote 0x%08x%s\n", round, off,
                                i, r, v[i], (off >= 0x40 && off <= 0xbf) ? "  [0x40-0xBF window]" : "");
                    ++readback_bad;
                }
            }
            const bool ok = valid && got == want && readback_bad == 0;
            std::printf("round %d: kernel sum 0x%08x, expected 0x%08x, %d/%d registers read back -> %s\n", round,
                        got, want, N - readback_bad, N, ok ? "OK" : "FAIL");
            failures += ok ? 0 : 1;
        }
        std::printf("registers 0x40-0xBF (a6..a21) written by the host and used by the kernel: %s\n",
                    failures == 0 ? "yes" : "NO");
        std::printf("REG_WINDOW: %s\n", failures == 0 ? "PASS" : "FAIL");
        return failures == 0 ? 0 : 1;
    } catch (const std::exception &e) {
        std::fprintf(stderr, "07_reg_window: %s\n", e.what());
        std::printf("REG_WINDOW: ERROR\n");
        return 2;
    }
}
