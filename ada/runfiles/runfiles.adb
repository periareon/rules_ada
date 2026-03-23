with Ada.Text_IO;
with Ada.Environment_Variables;
with Ada.Command_Line;
with Ada.Directories;

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

   --  Helper: return env var value or "" if unset.
   function Get_Env (Name : String) return String is
   begin
      if Ada.Environment_Variables.Exists (Name) then
         return Ada.Environment_Variables.Value (Name);
      else
         return "";
      end if;
   end Get_Env;

   --  Unescape manifest entries per SourceManifestAction.java conventions.
   --  \n -> LF, \b -> backslash, \s -> space (key only).
   function Unescape
     (S             : String;
      Include_Space : Boolean) return String
   is
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
            elsif Include_Space and then S (I + 1) = 's' then
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

   --  Walk ancestors of Path looking for a directory whose name ends
   --  with ".runfiles". Returns "" if none found.
   function Find_Ancestor_Runfiles (Path : String) return String is
      use Ada.Directories;
      Name : constant String := Simple_Name (Path);
   begin
      if Ends_With (Name, ".runfiles")
        and then Exists (Path)
        and then Kind (Path) = Directory
      then
         return Path;
      end if;
      declare
         Parent : constant String := Containing_Directory (Path);
      begin
         if Parent = Path or else Parent'Length = 0 then
            return "";
         end if;
         return Find_Ancestor_Runfiles (Parent);
      end;
   exception
      when others => return "";
   end Find_Ancestor_Runfiles;

   --  Discover the runfiles directory from env vars or argv[0].
   function Find_Runfiles_Dir return String is
      use Ada.Directories;
   begin
      declare
         V : constant String := Get_Env ("RUNFILES_DIR");
      begin
         if V'Length > 0
           and then Exists (V)
           and then Kind (V) = Directory
         then
            return V;
         end if;
      end;

      declare
         V : constant String := Get_Env ("TEST_SRCDIR");
      begin
         if V'Length > 0
           and then Exists (V)
           and then Kind (V) = Directory
         then
            return V;
         end if;
      end;

      declare
         Exe     : constant String := Ada.Command_Line.Command_Name;
         Full    : constant String := Full_Name (Exe);
         Sibling : constant String := Full & ".runfiles";
      begin
         if Exists (Sibling) and then Kind (Sibling) = Directory then
            return Sibling;
         end if;

         declare
            Ancestor : constant String := Find_Ancestor_Runfiles (Full);
         begin
            if Ancestor'Length > 0 then
               return Ancestor;
            end if;
         end;
      end;

      raise Runfiles_Error with "Could not find runfiles directory";
   end Find_Runfiles_Dir;

   --  Parse a MANIFEST file into the map. Each line is
   --  "rlocation_path real_path" (space-separated). Lines beginning with
   --  a space contain backslash-escaped content.
   procedure Parse_Manifest_File
     (Map  : in out String_Maps.Map;
      Path : String)
   is
      use Ada.Text_IO;
      File : File_Type;
   begin
      Open (File, In_File, Path);
      while not End_Of_File (File) loop
         declare
            Line : constant String := Get_Line (File);
         begin
            if Line'Length > 0 then
               declare
                  Escaped : constant Boolean :=
                    Line (Line'First) = ' ';
                  Start   : constant Positive :=
                    (if Escaped then Line'First + 1 else Line'First);
                  Content : constant String :=
                    Line (Start .. Line'Last);
               begin
                  for I in Content'Range loop
                     if Content (I) = ' ' then
                        declare
                           Raw_Key   : constant String :=
                             Content (Content'First .. I - 1);
                           Raw_Value : constant String :=
                             Content (I + 1 .. Content'Last);
                           Key       : constant String :=
                             (if Escaped
                              then Unescape (Raw_Key, Include_Space => True)
                              else Raw_Key);
                           Value     : constant String :=
                             (if Escaped
                              then Unescape (Raw_Value, Include_Space => False)
                              else Raw_Value);
                        begin
                           Map.Include (Key, Value);
                        end;
                        exit;
                     end if;
                  end loop;
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
      when E : others =>
         if Is_Open (File) then
            Close (File);
         end if;
         raise Runfiles_Error with "Failed to parse manifest: " & Path;
   end Parse_Manifest_File;

   --  Parse _repo_mapping CSV file. Each line is
   --  "source_repo,apparent_name,target_repo".
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
      File : File_Type;
   begin
      if not Ada.Directories.Exists (Path) then
         return;
      end if;

      Open (File, In_File, Path);
      while not End_Of_File (File) loop
         declare
            Line         : constant String := Get_Line (File);
            First_Comma  : Natural := 0;
            Second_Comma : Natural := 0;
         begin
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

               if First_Comma > 0 and then Second_Comma > 0 then
                  declare
                     Source   : constant String :=
                       Line (Line'First .. First_Comma - 1);
                     Apparent : constant String :=
                       Line (First_Comma + 1 .. Second_Comma - 1);
                     Target   : constant String :=
                       Line (Second_Comma + 1 .. Line'Last);
                  begin
                     if Ends_With (Source, "*") then
                        declare
                           Prefix : constant String :=
                             Source (Source'First .. Source'Last - 1);
                           Key    : constant String :=
                             Prefix & "," & Apparent;
                        begin
                           Prefix_Map.Include (Key, Target);
                        end;
                     else
                        declare
                           Key : constant String :=
                             Source & "," & Apparent;
                        begin
                           Exact_Map.Include (Key, Target);
                        end;
                     end if;
                  end;
               end if;
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
   end Parse_Repo_Mapping_File;

   --  Internal rlocation that returns "" when the path is not found
   --  in manifest mode (instead of raising).
   function Try_Resolve (Ctx : Context; Path : String) return String is
   begin
      case Ctx.Mode is
         when Directory_Based =>
            return To_String (Ctx.Runfiles_Dir) & "/" & Path;
         when Manifest_Based =>
            if Ctx.Manifest.Contains (Path) then
               return Ctx.Manifest.Element (Path);
            else
               return "";
            end if;
      end case;
   end Try_Resolve;

   --  Internal rlocation that raises on not-found in manifest mode.
   function Resolve_Path (Ctx : Context; Path : String) return String is
   begin
      case Ctx.Mode is
         when Directory_Based =>
            return To_String (Ctx.Runfiles_Dir) & "/" & Path;
         when Manifest_Based =>
            if Ctx.Manifest.Contains (Path) then
               return Ctx.Manifest.Element (Path);
            else
               raise Runfiles_Error with
                 "Runfile not found in manifest: " & Path;
            end if;
      end case;
   end Resolve_Path;

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
        and then Path (Path'First + 1) = ':'
        and then (Path (Path'First + 2) = '\'
                  or else Path (Path'First + 2) = '/')
      then
         return True;
      end if;
      return False;
   end Is_Absolute;

   -----------
   -- Create --
   -----------

   function Create return Context is
      Manifest_Env : constant String := Get_Env ("RUNFILES_MANIFEST_FILE");
      Result       : Context;
   begin
      if Manifest_Env'Length > 0 then
         Result.Mode := Manifest_Based;
         Parse_Manifest_File (Result.Manifest, Manifest_Env);
      else
         declare
            Dir           : constant String := Find_Runfiles_Dir;
            Manifest_Path : constant String := Dir & "/MANIFEST";
         begin
            if Ada.Directories.Exists (Manifest_Path) then
               Result.Mode := Manifest_Based;
               Parse_Manifest_File (Result.Manifest, Manifest_Path);
            else
               Result.Mode := Directory_Based;
               Result.Runfiles_Dir := To_Unbounded_String (Dir);
            end if;
         end;
      end if;

      --  Load _repo_mapping if available.
      declare
         Mapping_Path : constant String :=
           Try_Resolve (Result, "_repo_mapping");
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
      if Is_Absolute (Path) then
         return Path;
      end if;
      return Resolve_Path (Self, Path);
   end Rlocation;

   ---------------
   -- Rlocation --
   ---------------

   --  Search the prefix map for a matching entry. Prefix entries come from
   --  --incompatible_compact_repo_mapping_manifest where source repos like
   --  "+deps+*" are stored with the '*' stripped as "prefix,apparent".
   --  Returns "" if no prefix matches.
   function Lookup_Prefix_Map
     (Map         : String_Maps.Map;
      Source_Repo : String;
      Apparent    : String) return String
   is
      use String_Maps;
      C : Cursor := Map.First;
   begin
      while Has_Element (C) loop
         declare
            K          : constant String := Key (C);
            Comma_Pos  : Natural := 0;
         begin
            for I in K'Range loop
               if K (I) = ',' then
                  Comma_Pos := I;
                  exit;
               end if;
            end loop;

            if Comma_Pos > 0 then
               declare
                  Prefix     : constant String :=
                    K (K'First .. Comma_Pos - 1);
                  Entry_Name : constant String :=
                    K (Comma_Pos + 1 .. K'Last);
               begin
                  if Entry_Name = Apparent
                    and then Starts_With (Source_Repo, Prefix)
                  then
                     return Element (C);
                  end if;
               end;
            end if;
         end;
         Next (C);
      end loop;
      return "";
   end Lookup_Prefix_Map;

   function Rlocation
     (Self        : Context;
      Path        : String;
      Source_Repo : String) return String
   is
   begin
      if Is_Absolute (Path) then
         return Path;
      end if;

      --  Split path into repo alias (before first '/') and remainder.
      declare
         Slash_Pos : Natural := 0;
      begin
         for I in Path'Range loop
            if Path (I) = '/' then
               Slash_Pos := I;
               exit;
            end if;
         end loop;

         declare
            Repo_Alias : constant String :=
              (if Slash_Pos > 0
               then Path (Path'First .. Slash_Pos - 1)
               else Path);
            Repo_Path  : constant String :=
              (if Slash_Pos > 0
               then Path (Slash_Pos + 1 .. Path'Last)
               else "");
            Key        : constant String :=
              Source_Repo & "," & Repo_Alias;
         begin
            --  First try an exact match in the repo map (O(1) hash lookup).
            if Self.Repo_Map.Contains (Key) then
               declare
                  Target : constant String := Self.Repo_Map.Element (Key);
               begin
                  if Repo_Path'Length > 0 then
                     return Resolve_Path
                       (Self, Target & "/" & Repo_Path);
                  else
                     return Resolve_Path (Self, Target);
                  end if;
               end;
            end if;

            --  Fall back to prefix matching for compact repo mapping
            --  (--incompatible_compact_repo_mapping_manifest).
            declare
               Target : constant String :=
                 Lookup_Prefix_Map
                   (Self.Repo_Map_Prefixes, Source_Repo, Repo_Alias);
            begin
               if Target'Length > 0 then
                  if Repo_Path'Length > 0 then
                     return Resolve_Path
                       (Self, Target & "/" & Repo_Path);
                  else
                     return Resolve_Path (Self, Target);
                  end if;
               end if;
            end;

            return Resolve_Path (Self, Path);
         end;
      end;
   end Rlocation;

end Runfiles;
