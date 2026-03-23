# examples/simple

A standalone consumer of `rules_ada` showing the typical Bazel module setup with an
`ada_library`, an `ada_binary` that depends on it, and an `ada_test` that exercises it.

The `MODULE.bazel` uses `local_path_override` so this directory builds against the
parent checkout of `rules_ada`. A downstream consumer would simply drop the
`local_path_override` and use a published version.

## Build and test

```bash
cd examples/simple
bazel build //:main
bazel test //:math_test
```
