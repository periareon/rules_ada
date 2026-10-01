with Ada.Environment_Variables;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Runfiles;
with Test_Support;

--  Manifest-only mode: RUNFILES_MANIFEST_FILE points at a fixture manifest
--  written to TEST_TMPDIR and no runfiles directory is known. Covers exact
--  lookup, escaped entries, the directory-prefix fallback, not-found
--  raising and Env_Vars contents.
procedure Test_Manifest_Mode is
   use Ada.Text_IO;
   use Ada.Strings.Unbounded;
   use Test_Support;
   package Env renames Ada.Environment_Variables;

   Manifest : constant String := Env.Value ("TEST_TMPDIR") & "/manifest.txt";
   File     : File_Type;
begin
   Create (File, Out_File, Manifest);
   Put_Line (File, "_main/data/file.txt /fake/file.txt");
   Put_Line (File, "_main/data/dir /fake/dir");
   Put_Line (File, " _main/data/with\sspace.txt /fake/with\sspace.txt");
   Close (File);

   Env.Set ("RUNFILES_MANIFEST_FILE", Manifest);
   Env.Clear ("RUNFILES_DIR");
   Env.Clear ("TEST_SRCDIR");

   declare
      R    : constant Runfiles.Context := Runfiles.Create;
      Vars : constant Runfiles.Env_Var_Array := R.Env_Vars;
   begin
      Expect (To_String (Vars (1).Name), "RUNFILES_MANIFEST_FILE", "var 1");
      Expect (To_String (Vars (1).Value), Manifest, "manifest env value");
      Expect (To_String (Vars (2).Name), "RUNFILES_DIR", "var 2");
      Expect (To_String (Vars (2).Value), "", "no directory known");
      Expect (To_String (Vars (3).Name), "JAVA_RUNFILES", "var 3");
      Expect (To_String (Vars (3).Value), "", "no java runfiles known");

      Expect (R.Rlocation ("_main/data/file.txt"), "/fake/file.txt",
              "exact manifest entry");
      Expect (R.Rlocation ("_main/data/with space.txt"),
              "/fake/with space.txt", "escaped manifest entry");
      Expect (R.Rlocation ("_main/data/dir/sub/f.txt"), "/fake/dir/sub/f.txt",
              "prefix fallback for directory entry");

      Expect_Error (R, "_main/data/missing");
   end;

   Put_Line ("PASS: manifest mode");
end Test_Manifest_Mode;
