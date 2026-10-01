with Ada.Text_IO;
with Runfiles;
with Test_Support;

procedure Test_Runfiles is
   use Ada.Text_IO;
   use Test_Support;

   R : constant Runfiles.Context := Runfiles.Create;

   --  Use the bzlmod-aware Rlocation with Source_Repo => "". In bzlmod,
   --  the root module's canonical name is "" as a source repo, and the
   --  _repo_mapping file maps the apparent name "rules_ada" to the
   --  canonical name "_main" used in the runfiles tree.
   Path : constant String :=
     R.Rlocation ("rules_ada/tests/runfiles/sample.txt",
                   Source_Repo => "");

   File   : File_Type;
   Buffer : String (1 .. 256);
   Last   : Natural;
begin
   Put_Line ("Resolved path: " & Path);

   Open (File, In_File, Path);
   Get_Line (File, Buffer, Last);
   Close (File);
   Expect (Buffer (1 .. Last), "Hello from runfiles!", "sample.txt content");

   --  Absolute paths pass through unchanged.
   Expect (R.Rlocation ("/tmp/absolute"), "/tmp/absolute",
           "absolute path returned as-is");

   Put_Line ("PASS: all runfiles assertions passed");
end Test_Runfiles;
