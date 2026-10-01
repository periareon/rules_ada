# Toolchains

`rules_ada` ships with hermetic GNAT toolchains built by
[hermetic-gnat](https://github.com/periareon/hermetic-gnat). The `ada` module
extension declared in `@rules_ada//ada:extensions.bzl` downloads the archive
for the execution platform on first use and `rules_ada` registers the resulting
toolchains itself, so a consumer only needs the `bazel_dep`.

## Supported platforms

| Platform | Constraints |
| --- | --- |
| Linux x86_64 | `@platforms//os:linux`, `@platforms//cpu:x86_64` |
| Linux aarch64 | `@platforms//os:linux`, `@platforms//cpu:aarch64` |
| macOS x86_64 | `@platforms//os:macos`, `@platforms//cpu:x86_64` |
| macOS aarch64 | `@platforms//os:macos`, `@platforms//cpu:aarch64` |
| Windows x86_64 | `@platforms//os:windows`, `@platforms//cpu:x86_64` |

## Selecting a GCC version

Every `rules_ada` release tracks exactly one hermetic-gnat release. That
release contains one toolchain per supported GCC version; the newest is the
default. The `version` build setting selects another one:

```bash
bazel build --@rules_ada//ada/settings:version=15.3.0 //...
```

The accepted values, the tracked hermetic-gnat release and the default are all
recorded in
[`ada/private/versions.bzl`](https://github.com/periareon/rules_ada/blob/main/ada/private/versions.bzl).
A `config_setting` named `@rules_ada//ada/settings:version_<gcc version>`
exists for each entry and can be used in `select()`.

## The C/C++ toolchain

Linking, archiving (when the GNAT archive ships no `ar`) and interop with
`cc_*` targets use the C/C++ toolchain registered by `rules_cc`. On macOS the
Apple toolchain from `apple_support` must be registered before the default
one, so add it to your own `MODULE.bazel` ahead of any `bazel_dep` on
`rules_cc`:

```python
bazel_dep(name = "apple_support", version = "2.5.4")
```

## Bringing your own GNAT

A GNAT installation that is not provided by hermetic-gnat can be wired up with
the [`ada_toolchain`](./ada_toolchain.md) rule and a `toolchain()` declaration
for `@rules_ada//ada:toolchain_type`. Link flags that are plain relative paths
are resolved against the toolchain repository root, which is taken to be the
parent directory of the compiler's `bin/` directory.
