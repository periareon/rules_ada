# Ada Runfiles Library

Resolve [Bazel runfile](https://bazel.build/extending/rules#runfiles) paths at
runtime from Ada binaries and tests.

The library follows the Bazel runfiles contract as implemented by the
[rules_cc C++ runfiles library](https://github.com/bazelbuild/rules_cc/blob/main/cc/runfiles/runfiles.h):
the same discovery order, manifest/directory fallback rules, path validation and
bzlmod repository mapping.

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

The recommended form is the `Rlocation` overload that takes a `Source_Repo`.
The path starts with the *apparent* repository name as seen from `Source_Repo`
(your module name from `MODULE.bazel`, or a repo name you obtained via
`bazel_dep` / `use_repo`), and `Source_Repo` is the canonical name of the
repository doing the lookup, which is `""` for the root module:

```ada
with Ada.Text_IO;
with Runfiles;

procedure Main is
   R    : constant Runfiles.Context := Runfiles.Create;
   Path : constant String :=
     R.Rlocation ("my_module/path/to/data.txt", Source_Repo => "");
begin
   Ada.Text_IO.Put_Line ("File is at: " & Path);
end Main;
```

### Repository mapping

Under [Bzlmod](https://bazel.build/external/overview#bzlmod) the repository
name you write in `BUILD` files (the apparent name, e.g. `my_module` or
`rules_ada`) differs from the canonical name used inside the runfiles tree
(e.g. `_main` for the root module, `rules_ada+` for a `bazel_dep`). Bazel
emits a `_repo_mapping` file alongside the runfiles that lists, for every
source repository, how apparent names translate to canonical names.

`Rlocation (Path, Source_Repo)` looks up the first component of `Path` in that
file using `Source_Repo` as the key and rewrites it to the canonical name
before resolving. Both the standard format and the compact format produced by
[`--incompatible_compact_repo_mapping_manifest`](https://github.com/bazelbuild/bazel/issues/26262)
(Bazel 9+, source repos such as `+deps+*`) are supported. When several
wildcard entries match the caller's `Source_Repo`, the one with the longest
prefix wins, and an exact entry always beats a wildcard. Paths without a `/`
are never mapped. If no entry applies, the path is resolved unchanged.

The one-argument `Rlocation (Path)` performs **no** mapping, so its path must
already start with the canonical repository name:

```ada
--  Equivalent to the call above for the root module under bzlmod.
Path : constant String := R.Rlocation ("_main/path/to/data.txt");
```

### Passing runfiles to subprocesses

A binary that located its runfiles by probing `argv[0]` has no environment
variables to hand down. `Env_Vars` returns what a child process needs:

```ada
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

for V of R.Env_Vars loop
   Ada.Environment_Variables.Set (To_String (V.Name), To_String (V.Value));
end loop;
```

## API reference

### `Runfiles.Create`

```ada
function Create return Context;
```

Locates the runfiles manifest and/or directory, in this order:

1. `RUNFILES_MANIFEST_FILE`, if it names a readable file. A stale or
   unreadable value is ignored rather than causing an error.
2. `RUNFILES_DIR`, then `TEST_SRCDIR`, if either names a directory.
3. If neither variable yielded anything, `argv[0]` is probed:
   `<argv0>.runfiles/MANIFEST`, `<argv0>.runfiles` and
   `<argv0>.runfiles_manifest`, followed by the same three probes for every
   ancestor directory of `argv[0]`. An ancestor whose own name ends in
   `.runfiles` is accepted directly as the runfiles directory. This makes
   `bazel build` outputs runnable even when `--nobuild_runfile_links` is in
   effect and only the `.runfiles_manifest` file exists.

Once one of the two locations is known the other is derived from it, if it
exists on disk: `<dir>/MANIFEST` or `<dir>_manifest` give the manifest, and a
manifest path with a trailing `_manifest` or `/MANIFEST` stripped gives the
directory. Both are kept and used by `Rlocation`.

The manifest (if any) is parsed eagerly. Lines beginning with a space use
Bazel's escaping (`\s`, `\n`, `\b`). A line with no separating space is
malformed and raises `Runfiles_Error`. The `_repo_mapping` file is loaded if
present; a malformed line there also raises `Runfiles_Error`.

Raises `Runfiles_Error` if no runfiles can be located.

### `Runfiles.Rlocation`

```ada
function Rlocation (Self : Context; Path : String) return String;
```

Resolves an rlocation path such as `"_main/path/to/file"` (canonical repo
name first) to a real filesystem path.

Invalid paths raise `Runfiles_Error`: the empty string, paths starting with
`../` or `./`, containing `/../`, `/./` or `//`, or ending with `/..` or `/.`.
Absolute paths (`/...`, or `X:\...` / `X:/...` with a drive letter) are returned
unchanged.

Resolution, in order:

1. An exact manifest entry for `Path`.
2. A manifest entry for the longest `/`-separated prefix of `Path`, with the
   remainder appended to the entry's value. Files inside directory and
   tree-artifact runfiles only appear in the manifest under their directory,
   so this is how they are found.
3. `<runfiles directory>/Path` if a directory is known. The file is not checked
   for existence.

Raises `Runfiles_Error` if none apply, i.e. in manifest-only mode when the
path is not in the manifest.

### `Runfiles.Rlocation` (bzlmod-aware)

```ada
function Rlocation
  (Self        : Context;
   Path        : String;
   Source_Repo : String) return String;
```

Same as above, after translating the first path component from an apparent
repository name to a canonical one as described under
[Repository mapping](#repository-mapping).

### `Runfiles.Env_Vars`

```ada
type Env_Var is record
   Name  : Ada.Strings.Unbounded.Unbounded_String;
   Value : Ada.Strings.Unbounded.Unbounded_String;
end record;

type Env_Var_Array is array (Positive range <>) of Env_Var;

function Env_Vars (Self : Context) return Env_Var_Array;
```

Returns exactly three entries, in order: `RUNFILES_MANIFEST_FILE` (the manifest
path, or `""` if none is known), `RUNFILES_DIR` (the directory, or `""`), and
`JAVA_RUNFILES` (same value as `RUNFILES_DIR`). Runfiles libraries treat an
empty variable like an unset one, so the array can be applied as-is to a child
process environment.

### `Runfiles_Error`

```ada
Runfiles_Error : exception;
```

Raised when runfiles cannot be located or a manifest / `_repo_mapping` file is
malformed (`Create`), and when a path is invalid or cannot be resolved
(`Rlocation`).
