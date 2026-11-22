# examples/ghdl

A consumer of `rules_ada` that builds [GHDL](https://github.com/ghdl/ghdl), a
VHDL simulator written in Ada, from the Bazel Central Registry. GHDL is a few
hundred Ada units plus some C and links against a C runtime, so it exercises
far more of the rules than the `simple` example does.

The `MODULE.bazel` uses `local_path_override` so `ghdl` builds against the
parent checkout of `rules_ada` instead of the release it declares. CI builds
this example on Linux, macOS and Windows for every pull request. A downstream
consumer would simply drop the `local_path_override`.

The test is an `ada_test` that takes `@ghdl//:ghdl` as `data`, finds it with
`@rules_ada//ada/runfiles`, runs `ghdl --version` and checks the output.

## Build and test

```bash
cd examples/ghdl
bazel test //...
```

GHDL's default `mcode` backend only generates x86 code. On other CPUs the
module falls back to its LLVM backend, which builds `llvm-project` from
source and takes considerably longer without a populated cache.
