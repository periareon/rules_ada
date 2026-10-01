with Ada.Command_Line;
with Ada.Text_IO;
with Interfaces.C;

procedure Main is
   function Registered_Plugins return Interfaces.C.int;
   pragma Import (C, Registered_Plugins, "registered_plugins");

   F : Ada.Text_IO.File_Type;
begin
   if Ada.Command_Line.Argument_Count > 0 then
      Ada.Text_IO.Create (F, Ada.Text_IO.Out_File, Ada.Command_Line.Argument (1));
      Ada.Text_IO.Set_Output (F);
   end if;

   Ada.Text_IO.Put_Line
     ("plugins:" & Interfaces.C.int'Image (Registered_Plugins));
end Main;
