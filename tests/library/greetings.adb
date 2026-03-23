with Ada.Text_IO;

package body Greetings is
   procedure Say_Hello is
   begin
      Ada.Text_IO.Put_Line ("Hello from Greetings!");
   end Say_Hello;
end Greetings;
