with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Runfiles;
with Test_Support;

--  Directory-only mode: RUNFILES_DIR points at an empty directory under
--  TEST_TMPDIR with no manifest. Rlocation joins without checking for
--  existence and Env_Vars reports the directory only.
procedure Test_Directory_Mode is
   use Ada.Text_IO;
   use Ada.Strings.Unbounded;
   use Test_Support;
   package Env renames Ada.Environment_Variables;

   Dir : constant String := Env.Value ("TEST_TMPDIR") & "/fake.runfiles";
begin
   Ada.Directories.Create_Path (Dir);

   Env.Clear ("RUNFILES_MANIFEST_FILE");
   Env.Set ("RUNFILES_DIR", Dir);
   Env.Clear ("TEST_SRCDIR");

   declare
      R    : constant Runfiles.Context := Runfiles.Create;
      Vars : constant Runfiles.Env_Var_Array := R.Env_Vars;
   begin
      Expect (To_String (Vars (1).Value), "", "no manifest known");
      Expect (To_String (Vars (2).Value), Dir, "RUNFILES_DIR");
      Expect (To_String (Vars (3).Value), Dir, "JAVA_RUNFILES");

      Expect (R.Rlocation ("_main/does/not/exist.txt"),
              Dir & "/_main/does/not/exist.txt",
              "directory join without existence check");
      Expect (R.Rlocation ("some_repo/x.txt", Source_Repo => ""),
              Dir & "/some_repo/x.txt",
              "unmapped path with no _repo_mapping");
   end;

   Put_Line ("PASS: directory mode");
end Test_Directory_Mode;
