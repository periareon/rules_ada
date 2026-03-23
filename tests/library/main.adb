with Ada.Command_Line;
with Ada.Text_IO;
with Greetings;

procedure Main is
   F : Ada.Text_IO.File_Type;
begin
   if Ada.Command_Line.Argument_Count > 0 then
      Ada.Text_IO.Create (F, Ada.Text_IO.Out_File, Ada.Command_Line.Argument (1));
      Ada.Text_IO.Set_Output (F);
   end if;

   Greetings.Say_Hello;
end Main;
