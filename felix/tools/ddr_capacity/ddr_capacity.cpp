#include <vrtd/buffer.hpp>
#include <vrtd/device.hpp>
#include <vrtd/error.hpp>
#include <vrtd/session.hpp>

#include <chrono>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <string>

namespace {

constexpr uint64_t DDR_BASE    = 0x60000000000ULL;
constexpr uint64_t REGION      = 512ULL << 20;
constexpr uint64_t FELIX_SIZE  = 14ULL << 30;
constexpr int      MAX_REPORTS = 4;
constexpr uint64_t PROBE_OFF   = 256ULL << 20;
constexpr uint64_t PROBE_SIZE  = 4096;

struct Pass {
    const char *name;
    vrtd::MmChannel write_ch;
    vrtd::MmChannel read_ch;
    uint64_t key;
};

double gbps(uint64_t bytes, std::chrono::steady_clock::duration d) {
    return static_cast<double>(bytes) / 1e9 / std::chrono::duration<double>(d).count();
}

void fill(uint64_t *words, uint64_t addr, uint64_t key) {
    for (uint64_t i = 0; i < REGION / 8; ++i) {
        words[i] = (addr + i * 8) ^ key;
    }
}

uint64_t check(const uint64_t *words, uint64_t addr, uint64_t key) {
    uint64_t bad = 0;
    for (uint64_t i = 0; i < REGION / 8; ++i) {
        const uint64_t want = (addr + i * 8) ^ key;
        if (words[i] != want) {
            if (bad < MAX_REPORTS) {
                std::printf("    MISMATCH @0x%" PRIx64 ": got 0x%016" PRIx64 " want 0x%016" PRIx64
                            "  (got = pattern of 0x%" PRIx64 ")\n",
                            addr + i * 8, words[i], want, words[i] ^ key);
            }
            ++bad;
        }
    }
    return bad;
}

bool parse_size(const char *s, uint64_t *out) {
    char *end = nullptr;
    const unsigned long long v = std::strtoull(s, &end, 10);
    uint64_t mul = 1;
    if (*end == 'G' || *end == 'g') { mul = 1ULL << 30; ++end; }
    else if (*end == 'M' || *end == 'm') { mul = 1ULL << 20; ++end; }
    if (*end != '\0' || v == 0) {
        return false;
    }
    *out = v * mul;
    return true;
}

uint64_t probe_aliases(const vrtd::Device &dev, uint64_t size) {
    const uint64_t regions = size / REGION;
    auto addr_of = [](uint64_t r) { return DDR_BASE + r * REGION + PROBE_OFF; };
    auto read_block = [&](uint64_t r, uint64_t *out) {
        vrtd::Buffer b = dev.openRawBuffer(addr_of(r), PROBE_SIZE, vrtd::BufferAllocDir::DeviceToHost,
                                           vrtd::MmChannel::Ch1);
        b.syncFromDevice(0, PROBE_SIZE);
        std::memcpy(out, b.data(), PROBE_SIZE);
    };
    auto write_block = [&](uint64_t r, const uint64_t *in) {
        vrtd::Buffer b = dev.openRawBuffer(addr_of(r), PROBE_SIZE, vrtd::BufferAllocDir::HostToDevice,
                                           vrtd::MmChannel::Ch0);
        std::memcpy(b.data(), in, PROBE_SIZE);
        b.syncToDevice(0, PROBE_SIZE);
    };

    std::printf("alias probe: %" PRIu64 " regions, 4 KB each at +256 MB, contents restored\n", regions);
    uint64_t saved[PROBE_SIZE / 8], tag[PROBE_SIZE / 8], seen[PROBE_SIZE / 8];
    uint64_t aliased = 0;
    for (uint64_t r = 0; r < regions; ++r) {
        read_block(r, saved);
        for (uint64_t i = 0; i < PROBE_SIZE / 8; ++i) {
            tag[i] = (addr_of(r) + i * 8) ^ 0xC3C3C3C3C3C3C3C3ULL;
        }
        write_block(r, tag);
        int64_t alias_of = -1;
        for (uint64_t q = 0; q < regions && alias_of < 0; ++q) {
            if (q == r) {
                continue;
            }
            read_block(q, seen);
            if (std::memcmp(seen, tag, PROBE_SIZE) == 0) {
                alias_of = static_cast<int64_t>(q);
            }
        }
        write_block(r, saved);
        if (alias_of >= 0) {
            std::printf("  region %2" PRIu64 " @0x%" PRIx64 " ALIASES region %2" PRId64 " @0x%" PRIx64
                        " (%+.1f GB)\n", r, DDR_BASE + r * REGION, alias_of,
                        DDR_BASE + static_cast<uint64_t>(alias_of) * REGION,
                        (static_cast<double>(alias_of) - static_cast<double>(r)) / 2.0);
            ++aliased;
        }
    }
    std::printf("  %" PRIu64 " of %" PRIu64 " regions share memory with another region\n", aliased, regions);
    return aliased;
}

uint64_t run_pass(const vrtd::Device &dev, const Pass &p, uint64_t size) {
    const uint64_t regions = size / REGION;
    std::printf("%s: write %" PRIu64 " x 512 MB on channel %d, then read all on channel %d\n",
                p.name, regions, p.write_ch == vrtd::MmChannel::Ch0 ? 0 : 1,
                p.read_ch == vrtd::MmChannel::Ch0 ? 0 : 1);

    auto t0 = std::chrono::steady_clock::now();
    std::chrono::steady_clock::duration dma{};
    for (uint64_t r = 0; r < regions; ++r) {
        const uint64_t addr = DDR_BASE + r * REGION;
        vrtd::Buffer buf = dev.openRawBuffer(addr, REGION, vrtd::BufferAllocDir::HostToDevice, p.write_ch);
        fill(static_cast<uint64_t *>(buf.data()), addr, p.key);
        auto s = std::chrono::steady_clock::now();
        buf.syncToDevice(0, REGION);
        dma += std::chrono::steady_clock::now() - s;
    }
    std::printf("  wrote %" PRIu64 " GB  (DMA %.2f GB/s, total %.0f s)\n", size >> 30, gbps(size, dma),
                std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count());

    uint64_t failed = 0;
    t0 = std::chrono::steady_clock::now();
    dma = {};
    for (uint64_t r = 0; r < regions; ++r) {
        const uint64_t addr = DDR_BASE + r * REGION;
        vrtd::Buffer buf = dev.openRawBuffer(addr, REGION, vrtd::BufferAllocDir::DeviceToHost, p.read_ch);
        std::memset(buf.data(), 0, REGION);
        auto s = std::chrono::steady_clock::now();
        buf.syncFromDevice(0, REGION);
        dma += std::chrono::steady_clock::now() - s;
        const uint64_t bad = check(static_cast<const uint64_t *>(buf.data()), addr, p.key);
        if (bad != 0) {
            std::printf("  region %2" PRIu64 " @0x%" PRIx64 ": FAIL (%" PRIu64 " bad words)\n", r, addr, bad);
            ++failed;
        }
    }
    std::printf("  read  %" PRIu64 " GB  (DMA %.2f GB/s, total %.0f s): %" PRIu64 "/%" PRIu64 " regions OK\n",
                size >> 30, gbps(size, dma),
                std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count(),
                regions - failed, regions);
    return failed;
}

}

