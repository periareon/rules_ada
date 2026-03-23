with Ada.Command_Line;
with Ada.Text_IO;
with Calculator;

procedure Main is
   F      : Ada.Text_IO.File_Type;
   Result : Integer;
begin
   if Ada.Command_Line.Argument_Count > 0 then
      Ada.Text_IO.Create (F, Ada.Text_IO.Out_File, Ada.Command_Line.Argument (1));
      Ada.Text_IO.Set_Output (F);
   end if;

   Result := Calculator.Sum_Three (1, 2, 3);
   Ada.Text_IO.Put_Line ("Sum: " & Integer'Image (Result));
end Main;
