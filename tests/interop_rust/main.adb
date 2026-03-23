with Ada.Command_Line;
with Ada.Text_IO;
with Interfaces.C;

procedure Main is
   use Interfaces.C;

   function Rust_Multiply (A, B : int) return int;
   pragma Import (C, Rust_Multiply, "rust_multiply");

   F      : Ada.Text_IO.File_Type;
   Result : int;
begin
   if Ada.Command_Line.Argument_Count > 0 then
      Ada.Text_IO.Create (F, Ada.Text_IO.Out_File, Ada.Command_Line.Argument (1));
      Ada.Text_IO.Set_Output (F);
   end if;

   Result := Rust_Multiply (6, 7);
   Ada.Text_IO.Put_Line ("6 * 7 =" & int'Image (Result));
end Main;
