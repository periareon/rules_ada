with Runfiles;

--  Assertion helpers shared by the runfiles tests. Every failure prints a
--  "FAIL: ..." line and raises Program_Error.
package Test_Support is

   --  Fails unless Actual = Expected.
   procedure Expect (Actual, Expected, What : String);

   --  Fails unless Ctx.Rlocation (Path) raises Runfiles_Error.
   procedure Expect_Error (Ctx : Runfiles.Context; Path : String);

   --  Fails unless Ctx.Rlocation (Path, Source_Repo) raises Runfiles_Error.
   procedure Expect_Error
     (Ctx         : Runfiles.Context;
      Path        : String;
      Source_Repo : String);

end Test_Support;
