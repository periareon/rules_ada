# rules_ada

`rules_ada` provides Bazel rules for building [Ada](https://ada-lang.io/) code with the [GNAT](https://gcc.gnu.org/wiki/GNAT) compiler.

## Setup

```python
bazel_dep(name = "rules_ada", version = "{version}")
```

## Quick start

```python
load("@rules_ada//ada:ada_binary.bzl", "ada_binary")
load("@rules_ada//ada:ada_library.bzl", "ada_library")

ada_library(
    name = "math_utils",
    srcs = ["math_utils.ads", "math_utils.adb"],
)

ada_binary(
    name = "calculator",
    srcs = ["main.adb"],
    deps = [":math_utils"],
)
```

Build with:

```bash
bazel build //:calculator
```

## Toolchains

`rules_ada` downloads prebuilt GNAT toolchains from
[hermetic-gnat](https://github.com/periareon/hermetic-gnat) and registers them
automatically, so nothing has to be installed on the host. Supported platforms
are Linux (x86_64, aarch64), macOS (x86_64, aarch64) and Windows (x86_64).

Each release of `rules_ada` tracks one hermetic-gnat release, which ships
several GCC versions. The newest is used by default; another can be selected
with the `version` flag, e.g.

```bash
bazel build --@rules_ada//ada/settings:version=15.3.0 //...
```

The available versions are listed in
[`ada/private/versions.bzl`](./ada/private/versions.bzl).

On macOS, also add [`apple_support`](https://github.com/bazelbuild/apple_support)
to your `MODULE.bazel`, before any `bazel_dep` on `rules_cc`, so that the Apple
C/C++ toolchain is used for linking:

```python
bazel_dep(name = "apple_support", version = "2.5.4")
```

## Docs

Additional documentation can be found at <https://periareon.github.io/rules_ada/>
