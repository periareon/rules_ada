with Ada.Command_Line;
with Ada.Environment_Variables;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Runfiles;
with Test_Support;

--  With every runfiles environment variable cleared, Create must still find
--  the runfiles by probing argv[0] and its ancestors, and Env_Vars must then
--  describe what it found so a child process could reuse it.
procedure Test_Argv0_Discovery is
   use Ada.Text_IO;
   use Ada.Strings.Unbounded;
   use Test_Support;
   package Env renames Ada.Environment_Variables;
begin
   Env.Clear ("RUNFILES_MANIFEST_FILE");
   Env.Clear ("RUNFILES_DIR");
   Env.Clear ("JAVA_RUNFILES");
   Env.Clear ("TEST_SRCDIR");

   Put_Line ("argv[0]: " & Ada.Command_Line.Command_Name);

   declare
      R      : constant Runfiles.Context := Runfiles.Create;
      Vars   : constant Runfiles.Env_Var_Array := R.Env_Vars;
      Path   : constant String :=
        R.Rlocation ("rules_ada/tests/runfiles/sample.txt", Source_Repo => "");
      File   : File_Type;
      Buffer : String (1 .. 256);
      Last   : Natural;
   begin
      for V of Vars loop
         Put_Line (To_String (V.Name) & "=" & To_String (V.Value));
      end loop;

      if Length (Vars (1).Value) = 0 and then Length (Vars (2).Value) = 0 then
         Put_Line ("FAIL: Env_Vars reports neither manifest nor directory");
         raise Program_Error;
      end if;

      --  Under "bazel test" argv[0] lives inside the ".runfiles" tree; the
      --  ancestor walk must then report that tree as the directory.
      if Ada.Strings.Fixed.Index (Ada.Command_Line.Command_Name, ".runfiles/")
           > 0
        and then Length (Vars (2).Value) = 0
      then
         Put_Line ("FAIL: ancestor .runfiles directory not discovered");
         raise Program_Error;
      end if;

      Open (File, In_File, Path);
      Get_Line (File, Buffer, Last);
      Close (File);
      Expect (Buffer (1 .. Last), "Hello from runfiles!", "sample.txt content");
   end;

   Put_Line ("PASS: argv[0] discovery");
end Test_Argv0_Discovery;
