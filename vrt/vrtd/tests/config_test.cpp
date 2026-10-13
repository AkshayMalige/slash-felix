/**
 * The MIT License (MIT)
 * Copyright (c) 2025-2026 Advanced Micro Devices, Inc. All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy of this software
 * and associated documentation files (the "Software"), to deal in the Software without restriction,
 * including without limitation the rights to use, copy, modify, merge, publish, distribute,
 * sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all copies or
 * substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT
 * NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
 * DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

#include <gtest/gtest.h>

#include <cstring>

extern "C" {
#include "config.h"
}

static struct device_policy *make_device_policy(const char *bdf, bool bar, bool qdma, bool buffer,
                                                bool design_write, bool cfgmem_program, bool clock,
                                                bool pcie_hotplug, bool raw_mem_access) {
    auto *dp = static_cast<struct device_policy *>(calloc(1, sizeof(struct device_policy)));
    dp->bdf = strdup(bdf);
    dp->bar = bar;
    dp->qdma = qdma;
    dp->buffer = buffer;
    dp->design_write = design_write;
    dp->cfgmem_program = cfgmem_program;
    dp->clock = clock;
    dp->pcie_hotplug = pcie_hotplug;
    dp->raw_mem_access = raw_mem_access;
    return dp;
}

// --- role_merge_new ---

TEST(RoleMergeTest, NewCreatesEmptyRole) {
    struct role *r = nullptr;
    ASSERT_EQ(role_merge_new(&r, "test_role"), 0);
    ASSERT_NE(r, nullptr);
    EXPECT_STREQ(r->name, "test_role");
    EXPECT_FALSE(r->query);
    EXPECT_EQ(r->device_policies.len, 0u);
    cleanup_role(r);
}

// --- role_merge_add_role ---

TEST(RoleMergeTest, MergeQueryFlag) {
    struct role *dst = nullptr;
    struct role *src = nullptr;
    ASSERT_EQ(role_merge_new(&dst, "dst"), 0);
    ASSERT_EQ(role_merge_new(&src, "src"), 0);

    EXPECT_FALSE(dst->query);
    src->query = true;

    ASSERT_EQ(role_merge_add_role(dst, src), 0);
    EXPECT_TRUE(dst->query);

    cleanup_role(src);
    cleanup_role(dst);
}

TEST(RoleMergeTest, MergeQueryOrSemantics) {
    struct role *dst = nullptr;
    struct role *src = nullptr;
    ASSERT_EQ(role_merge_new(&dst, "dst"), 0);
    ASSERT_EQ(role_merge_new(&src, "src"), 0);

    dst->query = true;
    src->query = false;

    ASSERT_EQ(role_merge_add_role(dst, src), 0);
    EXPECT_TRUE(dst->query);

    cleanup_role(src);
    cleanup_role(dst);
}

TEST(RoleMergeTest, MergeDevicePolicies) {
    struct role *dst = nullptr;
    struct role *src = nullptr;
    ASSERT_EQ(role_merge_new(&dst, "dst"), 0);
    ASSERT_EQ(role_merge_new(&src, "src"), 0);

    struct device_policy *dp = make_device_policy("0000:03:00", true, false, true, false, false, false, false, false);
    struct device_policy *src_ptr = dp;
    ASSERT_EQ(device_policy_ptr_array_push_move(&src->device_policies, &src_ptr), 0);

    ASSERT_EQ(role_merge_add_role(dst, src), 0);

    ASSERT_EQ(dst->device_policies.len, 1u);
    EXPECT_STREQ(dst->device_policies.d[0]->bdf, "0000:03:00");
    EXPECT_TRUE(dst->device_policies.d[0]->bar);
    EXPECT_FALSE(dst->device_policies.d[0]->qdma);
    EXPECT_TRUE(dst->device_policies.d[0]->buffer);

    cleanup_role(src);
    cleanup_role(dst);
}

TEST(RoleMergeTest, MergeDevicePoliciesOrPerField) {
    struct role *dst = nullptr;
    struct role *src = nullptr;
    ASSERT_EQ(role_merge_new(&dst, "dst"), 0);
    ASSERT_EQ(role_merge_new(&src, "src"), 0);

    struct device_policy *dp1 = make_device_policy("0000:03:00", true, false, false, false, false, false, false, false);
    struct device_policy *ptr1 = dp1;
    ASSERT_EQ(device_policy_ptr_array_push_move(&dst->device_policies, &ptr1), 0);

    struct device_policy *dp2 = make_device_policy("0000:03:00", false, true, false, false, true, true, false, false);
    struct device_policy *ptr2 = dp2;
    ASSERT_EQ(device_policy_ptr_array_push_move(&src->device_policies, &ptr2), 0);

    ASSERT_EQ(role_merge_add_role(dst, src), 0);

    ASSERT_EQ(dst->device_policies.len, 1u);
    EXPECT_TRUE(dst->device_policies.d[0]->bar);
    EXPECT_TRUE(dst->device_policies.d[0]->qdma);
    EXPECT_TRUE(dst->device_policies.d[0]->cfgmem_program);
    EXPECT_TRUE(dst->device_policies.d[0]->clock);

    cleanup_role(src);
    cleanup_role(dst);
}

TEST(RoleMergeTest, MergeDevicePoliciesDifferentBdf) {
    struct role *dst = nullptr;
    struct role *src = nullptr;
    ASSERT_EQ(role_merge_new(&dst, "dst"), 0);
    ASSERT_EQ(role_merge_new(&src, "src"), 0);

    struct device_policy *dp1 = make_device_policy("0000:03:00", true, false, false, false, false, false, false, false);
    struct device_policy *ptr1 = dp1;
    ASSERT_EQ(device_policy_ptr_array_push_move(&dst->device_policies, &ptr1), 0);

    struct device_policy *dp2 = make_device_policy("0000:04:00", false, true, false, false, false, false, false, false);
    struct device_policy *ptr2 = dp2;
    ASSERT_EQ(device_policy_ptr_array_push_move(&src->device_policies, &ptr2), 0);

    ASSERT_EQ(role_merge_add_role(dst, src), 0);

    ASSERT_EQ(dst->device_policies.len, 2u);

    cleanup_role(src);
    cleanup_role(dst);
}

TEST(RoleMergeTest, MergeWildcardPolicy) {
    struct role *dst = nullptr;
    struct role *src = nullptr;
    ASSERT_EQ(role_merge_new(&dst, "dst"), 0);
    ASSERT_EQ(role_merge_new(&src, "src"), 0);

    struct device_policy *dp = make_device_policy("any", true, true, true, true, true, true, true, true);
    struct device_policy *ptr = dp;
    ASSERT_EQ(device_policy_ptr_array_push_move(&src->device_policies, &ptr), 0);

    ASSERT_EQ(role_merge_add_role(dst, src), 0);

    ASSERT_EQ(dst->device_policies.len, 1u);
    EXPECT_STREQ(dst->device_policies.d[0]->bdf, "any");
    EXPECT_TRUE(dst->device_policies.d[0]->bar);
    EXPECT_TRUE(dst->device_policies.d[0]->cfgmem_program);
    EXPECT_TRUE(dst->device_policies.d[0]->raw_mem_access);

    cleanup_role(src);
    cleanup_role(dst);
}

// --- role_merge_add_array ---

TEST(RoleMergeTest, MergeArray) {
    struct role *dst = nullptr;
    ASSERT_EQ(role_merge_new(&dst, "dst"), 0);

    struct role *r1 = nullptr;
    struct role *r2 = nullptr;
    ASSERT_EQ(role_merge_new(&r1, "r1"), 0);
    ASSERT_EQ(role_merge_new(&r2, "r2"), 0);

    r1->query = true;

    struct device_policy *dp = make_device_policy("any", false, true, false, false, false, false, false, false);
    struct device_policy *ptr = dp;
    ASSERT_EQ(device_policy_ptr_array_push_move(&r2->device_policies, &ptr), 0);

    struct role_ref_array roles = role_ref_array_init();
    ASSERT_EQ(role_ref_array_push(&roles, r1), 0);
    ASSERT_EQ(role_ref_array_push(&roles, r2), 0);

    ASSERT_EQ(role_merge_add_array(dst, &roles), 0);

    EXPECT_TRUE(dst->query);
    ASSERT_EQ(dst->device_policies.len, 1u);
    EXPECT_TRUE(dst->device_policies.d[0]->qdma);

    role_ref_array_free(&roles);
    cleanup_role(r2);
    cleanup_role(r1);
    cleanup_role(dst);
}

// --- Cleanup functions ---

TEST(ConfigCleanupTest, CleanupDevicePolicyZeroed) {
    auto *dp = static_cast<struct device_policy *>(calloc(1, sizeof(struct device_policy)));
    cleanup_device_policy(dp);
}

TEST(ConfigCleanupTest, CleanupRoleZeroed) {
    auto *r = static_cast<struct role *>(calloc(1, sizeof(struct role)));
    cleanup_role(r);
}


#include <cstdio>
#include <cstdlib>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

static struct config *load_config_text(const std::string &text) {
    char path[] = "/tmp/vrtd_config_test_XXXXXX";
    int fd = mkstemp(path);
    if (fd < 0) {
        return nullptr;
    }
    if (write(fd, text.data(), text.size()) != (ssize_t)text.size()) {
        close(fd);
        unlink(path);
        return nullptr;
    }
    close(fd);
    setenv("VRTD_CONFIG", path, 1);
    struct config *config = nullptr;
    int ret = config_load(&config);
    unsetenv("VRTD_CONFIG");
    unlink(path);
    return ret == 0 ? config : nullptr;
}

TEST(ConfigDdrSizeTest, DefaultsToZero) {
    struct config *config = load_config_text("[role:info]\nquery-devices = yes\n");
    ASSERT_NE(config, nullptr);
    EXPECT_EQ(config->ddr_size, 0u);
    cleanup_configp(&config);
}

TEST(ConfigDdrSizeTest, ParsesBinarySuffixes) {
    const struct { const char *value; uint64_t bytes; } cases[] = {
        {"14G", 14ULL << 30}, {"14336M", 14ULL << 30}, {"14GiB", 14ULL << 30},
        {" 32g ", 32ULL << 30}, {"1073741824", 1ULL << 30},
    };
    for (const auto &c : cases) {
        struct config *config = load_config_text(std::string("ddr-size = ") + c.value + "\n");
        ASSERT_NE(config, nullptr) << c.value;
        EXPECT_EQ(config->ddr_size, c.bytes) << c.value;
        cleanup_configp(&config);
    }
}

TEST(ConfigDdrSizeTest, RejectsGarbage) {
    for (const char *bad : {"fourteen", "14X", "0", "-1G", ""}) {
        EXPECT_EQ(load_config_text(std::string("ddr-size = ") + bad + "\n"), nullptr) << bad;
    }
}

TEST(ConfigDdrSizeTest, ReadFromIncludedFile) {
    char dir[] = "/tmp/vrtd_config_dir_XXXXXX";
    ASSERT_NE(mkdtemp(dir), nullptr);
    const std::string base(dir);
    const std::string sub = base + "/vrtd.conf.d";
    ASSERT_EQ(mkdir(sub.c_str(), 0700), 0);
    FILE *f = std::fopen((base + "/vrtd.conf").c_str(), "w");
    ASSERT_NE(f, nullptr);
    std::fputs("include-glob = vrtd.conf.d/*.conf\n[role:info]\nquery-devices = yes\n", f);
    std::fclose(f);
    f = std::fopen((sub + "/felix.conf").c_str(), "w");
    ASSERT_NE(f, nullptr);
    std::fputs("ddr-size = 14G\n", f);
    std::fclose(f);

    setenv("VRTD_CONFIG", (base + "/vrtd.conf").c_str(), 1);
    struct config *config = nullptr;
    const int ret = config_load(&config);
    unsetenv("VRTD_CONFIG");
    std::remove((sub + "/felix.conf").c_str());
    rmdir(sub.c_str());
    std::remove((base + "/vrtd.conf").c_str());
    rmdir(dir);

    ASSERT_EQ(ret, 0);
    EXPECT_EQ(config->ddr_size, 14ULL << 30);
    cleanup_configp(&config);
}
