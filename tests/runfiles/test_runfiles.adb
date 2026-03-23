with Ada.Text_IO;
with Runfiles;

procedure Test_Runfiles is
   use Ada.Text_IO;

   R : constant Runfiles.Context := Runfiles.Create;

   --  Use the bzlmod-aware Rlocation with Source_Repo => "". In bzlmod,
   --  the root module's source repo is "", and the _repo_mapping file
   --  maps "rules_ada" to the canonical name "_main".
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

   declare
      Content  : constant String := Buffer (1 .. Last);
      Expected : constant String := "Hello from runfiles!";
   begin
      if Content /= Expected then
         Put_Line ("FAIL: expected """ & Expected & """");
         Put_Line ("      got     """ & Content & """");
         raise Program_Error;
      end if;
   end;

   --  Test that absolute paths pass through unchanged.
   declare
      Abs_Path : constant String := "/tmp/absolute";
      Result   : constant String := R.Rlocation (Abs_Path);
   begin
      if Result /= Abs_Path then
         Put_Line ("FAIL: absolute path not returned as-is");
         Put_Line ("      got """ & Result & """");
         raise Program_Error;
      end if;
   end;

   Put_Line ("PASS: all runfiles assertions passed");
end Test_Runfiles;
