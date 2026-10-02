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

## Link lines

Every link command is the compiler followed by the expansion of the
toolchain's `args`: [`ada_args`](./ada_args.md) targets whose templates
reference the variables of the action, in the order the toolchain lists
them, then the arguments of enabled [features](#features) in `known_features`
order. The rules add nothing on their own, not even `-o`, so a toolchain has
full control over the command line.

`rules_ada` ships complete link lines per platform family that the hermetic
toolchains use and a custom toolchain can reuse, extend or replace:

| Target | Behaviour |
| --- | --- |
| `@rules_ada//ada/toolchains/args/elf:link_line` | GNU ld: `--start-group` / `--end-group` around the dependency libraries, `--whole-archive` for `alwayslink` ones, `-Wl,-soname`, `$ORIGIN`-relative rpaths. Add `elf:linux_system_libs` for `-lm -lpthread -ldl -lrt`. |
| `@rules_ada//ada/toolchains/args/darwin:link_line` | Apple ld: `-force_load` for `alwayslink` libraries, `-undefined dynamic_lookup` and `-install_name @rpath/...` for shared libraries, `@loader_path`-relative rpaths, the C/C++ toolchain's deployment target. Add `darwin:sysroot_from_env` and `darwin:nodefaultrpaths`. |
| `@rules_ada//ada/toolchains/args/windows:link_line` | MinGW: runtime archives linked into DLLs as well, no rpaths. |

The building blocks live in `@rules_ada//ada/toolchains/args` (`objects`,
`gnu_libraries_to_link`, `darwin_libraries_to_link`, `dep_link_flags`,
`user_link_flags`, `runtime_libraries`, `coverage_link_flags`, `output`, ...).
The two link actions, `link_executable` and `link_shared_library`, expose
these variables:

| Variable | Type | Meaning |
| --- | --- | --- |
| `output` | File | The executable or shared library being linked. |
| `output_basename` | string | Its file name, for `-soname` and `-install_name`. |
| `objects` | list of File | Object files, including the binder's and, for executables, those of Ada dependencies. |
| `libraries_to_link` | list of struct | Dependency libraries in order; fields `file`, `whole_archive` (an `alwayslink` archive) and `dynamic`. |
| `dep_link_flags` | list of string | `linkopts` contributed by dependencies; bare MSVC `name.lib` entries arrive as `-lname`. |
| `user_link_flags` | list of string | The target's own `linkopts`, verbatim. |
| `runtime_libraries` | list of File | The toolchain's `static_runtime_lib`, in order. |
| `coverage_link_flags` | list of string | `libgcov.a` and the C/C++ coverage runtime; empty unless coverage is on. |
| `runtime_library_search_directories` | list of string | Directories, relative to the output, holding its shared dependencies and staged runtime libraries, for both the `bazel-bin` and runfiles layouts; `.` for its own directory. Executables list their shared dependencies; shared libraries only their staged runtime libraries. |
| `macos_deployment_target` | optional string | The C/C++ toolchain's Apple deployment target, when it declares one. |

A template is a plain string with `{name}` or `{name.field}` placeholders. An
argument that is exactly `{name}` for a list expands to one argument per
element; `iterate_over` expands a whole `ada_args` once per element with the
element bound to the list's name; `requires_true`, `requires_false`,
`requires_not_none` and `requires_none` make an `ada_args` (or an
[`ada_nested_args`](./ada_nested_args.md) inside an iteration) conditional.
An empty list counts as unset. Templates are checked against the action's
variables when the `ada_args` target is analyzed.

`ada_args` can also target `compile`, `bind` and `archive`; those actions
expose no variables, and the arguments are appended after the toolchain's
`compile_flags` or `bind_flags`, or right after the archiver.

## Features

Features follow the `cc_*` rules' conventions. An [`ada_feature`](./ada_feature.md)
names a set of arguments; a toolchain lists the features it understands in
`known_features` and the ones on by default in `enabled_features`; a target
adds or removes them with `features = ["name"]` or `features = ["-name"]`;
`--features` applies to every target. The effective set is also forwarded to
the C/C++ toolchain.

| Feature | Effect |
| --- | --- |
| `static_libgcc` (`@rules_ada//ada/toolchains/features:static_libgcc`) | Passes `-static-libgcc` to every link. While it is disabled the rules stage the toolchain's `dynamic_runtime_lib` beside the output. Enabled by default by every hermetic toolchain. |
| `static_linking_mode`, `dynamic_linking_mode` | Derived from `linkstatic` and `--dynamic_mode` exactly as `cc_binary` does and requested for forward compatibility. No shipped argument depends on them yet: the hermetic GNAT runtime is static only. |

`linkopts` are passed through verbatim and never inspected; a target that
wants the shared libgcc disables the feature rather than passing
`-shared-libgcc`.

## Differences from gnatlink

The hermetic toolchains aim to produce the binaries `gnatmake` and `gprbuild`
would, so that moving a project to Bazel changes as little as possible. Two
things take precedence over that, in order: every output must be
byte-for-byte reproducible across machines, and it must not depend on files
of the build machine that another machine may lack. Where `gnatlink` falls
short of either, rules_ada deviates, and the comment next to the deviation
says what the ecosystem does instead. The shipped arg sets and features make
every one of them reversible for a custom toolchain or a target.

| Topic | gnatlink | Hermetic rules_ada toolchains | Why |
| --- | --- | --- | --- |
| libgcc on Linux and Windows | `-static-libgcc` | `-static-libgcc` (feature `static_libgcc`) | Matches, and keeps binaries off the host's `libgcc_s.so.1`. Programs that must share one unwinder with `dlopen`'d C++ or JIT code set `features = ["-static_libgcc"]`. |
| libgcc on macOS | shared `libgcc_s.1.1.dylib`, found through absolute rpaths into the GNAT installation | `-static-libgcc` | gnatlink's shape bakes the output base into the binary. The unwinder is libSystem's either way, so nothing is lost. `features = ["-static_libgcc"]` restores the dynamic dependency with the dylib staged and reached through a relative rpath. |
| Driver rpaths on macOS | absolute paths to the toolchain's `lib/` directories | `-nodefaultrpaths`, rpaths only relative to the output | Absolute paths are neither reproducible nor relocatable. |
| Binder-generated linker options | taken from the binder output, including absolute paths | scrubbed; the toolchain's args list the runtime libraries explicitly | Reproducibility. |
| Deployment target on macOS | the driver's default (the release GNAT was built on) | the C/C++ toolchain's `-mmacosx-version-min` | Keeps Ada and C/C++ objects consistent and silences linker warnings; drop `darwin:macos_deployment_target` to get gnatlink's behaviour. |

## Linking on macOS

GCC's Darwin driver, as built for the hermetic toolchains, records absolute
`-rpath` entries for its own `lib/` directories in every executable and shared
library, and links `@rpath/libgcc_s.1.1.dylib` from there. Inside Bazel those
directories live in the output base that ran the link, so such a binary loads
only on that machine and fails with `Library not loaded: @rpath/libgcc_s.1.1.dylib`
when a remote cache hands it to another one.

The hermetic macOS toolchains therefore link with
`@rules_ada//ada/toolchains/args/darwin:nodefaultrpaths` and, like every
hermetic toolchain, enable the `static_libgcc` feature, which leaves the
output with no dependency on the toolchain at all. Exception propagation
across `dlopen` boundaries does not need a shared libgcc on macOS: the
unwinder is libSystem's for every image.

A target that disables `static_libgcc` with `features = ["-static_libgcc"]`
keeps the dynamic libgcc. `rules_ada` then symlinks the toolchain's
`dynamic_runtime_lib` into `<output>.runtime_libs/` beside the executable or
library, lists that directory in `runtime_library_search_directories` (which
the darwin link line turns into an `@loader_path` rpath), and carries the
staged copy in the target's runfiles and, for `ada_shared_library`, its
default outputs. The result loads from `bazel-bin`, from a runfiles tree and
from a remote cache hit alike. The staged files are symlinks, so copying a
binary out of `bazel-bin` by hand needs `cp -L`.

Other dylibs in the toolchain's `lib/` are not staged. In particular
`-lstdc++` resolves to the bundled GNU `libstdc++.6.dylib` and has the same
problem; link Apple's `-lc++` instead when mixing in C++ built by the Xcode
toolchain.

### Deployment target

The Apple C/C++ toolchain compiles and links for `--macos_minimum_os`, which
defaults to the version of the selected SDK. GNAT's driver defaults to the
macOS release the toolchain was built on, and Apple's linker warns about every
C/C++ object "built for newer macOS version than being linked" when the two
differ. `rules_ada` reads the version from the C/C++ toolchain's `-target`
or `-mmacosx-version-min` flag and exposes it as the `macos_deployment_target`
variable; the darwin link
line passes it as `-mmacosx-version-min` to every executable and shared
library link, so the output's deployment target is the one its C/C++ parts
already require. Set `--macos_minimum_os` to lower both at once. Without a
registered C/C++ toolchain the variable is unset and the GNAT default is left
alone.

## Defining custom toolchains

The hermetic-gnat toolchains above are registered automatically and need no
configuration. A GNAT installation that rules_ada does not ship, such as a
distribution package or a vendor build, is declared with the
[`ada_toolchain`](./ada_toolchain.md) rule and a `toolchain()` for
`@rules_ada//ada:toolchain_type`. The runtime archives go in
`static_runtime_lib`, in link order, and the link line is assembled from
`ada_args`, here the shipped ELF one plus the system libraries:

```python
load("@rules_ada//ada:ada_toolchain.bzl", "ada_toolchain")
load("@rules_ada//ada/toolchains:defs.bzl", "LINK_ACTIONS", "ada_args")

ada_args(
    name = "system_libs",
    actions = LINK_ACTIONS,
    args = ["-lm", "-lpthread", "-ldl", "-lrt"],
)

ada_toolchain(
    name = "gnat_toolchain",
    compiler = "@gnat//:bin/gcc",
    binder = "@gnat//:bin/gnatbind",
    ar = "@gnat//:bin/ar",
    gcov = "@gnat//:bin/gcov",
    ada_std = "@gnat//:ada_std",
    compiler_lib = "@gnat//:compiler_lib",
    static_runtime_lib = [
        "@gnat//:lib/gcc/x86_64-pc-linux-gnu/16.1.0/adalib/libgnarl.a",
        "@gnat//:lib/gcc/x86_64-pc-linux-gnu/16.1.0/adalib/libgnat.a",
        "@gnat//:lib/gcc/x86_64-pc-linux-gnu/16.1.0/libgcc.a",
    ],
    args = [
        "@rules_ada//ada/toolchains/args/elf:link_line",
        ":system_libs",
    ],
    known_features = ["@rules_ada//ada/toolchains/features:static_libgcc"],
    target_triple = "x86_64-pc-linux-gnu",
)

toolchain(
    name = "gnat",
    exec_compatible_with = ["@platforms//os:linux", "@platforms//cpu:x86_64"],
    toolchain = ":gnat_toolchain",
    toolchain_type = "@rules_ada//ada:toolchain_type",
)
```

GNU ld scans archives once, so `libgnarl.a` (which references `libgnat.a`)
must come first, as in `gnatlink`'s own `-lgnarl -lgnat`. Coverage builds look
for `libgcov.a` next to the listed `libgcc.a`. Anything the shipped link line
does not cover is one more `ada_args`; a toolchain that needs a different
structure lists the building blocks from `@rules_ada//ada/toolchains/args`
itself, or its own `ada_args`, instead of `link_line`.

A macOS toolchain additionally declares the shared libgcc, enables
`static_libgcc`, and keeps the driver's rpaths out of the outputs
(`-nodefaultrpaths` needs GCC 13 or newer):

```python
ada_toolchain(
    name = "gnat_toolchain",
    # ... as above, with the aarch64-apple-darwin paths ...
    dynamic_runtime_lib = ["@gnat//:lib/libgcc_s.1.1.dylib"],
    args = [
        "@rules_ada//ada/toolchains/args/darwin:link_line",
        "@rules_ada//ada/toolchains/args/darwin:sysroot_from_env",
        "@rules_ada//ada/toolchains/args/darwin:nodefaultrpaths",
    ],
    known_features = ["@rules_ada//ada/toolchains/features:static_libgcc"],
    enabled_features = ["@rules_ada//ada/toolchains/features:static_libgcc"],
    target_triple = "aarch64-apple-darwin24.6.0",
)
```

Output file names follow `artifact_name_patterns`; a Windows toolchain sets
`{"executable": "%{name}.exe", "shared_library": "%{name}.dll"}` and uses
`@rules_ada//ada/toolchains/args/windows:link_line`. A DLL declared in
`dynamic_runtime_lib` is staged and carried in runfiles like on any other
platform, but Windows has no rpath: it is only found if its directory is on
`PATH`.

### Migrating from 0.2.x

- `link_flags` is gone. Flags move into an `ada_args` target listed in `args`
  after the shipped `link_line` for the platform (so they follow the runtime
  archives), as `system_libs` does above. Runtime archives go in
  `static_runtime_lib`, in the same order they had.
- `enabled_features` now takes `ada_feature` labels, and every enabled
  feature must also be in `known_features`.
- `-shared-libgcc` in `linkopts` is no longer special; use
  `features = ["-static_libgcc"]`. On the hermetic macOS toolchains the
  linkopt now reaches the driver together with `-static-libgcc`, which wins.
- On macOS, executables now use `@loader_path` rpaths like shared libraries
  and `cc_binary`; staged runtime libraries follow the real output name
  (`main.exe.runtime_libs/` on Windows).
