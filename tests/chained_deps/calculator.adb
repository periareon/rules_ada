with Math_Utils;

package body Calculator is
   function Sum_Three (A, B, C : Integer) return Integer is
   begin
      return Math_Utils.Add (Math_Utils.Add (A, B), C);
   end Sum_Three;
end Calculator;
