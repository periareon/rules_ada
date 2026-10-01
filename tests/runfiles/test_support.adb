with Ada.Text_IO;

package body Test_Support is

   use Ada.Text_IO;

   ------------
   -- Expect --
   ------------

   procedure Expect (Actual, Expected, What : String) is
   begin
      if Actual /= Expected then
         Put_Line ("FAIL: " & What);
         Put_Line ("      want """ & Expected & """");
         Put_Line ("      got  """ & Actual & """");
         raise Program_Error;
      end if;
   end Expect;

   ------------------
   -- Expect_Error --
   ------------------

   procedure Expect_Error (Ctx : Runfiles.Context; Path : String) is
   begin
      declare
         Unused : constant String := Ctx.Rlocation (Path);
      begin
         Put_Line ("FAIL: expected Runfiles_Error for """ & Path
                   & """, got " & Unused);
         raise Program_Error;
      end;
   exception
      when Runfiles.Runfiles_Error => null;
   end Expect_Error;

   procedure Expect_Error
     (Ctx         : Runfiles.Context;
      Path        : String;
      Source_Repo : String)
   is
   begin
      declare
         Unused : constant String := Ctx.Rlocation (Path, Source_Repo);
      begin
         Put_Line ("FAIL: expected Runfiles_Error for """ & Path
                   & """ from """ & Source_Repo & """, got " & Unused);
         raise Program_Error;
      end;
   exception
      when Runfiles.Runfiles_Error => null;
   end Expect_Error;

end Test_Support;
