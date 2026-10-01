# rules_ada

Bazel rules for building [Ada](https://ada-lang.io/) with [GNAT](https://gcc.gnu.org/wiki/GNAT).

## Install

```python
bazel_dep(name = "rules_ada", version = "{version}")
```

## Getting started

1. Add `rules_ada` to `MODULE.bazel`.
2. Define Ada targets with rules from `@rules_ada//ada:defs.bzl`.
3. Build or test with Bazel:

```bash
bazel build //:your_target
bazel test //:your_test
```

## Features

- Ada libraries, binaries, and tests
- Static and shared library outputs
- Coverage support via `bazel coverage`
- Interop with C/C++/Rust via `CcInfo`
- Hermetic GNAT toolchains, registered automatically (see [Toolchains](./toolchains.md))

## Example

```python
load("@rules_ada//ada:defs.bzl", "ada_binary", "ada_library", "ada_test")

ada_library(
    name = "math_utils",
    srcs = [
        "math_utils.ads",
        "math_utils.adb",
    ],
)

ada_binary(
    name = "calculator",
    srcs = ["main.adb"],
    deps = [":math_utils"],
)

ada_test(
    name = "math_test",
    srcs = ["math_test.adb"],
    deps = [":math_utils"],
)
```

## Rule reference

See [Rules](./rules.md).

## Runfiles

Programs that need data files at runtime can locate them with the
[runfiles library](./runfiles.md).
