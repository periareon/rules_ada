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

## Docs

Additional documentation can be found at <https://periareon.github.io/rules_ada/>
