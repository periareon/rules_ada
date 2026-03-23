package Ada_Math is
   function Add (A, B : Integer) return Integer;
   pragma Export (C, Add, "ada_add");
end Ada_Math;
