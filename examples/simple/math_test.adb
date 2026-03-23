with Ada.Text_IO;
with Math;

procedure Math_Test is
begin
   if Math.Add (2, 3) /= 5 then
      Ada.Text_IO.Put_Line ("FAIL: Math.Add (2, 3) /= 5");
      raise Program_Error;
   end if;

   if Math.Sub (5, 2) /= 3 then
      Ada.Text_IO.Put_Line ("FAIL: Math.Sub (5, 2) /= 3");
      raise Program_Error;
   end if;

   Ada.Text_IO.Put_Line ("PASS: math_test");
end Math_Test;
