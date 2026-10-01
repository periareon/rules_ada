with Ada.Text_IO;
with Runfiles;
with Test_Support;

--  Invalid rlocation paths must raise Runfiles_Error; absolute paths are
--  returned unchanged.
procedure Test_Invalid_Paths is
   use Ada.Text_IO;
   use Test_Support;

   R : constant Runfiles.Context := Runfiles.Create;

   procedure Expect_Absolute (Path : String) is
   begin
      Expect (R.Rlocation (Path), Path, "absolute """ & Path & """ unchanged");
   end Expect_Absolute;
begin
   Expect_Error (R, "");
   Expect_Error (R, "../foo");
   Expect_Error (R, "foo/../bar");
   Expect_Error (R, "./foo");
   Expect_Error (R, "foo/./bar");
   Expect_Error (R, "foo/..");
   Expect_Error (R, "foo/.");
   Expect_Error (R, "foo//bar");
   Expect_Error (R, "//foo");

   --  The same checks apply to the mapping-aware overload.
   Expect_Error (R, "foo/../bar", Source_Repo => "");

   Expect_Absolute ("/tmp/absolute");
   Expect_Absolute ("C:\Windows\file.txt");
   Expect_Absolute ("c:/unix/style");

   Put_Line ("PASS: invalid paths");
end Test_Invalid_Paths;
