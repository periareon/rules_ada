with Ada.Text_IO;

procedure Test_Assertions is
begin
   if 2 + 2 /= 4 then
      Ada.Text_IO.Put_Line ("FAIL: 2 + 2 /= 4");
      raise Program_Error;
   end if;

   if 10 - 3 /= 7 then
      Ada.Text_IO.Put_Line ("FAIL: 10 - 3 /= 7");
      raise Program_Error;
   end if;

   Ada.Text_IO.Put_Line ("PASS: all assertions passed");
end Test_Assertions;
