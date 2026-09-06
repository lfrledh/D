// Ownership regressions adapted from MLX PR #4453, pinned to its reviewed head:
// https://github.com/ml-explore/mlx/pull/4453
// https://github.com/tudalex/mlx/blob/5002b5ff6adff93a9a439d012e60773c171ec206/tests/array_tests.cpp
// The standalone runner, both assignment orders, and alias/self cases are D additions.
//
// MIT License
//
// Copyright © 2023 Apple Inc.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

// Build against the same MLX headers that produced Cmlx.o. Assignment and the
// patched destructor are inline: mixing old headers with a patched object (or
// vice versa) makes a before/after comparison invalid.
// Only CPU split primitives are evaluated. MLX's allocator can still initialize
// Metal on macOS; this program does not dispatch GPU computation or load models.
// The first two cases intentionally expose a bounded leak on unpatched MLX.
// They never evaluate arrays carrying the zero-byte lifetime marker.

#include <cstdint>
#include <exception>
#include <iostream>
#include <memory>
#include <utility>

#include "mlx/array.h"
#include "mlx/device.h"
#include "mlx/ops.h"
#include "mlx/stream.h"

namespace mx = mlx::core;

namespace {

struct Checks {
  int total = 0;
  int failed = 0;

  bool check(bool condition, const char* message) {
    ++total;
    if (!condition) {
      ++failed;
      std::cerr << "  FAIL: " << message << '\n';
    }
    return condition;
  }
};

using Tracker = std::weak_ptr<mx::array::Data>;

Tracker attach_lifetime_marker(mx::array& output) {
  output.set_data(mx::allocator::malloc(0));
  return output.data_shared_ptr();
}

// Return the only outside reference to a two-output lazy primitive. Track real
// input data in the evaluation cases, so no fake buffer can be read by eval.
mx::array last_split(mx::Stream cpu, Tracker& input_lifetime) {
  mx::array key({1, 2});
  input_lifetime = key.data_shared_ptr();
  auto outputs = mx::split(key, 2, 0, cpu);
  return outputs[0];
}

void copy_and_move_release_sibling_cycles(Checks& checks, mx::Stream cpu) {
  // Each assignment operator must release a cycle when it replaces the last
  // outside reference; testing only one order would miss one operator's leak.
  for (bool copy_last : {false, true}) {
    Tracker lifetime;
    {
      mx::array sink({3, 4});
      auto outputs = mx::split(mx::array({1, 2}), 2, 0, cpu);
      lifetime = attach_lifetime_marker(outputs[0]);
      checks.check(!lifetime.expired(), "marker starts alive");
      if (copy_last) {
        outputs[0] = mx::array({5, 6});
        outputs[1] = sink;
      } else {
        outputs[0] = sink;
        outputs[1] = mx::array({5, 6});
      }
    }
    checks.check(
        lifetime.expired(),
        copy_last ? "last copy assignment releases sibling cycle"
                  : "last move assignment releases sibling cycle");
  }
}

void overwrite_releases_last_sibling_reference(Checks& checks, mx::Stream cpu) {
  Tracker lifetime;
  {
    auto outputs = mx::split(mx::array({1, 2}), 2, 0, cpu);
    lifetime = attach_lifetime_marker(outputs[0]);
    mx::array last = outputs[0];
    outputs.clear();
    checks.check(!lifetime.expired(), "last outside reference keeps marker alive");
    last.overwrite_descriptor(mx::array({7, 8}));
  }
  checks.check(lifetime.expired(), "overwrite_descriptor releases sibling cycle");
}

void sibling_replacement_remains_evaluable(Checks& checks, mx::Stream cpu) {
  Tracker lifetime;
  {
    auto last = last_split(cpu, lifetime);
    if (!checks.check(last.siblings().size() == 1, "split has one sibling")) {
      return;
    }
    const auto sibling_id = last.siblings()[0].id();
    last = last.siblings()[0];
    if (!checks.check(last.id() == sibling_id, "assignment retains incoming sibling")) {
      return;
    }
    if (!checks.check(last.siblings().size() == 1, "sibling graph remains intact")) {
      return;
    }
    checks.check(!lifetime.expired(), "incoming sibling retains input data");
    checks.check(last.item<std::int32_t>() == 2, "incoming sibling evaluates to 2");
  }
  mx::synchronize(cpu);
  checks.check(lifetime.expired(), "evaluated sibling releases input data on destruction");
}

void check_self_assignment(
    Checks& checks, mx::Stream cpu, void (*assign)(mx::array&)) {
  Tracker lifetime;
  {
    auto last = last_split(cpu, lifetime);
    const auto original_id = last.id();
    assign(last);
    if (!checks.check(last.id() == original_id, "self assignment preserves descriptor")) {
      return;
    }
    checks.check(last.siblings().size() == 1, "self assignment preserves sibling graph");
    checks.check(!lifetime.expired(), "self assignment retains input data");
    checks.check(last.item<std::int32_t>() == 1, "self-assigned array evaluates to 1");
  }
  mx::synchronize(cpu);
  checks.check(lifetime.expired(), "self-assigned array releases input data on destruction");
}

void self_copy_preserves_ownership(Checks& checks, mx::Stream cpu) {
  check_self_assignment(checks, cpu, [](mx::array& value) {
    const auto& alias = value;
    value = alias;
  });
}

void self_move_preserves_ownership(Checks& checks, mx::Stream cpu) {
  check_self_assignment(checks, cpu, [](mx::array& value) {
    auto& alias = value;
    value = std::move(alias);
  });
}

void self_overwrite_preserves_ownership(Checks& checks, mx::Stream cpu) {
  check_self_assignment(checks, cpu, [](mx::array& value) {
    value.overwrite_descriptor(value);
  });
}

void shared_descriptor_keeps_live_aliases(Checks& checks, mx::Stream cpu) {
  Tracker lifetime;
  {
    auto last = last_split(cpu, lifetime);
    auto alias = last;
    const auto original_id = last.id();
    last = alias;
    checks.check(last.id() == original_id, "copy from shared descriptor preserves identity");
    last = std::move(alias);
    if (!checks.check(last.id() == original_id, "move from shared descriptor preserves identity")) {
      return;
    }
    checks.check(alias.id() == 0, "move empties distinct source sharing descriptor");
    auto keeper = last;
    last.overwrite_descriptor(keeper);
    checks.check(last.id() == original_id, "overwrite from shared descriptor preserves identity");
    last = mx::array({9});
    checks.check(!lifetime.expired(), "outside alias prevents premature input release");
    if (!checks.check(keeper.siblings().size() == 1, "outside alias preserves sibling graph")) {
      return;
    }
    checks.check(keeper.item<std::int32_t>() == 1, "outside alias remains evaluable");
    checks.check(last.item<std::int32_t>() == 9, "replacement has its independent value");
  }
  mx::synchronize(cpu);
  checks.check(lifetime.expired(), "final shared descriptor releases input data");
}

struct TestCase {
  const char* name;
  void (*run)(Checks&, mx::Stream);
};

} // namespace

