# rules_ada

Bazel rules for building [Ada](https://ada-lang.io/) programs using the [GNAT](https://gcc.gnu.org/wiki/GNAT) compiler.

## Setup

```python
bazel_dep(name = "rules_ada", version = "{version}")
```

## Overview

`rules_ada` provides Bazel rules for compiling Ada source files (`.ads` specs and `.adb` bodies)
into libraries, shared libraries, binaries, and test executables. It integrates with the GNAT
toolchain (the GCC-based Ada compiler) and Bazel's C/C++ toolchain infrastructure via `rules_cc`.

### Features

- Compile Ada source files with full dependency tracking
- Static and shared library support
- Binary and test executable targets
- Code coverage via `bazel coverage`
- Interoperability with C, C++, and Rust targets through `CcInfo`
- Automatic GNAT toolchain detection and registration

## Quick Start

```python
load("//ada:defs.bzl", "ada_binary", "ada_library", "ada_test")

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
