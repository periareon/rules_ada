with Ada.Strings.Fixed;
with Ada.Text_IO;
with GNAT.Expect;
with GNAT.OS_Lib;
with Runfiles;

--  Locates the `ghdl` binary through runfiles, runs `ghdl --version` and
--  checks that it exits cleanly and identifies itself as GHDL.
procedure Ghdl_Version_Test is
   use Ada.Text_IO;

   R : constant Runfiles.Context := Runfiles.Create;

   --  `ghdl` is the apparent name of the module in MODULE.bazel; the
   --  repository mapping turns it into the canonical one. The suffix is
   --  ".exe" on Windows and empty elsewhere.
   Ghdl : constant String :=
     R.Rlocation
       ("ghdl/ghdl" & GNAT.OS_Lib.Get_Executable_Suffix.all,
        Source_Repo => "");

   Args   : GNAT.OS_Lib.Argument_List := (1 => new String'("--version"));
   Status : aliased Integer;
begin
   Put_Line ("ghdl: " & Ghdl);

   declare
      Output : constant String :=
        GNAT.Expect.Get_Command_Output
          (Command    => Ghdl,
           Arguments  => Args,
           Input      => "",
           Status     => Status'Access,
           Err_To_Out => True);
   begin
      Put_Line (Output);

      if Status /= 0 then
         Put_Line ("FAIL: ghdl --version exited with status"
                   & Integer'Image (Status));
         raise Program_Error;
      end if;

      if Ada.Strings.Fixed.Index (Output, "GHDL") = 0 then
         Put_Line ("FAIL: output does not mention GHDL");
         raise Program_Error;
      end if;
   end;

   for A of Args loop
      GNAT.OS_Lib.Free (A);
   end loop;

   Put_Line ("PASS: ghdl_version_test");
end Ghdl_Version_Test;
