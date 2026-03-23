--  Runfiles lookup library for Bazel-built Ada binaries and tests.
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
--           R.Rlocation ("my_workspace/path/to/my/data.txt");
--     begin
--        --  Use Path to open files, etc.
--     end Main;

with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded;

package Runfiles is

   type Context is tagged private;

   Runfiles_Error : exception;

   --  Creates a runfiles context by examining environment variables set by
   --  Bazel (RUNFILES_MANIFEST_FILE, RUNFILES_DIR, TEST_SRCDIR) or by
   --  discovering a .runfiles directory relative to the running executable.
   --  Raises Runfiles_Error if no runfiles can be located.
   function Create return Context;

   --  Resolves an rlocation path to a real filesystem path.
   --  Path should be of the form "repo_name/path/to/file".
   --  Returns the resolved path. In manifest mode, raises Runfiles_Error
   --  if the path is not found. In directory mode, returns the joined path
   --  regardless of whether the file exists on disk.
   function Rlocation (Self : Context; Path : String) return String;

   --  Resolves an rlocation path with bzlmod repo mapping support.
   --  Source_Repo identifies the repository performing the lookup, used
   --  to apply the _repo_mapping translations.
   function Rlocation
     (Self        : Context;
      Path        : String;
      Source_Repo : String) return String;

private

   use Ada.Strings.Unbounded;

   package String_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => String,
      Element_Type    => String,
      Hash            => Ada.Strings.Hash,
      Equivalent_Keys => "=");

   type Mode_Kind is (Directory_Based, Manifest_Based);

   --  Repo mapping stores two sets of entries:
   --    Repo_Map:          exact-match entries, keyed by "source_repo,apparent"
   --    Repo_Map_Prefixes: prefix-match entries from
   --                       --incompatible_compact_repo_mapping_manifest
   --                       (source repos ending with '*'). Keyed by
   --                       "prefix,apparent" where prefix has the '*' stripped.
   --                       Looked up by checking Starts_With on the caller's
   --                       source repo.
   type Context is tagged record
      Mode              : Mode_Kind := Directory_Based;
      Runfiles_Dir      : Unbounded_String;
      Manifest          : String_Maps.Map;
      Repo_Map          : String_Maps.Map;
      Repo_Map_Prefixes : String_Maps.Map;
   end record;

end Runfiles;
