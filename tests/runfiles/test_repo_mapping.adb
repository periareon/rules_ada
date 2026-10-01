with Ada.Environment_Variables;
with Ada.Text_IO;
with Runfiles;
with Test_Support;

--  Repository mapping against a fixture _repo_mapping (checked in under
--  testdata/) and a fixture manifest written to TEST_TMPDIR. Covers exact
--  entries, wildcard prefix entries with longest-prefix selection, exact
--  beating wildcard, and no mapping for paths without a "/".
procedure Test_Repo_Mapping is
   use Ada.Text_IO;
   use Test_Support;
   package Env renames Ada.Environment_Variables;

   --  Locate the checked-in fixture through the real runfiles first.
   Fixture : constant String :=
     Runfiles.Create.Rlocation
       ("rules_ada/tests/runfiles/testdata/fixture_repo_mapping",
        Source_Repo => "");

   Manifest : constant String := Env.Value ("TEST_TMPDIR") & "/manifest.txt";
   File     : File_Type;
begin
   Create (File, Out_File, Manifest);
   Put_Line (File, "_repo_mapping " & Fixture);
   Put_Line (File, "_main/data/file.txt /fake/main/file.txt");
   Put_Line (File, "+ext+foo/x.txt /fake/ext_foo/x.txt");
   Put_Line (File, "+star+foo/x.txt /fake/star_foo/x.txt");
   Put_Line (File, "+deps+foo/x.txt /fake/deps_foo/x.txt");
   Put_Line (File, "+deps+bar+foo/x.txt /fake/deps_bar_foo/x.txt");
   Put_Line (File, "my_data /fake/raw_my_data");
   Close (File);

   Env.Set ("RUNFILES_MANIFEST_FILE", Manifest);
   Env.Clear ("RUNFILES_DIR");
   Env.Clear ("TEST_SRCDIR");

   declare
      R : constant Runfiles.Context := Runfiles.Create;
   begin
      Expect (R.Rlocation ("my_data/data/file.txt", Source_Repo => ""),
              "/fake/main/file.txt", "exact entry for root module");
      Expect (R.Rlocation ("foo/x.txt", Source_Repo => ""),
              "/fake/ext_foo/x.txt", "exact entry for root module (foo)");
      Expect (R.Rlocation ("foo/x.txt", Source_Repo => "+other"),
              "/fake/star_foo/x.txt", "wildcard '+*' prefix");
      Expect (R.Rlocation ("foo/x.txt", Source_Repo => "+deps+zzz"),
              "/fake/deps_foo/x.txt",
              "longest wildcard prefix '+deps+*' beats '+*'");
      Expect (R.Rlocation ("foo/x.txt", Source_Repo => "+deps+bar"),
              "/fake/deps_bar_foo/x.txt", "exact entry beats wildcards");
      Expect (R.Rlocation ("my_data", Source_Repo => ""),
              "/fake/raw_my_data", "no mapping for path without '/'");

      Expect_Error (R, "unmapped/x.txt", Source_Repo => "");
   end;

   Put_Line ("PASS: repo mapping");
end Test_Repo_Mapping;
