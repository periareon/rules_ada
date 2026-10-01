with Ada.Text_IO;
with Ada.Numerics.Generic_Elementary_Functions;

procedure Runtime_Test is
   package Math is new Ada.Numerics.Generic_Elementary_Functions (Long_Float);

   protected Counter is
      procedure Increment;
      function Value return Natural;
   private
      Count : Natural := 0;
   end Counter;

   protected body Counter is
      procedure Increment is
      begin
         Count := Count + 1;
      end Increment;

      function Value return Natural is
      begin
         return Count;
      end Value;
   end Counter;

   task type Worker is
      entry Start (Iterations : Positive);
   end Worker;

   task body Worker is
      N : Positive;
   begin
      accept Start (Iterations : Positive) do
         N := Iterations;
      end Start;
      for I in 1 .. N loop
         Counter.Increment;
         if I mod 100 = 0 then
            delay 0.001;
         end if;
      end loop;
   end Worker;

   Custom_Error : exception;
   Handled      : Boolean := False;
begin
   --  Tasking: libgnarl and the platform thread library.
   declare
      Workers : array (1 .. 4) of Worker;
   begin
      for W of Workers loop
         W.Start (500);
      end loop;
   end;  --  waits for all workers
   if Counter.Value /= 2000 then
      Ada.Text_IO.Put_Line ("FAIL: counter =" & Natural'Image (Counter.Value));
      raise Program_Error;
   end if;

   --  Numerics: libm.
   if abs (Math.Sqrt (2.0) * Math.Sqrt (2.0) - 2.0) > 1.0e-12 then
      Ada.Text_IO.Put_Line ("FAIL: sqrt");
      raise Program_Error;
   end if;

   --  Exceptions: the unwinder.
   begin
      raise Custom_Error with "expected";
   exception
      when Custom_Error =>
         Handled := True;
   end;
   if not Handled then
      Ada.Text_IO.Put_Line ("FAIL: exception not handled");
      raise Program_Error;
   end if;

   Ada.Text_IO.Put_Line ("PASS: tasking, numerics and exceptions work");
end Runtime_Test;
