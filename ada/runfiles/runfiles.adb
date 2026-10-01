with Ada.Text_IO;
with Ada.Environment_Variables;
with Ada.Command_Line;
with Ada.Directories;
with Ada.Strings.Fixed;

package body Runfiles is

   --  Helper: check if S ends with Suffix.
   function Ends_With (S : String; Suffix : String) return Boolean is
   begin
      return S'Length >= Suffix'Length
        and then S (S'Last - Suffix'Length + 1 .. S'Last) = Suffix;
   end Ends_With;

   --  Helper: check if S starts with Prefix.
   function Starts_With (S : String; Prefix : String) return Boolean is
   begin
      return S'Length >= Prefix'Length
        and then S (S'First .. S'First + Prefix'Length - 1) = Prefix;
   end Starts_With;

   --  Helper: check if S contains Sub.
   function Contains (S : String; Sub : String) return Boolean is
   begin
      return Ada.Strings.Fixed.Index (S, Sub) > 0;
   end Contains;

   --  Helper: return env var value or "" if unset.
   function Get_Env (Name : String) return String is
   begin
      if Ada.Environment_Variables.Exists (Name) then
         return Ada.Environment_Variables.Value (Name);
      else
         return "";
      end if;
   end Get_Env;

   --  Helper: True if Path names an existing directory.
   function Is_Directory (Path : String) return Boolean is
      use Ada.Directories;
   begin
      return Path'Length > 0
        and then Exists (Path)
        and then Kind (Path) = Directory;
   exception
      when others => return False;
   end Is_Directory;

   --  Helper: True if Path names an ordinary file that can be opened for
   --  reading. A stale or unreadable manifest is treated as absent.
   function Is_Readable_File (Path : String) return Boolean is
      use Ada.Directories;
      File : Ada.Text_IO.File_Type;
   begin
      if Path'Length = 0
        or else not Exists (Path)
        or else Kind (Path) /= Ordinary_File
      then
         return False;
      end if;
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
      Ada.Text_IO.Close (File);
      return True;
   exception
      when others => return False;
   end Is_Readable_File;

   --  Returns True if Path is an absolute filesystem path.
   function Is_Absolute (Path : String) return Boolean is
   begin
      if Path'Length = 0 then
         return False;
      end if;
      if Path (Path'First) = '/' then
         return True;
      end if;
      --  Windows drive letter paths: C:\... or C:/...
      if Path'Length >= 3
        and then Path (Path'First) in 'a' .. 'z' | 'A' .. 'Z'
        and then Path (Path'First + 1) = ':'
        and then (Path (Path'First + 2) = '\'
                  or else Path (Path'First + 2) = '/')
      then
         return True;
      end if;
      return False;
   end Is_Absolute;

   --  Helper: absolute form of Path, or "" if it cannot be computed (for
   --  example an empty argv[0]). Symbolic links are deliberately not
   --  resolved: a binary executed from inside a ".runfiles" tree must keep
   --  that tree as an ancestor. Never raises.
   function Absolute_Path (Path : String) return String is
   begin
      if Path'Length = 0 then
         return "";
      elsif Is_Absolute (Path) then
         return Path;
      end if;
      return Ada.Directories.Current_Directory & "/" & Path;
   exception
      when others => return "";
   end Absolute_Path;

   --  Unescape manifest entries per SourceManifestAction.java conventions.
   --  \n -> LF, \b -> backslash, \s -> space.
   function Unescape (S : String) return String is
      Result : String (1 .. S'Length);
      J      : Natural := 0;
      I      : Positive := S'First;
   begin
      while I <= S'Last loop
         if I < S'Last and then S (I) = '\' then
            if S (I + 1) = 'n' then
               J := J + 1;
               Result (J) := ASCII.LF;
               I := I + 2;
            elsif S (I + 1) = 'b' then
               J := J + 1;
               Result (J) := '\';
               I := I + 2;
            elsif S (I + 1) = 's' then
               J := J + 1;
               Result (J) := ' ';
               I := I + 2;
            else
               J := J + 1;
               Result (J) := S (I);
               I := I + 1;
            end if;
         else
            J := J + 1;
            Result (J) := S (I);
            I := I + 1;
         end if;
      end loop;
      return Result (1 .. J);
   end Unescape;

   --  Probe the runfiles locations that live next to Base, i.e.
   --  "<Base>.runfiles/MANIFEST", "<Base>.runfiles" and
   --  "<Base>.runfiles_manifest". Only fills in what is still missing.
   procedure Probe_Sibling
     (Base      : String;
      Manifest  : in out Unbounded_String;
      Directory : in out Unbounded_String)
   is
   begin
      if Length (Manifest) = 0
        and then Is_Readable_File (Base & ".runfiles/MANIFEST")
      then
         Manifest := To_Unbounded_String (Base & ".runfiles/MANIFEST");
      end if;
      if Length (Directory) = 0
        and then Is_Directory (Base & ".runfiles")
      then
         Directory := To_Unbounded_String (Base & ".runfiles");
      end if;
      if Length (Manifest) = 0
        and then Is_Readable_File (Base & ".runfiles_manifest")
      then
         Manifest := To_Unbounded_String (Base & ".runfiles_manifest");
      end if;
   end Probe_Sibling;

   --  Walk argv[0] and its ancestors looking for runfiles. An ancestor whose
   --  name ends in ".runfiles" is accepted as the runfiles directory;
   --  otherwise the sibling probes are tried for each ancestor.
   procedure Discover_From_Argv0
     (Manifest  : in out Unbounded_String;
      Directory : in out Unbounded_String)
   is
      use Ada.Directories;
      Argv0 : constant String := Ada.Command_Line.Command_Name;
   begin
      if Argv0'Length = 0 then
         return;
      end if;

      Probe_Sibling (Argv0, Manifest, Directory);
      if Length (Manifest) > 0 or else Length (Directory) > 0 then
         return;
      end if;

      declare
         Current : Unbounded_String :=
           To_Unbounded_String (Absolute_Path (Argv0));
      begin
         while Length (Current) > 0
           and then Length (Manifest) = 0
           and then Length (Directory) = 0
         loop
            declare
               P : constant String := To_String (Current);
            begin
               if Ends_With (Simple_Name (P), ".runfiles")
                 and then Is_Directory (P)
               then
                  Directory := Current;
               else
                  Probe_Sibling (P, Manifest, Directory);
               end if;

               declare
                  Parent : constant String := Containing_Directory (P);
               begin
                  exit when Parent = P;
                  Current := To_Unbounded_String (Parent);
               end;
            exception
               when others => exit;
            end;
         end loop;
      end;
   end Discover_From_Argv0;

   --  Locate the runfiles manifest and/or directory. On return at least one
   --  of Manifest / Directory is non-empty, otherwise Runfiles_Error is
   --  raised. Mirrors PathsFrom() in rules_cc's runfiles.cc.
   procedure Find_Runfiles_Paths
     (Manifest  : out Unbounded_String;
      Directory : out Unbounded_String)
   is
   begin
      Manifest  := Null_Unbounded_String;
      Directory := Null_Unbounded_String;

      --  1. Environment variables.
      declare
         V : constant String := Get_Env ("RUNFILES_MANIFEST_FILE");
      begin
         if Is_Readable_File (V) then
            Manifest := To_Unbounded_String (V);
         end if;
      end;

      declare
         V : constant String := Get_Env ("RUNFILES_DIR");
      begin
         if Is_Directory (V) then
            Directory := To_Unbounded_String (V);
         end if;
      end;

      if Length (Directory) = 0 then
         declare
            V : constant String := Get_Env ("TEST_SRCDIR");
         begin
            if Is_Directory (V) then
               Directory := To_Unbounded_String (V);
            end if;
         end;
      end if;

      --  2. argv[0] discovery, only when the environment gave us nothing.
      if Length (Manifest) = 0 and then Length (Directory) = 0 then
         Discover_From_Argv0 (Manifest, Directory);
      end if;

      if Length (Manifest) = 0 and then Length (Directory) = 0 then
         raise Runfiles_Error with
           "Could not find runfiles (argv0="""
           & Ada.Command_Line.Command_Name & """)";
      end if;

      --  3. Derive the manifest from the directory ...
      if Length (Manifest) = 0 then
         declare
            Dir : constant String := To_String (Directory);
         begin
            if Is_Readable_File (Dir & "/MANIFEST") then
               Manifest := To_Unbounded_String (Dir & "/MANIFEST");
            elsif Is_Readable_File (Dir & "_manifest") then
               Manifest := To_Unbounded_String (Dir & "_manifest");
            end if;
         end;
      end if;

      --  ... or the directory from the manifest.
      if Length (Directory) = 0 then
         declare
            Mf : constant String := To_String (Manifest);
            --  Both "_manifest" and "/MANIFEST" are 9 characters long.
            Suffix_Length : constant := 9;
         begin
            if Ends_With (Mf, "_manifest") or else Ends_With (Mf, "/MANIFEST")
            then
               declare
                  Dir : constant String :=
                    Mf (Mf'First .. Mf'Last - Suffix_Length);
               begin
                  if Is_Directory (Dir) then
                     Directory := To_Unbounded_String (Dir);
                  end if;
               end;
            end if;
         end;
      end if;
   end Find_Runfiles_Paths;

   --  Parse a MANIFEST file into the map. Each line is
   --  "rlocation_path real_path" (space-separated). Lines beginning with
   --  a space contain backslash-escaped content. Lines without a separating
   --  space are malformed.
   procedure Parse_Manifest_File
     (Map  : in out String_Maps.Map;
      Path : String)
   is
      use Ada.Text_IO;
      File        : File_Type;
      Line_Number : Natural := 0;
   begin
      begin
         Open (File, In_File, Path);
      exception
         when others =>
            raise Runfiles_Error with
              "Cannot open runfiles manifest: " & Path;
      end;

      while not End_Of_File (File) loop
         declare
            Line : constant String := Get_Line (File);
         begin
            Line_Number := Line_Number + 1;
            if Line'Length > 0 then
               declare
                  Escaped : constant Boolean :=
                    Line (Line'First) = ' ';
                  Start   : constant Positive :=
                    (if Escaped then Line'First + 1 else Line'First);
                  Content : constant String :=
                    Line (Start .. Line'Last);
                  Space   : constant Natural :=
                    Ada.Strings.Fixed.Index (Content, " ");
               begin
                  if Space = 0 then
                     raise Runfiles_Error with
                       "Bad runfiles manifest entry in """ & Path
                       & """ line #" & Line_Number'Image
                       & ": """ & Line & """";
                  end if;

                  declare
                     Raw_Key   : constant String :=
                       Content (Content'First .. Space - 1);
                     Raw_Value : constant String :=
                       Content (Space + 1 .. Content'Last);
                  begin
                     if Escaped then
                        Map.Include
                          (Unescape (Raw_Key), Unescape (Raw_Value));
                     else
                        Map.Include (Raw_Key, Raw_Value);
                     end if;
                  end;
               end;
            end if;
         end;
      end loop;
      Close (File);
   exception
      when Runfiles_Error =>
         if Is_Open (File) then
            Close (File);
         end if;
         raise;
      when others =>
         if Is_Open (File) then
            Close (File);
         end if;
         raise Runfiles_Error with "Failed to parse manifest: " & Path;
   end Parse_Manifest_File;

   --  Parse _repo_mapping CSV file. Each line is
   --  "source_repo,apparent_name,target_repo". A missing file is not an
   --  error (the binary was built without bzlmod); a malformed line is.
   --
   --  Exact entries are stored in Exact_Map as "source_repo,apparent" -> target.
   --
   --  Compact/wildcard entries (--incompatible_compact_repo_mapping_manifest,
   --  see https://github.com/bazelbuild/bazel/issues/26262) have source_repo
   --  ending with '*'. The '*' is stripped and the entry is stored in
   --  Prefix_Map as "prefix,apparent" -> target, to be matched at lookup time
   --  by checking whether the caller's source repo starts with the prefix.
   procedure Parse_Repo_Mapping_File
     (Exact_Map  : in out String_Maps.Map;
      Prefix_Map : in out String_Maps.Map;
      Path       : String)
   is
      use Ada.Text_IO;
      File        : File_Type;
      Line_Number : Natural := 0;
   begin
      if not Is_Readable_File (Path) then
         return;
      end if;

      Open (File, In_File, Path);
      while not End_Of_File (File) loop
         declare
            Line         : constant String := Get_Line (File);
            First_Comma  : Natural := 0;
            Second_Comma : Natural := 0;
         begin
            Line_Number := Line_Number + 1;
            if Line'Length > 0 then
               for I in Line'Range loop
                  if Line (I) = ',' then
                     if First_Comma = 0 then
                        First_Comma := I;
                     elsif Second_Comma = 0 then
                        Second_Comma := I;
                        exit;
                     end if;
                  end if;
               end loop;

               if First_Comma = 0 or else Second_Comma = 0 then
                  raise Runfiles_Error with
                    "Bad repository mapping entry in """ & Path
                    & """ line #" & Line_Number'Image
                    & ": """ & Line & """";
               end if;

               declare
                  Source   : constant String :=
                    Line (Line'First .. First_Comma - 1);
                  Apparent : constant String :=
                    Line (First_Comma + 1 .. Second_Comma - 1);
                  Target   : constant String :=
                    Line (Second_Comma + 1 .. Line'Last);
               begin
                  if Ends_With (Source, "*") then
                     Prefix_Map.Include
                       (Source (Source'First .. Source'Last - 1)
                        & "," & Apparent,
                        Target);
                  else
                     Exact_Map.Include (Source & "," & Apparent, Target);
                  end if;
               end;
            end if;
         end;
      end loop;
      Close (File);
   exception
      when Runfiles_Error =>
         if Is_Open (File) then
            Close (File);
         end if;
         raise;
      when others =>
         if Is_Open (File) then
            Close (File);
         end if;
         raise Runfiles_Error with
           "Failed to parse repository mapping: " & Path;
   end Parse_Repo_Mapping_File;

   --  Resolve Path through the manifest (exact entry, then the longest
   --  "/"-prefix entry) and finally the runfiles directory. Returns "" when
   --  nothing applies. Mirrors RlocationUnchecked() in rules_cc.
   function Resolve_Unchecked (Ctx : Context; Path : String) return String is
   begin
      if Ctx.Manifest.Contains (Path) then
         return Ctx.Manifest.Element (Path);
      end if;

      --  If Path lies under a directory that itself is a runfile, only the
      --  directory is listed in the manifest. Try each prefix of Path from
      --  longest to shortest and append the remainder to the match.
      declare
         Prefix_End : Natural := Path'Last;
      begin
         loop
            declare
               Slash : constant Natural :=
                 Ada.Strings.Fixed.Index
                   (Path (Path'First .. Prefix_End), "/",
                    Going => Ada.Strings.Backward);
            begin
               exit when Slash = 0;
               declare
                  Prefix : constant String := Path (Path'First .. Slash - 1);
               begin
                  if Ctx.Manifest.Contains (Prefix) then
                     return Ctx.Manifest.Element (Prefix)
                       & "/" & Path (Slash + 1 .. Path'Last);
                  end if;
               end;
               exit when Slash = Path'First;
               Prefix_End := Slash - 1;
            end;
         end loop;
      end;

      if Length (Ctx.Runfiles_Dir) > 0 then
         return To_String (Ctx.Runfiles_Dir) & "/" & Path;
      end if;

      return "";
   end Resolve_Unchecked;

   --  Like Resolve_Unchecked, but raises Runfiles_Error on a miss.
   function Resolve_Path (Ctx : Context; Path : String) return String is
      Result : constant String := Resolve_Unchecked (Ctx, Path);
   begin
      if Result'Length = 0 then
         raise Runfiles_Error with "Runfile not found: " & Path;
      end if;
      return Result;
   end Resolve_Path;

   --  Raise Runfiles_Error if Path is not a well-formed rlocation path.
   procedure Validate_Path (Path : String) is
   begin
      if Path'Length = 0
        or else Starts_With (Path, "../")
        or else Contains (Path, "/../")
        or else Starts_With (Path, "./")
        or else Contains (Path, "/./")
        or else Ends_With (Path, "/..")
        or else Ends_With (Path, "/.")
        or else Contains (Path, "//")
      then
         raise Runfiles_Error with
           "Invalid rlocation path (must be normalized and non-empty): """
           & Path & """";
      end if;
   end Validate_Path;

   --  Search the prefix map for the entry with the longest prefix that
   --  Source_Repo starts with, among entries for Apparent. Prefix entries
   --  come from --incompatible_compact_repo_mapping_manifest where source
   --  repos like "+deps+*" are stored with the '*' stripped as
   --  "prefix,apparent". Returns "" if no prefix matches.
   function Lookup_Prefix_Map
     (Map         : String_Maps.Map;
      Source_Repo : String;
      Apparent    : String) return String
   is
      use String_Maps;
      C           : Cursor := Map.First;
      Best_Length : Integer := -1;
      Best        : Unbounded_String;
   begin
      while Has_Element (C) loop
         declare
            K     : constant String := Key (C);
            Comma : constant Natural := Ada.Strings.Fixed.Index (K, ",");
         begin
            if Comma > 0 then
               declare
                  Prefix     : constant String := K (K'First .. Comma - 1);
                  Entry_Name : constant String := K (Comma + 1 .. K'Last);
               begin
                  if Entry_Name = Apparent
                    and then Starts_With (Source_Repo, Prefix)
                    and then Prefix'Length > Best_Length
                  then
                     Best_Length := Prefix'Length;
                     Best := To_Unbounded_String (Element (C));
                  end if;
               end;
            end if;
         end;
         Next (C);
      end loop;
      return To_String (Best);
   end Lookup_Prefix_Map;

   ------------
   -- Create --
   ------------

   function Create return Context is
      Result : Context;
   begin
      Find_Runfiles_Paths (Result.Manifest_Path, Result.Runfiles_Dir);

      if Length (Result.Manifest_Path) > 0 then
         Parse_Manifest_File
           (Result.Manifest, To_String (Result.Manifest_Path));
      end if;

      --  Load _repo_mapping if available.
      declare
         Mapping_Path : constant String :=
           Resolve_Unchecked (Result, "_repo_mapping");
      begin
         if Mapping_Path'Length > 0 then
            Parse_Repo_Mapping_File
              (Exact_Map  => Result.Repo_Map,
               Prefix_Map => Result.Repo_Map_Prefixes,
               Path       => Mapping_Path);
         end if;
      end;

      return Result;
   end Create;

   ---------------
   -- Rlocation --
   ---------------

   function Rlocation (Self : Context; Path : String) return String is
   begin
      Validate_Path (Path);
      if Is_Absolute (Path) then
         return Path;
      end if;
      return Resolve_Path (Self, Path);
   end Rlocation;

   ---------------
   -- Rlocation --
   ---------------

   function Rlocation
     (Self        : Context;
      Path        : String;
      Source_Repo : String) return String
   is
      Slash : constant Natural := Ada.Strings.Fixed.Index (Path, "/");
   begin
      Validate_Path (Path);
      if Is_Absolute (Path) then
         return Path;
      end if;

      --  Paths without a "/" are not subject to repository mapping.
      if Slash = 0 then
         return Resolve_Path (Self, Path);
      end if;

      declare
         Apparent  : constant String := Path (Path'First .. Slash - 1);
         Remainder : constant String := Path (Slash .. Path'Last);
         Key       : constant String := Source_Repo & "," & Apparent;
      begin
         --  Exact entries take precedence over wildcard prefix entries.
         if Self.Repo_Map.Contains (Key) then
            return Resolve_Path
              (Self, Self.Repo_Map.Element (Key) & Remainder);
         end if;

         declare
            Target : constant String :=
              Lookup_Prefix_Map (Self.Repo_Map_Prefixes, Source_Repo, Apparent);
         begin
            if Target'Length > 0 then
               return Resolve_Path (Self, Target & Remainder);
            end if;
         end;

         return Resolve_Path (Self, Path);
      end;
   end Rlocation;

   --------------
   -- Env_Vars --
   --------------

   function Env_Vars (Self : Context) return Env_Var_Array is
   begin
      return
        (1 => (Name  => To_Unbounded_String ("RUNFILES_MANIFEST_FILE"),
               Value => Self.Manifest_Path),
         2 => (Name  => To_Unbounded_String ("RUNFILES_DIR"),
               Value => Self.Runfiles_Dir),
         3 => (Name  => To_Unbounded_String ("JAVA_RUNFILES"),
               Value => Self.Runfiles_Dir));
   end Env_Vars;

end Runfiles;
