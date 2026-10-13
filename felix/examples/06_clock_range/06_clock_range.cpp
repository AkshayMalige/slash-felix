#include <vrt/device.hpp>
#include <vrt/kernel.hpp>

#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <string>
#include <vector>

namespace {

constexpr uint32_t OUT_DATA = 0x18;
constexpr uint32_t OUT_CTRL = 0x1c;

constexpr double RUN_SECONDS = 2.0;
constexpr double MEASURE_TOL = 0.005;
constexpr double PROGRAM_TOL = 0.01;

uint32_t model(uint64_t cycles) {
    uint32_t acc = 0;
    for (uint64_t i = 0; i < cycles; ++i) {
        acc = (acc >> 1) ^ static_cast<uint32_t>(i);
    }
    return acc;
}

}

int main(int argc, char *argv[]) {
    if (argc < 3) {
        std::cerr << "Usage: " << argv[0] << " <BDF> <vbin> [MHz ...]\n";
        return 2;
    }
    std::vector<double> mhz;
    for (int i = 3; i < argc; ++i) {
        mhz.push_back(std::atof(argv[i]));
    }
    if (mhz.empty()) {
        mhz = {100, 156.25, 200, 240.474, 250, 300, 320, 350, 400};
    }

    try {
        vrt::Device device(argv[1], argv[2]);
        vrt::Kernel k(device, "clk_count_0");
        std::cout << "vbin linked for " << device.getMaxFrequency() / 1e6 << " MHz\n\n"
                  << " requested   read-back    measured   result\n";

        int failures = 0;
        for (double f : mhz) {
            const uint64_t req_hz = static_cast<uint64_t>(std::llround(f * 1e6));
            device.setFrequency(req_hz);
            const double rb_hz = static_cast<double>(device.getFrequency());
            const uint64_t cycles = static_cast<uint64_t>(rb_hz * RUN_SECONDS);

            k.setArg(0, cycles);
            const auto t0 = std::chrono::steady_clock::now();
            k.start();
            k.wait();
            const double secs =
                std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
            const double meas_hz = static_cast<double>(cycles) / secs;

            const bool valid = (k.read(OUT_CTRL) & 1u) != 0;
            const bool correct = valid && k.read(OUT_DATA) == model(cycles);
            const bool programmed = std::fabs(rb_hz - req_hz) <= PROGRAM_TOL * req_hz;
            const bool measured = std::fabs(meas_hz - rb_hz) <= MEASURE_TOL * rb_hz;
            const bool ok = correct && programmed && measured;
            failures += ok ? 0 : 1;

            std::cout << std::fixed << std::setprecision(3) << std::setw(10) << req_hz / 1e6
                      << std::setw(12) << rb_hz / 1e6 << std::setw(12) << meas_hz / 1e6 << "   "
                      << (ok ? "OK" : "FAIL")
                      << (correct ? "" : " (wrong kernel result)")
                      << (programmed ? "" : " (clock not at request)")
                      << (measured ? "" : " (measured != read-back)") << "\n";
        }
        std::cout << "\nCLOCK_RANGE: " << (failures == 0 ? "PASS" : "FAIL") << "\n";
        return failures == 0 ? 0 : 1;
    } catch (const std::exception &e) {
        std::cerr << "06_clock_range: " << e.what() << "\n";
        std::cout << "CLOCK_RANGE: ERROR\n";
        return 2;
    }
}