int main() {
  const TestCase cases[] = {
      {"copy_and_move_release_sibling_cycles", copy_and_move_release_sibling_cycles},
      {"overwrite_releases_last_sibling_reference", overwrite_releases_last_sibling_reference},
      {"sibling_replacement_remains_evaluable", sibling_replacement_remains_evaluable},
      {"self_copy_preserves_ownership", self_copy_preserves_ownership},
      {"self_move_preserves_ownership", self_move_preserves_ownership},
      {"self_overwrite_preserves_ownership", self_overwrite_preserves_ownership},
      {"shared_descriptor_keeps_live_aliases", shared_descriptor_keeps_live_aliases},
  };

  try {
    mx::set_default_device(mx::Device::cpu);
    const auto cpu = mx::default_stream(mx::Device::cpu);
    int passed = 0;
    int failed = 0;
    int total_checks = 0;
    for (const auto& test : cases) {
      Checks checks;
      std::cout << "RUN " << test.name << std::endl;
      try {
        test.run(checks, cpu);
        mx::synchronize(cpu);
      } catch (const std::exception& error) {
        checks.check(false, error.what());
      } catch (...) {
        checks.check(false, "unexpected non-standard exception");
      }
      total_checks += checks.total;
      if (checks.failed == 0) {
        ++passed;
        std::cout << "PASS ";
      } else {
        ++failed;
        std::cout << "FAIL ";
      }
      std::cout << test.name << " checks=" << checks.total
                << " failed_checks=" << checks.failed << std::endl;
    }
    std::cout << "SUMMARY cases=" << passed + failed << " passed=" << passed
              << " failed=" << failed << " checks=" << total_checks << std::endl;
    return failed == 0 ? 0 : 1;
  } catch (const std::exception& error) {
    std::cerr << "SETUP FAILED: " << error.what() << '\n';
    return 2;
  }
}
