#pragma once

// A small test harness, deliberately dependency-free.
//
// The core must cross-compile to Android and iOS without pulling anything in,
// and fetching a framework at configure time would put a network step in a
// build that otherwise has none. This covers what the ported Swift tests need:
// named suites and cases, expectations that report file and line, and a
// non-zero exit when anything fails. Swap it for GoogleTest later if the core's
// test needs outgrow it.

#include <cstdio>
#include <exception>
#include <functional>
#include <string>
#include <vector>

namespace voxscripta::testing {

struct TestCase {
    std::string suite;
    std::string name;
    std::function<void()> body;
};

inline std::vector<TestCase>& registry() {
    static std::vector<TestCase> cases;
    return cases;
}

inline int& failure_count() {
    static int count = 0;
    return count;
}

struct Registrar {
    Registrar(const char* suite, const char* name, std::function<void()> body) {
        registry().push_back({suite, name, std::move(body)});
    }
};

inline void report_failure(const char* file, int line, const std::string& detail) {
    std::printf("    FAIL %s:%d\n         %s\n", file, line, detail.c_str());
    ++failure_count();
}

inline int run_all() {
    std::string current_suite;
    int passed = 0;
    for (const auto& test : registry()) {
        if (test.suite != current_suite) {
            current_suite = test.suite;
            std::printf("\n%s\n", current_suite.c_str());
        }
        const int before = failure_count();
        try {
            test.body();
        } catch (const std::exception& error) {
            report_failure(__FILE__, 0,
                           "unexpected exception: " + std::string(error.what()));
        } catch (...) {
            report_failure(__FILE__, 0, "unexpected non-standard exception");
        }
        const bool ok = failure_count() == before;
        std::printf("  %s %s\n", ok ? "\xE2\x9C\x94" : "\xE2\x9C\x98", test.name.c_str());
        if (ok) ++passed;
    }
    const int failed = static_cast<int>(registry().size()) - passed;
    std::printf("\n%d of %zu tests passed%s\n", passed, registry().size(),
                failed ? "" : " \xE2\x80\x94 all green");
    return failed == 0 ? 0 : 1;
}

}  // namespace voxscripta::testing

#define VS_CONCAT_INNER(a, b) a##b
#define VS_CONCAT(a, b) VS_CONCAT_INNER(a, b)

#define VS_TEST(suite_name, case_name)                                                     \
    static void VS_CONCAT(vs_test_body_, __LINE__)();                                      \
    static const ::voxscripta::testing::Registrar VS_CONCAT(vs_test_reg_, __LINE__)(       \
        suite_name, case_name, VS_CONCAT(vs_test_body_, __LINE__));                        \
    static void VS_CONCAT(vs_test_body_, __LINE__)()

#define VS_EXPECT(condition)                                                               \
    do {                                                                                   \
        if (!(condition)) {                                                                \
            ::voxscripta::testing::report_failure(__FILE__, __LINE__, #condition);         \
        }                                                                                  \
    } while (false)

#define VS_EXPECT_EQ(actual, expected)                                                     \
    do {                                                                                   \
        const auto vs_a = (actual);                                                        \
        const auto vs_b = (expected);                                                      \
        if (!(vs_a == vs_b)) {                                                             \
            ::voxscripta::testing::report_failure(                                         \
                __FILE__, __LINE__,                                                        \
                std::string(#actual) + " == " + #expected);                                \
        }                                                                                  \
    } while (false)

/// Asserts that evaluating the expression throws the named exception type.
#define VS_EXPECT_THROWS(expression, exception_type)                                       \
    do {                                                                                   \
        bool vs_threw = false;                                                             \
        try {                                                                              \
            (void)(expression);                                                            \
        } catch (const exception_type&) {                                                  \
            vs_threw = true;                                                               \
        } catch (...) {                                                                    \
        }                                                                                  \
        if (!vs_threw) {                                                                   \
            ::voxscripta::testing::report_failure(                                         \
                __FILE__, __LINE__,                                                        \
                std::string(#expression) + " did not throw " + #exception_type);           \
        }                                                                                  \
    } while (false)