int main(int argc, char **argv) {
    std::string bdf;
    uint64_t size = FELIX_SIZE;
    bool probe_only = false;
    for (int i = 1; i < argc; ++i) {
        const std::string a = argv[i];
        if ((a == "-d" || a == "--device") && i + 1 < argc) {
            bdf = argv[++i];
            if (const auto dot = bdf.rfind('.'); dot != std::string::npos) {
                bdf.resize(dot);
            }
        } else if (a == "--probe-only") {
            probe_only = true;
        } else if (a == "--size" && i + 1 < argc) {
            if (!parse_size(argv[++i], &size)) {
                std::fprintf(stderr, "bad --size '%s' (e.g. 14G, 1024M)\n", argv[i]);
                return 2;
            }
        } else {
            std::fprintf(stderr, "usage: %s [-d <BDF>] [--size <N>G] [--probe-only]   (default size 14G)\n",
                         argv[0]);
            return 2;
        }
    }
    if (size % REGION != 0 || size > FELIX_SIZE) {
        std::fprintf(stderr, "--size must be a multiple of 512M and at most 14G (FELIX has no DDR above "
                             "0x%" PRIx64 ")\n", DDR_BASE + FELIX_SIZE);
        return 2;
    }

    try {
        vrtd::Session session;
        const vrtd::Device dev = bdf.empty() ? session.getDevice(0) : session.getDeviceByBdf(bdf);
        std::printf("ddr_capacity: device %s, 0x%" PRIx64 " .. 0x%" PRIx64 " (%" PRIu64 " GB)\n",
                    dev.getBdf().c_str(), DDR_BASE, DDR_BASE + size, size >> 30);

        if (probe_aliases(dev, size) != 0) {
            std::printf("DDR_CAPACITY: FAIL (aliasing; full test skipped -- it would overwrite the aliased memory)\n");
            return 1;
        }
        if (probe_only) {
            std::printf("DDR_CAPACITY: PROBE PASS (no aliasing; full test not run)\n");
            return 0;
        }

        const Pass passes[] = {
            {"pass 1", vrtd::MmChannel::Ch0, vrtd::MmChannel::Ch1, 0x5A5A5A5A5A5A5A5AULL},
            {"pass 2", vrtd::MmChannel::Ch1, vrtd::MmChannel::Ch0, ~0x5A5A5A5A5A5A5A5AULL},
        };
        uint64_t failed = 0;
        for (const Pass &p : passes) {
            failed += run_pass(dev, p, size);
        }
        std::printf("%s\n", failed == 0 ? "DDR_CAPACITY: PASS" : "DDR_CAPACITY: FAIL");
        return failed == 0 ? 0 : 1;
    } catch (const std::exception &e) {
        std::fprintf(stderr, "ddr_capacity: %s\n", e.what());
        std::printf("DDR_CAPACITY: ERROR\n");
        return 2;
    }
}
