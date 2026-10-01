# Runfiles

`@rules_ada//ada/runfiles` is an Ada implementation of Bazel's runfiles
lookup, equivalent to the C++ and Python libraries that ship with Bazel. It
finds the runfiles manifest or directory from the environment or from the
program's own path and resolves `Rlocation` paths, honouring the bzlmod
repository mapping.

```python
ada_binary(
    name = "tool",
    srcs = ["tool.adb"],
    data = ["config.toml"],
    deps = ["@rules_ada//ada/runfiles"],
)
```

```ada
with Runfiles;

procedure Tool is
   R    : constant Runfiles.Context := Runfiles.Create;
   Path : constant String :=
     R.Rlocation ("my_module/config.toml", Source_Repo => "");
begin
   ...
end Tool;
```

The full API and discovery rules are documented in the library's
[README](https://github.com/periareon/rules_ada/blob/main/ada/runfiles/README.md).
