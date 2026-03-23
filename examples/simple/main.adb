with Ada.Text_IO;
with Math;

procedure Main is
   Result : constant Integer := Math.Add (2, 3);
begin
   Ada.Text_IO.Put_Line ("2 + 3 =" & Integer'Image (Result));
end Main;
