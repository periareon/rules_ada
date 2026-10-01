with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Runfiles;
with Test_Support;

--  Builds two small runfiles layouts under TEST_TMPDIR and checks that
--  giving only RUNFILES_MANIFEST_FILE or only RUNFILES_DIR derives the
--  other ("<dir>/MANIFEST" and "<dir>_manifest" forms), that a stale
--  manifest path is ignored, and that a manifest miss falls back to the
--  directory when one is known.
procedure Test_Derived_Paths is
   use Ada.Text_IO;
   use Ada.Strings.Unbounded;
   use Test_Support;
   package Env renames Ada.Environment_Variables;

   --  Create with the given variables and check what Env_Vars reports.
   procedure Check
     (Manifest_Env, Dir_Env, Want_Manifest, Want_Dir, What : String)
   is
      R : Runfiles.Context;
   begin
      if Manifest_Env'Length > 0 then
         Env.Set ("RUNFILES_MANIFEST_FILE", Manifest_Env);
      else
         Env.Clear ("RUNFILES_MANIFEST_FILE");
      end if;
      if Dir_Env'Length > 0 then
         Env.Set ("RUNFILES_DIR", Dir_Env);
      else
         Env.Clear ("RUNFILES_DIR");
      end if;

      R := Runfiles.Create;
      Expect (To_String (R.Env_Vars (1).Value), Want_Manifest,
              What & ": manifest");
      Expect (To_String (R.Env_Vars (2).Value), Want_Dir, What & ": dir");

      --  Resolved through the manifest in every case; the file is real.
      declare
         Path   : constant String := R.Rlocation ("_main/sample.txt");
         File   : File_Type;
         Buffer : String (1 .. 256);
         Last   : Natural;
      begin
         Open (File, In_File, Path);
         Get_Line (File, Buffer, Last);
         Close (File);
         Expect (Buffer (1 .. Last), "Hello from runfiles!", What & ": read");
      end;

      Expect (R.Rlocation ("_main/nope.txt"), Want_Dir & "/_main/nope.txt",
              What & ": manifest miss falls back to directory");
   end Check;

   Sample : constant String :=
     Runfiles.Create.Rlocation
       ("rules_ada/tests/runfiles/sample.txt", Source_Repo => "");

   Tmp   : constant String := Env.Value ("TEST_TMPDIR");
   Dir_A : constant String := Tmp & "/a.runfiles";
   Mf_A  : constant String := Dir_A & "/MANIFEST";
   Dir_B : constant String := Tmp & "/b.runfiles";
   Mf_B  : constant String := Tmp & "/b.runfiles_manifest";

   procedure Write_Manifest (Path : String) is
      File : File_Type;
   begin
      Create (File, Out_File, Path);
      Put_Line (File, "_main/sample.txt " & Sample);
      Close (File);
   end Write_Manifest;
begin
   Ada.Directories.Create_Path (Dir_A);
   Ada.Directories.Create_Path (Dir_B);
   Write_Manifest (Mf_A);
   Write_Manifest (Mf_B);
   Env.Clear ("TEST_SRCDIR");

   Check (Mf_A, "", Mf_A, Dir_A, "dir derived from /MANIFEST");
   Check ("", Dir_A, Mf_A, Dir_A, "manifest derived as /MANIFEST");
   Check (Mf_B, "", Mf_B, Dir_B, "dir derived from _manifest");
   Check ("", Dir_B, Mf_B, Dir_B, "manifest derived as _manifest");
   Check (Tmp & "/stale_manifest", Dir_A, Mf_A, Dir_A, "stale manifest");

   Put_Line ("PASS: derived paths");
end Test_Derived_Paths;
