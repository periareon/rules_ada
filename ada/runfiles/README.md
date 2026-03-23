# Ada Runfiles Library

Resolve [Bazel runfile](https://bazel.build/extending/rules#runfiles) paths at
runtime from Ada binaries and tests.

## Setup

Add `@rules_ada//ada/runfiles` as a dependency and list any runtime data files
in the `data` attribute:

```python
load("@rules_ada//ada:defs.bzl", "ada_binary")

ada_binary(
    name = "my_binary",
    srcs = ["main.adb"],
    data = ["//path/to:data.txt"],
    deps = ["@rules_ada//ada/runfiles"],
)
```

## Usage

```ada
with Ada.Text_IO;
with Runfiles;

procedure Main is
   R    : constant Runfiles.Context := Runfiles.Create;
   Path : constant String :=
     R.Rlocation ("my_workspace/path/to/data.txt");
begin
   Ada.Text_IO.Put_Line ("File is at: " & Path);
end Main;
```

### Bzlmod repo mapping

When using [Bzlmod](https://bazel.build/external/overview#bzlmod), repository
names seen at build time (apparent names) may differ from the canonical names
used in the runfiles tree. Use the `Rlocation` overload with `Source_Repo` to
apply the `_repo_mapping` translations automatically:

```ada
Path : constant String :=
  R.Rlocation ("my_dep/data/config.json",
                Source_Repo => "");
```

`Source_Repo` identifies the repository that is performing the lookup. For the
root module this is `""` (empty string). The library reads the `_repo_mapping`
file produced by Bazel and translates the apparent repo name (first path
component) to its canonical name before resolving.

## API reference

### `Runfiles.Create`

```ada
function Create return Context;
```

Creates a runfiles context by examining, in order:

1. `RUNFILES_MANIFEST_FILE` environment variable (manifest mode)
2. `RUNFILES_DIR` environment variable (directory mode)
3. `TEST_SRCDIR` environment variable (directory mode, set by Bazel test runner)
4. `argv[0].runfiles` sibling directory
5. Ancestor directories ending in `.runfiles`

If a `MANIFEST` file exists inside the discovered directory, manifest mode is
used instead of directory mode.

Raises `Runfiles_Error` if no runfiles can be located.

### `Runfiles.Rlocation`

```ada
function Rlocation (Self : Context; Path : String) return String;
```

Resolves an rlocation path (e.g. `"my_repo/path/to/file"`) to a real filesystem
path. Absolute paths are returned unchanged.

- **Manifest mode**: looks up the path in the parsed manifest. Raises
  `Runfiles_Error` if not found.
- **Directory mode**: joins the runfiles directory with the path. Does not check
  whether the file exists on disk.

### `Runfiles.Rlocation` (bzlmod-aware)

```ada
function Rlocation
  (Self        : Context;
   Path        : String;
   Source_Repo : String) return String;
```

Same as above, but first applies the `_repo_mapping` to translate the apparent
repository name (first path component) using the given `Source_Repo` as the
lookup key. Falls back to the unmapped path if no mapping entry exists.

Supports both the standard and compact repo mapping formats, including the
wildcard prefix entries from
[`--incompatible_compact_repo_mapping_manifest`](https://github.com/bazelbuild/bazel/issues/26262)
(Bazel 9+).

### `Runfiles_Error`

```ada
Runfiles_Error : exception;
```

Raised when runfiles cannot be located (`Create`) or a specific path cannot be
resolved in manifest mode (`Rlocation`).
