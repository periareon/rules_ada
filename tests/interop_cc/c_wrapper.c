extern int ada_add(int a, int b);

int c_compute(int a, int b, int c) { return ada_add(ada_add(a, b), c); }
