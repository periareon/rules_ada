with Ada.Command_Line;
with Ada.Text_IO;
with Interfaces.C;

procedure Main is
   function C_Compute (A, B, C : Interfaces.C.int) return Interfaces.C.int;
   pragma Import (C, C_Compute, "c_compute");

   F      : Ada.Text_IO.File_Type;
   Result : Interfaces.C.int;
begin
   if Ada.Command_Line.Argument_Count > 0 then
      Ada.Text_IO.Create (F, Ada.Text_IO.Out_File, Ada.Command_Line.Argument (1));
      Ada.Text_IO.Set_Output (F);
   end if;

   Result := C_Compute (1, 2, 3);
   Ada.Text_IO.Put_Line ("1 + 2 + 3 =" & Interfaces.C.int'Image (Result));
end Main;
