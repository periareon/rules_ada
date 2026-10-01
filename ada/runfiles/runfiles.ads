--  Runfiles lookup library for Bazel-built Ada binaries and tests.
--
--  This package follows the Bazel runfiles contract as implemented by the
--  rules_cc C++ runfiles library: runfiles are located via the
--  RUNFILES_MANIFEST_FILE / RUNFILES_DIR environment variables or by probing
--  next to argv[0], paths are resolved through the manifest (with a fallback
--  to the runfiles directory), and bzlmod repository mappings are applied
--  from the _repo_mapping file.
--
--  USAGE:
--
--  1. Depend on this runfiles library from your build rule:
--
--     ada_binary(
--         name = "my_binary",
--         ...
--         data = ["//path/to/my/data.txt"],
--         deps = ["@rules_ada//ada/runfiles"],
--     )
--
--  2. With the runfiles library:
--
--     with Runfiles;
--
--     procedure Main is
--        R    : constant Runfiles.Context := Runfiles.Create;
--        Path : constant String :=
--           R.Rlocation ("my_module/path/to/my/data.txt",
--                        Source_Repo => "");
--     begin
--        --  Use Path to open files, etc.
--     end Main;
--
--     The first path component is the *apparent* repository name as seen
--     from Source_Repo (the module name from MODULE.bazel, or a repo name
--     given to bazel_dep / use_repo). Source_Repo is the canonical name of
--     the repository performing the lookup; for the root module it is "".
--
--     The one-argument Rlocation performs no repository mapping, so its path
--     must already start with the *canonical* repository name. Under bzlmod
--     the root module's canonical name is "_main":
--
--        R.Rlocation ("_main/path/to/my/data.txt")

with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded;

package Runfiles is

   type Context is tagged private;

   Runfiles_Error : exception;

   --  Creates a runfiles context. Runfiles are discovered in this order:
   --
   --  1. RUNFILES_MANIFEST_FILE, if it names a readable file.
   --  2. RUNFILES_DIR, then TEST_SRCDIR, if either names a directory.
   --  3. argv[0] probes: "<argv0>.runfiles/MANIFEST", "<argv0>.runfiles"
   --     and "<argv0>.runfiles_manifest", then the same probes for every
   --     ancestor directory of argv[0] (an ancestor whose name ends in
   --     ".runfiles" is itself accepted as the runfiles directory).
   --
   --  Whenever only one of manifest/directory is found, the other is derived
   --  from it when it exists on disk: "<dir>/MANIFEST" or "<dir>_manifest"
   --  for the manifest, and the manifest path with a trailing "_manifest" or
   --  "/MANIFEST" stripped for the directory.
   --
   --  Raises Runfiles_Error if no runfiles can be located, or if a manifest
   --  or _repo_mapping file is malformed.
   function Create return Context;

   --  Resolves an rlocation path to a real filesystem path without applying
   --  any repository mapping. Path must be of the form
   --  "canonical_repo_name/path/to/file" (the root module's canonical name
   --  under bzlmod is "_main").
   --
   --  Absolute paths are returned unchanged. Raises Runfiles_Error for
   --  invalid paths: the empty string, paths starting with "../" or "./",
   --  containing "/../", "/./" or "//", or ending with "/.." or "/.".
   --
   --  Resolution order:
   --
   --  1. An exact manifest entry for Path.
   --  2. A manifest entry for the longest "/"-separated prefix of Path; the
   --     remainder of Path is appended to that entry's value. This is how
   --     files inside directory and tree-artifact runfiles are found, since
   --     the manifest only lists the directory itself.
   --  3. "<runfiles directory>/Path" if a runfiles directory is known. The
   --     file is not checked for existence.
   --
   --  Raises Runfiles_Error if none of the above apply (manifest-only mode
   --  and Path is not in the manifest).
   function Rlocation (Self : Context; Path : String) return String;

   --  Resolves an rlocation path with bzlmod repository mapping support.
   --  This is the recommended form.
   --
   --  Source_Repo is the canonical name of the repository performing the
   --  lookup ("" for the root module). The first component of Path is
   --  treated as an apparent repository name visible from Source_Repo and
   --  is translated to its canonical name via the _repo_mapping file. Both
   --  exact entries and the wildcard prefix entries produced by
   --  --incompatible_compact_repo_mapping_manifest are supported; when
   --  several wildcard entries match, the longest prefix wins. If no mapping
   --  entry applies, Path is resolved as-is.
   --
   --  Paths without a "/" are never mapped. Everything else behaves exactly
   --  like the one-argument Rlocation.
   function Rlocation
     (Self        : Context;
      Path        : String;
      Source_Repo : String) return String;

   --  A single environment variable assignment.
   type Env_Var is record
      Name  : Ada.Strings.Unbounded.Unbounded_String;
      Value : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   type Env_Var_Array is array (Positive range <>) of Env_Var;

   --  Returns the environment variables that a child process needs in order
   --  to locate the same runfiles as this context, regardless of how the
   --  context itself was discovered (e.g. by walking argv[0]).
   --
   --  Always returns exactly three entries, in this order:
   --
   --     RUNFILES_MANIFEST_FILE  the manifest path, or "" if none is known
   --     RUNFILES_DIR            the runfiles directory, or "" if unknown
   --     JAVA_RUNFILES           same value as RUNFILES_DIR
   --
   --  An empty value means the variable carries no information; runfiles
   --  libraries treat an empty variable the same as an unset one.
   function Env_Vars (Self : Context) return Env_Var_Array;

private

   use Ada.Strings.Unbounded;

   package String_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => String,
      Element_Type    => String,
      Hash            => Ada.Strings.Hash,
      Equivalent_Keys => "=");

   --  Repo mapping stores two sets of entries:
   --    Repo_Map:          exact-match entries, keyed by "source_repo,apparent"
   --    Repo_Map_Prefixes: prefix-match entries from
   --                       --incompatible_compact_repo_mapping_manifest
   --                       (source repos ending with '*'). Keyed by
   --                       "prefix,apparent" where prefix has the '*' stripped.
   --                       Looked up by checking Starts_With on the caller's
   --                       source repo, preferring the longest prefix.
   --
   --  Manifest_Path and Runfiles_Dir are "" when unknown; at least one of
   --  them is always set by Create.
   type Context is tagged record
      Manifest_Path     : Unbounded_String;
      Runfiles_Dir      : Unbounded_String;
      Manifest          : String_Maps.Map;
      Repo_Map          : String_Maps.Map;
      Repo_Map_Prefixes : String_Maps.Map;
   end record;

end Runfiles;
